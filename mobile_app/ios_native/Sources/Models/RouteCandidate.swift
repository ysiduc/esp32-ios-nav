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

    public var formattedDelta: String? {
        guard !isPrimary else { return nil }
        let mins = Int(round(relativeDurationSeconds / 60.0))
        let timeDeltaStr: String
        if mins > 0 {
            timeDeltaStr = "+\(mins)p"
        } else if mins < 0 {
            timeDeltaStr = "\(mins)p"
        } else {
            timeDeltaStr = "+0p"
        }

        let distKm = relativeDistanceMeters / 1000.0
        let distDeltaStr: String
        if abs(distKm) >= 0.1 {
            let sign = distKm > 0 ? "+" : ""
            distDeltaStr = String(format: "%@%.1f km", sign, distKm)
        } else {
            distDeltaStr = "+0.0 km"
        }

        return "\(timeDeltaStr) · \(distDeltaStr)"
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
    /// 1. Drops candidate if coordinate sequences are effectively identical to an earlier candidate (within microdegree precision)
    /// 2. Normalizes candidate labels: index 0 -> "Đề xuất", index 1 -> "Tuyến 2", index 2 -> "Tuyến 3"
    /// 3. Computes relative duration and distance deltas compared to primary (index 0)
    /// Note: Does NOT drop distinct routes merely because distance/ETA match.
    public static func deduplicate(candidates: [RouteCandidate]) -> [RouteCandidate] {
        guard !candidates.isEmpty else { return [] }

        var filtered: [RouteCandidate] = []
        for candidate in candidates {
            let isDuplicate = filtered.contains { existing in
                // 1. Geometric overlap corridor metric (P5.3)
                let overlap = RouteSimilarity.overlap(routeA: existing.route, routeB: candidate.route)
                if overlap >= RouteSimilarity.defaultDiversityThreshold {
                    return true
                }

                // 2. Exact coordinate sequence match fallback
                let c1 = existing.route.coordinates
                let c2 = candidate.route.coordinates
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
            if isPrim {
                label = c.label.isEmpty || c.label == "Tuyến phụ" ? "Đề xuất" : c.label
            } else if !c.label.isEmpty && c.label != "Tuyến phụ" && c.label != "Đề xuất" {
                label = c.label
            } else {
                switch idx {
                case 1: label = "Tuyến 2"
                case 2: label = "Tuyến 3"
                default: label = "Tuyến \(idx + 1)"
                }
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
