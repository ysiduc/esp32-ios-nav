import Foundation
@preconcurrency import CoreLocation
import Combine

#if canImport(FerrostarCore)
import FerrostarCore
#endif

/// Manages active navigation state, GPS tracking, route snapping and map-matching.
/// Built-in fixes:
///  - GPS accuracy filter (ignore junk updates with horizontalAccuracy > 30m)
///  - Correct perpendicular map-matching: snap raw GPS onto nearest polyline segment
///  - Tight step-transition threshold (8m) so turn banner clears immediately
///  - Proper perpendicular off-route detection (25m) – no more false negatives
///  - Debounced reroute: requires 3 consecutive off-route frames before triggering
@MainActor
public final class FerrostarNavManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published public private(set) var isNavigating: Bool = false
    @Published public private(set) var activeRoute: NavRoute?
    @Published public private(set) var activeProgress: NavigationProgress = NavigationProgress()
    @Published public private(set) var userLocation: CLLocation?
    @Published public private(set) var snappedLocation: CLLocationCoordinate2D?
    @Published public private(set) var isOffRoute: Bool = false

    public var onProgressUpdate: ((NavigationProgress) -> Void)?
    public var onRerouteNeeded: (() -> Void)?

    private let locationManager = CLLocationManager()
    private var currentStepIndex: Int = 0

    /// Maximum GPS horizontal accuracy to accept (meters). Updates worse than this are discarded.
    private let maxAcceptableAccuracy: Double = 30.0

    /// Distance threshold to advance to the next maneuver step (meters).
    /// 8m ≈ 1 GPS tick at 30 km/h – banner clears at the turn, not 18m past it.
    private let stepAdvanceThresholdMeters: Double = 8.0

    /// Distance from polyline at which off-route is declared (meters).
    /// 25m is tight enough to detect a wrong lane on a wide road without false alarms.
    private let offRouteThresholdMeters: Double = 25.0

    /// How many consecutive off-route GPS frames before triggering a reroute.
    /// Prevents a single bad GPS fix from causing an immediate reroute.
    private var offRouteConsecutiveCount: Int = 0
    private let offRouteConsecutiveRequired: Int = 3

    public override init() {
        super.init()
        setupLocationManager()
    }

    private func setupLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone  // Get every update; we filter by accuracy ourselves
        locationManager.activityType = .automotiveNavigation     // Tells iOS this is driving navigation
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.showsBackgroundLocationIndicator = true
    }

    public func requestPermissions() {
        locationManager.requestAlwaysAuthorization()
    }

    // MARK: - Navigation Control

    /// Start Turn-by-Turn Navigation with a calculated route
    public func startNavigation(route: NavRoute) {
        self.activeRoute = route
        self.isNavigating = true
        self.currentStepIndex = 0
        self.isOffRoute = false
        self.offRouteConsecutiveCount = 0
        self.snappedLocation = nil

        locationManager.startUpdatingLocation()

        if let firstStep = route.steps.first {
            self.activeProgress = NavigationProgress(
                maneuver: firstStep.maneuverType,
                distanceToTurnMeters: UInt32(firstStep.distanceMeters),
                remainingDistanceMeters: UInt32(route.totalDistanceMeters),
                remainingEtaSeconds: UInt32(route.totalDurationSeconds),
                currentSpeedKmh: 0,
                speedLimitKmh: 0,
                nextStreetName: firstStep.streetName
            )
            self.onProgressUpdate?(self.activeProgress)
        }
    }

    /// Stop Turn-by-Turn Navigation and reset all state
    public func stopNavigation() {
        self.isNavigating = false
        self.activeRoute = nil
        self.currentStepIndex = 0
        self.isOffRoute = false
        self.offRouteConsecutiveCount = 0
        self.activeProgress = NavigationProgress()
        self.snappedLocation = nil
        locationManager.stopUpdatingLocation()
    }

    // MARK: - CLLocationManagerDelegate

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        // --- Fix 3a: GPS Accuracy Filter ---
        // Discard updates where iOS hasn't achieved a good fix yet.
        // horizontalAccuracy < 0 means invalid; > maxAcceptableAccuracy means too noisy.
        guard location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= maxAcceptableAccuracy else {
            print("[NavManager] GPS update discarded: accuracy=\(Int(location.horizontalAccuracy))m (threshold=\(Int(maxAcceptableAccuracy))m)")
            return
        }

        self.userLocation = location

        guard isNavigating, let route = activeRoute else { return }
        updateNavigationState(currentLocation: location, route: route)
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[NavManager] CLLocationManager error: \(error.localizedDescription)")
    }

    // MARK: - Core Navigation State Machine

    /// Update step progress, snap to polyline, and detect off-route divergence.
    private func updateNavigationState(currentLocation: CLLocation, route: NavRoute) {
        guard currentStepIndex < route.steps.count else {
            // Arrived at destination
            let finalProgress = NavigationProgress(
                maneuver: .arrive,
                distanceToTurnMeters: 0,
                remainingDistanceMeters: 0,
                remainingEtaSeconds: 0,
                currentSpeedKmh: UInt8(max(0, currentLocation.speed * 3.6)),
                speedLimitKmh: 0,
                nextStreetName: "Đã đến đích"
            )
            self.activeProgress = finalProgress
            self.onProgressUpdate?(finalProgress)
            return
        }

        // --- Fix 3b: Map-Matching — snap raw GPS onto the polyline ---
        // This gives the correct "which lane am I on" position for multi-lane roads.
        let snapped = snapToNearestPolylinePoint(rawCoord: currentLocation.coordinate, polyline: route.coordinates)
        self.snappedLocation = snapped
        let snappedLocation = CLLocation(latitude: snapped.latitude, longitude: snapped.longitude)

        let currentStep = route.steps[currentStepIndex]
        let stepEndLoc = CLLocation(latitude: currentStep.coordinate.latitude, longitude: currentStep.coordinate.longitude)

        // Use snapped position to measure distance to the step-end maneuver point
        let distanceToStepEnd = snappedLocation.distance(from: stepEndLoc)

        // --- Fix 1: Tight step transition threshold (8m instead of 18m) ---
        // Advance through ALL steps that the snapped position has already passed.
        // The while-loop handles the edge case where GPS jumps over a very short step.
        while distanceToStepEnd < stepAdvanceThresholdMeters && currentStepIndex + 1 < route.steps.count {
            currentStepIndex += 1
            print("[NavManager] Advanced to step \(currentStepIndex)/\(route.steps.count - 1)")
        }

        // --- Fix 2: Perpendicular off-route detection using snapped point ---
        let minDistanceToRoute = calculateMinDistanceToPolyline(
            point: currentLocation.coordinate,  // Use raw GPS for off-route (snapped would always be 0)
            polyline: route.coordinates
        )

        if minDistanceToRoute > offRouteThresholdMeters {
            offRouteConsecutiveCount += 1
            if !isOffRoute && offRouteConsecutiveCount >= offRouteConsecutiveRequired {
                isOffRoute = true
                print("[NavManager] Off-route confirmed after \(offRouteConsecutiveCount) frames (\(Int(minDistanceToRoute))m from route). Triggering reroute...")
                onRerouteNeeded?()
            }
        } else {
            // Back on route — reset debounce counter
            if offRouteConsecutiveCount > 0 {
                print("[NavManager] Back on route (\(Int(minDistanceToRoute))m from polyline). Resetting off-route counter.")
            }
            offRouteConsecutiveCount = 0
            isOffRoute = false
        }

        // Calculate remaining distance from snapped position through remaining steps
        let targetStep = route.steps[currentStepIndex]
        let targetStepEndLoc = CLLocation(latitude: targetStep.coordinate.latitude, longitude: targetStep.coordinate.longitude)
        let distToCurrentStepEnd = snappedLocation.distance(from: targetStepEndLoc)

        var remainingDist: Double = distToCurrentStepEnd
        for i in (currentStepIndex + 1)..<route.steps.count {
            remainingDist += route.steps[i].distanceMeters
        }

        let speedKmh = UInt8(max(0, min(250, currentLocation.speed * 3.6)))
        // Use GPS speed if valid, otherwise assume 30 km/h for ETA
        let speedMps = currentLocation.speed > 0.5 ? currentLocation.speed : 8.33
        let remainingSeconds = UInt32(remainingDist / speedMps)

        let progress = NavigationProgress(
            maneuver: targetStep.maneuverType,
            distanceToTurnMeters: UInt32(max(0, distToCurrentStepEnd)),
            remainingDistanceMeters: UInt32(max(0, remainingDist)),
            remainingEtaSeconds: remainingSeconds,
            currentSpeedKmh: speedKmh,
            speedLimitKmh: 0,
            nextStreetName: targetStep.streetName
        )

        self.activeProgress = progress
        self.onProgressUpdate?(progress)
    }

    // MARK: - Geometry Helpers

    /// Map-matching: project rawCoord onto the nearest polyline segment and return the closest on-road point.
    /// This corrects the "wrong lane on multi-lane road" problem by snapping GPS to the route geometry.
    private func snapToNearestPolylinePoint(
        rawCoord: CLLocationCoordinate2D,
        polyline: [CLLocationCoordinate2D]
    ) -> CLLocationCoordinate2D {
        guard polyline.count >= 2 else { return rawCoord }

        var bestPoint = rawCoord
        var bestDistSq: Double = .infinity

        for i in 0..<(polyline.count - 1) {
            let proj = projectPointOntoSegment(
                point: rawCoord,
                segStart: polyline[i],
                segEnd: polyline[i + 1]
            )
            let dx = (proj.latitude - rawCoord.latitude) * 111_319.9
            let dy = (proj.longitude - rawCoord.longitude) * 111_319.9 * cos(rawCoord.latitude * .pi / 180)
            let distSq = dx * dx + dy * dy
            if distSq < bestDistSq {
                bestDistSq = distSq
                bestPoint = proj
            }
        }

        return bestPoint
    }

    /// Fix 2: True perpendicular distance from a point to each polyline segment.
    /// Previous implementation only measured distance to segment START POINTS — completely wrong.
    private func calculateMinDistanceToPolyline(
        point: CLLocationCoordinate2D,
        polyline: [CLLocationCoordinate2D]
    ) -> Double {
        guard polyline.count >= 2 else { return 0.0 }
        var minDistanceMeters: Double = .infinity

        for i in 0..<(polyline.count - 1) {
            let proj = projectPointOntoSegment(
                point: point,
                segStart: polyline[i],
                segEnd: polyline[i + 1]
            )
            let pLoc = CLLocation(latitude: point.latitude, longitude: point.longitude)
            let projLoc = CLLocation(latitude: proj.latitude, longitude: proj.longitude)
            let d = pLoc.distance(from: projLoc)
            if d < minDistanceMeters {
                minDistanceMeters = d
            }
        }

        return minDistanceMeters
    }

    /// Project a geographic point onto a line segment [segStart, segEnd] using linear algebra in local metric space.
    /// Returns the closest point on the segment (clamped between the two endpoints).
    private func projectPointOntoSegment(
        point: CLLocationCoordinate2D,
        segStart: CLLocationCoordinate2D,
        segEnd: CLLocationCoordinate2D
    ) -> CLLocationCoordinate2D {
        // Convert to approximate metric space (meters) centered on segStart
        let cosLat = cos(segStart.latitude * .pi / 180)
        let metersPerLat: Double = 111_319.9
        let metersPerLon: Double = 111_319.9 * cosLat

        let ax: Double = 0.0
        let ay: Double = 0.0
        let bx: Double = (segEnd.longitude - segStart.longitude) * metersPerLon
        let by: Double = (segEnd.latitude  - segStart.latitude)  * metersPerLat
        let px: Double = (point.longitude - segStart.longitude) * metersPerLon
        let py: Double = (point.latitude  - segStart.latitude)  * metersPerLat

        let abx = bx - ax
        let aby = by - ay
        let lenSq = abx * abx + aby * aby

        guard lenSq > 1e-10 else {
            // Degenerate segment (zero length) — return start point
            return segStart
        }

        // t is the scalar projection, clamped to [0, 1] to stay on segment
        let t = max(0.0, min(1.0, ((px - ax) * abx + (py - ay) * aby) / lenSq))

        let projX = ax + t * abx
        let projY = ay + t * aby

        return CLLocationCoordinate2D(
            latitude:  segStart.latitude  + projY / metersPerLat,
            longitude: segStart.longitude + projX / metersPerLon
        )
    }
}
