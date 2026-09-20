//
//  ValhallaWrapper.swift
//  Swift routing service managing native offline Valhalla and mode-safe Apple MapKit fallback.
//

import CoreLocation
import Foundation
import MapKit

// MARK: - Routing Service Protocol

public protocol RoutingServiceProtocol: Sendable {
    /// Calculate route candidates (primary + alternatives) based on RoutingRequest.
    func calculateRoutes(request: RoutingRequest) async throws -> RouteSet

    /// Calculate a single route for a given transport costing (backward-compatible / reroute usage).
    func calculateRoute(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        costing: String
    ) async throws -> NavRoute
}

public extension RoutingServiceProtocol {
    func calculateRoute(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        costing: String = "motorcycle"
    ) async throws -> NavRoute {
        let mode = NavigationTransportMode(costingValue: costing)
        let profile = RoutingProfile.profile(for: mode)
        let request = RoutingRequest(
            origin: origin,
            destination: destination,
            profile: profile,
            requestedAlternatives: 0
        )
        let routeSet = try await calculateRoutes(request: request)
        guard let primary = routeSet.primaryRoute else {
            throw ValhallaRoutingError.noRouteFound("Không tìm thấy lộ trình phù hợp")
        }
        return primary
    }

    func calculateRoutes(request: RoutingRequest) async throws -> RouteSet {
        let route = try await calculateRoute(
            from: request.origin,
            to: request.destination,
            costing: request.profile.valhallaCosting
        )
        let candidate = RouteCandidate(
            id: "route_0",
            route: route,
            provider: .valhalla,
            requestedMode: request.profile.transportMode,
            profileID: request.profile.id,
            isPrimary: true,
            isDegradedFallback: false,
            label: "Đề xuất"
        )
        return RouteSet(candidates: [candidate])
    }
}

// MARK: - Error Definitions

public enum RoutingErrorCategory: String, Sendable {
    case engineUnavailable
    case tileCoverageMissing
    case noRouteFound
    case invalidRequest
    case unknown
}

public enum ValhallaRoutingError: LocalizedError, Sendable {
    case configMissing
    case noRouteFound(String)
    case decodingFailed(String)
    case modeUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .configMissing:
            return "Không tìm thấy file cấu hình Valhalla"
        case .noRouteFound(let msg):
            return "Không tìm thấy đường: \(msg)"
        case .decodingFailed(let msg):
            return "Lỗi giải mã lộ trình: \(msg)"
        case .modeUnavailable(let msg):
            return msg
        }
    }
}

// MARK: - Pure MapKit Mode Mapper

public enum MapKitModeMapper {
    public struct MappingResult: Sendable, Equatable {
        public let transportType: MKDirectionsTransportType
        public let isDegraded: Bool
        public let degradedReason: String?
    }

    public static func mapTransportMode(
        _ mode: NavigationTransportMode,
        policy: FallbackPolicy
    ) throws -> MappingResult {
        switch mode {
        case .auto:
            return MappingResult(
                transportType: .automobile,
                isDegraded: false,
                degradedReason: nil
            )
        case .pedestrian:
            return MappingResult(
                transportType: .walking,
                isDegraded: false,
                degradedReason: nil
            )
        case .motorcycle:
            if case .degradedApproximation(let reason) = policy.mapKitCapability {
                return MappingResult(
                    transportType: .automobile,
                    isDegraded: true,
                    degradedReason: reason
                )
            } else {
                throw ValhallaRoutingError.modeUnavailable("Chế độ xe máy không được hỗ trợ bởi Apple MapKit.")
            }
        case .bicycle:
            if case .degradedApproximation(let reason) = policy.mapKitCapability {
                return MappingResult(
                    transportType: .walking,
                    isDegraded: true,
                    degradedReason: reason
                )
            } else {
                throw ValhallaRoutingError.modeUnavailable("Chế độ xe đạp không được hỗ trợ bởi Apple MapKit.")
            }
        }
    }
}

// MARK: - ValhallaWrapper Service

public final class ValhallaWrapper: RoutingServiceProtocol, @unchecked Sendable {

    public static let shared = ValhallaWrapper()

    private let routingQueue = DispatchQueue(label: "com.ysiduc.valhalla.swift", qos: .userInitiated)
    public private(set) var isLoaded: Bool = false

    private init() {
        loadConfig()
    }

    // MARK: - Engine Initialization

    public func loadConfig() {
        guard let configPath = Bundle.main.path(forResource: "valhalla", ofType: "json") else {
            let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let docConfig = docsDir.appendingPathComponent("valhalla.json").path
            if FileManager.default.fileExists(atPath: docConfig) {
                initEngine(at: docConfig)
            } else {
                print("[ValhallaWrapper] valhalla.json not found in Bundle or Documents.")
            }
            return
        }
        initEngine(at: configPath)
    }

