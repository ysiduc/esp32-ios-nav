//
//  RouteSimilarity.swift
//  Pure geometric overlap metric and route quality filters.
//

import CoreLocation
import Foundation

public enum RouteSimilarity {

    /// Default diversity overlap threshold: routes with >= 85% overlap are considered duplicates.
    public static let defaultDiversityThreshold: Double = 0.85

    /// Default corridor distance: 30m accounts for dual carriageways, GPS precision, and interpolation.
    public static let defaultCorridorDistanceMeters: Double = 30.0

    /// Default sampling step along the route geometry.
    public static let defaultSampleIntervalMeters: Double = 25.0

    /// Default endpoint corridor mask: ignore first/last 150m (or 5% of route) so common origin/destination
    /// points do not falsely dominate diversity calculations.
    public static let defaultEndpointMaskDistanceMeters: Double = 150.0

    /// Computes normalized geometric overlap between two routes:
    /// - 0.0: entirely distinct
    /// - 1.0: effectively identical geometry
    public static func overlap(
        routeA: NavRoute,
        routeB: NavRoute,
        corridorDistanceMeters: Double = defaultCorridorDistanceMeters,
        sampleIntervalMeters: Double = defaultSampleIntervalMeters,
        endpointMaskDistanceMeters: Double = defaultEndpointMaskDistanceMeters
    ) -> Double {
        let lenA = routeA.totalDistanceMeters
        let lenB = routeB.totalDistanceMeters

        guard lenA > 0 && lenB > 0 else { return 0.0 }
        guard !routeA.coordinates.isEmpty && !routeB.coordinates.isEmpty else { return 0.0 }

        // Sample points along route A outside endpoint mask and test corridor match against B
        let ratioAtoB = corridorMatchRatio(
            subjectRoute: routeA,
            targetRoute: routeB,
            corridorDistanceMeters: corridorDistanceMeters,
            sampleIntervalMeters: sampleIntervalMeters,
            endpointMaskDistanceMeters: endpointMaskDistanceMeters
        )

        // Sample points along route B outside endpoint mask and test corridor match against A
        let ratioBtoA = corridorMatchRatio(
            subjectRoute: routeB,
            targetRoute: routeA,
            corridorDistanceMeters: corridorDistanceMeters,
            sampleIntervalMeters: sampleIntervalMeters,
            endpointMaskDistanceMeters: endpointMaskDistanceMeters
        )

        return (ratioAtoB + ratioBtoA) / 2.0
    }

    /// Evaluates what fraction of resampled points along  lie within 
    /// of 's geometry.
    public static func corridorMatchRatio(
        subjectRoute: NavRoute,
        targetRoute: NavRoute,
        corridorDistanceMeters: Double,
        sampleIntervalMeters: Double,
        endpointMaskDistanceMeters: Double
    ) -> Double {
        let totalLen = subjectRoute.totalDistanceMeters
        guard totalLen > 0 else { return 0.0 }

        let mask = min(endpointMaskDistanceMeters, totalLen * 0.05)
        let startD = mask
        let endD = max(startD, totalLen - mask)

        guard endD > startD else {
            // Short route: sample full span without mask
            return sampleRatio(
                from: 0.0,
                to: totalLen,
                step: max(5.0, totalLen / 10.0),
                subjectRoute: subjectRoute,
                targetRoute: targetRoute,
                corridorDistanceMeters: corridorDistanceMeters
            )
        }

        let step = max(5.0, sampleIntervalMeters)
        return sampleRatio(
            from: startD,
            to: endD,
            step: step,
            subjectRoute: subjectRoute,
            targetRoute: targetRoute,
            corridorDistanceMeters: corridorDistanceMeters
        )
    }

    private static func sampleRatio(
        from startD: Double,
        to endD: Double,
        step: Double,
        subjectRoute: NavRoute,
        targetRoute: NavRoute,
        corridorDistanceMeters: Double
    ) -> Double {
        var totalSamples = 0
        var matchedSamples = 0

        var currentD = startD
        while currentD <= endD {
            if let point = subjectRoute.geometry.coordinate(atDistanceAlongRoute: currentD) {
                totalSamples += 1
                if let proj = targetRoute.geometry.nearestProjection(to: point) {
                    if proj.lateralDistanceMeters <= corridorDistanceMeters {
                        matchedSamples += 1
                    }
                }
            }
            currentD += step
        }

        guard totalSamples > 0 else { return 1.0 }
        return Double(matchedSamples) / Double(totalSamples)
    }

    /// Determines whether a candidate route exceeds detour limits compared to the fastest/shortest reference routes:
    /// - duration <= fastest * 1.40
    /// - distance <= shortest * 1.50
    public static func isAcceptableCandidate(
        candidate: NavRoute,
        fastestDurationSeconds: Double,
        shortestDistanceMeters: Double,
        maxDurationMultiplier: Double = 1.40,
        maxDistanceMultiplier: Double = 1.50
    ) -> Bool {
        if fastestDurationSeconds > 0 && candidate.totalDurationSeconds > (fastestDurationSeconds * maxDurationMultiplier) {
            return false
        }
        if shortestDistanceMeters > 0 && candidate.totalDistanceMeters > (shortestDistanceMeters * maxDistanceMultiplier) {
            return false
        }
        return true
    }
}
