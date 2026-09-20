//
//  OffRouteDetector.swift
//  Pure deterministic state machine for quality-aware, time-based off-route detection.
//

import Foundation
import CoreLocation

// MARK: - Observation Model

/// Input observation from the location pipeline (physical filtered GPS + route projection).
public struct OffRouteObservation: Sendable, Equatable {
    public let timestamp: Date
    public let lateralDistanceMeters: Double
    public let horizontalAccuracyMeters: Double
    public let speedMetersPerSecond: Double
    public let courseDegrees: Double?
    public let routeBearingDegrees: Double?
    public let distanceAlongRouteMeters: Double

    public init(
        timestamp: Date,
        lateralDistanceMeters: Double,
        horizontalAccuracyMeters: Double,
        speedMetersPerSecond: Double,
        courseDegrees: Double? = nil,
        routeBearingDegrees: Double? = nil,
        distanceAlongRouteMeters: Double = 0.0
    ) {
        self.timestamp = timestamp
        self.lateralDistanceMeters = lateralDistanceMeters
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
        self.speedMetersPerSecond = speedMetersPerSecond
        self.courseDegrees = courseDegrees
        self.routeBearingDegrees = routeBearingDegrees
        self.distanceAlongRouteMeters = distanceAlongRouteMeters
    }
}

// MARK: - States & Decisions

public enum OffRouteState: String, Sendable, Equatable {
    case onRoute
    case suspected
    case confirmed
}

public enum OffRouteReason: String, Sendable, Equatable {
    case none
    case sustainedLateralDeviation
    case courseDivergence
    case strongLateralDeviation
    case lowSpeedDriftDwell
    case recoveredToRoute
}

public struct OffRouteDecision: Sendable, Equatable {
    public let state: OffRouteState
    public let becameConfirmed: Bool
    public let recovered: Bool
    public let reason: OffRouteReason
    public let lateralDistanceMeters: Double
    public let activeThresholdMeters: Double

    public init(
        state: OffRouteState,
        becameConfirmed: Bool,
        recovered: Bool,
        reason: OffRouteReason,
        lateralDistanceMeters: Double,
        activeThresholdMeters: Double
    ) {
        self.state = state
        self.becameConfirmed = becameConfirmed
        self.recovered = recovered
        self.reason = reason
        self.lateralDistanceMeters = lateralDistanceMeters
        self.activeThresholdMeters = activeThresholdMeters
    }
}

// MARK: - Configuration

public struct OffRouteDetectorConfig: Sendable {
    /// Base lateral deviation threshold (meters) under ideal GPS conditions.
    public var baseEnterThresholdMeters: Double = 15.0
    /// Accuracy scalar: enter threshold scales with horizontal accuracy to prevent noisy false positives.
    public var accuracyMultiplier: Double = 1.2
    /// Hysteresis recovery threshold (meters) to prevent state oscillation.
    public var recoveryThresholdMeters: Double = 10.0
    /// Standard dwell duration required to confirm off-route when moving normally.
    public var standardDwellSeconds: Double = 2.5
    /// Reduced dwell duration when moving vehicle course clearly diverges from route.
    public var courseDivergenceDwellSeconds: Double = 1.5
    /// Extended dwell duration when stationary/low-speed to suppress GPS drift reroutes.
    public var stationaryDwellSeconds: Double = 5.0
    /// Accelerated dwell duration for very large physical deviations with good GPS accuracy.
    public var strongDeviationDwellSeconds: Double = 1.0
    /// Lateral deviation qualifying as strong physical deviation (meters).
    public var strongDeviationThresholdMeters: Double = 40.0
    /// Maximum allowable horizontal accuracy for strong-deviation fast-tracking.
    public var strongDeviationMaxAccuracyMeters: Double = 15.0
    /// Angular divergence between course and route bearing considered divergent (degrees).
    public var courseMismatchAngleDegrees: Double = 45.0
    /// Minimum vehicle speed required to evaluate course divergence (m/s) (~10.8 km/h).
    public var minSpeedForCourseMetersPerSecond: Double = 3.0
    /// Persistence duration below recovery threshold before confirming return to route.
    public var recoveryDwellSeconds: Double = 1.0

