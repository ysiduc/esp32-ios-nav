//
//  NavigationSessionManager.swift
//  Core navigation state machine and GPS engine.
//
//  States: .idle -> .searching -> .routePreview -> .navigating -> .arrived
//
//  Key behaviours:
//  1. High-accuracy GPS (kCLLocationAccuracyBestForNavigation)
//  2. Background location (iOS 17+)
//  3. Explicit location pipeline: rawLocation -> filteredLocation -> matchedLocation
//  4. Independent route indices: maneuverStepIndex vs polylineSegmentIndex
//  5. Authoritative RouteGeometry projection with continuity gating & heading tie-breaker
//  6. Along-route step advancement & conservative arrival logic
//  7. remainingPolyline trimmed by actual polylineSegmentIndex
//  8. Kalman filter smoothing to reduce GPS jitter
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

    public var formattedDistanceToTurn: String {
        distanceToTurnMeters >= 1000
            ? String(format: "%.1f km", Double(distanceToTurnMeters) / 1000)
            : "\(distanceToTurnMeters) m"
    }

    public var formattedRemainingDistance: String {
        remainingDistanceMeters >= 1000
            ? String(format: "%.1f km", Double(remainingDistanceMeters) / 1000)
            : "\(remainingDistanceMeters) m"
    }

    public var formattedRemainingEta: String {
        let mins = Int(remainingEtaSeconds / 60)
        if mins >= 60 { return "\(mins / 60)h \(mins % 60)m" }
        return "\(mins) phut"
    }
}

// MARK: - NavigationSessionManager

@MainActor
public final class NavigationSessionManager: NSObject, ObservableObject {

    // MARK: - Explicit Location Pipeline
    /// Raw, unfiltered GPS location directly from CoreLocation (diagnostics/debug).
    @Published public var rawLocation: CLLocation?
    /// Filtered (Kalman-smoothed) physical GPS location (used for search bias and route matching).
    @Published public var filteredLocation: CLLocation?
    /// Authoritative matched coordinate along route polyline (used for navigation puck).
    @Published public var matchedLocation: CLLocationCoordinate2D?
    /// Authoritative projection metadata along route polyline.
    @Published public var currentProjection: RouteProjection?

    // Backwards-compatible aliases
    @Published public var userLocation: CLLocation?
    @Published public var snappedLocation: CLLocationCoordinate2D?

    @Published public var state: NavigationState            = .idle
    @Published public var activeRoute: NavRoute?
    @Published public var activeProgress: NavigationProgress = NavigationProgress()
    @Published public var locationAuthStatus: CLAuthorizationStatus = .notDetermined
    @Published public var heading: Double = 0
    /// Remaining (undriven) polyline — trimmed from snapped position to destination.
    @Published public var remainingPolyline: [CLLocationCoordinate2D] = []

    // MARK: - Session Identity & Destination Lifecycle
    /// Monotonically increasing session generation. Incremented on start and stop.
    public private(set) var sessionGeneration: UInt64 = 0
    /// Monotonically increasing active route revision. Increments on route start, route replace, and stop.
    public private(set) var activeRouteGeneration: UInt64 = 0
    /// Active navigation destination frozen at start of navigation session.
    public private(set) var navigationDestination: NavigationDestination?
    /// Flag indicating background reroute computation is underway.
    @Published public private(set) var isRerouting: Bool = false

    // MARK: - Independent Route Indices
    /// Index into route.steps (maneuver step progress).
    public private(set) var currentManeuverStepIndex: Int = 0
    /// Backwards compatible alias for step index.
    public var currentStepIndex: Int { currentManeuverStepIndex }

    /// Index into route.coordinates / linear segments.
    public private(set) var currentPolylineSegmentIndex: Int = 0

    /// Last matched projection used for continuity gating.
    public private(set) var lastMatchedProjection: RouteProjection?

    /// Timestamp of last accepted matched projection for temporal continuity gating.
    public private(set) var lastMatchedTimestamp: Date?

    // MARK: Callbacks
    public var onProgressUpdate: ((NavigationProgress) -> Void)?
    public var onRerouteNeeded: (() -> Void)?
    public var onArrived: (() -> Void)?

    // MARK: Thresholds
    private let stepAdvanceThresholdMeters: Double = 15.0
    private let offRouteThresholdMeters: Double    = 15.0
    private let offRouteConsecutiveRequired: Int   = 2
    private let maxAccuracyMeters: Double          = 20.0
    private let arrivalThresholdMeters: Double     = 15.0

