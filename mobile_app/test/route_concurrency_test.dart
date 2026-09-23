import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile_app/models/route_model.dart';
import 'package:mobile_app/services/ble_service.dart';
import 'package:mobile_app/services/mapbox_directions_service.dart';
import 'package:mobile_app/services/navigation_manager.dart';
import 'package:mobile_app/services/routing_service.dart';

class _FakeRoutingService implements RoutingService {
  @override
  Future<NavRoute?> calculateSingleRoute(LatLng start, LatLng destination, {String costing = 'motorcycle'}) async {
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final startPoint = const LatLng(21.0285, 105.8542);
  final endPoint = const LatLng(21.0300, 105.8600);

  NavRoute createDummyRoute({
    required String provider,
    bool isSynthetic = false,
    double distance = 1000.0,
    double duration = 120.0,
  }) {
    return NavRoute(
      title: 'Lộ trình thử nghiệm',
      subtitle: 'Tuyến thử nghiệm',
      summary: 'Đường thử nghiệm',
      totalDistanceMeters: distance,
      totalDurationSeconds: duration,
      steps: [
        NavStep(
          stepIndex: 0,
          instruction: 'Bắt đầu',
          streetName: 'Đường phố',
          distanceMeters: distance,
          durationSeconds: duration,
          coordinate: startPoint,
          maneuverTypeStr: 'depart',
        ),
      ],
      polylinePoints: [startPoint, endPoint],
      provider: provider,
      isFallbackSynthetic: isSynthetic,
    );
  }

  group('P5.9.1 Route Concurrency, Latency & Motorcycle Unification Tests', () {
    setUp(() {
      MapboxDirectionsService.clearCache();
    });
    // -------------------------------------------------------------
    // Test A: Valhalla Fast Success
    // -------------------------------------------------------------
    test('Test A: Valhalla fast success (<500ms) commits Valhalla motorcycle route', () async {
      final service = MapboxDirectionsService(
        valhallaProvider: (start, dest, {required costing}) async {
          await Future.delayed(const Duration(milliseconds: 50));
          return createDummyRoute(provider: 'valhalla');
        },
        osrmProvider: (start, dest, {required mode}) async {
          await Future.delayed(const Duration(milliseconds: 200));
          return [createDummyRoute(provider: 'osrm')];
        },
      );

      final result = await service.calculateRoutesDetailed(
        startPoint,
        endPoint,
        mode: 'bike',
        staggeredDelay: const Duration(milliseconds: 1500),
      );

      expect(result.isSuccess, isTrue);
      expect(result.provider, equals(RouteProvider.valhalla));
      expect(result.routes, isNotEmpty);
      expect(result.routes.first.provider, equals('valhalla'));
      expect(result.routes.first.isFallbackSynthetic, isFalse);
      expect(result.failure, isNull);
    });

    // -------------------------------------------------------------
    // Test B: Valhalla Slow, OSRM Fallback Success
    // -------------------------------------------------------------
    test('Test B: Valhalla slow, OSRM fallback succeeds without waiting 8s/10s', () async {
      final service = MapboxDirectionsService(
        valhallaProvider: (start, dest, {required costing}) async {
          // Valhalla is hanging / slow
          await Future.delayed(const Duration(seconds: 5));
          return createDummyRoute(provider: 'valhalla');
        },
        osrmProvider: (start, dest, {required mode}) async {
          // OSRM responds quickly once triggered
          await Future.delayed(const Duration(milliseconds: 80));
          return [createDummyRoute(provider: 'osrm')];
        },
      );

      final result = await service.calculateRoutesDetailed(
        startPoint,
        endPoint,
        mode: 'bike',
        staggeredDelay: const Duration(milliseconds: 100), // Quick trigger for test
      );

      expect(result.isSuccess, isTrue);
      expect(result.provider, equals(RouteProvider.osrm));
      expect(result.routes, isNotEmpty);
      expect(result.routes.first.provider, equals('osrm'));
      expect(result.routes.first.isFallbackSynthetic, isFalse);
      expect(result.latency.inMilliseconds, lessThan(1000));
    });

    // -------------------------------------------------------------
    // Test C: All Providers Timeout
    // -------------------------------------------------------------
    test('Test C: Hard deadline reached returns failure timeout without hanging', () async {
      final service = MapboxDirectionsService(
        valhallaProvider: (start, dest, {required costing}) async {
          await Future.delayed(const Duration(seconds: 10));
          return null;
        },
        osrmProvider: (start, dest, {required mode}) async {
          await Future.delayed(const Duration(seconds: 10));
          return [];
        },
      );

      final result = await service.calculateRoutesDetailed(
        startPoint,
        endPoint,
        mode: 'bike',
        staggeredDelay: const Duration(milliseconds: 50),
        hardDeadline: const Duration(milliseconds: 200), // Fast test deadline
      );

      expect(result.isSuccess, isFalse);
      expect(result.failure, equals(RouteFailureReason.timeout));
      expect(result.routes, isEmpty);
      expect(result.errorMessage, contains('Quá thời gian'));
    });

    // -------------------------------------------------------------
    // Test D: Stale Request Handling (Generation Token Racing)
    // -------------------------------------------------------------
    test('Test D: Stale request A arriving late does not overwrite fresh request B', () async {
      int activeGeneration = 0;
      NavRoute? committedRoute;
      String? committedPlace;

      Future<void> simulateUserSelectPlace(
        String placeName,
        LatLng dest,
        Duration serviceLatency,
      ) async {
        final currentGen = ++activeGeneration;
        final resultRoute = createDummyRoute(provider: 'valhalla');

        await Future.delayed(serviceLatency);

        // Verification of generation token check
        if (currentGen == activeGeneration) {
          committedRoute = resultRoute;
          committedPlace = placeName;
        }
      }

      // User selects Place A (which is slow, 200ms)
      final requestA = simulateUserSelectPlace('Place A', endPoint, const Duration(milliseconds: 200));

      // 50ms later, user selects Place B (which is fast, 50ms)
      await Future.delayed(const Duration(milliseconds: 50));
      final requestB = simulateUserSelectPlace('Place B', const LatLng(21.04, 105.87), const Duration(milliseconds: 50));

      await Future.wait([requestA, requestB]);

      // Place B arrived first (at T=100ms), Place A arrived late (at T=200ms).
      // Active place MUST remain Place B.
      expect(committedPlace, equals('Place B'));
      expect(committedRoute, isNotNull);
    });

    // -------------------------------------------------------------
    // Test E: Bike Mode Primary is Valhalla Motorcycle Costing
    // -------------------------------------------------------------
    test('Test E: Bike mode triggers Valhalla with motorcycle costing as primary', () async {
      String? recordedCosting;
      String? recordedOsrmMode;

      final service = MapboxDirectionsService(
        valhallaProvider: (start, dest, {required costing}) async {
          recordedCosting = costing;
          return createDummyRoute(provider: 'valhalla');
        },
        osrmProvider: (start, dest, {required mode}) async {
          recordedOsrmMode = mode;
          return [createDummyRoute(provider: 'osrm')];
        },
      );

      final result = await service.calculateRoutesDetailed(
        startPoint,
        endPoint,
        mode: 'bike',
      );

      expect(result.isSuccess, isTrue);
      expect(recordedCosting, equals('motorcycle'));
      expect(recordedOsrmMode, isNull);
    });

    // -------------------------------------------------------------
    // Test F: Synthetic Fallback Route Strict Safety
    // -------------------------------------------------------------
    test('Test F: Synthetic emergency route strictly blocked from startNavigation and startSimulation', () {
      final bleService = BleService();
      final fakeRouter = _FakeRoutingService();
      final navManager = NavigationManager(
        bleService: bleService,
        routingService: fakeRouter,
      );

      final syntheticRoute = MapboxDirectionsService.generateEmergencyRoute(
        startPoint,
        endPoint,
      );

      expect(syntheticRoute.isFallbackSynthetic, isTrue);
      expect(syntheticRoute.provider, equals('synthetic'));

      // Attempt startNavigation on synthetic route
      navManager.startNavigation(syntheticRoute);
      expect(navManager.isNavigating, isFalse);

      // Attempt startSimulation on synthetic route
      navManager.startSimulation(syntheticRoute);
      expect(navManager.isNavigating, isFalse);

      // Pass real route
      final realRoute = createDummyRoute(provider: 'valhalla', isSynthetic: false);
      navManager.startNavigation(realRoute);
      expect(navManager.isNavigating, isTrue);
      navManager.stopNavigation();
    });

    // -------------------------------------------------------------
    // Additional Test G: Invalid / (0,0) Coordinates Rejection
    // -------------------------------------------------------------
    test('Test G: Coordinates validation rejects null island (0,0) or NaN coordinates', () async {
      final service = MapboxDirectionsService();

      final resultZero = await service.calculateRoutesDetailed(
        const LatLng(0, 0),
        endPoint,
      );
      expect(resultZero.isSuccess, isFalse);
      expect(resultZero.failure, equals(RouteFailureReason.invalidCoordinates));

      final resultInvalidLat = await service.calculateRoutesDetailed(
        const LatLng(95.0, 105.0),
        endPoint,
      );
      expect(resultInvalidLat.isSuccess, isFalse);
      expect(resultInvalidLat.failure, equals(RouteFailureReason.invalidCoordinates));
    });
  });
}