    public init(
        baseEnterThresholdMeters: Double = 15.0,
        accuracyMultiplier: Double = 1.2,
        recoveryThresholdMeters: Double = 10.0,
        standardDwellSeconds: Double = 2.5,
        courseDivergenceDwellSeconds: Double = 1.5,
        stationaryDwellSeconds: Double = 5.0,
        strongDeviationDwellSeconds: Double = 1.0,
        strongDeviationThresholdMeters: Double = 40.0,
        strongDeviationMaxAccuracyMeters: Double = 15.0,
        courseMismatchAngleDegrees: Double = 45.0,
        minSpeedForCourseMetersPerSecond: Double = 3.0,
        recoveryDwellSeconds: Double = 1.0
    ) {
        self.baseEnterThresholdMeters = baseEnterThresholdMeters
        self.accuracyMultiplier = accuracyMultiplier
        self.recoveryThresholdMeters = recoveryThresholdMeters
        self.standardDwellSeconds = standardDwellSeconds
        self.courseDivergenceDwellSeconds = courseDivergenceDwellSeconds
        self.stationaryDwellSeconds = stationaryDwellSeconds
        self.strongDeviationDwellSeconds = strongDeviationDwellSeconds
        self.strongDeviationThresholdMeters = strongDeviationThresholdMeters
        self.strongDeviationMaxAccuracyMeters = strongDeviationMaxAccuracyMeters
        self.courseMismatchAngleDegrees = courseMismatchAngleDegrees
        self.minSpeedForCourseMetersPerSecond = minSpeedForCourseMetersPerSecond
        self.recoveryDwellSeconds = recoveryDwellSeconds
    }
}

// MARK: - Detector Implementation

public final class OffRouteDetector: @unchecked Sendable {
    public let config: OffRouteDetectorConfig
    public private(set) var state: OffRouteState = .onRoute
    public private(set) var suspectStartedAt: Date?
    public private(set) var recoveryStartedAt: Date?
    public private(set) var lastObservationTimestamp: Date?

    public init(config: OffRouteDetectorConfig = OffRouteDetectorConfig()) {
        self.config = config
    }

