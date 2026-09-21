//
//  ApplePlaceSearchService.swift
//  Provider-neutral search service powered by Apple MapKit.
//

import CoreLocation
import Foundation
import MapKit

// MARK: - MapKit Search Adapter Protocol

/// Testable adapter protocol abstracting MKLocalSearchCompleter and MKLocalSearch.
@MainActor
public protocol MapKitSearchAdapterProtocol: AnyObject {
    func searchCompletions(
        query: String,
        region: MKCoordinateRegion?
    ) async throws -> [SearchPrediction]

    func resolve(
        prediction: SearchPrediction,
        userLocation: CLLocationCoordinate2D?
    ) async throws -> ResolvedPlace
}

// MARK: - Production MapKit Search Adapter

@MainActor
public final class DefaultMapKitSearchAdapter: NSObject, MapKitSearchAdapterProtocol, MKLocalSearchCompleterDelegate {

    private let completer = MKLocalSearchCompleter()
    private var pendingContinuation: CheckedContinuation<[SearchPrediction], Error>?
    private var completionCache: [String: MKLocalSearchCompletion] = [:]

    public override init() {
        super.init()
        completer.resultTypes = [.address, .pointOfInterest, .query]
        completer.delegate = self
    }

    public func searchCompletions(
        query: String,
        region: MKCoordinateRegion?
    ) async throws -> [SearchPrediction] {
        // Cancel any pending continuation with cancellation
        pendingContinuation?.resume(throwing: CancellationError())
        pendingContinuation = nil

        if let region = region {
            completer.region = region
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.pendingContinuation = continuation
            self.completer.queryFragment = query
        }
    }

    public func resolve(
        prediction: SearchPrediction,
        userLocation: CLLocationCoordinate2D?
    ) async throws -> ResolvedPlace {
        let request: MKLocalSearch.Request
        if let completion = completionCache[prediction.id] {
            request = MKLocalSearch.Request(completion: completion)
        } else {
            request = MKLocalSearch.Request()
            request.naturalLanguageQuery = prediction.description
            if let userLoc = userLocation {
                request.region = MKCoordinateRegion(
                    center: userLoc,
                    latitudinalMeters: 100_000,
                    longitudinalMeters: 100_000
                )
            }
        }

        let search = MKLocalSearch(request: request)
        let response = try await search.start()
        guard !response.mapItems.isEmpty else {
            throw NSError(domain: "ApplePlaceSearchService", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "Không tìm thấy kết quả địa điểm"
            ])
        }

        let bestItem = Self.rankMapItems(
            response.mapItems,
            prediction: prediction,
            userLocation: userLocation
        )

        let resolvedName = bestItem.name ?? (prediction.title.isEmpty ? "Địa điểm" : prediction.title)
        let resolvedAddress = bestItem.placemark.title ?? prediction.subtitle

        return ResolvedPlace(
            id: prediction.id,
            name: resolvedName,
            formattedAddress: resolvedAddress,
            coordinate: bestItem.placemark.coordinate
        )
    }

    // MARK: - MKLocalSearchCompleterDelegate

    public nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        Task { @MainActor in
            guard let continuation = self.pendingContinuation else { return }
            self.pendingContinuation = nil

            self.completionCache.removeAll()
            var predictions: [SearchPrediction] = []
            for item in completer.results {
                let id = UUID().uuidString
                self.completionCache[id] = item
                predictions.append(SearchPrediction(
                    id: id,
                    title: item.title,
                    subtitle: item.subtitle
                ))
            }
            continuation.resume(returning: predictions)
        }
    }

    public nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in
            guard let continuation = self.pendingContinuation else { return }
            self.pendingContinuation = nil
            continuation.resume(throwing: error)
        }
    }

    // MARK: - Deterministic Ranking of Multiple MapItems

    public static func rankMapItems(
        _ items: [MKMapItem],
        prediction: SearchPrediction,
        userLocation: CLLocationCoordinate2D?
    ) -> MKMapItem {
        guard items.count > 1 else { return items[0] }

        let normTitle = SearchRanking.normalize(prediction.title)
        let normSub = SearchRanking.normalize(prediction.subtitle)

        func score(for item: MKMapItem) -> Double {
            var s: Double = 0.0
            let itemName = SearchRanking.normalize(item.name ?? "")
            let itemAddress = SearchRanking.normalize(item.placemark.title ?? "")

            // Title match
            if itemName == normTitle {
                s += 50.0
            } else if itemName.hasPrefix(normTitle) || normTitle.hasPrefix(itemName) {
                s += 30.0
            } else if itemName.contains(normTitle) {
                s += 15.0
            }

            // Subtitle / address match
            if !normSub.isEmpty {
                if itemAddress.contains(normSub) {
                    s += 20.0
                }
            }

            // Vietnam geographic bounding box bonus (approx 8.0...24.0 N, 102.0...110.5 E)
            let coord = item.placemark.coordinate
            if coord.latitude >= 8.0 && coord.latitude <= 24.0 &&
               coord.longitude >= 102.0 && coord.longitude <= 110.5 {
                s += 25.0
            }

            // User proximity bonus (closer gets up to 15 pts)
            if let userLoc = userLocation {
                let d = RouteGeometry.distanceBetween(userLoc, coord)
                let distBonus = max(0.0, 15.0 - (d / 10_000.0)) // decays over 150km
                s += distBonus
            }

            return s
        }

        let scored = items.map { (bash, score(for: bash)) }
        let sorted = scored.sorted { bash.1 > .1 }
        return sorted[0].0
    }
}

