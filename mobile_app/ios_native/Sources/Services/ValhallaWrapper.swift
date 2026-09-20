//
//  ValhallaWrapper.swift
//  Swift interface to the embedded Valhalla C++ routing engine.
//  Bridges ValhallaEngine (ObjC++) to async/await Swift with mode-safe MapKit fallback.
//

import CoreLocation
import Foundation
import MapKit

// MARK: - NavigationRoute (rich route model)

/// A single decoded navigation step from Valhalla or MapKit.
public struct NavStep: Sendable, Equatable {
    public let coordinate: CLLocationCoordinate2D   // end-point of the step (maneuver point)
    public let distanceMeters: Double               // distance from this step's start to maneuver
    public let durationSeconds: Double
    public let streetName: String
    public let maneuverType: ManeuverType
    public let instruction: String
    public let beginShapeIndex: Int?
    public let endShapeIndex: Int?

    public init(
        coordinate: CLLocationCoordinate2D,
        distanceMeters: Double,
        durationSeconds: Double,
        streetName: String,
        maneuverType: ManeuverType,
        instruction: String,
        beginShapeIndex: Int? = nil,
        endShapeIndex: Int? = nil
    ) {
        self.coordinate = coordinate
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
        self.streetName = streetName
        self.maneuverType = maneuverType
        self.instruction = instruction
        self.beginShapeIndex = beginShapeIndex
        self.endShapeIndex = endShapeIndex
    }

    public static func == (lhs: NavStep, rhs: NavStep) -> Bool {
        return abs(lhs.coordinate.latitude - rhs.coordinate.latitude) < 1e-6 &&
               abs(lhs.coordinate.longitude - rhs.coordinate.longitude) < 1e-6 &&
               abs(lhs.distanceMeters - rhs.distanceMeters) < 1e-3 &&
               abs(lhs.durationSeconds - rhs.durationSeconds) < 1e-3 &&
               lhs.streetName == rhs.streetName &&
               lhs.maneuverType == rhs.maneuverType &&
               lhs.instruction == rhs.instruction &&
               lhs.beginShapeIndex == rhs.beginShapeIndex &&
               lhs.endShapeIndex == rhs.endShapeIndex
    }
}

/// Complete navigation route.
public struct NavRoute: Sendable, Equatable {
    public let coordinates: [CLLocationCoordinate2D]  // full polyline
    public let steps: [NavStep]
    public let totalDistanceMeters: Double
    public let totalDurationSeconds: Double
    public let geometry: RouteGeometry

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
        self.geometry = RouteGeometry(coordinates: coordinates, steps: steps)
    }

    public init(
        coordinates: [CLLocationCoordinate2D],
        steps: [NavStep],
        totalDistanceMeters: Double,
        totalDurationSeconds: Double,
        geometry: RouteGeometry
    ) {
        self.coordinates = coordinates
        self.steps = steps
        self.totalDistanceMeters = totalDistanceMeters
        self.totalDurationSeconds = totalDurationSeconds
        self.geometry = geometry
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

    public static func == (lhs: NavRoute, rhs: NavRoute) -> Bool {
        return abs(lhs.totalDistanceMeters - rhs.totalDistanceMeters) < 1e-3 &&
               abs(lhs.totalDurationSeconds - rhs.totalDurationSeconds) < 1e-3 &&
               lhs.coordinates.count == rhs.coordinates.count &&
               lhs.steps.count == rhs.steps.count
    }
}

// MARK: - ValhallaRoutingService Errors

public enum ValhallaRoutingError: LocalizedError, Sendable {
    case configLoadFailed(String)
    case noRouteFound(String)
    case engineUnavailable
    case decodingFailed(String)
    case modeUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .configLoadFailed(let m):  return "Lỗi tải cấu hình Valhalla: \(m)"
        case .noRouteFound(let m):      return "Không tìm được đường: \(m)"
        case .engineUnavailable:        return "Engine định tuyến chưa sẵn sàng"
        case .decodingFailed(let m):    return "Lỗi giải mã lộ trình: \(m)"
        case .modeUnavailable(let m):   return m
        }
    }
}

public enum RoutingErrorCategory: String, Sendable {
    case engineUnavailable
    case tileCoverageMissing
    case noRouteFound
    case invalidRequest
    case unknown
}

// MARK: - Routing Service Protocol

/// Protocol abstracting route calculation for testability, multi-route preview, and provider substitution.
@MainActor
public protocol RoutingServiceProtocol: AnyObject, Sendable {
    /// Calculate multiple route candidates (primary + alternatives) based on RoutingRequest.
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

// MARK: - ValhallaRoutingService

@MainActor
public final class ValhallaRoutingService: ObservableObject, RoutingServiceProtocol {

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
            try engine.loadConfig(atPath: activeConfigURL.path)
            isLoaded = true
            print("[ValhallaWrapper] ✅ Native Valhalla initialized with tiles: \(tilesURL?.path ?? "none")")
        } catch {
            loadError = error.localizedDescription
            print("[ValhallaWrapper] ⚠️ Valhalla tiles not loaded (\(loadError!)). Online fallback ready.")
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
            print("[ValhallaWrapper] ⚠️ Valhalla offline or not loaded (isLoaded=\(isLoaded)). Evaluating fallback for mode=\(request.profile.transportMode)...")
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

public typealias ValhallaWrapper = ValhallaRoutingService

// MARK: - MKPolyline helper
extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}
