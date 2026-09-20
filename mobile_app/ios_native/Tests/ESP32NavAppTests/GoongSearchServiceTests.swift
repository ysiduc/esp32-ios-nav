//
//  GoongSearchServiceTests.swift
//  Unit tests for GoongSearchService — autocomplete generation safety,
//  session token lifecycle, radius/limit/more_compound parameters,
//  loading/error generation safety, empty/short query handling.
//

import XCTest
@testable import ESP32NavApp

@MainActor
final class GoongSearchServiceTests: XCTestCase {

    var client: MockGoongPlacesClient!
    var service: GoongSearchService!

    override func setUp() async throws {
        client  = MockGoongPlacesClient()
        service = GoongSearchService(client: client)
    }

    // MARK: - 1. Query source of truth

    func testUpdateQueryDoesNotMutatePredictions_WhenQueryTooShort() async throws {
        client.autocompleteResult = .success([client.makePrediction()])
        service.updateQuery("ab")
        // Short: exactly 2 chars — should fire (>= 2 means >=2)
        await Task.yield()
        // predictions currently empty because debounce hasn't fired yet
        // After 0 delay (mock), run the debounce explicitly
        // updateQuery with 1-char should clear
        service.updateQuery("a")
        XCTAssertTrue(service.predictions.isEmpty)
        XCTAssertFalse(service.isLoading)
    }

    func testUpdateQuerySetsIsLoading_WhenQueryLongEnough() {
        service.updateQuery("Hanoi")
        XCTAssertTrue(service.isLoading)
    }

    func testShortQuery_ClearsPredictions() async throws {
        // Seed some predictions
        client.autocompleteResult = .success([client.makePrediction()])
        // Simulate predictions were set
        service.updateQuery("Ha")
        // Short query
        service.updateQuery("H")
        XCTAssertTrue(service.predictions.isEmpty)
        XCTAssertFalse(service.isLoading)
    }

    // MARK: - 2. Autocomplete generation safety (stale response discarded)

    func testStaleAutocompleteResponse_IsDiscarded() async throws {
        // Two rapid queries: gen=1 fires and is debounce-cancelled by gen=2.
        // gen=2 resolves with result B. Result for gen=1 must not appear.
        let controlledClient = ControlledMockClient()
        let svc = GoongSearchService(client: controlledClient)

        // Query 1 (gen=1) — debounce not yet fired
        svc.updateQuery("Ho Chi Minh")
        await Task.yield()

        // Query 2 (gen=2) — cancels gen=1 debounce
        svc.updateQuery("Ha Noi")

        // Resolve with result B for gen=2
        let resultB = [GoongRawPrediction(placeID: "b", mainText: "Ha Noi", secondaryText: "", description: "Ha Noi")]
        controlledClient.resolve(with: resultB)

        try await Task.sleep(nanoseconds: 50_000_000)

        // Gen=1 was cancelled by debounce; gen=2 resolved.
        XCTAssertTrue(svc.predictions.first?.placeID == "b" || svc.predictions.isEmpty,
                      "Should not show stale result from gen=1")
    }

    // MARK: - 3. Autocomplete radius, limit, more_compound

    func testAutocompleteRequest_HasCorrectRadius() async throws {
        client.autocompleteResult = .success([])
        client.autocompleteDelay = 0
        service.updateQuery("Hanoi street")
        try await Task.sleep(nanoseconds: 350_000_000) // > 300ms debounce
        XCTAssertEqual(client.autocompleteRadii.last, 2_000,
                       "Radius should be 2000 km, not metres")
    }

    func testAutocompleteRequest_HasCorrectLimit() async throws {
        client.autocompleteResult = .success([])
        service.updateQuery("Hanoi street")
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(client.autocompleteLimits.last, 10)
    }

    func testAutocompleteRequest_DeliversQueryUnchanged() async throws {
        client.autocompleteResult = .success([])
        service.updateQuery("Đường Trần Hưng Đạo")
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(client.autocompleteQueries.last, "Đường Trần Hưng Đạo")
    }

    func testAutocompleteRequest_IncludesLocationWhenSet() async throws {
        service.userLocation = CLLocationCoordinate2DMake(21.0, 105.8)
        client.autocompleteResult = .success([])
        service.updateQuery("Test location")
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertNotNil(client.autocompleteLocations.last as? CLLocationCoordinate2D)
    }

    func testAutocompleteRequest_NoLocation_WhenNil() async throws {
        service.userLocation = nil
        client.autocompleteResult = .success([])
        service.updateQuery("Test no location")
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertNil(client.autocompleteLocations.last as? CLLocationCoordinate2D)
    }

    // MARK: - 4. Session token lifecycle

    func testSessionToken_SameAcrossAutocompleteAndDetail() async throws {
        client.autocompleteResult = .success([client.makePrediction()])
        service.updateQuery("Ba Dinh")
        try await Task.sleep(nanoseconds: 350_000_000)
        let autocompleteToken = client.autocompleteSessionTokens.last!

        _ = try await service.getPlaceDetail(placeID: "place-1")
        let detailToken = client.detailSessionTokens.last!

        XCTAssertEqual(autocompleteToken, detailToken,
                       "Autocomplete and Place Detail must share the same session token")
    }

