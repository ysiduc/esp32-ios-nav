import Foundation
import CoreLocation

// =============================================================================
// SERVER CONFIG — doi URL nay khi doi server
// =============================================================================
public enum NavServerConfig {
    /// IP/domain cua Android phone server
    /// Vi du: "http://192.168.1.100" hoac "https://nav.yourdomain.com"
    public static let serverBase = "YOUR_SERVER_URL"  // <-- doi o day

    // --- Derived endpoints (khong can sua) ---
    public static let mapStyleURL  = "\(serverBase):3000/style.json"   // Martin tiles
    public static let routingURL   = "\(serverBase):8989"               // GraphHopper
    public static let geocodingURL = "\(serverBase):2322/api"           // Photon
}

// =============================================================================
// ROUTING SERVICE — GraphHopper API
// GraphHopper API docs: https://docs.graphhopper.com/
// =============================================================================
public final class ValhallaRoutingService: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Calculate a detailed turn-by-turn route using GraphHopper.
    /// - Parameters:
    ///   - start: Starting coordinate
    ///   - destination: Destination coordinate
    ///   - costing: "car", "bike" (motorcycle) — GraphHopper vehicle profile
    public func calculateRoute(
        from start: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        costing: String = "bike"
    ) async throws -> (route: NavRoute, rawJson: Data) {

        guard var components = URLComponents(string: "\(NavServerConfig.routingURL)/route") else {
            throw URLError(.badURL)
        }

        // GraphHopper GET /route?point=lat,lon&point=lat,lon&vehicle=car&type=json
        components.queryItems = [
            URLQueryItem(name: "point",   value: "\(start.latitude),\(start.longitude)"),
            URLQueryItem(name: "point",   value: "\(destination.latitude),\(destination.longitude)"),
            URLQueryItem(name: "vehicle", value: ghVehicle(from: costing)),
            URLQueryItem(name: "type",    value: "json"),
            URLQueryItem(name: "points_encoded", value: "true"),
            URLQueryItem(name: "instructions",   value: "true"),
            URLQueryItem(name: "locale",         value: "vi")
        ]

        guard let url = components.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("ESP32_Native_Navigator/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20.0

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            print("[GraphHopper] First attempt failed: \(error.localizedDescription). Retrying...")
            (data, response) = try await session.data(for: request)
        }

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            print("[GraphHopper] Error: \(String(data: data, encoding: .utf8) ?? "")")
            throw URLError(.badServerResponse)
        }

        // GraphHopper response:
        // { "paths": [ {
        //     "distance": meters,
        //     "time": milliseconds,
        //     "points": "encoded_polyline",
        //     "instructions": [ {
        //       "distance": m, "time": ms,
        //       "text": "Turn left onto ...",
        //       "street_name": "...",
        //       "sign": -2,          // turn direction code
        //       "interval": [0, 5]   // shape index range
        //     } ]
        //   } ]
        // }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let paths = json["paths"] as? [[String: Any]],
              let firstPath = paths.first else {
            throw URLError(.cannotParseResponse)
        }

        let totalDistanceMeters = (firstPath["distance"] as? Double) ?? 0.0
        let totalDurationMs     = (firstPath["time"]     as? Double) ?? 0.0
        let totalDurationSec    = totalDurationMs / 1000.0

        // Decode full route polyline (Precision-5 encoded)
        let encodedPolyline = (firstPath["points"] as? String) ?? ""
        let polylineCoords  = decodePolyline5(encodedPolyline)

        // Parse instructions → NavSteps
        var steps: [NavStep] = []
        let instructions = (firstPath["instructions"] as? [[String: Any]]) ?? []

        for (index, instr) in instructions.enumerated() {
            let distMeters = (instr["distance"] as? Double) ?? 0.0
            let durMs      = (instr["time"]     as? Double) ?? 0.0
            let text       = (instr["text"]     as? String) ?? ""
            let streetName = (instr["street_name"] as? String)
                             .flatMap { $0.isEmpty ? nil : $0 }
                             ?? "Đường tiếp theo"
            let sign       = (instr["sign"]     as? Int) ?? 0

            // Use end of step's interval as the turn coordinate
            let interval   = (instr["interval"] as? [Int]) ?? [0, 0]
            let endIdx     = min(interval.last ?? 0, polylineCoords.count - 1)
            let stepCoord  = (endIdx < polylineCoords.count) ? polylineCoords[endIdx] : start

            let maneuver = ManeuverType.fromGraphHopper(sign: sign)

            steps.append(NavStep(
                id: index,
                instruction: text.isEmpty ? maneuver.localizedInstruction : text,
                streetName: streetName,
                distanceMeters: distMeters,
                durationSeconds: durMs / 1000.0,
                coordinate: stepCoord,
                maneuverType: maneuver
            ))
        }

        let navRoute = NavRoute(
            totalDistanceMeters: totalDistanceMeters,
            totalDurationSeconds: totalDurationSec,
            coordinates: polylineCoords,
            steps: steps,
            summary: "Lộ trình"
        )

        print("[GraphHopper] Route: \(String(format: "%.1f", totalDistanceMeters/1000))km, \(steps.count) steps, \(polylineCoords.count) pts")

        return (route: navRoute, rawJson: data)
    }

    // MARK: - Helpers

    private func ghVehicle(from costing: String) -> String {
        switch costing.lowercased() {
        case "motorcycle", "bike": return "bike"      // GraphHopper: "bike" maps to fastest bike/motorcycle
        case "car", "auto":        return "car"
        default:                   return "car"
        }
    }

    /// Decode standard Precision-5 Google/GraphHopper encoded polyline
    private func decodePolyline5(_ encoded: String) -> [CLLocationCoordinate2D] {
        var coordinates: [CLLocationCoordinate2D] = []
        var index = encoded.startIndex
        var lat = 0, lon = 0

        while index < encoded.endIndex {
            var b: Int, shift = 0, result = 0
            repeat {
                guard index < encoded.endIndex else { break }
                b = Int(encoded[index].asciiValue ?? 63) - 63
                index = encoded.index(after: index)
                result |= (b & 0x1F) << shift
                shift += 5
            } while b >= 0x20
            lat += ((result & 1) != 0 ? ~(result >> 1) : (result >> 1))

            shift = 0; result = 0
            repeat {
                guard index < encoded.endIndex else { break }
                b = Int(encoded[index].asciiValue ?? 63) - 63
                index = encoded.index(after: index)
                result |= (b & 0x1F) << shift
                shift += 5
            } while b >= 0x20
            lon += ((result & 1) != 0 ? ~(result >> 1) : (result >> 1))

            coordinates.append(CLLocationCoordinate2D(
                latitude:  Double(lat) / 1e5,
                longitude: Double(lon) / 1e5
            ))
        }
        return coordinates
    }
}