    // MARK: Private State
    private let locationManager = CLLocationManager()
    private var offRouteConsecutiveCount: Int = 0
    private var isOffRoute: Bool = false
    private var backgroundSession: Any? = nil

    // Kalman filter
    private var kalmanLat: Double = 0
    private var kalmanLon: Double = 0
    private var kalmanAccuracy: Double = 1.0
    private var kalmanTimestamp: Date?
    private let kalmanQ: Double = 3.0 // m/s process noise

    override public init() {
        super.init()
        setupLocationManager()
    }

    // MARK: - Setup

    private func setupLocationManager() {
        locationManager.delegate        = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter  = kCLDistanceFilterNone
        locationManager.headingFilter   = 2.0
        locationManager.activityType    = .automotiveNavigation
        locationManager.pausesLocationUpdatesAutomatically = false

        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
                        NSClassFromString("XCTestCase") != nil
        if !isTesting {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    // MARK: - Public API

    public func requestAlwaysAuthorization() {
        locationManager.requestAlwaysAuthorization()
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
        matchedLocation             = nil
        snappedLocation             = nil
        offRouteConsecutiveCount    = 0
        isOffRoute                  = false
        isRerouting                 = false
        remainingPolyline           = route.coordinates
        kalmanTimestamp             = nil
        state                       = .navigating
        enableBackgroundLocation()
        print("[NavSession] Navigation started (session \(sessionGeneration), route rev \(activeRouteGeneration)) — \(route.steps.count) steps to \(destination.name ?? "destination")")
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
        offRouteConsecutiveCount    = 0
        isOffRoute                  = false
        remainingPolyline           = []
        disableBackgroundLocation()
        print("[NavSession] Navigation stopped (session invalidated to \(sessionGeneration), route rev \(activeRouteGeneration))")
    }

    public func setRoutePreview(_ route: NavRoute) {
        guard state != .navigating else {
            print("[NavSession] setRoutePreview rejected: active navigation in progress")
            return
        }
        activeRoute       = route
        remainingPolyline = route.coordinates
        state             = .routePreview
    }

    /// Replaces active route during an active navigation session (reroute commit).
    /// Maintains session identity and destination while atomically replacing path and resetting step/segment progress.
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
        matchedLocation             = nil
        snappedLocation             = nil
        offRouteConsecutiveCount    = 0
        isOffRoute                  = false
        isRerouting                 = false
        remainingPolyline           = route.coordinates

        // Recompute progress immediately on the new route if filtered location is available
        if let loc = filteredLocation ?? userLocation {
            var stepIdx = 0
            var segIdx  = 0
            var offCnt  = 0
            var offFlag = false
            let result = computeProgress(
                currentLocation: loc,
                route: route,
                lastProjection: nil,
                lastMatchedTimestamp: nil,
                maneuverStepIndex: &stepIdx,
                polylineSegmentIndex: &segIdx,
                offRouteCount: &offCnt,
                offRoute: &offFlag
            )
            currentManeuverStepIndex    = stepIdx
            currentPolylineSegmentIndex = segIdx
            offRouteConsecutiveCount    = offCnt
            isOffRoute                  = offFlag
            lastMatchedProjection       = result.projection
            lastMatchedTimestamp        = loc.timestamp
            currentProjection           = result.projection
            matchedLocation             = result.projection.coordinate
            snappedLocation             = result.projection.coordinate
            if result.remaining.count >= 2 { remainingPolyline = result.remaining }
            activeProgress              = result.progress
            onProgressUpdate?(result.progress)
        }
        print("[NavSession] Active route replaced successfully (session \(sessionGeneration)) — \(route.steps.count) steps")
    }

    public func setRerouting(_ rerouting: Bool) {
        isRerouting = rerouting
    }

    public func clearRoute() {
        activeRouteGeneration &+= 1
        activeRoute                 = nil
        remainingPolyline           = []
        lastMatchedProjection       = nil
        lastMatchedTimestamp        = nil
        if state == .routePreview || state == .arrived { state = .idle }
    }

    // MARK: - Background

    private func enableBackgroundLocation() {
        locationManager.allowsBackgroundLocationUpdates = true
    }

    private func disableBackgroundLocation() {
        locationManager.allowsBackgroundLocationUpdates = false
        backgroundSession = nil
    }

    // MARK: - Kalman Smoothing

    private func kalmanSmooth(rawLat: Double, rawLon: Double,
                               accuracy: Double, timestamp: Date) -> CLLocationCoordinate2D {
        guard let last = kalmanTimestamp else {
            kalmanLat = rawLat; kalmanLon = rawLon
            kalmanAccuracy = accuracy; kalmanTimestamp = timestamp
            return CLLocationCoordinate2D(latitude: rawLat, longitude: rawLon)
        }
        let dt = max(0.01, timestamp.timeIntervalSince(last))
        kalmanTimestamp = timestamp
        let predAcc = kalmanAccuracy + kalmanQ * dt
        let k = predAcc / (predAcc + accuracy)
        kalmanLat      += k * (rawLat - kalmanLat)
        kalmanLon      += k * (rawLon - kalmanLon)
        kalmanAccuracy  = (1.0 - k) * predAcc
        return CLLocationCoordinate2D(latitude: kalmanLat, longitude: kalmanLon)
    }

    // MARK: - Progress Computation

    nonisolated private func computeProgress(
        currentLocation: CLLocation,
        route: NavRoute,
        lastProjection: RouteProjection?,
        lastMatchedTimestamp: Date?,
        maneuverStepIndex: inout Int,
        polylineSegmentIndex: inout Int,
        offRouteCount: inout Int,
        offRoute: inout Bool
    ) -> (progress: NavigationProgress,
          projection: RouteProjection,
          remaining: [CLLocationCoordinate2D]) {

        guard !route.steps.isEmpty, !route.coordinates.isEmpty else {
            let fallbackProj = RouteProjection(
                coordinate: currentLocation.coordinate,
                segmentIndex: 0,
                segmentFraction: 0,
                lateralDistanceMeters: 0,
                distanceAlongRouteMeters: 0
            )
            return (NavigationProgress(maneuver: .arrive, nextStreetName: "Đã đến đích"),
                    fallbackProj, [])
        }

        let coords = route.coordinates

        // Authoritative Route Projection with continuity gating
        guard let projection = route.geometry.project(
            location: currentLocation,
            lastProjection: lastProjection,
            lastMatchedTimestamp: lastMatchedTimestamp
        ) else {
            let fallbackCoord = route.coordinates.first ?? currentLocation.coordinate
            let fallbackProj = RouteProjection(
                coordinate: fallbackCoord,
                segmentIndex: 0,
                segmentFraction: 0,
                lateralDistanceMeters: 0,
                distanceAlongRouteMeters: 0
            )
            return (NavigationProgress(maneuver: .none), fallbackProj, coords)
        }

        // Maintain polylineSegmentIndex strictly from geometry projection
        polylineSegmentIndex = projection.segmentIndex

        // Conservative arrival check:
        // Requires physical proximity (<= arrivalThresholdMeters 15m) AND remaining along-route distance (<= 30m),
        // or very close physical proximity (<= 7.5m) in case polyline end has slight coordinate offset.
        let destCoord = coords.last!
        let destLocation = CLLocation(latitude: destCoord.latitude, longitude: destCoord.longitude)
        let physicalDistToDest = currentLocation.distance(from: destLocation)
        let remDist = route.geometry.remainingDistance(from: projection.distanceAlongRouteMeters)

        let isPhysicallyNear = physicalDistToDest <= arrivalThresholdMeters
        let isRouteProgressNear = remDist <= 30.0
        if (isPhysicallyNear && isRouteProgressNear) || physicalDistToDest <= 7.5 {
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
                    arrivalProj, [])
        }

        // Maneuver step advancement based on along-route progress
        let stepDistances = route.geometry.maneuverDistancesAlongRoute
        while maneuverStepIndex + 1 < route.steps.count {
            let stepTriggerDist = stepDistances[maneuverStepIndex]
            if projection.distanceAlongRouteMeters >= (stepTriggerDist - stepAdvanceThresholdMeters) {
                maneuverStepIndex += 1
                let nextStep = route.steps[maneuverStepIndex]
                print("[NavSession] -> Step \(maneuverStepIndex): \(nextStep.maneuverType.localizedInstruction)")
            } else {
                break
            }
        }

        let curStep = route.steps[min(maneuverStepIndex, route.steps.count - 1)]

        // Off-route detection reusing lateralDistanceMeters from projection (O(1))
        let lateralDist = projection.lateralDistanceMeters
        if lateralDist > offRouteThresholdMeters {
            offRouteCount += 1
            if !offRoute && offRouteCount >= offRouteConsecutiveRequired {
                offRoute = true
                print("[NavSession] OFF-ROUTE lateral=\(Int(lateralDist))m (count=\(offRouteCount))")
            }
        } else {
            if offRouteCount > 0 {
                print("[NavSession] Back on route lateral=\(Int(lateralDist))m")
            }
            offRouteCount = 0
            offRoute = false
        }

        // Distance to turn along route
        let distToTurn = route.geometry.distanceToManeuver(
            stepIndex: maneuverStepIndex,
            from: projection.distanceAlongRouteMeters
        )

        // Remaining polyline: starts at projection point followed by coordinates strictly after projection.segmentIndex
        var remaining = [projection.coordinate]
        let segIdx = projection.segmentIndex
        if segIdx + 1 < coords.count {
            remaining.append(contentsOf: coords[(segIdx + 1)...])
        } else if let last = coords.last {
            remaining.append(last)
        }

        // Stable proportional ETA
        let totalGeomDist = route.geometry.totalDistanceMeters
        let remainingRatio = totalGeomDist > 0 ? max(0.0, min(1.0, remDist / totalGeomDist)) : 0.0
        let remSec = UInt32(round(route.totalDurationSeconds * remainingRatio))
        let kmh = UInt8(min(255, max(0, currentLocation.speed * 3.6)))

        let progress = NavigationProgress(
            maneuver: curStep.maneuverType,
            distanceToTurnMeters: UInt32(max(0, round(distToTurn))),
            remainingDistanceMeters: UInt32(max(0, round(remDist))),
            remainingEtaSeconds: remSec,
            currentSpeedKmh: kmh,
            speedLimitKmh: 0,
            nextStreetName: curStep.streetName
        )

        return (progress, projection, remaining)
    }
}

