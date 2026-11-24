import Foundation
import CoreLocation
import Combine

/// Main ViewModel orchestrating Search, Valhalla Routing, Ferrostar Navigation, and BLE Dispatch
@MainActor
public final class NavigationViewModel: ObservableObject {
    @Published public var searchService: PhotonSearchService
    @Published public var navManager: FerrostarNavManager
    @Published public var bleManager: BLEManager

    @Published public var selectedDestination: SearchResultItem?
    @Published public var calculatedRoute: NavRoute?
    @Published public var isCalculatingRoute: Bool = false
    @Published public var routeErrorMessage: String?
    @Published public var transportMode: String = "motorcycle" // 'motorcycle', 'auto', 'bicycle'

    @Published public var isSearchActive: Bool = false
    @Published public var showBLEScanner: Bool = false

    private let routingService = ValhallaRoutingService()
    private var cancellables = Set<AnyCancellable>()

    public init() {
        let search = PhotonSearchService()
        let nav = FerrostarNavManager()
        let ble = BLEManager()

        self.searchService = search
        self.navManager = nav
        self.bleManager = ble

        setupBindings()
    }

    private func setupBindings() {
        // Forward progress updates from Ferrostar navigation to BLE packet transmitter
        navManager.onProgressUpdate = { [weak self] progress in
            guard let self = self else { return }
            self.bleManager.sendNavigationPacket(progress)
        }

        // Handle off-route reroute trigger
        navManager.onRerouteNeeded = { [weak self] in
            guard let self = self else { return }
            Task {
                await self.recalculateCurrentRoute()
            }
        }
    }

    /// Select destination from search and calculate route immediately
    public func selectDestination(_ item: SearchResultItem) {
        self.selectedDestination = item
        self.isSearchActive = false
        self.searchService.clear()

        Task {
            await calculateRoute(to: item.coordinate)
        }
    }

    /// Calculate route from user location to target coordinate
    public func calculateRoute(to destination: CLLocationCoordinate2D) async {
        guard let userLoc = navManager.userLocation?.coordinate else {
            routeErrorMessage = "Chưa nhận được tín hiệu định vị GPS"
            return
        }

        isCalculatingRoute = true
        routeErrorMessage = nil

        do {
            let costing = (transportMode == "motorcycle") ? "motorcycle" : ((transportMode == "auto") ? "auto" : "bicycle")
            let result = try await routingService.calculateRoute(from: userLoc, to: destination, costing: costing)
            self.calculatedRoute = result.route
        } catch {
            print("[NavigationViewModel] Routing error: \(error.localizedDescription)")
            self.routeErrorMessage = "Không thể tìm đường đến địa điểm này"
        }

        isCalculatingRoute = false
    }

    /// Recalculate route when diverging from current path
    public func recalculateCurrentRoute() async {
        guard let destination = selectedDestination?.coordinate else { return }
        await calculateRoute(to: destination)
        if let route = calculatedRoute {
            navManager.startNavigation(route: route)
        }
    }

    /// Start active driving turn-by-turn navigation
    public func startNavigation() {
        guard let route = calculatedRoute else { return }
        navManager.startNavigation(route: route)
    }

    /// Stop navigation and reset destination
    public func stopNavigation() {
        navManager.stopNavigation()
        selectedDestination = nil
        calculatedRoute = nil

        // Send a clear packet (arrive code with 0 distance) to clear ESP32 screen
        let endProgress = NavigationProgress(maneuver: .none, nextStreetName: "Chờ kết nối")
        bleManager.sendNavigationPacket(endProgress)
    }
}