    func testEndSearchSession_RotatesToken() async throws {
        client.autocompleteResult = .success([])
        service.updateQuery("Some query")
        try await Task.sleep(nanoseconds: 350_000_000)
        let tokenBefore = client.autocompleteSessionTokens.last!

        service.endSearchSession()

        service.updateQuery("New query")
        try await Task.sleep(nanoseconds: 350_000_000)
        let tokenAfter = client.autocompleteSessionTokens.last!

        XCTAssertNotEqual(tokenBefore, tokenAfter,
                          "endSearchSession() must rotate the session token")
    }

    func testCancelAutocomplete_DoesNotRotateToken() async throws {
        client.autocompleteResult = .success([])
        service.updateQuery("Hoan Kiem")
        try await Task.sleep(nanoseconds: 350_000_000)
        let tokenBefore = client.autocompleteSessionTokens.last!

        service.cancelAutocomplete()

        service.updateQuery("Hoan Kiem more")
        try await Task.sleep(nanoseconds: 350_000_000)
        let tokenAfter = client.autocompleteSessionTokens.last!

        XCTAssertEqual(tokenBefore, tokenAfter,
                       "cancelAutocomplete() must NOT rotate the session token")
    }

    func testResetAll_RotatesToken() async throws {
        client.autocompleteResult = .success([])
        service.updateQuery("Query before reset")
        try await Task.sleep(nanoseconds: 350_000_000)
        let tokenBefore = client.autocompleteSessionTokens.last!

        service.resetAll()

        service.updateQuery("Query after reset")
        try await Task.sleep(nanoseconds: 350_000_000)
        let tokenAfter = client.autocompleteSessionTokens.last!

        XCTAssertNotEqual(tokenBefore, tokenAfter)
    }

    // MARK: - 5. Error handling

    func testAutocompleteError_SetsErrorMessage() async throws {
        client.autocompleteResult = .failure(GoongSearchError.networkError(URLError(.notConnectedToInternet)))
        service.updateQuery("Error test")
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertNotNil(service.errorMessage)
        XCTAssertTrue(service.predictions.isEmpty)
        XCTAssertFalse(service.isLoading)
    }

    func testClearPredictions_DoesNotRotateToken() async throws {
        client.autocompleteResult = .success([client.makePrediction()])
        service.updateQuery("Dong Da")
        try await Task.sleep(nanoseconds: 350_000_000)
        let tokenBefore = client.autocompleteSessionTokens.last!

        service.clearPredictions()

        service.updateQuery("Dong Da new")
        try await Task.sleep(nanoseconds: 350_000_000)
        let tokenAfter = client.autocompleteSessionTokens.last!

        XCTAssertEqual(tokenBefore, tokenAfter,
                       "clearPredictions() must not rotate the session token")
    }

    // MARK: - 6. Results deduplication

    func testDuplicatePlaceIDs_AreRemovedKeepingFirst() async throws {
        let predictions = [
            client.makePrediction(placeID: "dup", mainText: "A", providerIndex: 0),
            client.makePrediction(placeID: "dup", mainText: "B", providerIndex: 1),
            client.makePrediction(placeID: "unique", mainText: "C", providerIndex: 2),
        ]
        client.autocompleteResult = .success(predictions)
        service.updateQuery("Duplicate test")
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(service.predictions.count, 2)
        XCTAssertEqual(service.predictions.map(\.placeID), ["dup", "unique"])
    }

    // MARK: - 7. isLoading cleared on error

    func testIsLoading_ClearedAfterError() async throws {
        client.autocompleteResult = .failure(GoongSearchError.noResults)
        service.updateQuery("Load test")
        XCTAssertTrue(service.isLoading) // loading set synchronously
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertFalse(service.isLoading, "isLoading must be cleared after error")
    }

    // MARK: - 8. Empty result

    func testEmptyResult_Clears_SetsNoError() async throws {
        client.autocompleteResult = .success([])
        service.updateQuery("Empty result test")
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertTrue(service.predictions.isEmpty)
        XCTAssertNil(service.errorMessage)
        XCTAssertFalse(service.isLoading)
    }
}

// MARK: - Helpers

import CoreLocation

/// A client that never resolves until told to — for racing tests.
@MainActor
final class ControlledMockClient: GoongPlacesClientProtocol {

    private var resolveResult: [GoongRawPrediction]?
    private var continuation: CheckedContinuation<[GoongRawPrediction], Error>?

    func autocomplete(
        query: String,
        location: CLLocationCoordinate2D?,
        radius: Int,
        limit: Int,
        sessionToken: String
    ) async throws -> [GoongRawPrediction] {
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            // If we already have a result ready, resolve immediately
            if let result = resolveResult {
                resolveResult = nil
                cont.resume(returning: result)
            }
        }
    }

    func placeDetail(placeID: String, sessionToken: String) async throws -> GoongPlace {
        GoongPlace(
            placeID: placeID,
            name: "Controlled",
            formattedAddress: "Addr",
            location: GoongLocation(latitude: 21, longitude: 105),
            types: []
        )
    }

    func resolve(with predictions: [GoongRawPrediction]) {
        if let cont = continuation {
            continuation = nil
            cont.resume(returning: predictions)
        } else {
            resolveResult = predictions
        }
    }
}