    private func initEngine(at path: String) {
        do {
            try ValhallaEngine.shared().loadConfig(atPath: path)
            isLoaded = true
            print("[ValhallaWrapper] Valhalla initialized with config at: \(path)")
        } catch {
            print("[ValhallaWrapper] Failed to load config: \(error.localizedDescription)")
            isLoaded = false
        }
    }

    // MARK: - RoutingServiceProtocol Implementation

    public func calculateRoutes(request: RoutingRequest) async throws -> RouteSet {
        // 1. Try Valhalla native engine if loaded and available
        if isLoaded && ValhallaEngine.shared().isAvailable {
            do {
                let candidates = try await calculateValhallaRoutes(request: request)
                if !candidates.isEmpty {
                    let deduped = RouteSet.deduplicate(candidates: candidates)
                    return RouteSet(candidates: deduped)
                }
            } catch {
                let category = classifyValhallaError(error)
                print("[ValhallaWrapper] ⚠️ Primary routing failure: provider=Valhalla, mode=\(request.profile.transportMode), category=\(category), details=\(error.localizedDescription). Evaluating fallback...")
            }
        } else {
            print("[ValhallaWrapper] ⚠️ Valhalla offline or not loaded (isLoaded=\(isLoaded)). Evaluating fallback for mode=\(request.profile.transportMode)...)
        }

        // 2. Check fallback capability
        guard request.profile.fallbackPolicy.allowMapKitFallback else {
            throw ValhallaRoutingError.modeUnavailable(
                "Chế độ \(request.profile.transportMode.displayName) không khả dụng khi hệ thống định tuyến ngoại tuyến."
            )
        }

        // 3. Fallback to Apple MapKit MKDirections
        do {
            let candidates = try await calculateMapKitRoutes(request: request)
            let deduped = RouteSet.deduplicate(candidates: candidates)
            return RouteSet(candidates: deduped)
        } catch {
            print("[ValhallaWrapper] ❌ MapKit routing error: \(error.localizedDescription)")
            throw ValhallaRoutingError.noRouteFound(
                "Không tìm thấy đường từ cả Valhalla và MapKit: \(error.localizedDescription)"
            )
        }
    }

    public func calculateRoute(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        costing: String = "motorcycle"
    ) async throws -> NavRoute {
        let mode = NavigationTransportMode(costingValue: costing)
        let profile = RoutingProfile.profile(for: mode)
        let request = RoutingRequest(
            origin: origin,
            destination: destination,
            profile: profile,
            requestedAlternatives: 0
        )
        let set = try await calculateRoutes(request: request)
        guard let primary = set.primaryRoute else {
            throw ValhallaRoutingError.noRouteFound("Không tìm thấy lộ trình phù hợp")
        }
        return primary
    }

    // MARK: - Valhalla Private Routing

    private func calculateValhallaRoutes(request: RoutingRequest) async throws -> [RouteCandidate] {
        let jsonString = try ValhallaRequestBuilder.buildRequestJSON(
            origin: request.origin,
            destination: request.destination,
            profile: request.profile,
            alternates: request.requestedAlternatives
        )

        return try await withCheckedThrowingContinuation { continuation in
            routingQueue.async {
                do {
                    let result = try ValhallaEngine.shared().computeRoutes(
                        withRequestJSON: jsonString
                    )

                    let allRoutes = result.allRoutes
                    guard !allRoutes.isEmpty else {
                        continuation.resume(throwing: ValhallaRoutingError.noRouteFound("Empty routes array"))
                        return
                    }

                    var candidates: [RouteCandidate] = []
                    for (idx, vr) in allRoutes.enumerated() {
                        let coords = Self.decodeRouteCoordinates(from: vr)
                        guard !coords.isEmpty else { continue }
                        let steps = Self.decodeSteps(vr.steps, fullPolyline: coords)
                        let navRoute = NavRoute(
                            coordinates: coords,
                            steps: steps,
                            totalDistanceMeters: vr.totalDistanceMeters,
                            totalDurationSeconds: vr.totalDurationSeconds
                        )

                        let isPrim = (idx == 0)
                        let candidate = RouteCandidate(
                            id: "valhalla_\(idx)",
                            route: navRoute,
                            provider: .valhalla,
                            requestedMode: request.profile.transportMode,
                            profileID: request.profile.id,
                            isPrimary: isPrim,
                            isDegradedFallback: false,
                            degradedReason: nil,
                            label: isPrim ? "Đề xuất" : "Tuyến \(idx + 1)"
                        )
                        candidates.append(candidate)
                    }

                    guard !candidates.isEmpty else {
                        continuation.resume(throwing: ValhallaRoutingError.decodingFailed("Could not decode route coordinates"))
                        return
                    }

                    continuation.resume(returning: candidates)
                } catch {
                    continuation.resume(throwing: ValhallaRoutingError.noRouteFound(error.localizedDescription))
                }
            }
        }
    }

    // MARK: - MapKit Private Routing

    private func calculateMapKitRoutes(request: RoutingRequest) async throws -> [RouteCandidate] {
        let mapping = try MapKitModeMapper.mapTransportMode(
            request.profile.transportMode,
            policy: request.profile.fallbackPolicy
        )

        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: request.origin))
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: request.destination))
        req.transportType = mapping.transportType
        req.requestsAlternateRoutes = (request.requestedAlternatives > 0)

        let directions = MKDirections(request: req)
        let resp = try await directions.calculate()
        guard !resp.routes.isEmpty else {
            throw ValhallaRoutingError.noRouteFound("Không tìm thấy đường MapKit")
        }

        let maxCount = min(resp.routes.count, 1 + request.requestedAlternatives)
        var candidates: [RouteCandidate] = []

        for idx in 0..<maxCount {
            let mkRoute = resp.routes[idx]
            let polylinePoints = mkRoute.polyline.coordinates
            guard !polylinePoints.isEmpty else { continue }

            let validSteps = mkRoute.steps.filter { $0.distance > 0 }
            let mappings = RouteGeometry.mapStepPolylinesToIndices(
                stepPolylines: validSteps.map { $0.polyline.coordinates },
                fullPolyline: polylinePoints
            )

            let totalDist = mkRoute.distance
            let totalDur = mkRoute.expectedTravelTime

            var steps: [NavStep] = []
            for (stepIdx, step) in validSteps.enumerated() {
                let stepCoords = step.polyline.coordinates
                let maneuverCoord = stepCoords.last ?? request.origin
                let maneuver = ManeuverType.fromMKInstruction(step.instructions)
                let mappingIndices = stepIdx < mappings.count ? mappings[stepIdx] : (beginShapeIndex: 0, endShapeIndex: 0)

                // Proportional step duration derived from total expectedTravelTime based on step distance
                let stepDuration: Double = totalDist > 0 ? (step.distance / totalDist) * totalDur : 0

                steps.append(NavStep(
                    coordinate: maneuverCoord,
                    distanceMeters: step.distance,
                    durationSeconds: stepDuration,
                    streetName: "",
                    maneuverType: maneuver,
                    instruction: step.instructions.isEmpty ? "Đi tiếp" : step.instructions,
                    beginShapeIndex: mappingIndices.beginShapeIndex,
                    endShapeIndex: mappingIndices.endShapeIndex
                ))
            }

            let navRoute = NavRoute(
                coordinates: polylinePoints,
                steps: steps,
                totalDistanceMeters: totalDist,
                totalDurationSeconds: totalDur
            )

            let isPrim = (idx == 0)
            let candidate = RouteCandidate(
                id: "mapkit_\(idx)",
                route: navRoute,
                provider: .mapKit,
                requestedMode: request.profile.transportMode,
                profileID: request.profile.id,
                isPrimary: isPrim,
                isDegradedFallback: mapping.isDegraded,
                degradedReason: mapping.degradedReason,
                label: isPrim ? "Đề xuất" : "Tuyến \(idx + 1)"
            )
            candidates.append(candidate)
        }

        guard !candidates.isEmpty else {
            throw ValhallaRoutingError.noRouteFound("Không thể tạo danh sách ứng viên MapKit")
        }

        return candidates
    }

    // MARK: - Helper & Coordinate Decoding

    private func classifyValhallaError(_ error: Error) -> RoutingErrorCategory {
        let msg = error.localizedDescription.lowercased()
        let ns = error as NSError
        if ns.domain == ValhallaEngineErrorDomain {
            if ns.code == ValhallaEngineError.configNotLoaded.rawValue ||
               ns.code == ValhallaEngineError.libraryMissing.rawValue {
                return .engineUnavailable
            }
            if ns.code == ValhallaEngineError.noRouteFound.rawValue {
                if msg.contains("edge") || msg.contains("disconnected") || msg.contains("tile") || msg.contains("boundary") {
                    return .tileCoverageMissing
                }
                return .noRouteFound
            }
        }
        if msg.contains("tile") || msg.contains("coverage") || msg.contains("no suitable edge") {
            return .tileCoverageMissing
        }
        return .unknown
    }

    nonisolated private static func decodeRouteCoordinates(from route: ValhallaRoute) -> [CLLocationCoordinate2D] {
        if !route.encodedPolyline6.isEmpty {
            return decodePolyline6(route.encodedPolyline6)
        }
        return []
    }

    nonisolated private static func decodePolyline6(_ encoded: String) -> [CLLocationCoordinate2D] {
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

    nonisolated private static func decodeSteps(
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
                instruction: vs.instruction,
                beginShapeIndex: vs.beginShapeIndex,
                endShapeIndex: vs.endShapeIndex
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
