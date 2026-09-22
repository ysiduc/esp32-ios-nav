import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile_app/models/route_model.dart';
import 'package:mobile_app/services/ble_service.dart';
import 'package:mobile_app/services/navigation_manager.dart';
import 'package:mobile_app/services/route_geometry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Navigation Progress & Line Trimming Tests (P5.5 Sections 8 - 14, 58, 59)', () {
    late NavigationManager navManager;
    late BleService bleService;

    // Create a straight East-West route: 5 vertices separated by ~25m each (~100m total)
    // 0.000225 deg longitude at lat 21.0 is ~23.3 meters
    final p0 = const LatLng(21.00000, 105.80000);
    final p1 = const LatLng(21.00000, 105.80025);
    final p2 = const LatLng(21.00000, 105.80050);
    final p3 = const LatLng(21.00000, 105.80075);
    final p4 = const LatLng(21.00000, 105.80100);
    final polyline = [p0, p1, p2, p3, p4];

    late NavRoute testRoute;
    late double totalMeters;

    setUp(() {
      bleService = BleService();
      navManager = NavigationManager(bleService: bleService);

      final geom = RouteGeometry(polyline);
      totalMeters = geom.totalDistanceMeters;

      testRoute = NavRoute(
        totalDistanceMeters: totalMeters,
        totalDurationSeconds: 60.0,
        polylinePoints: polyline,
        steps: [
          NavStep(
            stepIndex: 0,
            instruction: 'Đi thẳng trên Đường Thử Nghiệm',
            streetName: 'Đường Thử Nghiệm',
            distanceMeters: totalMeters,
            durationSeconds: 60.0,
            coordinate: p0,
            maneuverTypeStr: 'depart',
            beginShapeIndex: 0,
            endShapeIndex: 4,
          ),
        ],
        summary: 'Đường Thử Nghiệm',
      );
    });

    tearDown(() {
      navManager.dispose();
    });

    test('Section 58: Continuous line trimming test (0m -> 20m -> 40m -> 60m -> 80m)', () {
      navManager.startNavigation(testRoute);

      expect(navManager.isNavigating, isTrue);
      expect(navManager.displayProgressMeters, equals(0.0));
      expect(navManager.remainingPolyline.length, equals(5));

      final geom = navManager.activeRouteGeometry!;

      // Step through 20m, 40m, 60m, 80m
      final testDists = [20.0, 40.0, 60.0, 80.0];
      double prevProgress = 0.0;
      double prevRemainingDist = totalMeters;

      for (final targetD in testDists) {
        final coord = geom.coordinateAtDistance(targetD)!;
        navManager.updatePositionForTesting(
          coord,
          speedKmh: 30.0,
          heading: 90.0,
          horizontalAccuracy: 4.0,
        );

        // 1. Assert displayProgress is monotonic and advancing
        expect(navManager.displayProgressMeters, greaterThanOrEqualTo(prevProgress));
        expect(navManager.displayProgressMeters, closeTo(targetD, 1.5));
        prevProgress = navManager.displayProgressMeters;

        // 2. Assert remaining distance is decreasing monotonically
        expect(navManager.remainingTotalDistance, lessThan(prevRemainingDist));
        prevRemainingDist = navManager.remainingTotalDistance;

        // 3. Assert remainingPolyline first point matches current display progress
        final remaining = navManager.remainingPolyline;
        expect(remaining.isNotEmpty, isTrue);
        expect(remaining.first.latitude, closeTo(coord.latitude, 1e-4));
        expect(remaining.first.longitude, closeTo(coord.longitude, 1e-4));

        // 4. Assert already passed polyline vertices are absent from remainingPolyline
        for (int i = 0; i < polyline.length; i++) {
          if (geom.cumulativeDistances[i] < targetD - 2.0) {
            final passedVertex = polyline[i];
            expect(
              remaining.contains(passedVertex),
              isFalse,
              reason: 'Vertex $i at ${geom.cumulativeDistances[i]}m should be removed when progress is ${targetD}m',
            );
          }
        }
      }
    });

    test('Section 59: GPS noise test (progress 80m, temporary noisy sample at 55m)', () {
      navManager.startNavigation(testRoute);
      final geom = navManager.activeRouteGeometry!;

      // Advance to 80m
      final coord80 = geom.coordinateAtDistance(80.0)!;
      navManager.updatePositionForTesting(
        coord80,
        speedKmh: 30.0,
        heading: 90.0,
        horizontalAccuracy: 4.0,
      );

      final progressAt80 = navManager.displayProgressMeters;
      expect(progressAt80, closeTo(80.0, 1.5));
      final remainingDistAt80 = navManager.remainingTotalDistance;
      final remainingCountAt80 = navManager.remainingPolyline.length;

      // GPS noise: sample temporarily projects back around 55m
      final coord55 = geom.coordinateAtDistance(55.0)!;
      navManager.updatePositionForTesting(
        coord55,
        speedKmh: 30.0,
        heading: 90.0,
        horizontalAccuracy: 4.0,
      );

      // Invariant: displayProgressMeters must NEVER move backwards!
      expect(navManager.displayProgressMeters, greaterThanOrEqualTo(progressAt80));
      expect(navManager.displayProgressMeters, equals(progressAt80));

      // Blue line does NOT grow backward!
      expect(navManager.remainingTotalDistance, equals(remainingDistAt80));
      expect(navManager.remainingPolyline.length, lessThanOrEqualTo(remainingCountAt80));
      // First point remains at or ahead of 80m, not 55m
      expect(navManager.remainingPolyline.first.longitude, greaterThanOrEqualTo(coord80.longitude - 1e-5));
    });

    test('GPS accuracy gating: sample with accuracy > 20m is rejected from progress', () {
      navManager.startNavigation(testRoute);
      final geom = navManager.activeRouteGeometry!;

      // Normal sample at 30m
      final coord30 = geom.coordinateAtDistance(30.0)!;
      navManager.updatePositionForTesting(
        coord30,
        speedKmh: 30.0,
        heading: 90.0,
        horizontalAccuracy: 5.0,
      );
      expect(navManager.displayProgressMeters, closeTo(30.0, 1.5));

      // Bad accuracy sample claiming 70m but with 35m accuracy (> 20m threshold)
      final coord70 = geom.coordinateAtDistance(70.0)!;
      navManager.updatePositionForTesting(
        coord70,
        speedKmh: 30.0,
        heading: 90.0,
        horizontalAccuracy: 35.0, // Unreliable!
      );

      // Must NOT force route progress!
      expect(navManager.displayProgressMeters, closeTo(30.0, 1.5));
      expect(navManager.rawLocation, equals(coord70));
    });
    test('P5.5.1 Section 8: GPS jitter sequence (30 -> 28 -> 32 -> 29 -> 40)', () {
      navManager.startNavigation(testRoute);
      final geom = navManager.activeRouteGeometry!;

      final jitterTargets = [30.0, 28.0, 32.0, 29.0, 40.0];
      final expectedProgress = [30.0, 30.0, 32.0, 32.0, 40.0];

      DateTime baseTime = DateTime(2026, 9, 22, 12, 0, 0);

      for (int i = 0; i < jitterTargets.length; i++) {
        final targetD = jitterTargets[i];
        final coord = geom.coordinateAtDistance(targetD)!;
        baseTime = baseTime.add(const Duration(seconds: 1));

        navManager.updatePositionForTesting(
          coord,
          speedKmh: 30.0,
          heading: 90.0,
          horizontalAccuracy: 4.0,
          timestamp: baseTime,
        );

        expect(
          navManager.displayProgressMeters,
          closeTo(expectedProgress[i], 1.5),
          reason: 'At step $i target $targetD expected ${expectedProgress[i]}',
        );

        // First point of remainingPolyline must be at or ahead of expected progress
        final remaining = navManager.remainingPolyline;
        final expectedCoord = geom.coordinateAtDistance(expectedProgress[i])!;
        expect(remaining.first.longitude, greaterThanOrEqualTo(expectedCoord.longitude - 1e-5));
      }
    });

    test('P5.5.1 Section 4: Impossible forward jump rejection (300m jump in 1s rejected)', () {
      const pStart = LatLng(21.000, 105.800);
      const pEnd = LatLng(21.000, 105.810);
      final longGeom = RouteGeometry([pStart, pEnd]);
      final longRoute = NavRoute(
        totalDistanceMeters: longGeom.totalDistanceMeters,
        totalDurationSeconds: 120.0,
        polylinePoints: [pStart, pEnd],
        steps: [],
        summary: 'Long test road',
      );

      navManager.startNavigation(longRoute);
      final t0 = DateTime(2026, 9, 22, 12, 0, 0);

      // Normal progress at 50m
      final coord50 = longGeom.coordinateAtDistance(50.0)!;
      navManager.updatePositionForTesting(
        coord50,
        speedKmh: 30.0,
        heading: 90.0,
        horizontalAccuracy: 4.0,
        timestamp: t0,
      );
      expect(navManager.displayProgressMeters, closeTo(50.0, 1.5));

      // 1.0s later, noisy GPS reading snaps to 500m ahead
      final t1 = t0.add(const Duration(seconds: 1));
      final coord500 = longGeom.coordinateAtDistance(500.0)!;
      navManager.updatePositionForTesting(
        coord500,
        speedKmh: 30.0,
        heading: 90.0,
        horizontalAccuracy: 4.0,
        timestamp: t1,
      );

      // Must NOT allow 450m jump in 1 second at 30km/h!
      expect(navManager.displayProgressMeters, closeTo(50.0, 1.5));
    });
  });
}
