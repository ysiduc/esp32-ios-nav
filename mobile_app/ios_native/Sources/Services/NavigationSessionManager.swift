//
//  NavigationSessionManager.swift
//  Core navigation state machine, location tracking profiles, and GPS engine.
//
//  States: .idle -> .searching -> .routePreview -> .navigating -> .arrived
//
//  Key behaviours:
//  1. State-aware location tracking profiles (suspended, foregroundPassive, routePreview, activeNavigation)
//  2. Availability-gated background activity session (iOS 17+)
//  3. Pure transport-mode to CLActivityType mapping
//  4. Explicit location pipeline: rawLocation -> filteredLocation -> matchedLocation
//  5. Synchronous, deterministic location ingestion on @MainActor
//  6. Independent route indices: maneuverStepIndex vs polylineSegmentIndex
//  7. Authoritative RouteGeometry projection with continuity gating & heading tie-breaker
//  8. Along-route step advancement & conservative arrival logic
//  9. remainingPolyline trimmed by actual polylineSegmentIndex
//  10. Kalman filter smoothing to reduce GPS jitter
//  11. Runtime diagnostics metrics tracking
//

import CoreLocation
import Foundation

// MARK: - Navigation State

public enum NavigationState: Equatable, Sendable {
    case idle
    case searching
    case routePreview
    case navigating
    case arrived
}

// MARK: - NavigationProgress

public struct NavigationProgress: Sendable {
    public var maneuver: ManeuverType        = .none
    public var distanceToTurnMeters: UInt32  = 0
    public var remainingDistanceMeters: UInt32 = 0
    public var remainingEtaSeconds: UInt32   = 0
    public var currentSpeedKmh: UInt8        = 0
    public var speedLimitKmh: UInt8          = 0
    public var nextStreetName: String        = ""

    public init(maneuver: ManeuverType = .none, nextStreetName: String = "") {
        self.maneuver = maneuver
        self.nextStreetName = nextStreetName
    }

    public init(
        maneuver: ManeuverType,
        distanceToTurnMeters: UInt32,
        remainingDistanceMeters: UInt32,
        remainingEtaSeconds: UInt32,
        currentSpeedKmh: UInt8,
        speedLimitKmh: UInt8,
        nextStreetName: String
    ) {
        self.maneuver                = maneuver
        self.distanceToTurnMeters    = distanceToTurnMeters
        self.remainingDistanceMeters = remainingDistanceMeters
        self.remainingEtaSeconds     = remainingEtaSeconds
        self.currentSpeedKmh         = currentSpeedKmh
        self.speedLimitKmh           = speedLimitKmh
        self.nextStreetName          = nextStreetName
    }

    public var formattedRemainingDistance: String {
        if remainingDistanceMeters >= 1000 {
            return String(format: "%.1f km", Double(remainingDistanceMeters) / 1000.0)
        }
        return "\(remainingDistanceMeters) m"
    }

    public var formattedDistanceToTurn: String {
        if distanceToTurnMeters >= 1000 {
            return String(format: "%.1f km", Double(distanceToTurnMeters) / 1000.0)
        }
        return "\(distanceToTurnMeters) m"
    }

    public var formattedRemainingEta: String {
        let mins = Int(remainingEtaSeconds / 60)
        if mins >= 60 { return "\(mins / 60)h \(mins % 60)m" }
        return "\(mins) phut"
    }

    public var formattedEta: String { formattedRemainingEta }
}

// MARK: - NavigationSessionManager

@MainActor
public final class NavigationSessionManager: NSObject, ObservableObject {

    // MARK: - Explicit Location Pipeline
    /// Raw, unfiltered GPS location directly from CoreLocation (diagnostics/debug).
    @Published public var rawLocation: CLLocation?

    /// Raw GPS sample that passed horizontal accuracy validation, before Kalman smoothing (P5.2).
    /// Used for physical displacement, raw route distance, off-route evidence, and reroute origin.
    @Published public private(set) var acceptedPhysicalLocation: CLLocation?

    /// Kalman-filtered, accuracy-checked GPS location.
    @Published public var filteredLocation: CLLocation?

    /// Backward-compatible alias for views observing user position.
    @Published public var userLocation: CLLocation?

    /// Exact mathematically projected position snapped to route geometry.
    @Published public var matchedLocation: CLLocationCoordinate2D?

    /// Exact projection coordinate for MapLibre puck rendering.
    @Published public var snappedLocation: CLLocationCoordinate2D?

    /// Full projection metadata (distance along route, lateral distance, segment index).
    @Published public var currentProjection: RouteProjection?

    /// Device heading in degrees (0-359).
    @Published public var heading: Double = 0

