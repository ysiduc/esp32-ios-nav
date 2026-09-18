import Foundation
import Combine
import CoreLocation
import MapKit

/// Reactive Search Service using Apple MKLocalSearch — 100% free, no API key, built into iOS.
/// Quality is excellent for Vietnam: uses Apple Maps POI database.
@MainActor
public final class PhotonSearchService: ObservableObject {
    @Published public private(set) var results: [SearchResultItem] = []
    @Published public private(set) var isSearching: Bool = false
    @Published public var searchText: String = ""

    private var cancellables = Set<AnyCancellable>()
    private var currentSearchTask: Task<Void, Never>?

    public init() {
        setupDebouncedSearch()
    }

    private func setupDebouncedSearch() {
        $searchText
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .removeDuplicates()
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] query in
                guard let self = self else { return }
                self.currentSearchTask?.cancel()
                if query.isEmpty {
                    self.results = []; self.isSearching = false
                } else {
                    self.currentSearchTask = Task {
                        await self.search(query: query)
                    }
                }
            }
            .store(in: &cancellables)
    }

    /// Search places using Apple MKLocalSearch (completer + request)
    public func search(query: String, near coordinate: CLLocationCoordinate2D? = nil, limit: Int = 10) async {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { self.results = []; return }

        self.isSearching = true
        defer { self.isSearching = false }

        do {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = clean
            request.resultTypes = [.pointOfInterest, .address]

            // Bias search toward Vietnam if no specific location given
            if let coord = coordinate {
                // 50km radius search region centered on user
                let region = MKCoordinateRegion(
                    center: coord,
                    latitudinalMeters: 50_000,
                    longitudinalMeters: 50_000
                )
                request.region = region
            } else {
                // Default to Vietnam bounding box
                let vietnamCenter = CLLocationCoordinate2D(latitude: 16.0, longitude: 107.5)
                request.region = MKCoordinateRegion(
                    center: vietnamCenter,
                    span: MKCoordinateSpan(latitudeDelta: 15.0, longitudeDelta: 8.0)
                )
            }

            let search = MKLocalSearch(request: request)
            let response = try await search.start()

            let items = response.mapItems.prefix(limit).map { item -> SearchResultItem in
                let placemark = item.placemark
                let coord     = placemark.coordinate

                var dist: Double? = nil
                if let userLoc = coordinate {
                    let locA = CLLocation(latitude: userLoc.latitude, longitude: userLoc.longitude)
                    let locB = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                    dist = locA.distance(from: locB)
                }

                // Build clean name
                let name     = item.name ?? placemark.name ?? "Địa điểm"
                let street   = placemark.thoroughfare
                let district = placemark.subLocality ?? placemark.locality
                let city     = placemark.administrativeArea

                return SearchResultItem(
                    name: name,
                    street: street,
                    houseNumber: placemark.subThoroughfare,
                    district: district,
                    city: city,
                    country: placemark.country,
                    coordinate: coord,
                    distanceMeters: dist
                )
            }

            self.results = Array(items)
            print("[MKLocalSearch] '\(clean)' → \(items.count) results")

        } catch {
            if (error as? CancellationError) == nil {
                print("[MKLocalSearch] Search error: \(error.localizedDescription)")
            }
            self.results = []
        }
    }

    public func clear() {
        currentSearchTask?.cancel()
        searchText = ""; results = []; isSearching = false
    }
}
