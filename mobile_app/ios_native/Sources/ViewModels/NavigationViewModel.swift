//
//  NavigationViewModel.swift
//  Main view model — wires GoongSearchService → ValhallaRoutingService → NavigationSessionManager → BLE.
//  Observes state changes and drives the UI.
//
//  Search lifecycle:
//    beginSearch()           → isSearchActive = true
//    updateSearchQuery(text) → searchQuery updated; searchService.updateQuery(text) called
//    selectPrediction(pred)  → destinationSelectionGeneration incremented; Place Detail fetched
//    clearSearch()           → all pending tasks cancelled; full reset
//    cancelSearch()          → isSearchActive = false; autocomplete cancelled; searchQuery preserved
//

import Combine
import CoreLocation
import Foundation

@MainActor
public final class NavigationViewModel: ObservableObject {

    // MARK: - Child Services
    public let navSession: NavigationSessionManager
    public let searchService: GoongSearchService
    public let routing: RoutingServiceProtocol
    public let bleManager: BLEManager
    public let rerouteManager: RerouteManager

    // MARK: - Published UI State
    @Published public var showBLEScanner: Bool = false
    @Published public var isSearchActive: Bool = false
    @Published public var isCalculatingRoute: Bool = false
    @Published public var routeErrorMessage: String? = nil
    @Published public var selectedPrediction: GoongPrediction? = nil
    @Published public var selectedDestination: GoongPlace? = nil
    @Published public var transportMode: String = "motorcycle" // "motorcycle" | "auto" | "bicycle" | "pedestrian"

    // MARK: - Route Candidates & Alternatives (P4)
    @Published public var currentTransportMode: NavigationTransportMode = .motorcycle
    @Published public var routeCandidates: [RouteCandidate] = []
    @Published public var selectedRouteCandidateID: String? = nil
    @Published public var currentRoutingProvider: RoutingProvider? = nil
    @Published public var isDegradedRoute: Bool = false
    @Published public var degradedReason: String? = nil

    /// Authoritative source-of-truth for the text shown in the search bar.
    /// Views must bind to this; never derive from predictions or selectedPrediction.
    @Published public var searchQuery: String = ""

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

    // MARK: - Lifecycle & Concurrency Control (Route)
    private var routeRequestGeneration: UInt64 = 0
    private var routeCalculationTask: Task<RouteSet, Error>?

    // MARK: - Lifecycle & Concurrency Control (Search/Destination)
    private var destinationSelectionGeneration: UInt64 = 0
    private var placeDetailTask: Task<Void, Never>?

    public init(
        routingService: RoutingServiceProtocol? = nil,
        navSession: NavigationSessionManager? = nil,
        searchService: GoongSearchService? = nil,
        bleManager: BLEManager? = nil
    ) {
        let session = navSession ?? NavigationSessionManager(requestLocationAuthorizationOnInit: !ProcessInfo.isRunningUnitTests)
        let routing = routingService ?? ValhallaRoutingService.shared
        let search = searchService ?? GoongSearchService()
        let ble = bleManager ?? BLEManager()

        self.navSession = session
        self.searchService = search
        self.routing = routing
        self.bleManager = ble
        self.rerouteManager = RerouteManager(routingService: routing, navSession: session)

        // Forward filtered physical GPS location to Goong search for proximity-biased results
        self.navSession.$filteredLocation
            .compactMap { $0?.coordinate }
            .sink { [weak self] coord in
                self?.searchService.userLocation = coord
            }
            .store(in: &cancellables)

        // Forward navigation progress → BLE ESP32 display
        self.navSession.onProgressUpdate = { [weak self] progress in
            self?.bleManager.sendNavigationPacket(progress)
        }

        // Wire P2 quality-aware off-route decisions directly to RerouteManager (Single Authoritative Path)
        self.navSession.onOffRouteDecision = { [weak self] decision, location in
            guard let self = self else { return }
            let costing = self.valhallaCosting(for: self.transportMode)
            self.rerouteManager.handleObservation(
                location: location,
                decision: decision,
                costing: costing
            )
        }

        // Handle arrival
        self.navSession.onArrived = {
            print("[ViewModel] 🏁 Arrived at destination!")
        }
    }

    // MARK: - Search Flow

    /// Activate the search bar (keyboard focus / expand UI).
    /// Does NOT clear existing searchQuery — allows resuming a previous session.
    public func beginSearch() {
        isSearchActive = true
    }

    /// Update the authoritative search query and trigger debounced autocomplete.
    /// If a destination was already selected, editing the field begins a fresh session:
    /// clears the old destination, route preview, and invalidates pending tasks.
    public func updateSearchQuery(_ text: String) {
        let isNewSearchIntent = (
            selectedPrediction != nil ||
            selectedDestination != nil ||
            placeDetailTask != nil ||
            isCalculatingRoute ||
            navSession.state == .routePreview ||
            navSession.activeRoute != nil
        ) && text != searchQuery

        if isNewSearchIntent {
            // User is editing after a selection or while detail/preview was active — start fresh
            _cancelPendingSelectionTask()
            invalidateRoutePreviewState(clearActivePreview: true, resetLoading: true)
            selectedDestination = nil
            selectedPrediction  = nil
            routeErrorMessage   = nil
            searchService.endSearchSession()
        }
        searchQuery = text
        searchService.updateQuery(text)
    }

