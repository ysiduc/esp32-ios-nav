import 'dart:math' as math;

/// Observation from location pipeline and route projection.
class OffRouteObservation {
  final DateTime timestamp;
  final double matchedProjectionLateralDistanceMeters;
  final double rawPhysicalRouteDistanceMeters;
  final double horizontalAccuracyMeters;
  final double speedMetersPerSecond;
  final double? courseDegrees;
  final double? routeBearingDegrees;
  final double distanceAlongRouteMeters;
  final double physicalTravelMeters;
  final double matchedAdvanceMeters;
  final bool isMatcherStuck;

  double get lateralDistanceMeters => matchedProjectionLateralDistanceMeters;
  double get rawNearestRouteDistanceMeters => rawPhysicalRouteDistanceMeters;

  const OffRouteObservation({
    required this.timestamp,
    this.matchedProjectionLateralDistanceMeters = 0.0,
    this.rawPhysicalRouteDistanceMeters = 0.0,
    required this.horizontalAccuracyMeters,
    required this.speedMetersPerSecond,
    this.courseDegrees,
    this.routeBearingDegrees,
    this.distanceAlongRouteMeters = 0.0,
    this.physicalTravelMeters = 0.0,
    this.matchedAdvanceMeters = 0.0,
    this.isMatcherStuck = false,
  });
}

enum OffRouteState {
  onRoute,
  suspected,
  confirmed,
}

enum OffRouteReason {
  none,
  sustainedLateralDeviation,
  courseDivergence,
  wrongWayDivergence,
  strongLateralDeviation,
  lowSpeedDriftDwell,
  stuckMatcherDeviation,
  persistentModerateLateralDeviation,
  recoveredToRoute,
}

class OffRouteDecision {
  final OffRouteState state;
  final bool becameConfirmed;
  final bool recovered;
  final OffRouteReason reason;
  final double lateralDistanceMeters;
  final double activeThresholdMeters;

  const OffRouteDecision({
    required this.state,
    required this.becameConfirmed,
    required this.recovered,
    required this.reason,
    required this.lateralDistanceMeters,
    required this.activeThresholdMeters,
  });

  @override
  String toString() =>
      'OffRouteDecision(state: $state, becameConfirmed: $becameConfirmed, '
      'reason: $reason, lateral: ${lateralDistanceMeters.toStringAsFixed(1)}m, '
      'threshold: ${activeThresholdMeters.toStringAsFixed(1)}m)';
}

class OffRouteDetectorConfig {
  final double baseEnterThresholdMeters;
  final double accuracyMultiplier;
  final double recoveryThresholdMeters;
  final double standardDwellSeconds;
  final double courseDivergenceDwellSeconds;
  final double stationaryDwellSeconds;
  final double strongDeviationDwellSeconds;
  final double strongDeviationThresholdMeters;
  final double strongDeviationMaxAccuracyMeters;
  final double courseMismatchAngleDegrees;
  final double wrongWayMismatchAngleDegrees;
  final double wrongWayDwellSeconds;
  final double minSpeedForCourseMetersPerSecond;
  final double recoveryDwellSeconds;
  final double moderateDeviationDwellSeconds;

  const OffRouteDetectorConfig({
    this.baseEnterThresholdMeters = 15.0,
    this.accuracyMultiplier = 1.2,
    this.recoveryThresholdMeters = 10.0,
    this.standardDwellSeconds = 2.5,
    this.courseDivergenceDwellSeconds = 1.0,
    this.wrongWayDwellSeconds = 0.8,
    this.stationaryDwellSeconds = 5.0,
    this.strongDeviationDwellSeconds = 1.0,
    this.strongDeviationThresholdMeters = 40.0,
    this.strongDeviationMaxAccuracyMeters = 15.0,
    this.courseMismatchAngleDegrees = 45.0,
    this.wrongWayMismatchAngleDegrees = 120.0,
    this.minSpeedForCourseMetersPerSecond = 3.0,
    this.recoveryDwellSeconds = 1.0,
    this.moderateDeviationDwellSeconds = 2.0,
  });
}

