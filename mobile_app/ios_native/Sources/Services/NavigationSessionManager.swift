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

    public var formattedEta: String {
        let mins = remainingEtaSeconds / 60
        if mins >= 60 {
            let hours = mins / 60
            let remainMins = mins % 60
            return "\(hours) giờ \(remainMins) phút"
        }
        return "\(mins) phút"
    }
}

// MARK: - NavigationSessionManager

@MainActor
public final class NavigationSessionManager: NSObject, ObservableObject {

    // MARK: - Explicit Location Pipeline
    /// Raw, unfiltered GPS location directly from CoreLocation (diagnostics/debug).
    @Published public private(set) var rawLocation: CLLocation?

    /// Kalman-filtered, accuracy-checked GPS location.
    @Published public private(set) var filteredLocation: CLLocation?

    /// Backward-compatible alias for views observing user position.
    @Published public private(set) var userLocation: CLLocation?

    /// Exact mathematically projected position snapped to route geometry.
    @Published public private(set) var matchedLocation: CLLocationCoordinate2D?

    /// Exact projection coordinate for MapLibre puck rendering.
    @Published public private(set) var snappedLocation: CLLocationCoordinate2D?

    /// Full projection metadata (distance along route, lateral distance, segment index).
    @Published public private(set) var currentProjection: RouteProjection?

    /// Device heading in degrees (0-359).
    @Published public private(set) var heading: CLLocationDirection?

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

    // MARK: - Independent Route Indices
    @Published public private(set) var currentManeuverStepIndex: Int = 0
    @Published public private(set) var currentPolylineSegmentIndex: Int = 0

    // MARK: - Off-Route Detection (P2)
    @Published public private(set) var offRouteDecision: OffRouteDecision?
    @Published public private(set) var offRouteState: OffRouteState = .onRoute
    @Published public private(set) var isOffRoute: Bool = false
    private let offRouteDetector = OffRouteDetector()

    // MARK: - Diagnostics (P5)
    public var diagnostics = NavigationDiagnostics()

    // MARK: - Callbacks
    public var onProgressUpdate: ((NavigationProgress) -> Void)?
    public var onOffRouteDecision: ((OffRouteDecision, CLLocation) -> Void)?
    public var onRerouteNeeded: (() -> Void)?
    public var onArrived: (() -> Void)?

    // MARK: Thresholds
    private let stepAdvanceThresholdMeters: Double = 15.0
    private let arrivalRadiusMeters: Double        = 25.0
    private let maxAccuracyMeters: Double          = 50.0

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
    private var lastMatchedProjection: RouteProjection?
    private var lastMatchedTimestamp: Date?

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

        guard requestLocationAuthorizationOnInit else { return }

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

    public func setRoutePreview(route: NavRoute) {
        activeRoute       = route
        remainingPolyline = route.coordinates
        state             = .routePreview
        applyTrackingProfile(isForeground ? .routePreview : .suspended)
    }