// MARK: - Apple Place Search Service

@MainActor
public final class ApplePlaceSearchService: ObservableObject, PlaceSearchServiceProtocol {

    @Published public var predictions: [SearchPrediction] = []
    @Published public var isLoading: Bool = false
    @Published public var errorMessage: String?

    public var userLocation: CLLocationCoordinate2D?
    public var onPredictionsChanged: (([SearchPrediction]) -> Void)?

    private var autocompleteGeneration: UInt64 = 0
    private var debounceTask: Task<Void, Never>?
    private let debounceDelay: UInt64
    private let adapter: MapKitSearchAdapterProtocol

    public init(
        adapter: MapKitSearchAdapterProtocol? = nil,
        debounceDelay: UInt64 = 300_000_000
    ) {
        self.adapter = adapter ?? DefaultMapKitSearchAdapter()
        self.debounceDelay = debounceDelay
    }

    public func updateQuery(_ query: String) {
        debounceTask?.cancel()
        debounceTask = nil
        autocompleteGeneration &+= 1
        let myGeneration = autocompleteGeneration

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            predictions = []
            isLoading = false
            errorMessage = nil
            onPredictionsChanged?([])
            return
        }

        isLoading = true

        debounceTask = Task { [weak self] in
            guard let self else { return }
            do {
                if self.debounceDelay > 0 {
                    try await Task.sleep(nanoseconds: self.debounceDelay)
                }
                await self.performSearch(query: trimmed, generation: myGeneration)
            } catch {
                if self.autocompleteGeneration == myGeneration {
                    self.isLoading = false
                }
            }
        }
    }

    public func cancelAutocomplete() {
        debounceTask?.cancel()
        debounceTask = nil
        autocompleteGeneration &+= 1
        isLoading = false
    }

    public func clearPredictions() {
        predictions = []
        errorMessage = nil
        isLoading = false
        onPredictionsChanged?([])
    }

    public func resetAll() {
        cancelAutocomplete()
        clearPredictions()
    }

    public func resolve(prediction: SearchPrediction) async throws -> ResolvedPlace {
        try await adapter.resolve(prediction: prediction, userLocation: userLocation)
    }

    private func performSearch(query: String, generation: UInt64) async {
        let region: MKCoordinateRegion?
        if let loc = userLocation {
            // Broad regional ranking bias without restricting distant provinces
            region = MKCoordinateRegion(
                center: loc,
                span: MKCoordinateSpan(latitudeDelta: 2.0, longitudeDelta: 2.0)
            )
        } else {
            // Default Vietnam center
            region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 16.0, longitude: 106.0),
                span: MKCoordinateSpan(latitudeDelta: 10.0, longitudeDelta: 6.0)
            )
        }

        do {
            let results = try await adapter.searchCompletions(query: query, region: region)
            guard autocompleteGeneration == generation else {
                print("[AppleSearch] Discarding stale autocomplete response (gen \(generation) vs \(autocompleteGeneration))")
                return
            }

            self.predictions = results
            self.isLoading = false
            self.errorMessage = nil
            self.onPredictionsChanged?(results)
        } catch is CancellationError {
            // Ignore cancellation
        } catch {
            guard autocompleteGeneration == generation else { return }
            self.predictions = []
            self.isLoading = false
            self.errorMessage = error.localizedDescription
            self.onPredictionsChanged?([])
        }
    }
}
