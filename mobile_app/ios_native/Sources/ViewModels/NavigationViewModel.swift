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
    public var userLocation: CLLocation? { navSession.userLocation }
    public var snappedLocation: CLLocationCoordinate2D? { navSession.snappedLocation }
    public var heading: Double { navSession.heading }
    public var isNavigating: Bool { navSession.state == .navigating }

    private var cancellables = Set<AnyCancellable>()

    public init() {
        // Forward GPS location to Goong search for proximity-biased results
        navSession.$userLocation
            .compactMap { $0?.coordinate }
            .sink { [weak self] coord in
                self?.searchService.userLocation = coord
            }
            .store(in: &cancellables)

        // Forward navigation progress → BLE ESP32 display
        navSession.onProgressUpdate = { [weak self] progress in
            self?.bleManager.sendNavigationPacket(progress)
        }

        // Auto-reroute when off-route detected
        navSession.onRerouteNeeded = { [weak self] in
            Task { await self?.recalculateCurrentRoute() }
        }

        // Handle arrival
        navSession.onArrived = { [weak self] in
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

    /// Calculate route from current GPS location to destination.
    public func calculateRoute(to destination: CLLocationCoordinate2D) async {
        guard let userCoord = navSession.userLocation?.coordinate else {
            routeErrorMessage = "Chưa nhận được tín hiệu định vị GPS"
            return
        }

        isCalculatingRoute  = true
        routeErrorMessage   = nil

        let costing = valhallaCosting(for: transportMode)

        do {
            let route = try await routing.calculateRoute(
                from: userCoord,
                to: destination,
                costing: costing
            )
            navSession.setRoutePreview(route)
            print("[ViewModel] Route: \(route.formattedDistance), \(route.formattedDuration), \(route.steps.count) steps")
        } catch {
            routeErrorMessage = "Không thể tìm đường: \(error.localizedDescription)"
            print("[ViewModel] Routing error: \(error)")
        }

        isCalculatingRoute = false
    }

    /// Reroute from current position to original destination (triggered on off-route).
    public func recalculateCurrentRoute() async {
        guard let dest = selectedDestination?.location.coordinate else { return }
        print("[ViewModel] 🔄 Rerouting from current position…")
        await calculateRoute(to: dest)
        if let route = navSession.activeRoute {
            navSession.startNavigation(route: route)
        }
    }

    // MARK: - Navigation Control

    public func startNavigation() {
        guard let route = navSession.activeRoute else { return }
        navSession.startNavigation(route: route)
    }

    public func stopNavigation() {
        navSession.stopNavigation()
        navSession.clearRoute()
        selectedDestination = nil
        selectedPrediction  = nil
        let end = NavigationProgress(maneuver: .none, nextStreetName: "Chờ kết nối")
        bleManager.sendNavigationPacket(end)
    }

    public func recalculateForTransportMode() {
        guard let dest = selectedDestination?.location.coordinate else { return }
        Task { await calculateRoute(to: dest) }
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