    /// Dismiss the search UI without clearing the selected destination or query.
    /// Cancels in-flight autocomplete only (not Place Detail or route calculation).
    public func cancelSearch() {
        isSearchActive = false
        searchService.cancelAutocomplete()
        searchService.clearPredictions()
    }

    /// User selected an autocomplete prediction.
    ///
    /// Flow:
    ///   1. Increment `destinationSelectionGeneration` to invalidate any prior selection.
    ///   2. Set searchQuery to prediction.mainText immediately (search bar shows name).
    ///   3. Hide autocomplete list (cancel + clear predictions), preserve session token.
    ///   4. Fetch Place Detail using the current session token.
    ///   5. On success: set selectedDestination, rotate session token, calculate route.
    ///   6. On failure: show error; preserve selectedPrediction for retry context.
    public func selectPrediction(_ prediction: GoongPrediction) {
        // Cancel prior selection & routing, clear stale preview, candidates, and errors
        _cancelPendingSelectionTask()
        invalidateRoutePreviewState(clearActivePreview: true, resetLoading: true)
        selectedDestination = nil
        routeErrorMessage   = nil

        destinationSelectionGeneration &+= 1
        let mySelGen = destinationSelectionGeneration

        searchQuery        = prediction.mainText
        selectedPrediction = prediction
        isSearchActive     = false

        // Hide autocomplete list but preserve token for the upcoming Place Detail call
        searchService.cancelAutocomplete()
        searchService.clearPredictions()

        placeDetailTask = Task { [weak self] in
            guard let self else { return }
            do {
                let place = try await self.searchService.getPlaceDetail(placeID: prediction.placeID)

                // Generation guard: a newer selection may have superseded this one
                guard !Task.isCancelled,
                      self.destinationSelectionGeneration == mySelGen,
                      self.selectedPrediction?.placeID == prediction.placeID else {
                    print("[ViewModel] Discarding stale Place Detail (gen \(mySelGen) vs \(self.destinationSelectionGeneration))")
                    return
                }

                self.selectedDestination = place
                // Rotate session token now that Place Detail succeeded
                self.searchService.endSearchSession()
                await self.calculateRoute(to: place.location.coordinate)

            } catch is CancellationError {
                // Superseded by newer selection — silent
            } catch {
                guard self.destinationSelectionGeneration == mySelGen else { return }
                self.invalidateRoutePreviewState(clearActivePreview: true, resetLoading: true)
                self.routeErrorMessage = "Không thể lấy thông tin địa điểm: \(error.localizedDescription)"
                print("[ViewModel] Place detail error: \(error)")
                // Preserve selectedPrediction so the user can retry
            }
        }
    }

    /// Select an alternative route candidate in preview mode.
    public func selectRouteCandidate(id: String) {
        guard navSession.state != .navigating else {
            print("[ViewModel] selectRouteCandidate rejected: session is navigating")
            return
        }
        guard let candidate = routeCandidates.first(where: { $0.id == id }) else { return }
        selectedRouteCandidateID = candidate.id
        currentRoutingProvider = candidate.provider
        isDegradedRoute = candidate.isDegradedFallback
        degradedReason = candidate.degradedReason
        navSession.setRoutePreview(candidate.route)
        print("[ViewModel] Switched to candidate \(candidate.label) (\(candidate.id)) provider=\(candidate.provider.rawValue)")
    }

    /// Cancel all pending search/route tasks and reset all search state.
    /// Called when user taps the × button or explicitly cancels the search.
    public func clearSearch() {
        _cancelPendingSelectionTask()
        invalidateRoutePreviewState(clearActivePreview: true, resetLoading: true)

        isSearchActive      = false
        searchQuery         = ""
        selectedPrediction  = nil
        selectedDestination = nil
        routeErrorMessage   = nil

        searchService.resetAll()
    }

    // MARK: - Route Calculation

