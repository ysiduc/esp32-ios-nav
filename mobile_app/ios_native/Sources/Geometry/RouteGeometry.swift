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

    /// Cumulative along-route distance in meters for the BEGINNING of each maneuver step.
    public let maneuverBeginDistancesAlongRoute: [Double]

    /// Cumulative along-route distance in meters for the END of each maneuver step.
    public let maneuverEndDistancesAlongRoute: [Double]

    /// Cumulative along-route distance in meters for each maneuver step (defaults to end distances for backward compatibility).
    public var maneuverDistancesAlongRoute: [Double] {
        maneuverEndDistancesAlongRoute
    }

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

        // Precompute maneuver begin and end distances along the route
        var beginDists: [Double] = []
        var endDists: [Double] = []
        beginDists.reserveCapacity(steps.count)
        endDists.reserveCapacity(steps.count)

        var lastBeginDist: Double = 0.0
        var lastEndDist: Double = 0.0

        for (idx, step) in steps.enumerated() {
            var beginDist: Double
            var endDist: Double

            // 1. Begin distance computation & validation
            if let beginShape = step.beginShapeIndex,
               beginShape >= 0,
               beginShape < cumDist.count {
                beginDist = cumDist[beginShape]
            } else if idx == 0 {
                beginDist = 0.0
            } else {
                // Fallback: approximate closest coordinate cumulative distance
                var bestDist = Double.infinity
                var bestAlong = lastBeginDist
                for cIdx in 0..<coordinates.count {
                    let d = RouteGeometry.distanceBetween(step.coordinate, coordinates[cIdx])
                    if d < bestDist {
                        bestDist = d
                        bestAlong = cumDist[cIdx]
                    }
                }
                beginDist = bestAlong
            }

            // 2. End distance computation & validation
            if let endShape = step.endShapeIndex,
               endShape >= 0,
               endShape < cumDist.count {
                endDist = cumDist[endShape]
            } else if idx == steps.count - 1 && !cumDist.isEmpty {
                endDist = total
            } else {
                // Fallback: approximate closest coordinate cumulative distance
                var bestDist = Double.infinity
                var bestAlong = max(beginDist, lastEndDist)
                for cIdx in 0..<coordinates.count {
                    let d = RouteGeometry.distanceBetween(step.coordinate, coordinates[cIdx])
                    if d < bestDist {
                        bestDist = d
                        bestAlong = cumDist[cIdx]
                    }
                }
                endDist = bestAlong
            }

            // Monotonic step ordering validation (Requirement 36)
            if let bShape = step.beginShapeIndex, let eShape = step.endShapeIndex {
                if bShape > eShape || bShape < 0 || eShape >= coordinates.count {
                    #if DEBUG
                    print("[RouteGeometry] Invalid step indices for step \(idx): begin=\(bShape), end=\(eShape), coords=\(coordinates.count)")
                    #endif
                }
            }

            // Guarantee monotonic progression of begin and end distances
            beginDist = max(lastBeginDist, beginDist)
            endDist   = max(beginDist, max(lastEndDist, endDist))

            if idx == steps.count - 1 && !cumDist.isEmpty {
                endDist = max(endDist, total)
            }

            beginDists.append(beginDist)
            endDists.append(endDist)

            lastBeginDist = beginDist
            lastEndDist = endDist
        }

        self.maneuverBeginDistancesAlongRoute = beginDists
        self.maneuverEndDistancesAlongRoute   = endDists
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

    // MARK: - Pure Nearest-Distance Query (P5.2)

    /// Pure Euclidean nearest projection to the entire route geometry.
    /// Does NOT apply any previous-projection continuity bias or penalties.
    /// Used for physical off-route evidence and physical distance computation.
    public func nearestProjection(
        to coordinate: CLLocationCoordinate2D
    ) -> RouteProjection? {
        guard segmentCount > 0 else {
            if let first = coordinates.first {
                return RouteProjection(
                    coordinate: first,
                    segmentIndex: 0,
                    segmentFraction: 0.0,
                    lateralDistanceMeters: RouteGeometry.distanceBetween(coordinate, first),
                    distanceAlongRouteMeters: 0.0
                )
            }
            return nil
        }

        var bestProj: RouteProjection?
        var bestDist = Double.infinity

        for segIdx in 0..<segmentCount {
            let res = projectOnSegment(point: coordinate, segmentIndex: segIdx)
            if res.lateralDistanceMeters < bestDist {
                bestDist = res.lateralDistanceMeters
                bestProj = RouteProjection(
                    coordinate: res.coordinate,
                    segmentIndex: segIdx,
                    segmentFraction: res.fraction,
                    lateralDistanceMeters: res.lateralDistanceMeters,
                    distanceAlongRouteMeters: res.distanceAlongRouteMeters
                )
            }
        }

        return bestProj
    }

    // MARK: - Confidence-Based Route Matching & Recovery (P5.2)

    /// Matches a GPS location onto this route geometry using confidence-based search and stuck recovery.
    public func matchLocation(
        location: CLLocation,
        lastProjection: RouteProjection? = nil,
        lastMatchedTimestamp: Date? = nil,
        stuckRecoveryTriggered: Bool = false,
        previousPhysicalCoordinate: CLLocationCoordinate2D? = nil
    ) -> RouteMatchResult? {
        guard segmentCount > 0 else {
            if let first = coordinates.first {
                let proj = RouteProjection(
                    coordinate: first,
                    segmentIndex: 0,
                    segmentFraction: 0.0,
                    lateralDistanceMeters: RouteGeometry.distanceBetween(location.coordinate, first),
                    distanceAlongRouteMeters: 0.0
                )
                return RouteMatchResult(
                    projection: proj,
                    localCandidateDistance: proj.lateralDistanceMeters,
                    confidence: .high
                )
            }
            return nil
        }

        let point = location.coordinate

        // Elapsed time delta calculation with safety clamps (dt in seconds)
        let dt: Double
        if let prevTime = lastMatchedTimestamp {
            let rawDt = location.timestamp.timeIntervalSince(prevTime)
            dt = (rawDt > 0 && rawDt.isFinite) ? max(0.2, min(30.0, rawDt)) : 1.0
        } else {
            dt = 1.0
        }

        let physicalTravel: Double
        if let prevPhysical = previousPhysicalCoordinate {
            physicalTravel = RouteGeometry.distanceBetween(prevPhysical, point)
        } else if let prev = lastProjection {
            physicalTravel = RouteGeometry.distanceBetween(prev.coordinate, point)
        } else {
            physicalTravel = 0.0
        }

        let speedMps = max(0.0, location.speed)
        let accuracyAllowance = max(5.0, location.horizontalAccuracy * 1.5)
        let minimumNoiseAllowance = 25.0
        let maxPlausibleForward = max(
            minimumNoiseAllowance + accuracyAllowance,
            speedMps * dt * 1.8 + accuracyAllowance
        )

        // Helper to evaluate a segment with continuity penalties
        func scoreCandidate(
            segmentIdx: Int,
            allowRecoveryForwardJump: Bool = false
        ) -> (projection: RouteProjection, score: Double, headingDiff: Double?) {
            let res = projectOnSegment(point: point, segmentIndex: segmentIdx)
            let proj = RouteProjection(
                coordinate: res.coordinate,
                segmentIndex: segmentIdx,
                segmentFraction: res.fraction,
                lateralDistanceMeters: res.lateralDistanceMeters,
                distanceAlongRouteMeters: res.distanceAlongRouteMeters
            )

            var penalty: Double = 0.0
            var headingDiff: Double? = nil

            if let prev = lastProjection {
                let delta = res.distanceAlongRouteMeters - prev.distanceAlongRouteMeters

                // 1. Backward snap penalty: allow up to 20m for GPS noise, heavily penalize beyond
                if delta < -20.0 {
                    penalty += abs(delta + 20.0) * 5.0
                }

                // 2. Temporal forward jump penalty
                if delta > maxPlausibleForward {
                    if allowRecoveryForwardJump && stuckRecoveryTriggered && delta > 0 {
                        // In stuck recovery mode, waive forward penalty if candidate has good lateral proximity
                        if res.lateralDistanceMeters <= 15.0 {
                            penalty += 0.0
                        } else {
                            penalty += (delta - maxPlausibleForward) * 1.0
                        }
                    } else {
                        penalty += (delta - maxPlausibleForward) * 2.5
                    }
                }
            } else {
                penalty += Double(segmentIdx) * 0.05
            }

            // 3. Heading tie-breaker: evaluate vehicle course against segment bearing
            if location.speed > 1.5 && location.course >= 0 {
                let a = coordinates[segmentIdx]
                let b = coordinates[segmentIdx + 1]
                let segBearing = RouteGeometry.bearing(from: a, to: b)
                let diff = abs(segBearing - location.course)
                let minAngle = min(diff, 360.0 - diff)
                headingDiff = minAngle

                if minAngle > 95.0 {
                    penalty += 35.0
                } else if minAngle > 60.0 {
                    penalty += 15.0
                }
            }

            let totalScore = res.lateralDistanceMeters + penalty
            return (proj, totalScore, headingDiff)
        }

        // Tier 1: Local Window Search
        var bestLocal: RouteProjection?
        var bestLocalScore = Double.infinity
        var bestLocalHeadingDiff: Double?
        var localConfidence: RouteMatchConfidence = .low

        if let prev = lastProjection {
            let winStart = max(0, prev.segmentIndex - 2)
            let winEnd = min(segmentCount - 1, prev.segmentIndex + 25)

            for segIdx in winStart...winEnd {
                let candidate = scoreCandidate(segmentIdx: segIdx)
                if candidate.score < bestLocalScore {
                    bestLocalScore = candidate.score
                    bestLocal = candidate.projection
                    bestLocalHeadingDiff = candidate.headingDiff
                }
            }

            if let local = bestLocal {
                let delta = local.distanceAlongRouteMeters - prev.distanceAlongRouteMeters
                let tightLateralLimit = max(12.0, location.horizontalAccuracy * 1.0)
                let headingOk = (bestLocalHeadingDiff == nil || bestLocalHeadingDiff! <= 45.0)
                let forwardOk = (delta >= -5.0 && delta <= maxPlausibleForward)

                if !stuckRecoveryTriggered && local.lateralDistanceMeters <= tightLateralLimit && headingOk && forwardOk {
                    localConfidence = .high
                } else if local.lateralDistanceMeters <= 25.0 && (bestLocalHeadingDiff == nil || bestLocalHeadingDiff! <= 75.0) {
                    localConfidence = .medium
                } else {
                    localConfidence = .low
                }
            }
        }

        // Fast acceptance if local match has high confidence and no stuck recovery is active
        if localConfidence == .high, let local = bestLocal, !stuckRecoveryTriggered {
            let delta = local.distanceAlongRouteMeters - (lastProjection?.distanceAlongRouteMeters ?? 0.0)
            return RouteMatchResult(
                projection: local,
                localCandidateDistance: local.lateralDistanceMeters,
                globalCandidateDistance: nil,
                alongRouteDelta: delta,
                physicalTravelSincePrevious: physicalTravel,
                headingDifferenceDegrees: bestLocalHeadingDiff,
                usedGlobalRecovery: false,
                confidence: .high
            )
        }

        // Tier 2: Global Search Fallback (Evaluated when local confidence is medium/low or stuck recovery triggered)
        var bestGlobal: RouteProjection?
        var bestGlobalScore = Double.infinity
        var bestGlobalHeadingDiff: Double?

        for segIdx in 0..<segmentCount {
            let candidate = scoreCandidate(segmentIdx: segIdx, allowRecoveryForwardJump: stuckRecoveryTriggered)
            if candidate.score < bestGlobalScore {
                bestGlobalScore = candidate.score
                bestGlobal = candidate.projection
                bestGlobalHeadingDiff = candidate.headingDiff
            }
        }

        // Determine winner between local candidate and global candidate
        if stuckRecoveryTriggered,
           let global = bestGlobal,
           let prev = lastProjection,
           global.segmentIndex > prev.segmentIndex,
           global.lateralDistanceMeters <= 20.0 {
            // Controlled global jump forward to escape projection lock
            let delta = global.distanceAlongRouteMeters - prev.distanceAlongRouteMeters
            return RouteMatchResult(
                projection: global,
                localCandidateDistance: bestLocal?.lateralDistanceMeters ?? 0.0,
                globalCandidateDistance: global.lateralDistanceMeters,
                alongRouteDelta: delta,
                physicalTravelSincePrevious: physicalTravel,
                headingDifferenceDegrees: bestGlobalHeadingDiff,
                usedGlobalRecovery: true,
                confidence: .high
            )
        }

        if let global = bestGlobal,
           (bestLocal == nil || bestGlobalScore < (bestLocalScore - 5.0) || localConfidence == .low) {
            let delta = global.distanceAlongRouteMeters - (lastProjection?.distanceAlongRouteMeters ?? 0.0)
            let conf: RouteMatchConfidence = global.lateralDistanceMeters <= 15.0 ? .high : .medium
            return RouteMatchResult(
                projection: global,
                localCandidateDistance: bestLocal?.lateralDistanceMeters ?? 0.0,
                globalCandidateDistance: global.lateralDistanceMeters,
                alongRouteDelta: delta,
                physicalTravelSincePrevious: physicalTravel,
                headingDifferenceDegrees: bestGlobalHeadingDiff,
                usedGlobalRecovery: stuckRecoveryTriggered,
                confidence: conf
            )
        }

        if let local = bestLocal {
            let delta = local.distanceAlongRouteMeters - (lastProjection?.distanceAlongRouteMeters ?? 0.0)
            return RouteMatchResult(
                projection: local,
                localCandidateDistance: local.lateralDistanceMeters,
                globalCandidateDistance: bestGlobal?.lateralDistanceMeters,
                alongRouteDelta: delta,
                physicalTravelSincePrevious: physicalTravel,
                headingDifferenceDegrees: bestLocalHeadingDiff,
                usedGlobalRecovery: false,
                confidence: localConfidence
            )
        }

        if let global = bestGlobal {
            let delta = global.distanceAlongRouteMeters - (lastProjection?.distanceAlongRouteMeters ?? 0.0)
            return RouteMatchResult(
                projection: global,
                localCandidateDistance: 0.0,
                globalCandidateDistance: global.lateralDistanceMeters,
                alongRouteDelta: delta,
                physicalTravelSincePrevious: physicalTravel,
                headingDifferenceDegrees: bestGlobalHeadingDiff,
                usedGlobalRecovery: false,
                confidence: .medium
            )
        }

        return nil
    }

    /// Projects a GPS location onto this route geometry (delegates to matchLocation).
    public func project(
        location: CLLocation,
        lastProjection: RouteProjection? = nil,
        lastMatchedTimestamp: Date? = nil
    ) -> RouteProjection? {
        return matchLocation(
            location: location,
            lastProjection: lastProjection,
            lastMatchedTimestamp: lastMatchedTimestamp
        )?.projection
    }

    // MARK: - Progress Helpers

    /// Remaining distance in meters along the polyline from a given distanceAlongRoute.
    public func remainingDistance(from distanceAlongRouteMeters: Double) -> Double {
        return max(0.0, totalDistanceMeters - distanceAlongRouteMeters)
    }

    /// Distance in meters to a given maneuver step index from current distanceAlongRoute (legacy end-distance semantics).
    public func distanceToManeuver(
        stepIndex: Int,
        from distanceAlongRouteMeters: Double
    ) -> Double {
        guard stepIndex >= 0 && stepIndex < maneuverEndDistancesAlongRoute.count else {
            return 0.0
        }
        let stepDist = maneuverEndDistancesAlongRoute[stepIndex]
        return max(0.0, stepDist - distanceAlongRouteMeters)
    }

    /// Distance in meters to a given maneuver step's begin/action point from current distanceAlongRoute.
    public func distanceToManeuverBegin(
        stepIndex: Int,
        from distanceAlongRouteMeters: Double
    ) -> Double {
        guard stepIndex >= 0 && stepIndex < maneuverBeginDistancesAlongRoute.count else {
            return 0.0
        }
        let stepDist = maneuverBeginDistancesAlongRoute[stepIndex]
        return max(0.0, stepDist - distanceAlongRouteMeters)
    }

    /// Pure geometry helper returning the exact coordinate along the route at the given along-route distance (P5.2.1).
    public func coordinate(
        atDistanceAlongRoute distanceMeters: Double
    ) -> CLLocationCoordinate2D? {
        guard !coordinates.isEmpty else { return nil }
        guard coordinates.count >= 2 else { return coordinates.first }
        let targetDist = max(0.0, min(totalDistanceMeters, distanceMeters))

        var segIdx = 0
        while segIdx + 1 < cumulativeDistances.count && cumulativeDistances[segIdx + 1] < targetDist {
            segIdx += 1
        }
        segIdx = min(segIdx, segmentCount - 1)

        let a = coordinates[segIdx]
        let b = coordinates[segIdx + 1]
        let segStartDist = cumulativeDistances[segIdx]
        let segLen = cumulativeDistances[segIdx + 1] - segStartDist
        let fraction = segLen > 1e-6 ? max(0.0, min(1.0, (targetDist - segStartDist) / segLen)) : 0.0

        let lat = a.latitude + fraction * (b.latitude - a.latitude)
        let lon = a.longitude + fraction * (b.longitude - a.longitude)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Returns the remaining polyline coordinates starting from the specified along-route distance (P5.2 Requirements 17 & 18, P5.2.1).
    /// Continuous polyline trimming ensures passed geometry is promptly removed without requiring reroute.
    /// The first coordinate is derived directly from the along-route distance unless an explicit snapped coordinate is supplied.
    public func trimmedPolyline(
        from distanceAlongRouteMeters: Double,
        snappedCoordinate: CLLocationCoordinate2D? = nil
    ) -> [CLLocationCoordinate2D] {
        guard coordinates.count >= 2 else { return coordinates }
        let targetDist = max(0.0, min(totalDistanceMeters, distanceAlongRouteMeters))

        guard let startCoord = (snappedCoordinate ?? coordinate(atDistanceAlongRoute: targetDist)) else {
            return coordinates
        }

        var segIdx = 0
        while segIdx + 1 < cumulativeDistances.count && cumulativeDistances[segIdx + 1] < targetDist {
            segIdx += 1
        }
        segIdx = min(segIdx, segmentCount - 1)

        var remaining: [CLLocationCoordinate2D] = [startCoord]
        if segIdx + 1 < coordinates.count {
            remaining.append(contentsOf: coordinates[(segIdx + 1)...])
        }
        return remaining
    }

    // MARK: - MapKit Step Mapping Helper

    /// Pure helper to map sub-polylines (such as MKRouteStep polylines) monotonically into full route coordinates.
    public static func mapStepPolylinesToIndices(
        stepPolylines: [[CLLocationCoordinate2D]],
        fullPolyline: [CLLocationCoordinate2D]
    ) -> [(beginShapeIndex: Int, endShapeIndex: Int)] {
        var results: [(beginShapeIndex: Int, endShapeIndex: Int)] = []
        var searchIndex = 0

        for stepCoords in stepPolylines {
            guard !stepCoords.isEmpty && !fullPolyline.isEmpty else {
                results.append((beginShapeIndex: searchIndex, endShapeIndex: searchIndex))
                continue
            }

            let firstCoord = stepCoords.first!
            let lastCoord = stepCoords.last!

            var bestBegin = searchIndex
            var bestBeginDist = Double.infinity
            let maxBeginSearch = min(fullPolyline.count, searchIndex + 100)
            for i in searchIndex..<maxBeginSearch {
                let d = RouteGeometry.distanceBetween(firstCoord, fullPolyline[i])
                if d < bestBeginDist {
                    bestBeginDist = d
                    bestBegin = i
                    if d < 2.0 { break }
                }
            }

            var bestEnd = bestBegin
            var bestEndDist = Double.infinity
            let maxEndSearch = min(fullPolyline.count, bestBegin + max(20, stepCoords.count * 2))
            for j in bestBegin..<maxEndSearch {
                let d = RouteGeometry.distanceBetween(lastCoord, fullPolyline[j])
                if d < bestEndDist {
                    bestEndDist = d
                    bestEnd = j
                    if d < 2.0 { break }
                }
            }

            let beginIdx = bestBegin
            let endIdx = max(bestBegin, bestEnd)
            results.append((beginShapeIndex: beginIdx, endShapeIndex: endIdx))
            searchIndex = endIdx
        }

        return results
    }
}
