//
//  GoongPlacesClient.swift
//  Protocol abstraction + HTTP implementation for Goong Places REST API.
//
//  Endpoints:
//    GET https://rsapi.goong.io/Place/AutoComplete
//    GET https://rsapi.goong.io/Place/Detail
//
//  Unit tests inject MockGoongPlacesClient; production uses GoongPlacesHTTPClient.
//

import CoreLocation
import Foundation

// MARK: - Request Builder

/// Deterministic, testable URL builder for Goong REST API endpoints.
public enum GoongRequestBuilder {
    public static let baseURL = "https://rsapi.goong.io"

    public static func buildAutocompleteURL(
        apiKey: String,
        query: String,
        location: CLLocationCoordinate2D?,
        radius: Int,
        limit: Int,
        sessionToken: String
    ) -> URL? {
        var components = URLComponents(string: "\(baseURL)/Place/AutoComplete")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "input",         value: query),
            URLQueryItem(name: "api_key",       value: apiKey),
            URLQueryItem(name: "sessiontoken",  value: sessionToken),
            URLQueryItem(name: "radius",        value: "\(radius)"),
            URLQueryItem(name: "limit",         value: "\(limit)"),
            URLQueryItem(name: "more_compound", value: "true"),
        ]
        if let loc = location {
            items.append(URLQueryItem(
                name: "location",
                value: String(format: "%.6f,%.6f", loc.latitude, loc.longitude)
            ))
        }
        components.queryItems = items
        return components.url
    }

    public static func buildPlaceDetailURL(
        apiKey: String,
        placeID: String,
        sessionToken: String
    ) -> URL? {
        var components = URLComponents(string: "\(baseURL)/Place/Detail")!
        components.queryItems = [
            URLQueryItem(name: "place_id",     value: placeID),
            URLQueryItem(name: "api_key",      value: apiKey),
            URLQueryItem(name: "sessiontoken", value: sessionToken),
        ]
        return components.url
    }
}

// MARK: - Raw prediction model (pre-ranking)

/// A single autocomplete prediction as returned by Goong — not yet ranked or deduplicated.
public struct GoongRawPrediction: Sendable {
    public let placeID: String
    public let mainText: String       // primary name (street number + street)
    public let secondaryText: String  // district/city/province combined
    public let description: String    // full combined address
    public let providerScore: Double? // Goong ranking signal; nil when absent
    public let providerIndex: Int     // 0-based position in Goong response (stable tie-break)
    public let district: String?      // from more_compound
    public let commune: String?       // from more_compound
    public let province: String?      // from more_compound

    public init(
        placeID: String,
        mainText: String,
        secondaryText: String,
        description: String,
        providerScore: Double? = nil,
        providerIndex: Int = 0,
        district: String? = nil,
        commune: String? = nil,
        province: String? = nil
    ) {
        self.placeID       = placeID
        self.mainText      = mainText
        self.secondaryText = secondaryText
        self.description   = description
        self.providerScore = providerScore
        self.providerIndex = providerIndex
        self.district      = district
        self.commune       = commune
        self.province      = province
    }
}

// MARK: - Protocol

/// Testable abstraction over the Goong Places REST API.
/// All implementations must be `@MainActor`-safe.
@MainActor
public protocol GoongPlacesClientProtocol: AnyObject {
    /// Fetch autocomplete predictions for `query`.
    /// - Parameters:
    ///   - query: User-typed search string (already trimmed by caller).
    ///   - location: Optional user coordinate for proximity biasing.
    ///   - radius: Bias radius in **kilometres**. Use 2000 for Vietnam-wide.
    ///   - limit: Maximum number of predictions to request. Goong default is 5; use 10.
    ///   - sessionToken: UUID string grouping this autocomplete call with its Place Detail.
    func autocomplete(
        query: String,
        location: CLLocationCoordinate2D?,
        radius: Int,
        limit: Int,
        sessionToken: String
    ) async throws -> [GoongRawPrediction]

    /// Resolve `placeID` to a full `GoongPlace` (lat/lng + metadata).
    /// - Parameters:
    ///   - placeID: The `place_id` from an autocomplete prediction.
    ///   - sessionToken: Must match the token used for the preceding autocomplete calls.
    func placeDetail(placeID: String, sessionToken: String) async throws -> GoongPlace
}

// MARK: - HTTP Implementation

/// Production HTTP client that calls the real Goong REST API.
/// Reads the API key from `GoongConfiguration.apiKey()` — never hardcodes credentials.
@MainActor
public final class GoongPlacesHTTPClient: GoongPlacesClientProtocol {

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = 10
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    public init() {}

