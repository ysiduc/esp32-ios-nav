import Foundation
import Combine
import CoreLocation

/// Reactive Search Service using Komoot Photon API with Combine debounce (400ms)
@MainActor
public final class PhotonSearchService: ObservableObject {
    @Published public private(set) var results: [SearchResultItem] = []
    @Published public private(set) var isSearching: Bool = false
    @Published public var searchText: String = ""

    private var cancellables = Set<AnyCancellable>()
    private let session: URLSession
    private let baseUrl = "https://photon.komoot.io/api"

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

    /// Direct async search query
    public func search(query: String, near coordinate: CLLocationCoordinate2D? = nil, limit: Int = 10) async {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            self.results = []
            return
        }

        self.isSearching = true
        defer { self.isSearching = false }

        guard var components = URLComponents(string: baseUrl) else { return }
        var queryItems = [
            URLQueryItem(name: "q", value: clean),
            URLQueryItem(name: "limit", value: "\(limit)")
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
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return
            }

            let decoded = try JSONDecoder().decode(PhotonResponse.self, from: data)
            let items = decoded.features.compactMap { feature -> SearchResultItem? in
                guard feature.geometry.coordinates.count >= 2 else { return nil }
                let lon = feature.geometry.coordinates[0]
                let lat = feature.geometry.coordinates[1]
                let itemCoord = CLLocationCoordinate2D(latitude: lat, longitude: lon)

                let props = feature.properties
                let name = props.name ?? props.street ?? "Địa điểm"

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
            print("[PhotonSearchService] Search error: \(error.localizedDescription)")
            self.results = []
        }
    }

    /// Clear search results
    public func clear() {
        self.searchText = ""
        self.results = []
        self.isSearching = false
    }
}