/// Pure deterministic state machine for quality-aware, multi-signal off-route detection.
class OffRouteDetector {
  final OffRouteDetectorConfig config;

  OffRouteState _state = OffRouteState.onRoute;
  DateTime? _suspectStartedAt;
  DateTime? _recoveryStartedAt;
  DateTime? _lastObservationTimestamp;

  OffRouteState get state => _state;
  DateTime? get suspectStartedAt => _suspectStartedAt;
  DateTime? get recoveryStartedAt => _recoveryStartedAt;
  DateTime? get lastObservationTimestamp => _lastObservationTimestamp;

  OffRouteDetector({this.config = const OffRouteDetectorConfig()});

  void reset() {
    _state = OffRouteState.onRoute;
    _suspectStartedAt = null;
    _recoveryStartedAt = null;
    _lastObservationTimestamp = null;
  }

  OffRouteDecision evaluate(OffRouteObservation observation) {
    _lastObservationTimestamp = observation.timestamp;

    // Use pure physical route distance as physical evidence
    final physicalDistance = observation.rawPhysicalRouteDistanceMeters > 0.0
        ? observation.rawPhysicalRouteDistanceMeters
        : observation.matchedProjectionLateralDistanceMeters;

    final enterThreshold = math.max(
      config.baseEnterThresholdMeters,
      observation.horizontalAccuracyMeters * config.accuracyMultiplier,
    );

    final moderateThreshold = math.max(10.0, observation.horizontalAccuracyMeters * 1.5);
    final recoveryThreshold = config.recoveryThresholdMeters;

    final diffAngle = (observation.speedMetersPerSecond >= config.minSpeedForCourseMetersPerSecond &&
            observation.courseDegrees != null &&
            observation.courseDegrees! >= 0.0 &&
            observation.routeBearingDegrees != null)
        ? angularDifferenceDegrees(observation.courseDegrees!, observation.routeBearingDegrees!)
        : null;

    final isWrongWay = diffAngle != null &&
        diffAngle >= config.wrongWayMismatchAngleDegrees &&
        observation.horizontalAccuracyMeters <= 20.0;

    switch (_state) {
      case OffRouteState.onRoute:
        bool suspicionTriggered = false;
        OffRouteReason initialReason = OffRouteReason.none;

        // Signal W: Wrong-way movement fast track (P5.6 Section 3)
        // User moving opposite to route bearing escalates even inside corridor (>= 3m)
        if (isWrongWay && physicalDistance >= 3.0) {
          suspicionTriggered = true;
          initialReason = OffRouteReason.wrongWayDivergence;
        }

        // Signal D: Strong deviation fast track (checked first for accurate initialReason)
        if (!suspicionTriggered &&
            physicalDistance >= config.strongDeviationThresholdMeters &&
            observation.horizontalAccuracyMeters <= config.strongDeviationMaxAccuracyMeters) {
          suspicionTriggered = true;
          initialReason = OffRouteReason.strongLateralDeviation;
        }

        // Signal A: Physical lateral distance exceeds enter threshold
        if (!suspicionTriggered && physicalDistance >= enterThreshold) {
          suspicionTriggered = true;
          initialReason = OffRouteReason.sustainedLateralDeviation;
        }

        // Signal B: Course mismatch while moving fast enough
        if (!suspicionTriggered &&
            observation.speedMetersPerSecond >= config.minSpeedForCourseMetersPerSecond &&
            observation.courseDegrees != null &&
            observation.courseDegrees! >= 0.0 &&
            observation.routeBearingDegrees != null) {
          final diff = angularDifferenceDegrees(
            observation.courseDegrees!,
            observation.routeBearingDegrees!,
          );
          if (diff >= config.courseMismatchAngleDegrees && physicalDistance >= moderateThreshold) {
            suspicionTriggered = true;
            initialReason = OffRouteReason.courseDivergence;
          }
        }

        // Signal C: Stuck matcher while moving fast enough
        if (!suspicionTriggered &&
            observation.speedMetersPerSecond >= config.minSpeedForCourseMetersPerSecond &&
            observation.isMatcherStuck &&
            physicalDistance >= moderateThreshold) {
          suspicionTriggered = true;
          initialReason = OffRouteReason.stuckMatcherDeviation;
        }



        // Signal E: Persistent moderate deviation on parallel road below enter threshold
        if (!suspicionTriggered &&
            observation.speedMetersPerSecond >= config.minSpeedForCourseMetersPerSecond &&
            observation.horizontalAccuracyMeters <= 20.0 &&
            physicalDistance >= moderateThreshold &&
            physicalDistance <= enterThreshold) {
          suspicionTriggered = true;
          initialReason = OffRouteReason.persistentModerateLateralDeviation;
        }

        if (suspicionTriggered) {
          _state = OffRouteState.suspected;
          _suspectStartedAt = observation.timestamp;
          _recoveryStartedAt = null;
          return OffRouteDecision(
            state: OffRouteState.suspected,
            becameConfirmed: false,
            recovered: false,
            reason: initialReason,
            lateralDistanceMeters: physicalDistance,
            activeThresholdMeters: enterThreshold,
          );
        } else {
          return OffRouteDecision(
            state: OffRouteState.onRoute,
            becameConfirmed: false,
            recovered: false,
            reason: OffRouteReason.none,
            lateralDistanceMeters: physicalDistance,
            activeThresholdMeters: enterThreshold,
          );
        }

      case OffRouteState.suspected:
        // If physical distance returned below recovery threshold, abort suspicion immediately
        // (Only recover if not traveling in the wrong direction)
        if (physicalDistance <= recoveryThreshold && !isWrongWay) {
          _state = OffRouteState.onRoute;
          _suspectStartedAt = null;
          _recoveryStartedAt = null;
          return OffRouteDecision(
            state: OffRouteState.onRoute,
            becameConfirmed: false,
            recovered: true,
            reason: OffRouteReason.recoveredToRoute,
            lateralDistanceMeters: physicalDistance,
            activeThresholdMeters: recoveryThreshold,
          );
        }

        final startTime = _suspectStartedAt ?? observation.timestamp;
        final elapsedSeconds =
            math.max(0.0, observation.timestamp.difference(startTime).inMilliseconds / 1000.0);

        final dwellAndReason = _determineDwellAndReason(
          observation: observation,
          physicalDistance: physicalDistance,
          moderateThreshold: moderateThreshold,
          enterThreshold: enterThreshold,
        );

        final requiredDwell = dwellAndReason.$1;
        final reason = dwellAndReason.$2;

        if (elapsedSeconds >= requiredDwell) {
          _state = OffRouteState.confirmed;
          return OffRouteDecision(
            state: OffRouteState.confirmed,
            becameConfirmed: true,
            recovered: false,
            reason: reason,
            lateralDistanceMeters: physicalDistance,
            activeThresholdMeters: enterThreshold,
          );
        } else {
          return OffRouteDecision(
            state: OffRouteState.suspected,
            becameConfirmed: false,
            recovered: false,
            reason: reason,
            lateralDistanceMeters: physicalDistance,
            activeThresholdMeters: enterThreshold,
          );
        }

      case OffRouteState.confirmed:
        if (physicalDistance <= recoveryThreshold && !isWrongWay) {
          final recStart = _recoveryStartedAt ?? observation.timestamp;
          _recoveryStartedAt ??= observation.timestamp;
          final elapsedRecovery =
              math.max(0.0, observation.timestamp.difference(recStart).inMilliseconds / 1000.0);

          if (elapsedRecovery >= config.recoveryDwellSeconds) {
            _state = OffRouteState.onRoute;
            _suspectStartedAt = null;
            _recoveryStartedAt = null;
            return OffRouteDecision(
              state: OffRouteState.onRoute,
              becameConfirmed: false,
              recovered: true,
              reason: OffRouteReason.recoveredToRoute,
              lateralDistanceMeters: physicalDistance,
              activeThresholdMeters: recoveryThreshold,
            );
          } else {
            return OffRouteDecision(
              state: OffRouteState.confirmed,
              becameConfirmed: false,
              recovered: false,
              reason: OffRouteReason.none,
              lateralDistanceMeters: physicalDistance,
              activeThresholdMeters: recoveryThreshold,
            );
          }
        } else {
          _recoveryStartedAt = null;
          return OffRouteDecision(
            state: OffRouteState.confirmed,
            becameConfirmed: false,
            recovered: false,
            reason: OffRouteReason.sustainedLateralDeviation,
            lateralDistanceMeters: physicalDistance,
            activeThresholdMeters: enterThreshold,
          );
        }
    }
  }

