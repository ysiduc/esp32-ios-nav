//
//  MultiStrategyRoutePlanner.swift
//  Orchestration layer executing concurrent costing strategies on Valhalla
//  with geometric overlap deduplication, detour filtering, and diagnostic logging.
//

import CoreLocation
import Foundation

// MARK: - Strategy Definition

public struct RouteStrategy: Sendable, Equatable {
    public let id: String
    public let label: String
    public let valhallaCosting: String
    public let costingOptions: ProfileCostingOptions
    public let requestedAlternatives: Int

    public init(
        id: String,
        label: String,
        valhallaCosting: String,
        costingOptions: ProfileCostingOptions,
        requestedAlternatives: Int
    ) {
        self.id = id
        self.label = label
        self.valhallaCosting = valhallaCosting
        self.costingOptions = costingOptions
        self.requestedAlternatives = requestedAlternatives
    }

    /// Primary balanced strategy
    public static func motorcycleBalanced() -> RouteStrategy {
        RouteStrategy(
            id: "motorcycle_balanced",
            label: "Đề xuất",
            valhallaCosting: "motorcycle",
            costingOptions: ProfileCostingOptions([
                "use_highways": 0.5,
                "use_tolls": 0.5,
                "use_trails": 0.0,
                "use_tracks": 0.0,
                "use_ferry": 0.5,
                "use_living_streets": 0.5
            ]),
            requestedAlternatives: 1
        )
    }

    /// Major through roads variant
    public static func motorcycleMainRoads() -> RouteStrategy {
        RouteStrategy(
            id: "motorcycle_main_roads",
            label: "Đường chính",
            valhallaCosting: "motorcycle",
            costingOptions: ProfileCostingOptions([
                "use_highways": 0.8,
                "use_tolls": 0.5,
                "use_trails": 0.0,
                "use_tracks": 0.0,
                "use_ferry": 0.5,
                "use_living_streets": 0.2
            ]),
            requestedAlternatives: 1
        )
    }

    /// Urban & local road family variant
    public static func motorcycleLocal() -> RouteStrategy {
        RouteStrategy(
            id: "motorcycle_local",
            label: "Đường nội đô",
            valhallaCosting: "motorcycle",
            costingOptions: ProfileCostingOptions([
                "use_highways": 0.25,
                "use_tolls": 0.5,
                "use_trails": 0.0,
                "use_tracks": 0.0,
                "use_ferry": 0.5,
                "use_living_streets": 0.7
            ]),
            requestedAlternatives: 1
        )
    }

    /// Low-toll road variant
    public static func motorcycleLowToll() -> RouteStrategy {
        RouteStrategy(
            id: "motorcycle_low_toll",
            label: "Ít trạm thu phí",
            valhallaCosting: "motorcycle",
            costingOptions: ProfileCostingOptions([
                "use_highways": 0.5,
                "use_tolls": 0.0,
                "use_trails": 0.0,
                "use_tracks": 0.0,
                "use_ferry": 0.5,
                "use_living_streets": 0.5
            ]),
            requestedAlternatives: 0
        )
    }
}

// MARK: - Multi-Strategy Route Planner

@MainActor
public final class MultiStrategyRoutePlanner: RoutingServiceProtocol {

    public static let shared = MultiStrategyRoutePlanner()

    private let underlyingRouting: RoutingServiceProtocol

    public init(underlyingRouting: RoutingServiceProtocol? = nil) {
        self.underlyingRouting = underlyingRouting ?? ValhallaRoutingService.shared
    }

    // MARK: - RoutingServiceProtocol

    /// Calculate a single route for a given costing (backward-compatible / fast reroute usage).
    /// Bypasses multi-strategy preview logic completely to keep reroutes fast and minimal.
    public func calculateRoute(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        costing: String
    ) async throws -> NavRoute {
        try await underlyingRouting.calculateRoute(from: origin, to: destination, costing: costing)
    }

    /// Calculate route candidates.
    /// If requestedAlternatives == 0 or mode is not motorcycle, delegates to single-profile routing.
    /// If motorcycle preview, concurrently executes multi-strategy Valhalla queries.
    public func calculateRoutes(request: RoutingRequest) async throws -> RouteSet {
        // Fast path: Reroutes, single-route mode switches, or non-motorcycle profiles
        guard request.requestedAlternatives > 0,
              request.profile.transportMode == .motorcycle else {
            return try await underlyingRouting.calculateRoutes(request: request)
        }

        return try await calculateMultiStrategyRoutes(request: request)
    }

    // MARK: - Multi-Strategy Execution

