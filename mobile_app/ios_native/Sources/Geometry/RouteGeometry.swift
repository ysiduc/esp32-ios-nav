//
//  RouteGeometry.swift
//  Authoritative route geometry model, precomputed cumulative distances,
//  and robust route-constrained GPS projection with continuity gating.
//

import CoreLocation
import Foundation

/// Pure geometry abstraction representing a precomputed route polyline,
/// cumulative distances along the route, and step-to-geometry mappings.
public struct RouteGeometry: Sendable {

    /// Polyline coordinates making up the entire route.
    public let coordinates: [CLLocationCoordinate2D]

    /// Cumulative distance from start of route to coordinate at index i (meters).
    /// Invariant: cumulativeDistances.count == coordinates.count.
    public let cumulativeDistances: [Double]

    /// Total path distance along the polyline in meters.
    public let totalDistanceMeters: Double

    /// Cumulative along-route distance in meters for each maneuver step.
    public let maneuverDistancesAlongRoute: [Double]

    /// Number of distinct linear segments in the polyline.
    public var segmentCount: Int {
        max(0, coordinates.count - 1)
    }

    // MARK: - Initializer

    public init(
        coordinates: [CLLocationCoordinate2D],
        steps: [NavStep] = []
    ) {
        self.coordinates = coordinates

        // Precompute cumulative distances along polyline coordinates
        var cumDist: [Double] = []
        cumDist.reserveCapacity(coordinates.count)

        var total: Double = 0.0
        if !coordinates.isEmpty {
            cumDist.append(0.0)
            for i in 0..<(coordinates.count - 1) {
                let a = coordinates[i]
                let b = coordinates[i + 1]
                let segLen = RouteGeometry.distanceBetween(a, b)
                total += segLen
                cumDist.append(total)
            }
        }
        self.cumulativeDistances = cumDist
        self.totalDistanceMeters = total

        // Precompute maneuver distances along the route
        var stepDists: [Double] = []
        stepDists.reserveCapacity(steps.count)

        var lastStepDist: Double = 0.0
        for (idx, step) in steps.enumerated() {
            var stepDist: Double
            if let endShape = step.endShapeIndex, endShape >= 0, endShape < cumDist.count {
                stepDist = cumDist[endShape]
            } else if idx == steps.count - 1 && !cumDist.isEmpty {
                stepDist = total
            } else {
                // Fallback: approximate closest coordinate cumulative distance
                var bestDist = Double.infinity
                var bestAlong = lastStepDist
                for cIdx in 0..<coordinates.count {
                    let d = RouteGeometry.distanceBetween(step.coordinate, coordinates[cIdx])
                    if d < bestDist {
                        bestDist = d
                        bestAlong = cumDist[cIdx]
                    }
                }
                stepDist = bestAlong
            }

            // Guarantee monotonic progression of step distances
            stepDist = max(lastStepDist, stepDist)
            if idx == steps.count - 1 && !cumDist.isEmpty {
                stepDist = total
            }
            stepDists.append(stepDist)
            lastStepDist = stepDist
        }
        self.maneuverDistancesAlongRoute = stepDists
    }

    // MARK: - Segment Math

    /// Geodesic distance in meters between two coordinates using equirectangular approximation.
    public static func distanceBetween(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let midLat = (a.latitude + b.latitude) * 0.5 * (.pi / 180.0)
        let mLat = 111_319.9
        let mLon = 111_319.9 * cos(midLat)

        let dx = (b.longitude - a.longitude) * mLon
        let dy = (b.latitude - a.latitude) * mLat
        return sqrt(dx * dx + dy * dy)
    }

