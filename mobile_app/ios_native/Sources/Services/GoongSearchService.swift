//
//  GoongSearchService.swift
//  Goong Maps REST API — Autocomplete + Place Detail
//
//  Architecture:
//    - All Goong HTTP calls are delegated to a GoongPlacesClientProtocol (injectable for tests).
//    - Autocomplete uses a generation counter to discard stale responses from rapid typing.
//    - Session token is preserved across autocomplete + Place Detail calls for the same
//      search session and rotated only after a successful Place Detail or full session reset.
//    - Results are ranked via SearchRanking before being published.
//
//  Token lifecycle:
//    new query typed     → same token (session in progress)
//    Place Detail called → same token
//    Place Detail OK     → endSearchSession() → token rotated
//    cancelSearch()      → token preserved (search may resume)
//    clearSearch()       → endSearchSession() → token rotated
//
//  Documentation: https://docs.goong.io/rest/place/

import CoreLocation
import Foundation

// MARK: - Goong Data Models

/// A single autocomplete prediction from Goong (post-ranking).
public struct GoongPrediction: Identifiable, Sendable {
    public let id: String            // == placeID
    public let placeID: String
    public let mainText: String      // primary name (street number + street)
    public let secondaryText: String // district, city, province
    public let description: String   // full combined address
    public let structuredFormatting: GoongStructuredFormatting
    public let providerScore: Double?
    public let providerIndex: Int
    public let district: String?
    public let commune: String?
    public let province: String?
}

public struct GoongStructuredFormatting: Sendable {
    public let mainText: String
    public let secondaryText: String
}

/// Resolved location from Goong Place Detail.
public struct GoongLocation: Sendable {
    public let latitude: Double
    public let longitude: Double
    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Full place detail from Goong.
public struct GoongPlace: Sendable {
    public let placeID: String
    public let name: String
    public let formattedAddress: String
    public let location: GoongLocation
    public let types: [String]
}

// MARK: - Search Errors

public enum GoongSearchError: LocalizedError {
    case invalidURL
    case networkError(URLError)
    case decodingError(String)
    case noResults

    public var errorDescription: String? {
        switch self {
        case .invalidURL:             return "URL không hợp lệ"
        case .networkError(let e):    return "Lỗi mạng: \(e.localizedDescription)"
        case .decodingError(let m):   return "Lỗi đọc dữ liệu: \(m)"
        case .noResults:              return "Không tìm thấy kết quả"
        }
    }
}

// MARK: - Search Service

@MainActor
public final class GoongSearchService: ObservableObject {

    // MARK: - Configuration

    /// Autocomplete bias radius in **kilometres** (not metres).
    /// 2000 km covers all of Vietnam including cross-province searches.
    private let searchRadius: Int = 2_000
    private let searchLimit:  Int = 10

    // MARK: - Published State

    @Published public var predictions: [GoongPrediction] = []
    @Published public var isLoading: Bool = false
    @Published public var errorMessage: String?

    // MARK: - Session Token
    // One token per search session; preserved across autocomplete + detail calls.
    // Rotated only by endSearchSession() or resetAll().
    private var sessionToken: String = UUID().uuidString

    // MARK: - Autocomplete Concurrency

    /// Monotonically increasing counter — incremented on every new query.
    /// A response from generation N is discarded if the current generation is N+k.
    private var autocompleteGeneration: UInt64 = 0
    private var debounceTask: Task<Void, Never>?
    /// Debounce delay in nanoseconds. Defaults to 300ms.
    /// Injected in tests as 0 to eliminate timing dependencies.
    private let debounceDelay: UInt64

    // MARK: - User Location (proximity bias)

    public var userLocation: CLLocationCoordinate2D?

    // MARK: - Dependency

    private let client: GoongPlacesClientProtocol

    public init(client: GoongPlacesClientProtocol? = nil, debounceDelay: UInt64 = 300_000_000) {
        if let injected = client {
            self.client = injected
        } else {
            self.client = GoongPlacesHTTPClient()
        }
        self.debounceDelay = debounceDelay
    }

