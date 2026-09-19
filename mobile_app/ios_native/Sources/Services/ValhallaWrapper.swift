//
//  ValhallaWrapper.swift
//  Swift interface to the embedded Valhalla C++ routing engine.
//  Bridges ValhallaEngine (ObjC++) to async/await Swift with MapKit fallback.
//

import CoreLocation
import Foundation
import MapKit

// MARK: - NavigationRoute (rich route model)

/// A single decoded navigation step from Valhalla or MapKit.
public struct NavStep: Sendable {
    public let coordinate: CLLocationCoordinate2D   // end-point of the step (maneuver point)
    public let distanceMeters: Double               // distance from this step's start to maneuver
    public let durationSeconds: Double
    public let streetName: String
    public let maneuverType: ManeuverType
    public let instruction: String

    public init(
        coordinate: CLLocationCoordinate2D,
        distanceMeters: Double,
        durationSeconds: Double,
        streetName: String,
        maneuverType: ManeuverType,
        instruction: String
    ) {
        self.coordinate = coordinate
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
        self.streetName = streetName
        self.maneuverType = maneuverType
        self.instruction = instruction
    }
}

/// Complete navigation route.
public struct NavRoute: Sendable {
    public let coordinates: [CLLocationCoordinate2D]  // full polyline
    public let steps: [NavStep]
    public let totalDistanceMeters: Double
    public let totalDurationSeconds: Double

    public init(
        coordinates: [CLLocationCoordinate2D],
        steps: [NavStep],
        totalDistanceMeters: Double,
        totalDurationSeconds: Double
    ) {
        self.coordinates = coordinates
        self.steps = steps
        self.totalDistanceMeters = totalDistanceMeters
        self.totalDurationSeconds = totalDurationSeconds
    }

    /// Formatted distance string (e.g. "12.3 km")
    public var formattedDistance: String {
        if totalDistanceMeters >= 1000 {
            return String(format: "%.1f km", totalDistanceMeters / 1000)
        }
        return "\(Int(totalDistanceMeters)) m"
    }

    /// Formatted duration string (e.g. "23 phút" or "1h 5m")
    public var formattedDuration: String {
        let mins = Int(totalDurationSeconds / 60)
        if mins >= 60 { return "\(mins / 60)h \(mins % 60)m" }
        return "\(mins) phút"
    }
}

// MARK: - ValhallaRoutingService

public enum ValhallaRoutingError: LocalizedError {
    case configLoadFailed(String)
    case noRouteFound(String)
    case engineUnavailable
    case decodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .configLoadFailed(let m):  return "Lỗi tải cấu hình Valhalla: \(m)"
        case .noRouteFound(let m):      return "Không tìm được đường: \(m)"
        case .engineUnavailable:        return "Engine định tuyến chưa sẵn sàng"
        case .decodingFailed(let m):    return "Lỗi giải mã lộ trình: \(m)"
        }
    }
}

@MainActor
public final class ValhallaRoutingService: ObservableObject {

    public static let shared = ValhallaRoutingService()
    private init() { Task { await loadValhalla() } }

    // Background queue for blocking Valhalla calls
    private let routingQueue = DispatchQueue(
        label: "com.ysiduc.valhalla.routing",
        qos: .userInitiated
    )

    @Published public private(set) var isLoaded = false
    @Published public private(set) var loadError: String?

    // MARK: - Lifecycle

    private func loadValhalla() async {
        let engine = ValhallaEngine.shared()

        guard engine.isAvailable else {
            print("[ValhallaWrapper] STUB mode.")
            isLoaded = true
            return
        }

        // 1. Locate valhalla_tiles.tar
        let tilesURL = locateTilesTar()
        guard let configBaseURL = bundleConfigURL() ?? documentConfigURL() else {
            loadError = "valhalla.json not found."
            print("[ValhallaWrapper] ❌ \(loadError!)")
            return
        }

        do {
            // Prepare dynamic valhalla config pointing to actual tile location
            let activeConfigURL = try prepareActiveConfig(from: configBaseURL, tilesURL: tilesURL)
            var nsError: NSError?
            let ok = engine.loadConfig(atPath: activeConfigURL.path, error: &nsError)
            if ok {
                isLoaded = true
                print("[ValhallaWrapper] ✅ Native Valhalla initialized with tiles: \(tilesURL?.path ?? "none")")
            } else {
                loadError = nsError?.localizedDescription ?? "Valhalla init failed"
                print("[ValhallaWrapper] ⚠️ Valhalla tiles not loaded (\(loadError!)). Online fallback ready.")
            }
        } catch {
            loadError = error.localizedDescription
            print("[ValhallaWrapper] ⚠️ Config preparation error: \(error.localizedDescription)")
        }
    }

