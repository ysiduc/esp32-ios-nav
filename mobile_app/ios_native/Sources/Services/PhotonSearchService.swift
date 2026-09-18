import Foundation
import Combine
import CoreLocation

/// Reactive Search Service using self-hosted Photon geocoder.
/// API is identical to Komoot Photon — only base URL changes.
/// Photon repo: https://github.com/komoot/photon
@MainActor
public final class PhotonSearchService: ObservableObject {
    @Published public private(set) var results: [SearchResultItem] = []
    @Published public private(set) var isSearching: Bool = false
    @Published public var searchText: String = ""

    private var cancellables = Set<AnyCancellable>()
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
        setupDebouncedSearch()
    }

    private func setupDebouncedSearch() {
        $searchText
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .removeDuplicates()
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] query in
                guard let self = self else { return }
                if query.isEmpty {
                    self.results = []; self.isSearching = false
                } else {
                    Task { await self.search(query: query) }
                }
            }
            .store(in: &cancellables)
    }

    public func search(query: String, near coordinate: CLLocationCoordinate2D? = nil, limit: Int = 10) async {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { self.results = []; return }

        self.isSearching = true
        defer { self.isSearching = false }

        // Use self-hosted Photon from NavServerConfig
        guard var components = URLComponents(string: NavServerConfig.geocodingURL) else { return }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "q",     value: clean),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "lang",  value: "vi")
        ]
        if let coord = coordinate {
            queryItems.append(URLQueryItem(name: "lat", value: String(format: "%.6f", coord.latitude)))
            queryItems.append(URLQueryItem(name: "lon", value: String(format: "%.6f", coord.longitude)))
        }
        components.queryItems = queryItems
        guard let url = components.url else { return }

        do {
            var request = URLRequest(url: url)
            request.setValue("ESP32_Native_Navigator/1.0", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 8.0

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return }

            // Photon GeoJSON response
            let decoded = try JSONDecoder().decode(PhotonResponse.self, from: data)
            let items = decoded.features.compactMap { feature -> SearchResultItem? in
                guard feature.geometry.coordinates.count >= 2 else { return nil }
                let lon = feature.geometry.coordinates[0]
                let lat = feature.geometry.coordinates[1]
                let itemCoord = CLLocationCoordinate2D(latitude: lat, longitude: lon)

                let props = feature.properties
                let name  = props.name ?? props.street ?? "Địa điểm"

                var dist: Double? = nil
                if let userLoc = coordinate {
                    let locA = CLLocation(latitude: userLoc.latitude, longitude: userLoc.longitude)
                    let locB = CLLocation(latitude: lat, longitude: lon)
                    dist = locA.distance(from: locB)
                }

                return SearchResultItem(
                    name: name,
                    street: props.street,
                    houseNumber: props.housenumber,
                    district: props.district ?? props.locality,
                    city: props.city ?? props.state,
                    country: props.country,
                    coordinate: itemCoord,
                    distanceMeters: dist
                )
            }
            self.results = items
        } catch {
            print("[Photon] Search error: \(error.localizedDescription)")
            self.results = []
        }
    }

    public func clear() {
        self.searchText = ""; self.results = []; self.isSearching = false
    }
}
