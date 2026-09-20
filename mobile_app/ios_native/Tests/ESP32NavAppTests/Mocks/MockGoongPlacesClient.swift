//
//  MockGoongPlacesClient.swift
//  Controllable test double for GoongPlacesClientProtocol.
//  Records all invocation parameters for assertion.
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
