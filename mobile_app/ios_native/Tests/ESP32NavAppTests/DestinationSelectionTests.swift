//
//  DestinationSelectionTests.swift
//  Unit tests for NavigationViewModel destination selection lifecycle:
//  Place Detail generation safety, failure recovery, race safety, and cancellation.
//

import CoreLocation
import XCTest
@testable import ESP32NavApp

@MainActor
final class DestinationSelectionTests: XCTestCase {

    var searchService: MockPlaceSearchService!
    var navSession: NavigationSessionManager!
    var routingService: StubRoutingService!
    var viewModel: NavigationViewModel!

    override func setUp() async throws {
        searchService  = MockPlaceSearchService()
        navSession     = NavigationSessionManager(requestLocationAuthorizationOnInit: false)
        navSession.userLocation = CLLocation(latitude: 21.0, longitude: 105.8)
        routingService = StubRoutingService()
        viewModel      = NavigationViewModel(
            routingService: routingService,
            navSession:     navSession,
            searchService:  searchService,
            bleManager:     nil
        )
    }

    private func makePrediction(id: String, title: String) -> SearchPrediction {
        SearchPrediction(id: id, title: title, subtitle: "Việt Nam")
    }

    private func waitForPendingDetails(count: Int = 1) async throws {
        for _ in 0..<100 {
            if searchService.pendingDetails.count >= count { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func waitForPendingRoutes(count: Int = 1) async throws {
        for _ in 0..<100 {
            if routingService.pendingRoutes.count >= count { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - 1. Stale Place Detail is discarded

    func testStale_PlaceDetail_IsDiscarded() async throws {
        // A takes 150ms, B resolves immediately.
        searchService.onResolve = { pred in
            if pred.id == "A" {
                try await Task.sleep(nanoseconds: 150_000_000)
            }
            return self.searchService.makePlace(id: pred.id, name: pred.title)
        }

        let predA = makePrediction(id: "A", title: "Place A")
        let predB = makePrediction(id: "B", title: "Place B")

        viewModel.selectPrediction(predA)  // selection gen = 1
        viewModel.selectPrediction(predB)  // selection gen = 2 — immediately supersedes A

        try await Task.sleep(nanoseconds: 350_000_000)

        // B must win; A's stale detail was discarded by generation check
        XCTAssertEqual(viewModel.selectedPrediction?.id, "B",
                       "Newer prediction B must win; stale A detail must be discarded")
    }

    // MARK: - 2. New selection cancels old placeDetailTask

    func testSelectPrediction_CancelsOldDetailTask() async throws {
        let predA = makePrediction(id: "A-cancel", title: "Place A Cancel")
        let predB = makePrediction(id: "B-cancel", title: "Place B Cancel")

        searchService.onResolve = { pred in
            if pred.id == "A-cancel" {
                try await Task.sleep(nanoseconds: 300_000_000)
            }
            return self.searchService.makePlace(id: pred.id, name: pred.title)
        }

        viewModel.selectPrediction(predA)
        // Immediately (< A's 300ms) select B (0ms detail)
        viewModel.selectPrediction(predB)

        try await Task.sleep(nanoseconds: 450_000_000)

        XCTAssertEqual(viewModel.selectedDestination?.id, "B-cancel",
                       "Only B destination should be set (A was superseded)")
        XCTAssertEqual(viewModel.selectedPrediction?.id, "B-cancel")
    }

    // MARK: - 3. clearSearch while detail pending — no destination set

    func testClearSearch_WhileDetailPending_NoDestinationSet() async throws {
        searchService.resolveDelayNanoseconds = 300_000_000
        let pred = makePrediction(id: "clear-test", title: "Some Place Clear")

        viewModel.selectPrediction(pred)
        try await Task.sleep(nanoseconds: 10_000_000)
        viewModel.clearSearch()

        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertNil(viewModel.selectedDestination,
                     "clearSearch() must prevent stale Place Detail from setting destination")
        XCTAssertNil(viewModel.selectedPrediction)
        XCTAssertEqual(viewModel.searchQuery, "")
    }

    // MARK: - 4. Place resolution receives selected prediction

    func testPlaceResolution_ReceivesSelectedPrediction() async throws {
        let pred = makePrediction(id: "tok-place-test", title: "Token Test Place")
        viewModel.selectPrediction(pred)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(searchService.resolveCalls.last?.id, "tok-place-test")
        XCTAssertEqual(viewModel.selectedDestination?.id, "tok-place-test")
    }

    // MARK: - 5. Place Detail failure shows error, preserves prediction

    func testPlaceDetailFailure_ShowsError_PreservesPrediction() async throws {
        searchService.resolveResult = .failure(URLError(.notConnectedToInternet))
        let pred = makePrediction(id: "fail-test", title: "Fail Place Test")

        viewModel.selectPrediction(pred)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNotNil(viewModel.routeErrorMessage,
                        "Place Detail failure must set routeErrorMessage")
        XCTAssertEqual(viewModel.selectedPrediction?.id, "fail-test",
                       "selectedPrediction must be preserved on failure for retry")
        XCTAssertNil(viewModel.selectedDestination,
                     "selectedDestination must not be set on Place Detail failure")
    }

    // MARK: - 6. searchQuery shows prediction mainText immediately

    func testSearchQuery_ShowsMainText_AfterSelection() {
        searchService.resolveDelayNanoseconds = 300_000_000 // Slow detail
        let pred = makePrediction(id: "q-test", title: "Hoan Kiem Lake Test")

        viewModel.selectPrediction(pred)
        // searchQuery is updated synchronously before Place Detail resolves
        XCTAssertEqual(viewModel.searchQuery, "Hoan Kiem Lake Test")
    }

    // MARK: - 7. Editing field after selection begins new session

    func testEditQuery_AfterSelection_BeginsFreshSession() async throws {
        let pred = makePrediction(id: "first-sel", title: "First Selected Place")

        viewModel.selectPrediction(pred)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNotNil(viewModel.selectedDestination,
                        "Destination should be set after successful Place Detail")

        // User edits the text field — should clear old destination
        viewModel.updateSearchQuery("New search after selection")

        XCTAssertNil(viewModel.selectedDestination,
                     "Editing query after selection must clear the old destination")
        XCTAssertNil(viewModel.selectedPrediction)
        XCTAssertEqual(viewModel.searchQuery, "New search after selection")
    }

    // MARK: - 8. cancelSearch preserves searchQuery

    func testCancelSearch_PreservesSearchQuery() {
        viewModel.updateSearchQuery("Preserved query test")
        viewModel.cancelSearch()
        XCTAssertEqual(viewModel.searchQuery, "Preserved query test",
                       "cancelSearch must not clear searchQuery")
        XCTAssertFalse(viewModel.isSearchActive)
    }

    // MARK: - 9. Pending Detail cancellation on new query

    func testNewQuery_CancelsPendingDetail_AndDiscardsLateDetail() async throws {
        searchService.useContinuationForDetail = true
        let predA = makePrediction(id: "pred-A", title: "Place A")

        viewModel.selectPrediction(predA)
        try await waitForPendingDetails(count: 1)

        XCTAssertEqual(searchService.pendingDetails.count, 1)

        // User types new query
        viewModel.updateSearchQuery("B")

        XCTAssertNil(viewModel.selectedPrediction, "New query must clear selectedPrediction")
        XCTAssertNil(viewModel.selectedDestination, "New query must clear selectedDestination")

        // Late detail resolution
        let placeA = searchService.makePlace(id: "pred-A", name: "Place A")
        searchService.resumeDetail(at: 0, with: .success(placeA))
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertNil(viewModel.selectedPrediction, "Late detail must be discarded")
        XCTAssertNil(viewModel.selectedDestination, "Late detail must not set destination")
        XCTAssertEqual(routingService.callCount, 0, "No route calculation should occur for discarded detail")
    }

    // MARK: - 10. Route race between destinations

    func testRouteRace_DestinationAStartsRouteA_SelectB_RouteBWins_LateRouteADiscarded() async throws {
        routingService.useContinuation = true

        let predA = makePrediction(id: "A", title: "Place A")
        let coordA = CLLocationCoordinate2D(latitude: 21.05, longitude: 105.85)
        searchService.onResolve = { pred in
            if pred.id == "A" {
                return ResolvedPlace(id: "A", name: "Place A", formattedAddress: "Addr A", coordinate: coordA)
            } else {
                return ResolvedPlace(id: "B", name: "Place B", formattedAddress: "Addr B", coordinate: CLLocationCoordinate2D(latitude: 21.10, longitude: 105.90))
            }
        }

        viewModel.selectPrediction(predA)
        try await waitForPendingRoutes(count: 1)

        let predB = makePrediction(id: "B", title: "Place B")
        viewModel.selectPrediction(predB)
        try await waitForPendingRoutes(count: 2)

        // Route B resolves first
        let routeB = NavRoute(
            coordinates: [CLLocationCoordinate2D(latitude: 21.0, longitude: 105.8), CLLocationCoordinate2D(latitude: 21.10, longitude: 105.90)],
            steps: [],
            totalDistanceMeters: 5000,
            totalDurationSeconds: 600
        )
        routingService.resumeRoute(at: 1, with: routeB)
        for _ in 0..<100 {
            if viewModel.selectedDestination?.id == "B" && viewModel.navSession.activeRoute != nil { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(viewModel.selectedPrediction?.id, "B")
        XCTAssertEqual(viewModel.selectedDestination?.id, "B")
        XCTAssertEqual(viewModel.navSession.activeRoute?.totalDistanceMeters, 5000)

        // Route A completes late (resume index 0)
        let routeA = NavRoute(
            coordinates: [CLLocationCoordinate2D(latitude: 21.0, longitude: 105.8), coordA],
            steps: [],
            totalDistanceMeters: 1000,
            totalDurationSeconds: 120
        )
        routingService.resumeRoute(at: 0, with: routeA)
        try await Task.sleep(nanoseconds: 30_000_000)

        // Verify: Route A cannot overwrite Route B!
        XCTAssertEqual(viewModel.selectedPrediction?.id, "B")
        XCTAssertEqual(viewModel.selectedDestination?.id, "B")
        XCTAssertEqual(viewModel.navSession.activeRoute?.totalDistanceMeters, 5000,
                       "Stale Route A calculation must not overwrite active Route B preview")
    }

    // MARK: - 11. clearSearch while detail pending

    func testClearSearch_WhileDetailPending_CancelsAndCleansState() async throws {
        searchService.useContinuationForDetail = true
        let predA = makePrediction(id: "clear-detail-id", title: "Detail Pending Place")

        viewModel.selectPrediction(predA)
        try await waitForPendingDetails(count: 1)

        XCTAssertEqual(searchService.pendingDetails.count, 1)

        viewModel.clearSearch()

        XCTAssertNil(viewModel.selectedPrediction)
        XCTAssertNil(viewModel.selectedDestination)
        XCTAssertEqual(viewModel.searchQuery, "")

        let place = searchService.makePlace(id: "clear-detail-id")
        searchService.resumeDetail(at: 0, with: .success(place))
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertNil(viewModel.selectedPrediction)
        XCTAssertNil(viewModel.selectedDestination)
        XCTAssertEqual(routingService.callCount, 0)
    }

    // MARK: - 12. clearSearch while route pending

    func testClearSearch_WhileRoutePending_CancelsAndCleansState() async throws {
        routingService.useContinuation = true
        let pred = makePrediction(id: "clear-route-id", title: "Route Pending Place")

        viewModel.selectPrediction(pred)
        try await waitForPendingRoutes(count: 1)

        XCTAssertEqual(routingService.pendingRoutes.count, 1)

        viewModel.clearSearch()

        XCTAssertNil(viewModel.selectedPrediction)
        XCTAssertNil(viewModel.selectedDestination)
        XCTAssertNil(viewModel.navSession.activeRoute)

        let route = NavRoute(coordinates: [], steps: [], totalDistanceMeters: 200, totalDurationSeconds: 30)
        routingService.resumeRoute(at: 0, with: route)
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertNil(viewModel.navSession.activeRoute, "Route preview must remain nil after clearSearch")
    }
}

// MARK: - StubRoutingService

@MainActor
final class StubRoutingService: RoutingServiceProtocol {
    var shouldFail = false
    var callCount  = 0

    var useContinuation = false
    struct PendingRoute {
        let destination: CLLocationCoordinate2D
        let continuation: CheckedContinuation<NavRoute, Error>
    }
    private(set) var pendingRoutes: [PendingRoute] = []

    func resumeRoute(at index: Int = 0, with route: NavRoute) {
        guard index < pendingRoutes.count else { return }
        let pending = pendingRoutes.remove(at: index)
        pending.continuation.resume(returning: route)
    }

    func calculateRoute(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        costing: String
    ) async throws -> NavRoute {
        callCount += 1
        if useContinuation {
            return try await withCheckedThrowingContinuation { cont in
                pendingRoutes.append(PendingRoute(destination: destination, continuation: cont))
            }
        }
        if shouldFail { throw URLError(.networkConnectionLost) }
        let step = NavStep(
            coordinate:       origin,
            distanceMeters:   100,
            durationSeconds:  10,
            streetName:       "Stub St",
            maneuverType:     .straight,
            instruction:      "Go straight",
            beginShapeIndex:  0,
            endShapeIndex:    1
        )
        return NavRoute(
            coordinates:          [origin, destination],
            steps:                [step],
            totalDistanceMeters:  100,
            totalDurationSeconds: 10
        )
    }
}