    // MARK: - Autocomplete

    /// Update the search query and trigger a debounced autocomplete request.
    /// Concurrent calls within 300 ms cancel the previous debounce.
    public func updateQuery(_ query: String) {
        // Cancel the previous debounce task and invalidate its generation
        debounceTask?.cancel()
        debounceTask = nil
        autocompleteGeneration &+= 1
        let myGeneration = autocompleteGeneration

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.count >= 2 else {
            // Short query: clear results immediately; any in-flight response is stale
            predictions  = []
            isLoading    = false
            errorMessage = nil
            return
        }

        isLoading = true

        debounceTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: self.debounceDelay)
                await self.performAutocomplete(trimmed, generation: myGeneration)
            } catch {
                // Task cancelled by next keystroke — expected
                await MainActor.run {
                    // Only clear loading if still our generation
                    if self.autocompleteGeneration == myGeneration {
                        self.isLoading = false
                    }
                }
            }
        }
    }

    /// Cancel debounce + invalidate generation. Does NOT rotate session token.
    public func cancelAutocomplete() {
        debounceTask?.cancel()
        debounceTask = nil
        autocompleteGeneration &+= 1
        isLoading = false
    }

    /// Clear published prediction/error state. Does NOT rotate session token.
    public func clearPredictions() {
        predictions  = []
        errorMessage = nil
        isLoading    = false
    }

    /// Rotate the session token and fully cancel autocomplete + clear results.
    /// Call after a successful Place Detail fetch or when the user explicitly cancels
    /// the entire search session.
    public func endSearchSession() {
        cancelAutocomplete()
        clearPredictions()
        sessionToken = UUID().uuidString
    }

    /// Full reset: rotate token, clear everything.
    public func resetAll() {
        endSearchSession()
    }

    // MARK: - Place Detail

    /// Resolve a prediction's `placeID` to a `GoongPlace` with lat/lng.
    /// Uses the current session token — caller must NOT have rotated the token since autocomplete.
    public func getPlaceDetail(placeID: String) async throws -> GoongPlace {
        try await client.placeDetail(placeID: placeID, sessionToken: sessionToken)
    }

    // MARK: - Private

    private func performAutocomplete(_ query: String, generation: UInt64) async {
        let token    = sessionToken
        let location = userLocation

        do {
            let raw = try await client.autocomplete(
                query:        query,
                location:     location,
                radius:       searchRadius,
                limit:        searchLimit,
                sessionToken: token
            )

            // Generation guard: discard if a newer query has already been issued
            guard autocompleteGeneration == generation else {
                print("[Search] Discarding stale autocomplete response (gen \(generation) vs current \(autocompleteGeneration))")
                return
            }

            let ranked   = SearchRanking.rank(raw, query: query)
            let unique   = deduplicated(ranked)
            predictions  = unique.map(toPrediction)
            isLoading    = false
            errorMessage = nil

        } catch is CancellationError {
            // Debounce cancellation — isLoading cleared by the cancellation handler above
        } catch {
            guard autocompleteGeneration == generation else { return }
            isLoading    = false
            predictions  = []
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Deduplication

    private func deduplicated(_ raw: [GoongRawPrediction]) -> [GoongRawPrediction] {
        var seen = Set<String>()
        return raw.filter { seen.insert($0.placeID).inserted }
    }

    // MARK: - Mapping

    private func toPrediction(_ raw: GoongRawPrediction) -> GoongPrediction {
        GoongPrediction(
            id:            raw.placeID,
            placeID:       raw.placeID,
            mainText:      raw.mainText,
            secondaryText: raw.secondaryText,
            description:   raw.description,
            structuredFormatting: GoongStructuredFormatting(
                mainText:      raw.mainText,
                secondaryText: raw.secondaryText
            ),
            providerScore: raw.providerScore,
            providerIndex: raw.providerIndex,
            district:      raw.district,
            commune:       raw.commune,
            province:      raw.province
        )
    }
}