    /// Calculate route candidates from current GPS location to destination (Preview mode).
    public func calculateRoute(to destination: CLLocationCoordinate2D) async {
        // Cancel any pending preview route calculation and increment request generation
        _cancelPendingRouteCalculation(resetLoading: false)
        let thisRequestGen = routeRequestGeneration

        // Immediately invalidate prior route candidate and preview state
        resetRouteCandidateState()
        if navSession.state != .navigating {
            navSession.clearRoute()
        }

        guard let userCoord = navSession.userLocation?.coordinate else {
            isCalculatingRoute = false
            routeErrorMessage = "Chưa nhận được tín hiệu định vị GPS"
            return
        }

        isCalculatingRoute = true
        routeErrorMessage  = nil

        currentTransportMode = NavigationTransportMode(costingValue: transportMode)
        let profile = RoutingProfile.profile(for: currentTransportMode)
        let request = RoutingRequest(
            origin: userCoord,
            destination: destination,
            profile: profile,
            requestedAlternatives: profile.maxAlternatives
        )

        let task = Task<RouteSet, Error> {
            try Task.checkCancellation()
            let routeSet = try await routing.calculateRoutes(request: request)
            try Task.checkCancellation()
            return routeSet
        }
        routeCalculationTask = task

        do {
            let routeSet = try await task.value

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

            self.routeCandidates = routeSet.candidates
            if let primary = routeSet.candidates.first {
                self.selectedRouteCandidateID = primary.id
                self.currentRoutingProvider = primary.provider
                self.isDegradedRoute = primary.isDegradedFallback
                self.degradedReason = primary.degradedReason
                self.navSession.setRoutePreview(primary.route)
                print("[ViewModel] Set preview to primary candidate (\(primary.id)), \(routeSet.candidates.count) total candidates")
            }

            self.isCalculatingRoute = false
        } catch {
            guard !Task.isCancelled else { return }
            guard self.routeRequestGeneration == thisRequestGen else { return }
            guard self.navSession.state != .navigating else { return }

            self.isCalculatingRoute = false
            self.resetRouteCandidateState()
            self.navSession.clearRoute()
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
        guard let candidateID = selectedRouteCandidateID,
              let selectedCandidate = routeCandidates.first(where: { $0.id == candidateID }) else {
            routeErrorMessage = "Chưa chọn lộ trình để bắt đầu điều hướng"
            print("[ViewModel] startNavigation rejected: no active route candidate selected")
            return
        }

        guard selectedCandidate.requestedMode == currentTransportMode else {
            routeErrorMessage = "Lộ trình không phù hợp với phương tiện đã chọn (\(currentTransportMode.displayName))"
            print("[ViewModel] startNavigation rejected: mode mismatch (\(selectedCandidate.requestedMode) vs \(currentTransportMode))")
            return
        }

        guard let place = selectedDestination else {
            routeErrorMessage = "Không xác định được điểm đến"
            print("[ViewModel] startNavigation rejected: no selectedDestination available")
            return
        }

        // Cancel any pending preview route calculation and invalidate old preview requests
        _cancelPendingRouteCalculation(resetLoading: false)
        rerouteManager.cancel()

        let destination = NavigationDestination(
            coordinate: place.location.coordinate,
            name: place.name,
            placeID: place.placeID
        )

        navSession.startNavigation(route: selectedCandidate.route, destination: destination)
    }

    public func stopNavigation() {
        // Cancel all pending route and reroute tasks
        _cancelPendingRouteCalculation(resetLoading: true)
        _cancelPendingSelectionTask()
        rerouteManager.cancel()

        navSession.stopNavigation()
        navSession.clearRoute()
        selectedDestination = nil
        selectedPrediction  = nil
        searchQuery         = ""

        resetRouteCandidateState()

        let end = NavigationProgress(maneuver: .none, nextStreetName: "Chờ kết nối")
        bleManager.sendNavigationPacket(end)
    }

    public func recalculateForTransportMode() {
        currentTransportMode = NavigationTransportMode(costingValue: transportMode)
        if navSession.state == .navigating {
            rerouteManager.requestTransportModeReroute(costing: currentTransportMode.rawValue)
        } else {
            invalidateRoutePreviewState(clearActivePreview: true, resetLoading: false)
            if let dest = selectedDestination?.location.coordinate {
                Task { await calculateRoute(to: dest) }
            }
        }
    }

    // MARK: - Private Helpers

    private func resetRouteCandidateState() {
        routeCandidates          = []
        selectedRouteCandidateID = nil
        currentRoutingProvider   = nil
        isDegradedRoute          = false
        degradedReason           = nil
    }

    private func invalidateRoutePreviewState(clearActivePreview: Bool, resetLoading: Bool) {
        _cancelPendingRouteCalculation(resetLoading: resetLoading)
        resetRouteCandidateState()
        if clearActivePreview && navSession.state != .navigating {
            navSession.clearRoute()
        }
    }

    private func _cancelPendingSelectionTask() {
        placeDetailTask?.cancel()
        placeDetailTask = nil
        destinationSelectionGeneration &+= 1
    }

    private func _cancelPendingRouteCalculation(resetLoading: Bool = true) {
        routeCalculationTask?.cancel()
        routeCalculationTask = nil
        routeRequestGeneration &+= 1
        if resetLoading {
            isCalculatingRoute = false
        }
    }

    private func valhallaCosting(for mode: String) -> String {
        let tm = NavigationTransportMode(costingValue: mode)
        return RoutingProfile.profile(for: tm).valhallaCosting
    }
}
