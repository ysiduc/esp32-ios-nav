//
//  ApplePlaceSearchServiceTests.swift
//  Unit tests for ApplePlaceSearchService and deterministic MapKit ranking.
//

import CoreLocation
import MapKit
import XCTest
@testable import ESP32NavApp

// MARK: - Mock MapKit Search Adapter

@MainActor
final class MockMapKitSearchAdapter: MapKitSearchAdapterProtocol {
    var searchCompletionsHandler: ((String, MKCoordinateRegion?) async throws -> [SearchPrediction])?
    var resolveHandler: ((SearchPrediction, CLLocationCoordinate2D?) async throws -> ResolvedPlace)?

    var searchCalls: [(query: String, region: MKCoordinateRegion?)] = []
    var resolveCalls: [(prediction: SearchPrediction, location: CLLocationCoordinate2D?)] = []

    func searchCompletions(
        query: String,
        region: MKCoordinateRegion?
    ) async throws -> [SearchPrediction] {
        searchCalls.append((query, region))
        if let handler = searchCompletionsHandler {
            return try await handler(query, region)
        }
        return [
            SearchPrediction(id: "pred_1", title: query, subtitle: "Hà Nội, Việt Nam")
        ]
    }

    func resolve(
        prediction: SearchPrediction,
        userLocation: CLLocationCoordinate2D?
    ) async throws -> ResolvedPlace {
        resolveCalls.append((prediction, userLocation))
        if let handler = resolveHandler {
            return try await handler(prediction, userLocation)
        }
        return ResolvedPlace(
            id: prediction.id,
            name: prediction.title,
            formattedAddress: prediction.description,
            coordinate: CLLocationCoordinate2D(latitude: 21.0285, longitude: 105.8542)
        )
    }
}

// MARK: - ApplePlaceSearchService Tests

@MainActor
final class ApplePlaceSearchServiceTests: XCTestCase {

    var adapter: MockMapKitSearchAdapter!
    var service: ApplePlaceSearchService!

    override func setUp() async throws {
        try await super.setUp()
        adapter = MockMapKitSearchAdapter()
        service = ApplePlaceSearchService(adapter: adapter, debounceDelay: 0)
    }

    // MARK: - Autocomplete & Stale Generation Safety

    func testAutocomplete_EmitsPredictionsForValidQuery() async throws {
        service.updateQuery("Hồ Gươm")
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms

        XCTAssertEqual(service.predictions.count, 1)
        XCTAssertEqual(service.predictions.first?.title, "Hồ Gươm")
        XCTAssertFalse(service.isLoading)
        XCTAssertNil(service.errorMessage)
    }

    func testAutocomplete_ShortQueryClearsPredictionsImmediately() async throws {
        service.predictions = [SearchPrediction(id: "old", title: "Old", subtitle: "")]
        service.updateQuery("a")

        XCTAssertTrue(service.predictions.isEmpty)
        XCTAssertFalse(service.isLoading)
        XCTAssertEqual(adapter.searchCalls.count, 0)
    }

    func testAutocomplete_StaleResponseDiscardedOnRapidQueries() async throws {
        // Delayed adapter simulation
        adapter.searchCompletionsHandler = { query, _ in
            if query == "Ha" {
                try await Task.sleep(nanoseconds: 50_000_000) // 50ms
                return [SearchPrediction(id: "p_ha", title: "Ha", subtitle: "")]
            } else if query == "Hanoi" {
                return [SearchPrediction(id: "p_hanoi", title: "Hanoi", subtitle: "")]
            }
            return []
        }

        service.updateQuery("Ha")
        service.updateQuery("Hanoi")

        try await Task.sleep(nanoseconds: 80_000_000)

        // Only Hanoi should remain
        XCTAssertEqual(service.predictions.count, 1)
        XCTAssertEqual(service.predictions.first?.title, "Hanoi")
    }

    func testCancelAutocomplete_StopsLoadingAndDiscardsResult() async throws {
        adapter.searchCompletionsHandler = { _, _ in
            try await Task.sleep(nanoseconds: 50_000_000)
            return [SearchPrediction(id: "slow", title: "Slow", subtitle: "")]
        }

        service.updateQuery("SlowQuery")
        service.cancelAutocomplete()

        XCTAssertFalse(service.isLoading)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertTrue(service.predictions.isEmpty)
    }

    func testClearPredictions_ResetsPublishedList() {
        service.predictions = [SearchPrediction(id: "1", title: "P1", subtitle: "")]
        var callbackFired = false
        service.onPredictionsChanged = { list in
            if list.isEmpty { callbackFired = true }
        }

        service.clearPredictions()

        XCTAssertTrue(service.predictions.isEmpty)
        XCTAssertTrue(callbackFired)
    }

    func testResetAll_CancelsAndClears() {
        service.predictions = [SearchPrediction(id: "1", title: "P1", subtitle: "")]
        service.resetAll()

        XCTAssertTrue(service.predictions.isEmpty)
        XCTAssertFalse(service.isLoading)
    }

    // MARK: - Resolution

    func testResolve_CallsAdapterAndReturnsPlace() async throws {
        let pred = SearchPrediction(id: "lake_1", title: "Hồ Hoàn Kiếm", subtitle: "Hoàn Kiếm, Hà Nội")
        let place = try await service.resolve(prediction: pred)

        XCTAssertEqual(place.id, "lake_1")
        XCTAssertEqual(place.name, "Hồ Hoàn Kiếm")
        XCTAssertEqual(place.coordinate.latitude, 21.0285, accuracy: 0.001)
        XCTAssertEqual(adapter.resolveCalls.count, 1)
    }

    // MARK: - Deterministic MapItem Ranking

    func testMapItemRanking_ExactTitleScoresHigherThanSubstring() {
        let pred = SearchPrediction(title: "Hồ Hoàn Kiếm", subtitle: "Hà Nội")

        let pm1 = MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: 21.0285, longitude: 105.8542))
        let item1 = MKMapItem(placemark: pm1)
        item1.name = "Hồ Hoàn Kiếm"

        let pm2 = MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: 21.0300, longitude: 105.8500))
        let item2 = MKMapItem(placemark: pm2)
        item2.name = "Quán Cà Phê Nhìn Ra Hồ Hoàn Kiếm"

        let best = DefaultMapKitSearchAdapter.rankMapItems(
            [item2, item1],
            prediction: pred,
            userLocation: nil
        )

        XCTAssertEqual(best.name, "Hồ Hoàn Kiếm")
    }

    func testMapItemRanking_PrefersVietnamCoordinates() {
        let pred = SearchPrediction(title: "Hà Nội", subtitle: "")

        // Inside Vietnam (lat 21.0, lon 105.8)
        let pmVN = MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: 21.0285, longitude: 105.8542))
        let itemVN = MKMapItem(placemark: pmVN)
        itemVN.name = "Hà Nội"

        // Outside Vietnam (e.g. lat 40.0, lon -74.0)
        let pmUS = MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060))
        let itemUS = MKMapItem(placemark: pmUS)
        itemUS.name = "Hà Nội"

        let best = DefaultMapKitSearchAdapter.rankMapItems(
            [itemUS, itemVN],
            prediction: pred,
            userLocation: nil
        )

        XCTAssertEqual(best.placemark.coordinate.latitude, 21.0285, accuracy: 0.001)
    }
}
