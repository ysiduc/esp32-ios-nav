import Foundation
import Combine
import CoreLocation

/// Reactive Search Service using Goong Places Autocomplete API V2 with Combine debounce (400ms).
/// Replaces Komoot Photon with Goong for Vietnam-specific POI data and addresses.
///
/// API: https://rsapi.goong.io/v2/place/autocomplete
@MainActor
public final class PhotonSearchService: ObservableObject {
    @Published public private(set) var results: [SearchResultItem] = []
    @Published public private(set) var isSearching: Bool = false
    @Published public var searchText: String = ""

    private var cancellables = Set<AnyCancellable>()
    private let session: URLSession

    // Goong Places Autocomplete V2 endpoint
    private let baseUrl = "https://rsapi.goong.io/v2/place/autocomplete"
    private let apiKey  = ValhallaRoutingService.goongApiKey

    public init(session: URLSession = .shared) {
        self.session = session
        setupDebouncedSearch()
    }

    /// Setup Combine pipeline with 400ms debounce
    private func setupDebouncedSearch() {
        $searchText
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .removeDuplicates()
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] query in
                guard let self = self else { return }
                if query.isEmpty {
                    self.results = []
                    self.isSearching = false
                } else {
                    Task {
                        await self.search(query: query)
                    }
                }
            }
            .store(in: &cancellables)
    }

    /// Search places using Goong Autocomplete API
    public func search(query: String, near coordinate: CLLocationCoordinate2D? = nil, limit: Int = 10) async {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            self.results = []
            return
        }

        self.isSearching = true
        defer { self.isSearching = false }

        guard var components = URLComponents(string: baseUrl) else { return }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "input",   value: clean),
            URLQueryItem(name: "limit",   value: "\(limit)"),
            URLQueryItem(name: "api_key", value: apiKey)
        ]

        // Bias results toward user's current location if available
        if let coord = coordinate {
            queryItems.append(URLQueryItem(name: "location", value: "\(coord.latitude),\(coord.longitude)"))
        }

        components.queryItems = queryItems
        guard let url = components.url else { return }

        do {
            var request = URLRequest(url: url)
            request.setValue("ESP32_Native_Navigator/1.0", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 8.0

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return
            }

            // Goong Autocomplete response:
            // { "predictions": [ { "place_id": "...", "description": "...", "compound": { "district": "...", "province": "..." }, "geometry": { "location": { "lat": ..., "lng": ... } } } ] }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let predictions = json["predictions"] as? [[String: Any]] else {
                return
            }

            var items: [SearchResultItem] = []
            for pred in predictions {
                let placeId     = pred["place_id"] as? String ?? ""
                let description = (pred["description"] as? String ?? "Địa điểm").trimmingCharacters(in: .whitespacesAndNewlines)
                let compound    = pred["compound"] as? [String: Any]
                let district    = compound?["district"] as? String
                let province    = compound?["province"] as? String

                // Try to get coordinate directly from prediction (Goong v2 may include it)
                var itemCoord: CLLocationCoordinate2D? = nil
                if let geo = pred["geometry"] as? [String: Any],
                   let loc = geo["location"] as? [String: Any],
                   let lat = loc["lat"] as? Double,
                   let lng = loc["lng"] as? Double {
                    itemCoord = CLLocationCoordinate2D(latitude: lat, longitude: lng)
                }

                // If no geometry in prediction, geocode using place_id
                if itemCoord == nil && !placeId.isEmpty {
                    itemCoord = await geocodePlaceId(placeId)
                }

                guard let coord = itemCoord else { continue }

                var dist: Double? = nil
                if let userLoc = coordinate {
                    let locA = CLLocation(latitude: userLoc.latitude, longitude: userLoc.longitude)
                    let locB = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                    dist = locA.distance(from: locB)
                }

                // Parse name vs address from description ("Name, Street, District, Province")
                let parts = description.components(separatedBy: ", ")
                let name  = parts.first ?? description
                let street = parts.count > 1 ? parts[1] : nil

                items.append(SearchResultItem(
                    name: name,
                    street: street,
                    houseNumber: nil,
                    district: district,
                    city: province,
                    country: "Việt Nam",
                    coordinate: coord,
                    distanceMeters: dist
                ))
            }

            self.results = items
        } catch {
            print("[GoongSearch] Error: \(error.localizedDescription)")
            self.results = []
        }
    }

    /// Geocode a Goong place_id to get exact coordinates
    private func geocodePlaceId(_ placeId: String) async -> CLLocationCoordinate2D? {
        guard var components = URLComponents(string: "https://rsapi.goong.io/v2/place/detail") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "place_id", value: placeId),
            URLQueryItem(name: "api_key",  value: apiKey)
        ]
        guard let url = components.url else { return nil }

        do {
            let (data, _) = try await session.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let geo = result["geometry"] as? [String: Any],
                  let loc = geo["location"] as? [String: Any],
                  let lat = loc["lat"] as? Double,
                  let lng = loc["lng"] as? Double else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lng)
        } catch {
            return nil
        }
    }

    /// Clear search results and text
    public func clear() {
        self.searchText = ""
        self.results = []
        self.isSearching = false
    }
}
