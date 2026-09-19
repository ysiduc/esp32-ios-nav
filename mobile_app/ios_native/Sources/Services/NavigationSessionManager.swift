//
//  NavigationSessionManager.swift
//  Core navigation state machine and GPS engine.
//
//  States: .idle → .searching → .routePreview → .navigating → .arrived
//
//  Key behaviours:
//  1. High-accuracy GPS (kCLLocationAccuracyBestForNavigation)
//  2. Background location via CLBackgroundActivitySession (iOS 17+)
//  3. Snap-to-route map matching (projects GPS onto nearest polyline segment)
//  4. Off-route detection using perpendicular distance with 3-frame debounce
//  5. Automatic rerouting callback after 3 consecutive off-route GPS readings
//

import CoreLocation
import Foundation

// MARK: - Navigation State

public enum NavigationState: Equatable, Sendable {
    case idle               // App just launched, waiting for GPS
    case searching          // User typing in search bar
    case routePreview       // Route calculated, showing overview
    case navigating         // Active turn-by-turn navigation
    case arrived            // Destination reached
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

    // Formatted display strings
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
        return "\(mins) phút"
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

    // MARK: Callbacks
    public var onProgressUpdate: ((NavigationProgress) -> Void)?
    public var onRerouteNeeded: (() -> Void)?
    public var onArrived: (() -> Void)?

    // MARK: Thresholds (tuned for Vietnam urban roads)
    /// Step advance: enter within 8m of maneuver point to trigger next step.
    private let stepAdvanceThresholdMeters: Double = 8.0
    /// Off-route: perpendicular distance > 25m from polyline triggers reroute.
    private let offRouteThresholdMeters: Double = 25.0
    /// 3 consecutive readings before reroute to debounce GPS multipath.
    private let offRouteConsecutiveRequired: Int = 3
    /// Discard GPS readings with horizontal accuracy worse than 30m (urban GPS multipath).
    private let maxAccuracyMeters: Double = 30.0
    /// Arrival threshold: within 12m of final destination coordinate.
    private let arrivalThresholdMeters: Double = 12.0

    // MARK: Private State
    private let locationManager = CLLocationManager()
    private var currentStepIndex: Int = 0
    private var offRouteConsecutiveCount: Int = 0
    private var isOffRoute: Bool = false
    private var backgroundSession: Any? = nil // CLBackgroundActivitySession (iOS 17+)

    override public init() {
        super.init()
        setupLocationManager()
    }

    // MARK: - Location Manager Setup

    private func setupLocationManager() {
        locationManager.delegate        = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter  = kCLDistanceFilterNone
        locationManager.headingFilter   = 2.0  // degrees
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
        state                    = .navigating

        // Enable background location for active navigation
        enableBackgroundLocation()

        print("[NavSession] Navigation started — \(route.steps.count) steps, \(route.formattedDistance)")
    }

    public func stopNavigation() {
        state       = .idle
        activeRoute = nil
        activeProgress = NavigationProgress(maneuver: .none, nextStreetName: "Chờ kết nối")
        offRouteConsecutiveCount = 0
        isOffRoute               = false
        disableBackgroundLocation()
        print("[NavSession] Navigation stopped.")
    }

    public func setRoutePreview(_ route: NavRoute) {
        activeRoute = route
        state = .routePreview
    }

    public func clearRoute() {
        activeRoute = nil
        if state == .routePreview || state == .arrived {
            state = .idle
        }
    }

    // MARK: - Background Location

