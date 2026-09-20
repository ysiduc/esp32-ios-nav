//
//  DestinationSelectionTests.swift
//  Unit tests for NavigationViewModel destination selection lifecycle:
//  Place Detail generation safety, session token consistency, failure recovery.
//
//  Uses debounceDelay: 0 (no real-time waits for autocomplete).
//  Detail task waits use generous margins to be robust on CI runners.
//

import XCTest
@testable import ESP32NavApp
import CoreLocation

@MainActor
final class DestinationSelectionTests: XCTestCase {

    var mockClient: MockGoongPlacesClient!
    var searchService: GoongSearchService!
    var navSession: NavigationSessionManager!
    var routingService: StubRoutingService!
    var viewModel: NavigationViewModel!

    override func setUp() async throws {
        mockClient    = MockGoongPlacesClient()
        // debounceDelay: 0 — no timing dependencies for autocomplete
        searchService = GoongSearchService(client: mockClient, debounceDelay: 0)
        navSession    = NavigationSessionManager(requestLocationAuthorizationOnInit: false)
        routingService = StubRoutingService()
        viewModel = NavigationViewModel(
            routingService: routingService,
            navSession:     navSession,
            searchService:  searchService,
            bleManager:     nil
        )
    }

    // MARK: - 1. Stale Place Detail is discarded

    func testStale_PlaceDetail_IsDiscarded() async throws {
        // A takes 150ms, B resolves immediately.
        // We select A, then immediately select B.
        // B's detail resolves first; A's stale result must be discarded.
        let controlledService = GoongSearchService(
            client: DelayedDetailClient(aDelay: 150_000_000, bDelay: 0),
            debounceDelay: 0
        )
        let vm = NavigationViewModel(
            routingService: routingService,
            navSession:     navSession,
            searchService:  controlledService,
            bleManager:     nil
        )

        let predA = makeGoongPrediction(placeID: "A", mainText: "Place A")
        let predB = makeGoongPrediction(placeID: "B", mainText: "Place B")

        vm.selectPrediction(predA)  // selection gen = 1
        vm.selectPrediction(predB)  // selection gen = 2 — immediately supersedes A

        // Wait well past both delays (A=150ms+, B=0ms+)
        try await Task.sleep(nanoseconds: 400_000_000)

        // B must win; A's stale detail was discarded by generation check
        XCTAssertEqual(vm.selectedPrediction?.placeID, "B",
                       "Newer prediction B must win; stale A detail must be discarded")
    }

    // MARK: - 2. New selection cancels old placeDetailTask

    func testSelectPrediction_CancelsOldDetailTask() async throws {
        let predA = makeGoongPrediction(placeID: "A-cancel", mainText: "Place A Cancel")
        let predB = makeGoongPrediction(placeID: "B-cancel", mainText: "Place B Cancel")

        // A takes 300ms
        mockClient.detailDelay  = 300_000_000
        mockClient.detailResult = .success(mockClient.makePlace(placeID: "A-cancel", name: "Place A Cancel"))

        viewModel.selectPrediction(predA)
        // Immediately (< A's 300ms) select B (0ms detail)
        mockClient.detailDelay  = 0
        mockClient.detailResult = .success(mockClient.makePlace(placeID: "B-cancel", name: "Place B Cancel"))
        viewModel.selectPrediction(predB)

        // Wait past A's 300ms + margin
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(viewModel.selectedDestination?.placeID, "B-cancel",
                       "Only B destination should be set (A was superseded)")
        XCTAssertEqual(viewModel.selectedPrediction?.placeID, "B-cancel")
    }

    // MARK: - 3. clearSearch while detail pending — no destination set

    func testClearSearch_WhileDetailPending_NoDestinationSet() async throws {
        mockClient.detailDelay = 300_000_000
        let pred = makeGoongPrediction(placeID: "clear-test", mainText: "Some Place Clear")

        viewModel.selectPrediction(pred)
        // Clear before detail resolves
        try await Task.sleep(nanoseconds: 10_000_000)
        viewModel.clearSearch()

        // Wait past detail delay
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertNil(viewModel.selectedDestination,
                     "clearSearch() must prevent stale Place Detail from setting destination")
        XCTAssertNil(viewModel.selectedPrediction)
        XCTAssertEqual(viewModel.searchQuery, "")
    }

    // MARK: - 4. Place Detail token matches autocomplete session token

    func testPlaceDetailToken_MatchesAutocompleteToken() async throws {
        mockClient.autocompleteResult = .success([
            mockClient.makePrediction(placeID: "tok-place-test", mainText: "Token Test Place")
        ])
        // Fire autocomplete to establish session token
        viewModel.updateSearchQuery("Token Test Place")
        try await Task.sleep(nanoseconds: 30_000_000)

        guard let autocompleteToken = mockClient.autocompleteSessionTokens.last else {
            XCTFail("No autocomplete call was made"); return
        }

        let pred = makeGoongPrediction(placeID: "tok-place-test", mainText: "Token Test Place")
        mockClient.detailResult = .success(mockClient.makePlace(placeID: "tok-place-test"))
        mockClient.detailDelay  = 0
        viewModel.selectPrediction(pred)
        try await Task.sleep(nanoseconds: 30_000_000)

        guard let detailToken = mockClient.detailSessionTokens.last else {
            XCTFail("No detail call was made"); return
        }
        XCTAssertEqual(autocompleteToken, detailToken,
                       "Place Detail must use the same session token as autocomplete")
    }

    // MARK: - 5. Place Detail failure shows error, preserves prediction