  (double, OffRouteReason) _determineDwellAndReason({
    required OffRouteObservation observation,
    required double physicalDistance,
    required double moderateThreshold,
    required double enterThreshold,
  }) {
    // 0. Wrong-way fast track (P5.6 Section 3: angle >= 120 deg while moving)
    if (observation.speedMetersPerSecond >= config.minSpeedForCourseMetersPerSecond &&
        observation.horizontalAccuracyMeters <= 20.0 &&
        observation.courseDegrees != null &&
        observation.courseDegrees! >= 0.0 &&
        observation.routeBearingDegrees != null) {
      final diff = angularDifferenceDegrees(
        observation.courseDegrees!,
        observation.routeBearingDegrees!,
      );
      if (diff >= config.wrongWayMismatchAngleDegrees) {
        return (config.wrongWayDwellSeconds, OffRouteReason.wrongWayDivergence);
      }
    }

    // 1. Strong deviation fast track
    if (physicalDistance >= config.strongDeviationThresholdMeters &&
        observation.horizontalAccuracyMeters <= config.strongDeviationMaxAccuracyMeters) {
      return (config.strongDeviationDwellSeconds, OffRouteReason.strongLateralDeviation);
    }

    // 2. Course divergence supporting evidence (moving fast enough)
    if (observation.speedMetersPerSecond >= config.minSpeedForCourseMetersPerSecond &&
        observation.courseDegrees != null &&
        observation.courseDegrees! >= 0.0 &&
        observation.routeBearingDegrees != null) {
      final diff = angularDifferenceDegrees(
        observation.courseDegrees!,
        observation.routeBearingDegrees!,
      );
      if (diff >= config.courseMismatchAngleDegrees) {
        return (config.courseDivergenceDwellSeconds, OffRouteReason.courseDivergence);
      }
    }

    // 3. Stuck matcher while moving fast enough
    if (observation.speedMetersPerSecond >= config.minSpeedForCourseMetersPerSecond &&
        observation.isMatcherStuck) {
      return (config.courseDivergenceDwellSeconds, OffRouteReason.stuckMatcherDeviation);
    }

    // 4. Moderate parallel deviation with good GPS below enter threshold
    if (observation.speedMetersPerSecond >= config.minSpeedForCourseMetersPerSecond &&
        observation.horizontalAccuracyMeters <= 20.0 &&
        physicalDistance >= moderateThreshold &&
        physicalDistance <= enterThreshold) {
      return (config.moderateDeviationDwellSeconds, OffRouteReason.persistentModerateLateralDeviation);
    }

    // 5. Normal vehicle motion
    if (observation.speedMetersPerSecond >= config.minSpeedForCourseMetersPerSecond) {
      return (config.standardDwellSeconds, OffRouteReason.sustainedLateralDeviation);
    }

    // 6. Low speed / stationary motion
    return (config.stationaryDwellSeconds, OffRouteReason.lowSpeedDriftDwell);
  }

  static double angularDifferenceDegrees(double a, double b) {
    final diff = (a - b).abs() % 360.0;
    return diff > 180.0 ? 360.0 - diff : diff;
  }
}