    /// Bearing in degrees [0, 360) from coordinate a to coordinate b.
    public static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180.0
        let lat2 = b.latitude * .pi / 180.0
        let dLon = (b.longitude - a.longitude) * .pi / 180.0

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let radians = atan2(y, x)
        let degrees = radians * 180.0 / .pi
        return (degrees + 360.0).truncatingRemainder(dividingBy: 360.0)
    }

    /// Project a coordinate onto a specific polyline segment index.
    public func projectOnSegment(
        point: CLLocationCoordinate2D,
        segmentIndex: Int
    ) -> (coordinate: CLLocationCoordinate2D, fraction: Double, lateralDistanceMeters: Double, distanceAlongRouteMeters: Double) {
        guard segmentIndex >= 0 && segmentIndex < segmentCount else {
            let fallback = coordinates.first ?? point
            return (fallback, 0.0, RouteGeometry.distanceBetween(point, fallback), 0.0)
        }

        let a = coordinates[segmentIndex]
        let b = coordinates[segmentIndex + 1]

        let midLat = (a.latitude + b.latitude) * 0.5 * (.pi / 180.0)
        let mLat = 111_319.9
        let mLon = 111_319.9 * cos(midLat)

        let vx = (b.longitude - a.longitude) * mLon
        let vy = (b.latitude - a.latitude) * mLat
        let ux = (point.longitude - a.longitude) * mLon
        let uy = (point.latitude - a.latitude) * mLat

        let len2 = vx * vx + vy * vy
        let t: Double
        if len2 > 1e-10 {
            t = max(0.0, min(1.0, (ux * vx + uy * vy) / len2))
        } else {
            t = 0.0
        }

        let projLat = a.latitude + (t * vy) / mLat
        let projLon = a.longitude + (t * vx) / mLon
        let projCoord = CLLocationCoordinate2D(latitude: projLat, longitude: projLon)

        let dx = (point.longitude - projLon) * mLon
        let dy = (point.latitude - projLat) * mLat
        let lateralDist = sqrt(dx * dx + dy * dy)

        let segLen = sqrt(len2)
        let distAlong = cumulativeDistances[segmentIndex] + t * segLen

        return (projCoord, t, lateralDist, distAlong)
    }

    // MARK: - Robust Projection with Continuity Gating

    /// Projects a GPS location onto this route geometry using a two-tier search:
    /// 1. Fast local window search around previous matched segment (O(1)).
    /// 2. Global search fallback with continuity penalties (O(N)).
    ///
    /// Applies backward tolerance (20m) and forward jump penalties to prevent snap jumping
    /// on parallel roads, hairpins, and self-intersecting loops.
    public func project(
        location: CLLocation,
        lastProjection: RouteProjection? = nil
    ) -> RouteProjection? {
        guard segmentCount > 0 else {
            if let first = coordinates.first {
                return RouteProjection(
                    coordinate: first,
                    segmentIndex: 0,
                    segmentFraction: 0.0,
                    lateralDistanceMeters: RouteGeometry.distanceBetween(location.coordinate, first),
                    distanceAlongRouteMeters: 0.0
                )
            }
            return nil
        }

        let point = location.coordinate

        // Helper to evaluate a segment with continuity penalties
        func scoreCandidate(
            segmentIdx: Int
        ) -> (projection: RouteProjection, score: Double) {
            let res = projectOnSegment(point: point, segmentIndex: segmentIdx)
            let proj = RouteProjection(
                coordinate: res.coordinate,
                segmentIndex: segmentIdx,
                segmentFraction: res.fraction,
                lateralDistanceMeters: res.lateralDistanceMeters,
                distanceAlongRouteMeters: res.distanceAlongRouteMeters
            )

            var penalty: Double = 0.0
            if let prev = lastProjection {
                let delta = res.distanceAlongRouteMeters - prev.distanceAlongRouteMeters

                // 1. Backward snap penalty: allow up to 20m for GPS noise, heavily penalize beyond
                if delta < -20.0 {
                    penalty += abs(delta + 20.0) * 5.0
                }

                // 2. Forward jump penalty: penalize physically implausible sudden advances
                let speedMps = max(0.0, location.speed)
                let maxPlausibleForward = max(60.0, speedMps * 3.0 * 2.5 + location.horizontalAccuracy)
                if delta > maxPlausibleForward {
                    penalty += (delta - maxPlausibleForward) * 2.5
                }
            } else {
                // Initial match: slight bias towards earlier segments of the route
                penalty += Double(segmentIdx) * 0.05
            }

            // 3. Heading tie-breaker: if moving fast enough, penalize segments running opposite to vehicle course
            if location.speed > 1.5 && location.course >= 0 {
                let a = coordinates[segmentIdx]
                let b = coordinates[segmentIdx + 1]
                let segBearing = RouteGeometry.bearing(from: a, to: b)
                let diff = abs(segBearing - location.course)
                let minAngle = min(diff, 360.0 - diff)
                if minAngle > 95.0 {
                    penalty += 35.0
                }
            }

            let totalScore = res.lateralDistanceMeters + penalty
            return (proj, totalScore)
        }

        // Tier 1: Local Window Search
        if let prev = lastProjection {
            let winStart = max(0, prev.segmentIndex - 2)
            let winEnd = min(segmentCount - 1, prev.segmentIndex + 25)

            var bestLocal: RouteProjection?
            var bestLocalScore = Double.infinity

            for segIdx in winStart...winEnd {
                let candidate = scoreCandidate(segmentIdx: segIdx)
                if candidate.score < bestLocalScore {
                    bestLocalScore = candidate.score
                    bestLocal = candidate.projection
                }
            }

            // If local search found a candidate within reasonable lateral distance, accept immediately
            if let localMatch = bestLocal, localMatch.lateralDistanceMeters <= 25.0 {
                return localMatch
            }
        }

        // Tier 2: Global Search Fallback
        var bestGlobal: RouteProjection?
        var bestGlobalScore = Double.infinity

        for segIdx in 0..<segmentCount {
            let candidate = scoreCandidate(segmentIdx: segIdx)
            if candidate.score < bestGlobalScore {
                bestGlobalScore = candidate.score
                bestGlobal = candidate.projection
            }
        }

        return bestGlobal
    }

    // MARK: - Progress Helpers

    /// Remaining distance in meters along the polyline from a given distanceAlongRoute.
    public func remainingDistance(from distanceAlongRouteMeters: Double) -> Double {
        return max(0.0, totalDistanceMeters - distanceAlongRouteMeters)
    }

    /// Distance in meters to a given maneuver step index from current distanceAlongRoute.
    public func distanceToManeuver(
        stepIndex: Int,
        from distanceAlongRouteMeters: Double
    ) -> Double {
        guard stepIndex >= 0 && stepIndex < maneuverDistancesAlongRoute.count else {
            return 0.0
        }
        let stepDist = maneuverDistancesAlongRoute[stepIndex]
        return max(0.0, stepDist - distanceAlongRouteMeters)
    }
}
