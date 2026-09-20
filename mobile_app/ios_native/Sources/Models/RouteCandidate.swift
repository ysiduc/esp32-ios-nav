//
//  RouteCandidate.swift
//  Pure models for candidate route sets, provider metadata, and candidate deduplication.
//

import CoreLocation
import Foundation

public enum RoutingProvider: String, Sendable, Equatable {
    case valhalla = "Valhalla"
    case mapKit   = "Apple MapKit"
}

public struct RouteCandidate: Sendable, Identifiable, Equatable {
    public let id: String
    public let route: NavRoute
    public let provider: RoutingProvider
    public let requestedMode: NavigationTransportMode
    public let profileID: String
    public let isPrimary: Bool
    public let isDegradedFallback: Bool
    public let degradedReason: String?
    public let label: String
    public let relativeDurationSeconds: Double
    public let relativeDistanceMeters: Double

    public init(
        id: String,
        route: NavRoute,
        provider: RoutingProvider,
        requestedMode: NavigationTransportMode,
        profileID: String,
        isPrimary: Bool,
        isDegradedFallback: Bool = false,
        degradedReason: String? = nil,
        label: String? = nil,
        relativeDurationSeconds: Double = 0,
        relativeDistanceMeters: Double = 0
    ) {
        self.id = id
        self.route = route
        self.provider = provider
        self.requestedMode = requestedMode
        self.profileID = profileID
        self.isPrimary = isPrimary
        self.isDegradedFallback = isDegradedFallback
        self.degradedReason = degradedReason
        self.label = label ?? (isPrimary ? "Đề xuất" : "Tuyến phụ")
        self.relativeDurationSeconds = relativeDurationSeconds
        self.relativeDistanceMeters = relativeDistanceMeters
    }

    public static func == (lhs: RouteCandidate, rhs: RouteCandidate) -> Bool {
        return lhs.id == rhs.id &&
               lhs.provider == rhs.provider &&
               lhs.requestedMode == rhs.requestedMode &&
               lhs.profileID == rhs.profileID &&
               lhs.isPrimary == rhs.isPrimary &&
               lhs.isDegradedFallback == rhs.isDegradedFallback &&
               lhs.label == rhs.label &&
               lhs.route == rhs.route
    }
}

public struct RouteSet: Sendable, Equatable {
    public let candidates: [RouteCandidate]

    public var primaryCandidate: RouteCandidate? {
        candidates.first
    }

    public var primaryRoute: NavRoute? {
        primaryCandidate?.route
    }

    public init(candidates: [RouteCandidate]) {
        self.candidates = candidates
    }

    /// Pure, deterministic candidate deduplication:
    /// 1. Drops candidate if coordinates are identical to an earlier candidate (within microdegree precision)
    /// 2. Drops candidate if distance (<20m diff), duration (<5s diff), origin, and destination match an earlier candidate
    /// 3. Normalizes candidate labels: index 0 -> "Đề xuất", index 1 -> "Tuyến 2", index 2 -> "Tuyến 3"
    /// 4. Computes relative duration and distance deltas compared to primary (index 0)
    public static func deduplicate(candidates: [RouteCandidate]) -> [RouteCandidate] {
        guard !candidates.isEmpty else { return [] }

        var filtered: [RouteCandidate] = []
        for candidate in candidates {
            let isDuplicate = filtered.contains { existing in
                let c1 = existing.route.coordinates
                let c2 = candidate.route.coordinates

                // Check 1: Identical coordinate count and sequence
                if c1.count == c2.count && !c1.isEmpty {
                    var allMatch = true
                    for i in 0..<c1.count {
                        if abs(c1[i].latitude - c2[i].latitude) > 1e-5 ||
                           abs(c1[i].longitude - c2[i].longitude) > 1e-5 {
                            allMatch = false
                            break
                        }
                    }
                    if allMatch { return true }
                }

                // Check 2: Near-identical total length, duration, and endpoints
                if abs(existing.route.totalDistanceMeters - candidate.route.totalDistanceMeters) < 20.0 &&
                   abs(existing.route.totalDurationSeconds - candidate.route.totalDurationSeconds) < 5.0 {
                    if let s1 = c1.first, let s2 = c2.first, let e1 = c1.last, let e2 = c2.last {
                        if abs(s1.latitude - s2.latitude) < 1e-5 && abs(s1.longitude - s2.longitude) < 1e-5 &&
                           abs(e1.latitude - e2.latitude) < 1e-5 && abs(e1.longitude - e2.longitude) < 1e-5 {
                            return true
                        }
                    }
                }

                return false
            }

            if !isDuplicate {
                filtered.append(candidate)
            }
        }

        guard let primary = filtered.first else { return [] }
        var result: [RouteCandidate] = []

        for (idx, c) in filtered.enumerated() {
            let isPrim = (idx == 0)
            let label: String
            switch idx {
            case 0: label = "Đề xuất"
            case 1: label = "Tuyến 2"
            case 2: label = "Tuyến 3"
            default: label = "Tuyến \(idx + 1)"
            }

            let durDelta = isPrim ? 0 : (c.route.totalDurationSeconds - primary.route.totalDurationSeconds)
            let distDelta = isPrim ? 0 : (c.route.totalDistanceMeters - primary.route.totalDistanceMeters)

            result.append(RouteCandidate(
                id: c.id,
                route: c.route,
                provider: c.provider,
                requestedMode: c.requestedMode,
                profileID: c.profileID,
                isPrimary: isPrim,
                isDegradedFallback: c.isDegradedFallback,
                degradedReason: c.degradedReason,
                label: label,
                relativeDurationSeconds: durDelta,
                relativeDistanceMeters: distDelta
            ))
        }

        return result
    }
}
