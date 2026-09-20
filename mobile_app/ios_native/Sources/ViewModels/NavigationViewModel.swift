//
//  NavigationViewModel.swift
//  Main view model — wires GoongSearchService → ValhallaRoutingService → NavigationSessionManager → BLE.
//  Observes state changes and drives the UI.
//

import Combine
import CoreLocation
import Foundation

@MainActor
public final class NavigationViewModel: ObservableObject {

    // MARK: - Child Services
    public let navSession    = NavigationSessionManager()
    public let searchService = GoongSearchService()
    public let routing       = ValhallaRoutingService.shared
    public let bleManager    = BLEManager()
    public let rerouteManager: RerouteManager

    // MARK: - Published UI State
    @Published public var showBLEScanner: Bool = false
    @Published public var isSearchActive: Bool = false
    @Published public var isCalculatingRoute: Bool = false
    @Published public var routeErrorMessage: String? = nil
    @Published public var selectedPrediction: GoongPrediction? = nil
    @Published public var selectedDestination: GoongPlace? = nil
    @Published public var transportMode: String = "motorcycle" // "motorcycle" | "auto" | "bicycle" | "pedestrian"

    // Convenience mirrors from navSession
    public var state: NavigationState { navSession.state }
    public var activeRoute: NavRoute?  { navSession.activeRoute }
    public var progress: NavigationProgress { navSession.activeProgress }
    // MARK: - Location Pipeline Properties
    public var rawLocation: CLLocation? { navSession.rawLocation }
    public var filteredLocation: CLLocation? { navSession.filteredLocation }
    public var matchedLocation: CLLocationCoordinate2D? { navSession.matchedLocation }
    public var currentProjection: RouteProjection? { navSession.currentProjection }

    // Backwards-compatible aliases
    public var userLocation: CLLocation? { navSession.userLocation }
    public var snappedLocation: CLLocationCoordinate2D? { navSession.snappedLocation }
    public var heading: Double { navSession.heading }
    public var isNavigating: Bool { navSession.state == .navigating }

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Lifecycle & Concurrency Control
    private var routeRequestGeneration: UInt64 = 0
    private var rerouteRequestGeneration: UInt64 = 0
    private var routeCalculationTask: Task<NavRoute, Error>?
    private var rerouteTask: Task<NavRoute, Error>?

    public init(routingService: RoutingServiceProtocol = ValhallaRoutingService.shared) {
        let reroute = RerouteManager(routingService: routingService, navSession: navSession)
        self.rerouteManager = reroute

        // Forward filtered physical GPS location to Goong search for proximity-biased results
        navSession.$filteredLocation
            .compactMap { $0?.coordinate }
            .sink { [weak self] coord in
                self?.searchService.userLocation = coord
            }
            .store(in: &cancellables)

        // Forward navigation progress → BLE ESP32 display
        navSession.onProgressUpdate = { [weak self] progress in
            self?.bleManager.sendNavigationPacket(progress)
        }

        // Wire P2 quality-aware off-route decisions directly to RerouteManager
        navSession.onOffRouteDecision = { [weak self] decision, location in
            guard let self = self else { return }
            let costing = self.valhallaCosting(for: self.transportMode)
            self.rerouteManager.handleObservation(
                location: location,
                decision: decision,
                costing: costing
            )
        }

        // Auto-reroute callback fallback
        navSession.onRerouteNeeded = { [weak self] in
            Task { @MainActor in
                await self?.recalculateCurrentRoute()
            }
        }

        // Handle arrival
        navSession.onArrived = {
            print("[ViewModel] 🏁 Arrived at destination!")
        }
    }

    // MARK: - Search Flow

    public func activateSearch() {
        isSearchActive = true
    }

    public func deactivateSearch() {
        isSearchActive = false
        searchService.clear()
    }

    /// User selected a Goong autocomplete prediction.
    /// Fetches Place Detail (lat/lng) then calculates route.
    public func selectPrediction(_ prediction: GoongPrediction) {
        selectedPrediction = prediction
        isSearchActive     = false
        searchService.clear()

        Task {
            do {
                let place = try await searchService.getPlaceDetail(placeID: prediction.placeID)
                self.selectedDestination = place
                await self.calculateRoute(to: place.location.coordinate)
            } catch {
                self.routeErrorMessage = "Không thể lấy thông tin địa điểm: \(error.localizedDescription)"
                print("[ViewModel] Place detail error: \(error)")
            }
        }
    }

    // MARK: - Route Calculation

