//
//  OffRouteDetector.swift
//  Pure deterministic state machine for quality-aware, multi-signal off-route detection.
//

import Foundation
import CoreLocation

// MARK: - Observation Model

/// Input observation from the location pipeline (physical raw/filtered GPS + route projection).
public struct OffRouteObservation: Sendable, Equatable {
    public let timestamp: Date
    public let lateralDistanceMeters: Double
    public let horizontalAccuracyMeters: Double
    public let speedMetersPerSecond: Double
    public let courseDegrees: Double?
    public let routeBearingDegrees: Double?
    public let distanceAlongRouteMeters: Double
    public let rawNearestRouteDistanceMeters: Double
    public let isMatcherStuck: Bool

    public init(
        timestamp: Date,
        lateralDistanceMeters: Double,
        horizontalAccuracyMeters: Double,
        speedMetersPerSecond: Double,
        courseDegrees: Double? = nil,
        routeBearingDegrees: Double? = nil,
        distanceAlongRouteMeters: Double = 0.0,
        rawNearestRouteDistanceMeters: Double = 0.0,
        isMatcherStuck: Bool = false
    ) {
        self.timestamp = timestamp
        self.lateralDistanceMeters = lateralDistanceMeters
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
        self.speedMetersPerSecond = speedMetersPerSecond
        self.courseDegrees = courseDegrees
        self.routeBearingDegrees = routeBearingDegrees
        self.distanceAlongRouteMeters = distanceAlongRouteMeters
        self.rawNearestRouteDistanceMeters = rawNearestRouteDistanceMeters
        self.isMatcherStuck = isMatcherStuck
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
    case stuckMatcherDeviation
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
    public var baseEnterThresholdMeters: Double
    public var accuracyMultiplier: Double
    public var recoveryThresholdMeters: Double
    public var standardDwellSeconds: Double
    public var courseDivergenceDwellSeconds: Double
    public var stationaryDwellSeconds: Double
    public var strongDeviationDwellSeconds: Double
    public var strongDeviationThresholdMeters: Double
    public var strongDeviationMaxAccuracyMeters: Double
    public var courseMismatchAngleDegrees: Double
    public var minSpeedForCourseMetersPerSecond: Double
    public var recoveryDwellSeconds: Double

    public init(
        baseEnterThresholdMeters: Double = 15.0,
        accuracyMultiplier: Double = 1.2,
        recoveryThresholdMeters: Double = 10.0,
        standardDwellSeconds: Double = 2.5,
        courseDivergenceDwellSeconds: Double = 1.0,
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

        // Effective physical distance uses pure raw nearest distance if available and larger
        let effectivePhysicalDistance = max(observation.lateralDistanceMeters, observation.rawNearestRouteDistanceMeters)

        switch state {
        case .onRoute:
            var suspicionTriggered = false
            var initialReason: OffRouteReason = .none

            // Signal A: Lateral or pure raw nearest distance exceeds physical enter threshold
            if effectivePhysicalDistance > enterThreshold {
                suspicionTriggered = true
                initialReason = .sustainedLateralDeviation
            }

            // Signal B: Course divergence while moving at meaningful speed (>= 3.0 m/s) with non-trivial physical separation
            if !suspicionTriggered && observation.speedMetersPerSecond >= config.minSpeedForCourseMetersPerSecond,
               let course = observation.courseDegrees, course >= 0.0,
               let bearing = observation.routeBearingDegrees {
                let diff = angularDifferenceDegrees(course, bearing)
                if diff >= config.courseMismatchAngleDegrees && effectivePhysicalDistance >= 8.0 {
                    suspicionTriggered = true
                    initialReason = .courseDivergence
                }
            }

            // Signal C: Stuck matcher progress while physical GPS advances
            if !suspicionTriggered && observation.isMatcherStuck && effectivePhysicalDistance >= 8.0 {
                suspicionTriggered = true
                initialReason = .stuckMatcherDeviation
            }

            // Signal D: Two moderate signals agree (physical distance >= 10m + course diff >= 45° moving)
            if !suspicionTriggered && observation.speedMetersPerSecond >= 2.5,
               let course = observation.courseDegrees, course >= 0.0,
               let bearing = observation.routeBearingDegrees {
                let diff = angularDifferenceDegrees(course, bearing)
                if diff >= 45.0 && effectivePhysicalDistance >= 10.0 {
                    suspicionTriggered = true
                    initialReason = .courseDivergence
                }
            }

            if suspicionTriggered {
                state = .suspected
                suspectStartedAt = observation.timestamp
                recoveryStartedAt = nil
                return OffRouteDecision(
                    state: .suspected,
                    becameConfirmed: false,
                    recovered: false,
                    reason: initialReason,
                    lateralDistanceMeters: effectivePhysicalDistance,
                    activeThresholdMeters: enterThreshold
                )
            } else {
                return OffRouteDecision(
                    state: .onRoute,
                    becameConfirmed: false,
                    recovered: false,
                    reason: .none,
                    lateralDistanceMeters: effectivePhysicalDistance,
                    activeThresholdMeters: enterThreshold
                )
            }

        case .suspected:
            // If observation returned below recovery threshold, immediately abort suspicion (spike protection)
            if effectivePhysicalDistance <= recoveryThreshold {
                state = .onRoute
                suspectStartedAt = nil
                recoveryStartedAt = nil
                return OffRouteDecision(
                    state: .onRoute,
                    becameConfirmed: false,
                    recovered: true,
                    reason: .recoveredToRoute,
                    lateralDistanceMeters: effectivePhysicalDistance,
                    activeThresholdMeters: recoveryThreshold
                )
            }

            let suspectStartTime = suspectStartedAt ?? observation.timestamp
            let elapsedSuspect = max(0.0, observation.timestamp.timeIntervalSince(suspectStartTime))

            // Determine required dwell time and reason
            let (requiredDwell, reason) = determineDwellAndReason(observation: observation, effectiveDistance: effectivePhysicalDistance)

            if elapsedSuspect >= requiredDwell {
                state = .confirmed
                return OffRouteDecision(
                    state: .confirmed,
                    becameConfirmed: true,
                    recovered: false,
                    reason: reason,
                    lateralDistanceMeters: effectivePhysicalDistance,
                    activeThresholdMeters: enterThreshold
                )
            } else {
                return OffRouteDecision(
                    state: .suspected,
                    becameConfirmed: false,
                    recovered: false,
                    reason: reason,
                    lateralDistanceMeters: effectivePhysicalDistance,
                    activeThresholdMeters: enterThreshold
                )
            }

        case .confirmed:
            // While confirmed, evaluate recovery with hysteresis and dwell
            if effectivePhysicalDistance <= recoveryThreshold {
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
                        lateralDistanceMeters: effectivePhysicalDistance,
                        activeThresholdMeters: recoveryThreshold
                    )
                } else {
                    return OffRouteDecision(
                        state: .confirmed,
                        becameConfirmed: false,
                        recovered: false,
                        reason: .none,
                        lateralDistanceMeters: effectivePhysicalDistance,
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
                    lateralDistanceMeters: effectivePhysicalDistance,
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

    private func determineDwellAndReason(
        observation: OffRouteObservation,
        effectiveDistance: Double
    ) -> (Double, OffRouteReason) {
        // 1. Strong deviation fast track
        if effectiveDistance >= config.strongDeviationThresholdMeters &&
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

        // 3. Stuck matcher while moving fast enough
        if observation.speedMetersPerSecond >= config.minSpeedForCourseMetersPerSecond && observation.isMatcherStuck {
            return (config.courseDivergenceDwellSeconds, .stuckMatcherDeviation)
        }

        // 4. Normal vehicle motion
        if observation.speedMetersPerSecond >= config.minSpeedForCourseMetersPerSecond {
            return (config.standardDwellSeconds, .sustainedLateralDeviation)
        }

        // 5. Low speed / stationary motion
        return (config.stationaryDwellSeconds, .lowSpeedDriftDwell)
    }

    private func angularDifferenceDegrees(_ a: Double, _ b: Double) -> Double {
        let diff = abs(a - b).truncatingRemainder(dividingBy: 360.0)
        return diff > 180.0 ? 360.0 - diff : diff
    }
}
