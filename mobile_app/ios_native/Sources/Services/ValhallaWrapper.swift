//
//  ValhallaWrapper.swift
//  Swift-facing async wrapper around ValhallaEngine (ObjC++ → Swift).
//
//  Usage:
//    let service = ValhallaRoutingService.shared
//    let route   = try await service.calculateRoute(from: origin, to: dest, costing: "motorcycle")
//
//  Stub mode (VALHALLA_AVAILABLE=0 in ValhallaEngine.mm):
//    Returns a fake straight-line route for UI testing. Routing logic (snapping,
//    off-route detection, HUD updates) all work exactly as in production.
//
//  Production mode (VALHALLA_AVAILABLE=1):
//    Pass costing: "auto" | "motorcycle" | "bicycle" | "pedestrian"
//

import CoreLocation
import Foundation

// MARK: - NavigationRoute (rich route model)

/// A single decoded navigation step from Valhalla.
public struct NavStep: Sendable {
    public let coordinate: CLLocationCoordinate2D   // end-point of the step (maneuver point)
    public let distanceMeters: Double               // distance from this step's start to maneuver
    public let durationSeconds: Double
    public let streetName: String
    public let maneuverType: ManeuverType
    public let instruction: String
}

/// Complete navigation route.
public struct NavRoute: Sendable {
    public let coordinates: [CLLocationCoordinate2D]  // full polyline
    public let steps: [NavStep]
    public let totalDistanceMeters: Double
    public let totalDurationSeconds: Double

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

        // If stub, skip config loading (engine always "succeeds")
        guard engine.isAvailable else {
            print("[ValhallaWrapper] Running in STUB mode — link libvalhalla.a for real routing.")
            isLoaded = true
            return
        }

        // Find valhalla.json in the app bundle or Application Support
        guard let configURL = bundleConfigURL() ?? documentConfigURL() else {
            loadError = "valhalla.json not found in bundle or Application Support."
            print("[ValhallaWrapper] ❌ \(loadError!)")
            return
        }

        var nsError: NSError?
        let ok = engine.loadConfig(atPath: configURL.path, error: &nsError)
        if ok {
            isLoaded = true
            print("[ValhallaWrapper] ✅ Valhalla loaded from \(configURL.lastPathComponent)")
        } else {
            loadError = nsError?.localizedDescription ?? "Unknown error"
            print("[ValhallaWrapper] ❌ Valhalla load failed: \(loadError!)")
        }
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

    /// Compute a route on a background thread and return to the caller's actor.
    /// @param costing "auto" | "motorcycle" | "bicycle" | "pedestrian"
    public func calculateRoute(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        costing: String = "motorcycle"
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

                // Decode coordinates from polyline6 OR stub coords
                let coords = Self.decodeRouteCoordinates(from: vr)
                if coords.isEmpty {
                    continuation.resume(throwing: ValhallaRoutingError.decodingFailed("Empty coordinate list"))
                    return
                }

                // Map ObjC ValhallaStep array → Swift NavStep array
                let steps = Self.decodeSteps(vr.steps as! [ValhallaStep],
                                             fullPolyline: coords)

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

    // MARK: - Coordinate Decoding

    /// Decode coordinates from a ValhallaRoute.
    /// In production: uses polyline6 encoded string from Valhalla.
    /// In stub mode:  parses the _stub_coords array injected by ValhallaEngine.mm.
    private static func decodeRouteCoordinates(from route: ValhallaRoute) -> [CLLocationCoordinate2D] {
        // --- Production path: decode polyline6 ---
        if !route.encodedPolyline6.isEmpty {
            return decodePolyline6(route.encodedPolyline6)
        }

        // --- Stub path: parse _stub_coords from rawJSON ---
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

    /// Decode Valhalla/OSRM-style Polyline 6 (precision=6) encoded string.
    /// Standard polyline5 uses factor 1e5; polyline6 uses 1e6.
    private static func decodePolyline6(_ encoded: String) -> [CLLocationCoordinate2D] {
        var coordinates: [CLLocationCoordinate2D] = []
        var lat = 0
        var lng = 0
        var index = encoded.startIndex

        while index < encoded.endIndex {
            // Latitude
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

            // Longitude
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

    // MARK: - Step Decoding

    private static func decodeSteps(
        _ valhallaSteps: [ValhallaStep],
        fullPolyline: [CLLocationCoordinate2D]
    ) -> [NavStep] {
        var steps: [NavStep] = []

        for vs in valhallaSteps {
            // Use end-shape-index to get the coordinate at the maneuver point
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

