import Foundation
import CoreLocation

/// Represents a geocoded search result item returned by Photon / OpenStreetMap
public struct SearchResultItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let street: String?
    public let houseNumber: String?
    public let district: String?
    public let city: String?
    public let country: String?
    public let coordinate: CLLocationCoordinate2D
    public let distanceMeters: Double?

    public init(
        id: String = UUID().uuidString,
        name: String,
        street: String? = nil,
        houseNumber: String? = nil,
        district: String? = nil,
        city: String? = nil,
        country: String? = nil,
        coordinate: CLLocationCoordinate2D,
        distanceMeters: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.street = street
        self.houseNumber = houseNumber
        self.district = district
        self.city = city
        self.country = country
        self.coordinate = coordinate
        self.distanceMeters = distanceMeters
    }

    /// Full human-readable display address
    public var formattedAddress: String {
        var parts: [String] = []
        if let street = street, !name.contains(street) {
            if let house = houseNumber {
                parts.append("\(house) \(street)")
            } else {
                parts.append(street)
            }
        }
        if let district = district, !name.contains(district) {
            parts.append(district)
        }
        if let city = city, !name.contains(city) {
            parts.append(city)
        }
        if parts.isEmpty {
            return name
        }
        return "\(name), " + parts.joined(separator: ", ")
    }

    /// Subtitle string suitable for dropdown items
    public var formattedSubtitle: String {
        var parts: [String] = []
        if let street = street {
            if let house = houseNumber {
                parts.append("\(house) \(street)")
            } else {
                parts.append(street)
            }
        }
        if let district = district { parts.append(district) }
        if let city = city { parts.append(city) }
        return parts.joined(separator: ", ")
    }

    public var formattedDistance: String {
        guard let dist = distanceMeters else { return "" }
        if dist >= 1000 {
            return String(format: "%.1f km", dist / 1000.0)
        }
        return "\(Int(dist.rounded())) m"
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(coordinate.latitude)
        hasher.combine(coordinate.longitude)
    }

    public static func == (lhs: SearchResultItem, rhs: SearchResultItem) -> Bool {
        lhs.id == rhs.id &&
        lhs.coordinate.latitude == rhs.coordinate.latitude &&
        lhs.coordinate.longitude == rhs.coordinate.longitude
    }
}

// MARK: - Photon GeoJSON Decodable Structures
struct PhotonResponse: Decodable {
    let type: String
    let features: [PhotonFeature]
}

struct PhotonFeature: Decodable {
    let geometry: PhotonGeometry
    let properties: PhotonProperties
}

struct PhotonGeometry: Decodable {
    let coordinates: [Double] // [lon, lat]
}

struct PhotonProperties: Decodable {
    let osmId: Int?
    let osmType: String?
    let name: String?
    let street: String?
    let housenumber: String?
    let locality: String?
    let district: String?
    let city: String?
    let state: String?
    let country: String?
    let postcode: String?

    enum CodingKeys: String, CodingKey {
        case osmId = "osm_id"
        case osmType = "osm_type"
        case name, street, housenumber, locality, district, city, state, country, postcode
    }
}