    /// Authorization status for location services.
    @Published public private(set) var locationAuthStatus: CLAuthorizationStatus = .notDetermined

    // MARK: - Location Tracking Profile & Power
    @Published public private(set) var trackingProfile: LocationTrackingProfile = .foregroundPassive
    @Published public private(set) var currentTrackingConfig: LocationTrackingConfiguration

    // MARK: - Session Identity & Destination Lifecycle
    @Published public private(set) var sessionGeneration: UInt64 = 0
    @Published public private(set) var activeRouteGeneration: UInt64 = 0
    @Published public private(set) var navigationDestination: NavigationDestination?

    // MARK: - State Machine
    @Published public private(set) var state: NavigationState = .idle
    @Published public private(set) var activeRoute: NavRoute?
    @Published public private(set) var remainingPolyline: [CLLocationCoordinate2D] = []
    @Published public private(set) var activeProgress: NavigationProgress = NavigationProgress()

    /// Flag indicating background reroute computation is underway.
    @Published public private(set) var isRerouting: Bool = false

    // MARK: - Independent Route Indices & Authoritative Progress (P5.2)
    @Published public private(set) var currentManeuverStepIndex: Int = 0
    @Published public private(set) var currentPolylineSegmentIndex: Int = 0

    /// Monotonic along-route distance for UI presentation and continuous polyline trimming (P5.2).
    @Published public private(set) var displayProgressDistanceAlongRoute: Double = 0.0

    /// Authoritative upcoming maneuver step index representing the next upcoming action (P5.2 Requirement 31).
    public var upcomingManeuverIndex: Int {
        currentManeuverStepIndex
    }

    /// Matcher stuck status from rolling continuity tracking (P5.2 Requirement 12).
    @Published public private(set) var isMatcherStuck: Bool = false
    public private(set) var lastMatchConfidence: RouteMatchConfidence = .high

    // MARK: - Off-Route Detection (P2)
    @Published public private(set) var offRouteDecision: OffRouteDecision?
    @Published public private(set) var offRouteState: OffRouteState = .onRoute
    @Published public private(set) var isOffRoute: Bool = false
    let offRouteDetector = OffRouteDetector()

    // MARK: - Diagnostics (P5)
    public var diagnostics = NavigationDiagnostics()

    // MARK: - Callbacks
    public var onProgressUpdate: ((NavigationProgress) -> Void)?
    public var onOffRouteDecision: ((OffRouteDecision, CLLocation) -> Void)?
    public var onRerouteNeeded: (() -> Void)?
    public var onArrived: (() -> Void)?

    // MARK: Thresholds (P5.2)
    public let backwardToleranceMeters: Double     = 2.0
    public let maneuverPassToleranceMeters: Double = 2.0
    private let stepAdvanceThresholdMeters: Double = 15.0
    /// Conservative arrival: physical distance from destination must be ≤15m (P1 accepted value).
    private let arrivalThresholdMeters: Double     = 15.0
    /// Maximum accepted GPS horizontal accuracy; samples above this are rejected.
    private let maxAccuracyMeters: Double          = 20.0

    // Rolling stuck-matcher continuity tracker (P5.2 Requirements 12 & 13)
    private var rollingSamples: [(timestamp: Date, coord: CLLocationCoordinate2D, matchedDist: Double)] = []

    private func updateStuckMatcherStatus(
        timestamp: Date,
        coordinate: CLLocationCoordinate2D,
        matchedProgress: Double
    ) -> Bool {
        rollingSamples.append((timestamp: timestamp, coord: coordinate, matchedDist: matchedProgress))
        // Window of 3.5 seconds
        rollingSamples.removeAll { timestamp.timeIntervalSince($0.timestamp) > 3.5 }

        guard rollingSamples.count >= 3, let first = rollingSamples.first else {
            isMatcherStuck = false
            return false
        }

        var physicalTravel = 0.0
        for i in 0..<(rollingSamples.count - 1) {
            physicalTravel += RouteGeometry.distanceBetween(rollingSamples[i].coord, rollingSamples[i+1].coord)
        }

        let alongRouteAdvance = matchedProgress - first.matchedDist

        // If physically moved >= 25m but along-route progress is stuck (<= 6m)
        if physicalTravel >= 25.0 && alongRouteAdvance <= 6.0 {
            isMatcherStuck = true
            return true
        } else {
            isMatcherStuck = false
            return false
        }
    }

    // MARK: Private State
    private let locationManager = CLLocationManager()
    private var backgroundActivitySession: Any? = nil
    private var isForeground: Bool = true
    private var currentTransportMode: NavigationTransportMode = .motorcycle

    // Kalman filter
    private var kalmanLat: Double = 0
    private var kalmanLon: Double = 0
    private var kalmanAccuracy: Double = 1.0
    private var kalmanTimestamp: Date?
    private let kalmanQ: Double = 3.0 // process noise (m/s)