    private func enableBackgroundLocation() {
        locationManager.allowsBackgroundLocationUpdates = true
        if #available(iOS 17.0, *) {
            // CLBackgroundActivitySession keeps location running in background
            // without showing the blue status bar (requires "location" background mode).
            // backgroundSession = CLBackgroundActivitySession()
            // Note: Uncomment the above line after adding CLBackgroundActivitySession
            // to Info.plist UIBackgroundModes.
        }
    }

    private func disableBackgroundLocation() {
        locationManager.allowsBackgroundLocationUpdates = false
        if #available(iOS 17.0, *) {
            // (backgroundSession as? CLBackgroundActivitySession)?.invalidate()
            backgroundSession = nil
        }
    }

    // MARK: - Navigation Progress Computation

    nonisolated private func computeProgress(
        currentLocation: CLLocation,
        route: NavRoute,
        stepIndex: inout Int,
        offRouteCount: inout Int,
        offRoute: inout Bool
    ) -> NavigationProgress {

        guard !route.steps.isEmpty else {
            return NavigationProgress(maneuver: .arrive, nextStreetName: "Đã đến đích")
        }

        let coords = route.coordinates

        // --- Arrival check ---
        let finalDest = CLLocation(
            latitude: coords.last!.latitude,
            longitude: coords.last!.longitude
        )
        if currentLocation.distance(from: finalDest) < arrivalThresholdMeters {
            return NavigationProgress(
                maneuver: .arrive,
                distanceToTurnMeters: 0,
                remainingDistanceMeters: 0,
                remainingEtaSeconds: 0,
                currentSpeedKmh: 0,
                speedLimitKmh: 0,
                nextStreetName: "Đã đến đích"
            )
        }

        // --- Map-matching: snap GPS onto nearest polyline segment ---
        let snapped = snapToNearestPolylinePoint(
            rawCoord: currentLocation.coordinate,
            polyline: coords
        )
        let snappedLoc = CLLocation(latitude: snapped.latitude, longitude: snapped.longitude)

        // --- Step advancement ---
        let safeStep = { () -> NavStep in
            let i = min(stepIndex, route.steps.count - 1)
            return route.steps[i]
        }

        var currentStep = safeStep()
        let stepEndLoc  = CLLocation(
            latitude:  currentStep.coordinate.latitude,
            longitude: currentStep.coordinate.longitude
        )
        var distToStepEnd = snappedLoc.distance(from: stepEndLoc)

        // Advance through steps the snapped position has already passed
        while distToStepEnd < stepAdvanceThresholdMeters
                && stepIndex + 1 < route.steps.count {
            stepIndex  += 1
            currentStep = safeStep()
            let nextEnd = CLLocation(
                latitude:  currentStep.coordinate.latitude,
                longitude: currentStep.coordinate.longitude
            )
            distToStepEnd = snappedLoc.distance(from: nextEnd)
            print("[NavSession] → Step \(stepIndex)/\(route.steps.count - 1): \(currentStep.maneuverType.localizedInstruction)")
        }

        // --- Off-route detection (perpendicular to full polyline) ---
        let minDist = calculateMinDistanceToPolyline(
            point: currentLocation.coordinate, // raw GPS — snapped would always be ~0
            polyline: coords
        )

        if minDist > offRouteThresholdMeters {
            offRouteCount += 1
            if !offRoute && offRouteCount >= offRouteConsecutiveRequired {
                offRoute = true
                print("[NavSession] ⚠️ Off-route: \(Int(minDist))m from polyline after \(offRouteCount) frames.")
            }
        } else {
            if offRouteCount > 0 {
                print("[NavSession] ✅ Back on route (\(Int(minDist))m). Resetting counter.")
            }
            offRouteCount = 0
            offRoute      = false
        }

        // --- Remaining distance calculation ---
        var remainingDist = distToStepEnd
        for i in (stepIndex + 1)..<route.steps.count {
            remainingDist += route.steps[i].distanceMeters
        }

        // --- ETA ---
        let speedMps     = currentLocation.speed > 0.5 ? currentLocation.speed : 8.33 // default 30km/h
        let remainingSec = UInt32(remainingDist / speedMps)
        let speedKmh     = UInt8(min(255, max(0, currentLocation.speed * 3.6)))

        return NavigationProgress(
            maneuver: currentStep.maneuverType,
            distanceToTurnMeters: UInt32(max(0, distToStepEnd)),
            remainingDistanceMeters: UInt32(max(0, remainingDist)),
            remainingEtaSeconds: remainingSec,
            currentSpeedKmh: speedKmh,
            speedLimitKmh: 0,
            nextStreetName: currentStep.streetName
        )
    }

    // MARK: - Geometry Helpers

    /// Projects rawCoord onto the nearest polyline segment (map-matching).
    nonisolated private func snapToNearestPolylinePoint(
        rawCoord: CLLocationCoordinate2D,
        polyline: [CLLocationCoordinate2D]
    ) -> CLLocationCoordinate2D {
        guard polyline.count >= 2 else { return rawCoord }
        var best = rawCoord
        var bestDistSq: Double = .infinity

        for i in 0..<(polyline.count - 1) {
            let proj = projectPointOntoSegment(
                point: rawCoord,
                segStart: polyline[i],
                segEnd: polyline[i + 1]
            )
            let dx = (proj.latitude  - rawCoord.latitude)  * 111_319.9
            let dy = (proj.longitude - rawCoord.longitude) * 111_319.9
                   * cos(rawCoord.latitude * .pi / 180)
            let dsq = dx * dx + dy * dy
            if dsq < bestDistSq { bestDistSq = dsq; best = proj }
        }

        return best
    }

    /// Perpendicular distance from point to each polyline segment — returns minimum.
    nonisolated private func calculateMinDistanceToPolyline(
        point: CLLocationCoordinate2D,
        polyline: [CLLocationCoordinate2D]
    ) -> Double {
        guard polyline.count >= 2 else { return 0 }
        var minDist: Double = .infinity

        for i in 0..<(polyline.count - 1) {
            let proj = projectPointOntoSegment(
                point: point,
                segStart: polyline[i],
                segEnd: polyline[i + 1]
            )
            let pLoc    = CLLocation(latitude: point.latitude, longitude: point.longitude)
            let projLoc = CLLocation(latitude: proj.latitude,  longitude: proj.longitude)
            let d       = pLoc.distance(from: projLoc)
            if d < minDist { minDist = d }
        }

        return minDist
    }

    /// Project geographic point onto segment [segStart, segEnd] using local metric space.
    nonisolated private func projectPointOntoSegment(
        point: CLLocationCoordinate2D,
        segStart: CLLocationCoordinate2D,
        segEnd: CLLocationCoordinate2D
    ) -> CLLocationCoordinate2D {
        let cosLat       = cos(segStart.latitude * .pi / 180)
        let mPerLat: Double = 111_319.9
        let mPerLon: Double = 111_319.9 * cosLat

        let bx = (segEnd.longitude   - segStart.longitude) * mPerLon
        let by = (segEnd.latitude    - segStart.latitude)  * mPerLat
        let px = (point.longitude    - segStart.longitude) * mPerLon
        let py = (point.latitude     - segStart.latitude)  * mPerLat

        let lenSq = bx * bx + by * by
        guard lenSq > 1e-10 else { return segStart }

        let t = max(0, min(1, (px * bx + py * by) / lenSq))
        return CLLocationCoordinate2D(
            latitude:  segStart.latitude  + t * by / mPerLat,
            longitude: segStart.longitude + t * bx / mPerLon
        )
    }
}

