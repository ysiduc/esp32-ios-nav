//
//  GoongSearchServiceTests.swift
//  Unit tests for GoongSearchService — autocomplete generation safety,
//  session token lifecycle, radius/limit parameters, loading/error generation
//  safety, empty/short query handling, deduplication.
//
//  Tests use debounceDelay: 0 to eliminate real-time waits.
//  All async coordination uses Task.yield() and await-on-mock not wall-clock sleep.
//

import XCTest
@testable import ESP32NavApp
import CoreLocation

@MainActor
final class GoongSearchServiceTests: XCTestCase {

    var client: MockGoongPlacesClient!
    var service: GoongSearchService!

    override func setUp() async throws {
        client  = MockGoongPlacesClient()
        // debounceDelay: 0 eliminates all timing sensitivity
        service = GoongSearchService(client: client, debounceDelay: 0)
    }

    // MARK: - 1. Short query clears state immediately

    func testShortQuery_ClearsPredictions() async {
        // After a short query, predictions and loading must be cleared immediately.
        // (Do NOT interleave with a long query to avoid racing the mock.)
        service.updateQuery("Ha")   // 2 chars — valid but won't fire because we immediately cancel
        service.updateQuery("H")    // 1 char — cancels previous, clears immediately
        XCTAssertTrue(service.predictions.isEmpty)
        XCTAssertFalse(service.isLoading)
    }

    func testEmptyQuery_ClearsState() {
        service.updateQuery("")
        XCTAssertTrue(service.predictions.isEmpty)
        XCTAssertFalse(service.isLoading)
    }

    func testSingleCharQuery_ClearsState() {
        service.updateQuery("a")
        XCTAssertTrue(service.predictions.isEmpty)
        XCTAssertFalse(service.isLoading)
    }

    // MARK: - 2. isLoading set on valid query

    func testUpdateQuery_LongEnough_SetsIsLoading() {
        service.updateQuery("Hanoi")
        XCTAssertTrue(service.isLoading)
    }

    // MARK: - 3. Autocomplete parameters

    func testAutocompleteRequest_HasRadius2000km() async throws {
        client.autocompleteResult = .success([])
        service.updateQuery("Hanoi street")
        try await Task.sleep(nanoseconds: 50_000_000) // let debounce(0) fire
        guard client.autocompleteCallCount > 0 else {
            XCTFail("No autocomplete call made"); return
        }
        XCTAssertEqual(client.autocompleteRadii.last, 2_000,
                       "Radius must be 2000 km, not metres")
    }

    func testAutocompleteRequest_HasLimit10() async throws {
        client.autocompleteResult = .success([])
        service.updateQuery("Hanoi street test")
        try await Task.sleep(nanoseconds: 50_000_000)
        guard client.autocompleteCallCount > 0 else {
            XCTFail("No autocomplete call made"); return
        }
        XCTAssertEqual(client.autocompleteLimits.last, 10)
    }

    func testAutocompleteRequest_QueryPassedUnchanged() async throws {
        client.autocompleteResult = .success([])
        service.updateQuery("Đường Trần Hưng Đạo")
        try await Task.sleep(nanoseconds: 50_000_000)
        guard client.autocompleteCallCount > 0 else {
            XCTFail("No autocomplete call made"); return
        }
        XCTAssertEqual(client.autocompleteQueries.last, "Đường Trần Hưng Đạo")
    }

    func testAutocompleteRequest_IncludesLocationWhenSet() async throws {
        service.userLocation = CLLocationCoordinate2D(latitude: 21.0, longitude: 105.8)
        client.autocompleteResult = .success([])
        service.updateQuery("Test location bias")
        try await Task.sleep(nanoseconds: 50_000_000)
        guard client.autocompleteCallCount > 0 else {
            XCTFail("No autocomplete call made"); return
        }
        XCTAssertTrue(client.lastAutocompleteHadLocation,
                      "Location should be forwarded when userLocation is set")
    }

    func testAutocompleteRequest_NoLocationWhenNil() async throws {
        service.userLocation = nil
        client.autocompleteResult = .success([])
        service.updateQuery("Test no location")
        try await Task.sleep(nanoseconds: 50_000_000)
        guard client.autocompleteCallCount > 0 else {
            XCTFail("No autocomplete call made"); return
        }
        XCTAssertFalse(client.lastAutocompleteHadLocation,
                       "No location should be sent when userLocation is nil")
    }

    // MARK: - 4. Session token lifecycle