// MARK: - CLLocationManagerDelegate

extension NavigationSessionManager: @preconcurrency CLLocationManagerDelegate {

    public func locationManager(_ manager: CLLocationManager,
                                didChangeAuthorization status: CLAuthorizationStatus) {
        locationAuthStatus = status
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.startUpdatingLocation(); manager.startUpdatingHeading()
        }
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        locationAuthStatus = status
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.startUpdatingLocation(); manager.startUpdatingHeading()
        }
    }

    public func locationManager(_ manager: CLLocationManager,
                                didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }

        // Update raw location immediately for all incoming samples (including poor accuracy)
        rawLocation = loc

        guard loc.horizontalAccuracy > 0, loc.horizontalAccuracy <= maxAccuracyMeters else {
            print("[NavSession] GPS discarded acc=\(Int(loc.horizontalAccuracy))m")
            return
        }

        // Kalman smooth
        let sm = kalmanSmooth(rawLat: loc.coordinate.latitude, rawLon: loc.coordinate.longitude,
                               accuracy: loc.horizontalAccuracy, timestamp: loc.timestamp)
        let smLoc = CLLocation(coordinate: sm, altitude: loc.altitude,
                                horizontalAccuracy: loc.horizontalAccuracy,
                                verticalAccuracy: loc.verticalAccuracy,
                                course: loc.course, speed: loc.speed,
                                timestamp: loc.timestamp)
        filteredLocation = smLoc
        userLocation     = smLoc

        guard state == .navigating, let route = activeRoute else { return }

        // Capture session & route revision at computation time
        let capturedSessionGeneration = sessionGeneration
        let capturedRouteGeneration = activeRouteGeneration

        var stepIdx = currentManeuverStepIndex
        var segIdx  = currentPolylineSegmentIndex
        var offCnt  = offRouteConsecutiveCount
        var offFlag = isOffRoute
        let prevProj = lastMatchedProjection
        let prevTime = lastMatchedTimestamp

        let result = computeProgress(
            currentLocation: smLoc,
            route: route,
            lastProjection: prevProj,
            lastMatchedTimestamp: prevTime,
            maneuverStepIndex: &stepIdx,
            polylineSegmentIndex: &segIdx,
            offRouteCount: &offCnt,
            offRoute: &offFlag
        )

        Task { @MainActor in
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
            self.offRouteConsecutiveCount    = offCnt
            if result.remaining.count >= 2 { self.remainingPolyline = result.remaining }

            if offFlag && !self.isOffRoute {
                self.isOffRoute = true
                print("[NavSession] Triggering reroute")
                self.onRerouteNeeded?()
            } else if !offFlag {
                self.isOffRoute = false
            }

            if result.progress.maneuver == .arrive && self.state == .navigating {
                self.state = .arrived
                self.onArrived?()
            }

            self.activeProgress = result.progress
            self.onProgressUpdate?(result.progress)
        }
    }

    public func locationManager(_ manager: CLLocationManager,
                                didUpdateHeading newHeading: CLHeading) {
        if newHeading.headingAccuracy >= 0 { heading = newHeading.trueHeading }
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[NavSession] CLLocationManager error: \(error.localizedDescription)")
    }
}