// MARK: - CLLocationManagerDelegate

extension NavigationSessionManager: CLLocationManagerDelegate {

    public func locationManager(_ manager: CLLocationManager,
                                didChangeAuthorization status: CLAuthorizationStatus) {
        locationAuthStatus = status
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.startUpdatingLocation()
            manager.startUpdatingHeading()
            print("[NavSession] Location authorised — GPS started.")
        }
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        locationAuthStatus = status
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.startUpdatingLocation()
            manager.startUpdatingHeading()
        }
    }

    public func locationManager(_ manager: CLLocationManager,
                                didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        // Filter out low-accuracy GPS jitter (urban GPS multipath)
        guard location.horizontalAccuracy > 0,
              location.horizontalAccuracy <= maxAccuracyMeters else {
            print("[NavSession] GPS reading discarded — accuracy \(Int(location.horizontalAccuracy))m > \(Int(maxAccuracyMeters))m threshold.")
            return
        }

        userLocation = location

        guard state == .navigating, let route = activeRoute else { return }

        // Compute on calling thread (already non-UI) then update @Published on main
        var stepIdx        = currentStepIndex
        var offCount       = offRouteConsecutiveCount
        var offRouteFlag   = isOffRoute

        let progress = computeProgress(
            currentLocation: location,
            route: route,
            stepIndex: &stepIdx,
            offRouteCount: &offCount,
            offRoute: &offRouteFlag
        )

        // Write-back mutated state (must be on MainActor since all @Published)
        Task { @MainActor in
            self.currentStepIndex         = stepIdx
            self.offRouteConsecutiveCount = offCount
            self.snappedLocation          = self.snapToNearestPolylinePoint(
                rawCoord: location.coordinate,
                polyline: route.coordinates
            )

            // Trigger reroute if newly off-route
            if offRouteFlag && !self.isOffRoute {
                self.isOffRoute = true
                self.onRerouteNeeded?()
            } else if !offRouteFlag {
                self.isOffRoute = false
            }

            // Trigger arrival
            if progress.maneuver == .arrive && self.state == .navigating {
                self.state = .arrived
                self.onArrived?()
            }

            self.activeProgress = progress
            self.onProgressUpdate?(progress)
        }
    }

    public func locationManager(_ manager: CLLocationManager,
                                didUpdateHeading newHeading: CLHeading) {
        if newHeading.headingAccuracy >= 0 {
            heading = newHeading.trueHeading
        }
    }

    public func locationManager(_ manager: CLLocationManager,
                                didFailWithError error: Error) {
        print("[NavSession] CLLocationManager error: \(error.localizedDescription)")
    }
}