    func testSessionToken_SameAcrossAutocompleteAndDetail() async throws {
        client.autocompleteResult = .success([client.makePrediction(placeID: "tok1")])
        service.updateQuery("Ba Dinh")
        try await Task.sleep(nanoseconds: 50_000_000)
        guard let autocompleteToken = client.autocompleteSessionTokens.last else {
            XCTFail("No autocomplete call"); return
        }

        _ = try await service.getPlaceDetail(placeID: "tok1")
        guard let detailToken = client.detailSessionTokens.last else {
            XCTFail("No detail call"); return
        }

        XCTAssertEqual(autocompleteToken, detailToken,
                       "Autocomplete and Place Detail must share the same session token")
    }

    func testEndSearchSession_RotatesToken() async throws {
        client.autocompleteResult = .success([])
        service.updateQuery("First session")
        try await Task.sleep(nanoseconds: 50_000_000)
        let tokenBefore = client.autocompleteSessionTokens.last ?? ""

        service.endSearchSession()

        service.updateQuery("Second session")
        try await Task.sleep(nanoseconds: 50_000_000)
        let tokenAfter = client.autocompleteSessionTokens.last ?? ""

        XCTAssertFalse(tokenBefore.isEmpty, "Should have made at least one autocomplete call")
        XCTAssertFalse(tokenAfter.isEmpty,  "Should have made at least two autocomplete calls")
        XCTAssertNotEqual(tokenBefore, tokenAfter,
                          "endSearchSession() must rotate the session token")
    }

    func testCancelAutocomplete_DoesNotRotateToken() async throws {
        client.autocompleteResult = .success([])
        service.updateQuery("Hoan Kiem test")
        try await Task.sleep(nanoseconds: 50_000_000)
        let tokenBefore = client.autocompleteSessionTokens.last ?? ""

        service.cancelAutocomplete()

        service.updateQuery("Hoan Kiem more test")
        try await Task.sleep(nanoseconds: 50_000_000)
        let tokenAfter = client.autocompleteSessionTokens.last ?? ""

        XCTAssertFalse(tokenBefore.isEmpty)
        XCTAssertFalse(tokenAfter.isEmpty)
        XCTAssertEqual(tokenBefore, tokenAfter,
                       "cancelAutocomplete() must NOT rotate the session token")
    }

    func testClearPredictions_DoesNotRotateToken() async throws {
        client.autocompleteResult = .success([])
        service.updateQuery("Dong Da token test")
        try await Task.sleep(nanoseconds: 50_000_000)
        let tokenBefore = client.autocompleteSessionTokens.last ?? ""

        service.clearPredictions()
        XCTAssertTrue(service.predictions.isEmpty)

        service.updateQuery("Dong Da still same token")
        try await Task.sleep(nanoseconds: 50_000_000)
        let tokenAfter = client.autocompleteSessionTokens.last ?? ""

        XCTAssertFalse(tokenBefore.isEmpty)
        XCTAssertFalse(tokenAfter.isEmpty)
        XCTAssertEqual(tokenBefore, tokenAfter,
                       "clearPredictions() must not rotate the session token")
    }

    func testResetAll_RotatesToken() async throws {
        client.autocompleteResult = .success([])
        service.updateQuery("Before reset query test")
        try await Task.sleep(nanoseconds: 50_000_000)
        let tokenBefore = client.autocompleteSessionTokens.last ?? ""

        service.resetAll()

        service.updateQuery("After reset query test")
        try await Task.sleep(nanoseconds: 50_000_000)
        let tokenAfter = client.autocompleteSessionTokens.last ?? ""

        XCTAssertFalse(tokenBefore.isEmpty)
        XCTAssertFalse(tokenAfter.isEmpty)
        XCTAssertNotEqual(tokenBefore, tokenAfter)
    }

    // MARK: - 5. Error handling

    func testAutocompleteError_SetsErrorMessage() async throws {
        client.autocompleteResult = .failure(GoongSearchError.networkError(URLError(.notConnectedToInternet)))
        service.updateQuery("Error test query")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNotNil(service.errorMessage)
        XCTAssertTrue(service.predictions.isEmpty)
        XCTAssertFalse(service.isLoading)
    }

    func testIsLoading_ClearedAfterError() async throws {
        client.autocompleteResult = .failure(GoongSearchError.noResults)
        service.updateQuery("Loading test query")
        XCTAssertTrue(service.isLoading, "isLoading should be set synchronously")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(service.isLoading, "isLoading must be cleared after error")
    }

    // MARK: - 6. Deduplication

