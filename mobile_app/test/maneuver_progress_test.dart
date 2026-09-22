import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile_app/models/route_model.dart';
import 'package:mobile_app/services/ble_service.dart';
import 'package:mobile_app/services/navigation_manager.dart';
import 'package:mobile_app/services/route_geometry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Maneuver Progression Tests (P5.5 Sections 45 - 48, 61)', () {
    late NavigationManager navManager;
    late BleService bleService;

    // 4 segments of ~100m each (~400m total)
    // Coords: p0 (0m), p1 (100m), p2 (200m), p3 (300m), p4 (400m)
    // 0.00108 deg lon at lat 21 is ~112m
    const p0 = LatLng(21.000, 105.8000);
    const p1 = LatLng(21.000, 105.8010);
    const p2 = LatLng(21.000, 105.8020);
    const p3 = LatLng(21.000, 105.8030);
    const p4 = LatLng(21.000, 105.8040);
    final polyline = [p0, p1, p2, p3, p4];

    late NavRoute route;
    late RouteGeometry geom;

    setUp(() {
      bleService = BleService();
      navManager = NavigationManager(bleService: bleService);
      geom = RouteGeometry(polyline);

      route = NavRoute(
        totalDistanceMeters: geom.totalDistanceMeters,
        totalDurationSeconds: 240.0,
        polylinePoints: polyline,
        steps: [
          NavStep(
            stepIndex: 0,
            instruction: 'Xuất phát trên Đường Phố Huế',
            streetName: 'Đường Phố Huế',
            distanceMeters: geom.cumulativeDistances[1],
            durationSeconds: 60.0,
            coordinate: p0,
            maneuverTypeStr: 'depart',
            beginShapeIndex: 0,
            endShapeIndex: 1,
          ),
          NavStep(
            stepIndex: 1,
            instruction: 'Rẽ phải vào Trần Khát Chân',
            streetName: 'Trần Khát Chân',
            distanceMeters: geom.cumulativeDistances[2] - geom.cumulativeDistances[1],
            durationSeconds: 60.0,
            coordinate: p1,
            maneuverTypeStr: 'turn right',
            beginShapeIndex: 1,
            endShapeIndex: 2,
          ),
          NavStep(
            stepIndex: 2,
            instruction: 'Rẽ trái vào Bạch Mai',
            streetName: 'Bạch Mai',
            distanceMeters: geom.cumulativeDistances[3] - geom.cumulativeDistances[2],
            durationSeconds: 60.0,
            coordinate: p2,
            maneuverTypeStr: 'turn left',
            beginShapeIndex: 2,
            endShapeIndex: 3,
          ),
          NavStep(
            stepIndex: 3,
            instruction: 'Đến nơi: Điểm đến bên phải',
            streetName: 'Đại Cồ Việt',
            distanceMeters: geom.totalDistanceMeters - geom.cumulativeDistances[3],
            durationSeconds: 60.0,
            coordinate: p4,
            maneuverTypeStr: 'arrive',
            beginShapeIndex: 3,
            endShapeIndex: 4,
          ),
        ],
        summary: 'Tuyến đường nhiều ngã rẽ',
      );
    });

    tearDown(() {
      navManager.dispose();
    });

    test('Section 45 & 47: Maneuver boundaries advance with along-route display progress', () {
      navManager.startNavigation(route);

      expect(navManager.currentStepIndex, equals(0));
      expect(navManager.currentStep?.streetName, equals('Đường Phố Huế'));

      final step1Begin = navManager.activeRouteGeometry!.maneuverBeginDistancesAlongRoute[1];
      expect(navManager.distanceToNextManeuver, closeTo(step1Begin, 1.0));

      // Advance halfway through Step 0
      final midCoord = geom.coordinateAtDistance(step1Begin * 0.5)!;
      navManager.updatePositionForTesting(
        midCoord,
        speedKmh: 30.0,
        heading: 90.0,
        horizontalAccuracy: 4.0,
      );

      expect(navManager.currentStepIndex, equals(0));
      expect(navManager.distanceToNextManeuver, closeTo(step1Begin * 0.5, 1.5));

      // Advance past step 1 begin boundary
      final pastStep1Coord = geom.coordinateAtDistance(step1Begin + 5.0)!;
      navManager.updatePositionForTesting(
        pastStep1Coord,
        speedKmh: 30.0,
        heading: 90.0,
        horizontalAccuracy: 4.0,
      );

      // Current step should advance to Step 1
      expect(navManager.currentStepIndex, equals(1));
      expect(navManager.currentStep?.streetName, equals('Trần Khát Chân'));
      final step2Begin = navManager.activeRouteGeometry!.maneuverBeginDistancesAlongRoute[2];
      expect(navManager.distanceToNextManeuver, closeTo(step2Begin - (step1Begin + 5.0), 1.5));
    });

    test('Section 48 & 61: GPS jump over intersection advances step correctly', () {
      navManager.startNavigation(route);

      final step1Begin = navManager.activeRouteGeometry!.maneuverBeginDistancesAlongRoute[1];

      // Sample 1: 20m before turn
      final beforeTurn = geom.coordinateAtDistance(step1Begin - 20.0)!;
      navManager.updatePositionForTesting(
        beforeTurn,
        speedKmh: 35.0,
        heading: 90.0,
        horizontalAccuracy: 4.0,
      );
      expect(navManager.currentStepIndex, equals(0));
      expect(navManager.distanceToNextManeuver, closeTo(20.0, 1.5));

      // Sample 2: GPS jumps 25m after turn (skipping the exact 25m radius of p1!)
      final afterTurn = geom.coordinateAtDistance(step1Begin + 25.0)!;
      navManager.updatePositionForTesting(
        afterTurn,
        speedKmh: 35.0,
        heading: 90.0,
        horizontalAccuracy: 4.0,
      );

      // Must advance to Step 1 without getting stuck on Step 0!
      expect(navManager.currentStepIndex, equals(1));
      expect(navManager.currentStep?.streetName, equals('Trần Khát Chân'));
    });

    test('GPS jump over multiple steps advances through while loop', () {
      navManager.startNavigation(route);

      final step3Begin = navManager.activeRouteGeometry!.maneuverBeginDistancesAlongRoute[3];

      // Jump directly from start to step 3
      final atStep3 = geom.coordinateAtDistance(step3Begin + 10.0)!;
      navManager.updatePositionForTesting(
        atStep3,
        speedKmh: 40.0,
        heading: 90.0,
        horizontalAccuracy: 4.0,
      );

      // While loop in NavigationManager advances index directly to Step 3
      expect(navManager.currentStepIndex, equals(3));
      expect(navManager.currentStep?.maneuverTypeStr, equals('arrive'));
    });

    test('P5.6 Section 6: Authoritative maneuver synchronization between distance, banner instruction and turn icon', () {
      navManager.startNavigation(route);

      // At start (Step 0: Depart):
      // Upcoming maneuver must be Step 1 (Turn Right into Trần Khát Chân)
      expect(navManager.currentStepIndex, equals(0));
      expect(navManager.authoritativeCurrentManeuver?.stepIndex, equals(1));
      expect(navManager.authoritativeCurrentManeuver?.maneuverType, equals(ManeuverType.turnRight));
      expect(navManager.bannerTurnIcon, equals(Icons.turn_right_rounded));
      expect(navManager.bannerInstruction, contains('Trần Khát Chân'));

      // Move forward 50m (halfway to Step 1)
      final midPoint = geom.coordinateAtDistance(50.0)!;
      navManager.updatePositionForTesting(
        midPoint,
        speedKmh: 30.0,
        heading: 90.0,
        horizontalAccuracy: 4.0,
      );

      expect(navManager.currentStepIndex, equals(0));
      expect(navManager.authoritativeCurrentManeuver?.stepIndex, equals(1));
      expect(navManager.bannerTurnIcon, equals(Icons.turn_right_rounded));
      expect(navManager.distanceToNextManeuver, closeTo(geom.cumulativeDistances[1] - 50.0, 1.0));

      // Advance past Step 1 turn into Step 2 (e.g. 85m then 125m)
      final step1Begin = navManager.activeRouteGeometry!.maneuverBeginDistancesAlongRoute[1];
      final nearStep1 = geom.coordinateAtDistance(step1Begin - 15.0)!;
      navManager.updatePositionForTesting(
        nearStep1,
        speedKmh: 30.0,
        heading: 90.0,
        horizontalAccuracy: 4.0,
      );

      final pastStep1 = geom.coordinateAtDistance(step1Begin + 20.0)!;
      navManager.updatePositionForTesting(
        pastStep1,
        speedKmh: 30.0,
        heading: 90.0,
        horizontalAccuracy: 4.0,
      );

      // Now index is 1, upcoming maneuver is Step 2
      expect(navManager.currentStepIndex, equals(1));
      expect(navManager.authoritativeCurrentManeuver?.stepIndex, equals(2));
      expect(navManager.bannerInstruction, contains(route.steps[2].streetName));
      expect(navManager.bannerTurnIcon, equals(route.steps[2].icon));
    });

    test('P5.6 Section 5: Real-time route trimming monotonically strips passed coordinates', () {
      navManager.startNavigation(route);
      final initialLength = navManager.remainingPolyline.length;

      // Advance by 120m (past first vertex p1 at ~112m)
      final at120m = geom.coordinateAtDistance(120.0)!;
      navManager.updatePositionForTesting(
        at120m,
        speedKmh: 30.0,
        heading: 90.0,
        horizontalAccuracy: 4.0,
      );

      final trimmed = navManager.remainingPolyline;
      expect(trimmed.first.latitude, closeTo(at120m.latitude, 0.0001));
      expect(trimmed.first.longitude, closeTo(at120m.longitude, 0.0001));
      expect(trimmed.length, lessThan(initialLength));
    });
  });
}