    private func calculateMultiStrategyRoutes(request: RoutingRequest) async throws -> RouteSet {
        let startTime = Date().timeIntervalSinceReferenceDate
        let strategies: [RouteStrategy] = [
            .motorcycleBalanced(),
            .motorcycleMainRoads(),
            .motorcycleLocal(),
            .motorcycleLowToll()
        ]

        print("[MultiStrategy] Starting \(strategies.count) concurrent strategies for motorcycle preview")

        // Concurrently execute strategies via structured task group
        let rawCandidates: [RouteCandidate] = await withTaskGroup(of: [RouteCandidate]?.self) { group in
            for strategy in strategies {
                group.addTask { () -> [RouteCandidate]? in
                    if Task.isCancelled { return nil }
                    let stratStart = Date().timeIntervalSinceReferenceDate
                    do {
                        let subProfile = RoutingProfile(
                            id: strategy.id,
                            transportMode: .motorcycle,
                            valhallaCosting: strategy.valhallaCosting,
                            costingOptions: strategy.costingOptions,
                            maxAlternatives: strategy.requestedAlternatives,
                            fallbackPolicy: .motorcycle
                        )
                        let subRequest = RoutingRequest(
                            origin: request.origin,
                            destination: request.destination,
                            profile: subProfile,
                            requestedAlternatives: strategy.requestedAlternatives
                        )

                        let set = try await self.underlyingRouting.calculateRoutes(request: subRequest)
                        let elapsed = Date().timeIntervalSinceReferenceDate - stratStart

                        // Relabel raw candidates with meaningful strategy label
                        let candidates = set.candidates.enumerated().map { idx, c in
                            let label = (idx == 0) ? strategy.label : "\(strategy.label) \(idx + 1)"
                            return RouteCandidate(
                                id: "\(strategy.id)_\(idx)",
                                route: c.route,
                                provider: c.provider,
                                requestedMode: c.requestedMode,
                                profileID: strategy.id,
                                isPrimary: (strategy.id == "motorcycle_balanced" && idx == 0),
                                isDegradedFallback: c.isDegradedFallback,
                                degradedReason: c.degradedReason,
                                label: label
                            )
                        }

                        print("[MultiStrategy] Strategy \(strategy.id) returned \(candidates.count) routes in \(String(format: "%.2f", elapsed))s")
                        return candidates
                    } catch {
                        let elapsed = Date().timeIntervalSinceReferenceDate - stratStart
                        print("[MultiStrategy] Strategy \(strategy.id) failed in \(String(format: "%.2f", elapsed))s: \(error.localizedDescription)")
                        return nil
                    }
                }
            }

            var accumulated: [RouteCandidate] = []
            for await result in group {
                if let list = result {
                    accumulated.append(contentsOf: list)
                }
            }
            return accumulated
        }

        try Task.checkCancellation()

        guard !rawCandidates.isEmpty else {
            throw ValhallaRoutingError.noRouteFound("Không tìm thấy lộ trình phù hợp từ các chiến lược định tuyến")
        }

        // Separate primary balanced candidate
        let primaryCandidate = rawCandidates.first(where: { $0.profileID == "motorcycle_balanced" && $0.isPrimary }) ?? rawCandidates[0]

        // Find reference fastest duration & shortest distance
        let fastestDuration = rawCandidates.map(\.route.totalDurationSeconds).min() ?? primaryCandidate.route.totalDurationSeconds
        let shortestDistance = rawCandidates.map(\.route.totalDistanceMeters).min() ?? primaryCandidate.route.totalDistanceMeters

        // Detour filtering: drop routes with excessive duration or distance
        let qualityCandidates = rawCandidates.filter { candidate in
            RouteSimilarity.isAcceptableCandidate(
                candidate: candidate.route,
                fastestDurationSeconds: fastestDuration,
                shortestDistanceMeters: shortestDistance,
                maxDurationMultiplier: 1.40,
                maxDistanceMultiplier: 1.50
            )
        }

        let candidatesToDedup = qualityCandidates.isEmpty ? rawCandidates : qualityCandidates

        // Deduplicate using RouteSimilarity.overlap (corridor metric)
        // Ensure primary candidate is evaluated first so it remains index 0
        var orderedCandidates = candidatesToDedup.filter { $0.id == primaryCandidate.id }
        orderedCandidates.append(contentsOf: candidatesToDedup.filter { $0.id != primaryCandidate.id })

        let deduplicated = RouteSet.deduplicate(candidates: orderedCandidates)

        // Limit target display count to at most 5 genuinely distinct routes
        let finalCandidates = Array(deduplicated.prefix(5))

        let totalTime = Date().timeIntervalSinceReferenceDate - startTime
        print("[MultiStrategy] Aggregation complete: raw=\(rawCandidates.count), quality=\(candidatesToDedup.count), dedup=\(deduplicated.count), final=\(finalCandidates.count) in \(String(format: "%.2f", totalTime))s")

        return RouteSet(candidates: finalCandidates)
    }
}
