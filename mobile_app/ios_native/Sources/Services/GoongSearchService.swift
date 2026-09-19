//
//  GoongSearchService.swift
//  Goong Maps REST API — Autocomplete + Place Detail
//
//  Endpoints used:
//    GET https://rsapi.goong.io/Place/AutoComplete
//      Params: input={query}&api_key={key}&sessiontoken={uuid}&radius=50000&location={lat,lng}
//    GET https://rsapi.goong.io/Place/Detail
//      Params: place_id={id}&api_key={key}
//
//  Documentation: https://docs.goong.io/rest/place/
//

import CoreLocation
import Foundation

// MARK: - Goong Data Models

/// A single autocomplete prediction from Goong.
public struct GoongPrediction: Identifiable, Sendable {
    public let id: String           // place_id
    public let placeID: String
    public let mainText: String     // primary name (street number + street)
    public let secondaryText: String // district, city, province
    public let description: String  // full combined address
    public let structuredFormatting: GoongStructuredFormatting
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

// MARK: - GoongSearchService

public enum GoongSearchError: LocalizedError {
    case invalidURL
    case networkError(Error)
    case decodingError(String)
    case noResults

    public var errorDescription: String? {
        switch self {
        case .invalidURL:           return "URL không hợp lệ"
        case .networkError(let e): return "Lỗi mạng: \(e.localizedDescription)"
        case .decodingError(let m):return "Lỗi đọc dữ liệu: \(m)"
        case .noResults:           return "Không tìm thấy kết quả"
        }
    }
}

@MainActor
public final class GoongSearchService: ObservableObject {

    // MARK: - Configuration
    /// Goong API key (autocomplete + place detail).
    /// Get your key at: https://account.goong.io/keys
    private let apiKey = "LyG3pKyU88XZHKpKudhyUoG9jsB5i8twzm8vXfIq"
    private let baseURL = "https://rsapi.goong.io"

    // Search radius around user location (metres)
    private let searchRadius: Int = 50_000

    // Session token groups autocomplete + detail calls for billing
    private var sessionToken: String = UUID().uuidString

    // MARK: - Published State
    @Published public var predictions: [GoongPrediction] = []
    @Published public var isLoading: Bool = false
    @Published public var errorMessage: String?

    // MARK: - Debouncing
    private var debounceTask: Task<Void, Never>?
    private let debounceDelay: UInt64 = 300_000_000 // 300ms in nanoseconds

    // User location for biasing results
    public var userLocation: CLLocationCoordinate2D?

    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    public init() {}

    // MARK: - Autocomplete

    /// Trigger debounced autocomplete search.
    /// Cancels any in-flight request and waits 300ms before firing.
    public func search(_ query: String) {
        debounceTask?.cancel()
        debounceTask = nil

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            predictions = []
            isLoading   = false
            return
        }

        debounceTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: self.debounceDelay)
                await self.performAutocomplete(trimmed)
            } catch {
                // Task cancelled — this is expected on rapid typing
            }
        }
    }

    /// Cancel active search and clear results.
    public func clear() {
        debounceTask?.cancel()
        debounceTask = nil
        predictions  = []
        isLoading    = false
        errorMessage = nil
        // Rotate session token after a completed search session
        sessionToken = UUID().uuidString
    }

    private func performAutocomplete(_ query: String) async {
        isLoading = true
        errorMessage = nil

        // Encode query
        var components = URLComponents(string: "\(baseURL)/Place/AutoComplete")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "input",        value: query),
            URLQueryItem(name: "api_key",      value: apiKey),
            URLQueryItem(name: "sessiontoken", value: sessionToken),
            URLQueryItem(name: "radius",       value: "\(searchRadius)"),
        ]

        // Bias towards user location if available
        if let loc = userLocation {
            queryItems.append(URLQueryItem(
                name: "location",
                value: String(format: "%.6f,%.6f", loc.latitude, loc.longitude)
            ))
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            isLoading    = false
            errorMessage = GoongSearchError.invalidURL.localizedDescription
            return
        }

        do {
            let (data, response) = try await urlSession.data(from: url)

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw GoongSearchError.networkError(
                    URLError(.badServerResponse)
                )
            }

            let decoded = try parseAutocompleteResponse(data)
            self.predictions = decoded
            self.isLoading   = false

        } catch is CancellationError {
            isLoading = false
        } catch let err as GoongSearchError {
            isLoading    = false
            errorMessage = err.localizedDescription
            predictions  = []
        } catch {
            isLoading    = false
            errorMessage = error.localizedDescription
            predictions  = []
        }
    }

    // MARK: - Place Detail

    /// Resolve a prediction's `placeID` to a precise `GoongPlace` with lat/lng.
    public func getPlaceDetail(placeID: String) async throws -> GoongPlace {
        var components = URLComponents(string: "\(baseURL)/Place/Detail")!
        components.queryItems = [
            URLQueryItem(name: "place_id",     value: placeID),
            URLQueryItem(name: "api_key",      value: apiKey),
            URLQueryItem(name: "sessiontoken", value: sessionToken),
        ]

        guard let url = components.url else {
            throw GoongSearchError.invalidURL
        }

        let (data, response) = try await urlSession.data(from: url)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw GoongSearchError.networkError(URLError(.badServerResponse))
        }

        return try parsePlaceDetailResponse(data)
    }

    // MARK: - JSON Parsing

    private func parseAutocompleteResponse(_ data: Data) throws -> [GoongPrediction] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GoongSearchError.decodingError("Invalid JSON root")
        }

        // Goong returns: {"predictions": [...], "status": "OK"}
        guard let predictions = root["predictions"] as? [[String: Any]] else {
            // status != OK or empty result
            return []
        }

        return predictions.compactMap { p -> GoongPrediction? in
            guard let placeID = p["place_id"] as? String,
                  let desc    = p["description"] as? String else { return nil }

            let sf = p["structured_formatting"] as? [String: Any]
            let mainText      = sf?["main_text"]      as? String ?? desc
            let secondaryText = sf?["secondary_text"] as? String ?? ""

            return GoongPrediction(
                id: placeID,
                placeID: placeID,
                mainText: mainText,
                secondaryText: secondaryText,
                description: desc,
                structuredFormatting: GoongStructuredFormatting(
                    mainText: mainText,
                    secondaryText: secondaryText
                )
            )
        }
    }

    private func parsePlaceDetailResponse(_ data: Data) throws -> GoongPlace {
        guard let root   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any] else {
            throw GoongSearchError.decodingError("Missing result field")
        }

        guard let placeID   = result["place_id"]          as? String,
              let name      = result["name"]               as? String,
              let address   = result["formatted_address"]  as? String,
              let geometry  = result["geometry"]           as? [String: Any],
              let location  = geometry["location"]         as? [String: Any],
              let lat       = location["lat"]               as? Double,
              let lng       = location["lng"]               as? Double else {
            throw GoongSearchError.decodingError("Missing required fields in Place Detail response")
        }

        let types = result["types"] as? [String] ?? []

        return GoongPlace(
            placeID: placeID,
            name: name,
            formattedAddress: address,
            location: GoongLocation(latitude: lat, longitude: lng),
            types: types
        )
    }
}