    /// Evaluates a new navigation observation and returns a deterministic decision.
    public func evaluate(observation: OffRouteObservation) -> OffRouteDecision {
        lastObservationTimestamp = observation.timestamp

        let enterThreshold = max(
            config.baseEnterThresholdMeters,
            observation.horizontalAccuracyMeters * config.accuracyMultiplier
        )
        let recoveryThreshold = min(
            config.recoveryThresholdMeters,
            enterThreshold * 0.65
        )

        switch state {
        case .onRoute:
            if observation.lateralDistanceMeters > enterThreshold {
                state = .suspected
                suspectStartedAt = observation.timestamp
                recoveryStartedAt = nil
                return OffRouteDecision(
                    state: .suspected,
                    becameConfirmed: false,
                    recovered: false,
                    reason: .sustainedLateralDeviation,
                    lateralDistanceMeters: observation.lateralDistanceMeters,
                    activeThresholdMeters: enterThreshold
                )
            } else {
                return OffRouteDecision(
                    state: .onRoute,
                    becameConfirmed: false,
                    recovered: false,
                    reason: .none,
                    lateralDistanceMeters: observation.lateralDistanceMeters,
                    activeThresholdMeters: enterThreshold
                )
            }

        case .suspected:
            // If observation returned below recovery threshold, immediately abort suspicion (spike protection)
            if observation.lateralDistanceMeters <= recoveryThreshold {
                state = .onRoute
                suspectStartedAt = nil
                recoveryStartedAt = nil
                return OffRouteDecision(
                    state: .onRoute,
                    becameConfirmed: false,
                    recovered: true,
                    reason: .recoveredToRoute,
                    lateralDistanceMeters: observation.lateralDistanceMeters,
                    activeThresholdMeters: recoveryThreshold
                )
            }

            let suspectStartTime = suspectStartedAt ?? observation.timestamp
            let elapsedSuspect = max(0.0, observation.timestamp.timeIntervalSince(suspectStartTime))

            // Determine required dwell time and reason
            let (requiredDwell, reason) = determineDwellAndReason(observation: observation)

            if elapsedSuspect >= requiredDwell {
                state = .confirmed
                return OffRouteDecision(
                    state: .confirmed,
                    becameConfirmed: true,
                    recovered: false,
                    reason: reason,
                    lateralDistanceMeters: observation.lateralDistanceMeters,
                    activeThresholdMeters: enterThreshold
                )
            } else {
                return OffRouteDecision(
                    state: .suspected,
                    becameConfirmed: false,
                    recovered: false,
                    reason: reason,
                    lateralDistanceMeters: observation.lateralDistanceMeters,
                    activeThresholdMeters: enterThreshold
                )
            }

        case .confirmed:
            // While confirmed, evaluate recovery with hysteresis and dwell
            if observation.lateralDistanceMeters <= recoveryThreshold {
                let recStartTime = recoveryStartedAt ?? observation.timestamp
                if recoveryStartedAt == nil {
                    recoveryStartedAt = observation.timestamp
                }
                let elapsedRecovery = max(0.0, observation.timestamp.timeIntervalSince(recStartTime))

                if elapsedRecovery >= config.recoveryDwellSeconds {
                    state = .onRoute
                    suspectStartedAt = nil
                    recoveryStartedAt = nil
                    return OffRouteDecision(
                        state: .onRoute,
                        becameConfirmed: false,
                        recovered: true,
                        reason: .recoveredToRoute,
                        lateralDistanceMeters: observation.lateralDistanceMeters,
                        activeThresholdMeters: recoveryThreshold
                    )
                } else {
                    return OffRouteDecision(
                        state: .confirmed,
                        becameConfirmed: false,
                        recovered: false,
                        reason: .none,
                        lateralDistanceMeters: observation.lateralDistanceMeters,
                        activeThresholdMeters: recoveryThreshold
                    )
                }
            } else {
                recoveryStartedAt = nil
                return OffRouteDecision(
                    state: .confirmed,
                    becameConfirmed: false,
                    recovered: false,
                    reason: .sustainedLateralDeviation,
                    lateralDistanceMeters: observation.lateralDistanceMeters,
                    activeThresholdMeters: enterThreshold
                )
            }
        }
    }

    /// Resets all detector state to onRoute (called on route installation or lifecycle stop).
    public func reset() {
        state = .onRoute
        suspectStartedAt = nil
        recoveryStartedAt = nil
        lastObservationTimestamp = nil
    }

    // MARK: - Helper Calculations

    private func determineDwellAndReason(observation: OffRouteObservation) -> (Double, OffRouteReason) {
        // 1. Strong deviation fast track
        if observation.lateralDistanceMeters >= config.strongDeviationThresholdMeters &&
           observation.horizontalAccuracyMeters <= config.strongDeviationMaxAccuracyMeters {
            return (config.strongDeviationDwellSeconds, .strongLateralDeviation)
        }

        // 2. Course divergence supporting evidence (only when moving fast enough)
        if observation.speedMetersPerSecond >= config.minSpeedForCourseMetersPerSecond,
           let course = observation.courseDegrees, course >= 0.0,
           let bearing = observation.routeBearingDegrees {
            let diff = angularDifferenceDegrees(course, bearing)
            if diff >= config.courseMismatchAngleDegrees {
                return (config.courseDivergenceDwellSeconds, .courseDivergence)
            }
        }

        // 3. Normal vehicle motion
        if observation.speedMetersPerSecond >= config.minSpeedForCourseMetersPerSecond {
            return (config.standardDwellSeconds, .sustainedLateralDeviation)
        }

        // 4. Low speed / stationary motion
        return (config.stationaryDwellSeconds, .lowSpeedDriftDwell)
    }

    private func angularDifferenceDegrees(_ a: Double, _ b: Double) -> Double {
        let diff = abs(a - b).truncatingRemainder(dividingBy: 360.0)
        return diff > 180.0 ? 360.0 - diff : diff
    }
}
