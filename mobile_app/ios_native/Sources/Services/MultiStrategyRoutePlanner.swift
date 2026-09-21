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
    public let priority: Int
    public let label: String
    public let valhallaCosting: String
    public let costingOptions: ProfileCostingOptions
    public let requestedAlternatives: Int

    public init(
        id: String,
        priority: Int,
        label: String,
        valhallaCosting: String,
        costingOptions: ProfileCostingOptions,
        requestedAlternatives: Int
    ) {
        self.id = id
        self.priority = priority
        self.label = label
        self.valhallaCosting = valhallaCosting
        self.costingOptions = costingOptions
        self.requestedAlternatives = requestedAlternatives
    }

    /// Primary balanced strategy (priority 0)
    public static func motorcycleBalanced() -> RouteStrategy {
        RouteStrategy(
            id: "motorcycle_balanced",
            priority: 0,
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

    /// Major through roads variant (priority 1)
    public static func motorcycleMainRoads() -> RouteStrategy {
        RouteStrategy(
            id: "motorcycle_main_roads",
            priority: 1,
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

    /// Urban & local road family variant (priority 2)
    public static func motorcycleLocal() -> RouteStrategy {
        RouteStrategy(
            id: "motorcycle_local",
            priority: 2,
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

    /// Low-toll road variant (priority 3)
    public static func motorcycleLowToll() -> RouteStrategy {
        RouteStrategy(
            id: "motorcycle_low_toll",
            priority: 3,
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

    struct StrategyResult: Sendable {
        let priority: Int
        let strategyID: String
        let candidates: [RouteCandidate]
    }

    private func calculateMultiStrategyRoutes(request: RoutingRequest) async throws -> RouteSet {
        let startTime = Date().timeIntervalSinceReferenceDate
        let strategies: [RouteStrategy] = [
            .motorcycleBalanced(),
            .motorcycleMainRoads(),
            .motorcycleLocal(),
            .motorcycleLowToll()
        ]

        print("[MultiStrategy] Starting \(strategies.count) concurrent strategies for motorcycle preview")

        // Concurrently execute strategies via structured task group.
        // Individual strategies are STRICTLY Valhalla-only (allowMapKitFallback: false)
        let strategyResults: [StrategyResult] = await withTaskGroup(of: StrategyResult?.self) { group in
            for strategy in strategies {
                group.addTask { () -> StrategyResult? in
                    if Task.isCancelled { return nil }
                    let stratStart = Date().timeIntervalSinceReferenceDate
                    do {
                        // Subprofile strictly disables MapKit fallback to prevent car routes from entering motorcycle strategies
                        let subProfile = RoutingProfile(
                            id: strategy.id,
                            transportMode: .motorcycle,
                            valhallaCosting: strategy.valhallaCosting,
                            costingOptions: strategy.costingOptions,
                            maxAlternatives: strategy.requestedAlternatives,
                            fallbackPolicy: RoutingProfile.FallbackPolicy(allowMapKitFallback: false, mapKitCapability: .unsupported)
                        )
                        let subRequest = RoutingRequest(
                            origin: request.origin,
                            destination: request.destination,
                            profile: subProfile,
                            requestedAlternatives: strategy.requestedAlternatives
                        )

                        let set = try await self.underlyingRouting.calculateRoutes(request: subRequest)
                        let elapsed = Date().timeIntervalSinceReferenceDate - stratStart

                        // Ensure only valid Valhalla routes without degraded fallback are accepted
                        let validValhallaRoutes = set.candidates.filter { $0.provider == .valhalla && !$0.isDegradedFallback }

                        let candidates = validValhallaRoutes.enumerated().map { idx, c in
                            let label = (idx == 0) ? strategy.label : "\(strategy.label) \(idx + 1)"
                            return RouteCandidate(
                                id: "\(strategy.id)_\(idx)",
                                route: c.route,
                                provider: c.provider,
                                requestedMode: c.requestedMode,
                                profileID: strategy.id,
                                isPrimary: (strategy.id == "motorcycle_balanced" && idx == 0),
                                isDegradedFallback: false,
                                degradedReason: nil,
                                label: label
                            )
                        }

                        print("[MultiStrategy] Strategy \(strategy.id) returned \(candidates.count) routes in \(String(format: "%.2f", elapsed))s")
                        return StrategyResult(priority: strategy.priority, strategyID: strategy.id, candidates: candidates)
                    } catch {
                        let elapsed = Date().timeIntervalSinceReferenceDate - stratStart
                        print("[MultiStrategy] Strategy \(strategy.id) failed in \(String(format: "%.2f", elapsed))s: \(error.localizedDescription)")
                        return nil
                    }
                }
            }

            var accumulated: [StrategyResult] = []
            for await result in group {
                if let batch = result, !batch.candidates.isEmpty {
                    accumulated.append(batch)
                }
            }
            return accumulated
        }

        try Task.checkCancellation()

        // If ALL Valhalla strategies fail, run a single degraded motorcycle fallback request
        if strategyResults.isEmpty {
            print("[MultiStrategy] All Valhalla motorcycle strategies failed; executing single emergency degraded fallback")
            let emergencyProfile = RoutingProfile.motorcycle() // has fallbackPolicy: .motorcycle
            let emergencyRequest = RoutingRequest(
                origin: request.origin,
                destination: request.destination,
                profile: emergencyProfile,
                requestedAlternatives: 0
            )
            let emergencySet = try await self.underlyingRouting.calculateRoutes(request: emergencyRequest)
            guard let firstFallback = emergencySet.candidates.first else {
                throw ValhallaRoutingError.noRouteFound("Không tìm thấy lộ trình phù hợp từ các chiến lược định tuyến")
            }

            let fallbackCandidate = RouteCandidate(
                id: "motorcycle_degraded_fallback_0",
                route: firstFallback.route,
                provider: firstFallback.provider,
                requestedMode: .motorcycle,
                profileID: "motorcycle_degraded_fallback",
                isPrimary: true,
                isDegradedFallback: true,
                degradedReason: "Apple MapKit does not natively support motorcycle routing; automobile route approximation is used.",
                label: "Đề xuất (Dự phòng)"
            )
            return RouteSet(candidates: [fallbackCandidate])
        }

        // Deterministic candidate ranking:
        // Group and order candidates independently of async completion order.
        var allScored: [(priority: Int, candidateIndex: Int, candidate: RouteCandidate)] = []
        for batch in strategyResults {
            for (idx, cand) in batch.candidates.enumerated() {
                allScored.append((priority: batch.priority, candidateIndex: idx, candidate: cand))
            }
        }

        allScored.sort { a, b in
            // 1. Balanced primary always first
            let aIsPrimary = (a.priority == 0 && a.candidateIndex == 0)
            let bIsPrimary = (b.priority == 0 && b.candidateIndex == 0)
            if aIsPrimary != bIsPrimary { return aIsPrimary }

            // 2. Faster duration (shorter time)
            let durDiff = a.candidate.route.totalDurationSeconds - b.candidate.route.totalDurationSeconds
            if abs(durDiff) > 1.0 { return durDiff < 0 }

            // 3. Shorter distance
            let distDiff = a.candidate.route.totalDistanceMeters - b.candidate.route.totalDistanceMeters
            if abs(distDiff) > 5.0 { return distDiff < 0 }

            // 4. Strategy priority (balanced < main < local < low_toll)
            if a.priority != b.priority { return a.priority < b.priority }

            // 5. Candidate index within strategy
            if a.candidateIndex != b.candidateIndex { return a.candidateIndex < b.candidateIndex }

            // 6. Deterministic tiebreak
            return a.candidate.id < b.candidate.id
        }

        let rawCandidates = allScored.map(\.candidate)

        // Separate primary candidate (guaranteed index 0 by sort)
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

        // Deduplicate using RouteSimilarity.overlap (corridor metric).
        // Since candidates are deterministically ordered with the best/faster routes first,
        // duplicate routes with overlap >= threshold will discard the slower duplicate.
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