    private func locateTilesTar() -> URL? {
        // Check bundle first
        if let bundleTar = Bundle.main.url(forResource: "valhalla_tiles", withExtension: "tar") {
            return bundleTar
        }
        // Check Application Support
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if let appSupportTar = appSupport?.appendingPathComponent("valhalla_data/valhalla_tiles.tar"),
           FileManager.default.fileExists(atPath: appSupportTar.path) {
            return appSupportTar
        }
        // Check Documents
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if let docsTar = docs?.appendingPathComponent("valhalla_tiles.tar"),
           FileManager.default.fileExists(atPath: docsTar.path) {
            return docsTar
        }
        return nil
    }

    private func prepareActiveConfig(from baseConfigURL: URL, tilesURL: URL?) throws -> URL {
        let data = try Data(contentsOf: baseConfigURL)
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return baseConfigURL
        }

        if let tiles = tilesURL, var mjolnir = json["mjolnir"] as? [String: Any] {
            mjolnir["tile_extract"] = tiles.path
            json["mjolnir"] = mjolnir
        }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let activeURL = appSupport.appendingPathComponent("active_valhalla.json")
        let updatedData = try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
        try updatedData.write(to: activeURL)
        return activeURL
    }

    private func bundleConfigURL() -> URL? {
        Bundle.main.url(forResource: "valhalla", withExtension: "json")
    }

    private func documentConfigURL() -> URL? {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
        return appSupport?.appendingPathComponent("valhalla_data/valhalla.json")
    }

    // MARK: - Route Calculation

    /// Compute a route with Valhalla native engine as primary, MapKit as fallback.
    public func calculateRoute(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        costing: String = "motorcycle"
    ) async throws -> NavRoute {

        // 1. If Valhalla engine is loaded and ready, use offline native routing
        if isLoaded && ValhallaEngine.shared().isAvailable {
            do {
                return try await calculateValhallaRoute(from: origin, to: destination, costing: costing)
            } catch {
                print("[ValhallaWrapper] Valhalla routing error: \(error.localizedDescription). Trying MapKit...")
            }
        }

        // 2. Fallback to Apple MapKit MKDirections (Zero cost, high precision in VN)
        do {
            return try await calculateMapKitRoute(from: origin, to: destination)
        } catch {
            print("[ValhallaWrapper] MapKit routing error: \(error.localizedDescription). Using straight fallback...")
        }

        // 3. Simple straight line fallback
        return makeFallbackRoute(from: origin, to: destination)
    }

    private func calculateValhallaRoute(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        costing: String
    ) async throws -> NavRoute {
        return try await withCheckedThrowingContinuation { continuation in
            routingQueue.async {
                var nsError: NSError?
                let valhallaRoute = ValhallaEngine.shared().computeRoute(
                    fromLat: origin.latitude,
                    fromLon: origin.longitude,
                    toLat: destination.latitude,
                    toLon: destination.longitude,
                    costing: costing,
                    error: &nsError
                )

                if let err = nsError {
                    continuation.resume(throwing: ValhallaRoutingError.noRouteFound(err.localizedDescription))
                    return
                }

                guard let vr = valhallaRoute else {
                    continuation.resume(throwing: ValhallaRoutingError.noRouteFound("No route returned"))
                    return
                }

                let coords = Self.decodeRouteCoordinates(from: vr)
                if coords.isEmpty {
                    continuation.resume(throwing: ValhallaRoutingError.decodingFailed("Empty coordinate list"))
                    return
                }

                let steps = Self.decodeSteps(vr.steps as! [ValhallaStep], fullPolyline: coords)

                let navRoute = NavRoute(
                    coordinates: coords,
                    steps: steps,
                    totalDistanceMeters: vr.totalDistanceMeters,
                    totalDurationSeconds: vr.totalDurationSeconds
                )
                continuation.resume(returning: navRoute)
            }
        }
    }

    private func calculateMapKitRoute(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) async throws -> NavRoute {
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        req.transportType = .automobile

        let directions = MKDirections(request: req)
        let resp = try await directions.calculate()
        guard let firstRoute = resp.routes.first else {
            throw ValhallaRoutingError.noRouteFound("Không tìm thấy đường MapKit")
        }

        let polylinePoints = firstRoute.polyline.coordinates
        var steps: [NavStep] = []

        for step in firstRoute.steps {
            guard step.distance > 0 else { continue }
            let stepCoords = step.polyline.coordinates
            let maneuverCoord = stepCoords.last ?? origin
            let maneuver = ManeuverType.fromMKInstruction(step.instructions)
            steps.append(NavStep(
                coordinate: maneuverCoord,
                distanceMeters: step.distance,
                durationSeconds: (step.distance / 10.0),
                streetName: "",
                maneuverType: maneuver,
                instruction: step.instructions.isEmpty ? "Đi tiếp" : step.instructions
            ))
        }

        return NavRoute(
            coordinates: polylinePoints,
            steps: steps,
            totalDistanceMeters: firstRoute.distance,
            totalDurationSeconds: firstRoute.expectedTravelTime
        )
    }

    private func makeFallbackRoute(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) -> NavRoute {
        let mid = CLLocationCoordinate2D(
            latitude: (origin.latitude + destination.latitude) / 2.0,
            longitude: (origin.longitude + destination.longitude) / 2.0
        )
        let coords = [origin, mid, destination]
        let dlat = (destination.latitude - origin.latitude) * 111319.9
        let dlon = (destination.longitude - origin.longitude) * 111319.9 * cos(origin.latitude * .pi / 180.0)
        let totalMeters = sqrt(dlat * dlat + dlon * dlon)

        let step1 = NavStep(
            coordinate: mid,
            distanceMeters: totalMeters / 2.0,
            durationSeconds: (totalMeters / 2.0) / 10.0,
            streetName: "Đường Thẳng",
            maneuverType: .straight,
            instruction: "Đi thẳng tới điểm đích"
        )
        let step2 = NavStep(
            coordinate: destination,
            distanceMeters: totalMeters / 2.0,
            durationSeconds: (totalMeters / 2.0) / 10.0,
            streetName: "",
            maneuverType: .destination,
            instruction: "Đến đích"
        )

        return NavRoute(
            coordinates: coords,
            steps: [step1, step2],
            totalDistanceMeters: totalMeters,
            totalDurationSeconds: totalMeters / 10.0
        )
    }

    // MARK: - Coordinate Decoding

    private static func decodeRouteCoordinates(from route: ValhallaRoute) -> [CLLocationCoordinate2D] {
        if !route.encodedPolyline6.isEmpty {
            return decodePolyline6(route.encodedPolyline6)
        }

        if !route.rawJSON.isEmpty,
           let data = route.rawJSON.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let stubCoords = json["_stub_coords"] as? [[Double]] {
            return stubCoords.compactMap { pair in
                guard pair.count == 2 else { return nil }
                return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
            }
        }

        return []
    }

    private static func decodePolyline6(_ encoded: String) -> [CLLocationCoordinate2D] {
        var coordinates: [CLLocationCoordinate2D] = []
        var lat = 0
        var lng = 0
        var index = encoded.startIndex

        while index < encoded.endIndex {
            var b = 0
            var shift = 0
            var result = 0
            repeat {
                guard index < encoded.endIndex else { break }
                b = Int(encoded[index].asciiValue ?? 63) - 63
                index = encoded.index(after: index)
                result |= (b & 0x1F) << shift
                shift += 5
            } while b >= 0x20

            let dLat = (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
            lat += dLat

            b = 0; shift = 0; result = 0
            repeat {
                guard index < encoded.endIndex else { break }
                b = Int(encoded[index].asciiValue ?? 63) - 63
                index = encoded.index(after: index)
                result |= (b & 0x1F) << shift
                shift += 5
            } while b >= 0x20

            let dLng = (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
            lng += dLng

            coordinates.append(CLLocationCoordinate2D(
                latitude:  Double(lat) * 1e-6,
                longitude: Double(lng) * 1e-6
            ))
        }

        return coordinates
    }

    private static func decodeSteps(
        _ valhallaSteps: [ValhallaStep],
        fullPolyline: [CLLocationCoordinate2D]
    ) -> [NavStep] {
        var steps: [NavStep] = []

        for vs in valhallaSteps {
            let endIdx = min(vs.endShapeIndex, fullPolyline.count - 1)
            let coord: CLLocationCoordinate2D
            if endIdx >= 0 && endIdx < fullPolyline.count {
                coord = fullPolyline[endIdx]
            } else if !fullPolyline.isEmpty {
                coord = fullPolyline.last!
            } else {
                continue
            }

            let maneuver = ManeuverType.fromValhalla(type: Int(vs.maneuverType))

            steps.append(NavStep(
                coordinate: coord,
                distanceMeters: vs.distanceMeters,
                durationSeconds: vs.durationSeconds,
                streetName: vs.streetName,
                maneuverType: maneuver,
                instruction: vs.instruction
            ))
        }

        return steps
    }
}

// MARK: - MKPolyline helper
extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}