    // MARK: - Autocomplete

    public func autocomplete(
        query: String,
        location: CLLocationCoordinate2D?,
        radius: Int,
        limit: Int,
        sessionToken: String
    ) async throws -> [GoongRawPrediction] {
        let apiKey = try GoongConfiguration.apiKey()

        guard let url = GoongRequestBuilder.buildAutocompleteURL(
            apiKey: apiKey,
            query: query,
            location: location,
            radius: radius,
            limit: limit,
            sessionToken: sessionToken
        ) else {
            throw GoongSearchError.invalidURL
        }

        // Log without API key for safety
        print("[GoongClient] Autocomplete: \(query.prefix(40)) radius=\(radius)km limit=\(limit)")

        let (data, response) = try await session.data(from: url)
        try validateHTTPResponse(response)
        return try Self.parseAutocompleteResponse(data)
    }

    // MARK: - Place Detail

    public func placeDetail(placeID: String, sessionToken: String) async throws -> GoongPlace {
        let apiKey = try GoongConfiguration.apiKey()

        guard let url = GoongRequestBuilder.buildPlaceDetailURL(
            apiKey: apiKey,
            placeID: placeID,
            sessionToken: sessionToken
        ) else {
            throw GoongSearchError.invalidURL
        }

        print("[GoongClient] PlaceDetail: \(placeID.prefix(40))")

        let (data, response) = try await session.data(from: url)
        try validateHTTPResponse(response)
        return try Self.parsePlaceDetailResponse(data)
    }

    // MARK: - Response Parsing (public & testable)

    nonisolated public static func parseAutocompleteResponse(_ data: Data) throws -> [GoongRawPrediction] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GoongSearchError.decodingError("Invalid JSON root")
        }

        guard let status = root["status"] as? String else {
            throw GoongSearchError.decodingError("Missing status in response")
        }

        switch status {
        case "OK":
            guard let rawPredictions = root["predictions"] as? [[String: Any]] else {
                return []
            }

            return rawPredictions.enumerated().compactMap { index, p -> GoongRawPrediction? in
                guard let placeID = p["place_id"]    as? String,
                      let desc    = p["description"] as? String else { return nil }

                let sf            = p["structured_formatting"] as? [String: Any]
                let mainText      = sf?["main_text"]      as? String ?? desc
                let secondaryText = sf?["secondary_text"] as? String ?? ""

                // more_compound provides sub-components (all optional)
                let compound  = p["compound"]       as? [String: Any]
                let district  = compound?["district"]  as? String
                let commune   = compound?["commune"]   as? String
                let province  = compound?["province"]  as? String

                // Goong returns "score": 633.7587 as primary; fallback to legacy "provider_ranking"
                let score: Double?
                if let s = p["score"] as? Double {
                    score = s
                } else if let s = p["score"] as? Int {
                    score = Double(s)
                } else if let s = p["provider_ranking"] as? Double {
                    score = s
                } else if let s = p["provider_ranking"] as? Int {
                    score = Double(s)
                } else {
                    score = nil
                }

                return GoongRawPrediction(
                    placeID:       placeID,
                    mainText:      mainText,
                    secondaryText: secondaryText,
                    description:   desc,
                    providerScore: score,
                    providerIndex: index,
                    district:      district,
                    commune:       commune,
                    province:      province
                )
            }

        case "ZERO_RESULTS":
            return []

        default:
            throw GoongSearchError.apiStatus(status)
        }
    }

    nonisolated public static func parsePlaceDetailResponse(_ data: Data) throws -> GoongPlace {
        guard let root   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any] else {
            throw GoongSearchError.decodingError("Missing result field")
        }

        guard let placeID  = result["place_id"]          as? String,
              let name     = result["name"]               as? String,
              let address  = result["formatted_address"]  as? String,
              let geometry = result["geometry"]            as? [String: Any],
              let location = geometry["location"]          as? [String: Any],
              let lat      = location["lat"]               as? Double,
              let lng      = location["lng"]               as? Double else {
            throw GoongSearchError.decodingError("Missing required fields in Place Detail response")
        }

        let types = result["types"] as? [String] ?? []
        return GoongPlace(
            placeID:          placeID,
            name:             name,
            formattedAddress: address,
            location:         GoongLocation(latitude: lat, longitude: lng),
            types:            types
        )
    }

    // MARK: - Private helpers

    private func validateHTTPResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw GoongSearchError.networkError(URLError(.badServerResponse))
        }
    }
}
