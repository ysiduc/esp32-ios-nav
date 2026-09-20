//
//  MockGoongPlacesClient.swift
//  Controllable test double for GoongPlacesClientProtocol.
//  Records all invocation parameters for assertion.
//  Supports controllable continuation-based async responses for race testing.
//

import CoreLocation
import Foundation
@testable import ESP32NavApp

// MARK: - Mock Client

@MainActor
final class MockGoongPlacesClient: GoongPlacesClientProtocol {

    // MARK: - Autocomplete Recording
    var autocompleteCallCount = 0
    var autocompleteQueries:       [String]                          = []
    var autocompleteLocations:     [CLLocationCoordinate2D?]        = []
    /// Whether the last autocomplete call had a location parameter
    var lastAutocompleteHadLocation: Bool { autocompleteLocations.last.flatMap { $0 } != nil }
    var autocompleteRadii:         [Int]                             = []
    var autocompleteLimits:        [Int]                             = []
    var autocompleteSessionTokens: [String]                          = []

    // MARK: - PlaceDetail Recording
    var detailCallCount = 0
    var detailPlaceIDs:       [String] = []
    var detailSessionTokens:  [String] = []

    // MARK: - Controllable Responses

    /// Set to inject a fixed response for every autocomplete call.
    var autocompleteResult: Result<[GoongRawPrediction], Error> = .success([])

    /// Set to inject a fixed response for every placeDetail call.
    var detailResult: Result<GoongPlace, Error> = .success(
        GoongPlace(
            placeID: "mock-place-id",
            name: "Mock Place",
            formattedAddress: "123 Mock Street, Hanoi",
            location: GoongLocation(latitude: 21.0, longitude: 105.0),
            types: []
        )
    )

    /// Optional delay before returning (nanoseconds).
    var autocompleteDelay: UInt64 = 0
    var detailDelay: UInt64 = 0

    // MARK: - Controllable Continuation Support (Race Tests)

    var useContinuationForAutocomplete: Bool = false

    struct PendingAutocomplete {
        let query: String
        let sessionToken: String
        let continuation: CheckedContinuation<[GoongRawPrediction], Error>
    }
    private(set) var pendingAutocompletes: [PendingAutocomplete] = []

    func resumeAutocomplete(at index: Int = 0, with result: Result<[GoongRawPrediction], Error>) {
        guard index < pendingAutocompletes.count else { return }
        let pending = pendingAutocompletes.remove(at: index)
        switch result {
        case .success(let predictions):
            pending.continuation.resume(returning: predictions)
        case .failure(let error):
            pending.continuation.resume(throwing: error)
        }
    }

    var useContinuationForDetail: Bool = false

    struct PendingDetail {
        let placeID: String
        let sessionToken: String
        let continuation: CheckedContinuation<GoongPlace, Error>
    }
    private(set) var pendingDetails: [PendingDetail] = []

    func resumeDetail(at index: Int = 0, with result: Result<GoongPlace, Error>) {
        guard index < pendingDetails.count else { return }
        let pending = pendingDetails.remove(at: index)
        switch result {
        case .success(let place):
            pending.continuation.resume(returning: place)
        case .failure(let error):
            pending.continuation.resume(throwing: error)
        }
    }

    // MARK: - GoongPlacesClientProtocol

    func autocomplete(
        query: String,
        location: CLLocationCoordinate2D?,
        radius: Int,
        limit: Int,
        sessionToken: String
    ) async throws -> [GoongRawPrediction] {
        autocompleteCallCount += 1
        autocompleteQueries.append(query)
        autocompleteLocations.append(location)
        autocompleteRadii.append(radius)
        autocompleteLimits.append(limit)
        autocompleteSessionTokens.append(sessionToken)

        if useContinuationForAutocomplete {
            return try await withCheckedThrowingContinuation { cont in
                pendingAutocompletes.append(PendingAutocomplete(
                    query: query,
                    sessionToken: sessionToken,
                    continuation: cont
                ))
            }
        }

        if autocompleteDelay > 0 {
            try await Task.sleep(nanoseconds: autocompleteDelay)
        }
        switch autocompleteResult {
        case .success(let predictions): return predictions
        case .failure(let error):       throw error
        }
    }

    func placeDetail(placeID: String, sessionToken: String) async throws -> GoongPlace {
        detailCallCount += 1
        detailPlaceIDs.append(placeID)
        detailSessionTokens.append(sessionToken)

        if useContinuationForDetail {
            return try await withCheckedThrowingContinuation { cont in
                pendingDetails.append(PendingDetail(
                    placeID: placeID,
                    sessionToken: sessionToken,
                    continuation: cont
                ))
            }
        }

        if detailDelay > 0 {
            try await Task.sleep(nanoseconds: detailDelay)
        }
        switch detailResult {
        case .success(let place): return place
        case .failure(let error): throw error
        }
    }

    // MARK: - Helpers

    func reset() {
        autocompleteCallCount = 0
        autocompleteQueries       = []
        autocompleteLocations     = []
        autocompleteRadii         = []
        autocompleteLimits        = []
        autocompleteSessionTokens = []
        detailCallCount     = 0
        detailPlaceIDs      = []
        detailSessionTokens = []

        pendingAutocompletes.forEach { $0.continuation.resume(throwing: CancellationError()) }
        pendingAutocompletes.removeAll()
        pendingDetails.forEach { $0.continuation.resume(throwing: CancellationError()) }
        pendingDetails.removeAll()
        useContinuationForAutocomplete = false
        useContinuationForDetail = false
    }

    func makePrediction(
        placeID: String = "place-1",
        mainText: String = "Main Text",
        secondaryText: String = "Secondary",
        description: String = "Full description",
        providerScore: Double? = 1.0,
        providerIndex: Int = 0
    ) -> GoongRawPrediction {
        GoongRawPrediction(
            placeID:       placeID,
            mainText:      mainText,
            secondaryText: secondaryText,
            description:   description,
            providerScore: providerScore,
            providerIndex: providerIndex
        )
    }

    func makePlace(
        placeID: String = "place-1",
        name: String = "Mock Place",
        lat: Double = 21.0,
        lng: Double = 105.0
    ) -> GoongPlace {
        GoongPlace(
            placeID:          placeID,
            name:             name,
            formattedAddress: "\(name), Hanoi",
            location:         GoongLocation(latitude: lat, longitude: lng),
            types:            []
        )
    }
}