    // Route progress tracking state
    public private(set) var lastMatchedProjection: RouteProjection?
    public private(set) var lastMatchedTimestamp: Date?

    private let requestLocationAuthorizationOnInit: Bool

    // MARK: - Init

    public init(requestLocationAuthorizationOnInit: Bool = true) {
        self.requestLocationAuthorizationOnInit = requestLocationAuthorizationOnInit
        self.currentTrackingConfig = LocationTrackingPolicy.configuration(for: .foregroundPassive, transportMode: .motorcycle)
        super.init()
        setupLocationManager(requestAuthorization: requestLocationAuthorizationOnInit)
    }

    // MARK: - Setup

    private func setupLocationManager(requestAuthorization: Bool) {
        locationManager.delegate = self
        applyTrackingProfile(.foregroundPassive, transportMode: .motorcycle)

        if requestAuthorization && !ProcessInfo.isRunningUnitTests {
            requestLocationPermission()
        }
    }

    public func requestLocationPermission() {
        guard !ProcessInfo.isRunningUnitTests else { return }
        locationManager.requestWhenInUseAuthorization()
    }

    // MARK: - Tracking Profile & Power Policy (P5)

    public func applyTrackingProfile(
        _ profile: LocationTrackingProfile? = nil,
        transportMode: NavigationTransportMode? = nil
    ) {
        if let mode = transportMode {
            self.currentTransportMode = mode
        }
        let resolvedProfile = profile ?? LocationTrackingPolicy.resolveProfile(state: state, isForeground: isForeground)
        self.trackingProfile = resolvedProfile
        let config = LocationTrackingPolicy.configuration(for: resolvedProfile, transportMode: currentTransportMode)
        self.currentTrackingConfig = config

        guard requestLocationAuthorizationOnInit && !ProcessInfo.isRunningUnitTests else { return }

        locationManager.desiredAccuracy = config.desiredAccuracy
        locationManager.distanceFilter  = config.distanceFilter
        locationManager.activityType    = config.activityType
        locationManager.pausesLocationUpdatesAutomatically = config.pausesLocationUpdatesAutomatically

        if config.allowsBackgroundLocationUpdates {
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.showsBackgroundLocationIndicator = config.showsBackgroundLocationIndicator
        } else {
            locationManager.allowsBackgroundLocationUpdates = false
            locationManager.showsBackgroundLocationIndicator = false
        }

        updateBackgroundActivitySession(for: resolvedProfile)

        let isAuthorized = (locationAuthStatus == .authorizedWhenInUse || locationAuthStatus == .authorizedAlways)
        if isAuthorized {
            if resolvedProfile == .suspended {
                locationManager.stopUpdatingLocation()
                locationManager.stopUpdatingHeading()
            } else {
                locationManager.startUpdatingLocation()
                if config.headingEnabled {
                    locationManager.startUpdatingHeading()
                } else {
                    locationManager.stopUpdatingHeading()
                }
            }
        }
    }

    public func handleScenePhaseChange(isForeground: Bool) {
        self.isForeground = isForeground
        applyTrackingProfile()
    }

    public func updateTransportMode(_ mode: NavigationTransportMode) {
        self.currentTransportMode = mode
        applyTrackingProfile(transportMode: mode)
    }

