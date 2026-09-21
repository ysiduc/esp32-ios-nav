//
//  RouteProjection.swift
//  Pure geometry model representing a matched position along a route.
//

import CoreLocation
import Foundation

/// Represents a matched/projected position along a route polyline.
public struct RouteProjection: Equatable, Sendable {
    /// Coordinates of the projected point on the route polyline.
    public let coordinate: CLLocationCoordinate2D

    /// Index of the polyline segment (from coordinates[segmentIndex] to coordinates[segmentIndex + 1]).
    public let segmentIndex: Int

    /// Fraction along the segment in range [0.0, 1.0].
    public let segmentFraction: Double

    /// Perpendicular lateral distance from the input GPS point to the route segment in meters.
    public let lateralDistanceMeters: Double

    /// Cumulative distance from the start of the route to this projected point in meters.
    public let distanceAlongRouteMeters: Double

    public init(
        coordinate: CLLocationCoordinate2D,
        segmentIndex: Int,
        segmentFraction: Double,
        lateralDistanceMeters: Double,
        distanceAlongRouteMeters: Double
    ) {
        self.coordinate = coordinate
        self.segmentIndex = segmentIndex
        self.segmentFraction = max(0.0, min(1.0, segmentFraction))
        self.lateralDistanceMeters = lateralDistanceMeters
        self.distanceAlongRouteMeters = distanceAlongRouteMeters
    }

    public static func == (lhs: RouteProjection, rhs: RouteProjection) -> Bool {
        return abs(lhs.coordinate.latitude - rhs.coordinate.latitude) < 1e-6 &&
               abs(lhs.coordinate.longitude - rhs.coordinate.longitude) < 1e-6 &&
               lhs.segmentIndex == rhs.segmentIndex &&
               abs(lhs.segmentFraction - rhs.segmentFraction) < 1e-4 &&
               abs(lhs.lateralDistanceMeters - rhs.lateralDistanceMeters) < 1e-2 &&
               abs(lhs.distanceAlongRouteMeters - rhs.distanceAlongRouteMeters) < 1e-2
    }
}


// MARK: - Match Confidence & Result (P5.2)

public enum RouteMatchConfidence: String, Sendable, Equatable {
    case high
    case medium
    case low
}

/// Rich match result exposing projection details, candidate distances, heading agreement,
/// along-route progress delta, and match confidence.
public struct RouteMatchResult: Sendable, Equatable {
    public let projection: RouteProjection
    public let localCandidateDistance: Double
    public let globalCandidateDistance: Double?
    public let alongRouteDelta: Double
    public let physicalTravelSincePrevious: Double
    public let headingDifferenceDegrees: Double?
    public let usedGlobalRecovery: Bool
    public let confidence: RouteMatchConfidence

    public init(
        projection: RouteProjection,
        localCandidateDistance: Double,
        globalCandidateDistance: Double? = nil,
        alongRouteDelta: Double = 0.0,
        physicalTravelSincePrevious: Double = 0.0,
        headingDifferenceDegrees: Double? = nil,
        usedGlobalRecovery: Bool = false,
        confidence: RouteMatchConfidence = .high
    ) {
        self.projection = projection
        self.localCandidateDistance = localCandidateDistance
        self.globalCandidateDistance = globalCandidateDistance
        self.alongRouteDelta = alongRouteDelta
        self.physicalTravelSincePrevious = physicalTravelSincePrevious
        self.headingDifferenceDegrees = headingDifferenceDegrees
        self.usedGlobalRecovery = usedGlobalRecovery
        self.confidence = confidence
    }
}
