//
//  DestinationSelectionTests.swift
//  Unit tests for NavigationViewModel destination selection lifecycle:
//  Place Detail generation safety, session token consistency, failure recovery.
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
        mockClient     = MockGoongPlacesClient()
        searchService  = GoongSearchService(client: mockClient)
        navSession     = NavigationSessionManager(requestLocationAuthorizationOnInit: false)
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
        let predictionA = makeGoongPrediction(placeID: "A", mainText: "Place A")
        let predictionB = makeGoongPrediction(placeID: "B", mainText: "Place B")

        // Set up: selection A takes a long time; B resolves immediately.
        mockClient.detailDelay = 0

        // Override to differentiate A vs B
        let controlledService = GoongSearchService(client: DelayedDetailClient(
            aDelay: 100_000_000, // A resolves in 100ms
            bDelay: 0            // B resolves immediately
        ))
        let vm = NavigationViewModel(
            routingService: routingService,
            navSession:     navSession,
            searchService:  controlledService,
            bleManager:     nil
        )

        vm.selectPrediction(predictionA)  // selection gen = 1
        try await Task.sleep(nanoseconds: 10_000_000) // < A's 100ms
        vm.selectPrediction(predictionB)  // selection gen = 2

        // Wait for B to resolve and then A to arrive (A should be discarded)
        try await Task.sleep(nanoseconds: 200_000_000)

        // B should be the destination — A's stale detail discarded
        XCTAssertEqual(vm.selectedPrediction?.placeID, "B",
                       "Newer prediction B must win; stale A must be discarded")
    }

    // MARK: - 2. New search clears old placeDetailTask

    func testSelectPrediction_CancelsOldDetailTask() async throws {
        let predA = makeGoongPrediction(placeID: "A", mainText: "Place A")
        let predB = makeGoongPrediction(placeID: "B", mainText: "Place B")

        // A takes long time
        mockClient.detailDelay = 200_000_000
        mockClient.detailResult = .success(mockClient.makePlace(placeID: "A", name: "Place A"))

        viewModel.selectPrediction(predA)
        try await Task.sleep(nanoseconds: 10_000_000)

        // Immediately select B
        mockClient.detailDelay = 0
        mockClient.detailResult = .success(mockClient.makePlace(placeID: "B", name: "Place B"))
        viewModel.selectPrediction(predB)

        try await Task.sleep(nanoseconds: 100_000_000)

        // Only B's destination should be set
        XCTAssertEqual(viewModel.selectedDestination?.placeID, "B")
        XCTAssertEqual(viewModel.selectedPrediction?.placeID,  "B")
    }

    // MARK: - 3. clearSearch while detail pending — no destination set

    func testClearSearch_WhileDetailPending_NoDestinationSet() async throws {
        mockClient.detailDelay = 200_000_000
        let pred = makeGoongPrediction(placeID: "X", mainText: "Some Place")

        viewModel.selectPrediction(pred)
        try await Task.sleep(nanoseconds: 10_000_000)
        viewModel.clearSearch()

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(viewModel.selectedDestination,
                     "clearSearch() must prevent stale Place Detail from setting destination")
        XCTAssertNil(viewModel.selectedPrediction)
        XCTAssertEqual(viewModel.searchQuery, "")
    }

    // MARK: - 4. Place Detail token matches autocomplete session token

    func testPlaceDetailToken_MatchesAutocompleteToken() async throws {
        mockClient.autocompleteResult = .success([
            mockClient.makePrediction(placeID: "tok-place", mainText: "Token Test")
        ])

        // Fire autocomplete to establish the session token
        viewModel.updateSearchQuery("Token Test")
        try await Task.sleep(nanoseconds: 350_000_000) // wait for debounce

        let autocompleteToken = mockClient.autocompleteSessionTokens.last!

        // Select prediction
        let pred = makeGoongPrediction(placeID: "tok-place", mainText: "Token Test")
        mockClient.detailResult = .success(mockClient.makePlace(placeID: "tok-place"))
        viewModel.selectPrediction(pred)
        try await Task.sleep(nanoseconds: 50_000_000)

        let detailToken = mockClient.detailSessionTokens.last!
        XCTAssertEqual(autocompleteToken, detailToken,
                       "Place Detail must use the same session token as autocomplete")
    }

    // MARK: - 5. Place Detail failure shows error, preserves prediction

    func testPlaceDetailFailure_ShowsError_PreservesPrediction() async throws {
        mockClient.detailResult = .failure(GoongSearchError.networkError(URLError(.notConnectedToInternet)))
        mockClient.detailDelay  = 0
        let pred = makeGoongPrediction(placeID: "fail-place", mainText: "Fail Place")

        viewModel.selectPrediction(pred)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNotNil(viewModel.routeErrorMessage,
                        "Place Detail failure must set routeErrorMessage")
        XCTAssertEqual(viewModel.selectedPrediction?.placeID, "fail-place",
                       "selectedPrediction must be preserved on failure for retry")
        XCTAssertNil(viewModel.selectedDestination,
                     "selectedDestination must not be set on Place Detail failure")
    }

    // MARK: - 6. searchQuery shows prediction mainText after selection

    func testSearchQuery_ShowsMainText_AfterSelection() async throws {
        mockClient.detailDelay = 100_000_000
        let pred = makeGoongPrediction(placeID: "q-place", mainText: "Hoan Kiem Lake")

        viewModel.selectPrediction(pred)
        // searchQuery updated synchronously before Place Detail resolves
        XCTAssertEqual(viewModel.searchQuery, "Hoan Kiem Lake")
    }

    // MARK: - 7. editField after selection begins new session

    func testEditQuery_AfterSelection_BeginsFreshSession() async throws {
        mockClient.detailResult = .success(mockClient.makePlace(placeID: "first"))
        mockClient.detailDelay  = 0
        let pred = makeGoongPrediction(placeID: "first", mainText: "First Place")

        viewModel.selectPrediction(pred)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNotNil(viewModel.selectedDestination)

        // Now user edits the text field
        viewModel.updateSearchQuery("New search text")

        XCTAssertNil(viewModel.selectedDestination,
                     "Editing query after selection must clear the old destination")
        XCTAssertNil(viewModel.selectedPrediction)
        XCTAssertEqual(viewModel.searchQuery, "New search text")
    }

    // MARK: - 8. endSearchSession rotates token after Place Detail success

    func testEndSearchSession_CalledAfterSuccessfulDetail() async throws {
        mockClient.autocompleteResult = .success([mockClient.makePrediction(placeID: "tok2")])
        viewModel.updateSearchQuery("Token session test")
        try await Task.sleep(nanoseconds: 350_000_000)
        let firstToken = mockClient.autocompleteSessionTokens.last!

        mockClient.detailResult = .success(mockClient.makePlace(placeID: "tok2"))
        let pred = makeGoongPrediction(placeID: "tok2", mainText: "Token session test")
        viewModel.selectPrediction(pred)
        try await Task.sleep(nanoseconds: 50_000_000)

        // Destination was set → token was rotated
        XCTAssertNotNil(viewModel.selectedDestination)

        // Now start a new search — new session should use a different token
        viewModel.updateSearchQuery("Second search")
        try await Task.sleep(nanoseconds: 350_000_000)
        let secondToken = mockClient.autocompleteSessionTokens.last!
        XCTAssertNotEqual(firstToken, secondToken,
                          "Token must be rotated after successful Place Detail")
    }

    // MARK: - 9. cancelSearch preserves searchQuery

    func testCancelSearch_PreservesSearchQuery() {
        viewModel.updateSearchQuery("Preserved query")
        viewModel.cancelSearch()
        XCTAssertEqual(viewModel.searchQuery, "Preserved query",
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

// MARK: - DelayedDetailClient (for racing test)

@MainActor
final class DelayedDetailClient: GoongPlacesClientProtocol {
    let aDelay: UInt64
    let bDelay: UInt64

    init(aDelay: UInt64, bDelay: UInt64) {
        self.aDelay = aDelay
        self.bDelay = bDelay
    }

    func autocomplete(query: String, location: CLLocationCoordinate2D?,
                      radius: Int, limit: Int, sessionToken: String) async throws -> [GoongRawPrediction] {
        []
    }

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
        if shouldFail {
            throw URLError(.networkConnectionLost)
        }
        // Return a minimal stub route
        let coord = origin
        let step = NavStep(
            coordinate:       coord,
            distanceMeters:   100,
            durationSeconds:  10,
            streetName:       "Mock St",
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