    func testDuplicatePlaceIDs_AreRemovedKeepingFirst() async throws {
        let predictions = [
            client.makePrediction(placeID: "dup-id", mainText: "A", providerIndex: 0),
            client.makePrediction(placeID: "dup-id", mainText: "B", providerIndex: 1),
            client.makePrediction(placeID: "unique-id", mainText: "C", providerIndex: 2),
        ]
        client.autocompleteResult = .success(predictions)
        service.updateQuery("Duplicate test query")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(service.predictions.count, 2)
        XCTAssertTrue(service.predictions.map(\.placeID).contains("dup-id"))
        XCTAssertTrue(service.predictions.map(\.placeID).contains("unique-id"))
    }

    // MARK: - 7. Empty result

    func testEmptyResult_NoPredictions_NoError() async throws {
        client.autocompleteResult = .success([])
        service.updateQuery("Empty result test query")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(service.predictions.isEmpty)
        XCTAssertNil(service.errorMessage)
        XCTAssertFalse(service.isLoading)
    }

    // MARK: - 8. Results published correctly

    func testPredictions_PublishedAfterSuccessfulCall() async throws {
        let pred = client.makePrediction(placeID: "pub-test", mainText: "Published Place")
        client.autocompleteResult = .success([pred])
        service.updateQuery("Published test query")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(service.predictions.count, 1)
        XCTAssertEqual(service.predictions.first?.placeID, "pub-test")
        XCTAssertFalse(service.isLoading)
        XCTAssertNil(service.errorMessage)
    }

    // MARK: - 9. Race conditions with controllable continuations

    private func waitForPendingAutocompletes(count: Int = 1) async throws {
        for _ in 0..<100 {
            if client.pendingAutocompletes.count >= count { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testStaleAutocomplete_AReturnsAfterB_Discarded() async throws {
        client.useContinuationForAutocomplete = true

        service.updateQuery("ha")
        try await waitForPendingAutocompletes(count: 1)
        XCTAssertEqual(client.pendingAutocompletes.count, 1)

        service.updateQuery("hanoi")
        try await waitForPendingAutocompletes(count: 2)
        XCTAssertEqual(client.pendingAutocompletes.count, 2)

        let predA = client.makePrediction(placeID: "id-a", mainText: "Ha")
        let predB = client.makePrediction(placeID: "id-b", mainText: "Hanoi")

        // Resume B first (index 1)
        client.resumeAutocomplete(at: 1, with: .success([predB]))
        for _ in 0..<100 {
            if !service.predictions.isEmpty { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(service.predictions.map(\.placeID), ["id-b"],
                       "Service should publish B results immediately")

        // Resume A late (now index 0)
        client.resumeAutocomplete(at: 0, with: .success([predA]))
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(service.predictions.map(\.placeID), ["id-b"],
                       "Late response from query A must be discarded and not overwrite B")
    }

    func testStaleAutocomplete_OldCancellationMustNotClearNewLoading() async throws {
        client.useContinuationForAutocomplete = true

        service.updateQuery("ha")
        try await waitForPendingAutocompletes(count: 1)
        XCTAssertEqual(client.pendingAutocompletes.count, 1)

        service.updateQuery("hanoi")
        try await waitForPendingAutocompletes(count: 2)
        XCTAssertEqual(client.pendingAutocompletes.count, 2)
        XCTAssertTrue(service.isLoading, "isLoading must stay true while B is still pending")

        let predB = client.makePrediction(placeID: "id-b", mainText: "Hanoi")
        client.resumeAutocomplete(at: 1, with: .success([predB]))
        for _ in 0..<100 {
            if !service.isLoading { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertFalse(service.isLoading, "isLoading must be cleared once B completes")
        XCTAssertEqual(service.predictions.map(\.placeID), ["id-b"])

        // Clean up pending A
        client.resumeAutocomplete(at: 0, with: .failure(CancellationError()))
    }

    func testStaleAutocomplete_StaleErrorAfterSuccessDoesNotClearPredictions() async throws {
        client.useContinuationForAutocomplete = true

        service.updateQuery("ha")
        try await waitForPendingAutocompletes(count: 1)

        service.updateQuery("hanoi")
        try await waitForPendingAutocompletes(count: 2)
        XCTAssertEqual(client.pendingAutocompletes.count, 2)

        let predB = client.makePrediction(placeID: "id-b", mainText: "Hanoi")
        client.resumeAutocomplete(at: 1, with: .success([predB]))
        for _ in 0..<100 {
            if !service.predictions.isEmpty { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(service.predictions.map(\.placeID), ["id-b"])
        XCTAssertNil(service.errorMessage)

        // Late failure for A
        client.resumeAutocomplete(at: 0, with: .failure(URLError(.timedOut)))
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(service.predictions.map(\.placeID), ["id-b"],
                       "Late error from A must not clear B's predictions")
        XCTAssertNil(service.errorMessage,
                     "Late error from A must not publish error message over B")
    }
}
