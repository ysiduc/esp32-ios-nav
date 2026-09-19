//
//  NavigationSessionManager.swift
//  Core navigation state machine and GPS engine.
//
//  States: .idle -> .searching -> .routePreview -> .navigating -> .arrived
//
//  Key behaviours:
//  1. High-accuracy GPS (kCLLocationAccuracyBestForNavigation)
//  2. Background location (iOS 17+)
//  3. Ahead-only snap-to-route: projects GPS onto segments ahead of current step only
//  4. Off-route detection 15m threshold, 2-frame debounce (faster reroute)
//  5. Kalman filter smoothing to reduce GPS jitter
//  6. remainingPolyline: trimmed ahead-only polyline published for MapViewContainer
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

    // MARK: Published
    @Published public var state: NavigationState            = .idle
    @Published public var userLocation: CLLocation?
    @Published public var snappedLocation: CLLocationCoordinate2D?
    @Published public var activeRoute: NavRoute?
    @Published public var activeProgress: NavigationProgress = NavigationProgress()
    @Published public var locationAuthStatus: CLAuthorizationStatus = .notDetermined
    @Published public var heading: Double = 0
    /// Remaining (undriven) polyline — trimmed from snapped position to destination.
    @Published public var remainingPolyline: [CLLocationCoordinate2D] = []

    // MARK: Callbacks
    public var onProgressUpdate: ((NavigationProgress) -> Void)?
    public var onRerouteNeeded: (() -> Void)?
    public var onArrived: (() -> Void)?

    // MARK: Thresholds
    private let stepAdvanceThresholdMeters: Double = 12.0
    private let offRouteThresholdMeters: Double    = 15.0
    private let offRouteConsecutiveRequired: Int   = 2
    private let maxAccuracyMeters: Double          = 20.0
    private let arrivalThresholdMeters: Double     = 15.0

    // MARK: Private State
    private let locationManager = CLLocationManager()
    private var currentStepIndex: Int = 0
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
        locationManager.requestWhenInUseAuthorization()
    }

    // MARK: - Public API

    public func requestAlwaysAuthorization() {
        locationManager.requestAlwaysAuthorization()
    }

    public func startNavigation(route: NavRoute) {
        activeRoute              = route
        currentStepIndex         = 0
        offRouteConsecutiveCount = 0
        isOffRoute               = false
        remainingPolyline        = route.coordinates
        kalmanTimestamp          = nil
        state                    = .navigating
        enableBackgroundLocation()
        print("[NavSession] Navigation started — \(route.steps.count) steps")
    }

    public func stopNavigation() {
        state                    = .idle
        activeRoute              = nil
        activeProgress           = NavigationProgress()
        offRouteConsecutiveCount = 0
        isOffRoute               = false
        remainingPolyline        = []
        disableBackgroundLocation()
    }

    public func setRoutePreview(_ route: NavRoute) {
        activeRoute       = route
        remainingPolyline = route.coordinates
        state             = .routePreview
    }

    public func clearRoute() {
        activeRoute       = nil
        remainingPolyline = []
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
        stepIndex: inout Int,
        offRouteCount: inout Int,
        offRoute: inout Bool
    ) -> (progress: NavigationProgress,
          snapped: CLLocationCoordinate2D,
          remaining: [CLLocationCoordinate2D]) {

        guard !route.steps.isEmpty else {
            return (NavigationProgress(maneuver: .arrive, nextStreetName: "Da den dich"),
                    currentLocation.coordinate, [])
        }

        let coords = route.coordinates

        // Arrival check
        let finalLoc = CLLocation(latitude: coords.last!.latitude,
                                  longitude: coords.last!.longitude)
        if currentLocation.distance(from: finalLoc) < arrivalThresholdMeters {
            return (NavigationProgress(maneuver: .arrive, distanceToTurnMeters: 0,
                                       remainingDistanceMeters: 0, remainingEtaSeconds: 0,
                                       currentSpeedKmh: 0, speedLimitKmh: 0,
                                       nextStreetName: "Da den dich"),
                    coords.last!, [])
        }

        // Ahead-only snap
        let (snapped, segIdx) = snapAhead(
            rawCoord: currentLocation.coordinate,
            polyline: coords,
            fromSeg: max(0, stepIndex)
        )
        let snappedLoc = CLLocation(latitude: snapped.latitude, longitude: snapped.longitude)

        // Step advancement
        func step(_ i: Int) -> NavStep { route.steps[min(i, route.steps.count - 1)] }
        var cur = step(stepIndex)
        var distToEnd = snappedLoc.distance(from: CLLocation(latitude: cur.coordinate.latitude,
                                                              longitude: cur.coordinate.longitude))
        while distToEnd < stepAdvanceThresholdMeters && stepIndex + 1 < route.steps.count {
            stepIndex += 1
            cur = step(stepIndex)
            distToEnd = snappedLoc.distance(from: CLLocation(latitude: cur.coordinate.latitude,
                                                              longitude: cur.coordinate.longitude))
            print("[NavSession] -> Step \(stepIndex): \(cur.maneuverType.localizedInstruction)")
        }

        // Off-route
        let minDist = minDistToPolyline(point: currentLocation.coordinate, polyline: coords)
        if minDist > offRouteThresholdMeters {
            offRouteCount += 1
            if !offRoute && offRouteCount >= offRouteConsecutiveRequired {
                offRoute = true
                print("[NavSession] OFF-ROUTE \(Int(minDist))m")
            }
        } else {
            if offRouteCount > 0 { print("[NavSession] Back on route \(Int(minDist))m") }
            offRouteCount = 0; offRoute = false
        }

        // Trim remaining polyline
        var remaining = [snapped]
        if segIdx + 1 < coords.count {
            remaining.append(contentsOf: coords[(segIdx + 1)...])
        } else if let last = coords.last { remaining.append(last) }

        // Remaining distance
        var remDist = distToEnd
        for i in (stepIndex + 1)..<route.steps.count { remDist += route.steps[i].distanceMeters }

        let spd = currentLocation.speed > 0.5 ? currentLocation.speed : 8.33
        let remSec = UInt32(remDist / spd)
        let kmh = UInt8(min(255, max(0, currentLocation.speed * 3.6)))

        return (NavigationProgress(maneuver: cur.maneuverType,
                                   distanceToTurnMeters: UInt32(max(0, distToEnd)),
                                   remainingDistanceMeters: UInt32(max(0, remDist)),
                                   remainingEtaSeconds: remSec,
                                   currentSpeedKmh: kmh, speedLimitKmh: 0,
                                   nextStreetName: cur.streetName),
                snapped, remaining)
    }

    // MARK: - Geometry

    nonisolated private func snapAhead(
        rawCoord: CLLocationCoordinate2D,
        polyline: [CLLocationCoordinate2D],
        fromSeg: Int
    ) -> (CLLocationCoordinate2D, Int) {
        guard polyline.count >= 2 else { return (rawCoord, 0) }
        var best = rawCoord; var bestDSq = Double.infinity; var bestSeg = max(0, fromSeg)
        for i in max(0, fromSeg)..<(polyline.count - 1) {
            let proj = projectOnSegment(p: rawCoord, a: polyline[i], b: polyline[i+1])
            let dx = (proj.latitude  - rawCoord.latitude)  * 111_319.9
            let dy = (proj.longitude - rawCoord.longitude) * 111_319.9 * cos(rawCoord.latitude * .pi / 180)
            let dsq = dx*dx + dy*dy
            if dsq < bestDSq { bestDSq = dsq; best = proj; bestSeg = i }
        }
        return (best, bestSeg)
    }

    nonisolated private func minDistToPolyline(
        point: CLLocationCoordinate2D,
        polyline: [CLLocationCoordinate2D]
    ) -> Double {
        guard polyline.count >= 2 else { return 0 }
        var minD = Double.infinity
        for i in 0..<(polyline.count - 1) {
            let proj = projectOnSegment(p: point, a: polyline[i], b: polyline[i+1])
            let d = CLLocation(latitude: point.latitude, longitude: point.longitude)
                      .distance(from: CLLocation(latitude: proj.latitude, longitude: proj.longitude))
            if d < minD { minD = d }
        }
        return minD
    }

    nonisolated private func projectOnSegment(
        p: CLLocationCoordinate2D,
        a: CLLocationCoordinate2D,
        b: CLLocationCoordinate2D
    ) -> CLLocationCoordinate2D {
        let cosLat  = cos(a.latitude * .pi / 180)
        let mLat    = 111_319.9
        let mLon    = 111_319.9 * cosLat
        let bx = (b.longitude - a.longitude) * mLon
        let by = (b.latitude  - a.latitude)  * mLat
        let px = (p.longitude - a.longitude) * mLon
        let py = (p.latitude  - a.latitude)  * mLat
        let len2 = bx*bx + by*by
        guard len2 > 1e-10 else { return a }
        let t = max(0, min(1, (px*bx + py*by) / len2))
        return CLLocationCoordinate2D(latitude: a.latitude + t*by/mLat,
                                      longitude: a.longitude + t*bx/mLon)
    }
}

// MARK: - CLLocationManagerDelegate

extension NavigationSessionManager: CLLocationManagerDelegate {

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
        userLocation = smLoc

        guard state == .navigating, let route = activeRoute else { return }

        var stepIdx = currentStepIndex
        var offCnt  = offRouteConsecutiveCount
        var offFlag = isOffRoute

        let result = computeProgress(currentLocation: smLoc, route: route,
                                      stepIndex: &stepIdx, offRouteCount: &offCnt,
                                      offRoute: &offFlag)

        Task { @MainActor in
            self.currentStepIndex         = stepIdx
            self.offRouteConsecutiveCount = offCnt
            self.snappedLocation          = result.snapped
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
