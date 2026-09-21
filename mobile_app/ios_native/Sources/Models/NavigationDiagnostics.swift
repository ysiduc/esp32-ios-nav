//
//  NavigationDiagnostics.swift
//  Lightweight, thread-safe runtime diagnostics counters and latency tracking.
//

import Foundation

/// Snapshot of diagnostic telemetry for a single GPS update (DEBUG / testing).
public struct FieldNavigationTraceSnapshot: Sendable, Equatable {
    public let timestamp: Date
    public let horizontalAccuracy: Double
    public let speed: Double
    public let course: Double
    public let rawNearestRouteDistance: Double
    public let matchedSegmentIndex: Int
    public let matchedAlongRouteMeters: Double
    public let previousMatchedMeters: Double
    public let physicalDisplacement: Double
    public let alongRouteAdvancement: Double
    public let matchConfidence: String
    public let currentUpcomingManeuverIndex: Int
    public let distanceToUpcomingManeuver: Double
    public let offRouteState: String
    public let offRouteReason: String
    public let rerouteState: String

    public init(
        timestamp: Date,
        horizontalAccuracy: Double,
        speed: Double,
        course: Double,
        rawNearestRouteDistance: Double,
        matchedSegmentIndex: Int,
        matchedAlongRouteMeters: Double,
        previousMatchedMeters: Double,
        physicalDisplacement: Double,
        alongRouteAdvancement: Double,
        matchConfidence: String,
        currentUpcomingManeuverIndex: Int,
        distanceToUpcomingManeuver: Double,
        offRouteState: String,
        offRouteReason: String,
        rerouteState: String
    ) {
        self.timestamp = timestamp
        self.horizontalAccuracy = horizontalAccuracy
        self.speed = speed
        self.course = course
        self.rawNearestRouteDistance = rawNearestRouteDistance
        self.matchedSegmentIndex = matchedSegmentIndex
        self.matchedAlongRouteMeters = matchedAlongRouteMeters
        self.previousMatchedMeters = previousMatchedMeters
        self.physicalDisplacement = physicalDisplacement
        self.alongRouteAdvancement = alongRouteAdvancement
        self.matchConfidence = matchConfidence
        self.currentUpcomingManeuverIndex = currentUpcomingManeuverIndex
        self.distanceToUpcomingManeuver = distanceToUpcomingManeuver
        self.offRouteState = offRouteState
        self.offRouteReason = offRouteReason
        self.rerouteState = rerouteState
    }
}

/// Snapshot of runtime navigation, BLE, and rendering metrics.
public struct NavigationDiagnostics: Sendable, Equatable {
    // Location metrics
    public var locationsReceived: Int = 0
    public var locationsAccepted: Int = 0
    public var locationsRejectedForAccuracy: Int = 0
    public var progressComputations: Int = 0

    // Off-route & reroute metrics
    public var offRouteObservations: Int = 0
    public var offRouteConfirmations: Int = 0
    public var rerouteRequests: Int = 0
    public var rerouteCommits: Int = 0

    // Observable latency metrics (P5.2 Requirement 50)
    public var offRouteSuspectedAt: Date?
    public var offRouteConfirmedAt: Date?
    public var rerouteStartedAt: Date?
    public var rerouteCommittedAt: Date?

    public var suspectedToConfirmedLatency: TimeInterval? {
        guard let s = offRouteSuspectedAt, let c = offRouteConfirmedAt else { return nil }
        return c.timeIntervalSince(s)
    }

    public var confirmedToRequestStartLatency: TimeInterval? {
        guard let c = offRouteConfirmedAt, let r = rerouteStartedAt else { return nil }
        return r.timeIntervalSince(c)
    }

    public var requestStartToCommitLatency: TimeInterval? {
        guard let r = rerouteStartedAt, let commit = rerouteCommittedAt else { return nil }
        return commit.timeIntervalSince(r)
    }

    public var latestFieldTrace: FieldNavigationTraceSnapshot?

    public init() {}

    public mutating func reset() {
        self = NavigationDiagnostics()
    }
}