    public func clearRoute() {
        activeRoute                 = nil
        activeProgress              = NavigationProgress()
        currentManeuverStepIndex    = 0
        currentPolylineSegmentIndex = 0
        lastMatchedProjection       = nil
        lastMatchedTimestamp        = nil
        currentProjection           = nil
        matchedLocation             = nil
        snappedLocation             = nil
        remainingPolyline           = []
        offRouteDetector.reset()
        offRouteDecision            = nil
        offRouteState               = .onRoute
        isOffRoute                  = false
        if state == .routePreview {
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
        lastMatchedProjection       = nil
        lastMatchedTimestamp        = nil
        currentProjection           = nil
        isRerouting                 = false
        remainingPolyline           = route.coordinates
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
        lastMatchedProjection       = nil
        lastMatchedTimestamp        = nil
        currentProjection           = nil
        matchedLocation             = nil
        snappedLocation             = nil
        remainingPolyline           = []
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
        activeRoute                 = route
        currentManeuverStepIndex    = 0
        currentPolylineSegmentIndex = 0
        lastMatchedProjection       = nil
        lastMatchedTimestamp        = nil
        currentProjection           = nil
        remainingPolyline           = route.coordinates
        offRouteDetector.reset()
        offRouteDecision            = nil
        offRouteState               = .onRoute
        isOffRoute                  = false
        diagnostics.rerouteCommits += 1
        print("[NavSession] Active route replaced (rev \(activeRouteGeneration), \(route.coordinates.count) pts)")
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
            print("[NavSession] GPS discarded acc=\(Int(loc.horizontalAccuracy))m")
            return
        }

        diagnostics.locationsAccepted += 1

        // Kalman smooth
        let sm = kalmanSmooth(
            rawLat: loc.coordinate.latitude,
            rawLon: loc.coordinate.longitude,
            accuracy: loc.horizontalAccuracy,
            timestamp: loc.timestamp
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

        let result = computeProgress(
            currentLocation: smLoc,
            route: route,
            lastProjection: prevProj,
            lastMatchedTimestamp: prevTime,
            maneuverStepIndex: &stepIdx,
            polylineSegmentIndex: &segIdx
        )

        guard self.state == .navigating else { return }
        guard self.sessionGeneration == capturedSessionGeneration else {
            print("[NavSession] Discarding stale GPS progress (session \(capturedSessionGeneration) != current \(self.sessionGeneration))")
            return
        }
        guard self.activeRouteGeneration == capturedRouteGeneration else {
            print("[NavSession] Discarding stale GPS progress (route rev \(capturedRouteGeneration) != current \(self.activeRouteGeneration))")
            return
        }

        self.currentManeuverStepIndex    = stepIdx
        self.currentPolylineSegmentIndex = segIdx
        self.lastMatchedProjection       = result.projection
        self.lastMatchedTimestamp        = smLoc.timestamp
        self.currentProjection           = result.projection
        self.matchedLocation             = result.projection.coordinate
        self.snappedLocation             = result.projection.coordinate
        if result.remaining.count >= 2 { self.remainingPolyline = result.remaining }

        // P2 Quality-Aware Off-Route Detection
        let currentSegIdx = result.projection.segmentIndex
        var routeBearing: Double? = nil
        if currentSegIdx + 1 < route.coordinates.count {
            routeBearing = RouteGeometry.bearing(from: route.coordinates[currentSegIdx], to: route.coordinates[currentSegIdx + 1])
        }

        let obs = OffRouteObservation(
            timestamp: smLoc.timestamp,
            lateralDistanceMeters: result.projection.lateralDistanceMeters,
            horizontalAccuracyMeters: smLoc.horizontalAccuracy,
            speedMetersPerSecond: max(0.0, smLoc.speed),
            courseDegrees: smLoc.course >= 0.0 ? smLoc.course : nil,
            routeBearingDegrees: routeBearing,
            distanceAlongRouteMeters: result.projection.distanceAlongRouteMeters
        )
        self.diagnostics.offRouteObservations += 1

        let decision = self.offRouteDetector.evaluate(observation: obs)
        self.offRouteDecision = decision
        self.offRouteState = decision.state
        self.isOffRoute = (decision.state == .confirmed)

        if decision.becameConfirmed {
            self.diagnostics.offRouteConfirmations += 1
            print("[NavSession] OFF-ROUTE confirmed (reason=\(decision.reason.rawValue), lateral=\(Int(decision.lateralDistanceMeters))m)")
        }

        self.onOffRouteDecision?(decision, smLoc)

        if result.progress.maneuver == .arrive && self.state == .navigating {
            self.state = .arrived
            self.onArrived?()
        }

        self.activeProgress = result.progress
        self.onProgressUpdate?(result.progress)
    }

    // MARK: - Kalman Smoothing

    private func kalmanSmooth(
        rawLat: Double,
        rawLon: Double,
        accuracy: Double,
        timestamp: Date
    ) -> CLLocationCoordinate2D {
        guard let last = kalmanTimestamp else {
            kalmanLat = rawLat; kalmanLon = rawLon
            kalmanAccuracy = accuracy; kalmanTimestamp = timestamp
            return CLLocationCoordinate2D(latitude: rawLat, longitude: rawLon)
        }
        let dt = max(timestamp.timeIntervalSince(last), 0.0)
        kalmanTimestamp = timestamp

        let variance = kalmanAccuracy * kalmanAccuracy + dt * kalmanQ * kalmanQ
        let r = accuracy * accuracy
        let k = variance / (variance + r)

        kalmanLat += k * (rawLat - kalmanLat)
        kalmanLon += k * (rawLon - kalmanLon)
        kalmanAccuracy = sqrt((1.0 - k) * variance)

        return CLLocationCoordinate2D(latitude: kalmanLat, longitude: kalmanLon)
    }

    // MARK: - Progress Computation

    private struct ProgressComputationResult {
        let projection: RouteProjection
        let progress: NavigationProgress
        let remaining: [CLLocationCoordinate2D]
    }

    private func computeProgress(
        currentLocation: CLLocation,
        route: NavRoute,
        lastProjection: RouteProjection?,
        lastMatchedTimestamp: Date?,
        maneuverStepIndex: inout Int,
        polylineSegmentIndex: inout Int
    ) -> ProgressComputationResult {
        let coords = route.coordinates
        guard coords.count >= 2 else {
            return ProgressComputationResult(
                projection: RouteProjection(
                    coordinate: currentLocation.coordinate,
                    segmentIndex: 0,
                    fractionAlongSegment: 0.0,
                    distanceAlongRouteMeters: 0.0,
                    lateralDistanceMeters: 0.0
                ),
                progress: NavigationProgress(),
                remaining: coords
            )
        }

        let timeDelta = lastMatchedTimestamp.map { currentLocation.timestamp.timeIntervalSince($0) }
        let currentSpeed = max(0.0, currentLocation.speed)

        let projection = route.geometry.project(
            coordinate: currentLocation.coordinate,
            heading: currentLocation.course >= 0 ? currentLocation.course : nil,
            previousProjection: lastProjection,
            speedMetersPerSecond: currentSpeed,
            timeDeltaSeconds: timeDelta
        )

        polylineSegmentIndex = max(polylineSegmentIndex, projection.segmentIndex)

        let totalDist = route.totalDistanceMeters
        let remainingDist = max(0.0, totalDist - projection.distanceAlongRouteMeters)

        let speedMps = currentSpeed > 0 ? currentSpeed : 8.33
        let remainingEta = remainingDist / speedMps

        let destCoord = coords.last ?? currentLocation.coordinate
        let physicalDistToDest = currentLocation.distance(from: CLLocation(latitude: destCoord.latitude, longitude: destCoord.longitude))

        let isArrived = (physicalDistToDest <= arrivalRadiusMeters) &&
                        (remainingDist <= arrivalRadiusMeters * 1.5 || projection.distanceAlongRouteMeters >= totalDist * 0.95)

        if isArrived {
            let p = NavigationProgress(
                maneuver: .arrive,
                distanceToTurnMeters: 0,
                remainingDistanceMeters: 0,
                remainingEtaSeconds: 0,
                currentSpeedKmh: UInt8(clamping: Int(currentLocation.speed * 3.6)),
                speedLimitKmh: 0,
                nextStreetName: "Đã đến điểm đích"
            )
            return ProgressComputationResult(
                projection: projection,
                progress: p,
                remaining: []
            )
        }

        let steps = route.steps
        if !steps.isEmpty {
            while maneuverStepIndex < steps.count - 1 {
                let nextStep = steps[maneuverStepIndex + 1]
                let distToNextManeuver = currentLocation.distance(from: CLLocation(latitude: nextStep.coordinate.latitude, longitude: nextStep.coordinate.longitude))

                var passedShapeThreshold = false
                if let nextBeginIdx = nextStep.beginShapeIndex {
                    passedShapeThreshold = (projection.segmentIndex >= nextBeginIdx)
                }

                if distToNextManeuver < stepAdvanceThresholdMeters || passedShapeThreshold {
                    maneuverStepIndex += 1
                } else {
                    break
                }
            }
        }

        let currentStep: NavStep? = maneuverStepIndex < steps.count ? steps[maneuverStepIndex] : nil
        let nextStep: NavStep? = (maneuverStepIndex + 1) < steps.count ? steps[maneuverStepIndex + 1] : nil

        let distToTurn: Double
        if let target = (nextStep ?? currentStep) {
            distToTurn = currentLocation.distance(from: CLLocation(latitude: target.coordinate.latitude, longitude: target.coordinate.longitude))
        } else {
            distToTurn = remainingDist
        }

        let activeManeuver = nextStep?.maneuverType ?? currentStep?.maneuverType ?? .none
        let nextStreet = nextStep?.streetName ?? currentStep?.streetName ?? ""

        let progress = NavigationProgress(
            maneuver: activeManeuver,
            distanceToTurnMeters: UInt32(clamping: Int(distToTurn)),
            remainingDistanceMeters: UInt32(clamping: Int(remainingDist)),
            remainingEtaSeconds: UInt32(clamping: Int(remainingEta)),
            currentSpeedKmh: UInt8(clamping: Int(max(0.0, currentLocation.speed) * 3.6)),
            speedLimitKmh: 0,
            nextStreetName: nextStreet
        )

        let remainingCoords = RouteGeometry.remainingPolyline(from: coords, currentSegmentIndex: polylineSegmentIndex)

        return ProgressComputationResult(
            projection: projection,
            progress: progress,
            remaining: remainingCoords
        )
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
}