    func testPlaceDetailFailure_ShowsError_PreservesPrediction() async throws {
        mockClient.detailResult = .failure(GoongSearchError.networkError(URLError(.notConnectedToInternet)))
        mockClient.detailDelay  = 0
        let pred = makeGoongPrediction(placeID: "fail-test", mainText: "Fail Place Test")

        viewModel.selectPrediction(pred)
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertNotNil(viewModel.routeErrorMessage,
                        "Place Detail failure must set routeErrorMessage")
        XCTAssertEqual(viewModel.selectedPrediction?.placeID, "fail-test",
                       "selectedPrediction must be preserved on failure for retry")
        XCTAssertNil(viewModel.selectedDestination,
                     "selectedDestination must not be set on Place Detail failure")
    }

    // MARK: - 6. searchQuery shows prediction mainText immediately

    func testSearchQuery_ShowsMainText_AfterSelection() {
        mockClient.detailDelay = 300_000_000 // Slow detail
        let pred = makeGoongPrediction(placeID: "q-test", mainText: "Hoan Kiem Lake Test")

        viewModel.selectPrediction(pred)
        // searchQuery is updated synchronously before Place Detail resolves
        XCTAssertEqual(viewModel.searchQuery, "Hoan Kiem Lake Test")
    }

    // MARK: - 7. Editing field after selection begins new session

    func testEditQuery_AfterSelection_BeginsFreshSession() async throws {
        mockClient.detailResult = .success(mockClient.makePlace(placeID: "first-sel"))
        mockClient.detailDelay  = 0
        let pred = makeGoongPrediction(placeID: "first-sel", mainText: "First Selected Place")

        viewModel.selectPrediction(pred)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertNotNil(viewModel.selectedDestination,
                        "Destination should be set after successful Place Detail")

        // User edits the text field — should clear old destination
        viewModel.updateSearchQuery("New search after selection")

        XCTAssertNil(viewModel.selectedDestination,
                     "Editing query after selection must clear the old destination")
        XCTAssertNil(viewModel.selectedPrediction)
        XCTAssertEqual(viewModel.searchQuery, "New search after selection")
    }

    // MARK: - 8. endSearchSession rotates token after Place Detail success

    func testEndSearchSession_CalledAfterSuccessfulDetail() async throws {
        mockClient.autocompleteResult = .success([mockClient.makePrediction(placeID: "tok2-sel")])
        viewModel.updateSearchQuery("Token session selection test")
        try await Task.sleep(nanoseconds: 30_000_000)
        let firstToken = mockClient.autocompleteSessionTokens.last ?? ""

        mockClient.detailResult = .success(mockClient.makePlace(placeID: "tok2-sel"))
        mockClient.detailDelay  = 0
        let pred = makeGoongPrediction(placeID: "tok2-sel", mainText: "Token session selection test")
        viewModel.selectPrediction(pred)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertNotNil(viewModel.selectedDestination, "Destination should be set")

        // Now start new search — new session should get different token
        viewModel.updateSearchQuery("Second search session query")
        try await Task.sleep(nanoseconds: 30_000_000)
        let secondToken = mockClient.autocompleteSessionTokens.last ?? ""

        XCTAssertFalse(firstToken.isEmpty)
        XCTAssertFalse(secondToken.isEmpty)
        XCTAssertNotEqual(firstToken, secondToken,
                          "Token must be rotated after successful Place Detail")
    }

    // MARK: - 9. cancelSearch preserves searchQuery

    func testCancelSearch_PreservesSearchQuery() {
        viewModel.updateSearchQuery("Preserved query test")
        viewModel.cancelSearch()
        XCTAssertEqual(viewModel.searchQuery, "Preserved query test",
                       "cancelSearch must not clear searchQuery")
        XCTAssertFalse(viewModel.isSearchActive)
    }

    // MARK: - Helpers

    private func makeGoongPrediction(placeID: String, mainText: String) -> GoongPrediction {
        GoongPrediction(
            id:            placeID,
            placeID:       placeID,
            mainText:      mainText,
            secondaryText: "",
            description:   mainText,
            structuredFormatting: GoongStructuredFormatting(mainText: mainText, secondaryText: ""),
            providerScore: nil,
            providerIndex: 0,
            district:  nil,
            commune:   nil,
            province:  nil
        )
    }
}

// MARK: - DelayedDetailClient (for racing tests)

@MainActor
final class DelayedDetailClient: GoongPlacesClientProtocol {
    let aDelay: UInt64
    let bDelay: UInt64

    init(aDelay: UInt64, bDelay: UInt64) {
        self.aDelay = aDelay
        self.bDelay = bDelay
    }

    func autocomplete(
        query: String, location: CLLocationCoordinate2D?,
        radius: Int, limit: Int, sessionToken: String
    ) async throws -> [GoongRawPrediction] { [] }

    func placeDetail(placeID: String, sessionToken: String) async throws -> GoongPlace {
        let delay = placeID == "A" ? aDelay : bDelay
        if delay > 0 {
            try await Task.sleep(nanoseconds: delay)
        }
        return GoongPlace(
            placeID:          placeID,
            name:             "Place \(placeID)",
            formattedAddress: "Addr \(placeID)",
            location:         GoongLocation(latitude: 21.0, longitude: 105.0),
            types:            []
        )
    }
}

// MARK: - StubRoutingService

@MainActor
final class StubRoutingService: RoutingServiceProtocol {
    var shouldFail = false
    var callCount  = 0

    func calculateRoute(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        costing: String
    ) async throws -> NavRoute {
        callCount += 1
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
