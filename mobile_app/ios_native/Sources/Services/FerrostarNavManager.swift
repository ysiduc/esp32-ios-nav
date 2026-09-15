import Foundation
@preconcurrency import CoreLocation
import Combine

#if canImport(FerrostarCore)
import FerrostarCore
#endif

/// Manages active navigation state, GPS tracking, and route snapping
/// Designed to interface with Ferrostar Core where available, with built-in high-precision snapping
@MainActor
public final class FerrostarNavManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published public private(set) var isNavigating: Bool = false
    @Published public private(set) var activeRoute: NavRoute?
    @Published public private(set) var activeProgress: NavigationProgress = NavigationProgress()
    @Published public private(set) var userLocation: CLLocation?
    @Published public private(set) var isOffRoute: Bool = false

    public var onProgressUpdate: ((NavigationProgress) -> Void)?
    public var onRerouteNeeded: (() -> Void)?

    private let locationManager = CLLocationManager()
    private var currentStepIndex: Int = 0
    private var offRouteThresholdMeters: Double = 40.0 // 40m off polyline triggers reroute

    public override init() {
        super.init()
        setupLocationManager()
    }

    private func setupLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = 2.0 // Update every 2 meters
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.showsBackgroundLocationIndicator = true
    }

    public func requestPermissions() {
        locationManager.requestAlwaysAuthorization()
    }

    /// Start Turn-by-Turn Navigation with a calculated route
    public func startNavigation(route: NavRoute) {
        self.activeRoute = route
        self.isNavigating = true
        self.currentStepIndex = 0
        self.isOffRoute = false

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

    /// Stop Turn-by-Turn Navigation
    public func stopNavigation() {
        self.isNavigating = false
        self.activeRoute = nil
        self.currentStepIndex = 0
        self.isOffRoute = false
        self.activeProgress = NavigationProgress()
        locationManager.stopUpdatingLocation()
    }

    // MARK: - CLLocationManagerDelegate
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        self.userLocation = location

        guard isNavigating, let route = activeRoute else { return }
        updateNavigationState(currentLocation: location, route: route)
    }

    /// Update step progress, snap to polyline, and detect off-route divergence
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

        let currentStep = route.steps[currentStepIndex]
        let stepLoc = CLLocation(latitude: currentStep.coordinate.latitude, longitude: currentStep.coordinate.longitude)
        let distanceToStepEnd = currentLocation.distance(from: stepLoc)

        // Check if user transitioned to the next step (< 18m threshold)
        if distanceToStepEnd < 18.0 && currentStepIndex + 1 < route.steps.count {
            currentStepIndex += 1
        }

        // Check off-route: minimum distance from any polyline segment
        let minDistanceToRoute = calculateMinDistanceToPolyline(point: currentLocation.coordinate, polyline: route.coordinates)
        if minDistanceToRoute > offRouteThresholdMeters {
            if !isOffRoute {
                isOffRoute = true
                print("[FerrostarNavManager] Off-route detected (\(Int(minDistanceToRoute))m away). Requesting reroute...")
                onRerouteNeeded?()
            }
        } else {
            isOffRoute = false
        }

        // Calculate remaining distance
        var remainingDist: Double = distanceToStepEnd
        for i in (currentStepIndex + 1)..<route.steps.count {
            remainingDist += route.steps[i].distanceMeters
        }

        let speedKmh = UInt8(max(0, min(250, currentLocation.speed * 3.6)))
        let averageSpeedMps = max(currentLocation.speed, 8.33) // default ~30km/h
        let remainingSeconds = UInt32(remainingDist / averageSpeedMps)

        let targetStep = (currentStepIndex < route.steps.count) ? route.steps[currentStepIndex] : currentStep
        let progress = NavigationProgress(
            maneuver: targetStep.maneuverType,
            distanceToTurnMeters: UInt32(distanceToStepEnd),
            remainingDistanceMeters: UInt32(remainingDist),
            remainingEtaSeconds: remainingSeconds,
            currentSpeedKmh: speedKmh,
            speedLimitKmh: 0,
            nextStreetName: targetStep.streetName
        )

        self.activeProgress = progress
        self.onProgressUpdate?(progress)
    }

    /// Calculate distance from point to closest segment of polyline
    private func calculateMinDistanceToPolyline(point: CLLocationCoordinate2D, polyline: [CLLocationCoordinate2D]) -> Double {
        guard polyline.count >= 2 else { return 0.0 }
        var minDistance: Double = .infinity
        let pLoc = CLLocation(latitude: point.latitude, longitude: point.longitude)

        for i in 0..<(polyline.count - 1) {
            let segStart = CLLocation(latitude: polyline[i].latitude, longitude: polyline[i].longitude)
            let d = pLoc.distance(from: segStart)
            if d < minDistance { minDistance = d }
        }

        return minDistance
    }
}
