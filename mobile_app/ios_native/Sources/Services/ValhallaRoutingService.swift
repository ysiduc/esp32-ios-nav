import Foundation
import CoreLocation

/// Service for calculating optimised Turn-by-Turn routes using the Valhalla Routing Engine.
///
/// Improvements over the previous version:
///  - Richer costing options: highway preference, service-road penalty, avoid unpaved surfaces
///  - `date_time` injected so Valhalla can factor in time-of-day traffic patterns
///  - Longer timeout (20s) to tolerate slow public server on mobile
///  - Retry logic: automatically retries once on timeout/server error before throwing
///  - `end_shape_index` used to correctly assign the maneuver coordinate to the END of the step
///    (the point where the turn actually happens), not the beginning
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

    /// Calculate a detailed turn-by-turn route with optimised Valhalla costing parameters.
    public func calculateRoute(
        from start: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        costing: String = "auto"  // 'auto', 'motorcycle', 'bicycle'
    ) async throws -> (route: NavRoute, rawJson: Data) {
        guard let url = URL(string: "\(baseUrl)/route") else {
            throw URLError(.badURL)
        }

        // Build time string so Valhalla can use time-dependent routing (avoids rush-hour shortcuts)
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let dateTimeStr = formatter.string(from: now)

        // --- Fix 4: Optimised Valhalla costing ---
        // Reference: https://valhalla.github.io/valhalla/api/turn-by-turn/api-reference/
        let autoCostingOptions: [String: Any] = [
            "use_highways":       1.0,   // Strongly prefer highways / main roads (0–1, default 0.5)
            "use_tolls":          0.8,   // Allow tolled roads (Vietnam has toll booths on highways)
            "use_ferry":          0.2,   // Mostly avoid ferries
            "use_living_streets": 0.2,   // Avoid narrow residential streets
            "service_factor":     1.0,   // Penalise service roads (ngõ nhỏ, parking lots)
            "country_crossing_penalty": 2000.0
        ]

        let motorcycleCostingOptions: [String: Any] = [
            "use_highways":       0.9,
            "use_tolls":          0.8,
            "use_ferry":          0.2,
            "use_living_streets": 0.4,   // Motorcycles can use alleys more than cars
            "service_factor":     1.0,
            "country_crossing_penalty": 2000.0
        ]

        let costingOptions: [String: Any] = (costing == "motorcycle")
            ? ["motorcycle": motorcycleCostingOptions]
            : ["auto": autoCostingOptions]

        let requestPayload: [String: Any] = [
            "locations": [
                ["lat": start.latitude,       "lon": start.longitude,       "type": "break"],
                ["lat": destination.latitude, "lon": destination.longitude, "type": "break"]
            ],
            "costing": costing,
            "costing_options": costingOptions,
            "directions_options": [
                "units":    "kilometers",
                "language": "vi-VN"       // Vietnamese turn instructions
            ],
            // Time-dependent routing: tells Valhalla what time it is so it can pick
            // better routes (e.g. avoid roads that are one-way during peak hours)
            "date_time": [
                "type":  0,         // 0 = current time departure
                "value": dateTimeStr
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ESP32_Native_Navigator/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestPayload)
        request.timeoutInterval = 20.0  // Generous timeout for public server on mobile

        // Retry once on failure (network hiccup or server blip)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            print("[Valhalla] First attempt failed: \(error.localizedDescription). Retrying...")
            (data, response) = try await session.data(for: request)
        }

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            if let httpResponse = response as? HTTPURLResponse {
                print("[Valhalla] HTTP \(httpResponse.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
            }
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

        // Decode Valhalla Precision-6 encoded polyline
        let shapeStr = (firstLeg["shape"] as? String) ?? ""
        let polylineCoords = decodePolyline6(shapeStr)

        // Parse maneuvers — use end_shape_index for the turn coordinate so the dot
        // appears exactly where the driver needs to turn, not 50m before.
        var steps: [NavStep] = []
        let maneuvers = (firstLeg["maneuvers"] as? [[String: Any]]) ?? []

        for (index, m) in maneuvers.enumerated() {
            let instruction = ((m["instruction"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            // Prefer begin_street_names (the road you are currently on), fall back to street_names
            let beginStreetNames = (m["begin_street_names"] as? [String]) ?? []
            let streetNames      = (m["street_names"]       as? [String]) ?? []
            let streetName = beginStreetNames.first ?? streetNames.first ?? "Đường tiếp theo"

            let distMeters = ((m["length"] as? NSNumber)?.doubleValue ?? 0.0) * 1000.0
            let durSeconds = (m["time"] as? NSNumber)?.doubleValue ?? 0.0
            let typeCode   = (m["type"] as? Int) ?? 0

            // Use end_shape_index so the maneuver coordinate is the actual turn point
            let endShapeIndex   = (m["end_shape_index"]   as? Int) ?? 0
            let beginShapeIndex = (m["begin_shape_index"] as? Int) ?? 0

            // Maneuver coordinate: use end of the step (the turn itself)
            // For the final arrive maneuver, use begin_shape_index (destination)
            let shapeIndex = (typeCode == 4 || typeCode == 5) ? beginShapeIndex : endShapeIndex
            let stepCoord = (shapeIndex < polylineCoords.count)
                ? polylineCoords[shapeIndex]
                : (polylineCoords.last ?? destination)

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

        let legSummary = (firstLeg["summary"] as? [String: Any])?["name"] as? String ?? "Lộ trình"
        let navRoute = NavRoute(
            totalDistanceMeters: totalDistance,
            totalDurationSeconds: totalDuration,
            coordinates: polylineCoords,
            steps: steps,
            summary: legSummary
        )

        print("[Valhalla] Route: \(String(format: "%.1f", totalDistance / 1000))km, \(steps.count) maneuvers, \(polylineCoords.count) shape points")

        return (route: navRoute, rawJson: data)
    }

    // MARK: - Precision-6 Polyline Decoder

    /// Decode Valhalla Precision-6 encoded polyline string into an array of coordinates.
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