    /// Calculate route from current GPS location to destination (Preview mode).
    public func calculateRoute(to destination: CLLocationCoordinate2D) async {
        // Cancel any pending preview route calculation and increment request generation
        routeCalculationTask?.cancel()
        routeRequestGeneration &+= 1
        let thisRequestGen = routeRequestGeneration

        guard let userCoord = navSession.userLocation?.coordinate else {
            routeErrorMessage = "Chưa nhận được tín hiệu định vị GPS"
            return
        }

        isCalculatingRoute = true
        routeErrorMessage  = nil

        let costing = valhallaCosting(for: transportMode)

        let task = Task<NavRoute, Error> {
            try Task.checkCancellation()
            let route = try await routing.calculateRoute(
                from: userCoord,
                to: destination,
                costing: costing
            )
            try Task.checkCancellation()
            return route
        }
        routeCalculationTask = task

        do {
            let route = try await task.value

            // Post-await validations:
            guard !Task.isCancelled else {
                print("[ViewModel] Route calculation cancelled (gen \(thisRequestGen))")
                return
            }
            guard self.routeRequestGeneration == thisRequestGen else {
                print("[ViewModel] Discarding stale route calculation (gen \(thisRequestGen) != current \(self.routeRequestGeneration))")
                return
            }
            guard self.navSession.state != .navigating else {
                print("[ViewModel] Discarding route preview: session is navigating")
                return
            }

            self.navSession.setRoutePreview(route)
            self.isCalculatingRoute = false
            print("[ViewModel] Route: \(route.formattedDistance), \(route.formattedDuration), \(route.steps.count) steps")
        } catch {
            guard !Task.isCancelled else { return }
            guard self.routeRequestGeneration == thisRequestGen else { return }
            guard self.navSession.state != .navigating else { return }

            self.isCalculatingRoute = false
            self.routeErrorMessage = "Không thể tìm đường: \(error.localizedDescription)"
            print("[ViewModel] Routing error: \(error)")
        }
    }

    /// Reroute from current position to active navigation destination (triggered on off-route).
    /// Safe lifecycle: captures session & reroute generation, cancels superseded reroutes (Strategy B),
    /// and commits directly via replaceActiveRoute without touching route preview or resetting session identity.
    public func recalculateCurrentRoute() async {
        guard navSession.state == .navigating else {
            print("[ViewModel] Skipping reroute: navigation session not active")
            return
        }
        guard let origin = navSession.filteredLocation?.coordinate ?? navSession.userLocation?.coordinate else {
            print("[ViewModel] Skipping reroute: no GPS coordinate available")
            return
        }
        let costing = valhallaCosting(for: transportMode)
        rerouteManager.startReroute(reason: .offRoute, origin: origin, costing: costing)
    }

    // MARK: - Navigation Control

    public func startNavigation() {
        guard let route = navSession.activeRoute else { return }
        guard let place = selectedDestination else {
            routeErrorMessage = "Không xác định được điểm đến"
            print("[ViewModel] startNavigation rejected: no selectedDestination available")
            return
        }

        // Cancel any pending preview route calculation and invalidate old preview requests
        routeCalculationTask?.cancel()
        routeCalculationTask = nil
        routeRequestGeneration &+= 1
        rerouteManager.cancel()

        let destination = NavigationDestination(
            coordinate: place.location.coordinate,
            name: place.name,
            placeID: place.placeID
        )

        navSession.startNavigation(route: route, destination: destination)
    }

    public func stopNavigation() {
        // Cancel all pending route and reroute tasks
        routeCalculationTask?.cancel()
        routeCalculationTask = nil
        routeRequestGeneration &+= 1

        rerouteTask?.cancel()
        rerouteTask = nil
        rerouteRequestGeneration &+= 1
        rerouteManager.cancel()

        navSession.stopNavigation()
        navSession.clearRoute()
        selectedDestination = nil
        selectedPrediction  = nil
        isCalculatingRoute  = false

        let end = NavigationProgress(maneuver: .none, nextStreetName: "Chờ kết nối")
        bleManager.sendNavigationPacket(end)
    }

    public func recalculateForTransportMode() {
        if navSession.state == .navigating {
            let costing = valhallaCosting(for: transportMode)
            rerouteManager.requestTransportModeReroute(costing: costing)
        } else if let dest = selectedDestination?.location.coordinate {
            Task { await calculateRoute(to: dest) }
        }
    }

    // MARK: - Helpers

    private func valhallaCosting(for mode: String) -> String {
        switch mode {
        case "auto":       return "auto"
        case "bicycle":    return "bicycle"
        case "pedestrian": return "pedestrian"
        default:           return "motorcycle"
        }
    }
}
