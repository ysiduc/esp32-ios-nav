import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/services/off_route_detector.dart';

void main() {
  group('OffRouteDetector Deterministic Tests (P5.5 Sections 19 - 31)', () {
    late OffRouteDetector detector;
    final baseTime = DateTime(2026, 9, 22, 10, 0, 0);

    setUp(() {
      detector = OffRouteDetector();
    });

    test('Normal on-route driving stays in onRoute state', () {
      final t0 = baseTime;
      final obs = OffRouteObservation(
        timestamp: t0,
        rawPhysicalRouteDistanceMeters: 4.0,
        matchedProjectionLateralDistanceMeters: 2.0,
        horizontalAccuracyMeters: 5.0,
        speedMetersPerSecond: 10.0,
        courseDegrees: 90.0,
        routeBearingDegrees: 90.0,
      );

      final decision = detector.evaluate(obs);
      expect(decision.state, equals(OffRouteState.onRoute));
      expect(decision.becameConfirmed, isFalse);
      expect(decision.reason, equals(OffRouteReason.none));
    });

    test('Signal D: Strong deviation fast track confirms in ~1.0 synthetic second', () {
      final t0 = baseTime;
      // Strong deviation: 45m away with 5m GPS accuracy
      final obs0 = OffRouteObservation(
        timestamp: t0,
        rawPhysicalRouteDistanceMeters: 45.0,
        horizontalAccuracyMeters: 5.0,
        speedMetersPerSecond: 10.0,
        courseDegrees: 90.0,
        routeBearingDegrees: 90.0,
      );

      final dec0 = detector.evaluate(obs0);
      expect(dec0.state, equals(OffRouteState.suspected));
      expect(dec0.becameConfirmed, isFalse);
      expect(dec0.reason, equals(OffRouteReason.strongLateralDeviation));

      // After 0.5s: still suspected
      final t1 = t0.add(const Duration(milliseconds: 500));
      final dec1 = detector.evaluate(OffRouteObservation(
        timestamp: t1,
        rawPhysicalRouteDistanceMeters: 46.0,
        horizontalAccuracyMeters: 5.0,
        speedMetersPerSecond: 10.0,
      ));
      expect(dec1.state, equals(OffRouteState.suspected));
      expect(dec1.becameConfirmed, isFalse);

      // At 1.0s: confirmed!
      final t2 = t0.add(const Duration(milliseconds: 1000));
      final dec2 = detector.evaluate(OffRouteObservation(
        timestamp: t2,
        rawPhysicalRouteDistanceMeters: 48.0,
        horizontalAccuracyMeters: 5.0,
        speedMetersPerSecond: 10.0,
      ));
      expect(dec2.state, equals(OffRouteState.confirmed));
      expect(dec2.becameConfirmed, isTrue);
      expect(dec2.reason, equals(OffRouteReason.strongLateralDeviation));
    });

    test('Signal B: Course divergence (90° wrong turn) confirms in ~1.0 synthetic second', () {
      final t0 = baseTime;
      // Moving 10 m/s with 90° heading divergence and 12m lateral separation
      final obs0 = OffRouteObservation(
        timestamp: t0,
        rawPhysicalRouteDistanceMeters: 12.0,
        horizontalAccuracyMeters: 4.0,
        speedMetersPerSecond: 10.0,
        courseDegrees: 180.0, // Turning south
        routeBearingDegrees: 90.0, // Route goes east (90° diff)
      );

      final dec0 = detector.evaluate(obs0);
      expect(dec0.state, equals(OffRouteState.suspected));
      expect(dec0.reason, equals(OffRouteReason.courseDivergence));

      // At 1.0s: confirmed due to course divergence dwell
      final t1 = t0.add(const Duration(milliseconds: 1000));
      final dec1 = detector.evaluate(OffRouteObservation(
        timestamp: t1,
        rawPhysicalRouteDistanceMeters: 18.0,
        horizontalAccuracyMeters: 4.0,
        speedMetersPerSecond: 10.0,
        courseDegrees: 180.0,
        routeBearingDegrees: 90.0,
      ));
      expect(dec1.state, equals(OffRouteState.confirmed));
      expect(dec1.becameConfirmed, isTrue);
      expect(dec1.reason, equals(OffRouteReason.courseDivergence));
    });

    test('Signal E: Parallel wrong road (12m apart, same heading, good GPS) confirms in ~2.0s', () {
      final t0 = baseTime;
      // Parallel road: lateral distance 12m, accuracy 4m, speed 8 m/s, same heading
      final obs0 = OffRouteObservation(
        timestamp: t0,
        rawPhysicalRouteDistanceMeters: 12.0,
        horizontalAccuracyMeters: 4.0,
        speedMetersPerSecond: 8.0,
        courseDegrees: 90.0,
        routeBearingDegrees: 90.0,
      );

      final dec0 = detector.evaluate(obs0);
      expect(dec0.state, equals(OffRouteState.suspected));
      expect(dec0.reason, equals(OffRouteReason.persistentModerateLateralDeviation));

      // After 1.0s: still suspected (needs 2.0s moderate dwell)
      final t1 = t0.add(const Duration(seconds: 1));
      final dec1 = detector.evaluate(OffRouteObservation(
        timestamp: t1,
        rawPhysicalRouteDistanceMeters: 12.5,
        horizontalAccuracyMeters: 4.0,
        speedMetersPerSecond: 8.0,
        courseDegrees: 90.0,
        routeBearingDegrees: 90.0,
      ));
      expect(dec1.state, equals(OffRouteState.suspected));

      // At 2.0s: confirmed!
      final t2 = t0.add(const Duration(milliseconds: 2000));
      final dec2 = detector.evaluate(OffRouteObservation(
        timestamp: t2,
        rawPhysicalRouteDistanceMeters: 13.0,
        horizontalAccuracyMeters: 4.0,
        speedMetersPerSecond: 8.0,
        courseDegrees: 90.0,
        routeBearingDegrees: 90.0,
      ));
      expect(dec2.state, equals(OffRouteState.confirmed));
      expect(dec2.becameConfirmed, isTrue);
      expect(dec2.reason, equals(OffRouteReason.persistentModerateLateralDeviation));
    });

    test('Poor GPS accuracy prevents false reroute on 12m parallel road', () {
      final t0 = baseTime;
      // Accuracy is 15m; moderate threshold = max(10, 15 * 1.5) = 22.5m
      // 12m physical separation does NOT trigger suspicion under noisy GPS
      final obs0 = OffRouteObservation(
        timestamp: t0,
        rawPhysicalRouteDistanceMeters: 12.0,
        horizontalAccuracyMeters: 15.0,
        speedMetersPerSecond: 8.0,
        courseDegrees: 90.0,
        routeBearingDegrees: 90.0,
      );

      final dec0 = detector.evaluate(obs0);
      expect(dec0.state, equals(OffRouteState.onRoute));
      expect(dec0.becameConfirmed, isFalse);
    });

    test('Stationary vehicle protects against traffic-light GPS drift (5.0s dwell)', () {
      final t0 = baseTime;
      // Stopped at traffic light (speed 0.5 m/s), temporary drift to 18m
      final obs0 = OffRouteObservation(
        timestamp: t0,
        rawPhysicalRouteDistanceMeters: 18.0,
        horizontalAccuracyMeters: 5.0,
        speedMetersPerSecond: 0.5,
      );

      final dec0 = detector.evaluate(obs0);
      expect(dec0.state, equals(OffRouteState.suspected));

      // After 3 seconds of drift: still suspected, does NOT confirm yet
      final t1 = t0.add(const Duration(seconds: 3));
      final dec1 = detector.evaluate(OffRouteObservation(
        timestamp: t1,
        rawPhysicalRouteDistanceMeters: 19.0,
        horizontalAccuracyMeters: 5.0,
        speedMetersPerSecond: 0.5,
      ));
      expect(dec1.state, equals(OffRouteState.suspected));
      expect(dec1.becameConfirmed, isFalse);

      // Vehicle drifts back onto route: immediately recovers
      final t2 = t0.add(const Duration(seconds: 4));
      final dec2 = detector.evaluate(OffRouteObservation(
        timestamp: t2,
        rawPhysicalRouteDistanceMeters: 4.0, // <= 10m recovery threshold
        horizontalAccuracyMeters: 5.0,
        speedMetersPerSecond: 0.5,
      ));
      expect(dec2.state, equals(OffRouteState.onRoute));
      expect(dec2.recovered, isTrue);
    });

    test('Planned sharp turn does not false-reroute when vehicle returns to route', () {
      final t0 = baseTime;
      // Corner cutting / wide turn causing temporary 16m deviation
      detector.evaluate(OffRouteObservation(
        timestamp: t0,
        rawPhysicalRouteDistanceMeters: 16.0,
        horizontalAccuracyMeters: 5.0,
        speedMetersPerSecond: 6.0,
      ));
      expect(detector.state, equals(OffRouteState.suspected));

      // Completes turn within 0.8s, distance drops to 3m
      final t1 = t0.add(const Duration(milliseconds: 800));
      final dec1 = detector.evaluate(OffRouteObservation(
        timestamp: t1,
        rawPhysicalRouteDistanceMeters: 3.0,
        horizontalAccuracyMeters: 5.0,
        speedMetersPerSecond: 6.0,
      ));
      expect(dec1.state, equals(OffRouteState.onRoute));
      expect(dec1.recovered, isTrue);
    });

    test('P5.6 Section 3: Wrong-way movement triggers suspicion inside corridor and confirms in 0.8s', () {
      final t0 = baseTime;
      // Route heads East (90 deg), vehicle drives West (270 deg) -> angle diff = 180 deg
      // Vehicle is only 4.0m from centerline (inside normal corridor)
      final dec0 = detector.evaluate(OffRouteObservation(
        timestamp: t0,
        rawPhysicalRouteDistanceMeters: 4.0,
        horizontalAccuracyMeters: 4.0,
        speedMetersPerSecond: 8.0,
        courseDegrees: 270.0,
        routeBearingDegrees: 90.0,
      ));
      expect(dec0.state, equals(OffRouteState.suspected));
      expect(dec0.reason, equals(OffRouteReason.wrongWayDivergence));

      // After 0.9s (> 0.8s wrongWayDwellSeconds), confirmed off route
      final t1 = t0.add(const Duration(milliseconds: 900));
      final dec1 = detector.evaluate(OffRouteObservation(
        timestamp: t1,
        rawPhysicalRouteDistanceMeters: 4.5,
        horizontalAccuracyMeters: 4.0,
        speedMetersPerSecond: 8.0,
        courseDegrees: 270.0,
        routeBearingDegrees: 90.0,
      ));
      expect(dec1.state, equals(OffRouteState.confirmed));
      expect(dec1.becameConfirmed, isTrue);
      expect(dec1.reason, equals(OffRouteReason.wrongWayDivergence));
    });

    test('P5.6 Section 3: Active wrong-way travel prohibits false recovery to onRoute near centerline', () {
      final t0 = baseTime;
      detector.evaluate(OffRouteObservation(
        timestamp: t0,
        rawPhysicalRouteDistanceMeters: 4.0,
        horizontalAccuracyMeters: 4.0,
        speedMetersPerSecond: 8.0,
        courseDegrees: 270.0,
        routeBearingDegrees: 90.0,
      ));
      expect(detector.state, equals(OffRouteState.suspected));

      // Crosses road centerline (distance 1.5m <= 10m recovery threshold), but still driving wrong-way
      final t1 = t0.add(const Duration(milliseconds: 400));
      final dec1 = detector.evaluate(OffRouteObservation(
        timestamp: t1,
        rawPhysicalRouteDistanceMeters: 1.5,
        horizontalAccuracyMeters: 4.0,
        speedMetersPerSecond: 8.0,
        courseDegrees: 270.0,
        routeBearingDegrees: 90.0,
      ));
      expect(dec1.state, equals(OffRouteState.suspected), reason: 'Must NOT recover while driving in opposite direction');

      // Reaches dwell time -> confirms
      final t2 = t0.add(const Duration(milliseconds: 900));
      final dec2 = detector.evaluate(OffRouteObservation(
        timestamp: t2,
        rawPhysicalRouteDistanceMeters: 2.0,
        horizontalAccuracyMeters: 4.0,
        speedMetersPerSecond: 8.0,
        courseDegrees: 270.0,
        routeBearingDegrees: 90.0,
      ));
      expect(dec2.state, equals(OffRouteState.confirmed));
    });
  });
}
