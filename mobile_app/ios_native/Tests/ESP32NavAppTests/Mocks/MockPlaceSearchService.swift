//
//  MockPlaceSearchService.swift
//  Testable mock implementing PlaceSearchServiceProtocol for search lifecycle & race tests.
//

import CoreLocation
import Foundation
@testable import ESP32NavApp

@MainActor
public final class MockPlaceSearchService: PlaceSearchServiceProtocol {

    public var predictions: [SearchPrediction] = []
    public var isLoading: Bool = false
    public var errorMessage: String?
    public var userLocation: CLLocationCoordinate2D?
    public var onPredictionsChanged: (([SearchPrediction]) -> Void)?

    public var queriesReceived: [String] = []
    public var cancelAutocompleteCount: Int = 0
    public var clearPredictionsCount: Int = 0
    public var resetAllCount: Int = 0

    public var resolveDelayNanoseconds: UInt64 = 0
    public var resolveResult: Result<ResolvedPlace, Error>?
    public var resolveCalls: [SearchPrediction] = []
    public var onResolve: ((SearchPrediction) async throws -> ResolvedPlace)?

    public init() {}


    // Controllable continuation support for race tests
    public var useContinuationForDetail = false
    public struct PendingDetail {
        public let prediction: SearchPrediction
        public let continuation: CheckedContinuation<ResolvedPlace, Error>
    }
    public private(set) var pendingDetails: [PendingDetail] = []

    public func resumeDetail(at index: Int = 0, with result: Result<ResolvedPlace, Error>) {
        guard index < pendingDetails.count else { return }
        let pending = pendingDetails.remove(at: index)
        pending.continuation.resume(with: result)
    }

    public func makePlace(id: String, name: String = "Test Place", lat: Double = 21.0, lng: Double = 105.0) -> ResolvedPlace {
        ResolvedPlace(
            id: id,
            name: name,
            formattedAddress: "Address for \(name)",
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng)
        )
    }

    public func updateQuery(_ query: String) {
        queriesReceived.append(query)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 2 {
            predictions = []
            isLoading = false
            onPredictionsChanged?([])
            return
        }

        isLoading = true
        // Default behavior: create a synthetic prediction matching query
        let p = SearchPrediction(
            id: "pred_\(trimmed)",
            title: trimmed,
            subtitle: "Việt Nam"
        )
        predictions = [p]
        isLoading = false
        onPredictionsChanged?(predictions)
    }

    public func cancelAutocomplete() {
        cancelAutocompleteCount += 1
        isLoading = false
    }

    public func clearPredictions() {
        clearPredictionsCount += 1
        predictions = []
        isLoading = false
        errorMessage = nil
        onPredictionsChanged?([])
    }

    public func resetAll() {
        resetAllCount += 1
        cancelAutocomplete()
        clearPredictions()
    }

    public func resolve(prediction: SearchPrediction) async throws -> ResolvedPlace {
        resolveCalls.append(prediction)

        if useContinuationForDetail {
            return try await withCheckedThrowingContinuation { cont in
                pendingDetails.append(PendingDetail(prediction: prediction, continuation: cont))
            }
        }

        if resolveDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: resolveDelayNanoseconds)
        }

        if let customHandler = onResolve {
            return try await customHandler(prediction)
        }

        if let result = resolveResult {
            return try result.get()
        }

        // Default synthetic place
        return makePlace(id: prediction.id, name: prediction.title)
    }
}
