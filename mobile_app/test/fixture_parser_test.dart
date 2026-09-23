import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile_app/models/route_model.dart';
import 'package:mobile_app/services/mapbox_directions_service.dart';
import 'package:mobile_app/services/osrm_service.dart';
import 'package:mobile_app/services/valhalla_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final hanoiStart = const LatLng(21.0285, 105.8542); // Hoan Kiem Lake
  final hanoiDest = const LatLng(21.0478, 105.8368);  // West Lake (Tran Quoc)

  group('P5.9.2 Real Provider Fixture Parser Tests', () {
    test('OSRM Hanoi Route Fixture parsing produces valid production route geometry and steps', () {
      final file = File('test/fixtures/osrm_hanoi_route_fixture.json');
      expect(file.existsSync(), isTrue, reason: 'OSRM fixture file must exist');

      final jsonContent = file.readAsStringSync();
      final data = jsonDecode(jsonContent) as Map<String, dynamic>;

      final routes = OsrmService.parseOsrmResponse(data, hanoiStart, hanoiDest, 'bike');

      expect(routes, isNotEmpty);
      expect(routes.length, greaterThanOrEqualTo(1));

      final primary = routes.first;
      expect(primary.totalDistanceMeters, greaterThan(2000));
      expect(primary.totalDistanceMeters, lessThan(8000));
      expect(primary.totalDurationSeconds, greaterThan(60));
      expect(primary.polylinePoints.length, greaterThan(10));
      expect(primary.steps, isNotEmpty);
      expect(primary.isFallbackSynthetic, isFalse);
      expect(primary.provider, equals('osrm'));

      // Verify coordinate plausibility (within Hanoi bounding box)
      for (final pt in primary.polylinePoints) {
        expect(pt.latitude, inInclusiveRange(20.9, 21.2));
        expect(pt.longitude, inInclusiveRange(105.7, 106.0));
      }

      // Verify steps contain directions
      final stepInstructions = primary.steps.map((s) => s.instruction).toList();
      expect(stepInstructions, isNotEmpty);
      expect(primary.steps.first.maneuverTypeStr, equals('depart'));
      expect(primary.steps.last.maneuverTypeStr, equals('arrive'));
    });

    test('Valhalla Hanoi Route Fixture parsing produces valid Polyline6 geometry and maneuvers', () {
      final file = File('test/fixtures/valhalla_hanoi_route_fixture.json');
      expect(file.existsSync(), isTrue, reason: 'Valhalla fixture file must exist');

      final jsonContent = file.readAsStringSync();
      final data = jsonDecode(jsonContent) as Map<String, dynamic>;

      final route = ValhallaService.parseValhallaResponse(data, hanoiStart, hanoiDest);
      expect(route, isNotNull);

      final r = route!;
      expect(r.totalDistanceMeters, greaterThan(2000));
      expect(r.totalDistanceMeters, lessThan(8000));
      expect(r.totalDurationSeconds, greaterThan(60));
      expect(r.polylinePoints.length, greaterThan(10));
      expect(r.steps, isNotEmpty);
      expect(r.isFallbackSynthetic, isFalse);
      expect(r.provider, equals('valhalla'));

      // Check polyline coordinates
      for (final pt in r.polylinePoints) {
        expect(pt.latitude, inInclusiveRange(20.9, 21.2));
        expect(pt.longitude, inInclusiveRange(105.7, 106.0));
      }

      // Check Vietnamese instructions
      expect(r.steps.first.instruction, isNotEmpty);
      expect(r.steps.any((s) => s.instruction.contains('phía') || s.instruction.contains('đường') || s.instruction.contains('rẽ') || s.instruction.contains('Tiếp tục')), isTrue);
    });

    test('Routable point snapping: Destination > 300m away from road is flagged unroutable', () async {
      final service = MapboxDirectionsService(
        valhallaProvider: (start, dest, {required costing}) async => null,
        osrmProvider: (start, dest, {required mode}) async => [],
      );

      // Distant unroutable point (deep into ocean/desert)
      final farPoint = const LatLng(21.055, 105.820);
      final result = await service.calculateRoutesDetailed(
        hanoiStart,
        farPoint,
        mode: 'bike',
        allowSnapRecovery: false,
      );

      expect(result.isSuccess, isFalse);
      expect(result.failure, equals(RouteFailureReason.noRoute));
    });

    test('Routable point snapping: Destination within 300m snaps to nearest road and retries', () async {
      int queryCount = 0;
      LatLng? queriedDest;
      final snappedTarget = const LatLng(21.054824, 105.820152);

      final service = MapboxDirectionsService(
        valhallaProvider: (start, dest, {required costing}) async {
          queryCount++;
          queriedDest = dest;
          // First attempt at unroutable centroid fails; second attempt with snapped coordinate succeeds!
          if (queryCount > 1) {
            return NavRoute(
              title: 'Lộ trình sau snap',
              subtitle: 'Đã nối đường',
              summary: 'Đã nối đường thành công',
              totalDistanceMeters: 3500,
              totalDurationSeconds: 400,
              steps: [
                NavStep(
                  stepIndex: 0,
                  instruction: 'Bắt đầu',
                  streetName: 'Đường phố',
                  distanceMeters: 3500,
                  durationSeconds: 400,
                  coordinate: start,
                  maneuverTypeStr: 'depart',
                ),
              ],
              polylinePoints: [start, dest],
              provider: 'valhalla',
              isFallbackSynthetic: false,
            );
          }
          return null;
        },
        osrmProvider: (start, dest, {required mode}) async => [],
        nearestSnapProvider: (point, {maxRadiusMeters = 300.0}) async {
          return OsrmSnapResult(
            original: point,
            snapped: snappedTarget,
            distanceMeters: 25.1,
            streetName: 'Ngõ 59 Phố Quảng Khánh',
            success: true,
          );
        },
      );

      // Coordinate in West Lake that OSRM snaps ~25m to Ngõ 59 Phố Quảng Khánh
      final lakePoint = const LatLng(21.055, 105.820);
      final result = await service.calculateRoutesDetailed(
        hanoiStart,
        lakePoint,
        mode: 'bike',
        allowSnapRecovery: true,
        maxSnapMeters: 100.0,
      );

      expect(result.isSuccess, isTrue);
      expect(result.snapDistanceMeters, isNotNull);
      expect(result.snapDistanceMeters!, lessThanOrEqualTo(100.0));
      expect(queriedDest, isNot(equals(lakePoint)));
    });
  });
}
