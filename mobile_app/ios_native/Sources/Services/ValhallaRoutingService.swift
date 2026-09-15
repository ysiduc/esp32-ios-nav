import Foundation
import CoreLocation

/// Service for calculating Turn-by-Turn routes using the Valhalla Routing Engine
public final class ValhallaRoutingService: Sendable {
    private let baseUrl: String
    private let session: URLSession

    public init(
        baseUrl: String = "https://valhalla1.openstreetmap.de",
        session: URLSession = .shared
    ) {
        self.baseUrl = baseUrl
        self.session = session
    }

    /// Calculate a detailed turn-by-turn route
    public func calculateRoute(
        from start: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        costing: String = "auto" // 'auto', 'motorcycle', 'bicycle'
    ) async throws -> (route: NavRoute, rawJson: Data) {
        guard let url = URL(string: "\(baseUrl)/route") else {
            throw URLError(.badURL)
        }

        let requestPayload: [String: Any] = [
            "locations": [
                ["lat": start.latitude, "lon": start.longitude, "type": "break"],
                ["lat": destination.latitude, "lon": destination.longitude, "type": "break"]
            ],
            "costing": costing,
            "costing_options": [
                "auto": ["country_crossing_penalty": 2000.0]
            ],
            "directions_options": [
                "units": "kilometers",
                "language": "vi-VN" // Vietnamese turn instructions
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ESP32_Native_Navigator/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestPayload)
        request.timeoutInterval = 12.0

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let trip = json["trip"] as? [String: Any],
              let legs = trip["legs"] as? [[String: Any]],
              let firstLeg = legs.first,
              let summary = trip["summary"] as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }

        let totalDistance = ((summary["length"] as? NSNumber)?.doubleValue ?? 0.0) * 1000.0
        let totalDuration = (summary["time"] as? NSNumber)?.doubleValue ?? 0.0

        // Decode Valhalla Shape (Precision 6 Polyline)
        let shapeStr = (firstLeg["shape"] as? String) ?? ""
        let polylineCoords = decodePolyline6(shapeStr)

        // Parse maneuvers
        var steps: [NavStep] = []
        let maneuvers = (firstLeg["maneuvers"] as? [[String: Any]]) ?? []

        for (index, m) in maneuvers.enumerated() {
            let instruction = ((m["instruction"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let streetNames = (m["street_names"] as? [String]) ?? []
            let streetName = streetNames.first ?? "Đường tiếp theo"
            let distMeters = ((m["length"] as? NSNumber)?.doubleValue ?? 0.0) * 1000.0
            let durSeconds = (m["time"] as? NSNumber)?.doubleValue ?? 0.0
            let typeCode = (m["type"] as? Int) ?? 0

            let beginShapeIndex = (m["begin_shape_index"] as? Int) ?? 0
            let stepCoord = (beginShapeIndex < polylineCoords.count)
                ? polylineCoords[beginShapeIndex]
                : (polylineCoords.first ?? start)

            let maneuver = ManeuverType.fromValhalla(type: typeCode)

            steps.append(NavStep(
                id: index,
                instruction: instruction.isEmpty ? maneuver.localizedInstruction : instruction,
                streetName: streetName,
                distanceMeters: distMeters,
                durationSeconds: durSeconds,
                coordinate: stepCoord,
                maneuverType: maneuver
            ))
        }

        let legSummary = (firstLeg["summary"] as? [String: Any])?["name"] as? String ?? "Lộ trình Valhalla"
        let navRoute = NavRoute(
            totalDistanceMeters: totalDistance,
            totalDurationSeconds: totalDuration,
            coordinates: polylineCoords,
            steps: steps,
            summary: legSummary
        )

        return (route: navRoute, rawJson: data)
    }

    /// Decode Valhalla Precision 6 encoded polyline string
    private func decodePolyline6(_ encoded: String) -> [CLLocationCoordinate2D] {
        var coordinates: [CLLocationCoordinate2D] = []
        var index = encoded.startIndex
        var lat = 0
        var lon = 0

        while index < encoded.endIndex {
            var b: Int
            var shift = 0
            var result = 0
            repeat {
                b = Int(encoded[index].asciiValue ?? 63) - 63
                index = encoded.index(after: index)
                result |= (b & 0x1F) << shift
                shift += 5
            } while b >= 0x20
            let deltaLat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1))
            lat += deltaLat

            shift = 0
            result = 0
            repeat {
                b = Int(encoded[index].asciiValue ?? 63) - 63
                index = encoded.index(after: index)
                result |= (b & 0x1F) << shift
                shift += 5
            } while b >= 0x20
            let deltaLon = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1))
            lon += deltaLon

            let finalLat = Double(lat) / 1e6
            let finalLon = Double(lon) / 1e6
            coordinates.append(CLLocationCoordinate2D(latitude: finalLat, longitude: finalLon))
        }

        return coordinates
    }
}
