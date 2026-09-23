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

  // Field test coordinates (Dinh Cong / Dai Kim -> Tan Tien, Chuong My)
  final dinhCongStart = const LatLng(20.9785, 105.8340);
  final tanTienDest = const LatLng(20.8950, 105.6550);

  group('P5.9.3 Valhalla Absolute URI Regression & Diagnostics', () {
    test('Valhalla routeUri() returns absolute https URI with host and /route path', () {
      final uri = ValhallaService.routeUri();
      expect(uri.scheme, equals('https'));
      expect(uri.host, equals('valhalla1.openstreetmap.de'));
      expect(uri.path, equals('/route'));
      expect(uri.hasAbsolutePath, isTrue);
      expect(uri.toString(), equals('https://valhalla1.openstreetmap.de/route'));
    });

    test('Valhalla diagnostic catches no-host / relative URI error as invalidUri', () {
      final res = ProviderRouteResult.failure(
        provider: 'valhalla',
        latency: Duration.zero,
        errorType: 'invalidUri',
        safeMessage: 'Cấu hình URL Valhalla không hợp lệ',
      );
      expect(res.errorType, equals('invalidUri'));
      expect(res.success, isFalse);
    });
  });

  group('P5.9.2 & P5.9.3 Real Provider Fixture Parser Tests', () {
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

      for (final pt in primary.polylinePoints) {
        expect(pt.latitude, inInclusiveRange(20.9, 21.2));
        expect(pt.longitude, inInclusiveRange(105.7, 106.0));
      }

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

      for (final pt in r.polylinePoints) {
        expect(pt.latitude, inInclusiveRange(20.9, 21.2));
        expect(pt.longitude, inInclusiveRange(105.7, 106.0));
      }

      expect(r.steps.first.instruction, isNotEmpty);
      expect(r.steps.any((s) => s.instruction.contains('phía') || s.instruction.contains('đường') || s.instruction.contains('rẽ') || s.instruction.contains('Tiếp tục')), isTrue);
    });

    test('Field-like case: Dinh Cong to Tan Tien (Chuong My) Valhalla fixture parsing', () {
      final file = File('test/fixtures/valhalla_dinhcong_tantien_fixture.json');
      expect(file.existsSync(), isTrue);

      final jsonContent = file.readAsStringSync();
      final data = jsonDecode(jsonContent) as Map<String, dynamic>;

      final route = ValhallaService.parseValhallaResponse(data, dinhCongStart, tanTienDest);
      expect(route, isNotNull);

      final r = route!;
      // ~27.3km route from Dinh Cong to Tan Tien
      expect(r.totalDistanceMeters, greaterThan(25000));
      expect(r.totalDistanceMeters, lessThan(32000));
      expect(r.totalDurationSeconds, greaterThan(1500));
      expect(r.polylinePoints.length, greaterThan(100));
      expect(r.steps.length, greaterThan(15));
      expect(r.provider, equals('valhalla'));
      expect(r.isFallbackSynthetic, isFalse);
    });

    test('Field-like case: Dinh Cong to Tan Tien (Chuong My) OSRM fixture parsing', () {
      final file = File('test/fixtures/osrm_dinhcong_tantien_fixture.json');
      expect(file.existsSync(), isTrue);

      final jsonContent = file.readAsStringSync();
      final data = jsonDecode(jsonContent) as Map<String, dynamic>;

      final routes = OsrmService.parseOsrmResponse(data, dinhCongStart, tanTienDest, 'bike');
      expect(routes, isNotEmpty);

      final r = routes.first;
      // ~28.2km route
      expect(r.totalDistanceMeters, greaterThan(25000));
      expect(r.totalDistanceMeters, lessThan(32000));
      expect(r.totalDurationSeconds, greaterThan(1500));
      expect(r.polylinePoints.length, greaterThan(100));
      expect(r.steps.length, greaterThan(15));
      expect(r.provider, equals('osrm'));
    });
  });

  group('P5.9.3 Dual-Endpoint Routable Snap Recovery Tests', () {
    test('Destination > 300m away from road is flagged unroutable', () async {
      final service = MapboxDirectionsService(
        valhallaProvider: (start, dest, {required costing}) async => null,
        osrmProvider: (start, dest, {required mode}) async => [],
        nearestSnapProvider: (point, {maxRadiusMeters = 300.0}) async {
          if (point == hanoiStart) {
            return OsrmSnapResult(
              original: point,
              snapped: point,
              distanceMeters: 5.0,
              success: true,
            );
          }
          return OsrmSnapResult(
            original: point,
            snapped: point,
            distanceMeters: 450.0,
            success: false,
          );
        },
      );

      final farPoint = const LatLng(21.055, 105.820);
      final result = await service.calculateRoutesDetailed(
        hanoiStart,
        farPoint,
        mode: 'bike',
        allowSnapRecovery: true,
      );

      expect(result.isSuccess, isFalse);
      expect(result.failure, equals(RouteFailureReason.noRoute));
      expect(result.errorMessage, contains('Điểm đến nằm quá xa đường'));
    });

    test('Start position > 150m away from road is flagged unroutable with start error', () async {
      final service = MapboxDirectionsService(
        valhallaProvider: (start, dest, {required costing}) async => null,
        osrmProvider: (start, dest, {required mode}) async => [],
        nearestSnapProvider: (point, {maxRadiusMeters = 300.0}) async {
          if (point == hanoiStart) {
            return OsrmSnapResult(
              original: point,
              snapped: point,
              distanceMeters: 220.0,
              success: false,
            );
          }
          return OsrmSnapResult(
            original: point,
            snapped: point,
            distanceMeters: 10.0,
            success: true,
          );
        },
      );

      final result = await service.calculateRoutesDetailed(
        hanoiStart,
        hanoiDest,
        mode: 'bike',
        allowSnapRecovery: true,
      );

      expect(result.isSuccess, isFalse);
      expect(result.failure, equals(RouteFailureReason.noRoute));
      expect(result.errorMessage, contains('Vị trí bắt đầu nằm quá xa đường'));
    });

    test('Dual snap: Both start (35m) and destination (65m) off-road snap and route recovers', () async {
      int queryCount = 0;
      LatLng? queriedStart;
      LatLng? queriedDest;
      final snappedStartRoad = const LatLng(21.0286, 105.8545);
      final snappedDestRoad = const LatLng(21.0480, 105.8370);

      final service = MapboxDirectionsService(
        valhallaProvider: (start, dest, {required costing}) async {
          queryCount++;
          queriedStart = start;
          queriedDest = dest;
          // First attempt at unroutable centroids fails; retry with snapped endpoints succeeds
          if (queryCount > 1) {
            return NavRoute(
              title: 'Lộ trình sau dual-snap',
              subtitle: 'Đã nối đường cả 2 đầu',
              summary: 'Khôi phục thành công',
              totalDistanceMeters: 3800,
              totalDurationSeconds: 450,
              steps: [
                NavStep(
                  stepIndex: 0,
                  instruction: 'Bắt đầu từ đường đã snap',
                  streetName: 'Đường phố',
                  distanceMeters: 3800,
                  durationSeconds: 450,
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
          if (point == hanoiStart) {
            return OsrmSnapResult(
              original: point,
              snapped: snappedStartRoad,
              distanceMeters: 35.0,
              streetName: 'Phố Đinh Tiên Hoàng',
              success: true,
            );
          } else {
            return OsrmSnapResult(
              original: point,
              snapped: snappedDestRoad,
              distanceMeters: 65.0,
              streetName: 'Đường Thanh Niên',
              success: true,
            );
          }
        },
      );

      final result = await service.calculateRoutesDetailed(
        hanoiStart,
        hanoiDest,
        mode: 'bike',
        allowSnapRecovery: true,
      );

      expect(result.isSuccess, isTrue);
      expect(result.snapStartDistanceMeters, equals(35.0));
      expect(result.snapDistanceMeters, equals(65.0));
      expect(result.snappedStart, equals(snappedStartRoad));
      expect(result.snappedDestination, equals(snappedDestRoad));
      expect(queriedStart, equals(snappedStartRoad));
      expect(queriedDest, equals(snappedDestRoad));
    });

    test('Single snap: Start already on road (2m), only destination (70m) snaps', () async {
      int queryCount = 0;
      LatLng? queriedStart;
      LatLng? queriedDest;
      final snappedDestRoad = const LatLng(21.0480, 105.8370);

      final service = MapboxDirectionsService(
        valhallaProvider: (start, dest, {required costing}) async {
          queryCount++;
          queriedStart = start;
          queriedDest = dest;
          if (queryCount > 1) {
            return NavRoute(
              title: 'Lộ trình sau snap đích',
              subtitle: 'Đầu bắt đầu giữ nguyên',
              summary: 'Khôi phục thành công',
              totalDistanceMeters: 3800,
              totalDurationSeconds: 450,
              steps: [
                NavStep(
                  stepIndex: 0,
                  instruction: 'Bắt đầu',
                  streetName: 'Đường phố',
                  distanceMeters: 3800,
                  durationSeconds: 450,
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
          if (point == hanoiStart) {
            // Distance 2.1m <= 3.0m threshold -> considered on-road
            return OsrmSnapResult(
              original: point,
              snapped: point,
              distanceMeters: 2.1,
              streetName: 'Phố Đinh Tiên Hoàng',
              success: true,
            );
          } else {
            return OsrmSnapResult(
              original: point,
              snapped: snappedDestRoad,
              distanceMeters: 70.0,
              streetName: 'Đường Thanh Niên',
              success: true,
            );
          }
        },
      );

      final result = await service.calculateRoutesDetailed(
        hanoiStart,
        hanoiDest,
        mode: 'bike',
        allowSnapRecovery: true,
      );

      expect(result.isSuccess, isTrue);
      // Start did not move
      expect(queriedStart, equals(hanoiStart));
      // Dest moved
      expect(queriedDest, equals(snappedDestRoad));
      expect(result.snapDistanceMeters, equals(70.0));
    });
  });
}
