import Foundation
import CoreLocation

/// Service for calculating Turn-by-Turn routes using the Goong Directions API V2.
/// Goong has detailed road data for Vietnam including one-way streets, tunnels, and multi-lane roads.
///
/// API reference: https://document.goong.io/
/// Endpoint: https://rsapi.goong.io/v2/direction
public final class ValhallaRoutingService: Sendable {

    // MARK: - Configuration
    // Goong API Key (Maps Tiles key for map style + API key for Directions & Places)
    static let goongApiKey: String = "aBEuWpbGkXPXKEr7P5e5ghHBxcFzOd52P3NxXEhY"

    // Goong Map Style URL (use Navigation Day for driving — shows lanes, tunnels clearly)
    static let goongMapStyleUrl: String =
        "https://tiles.goong.io/assets/navigation_day.json?api_key=\(goongApiKey)"

    private let baseUrl: String
    private let session: URLSession

    public init(
        baseUrl: String = "https://rsapi.goong.io/v2/direction",
        session: URLSession = .shared
    ) {
        self.baseUrl = baseUrl
        self.session = session
    }

    /// Calculate a detailed turn-by-turn route using Goong Directions API V2.
    /// - Parameters:
    ///   - start: Starting coordinate
    ///   - destination: Destination coordinate
    ///   - vehicle: "car", "bike", "taxi", "truck" — use "bike" for motorcycles
    public func calculateRoute(
        from start: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        costing: String = "bike"  // Goong vehicle type: car / bike / taxi
    ) async throws -> (route: NavRoute, rawJson: Data) {

        // Build GET URL: rsapi.goong.io/v2/direction?origin=lat,lon&destination=lat,lon&vehicle=bike&api_key=...
        guard var components = URLComponents(string: baseUrl) else {
            throw URLError(.badURL)
        }

        let vehicle = goongVehicle(from: costing)

        components.queryItems = [
            URLQueryItem(name: "origin",      value: "\(start.latitude),\(start.longitude)"),
            URLQueryItem(name: "destination", value: "\(destination.latitude),\(destination.longitude)"),
            URLQueryItem(name: "vehicle",     value: vehicle),
            URLQueryItem(name: "alternatives",value: "false"),
            URLQueryItem(name: "api_key",     value: ValhallaRoutingService.goongApiKey)
        ]

        guard let url = components.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("ESP32_Native_Navigator/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20.0

        // Retry once on failure
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            print("[Goong] First attempt failed: \(error.localizedDescription). Retrying...")
            (data, response) = try await session.data(for: request)
        }

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            if let httpResponse = response as? HTTPURLResponse {
                print("[Goong] HTTP \(httpResponse.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
            }
            throw URLError(.badServerResponse)
        }

        // --- Parse Goong Response ---
        // Structure: { "geocoded_waypoints": [...], "routes": [ { "legs": [ { "steps": [...], "distance": {}, "duration": {} } ], "overview_polyline": { "points": "..." }, "summary": "..." } ] }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let routes = json["routes"] as? [[String: Any]],
              let firstRoute = routes.first,
              let legs = firstRoute["legs"] as? [[String: Any]],
              let firstLeg = legs.first else {
            throw URLError(.cannotParseResponse)
        }

        // Total distance & duration from leg summary
        let totalDistanceMeters = ((firstLeg["distance"] as? [String: Any])?["value"] as? Double) ?? 0.0
        let totalDurationSeconds = ((firstLeg["duration"] as? [String: Any])?["value"] as? Double) ?? 0.0

        // Decode full route polyline (Precision-5, standard Google encoding)
        let overviewPolyline = ((firstRoute["overview_polyline"] as? [String: Any])?["points"] as? String) ?? ""
        let polylineCoords = decodePolyline5(overviewPolyline)

        // Parse individual steps into NavStep
        var steps: [NavStep] = []
        let rawSteps = (firstLeg["steps"] as? [[String: Any]]) ?? []

        for (index, step) in rawSteps.enumerated() {
            let distMeters  = ((step["distance"] as? [String: Any])?["value"] as? Double) ?? 0.0
            let durSeconds  = ((step["duration"] as? [String: Any])?["value"] as? Double) ?? 0.0
            let instruction = ((step["html_instructions"] as? String) ?? "").stripHTML()
            let maneuverStr = (step["maneuver"] as? [String: Any])?["type"] as? String ?? ""

            // Step start coordinate from start_location
            let startLoc = step["start_location"] as? [String: Any]
            let stepLat  = (startLoc?["lat"] as? Double) ?? start.latitude
            let stepLon  = (startLoc?["lng"] as? Double) ?? start.longitude
            let stepCoord = CLLocationCoordinate2D(latitude: stepLat, longitude: stepLon)

            // Decode this step's polyline to get the end point (actual turn point)
            let stepPolylineStr = (step["polyline"] as? [String: Any])?["points"] as? String ?? ""
            let stepCoords = decodePolyline5(stepPolylineStr)
            // Use last coordinate of step as the maneuver point (where the turn happens)
            let turnCoord = stepCoords.last ?? stepCoord

            // Street name: from the next step's street name (the road you will turn onto)
            let streetName = (step["name"] as? String)
                ?? (step["road_name"] as? String)
                ?? "Đường tiếp theo"

            let maneuver = ManeuverType.fromGoong(type: maneuverStr)

            steps.append(NavStep(
                id: index,
                instruction: instruction.isEmpty ? maneuver.localizedInstruction : instruction,
                streetName: streetName,
                distanceMeters: distMeters,
                durationSeconds: durSeconds,
                coordinate: turnCoord,   // Turn point, not start
                maneuverType: maneuver
            ))
        }

        let summary = (firstRoute["summary"] as? String) ?? "Lộ trình Goong"
        let navRoute = NavRoute(
            totalDistanceMeters: totalDistanceMeters,
            totalDurationSeconds: totalDurationSeconds,
            coordinates: polylineCoords,
            steps: steps,
            summary: summary
        )

        print("[Goong] Route: \(String(format: "%.1f", totalDistanceMeters / 1000))km, \(steps.count) steps, \(polylineCoords.count) shape pts, vehicle=\(vehicle)")

        return (route: navRoute, rawJson: data)
    }

    // MARK: - Helpers

    /// Map internal costing string to Goong vehicle parameter
    private func goongVehicle(from costing: String) -> String {
        switch costing.lowercased() {
        case "motorcycle", "bike":  return "bike"
        case "taxi":                return "taxi"
        case "truck":               return "truck"
        default:                    return "car"
        }
    }

    /// Decode Standard Precision-5 Google/Goong encoded polyline
    private func decodePolyline5(_ encoded: String) -> [CLLocationCoordinate2D] {
        var coordinates: [CLLocationCoordinate2D] = []
        var index = encoded.startIndex
        var lat = 0
        var lon = 0

        while index < encoded.endIndex {
            var b: Int
            var shift = 0
            var result = 0
            repeat {
                guard index < encoded.endIndex else { break }
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
                guard index < encoded.endIndex else { break }
                b = Int(encoded[index].asciiValue ?? 63) - 63
                index = encoded.index(after: index)
                result |= (b & 0x1F) << shift
                shift += 5
            } while b >= 0x20
            let deltaLon = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1))
            lon += deltaLon

            coordinates.append(CLLocationCoordinate2D(
                latitude:  Double(lat) / 1e5,
                longitude: Double(lon) / 1e5
            ))
        }

        return coordinates
    }
}

// MARK: - String Extension — strip HTML tags from Goong instructions
private extension String {
    func stripHTML() -> String {
        guard self.contains("<") else { return self }
        return self.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