    private func updateBackgroundActivitySession(for profile: LocationTrackingProfile) {
        #if canImport(CoreLocation)
        if #available(iOS 17.0, *) {
            if profile == .activeNavigation {
                if backgroundActivitySession == nil && requestLocationAuthorizationOnInit && !ProcessInfo.isRunningUnitTests {
                    backgroundActivitySession = CLBackgroundActivitySession()
                }
            } else {
                if let session = backgroundActivitySession as? CLBackgroundActivitySession {
                    session.invalidate()
                }
                backgroundActivitySession = nil
            }
        }
        #endif
    }

    // MARK: - Public API

    public func setSearching() {
        state = .searching
        applyTrackingProfile(isForeground ? .foregroundPassive : .suspended)
    }

    public func setIdle() {
        state = .idle
        applyTrackingProfile(isForeground ? .foregroundPassive : .suspended)
    }

    public func setRoutePreview(_ route: NavRoute) {
        // Guard: active navigation owns state; preview cannot interrupt it.
        guard state != .navigating else {
            print("[NavSession] setRoutePreview ignored: navigation is active")
            return
        }
        activeRoute       = route
        remainingPolyline = route.coordinates
        state             = .routePreview
        applyTrackingProfile(isForeground ? .routePreview : .suspended)
    }

    public func setRoutePreview(route: NavRoute) {
        setRoutePreview(route)
    }

    public func clearRoute() {
        // Guard: do not silently destroy an active navigation session through preview cleanup.
        guard state != .navigating else {
            print("[NavSession] clearRoute ignored: navigation is active — call stopNavigation() instead")
            return
        }
        activeRouteGeneration &+= 1
        activeRoute                 = nil
        activeProgress              = NavigationProgress()
        currentManeuverStepIndex    = 0
        currentPolylineSegmentIndex = 0
        displayProgressDistanceAlongRoute = 0.0
        lastMatchedProjection       = nil
        lastMatchedTimestamp        = nil
        currentProjection           = nil
        matchedLocation             = nil
        snappedLocation             = nil
        remainingPolyline           = []
        acceptedPhysicalLocation    = nil
        rollingSamples.removeAll()
        isMatcherStuck              = false
        offRouteDetector.reset()
        offRouteDecision            = nil
        offRouteState               = .onRoute
        isOffRoute                  = false
        if state == .routePreview || state == .arrived {
            state = .idle
            applyTrackingProfile(isForeground ? .foregroundPassive : .suspended)
        }
    }

    public func startNavigation(route: NavRoute, destination: NavigationDestination) {
        sessionGeneration &+= 1
        activeRouteGeneration &+= 1
        navigationDestination       = destination
        activeRoute                 = route
        currentManeuverStepIndex    = 0
        currentPolylineSegmentIndex = 0
        displayProgressDistanceAlongRoute = 0.0
        lastMatchedProjection       = nil
        lastMatchedTimestamp        = nil
        currentProjection           = nil
        isRerouting                 = false
        remainingPolyline           = route.coordinates
        rollingSamples.removeAll()
        isMatcherStuck              = false
        offRouteDetector.reset()
        offRouteDecision            = nil
        offRouteState               = .onRoute
        isOffRoute                  = false
        state                       = .navigating

        applyTrackingProfile(.activeNavigation)
        print("[NavSession] Navigation started to \(destination.name ?? "destination")")
    }

    public func stopNavigation() {
        sessionGeneration &+= 1
        activeRouteGeneration &+= 1
        navigationDestination       = nil
        isRerouting                 = false
        state                       = .idle
        activeRoute                 = nil
        activeProgress              = NavigationProgress()
        currentManeuverStepIndex    = 0
        currentPolylineSegmentIndex = 0
        displayProgressDistanceAlongRoute = 0.0
        lastMatchedProjection       = nil
        lastMatchedTimestamp        = nil
        currentProjection           = nil
        matchedLocation             = nil
        snappedLocation             = nil
        remainingPolyline           = []
        rollingSamples.removeAll()
        isMatcherStuck              = false
        offRouteDetector.reset()
        offRouteDecision            = nil
        offRouteState               = .onRoute
        isOffRoute                  = false

        applyTrackingProfile(isForeground ? .foregroundPassive : .suspended)
        print("[NavSession] Navigation stopped")
    }

    public func replaceActiveRoute(_ route: NavRoute) {
        guard state == .navigating else {
            print("[NavSession] Cannot replace route: not in navigating state")
            return
        }
        activeRouteGeneration &+= 1
        // Clear isRerouting atomically with the route commit
        isRerouting                 = false
        activeRoute                 = route
        currentManeuverStepIndex    = 0
        currentPolylineSegmentIndex = 0
        displayProgressDistanceAlongRoute = 0.0
        // Clear all stale Route A match state — nothing from the old route survives
        lastMatchedProjection       = nil
        lastMatchedTimestamp        = nil
        currentProjection           = nil
        matchedLocation             = nil
        snappedLocation             = nil
        remainingPolyline           = route.coordinates
        rollingSamples.removeAll()
        isMatcherStuck              = false
        offRouteDetector.reset()
        offRouteDecision            = nil
        offRouteState               = .onRoute
        isOffRoute                  = false
        diagnostics.rerouteCommits += 1
        print("[NavSession] Active route replaced (rev \(activeRouteGeneration), \(route.coordinates.count) pts)")

        // Immediately recompute position on Route B from current filtered location.
        // This makes reroute commit atomic: matched state is Route B from the moment
        // the call returns, without waiting for the next GPS callback.
        if let loc = filteredLocation ?? userLocation {
            var stepIdx = currentManeuverStepIndex
            var segIdx  = currentPolylineSegmentIndex
            let capturedGen = activeRouteGeneration

            let result = computeProgress(
                currentLocation: loc,
                acceptedPhysicalLocation: acceptedPhysicalLocation ?? loc,
                route: route,
                lastProjection: nil,
                lastMatchedTimestamp: nil,
                stuckRecoveryTriggered: false,
                displayProgressDistance: &displayProgressDistanceAlongRoute,
                maneuverStepIndex: &stepIdx,
                polylineSegmentIndex: &segIdx
            )

            // Only apply if route hasn't been replaced again during computation
            guard self.activeRouteGeneration == capturedGen else { return }

            self.currentManeuverStepIndex    = stepIdx
            self.currentPolylineSegmentIndex = segIdx
            self.lastMatchedProjection       = result.projection
            self.lastMatchedTimestamp        = loc.timestamp
            self.currentProjection           = result.projection
            self.matchedLocation             = result.projection.coordinate
            self.snappedLocation             = result.projection.coordinate
            if result.remaining.count >= 2 { self.remainingPolyline = result.remaining }
            self.activeProgress              = result.progress
            self.onProgressUpdate?(result.progress)
        }
    }

    public func setRerouting(_ rerouting: Bool) {
        isRerouting = rerouting
        if rerouting {
            diagnostics.rerouteRequests += 1
        }
    }

    public func setIsRerouting(_ value: Bool) {
        setRerouting(value)
    }

    // MARK: - Location Ingestion Pipeline (P5)

    /// Ingest a location sample into the navigation pipeline synchronously on @MainActor.
    public func ingestLocation(_ loc: CLLocation) {
        rawLocation = loc
        diagnostics.locationsReceived += 1

        guard loc.horizontalAccuracy > 0, loc.horizontalAccuracy <= maxAccuracyMeters else {
            diagnostics.locationsRejectedForAccuracy += 1
            #if DEBUG
            print("[NavSession] GPS discarded acc=\(Int(loc.horizontalAccuracy))m")
            #endif
            return
        }

        diagnostics.locationsAccepted += 1
        acceptedPhysicalLocation = loc

        // Adaptive Kalman smooth (Requirement 41 & 42)
        let sm = kalmanSmooth(
            rawLat: loc.coordinate.latitude,
            rawLon: loc.coordinate.longitude,
            accuracy: loc.horizontalAccuracy,
            timestamp: loc.timestamp,
            course: loc.course,
            speed: loc.speed
        )
        let smLoc = CLLocation(
            coordinate: sm,
            altitude: loc.altitude,
            horizontalAccuracy: loc.horizontalAccuracy,
            verticalAccuracy: loc.verticalAccuracy,
            course: loc.course,
            speed: loc.speed,
            timestamp: loc.timestamp
        )
        filteredLocation = smLoc
        userLocation     = smLoc

        guard state == .navigating, let route = activeRoute else { return }

        diagnostics.progressComputations += 1

        // Capture session & route revision at computation time
        let capturedSessionGeneration = sessionGeneration
        let capturedRouteGeneration = activeRouteGeneration

        var stepIdx = currentManeuverStepIndex
        var segIdx  = currentPolylineSegmentIndex
        let prevProj = lastMatchedProjection
        let prevTime = lastMatchedTimestamp

        // 1. Pure nearest projection from accepted physical location (Requirement 10 & 11)
        let rawNearestProj = route.geometry.nearestProjection(to: loc.coordinate)
        let rawNearestDist = rawNearestProj?.lateralDistanceMeters ?? 0.0

        // 2. Rolling stuck matcher tracker (Requirement 12)
        let currentProgress = displayProgressDistanceAlongRoute
        let stuckDetected = updateStuckMatcherStatus(
            timestamp: loc.timestamp,
            coordinate: loc.coordinate,
            matchedProgress: currentProgress
        )

        // 3. Compute progress with confidence matching & stuck recovery
        let result = computeProgress(
            currentLocation: smLoc,
            acceptedPhysicalLocation: loc,
            route: route,
            lastProjection: prevProj,
            lastMatchedTimestamp: prevTime,
            stuckRecoveryTriggered: stuckDetected,
            displayProgressDistance: &displayProgressDistanceAlongRoute,
            maneuverStepIndex: &stepIdx,
            polylineSegmentIndex: &segIdx
        )

        guard self.state == .navigating else { return }
        guard self.sessionGeneration == capturedSessionGeneration else {
            #if DEBUG
            print("[NavSession] Discarding stale GPS progress (session \(capturedSessionGeneration) != current \(self.sessionGeneration))")
            #endif
            return
        }
        guard self.activeRouteGeneration == capturedRouteGeneration else {
            #if DEBUG
            print("[NavSession] Discarding stale GPS progress (route rev \(capturedRouteGeneration) != current \(self.activeRouteGeneration))")
            #endif
            return
        }

        self.currentManeuverStepIndex    = stepIdx
        self.currentPolylineSegmentIndex = segIdx
        self.lastMatchedProjection       = result.projection
        self.lastMatchedTimestamp        = smLoc.timestamp
        self.currentProjection           = result.projection
        self.lastMatchConfidence         = result.matchConfidence
        self.matchedLocation             = result.projection.coordinate
        self.snappedLocation             = result.projection.coordinate
        if result.remaining.count >= 2 { self.remainingPolyline = result.remaining }

        // 4. Multi-Signal Quality-Aware Off-Route Detection (Requirements 21, 22, 23)
        let currentSegIdx = result.projection.segmentIndex
        var routeBearing: Double? = nil
        if currentSegIdx + 1 < route.coordinates.count {
            routeBearing = RouteGeometry.bearing(from: route.coordinates[currentSegIdx], to: route.coordinates[currentSegIdx + 1])
        }

        let obs = OffRouteObservation(
            timestamp: loc.timestamp,
            lateralDistanceMeters: result.projection.lateralDistanceMeters,
            horizontalAccuracyMeters: loc.horizontalAccuracy,
            speedMetersPerSecond: max(0.0, loc.speed),
            courseDegrees: loc.course >= 0.0 ? loc.course : nil,
            routeBearingDegrees: routeBearing,
            distanceAlongRouteMeters: self.displayProgressDistanceAlongRoute,
            rawNearestRouteDistanceMeters: rawNearestDist,
            isMatcherStuck: stuckDetected
        )
        self.diagnostics.offRouteObservations += 1

        let decision = self.offRouteDetector.evaluate(observation: obs)
        self.offRouteDecision = decision
        self.offRouteState = decision.state
        self.isOffRoute = (decision.state == .confirmed)

        // Latency metric timestamps (Requirement 50)
        if decision.state == .suspected && self.diagnostics.offRouteSuspectedAt == nil {
            self.diagnostics.offRouteSuspectedAt = loc.timestamp
        } else if decision.recovered {
            self.diagnostics.offRouteSuspectedAt = nil
            self.diagnostics.offRouteConfirmedAt = nil
        }

        if decision.becameConfirmed {
            self.diagnostics.offRouteConfirmations += 1
            self.diagnostics.offRouteConfirmedAt = loc.timestamp
            #if DEBUG
            print("[NavSession] OFF-ROUTE confirmed (reason=\(decision.reason.rawValue), lateral=\(Int(decision.lateralDistanceMeters))m)")
            #endif
        }

        // Trace snapshot logging (Requirement 37)
        self.diagnostics.latestFieldTrace = FieldNavigationTraceSnapshot(
            timestamp: loc.timestamp,
            horizontalAccuracy: loc.horizontalAccuracy,
            speed: loc.speed,
            course: loc.course,
            rawNearestRouteDistance: rawNearestDist,
            matchedSegmentIndex: result.projection.segmentIndex,
            matchedAlongRouteMeters: result.projection.distanceAlongRouteMeters,
            previousMatchedMeters: prevProj?.distanceAlongRouteMeters ?? 0.0,
            physicalDisplacement: prevProj != nil ? RouteGeometry.distanceBetween(prevProj!.coordinate, loc.coordinate) : 0.0,
            alongRouteAdvancement: prevProj != nil ? (result.projection.distanceAlongRouteMeters - prevProj!.distanceAlongRouteMeters) : 0.0,
            matchConfidence: result.matchConfidence.rawValue,
            currentUpcomingManeuverIndex: stepIdx,
            distanceToUpcomingManeuver: Double(result.progress.distanceToTurnMeters),
            offRouteState: decision.state.rawValue,
            offRouteReason: decision.reason.rawValue,
            rerouteState: self.isRerouting ? "REROUTING" : "IDLE"
        )

        // Pass acceptedPhysicalLocation as reroute origin (Requirement 26)
        self.onOffRouteDecision?(decision, loc)

        if result.progress.maneuver == .arrive && self.state == .navigating {
            self.state = .arrived
            // Downgrade power profile immediately on arrival — do not wait for user tap
            applyTrackingProfile(isForeground ? .foregroundPassive : .suspended)
            self.onArrived?()
        }

        self.activeProgress = result.progress
        self.onProgressUpdate?(result.progress)
    }

    // MARK: - Kalman Smoothing (Adaptive Turn Responsiveness P5.2)

    private func kalmanSmooth(
        rawLat: Double,
        rawLon: Double,
        accuracy: Double,
        timestamp: Date,
        course: Double = -1.0,
        speed: Double = 0.0
    ) -> CLLocationCoordinate2D {
        guard let last = kalmanTimestamp else {
            kalmanLat = rawLat; kalmanLon = rawLon
            kalmanAccuracy = accuracy; kalmanTimestamp = timestamp
            return CLLocationCoordinate2D(latitude: rawLat, longitude: rawLon)
        }
        let dt = max(timestamp.timeIntervalSince(last), 0.0)
        kalmanTimestamp = timestamp

        // Adaptive process noise (Requirements 41 & 42):
        // If moving at meaningful speed and physical displacement is large (> 15m),
        // or accuracy is high (<= 10m), increase responsiveness to prevent turn lag.
        let rawCoord = CLLocationCoordinate2D(latitude: rawLat, longitude: rawLon)
        let lastSmCoord = CLLocationCoordinate2D(latitude: kalmanLat, longitude: kalmanLon)
        let displacement = RouteGeometry.distanceBetween(lastSmCoord, rawCoord)

        var effectiveQ = kalmanQ
        if speed >= 2.5 && displacement > 15.0 {
            effectiveQ = 12.0
            if displacement > 25.0 && accuracy <= 10.0 {
                // Reseed directly on major sharp turn with high accuracy to eliminate positional lag
                kalmanLat = rawLat
                kalmanLon = rawLon
                kalmanAccuracy = accuracy
                return rawCoord
            }
        }

        let variance = kalmanAccuracy * kalmanAccuracy + dt * effectiveQ * effectiveQ
        let r = accuracy * accuracy
        let k = variance / (variance + r)

        kalmanLat += k * (rawLat - kalmanLat)
        kalmanLon += k * (rawLon - kalmanLon)
        kalmanAccuracy = sqrt((1.0 - k) * variance)

        return CLLocationCoordinate2D(latitude: kalmanLat, longitude: kalmanLon)
    }

    // MARK: - Progress Computation (P5.2)

    nonisolated private func computeProgress(
        currentLocation: CLLocation,
        acceptedPhysicalLocation: CLLocation,
        route: NavRoute,
        lastProjection: RouteProjection?,
        lastMatchedTimestamp: Date?,
        stuckRecoveryTriggered: Bool,
        displayProgressDistance: inout Double,
        maneuverStepIndex: inout Int,
        polylineSegmentIndex: inout Int
    ) -> (progress: NavigationProgress,
          projection: RouteProjection,
          remaining: [CLLocationCoordinate2D],
          matchConfidence: RouteMatchConfidence) {

        guard !route.steps.isEmpty, !route.coordinates.isEmpty else {
            let fallbackProj = RouteProjection(
                coordinate: currentLocation.coordinate,
                segmentIndex: 0,
                segmentFraction: 0,
                lateralDistanceMeters: 0,
                distanceAlongRouteMeters: 0
            )
            return (NavigationProgress(maneuver: .arrive, nextStreetName: "Đã đến đích"),
                    fallbackProj, [], .high)
        }

        let coords = route.coordinates

        // Authoritative Route Matching with confidence scoring & stuck recovery
        let matchResult = route.geometry.matchLocation(
            location: currentLocation,
            lastProjection: lastProjection,
            lastMatchedTimestamp: lastMatchedTimestamp,
            stuckRecoveryTriggered: stuckRecoveryTriggered
        )

        let projection: RouteProjection
        let confidence: RouteMatchConfidence

        if let mr = matchResult {
            projection = mr.projection
            confidence = mr.confidence
        } else {
            let fallbackCoord = route.coordinates.first ?? currentLocation.coordinate
            let fallbackProj = RouteProjection(
                coordinate: fallbackCoord,
                segmentIndex: 0,
                segmentFraction: 0,
                lateralDistanceMeters: 0,
                distanceAlongRouteMeters: 0
            )
            return (NavigationProgress(maneuver: .none), fallbackProj, coords, .low)
        }

        // Maintain polylineSegmentIndex strictly from geometry projection
        polylineSegmentIndex = projection.segmentIndex

        // Monotonic forward display progress (Requirement 15 & 16)
        let rawMatchedProgress = projection.distanceAlongRouteMeters
        displayProgressDistance = max(displayProgressDistance - 2.0, rawMatchedProgress)

        // Conservative arrival check:
        // Requires physical proximity (<= arrivalThresholdMeters 15m) AND remaining along-route distance (<= 30m),
        // or very close physical proximity (<= 7.5m) in case polyline end has slight coordinate offset.
        let destCoord = coords.last!
        let destLocation = CLLocation(latitude: destCoord.latitude, longitude: destCoord.longitude)
        let physicalDistToDest = acceptedPhysicalLocation.distance(from: destLocation)
        let remDist = route.geometry.remainingDistance(from: displayProgressDistance)

        let isPhysicallyNear = physicalDistToDest <= arrivalThresholdMeters
        let isRouteProgressNear = remDist <= 30.0
        if (isPhysicallyNear && isRouteProgressNear) || physicalDistToDest <= 7.5 {
            displayProgressDistance = route.geometry.totalDistanceMeters
            let arrivalProj = RouteProjection(
                coordinate: destCoord,
                segmentIndex: max(0, coords.count - 2),
                segmentFraction: 1.0,
                lateralDistanceMeters: physicalDistToDest,
                distanceAlongRouteMeters: route.geometry.totalDistanceMeters
            )
            return (NavigationProgress(maneuver: .arrive,
                                       distanceToTurnMeters: 0,
                                       remainingDistanceMeters: 0,
                                       remainingEtaSeconds: 0,
                                       currentSpeedKmh: 0,
                                       speedLimitKmh: 0,
                                       nextStreetName: "Đã đến đích"),
                    arrivalProj, [], .high)
        }

        // Handle initial depart maneuver (Requirement 32)
        if maneuverStepIndex == 0 && route.steps.count > 1 {
            let step0Begin = route.geometry.maneuverBeginDistancesAlongRoute[0]
            if displayProgressDistance >= (step0Begin + 2.0) || displayProgressDistance >= 10.0 {
                maneuverStepIndex = 1
            }
        }

        // Maneuver step advancement based on along-route progress (Requirements 33, 34, 47)
        let beginDistances = route.geometry.maneuverBeginDistancesAlongRoute
        while maneuverStepIndex + 1 < route.steps.count {
            let upcomingTriggerDist = beginDistances[maneuverStepIndex]
            if displayProgressDistance >= (upcomingTriggerDist + 2.0) {
                maneuverStepIndex += 1
                #if DEBUG
                let nextStep = route.steps[maneuverStepIndex]
                print("[NavSession] -> Passed step, advanced to Step \(maneuverStepIndex): \(nextStep.maneuverType.localizedInstruction)")
                #endif
            } else {
                break
            }
        }

        let curStep = route.steps[min(maneuverStepIndex, route.steps.count - 1)]

        // Distance to turn along route (Requirement 31: upcomingManeuver.beginDistance - displayProgress)
        let distToTurn: Double
        if curStep.maneuverType == .arrive || maneuverStepIndex >= route.steps.count - 1 {
            distToTurn = remDist
        } else {
            distToTurn = route.geometry.distanceToManeuverBegin(
                stepIndex: maneuverStepIndex,
                from: displayProgressDistance
            )
        }

        // Authoritative continuous polyline trimming (Requirements 17 & 18)
        let remaining = route.geometry.trimmedPolyline(
            from: displayProgressDistance,
            snappedCoordinate: projection.coordinate
        )

        // Stable proportional ETA
        let totalGeomDist = route.geometry.totalDistanceMeters
        let remainingRatio = totalGeomDist > 0 ? max(0.0, min(1.0, remDist / totalGeomDist)) : 0.0
        let remSec = UInt32(round(route.totalDurationSeconds * remainingRatio))
        let kmh = UInt8(min(255, max(0, currentLocation.speed * 3.6)))

        let activeManeuver = (curStep.maneuverType == .arrive) ? .straight : curStep.maneuverType
        let progress = NavigationProgress(
            maneuver: activeManeuver,
            distanceToTurnMeters: UInt32(max(0, round(distToTurn))),
            remainingDistanceMeters: UInt32(max(0, round(remDist))),
            remainingEtaSeconds: remSec,
            currentSpeedKmh: kmh,
            speedLimitKmh: 0,
            nextStreetName: curStep.streetName
        )

        return (progress, projection, remaining, confidence)
    }
}

// MARK: - CLLocationManagerDelegate

extension NavigationSessionManager: @preconcurrency CLLocationManagerDelegate {

    public func locationManager(_ manager: CLLocationManager,
                                didChangeAuthorization status: CLAuthorizationStatus) {
        locationAuthStatus = status
        applyTrackingProfile()
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        locationAuthStatus = status
        applyTrackingProfile()
    }

    public func locationManager(_ manager: CLLocationManager,
                                didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        ingestLocation(loc)
    }

    public func locationManager(_ manager: CLLocationManager,
                                didUpdateHeading newHeading: CLHeading) {
        if newHeading.headingAccuracy >= 0 { heading = newHeading.trueHeading }
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[NavSession] CLLocationManager error: \(error.localizedDescription)")
    }
    // MARK: - Test Support (Internal)

    internal func applyOffRouteDecisionForTesting(_ decision: OffRouteDecision, location: CLLocation) {
        self.offRouteDecision = decision
        self.offRouteState = decision.state
        self.isOffRoute = (decision.state == .confirmed)
        if decision.becameConfirmed {
            self.diagnostics.offRouteConfirmations += 1
            self.diagnostics.offRouteConfirmedAt = location.timestamp
        }
        self.onOffRouteDecision?(decision, location)
    }
}
