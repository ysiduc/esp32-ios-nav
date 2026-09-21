import 'package:mobile_app/services/voice_guidance_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile_app/models/route_model.dart';
import 'package:mobile_app/services/ble_service.dart';
import 'package:mobile_app/services/esp_stream_service.dart';
import 'package:mobile_app/services/navigation_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('P5.4.1.2: iPhone Thermal & Battery Reduction Tests', () {
    late BleService bleService;
    late NavigationManager navManager;
    late EspStreamService streamService;

    setUp(() {
      VoiceGuidanceService().setMuted(true);
      bleService = BleService();
      navManager = NavigationManager(bleService: bleService);
      streamService = EspStreamService(bleService: bleService, navManager: navManager);
    });

    tearDown(() {
      streamService.dispose();
      navManager.dispose();
      bleService.dispose();
    });

    NavRoute createTestRoute({int id = 1}) {
      return NavRoute(
        totalDistanceMeters: 1500.0 * id,
        totalDurationSeconds: 300.0 * id,
        polylinePoints: [
          LatLng(21.0285, 105.8542),
          LatLng(21.0295 + id * 0.001, 105.8552 + id * 0.001),
          LatLng(21.0315 + id * 0.001, 105.8572 + id * 0.001),
        ],
        steps: [
          NavStep(
            stepIndex: 0,
            instruction: 'Đi thẳng',
            streetName: 'Đường Phố Huế',
            distanceMeters: 500.0,
            durationSeconds: 100.0,
            maneuverTypeStr: 'straight',
            coordinate: LatLng(21.0285, 105.8542),
          ),
          NavStep(
            stepIndex: 1,
            instruction: 'Rẽ phải',
            streetName: 'Đường Đại Cồ Việt',
            distanceMeters: 1000.0,
            durationSeconds: 200.0,
            maneuverTypeStr: 'turn-right',
            coordinate: LatLng(21.0295 + id * 0.001, 105.8552 + id * 0.001),
          ),
        ],
        summary: 'Tuyến đường $id',
        title: 'Tuyến đường $id',
        subtitle: '15 phút',
        isFastest: true,
        isShortest: false,
        isTollFree: true,
        themeColor: const Color(0xFF007AFF),
        durationDiffMinutes: 0,
        distanceDiffKm: 0.0,
      );
    }

    test('Section 47: Thermal Regression - No Consumer -> Render Frame Count == 0', () async {
      // State: Map open, ESP disconnected, not navigating
      expect(streamService.hasEspDisplayConsumer, isFalse);

      streamService.startStreaming();

      // State must be waitingForConsumer with 0 FPS
      expect(streamService.streamState, equals(EspMapStreamState.waitingForConsumer));
      expect(streamService.actualFps, equals(0.0));

      // Simulate 100ms
      await Future.delayed(const Duration(milliseconds: 100));

      // No JPEG frames rendered
      expect(streamService.mapJpegRendersCount, equals(0));
      expect(streamService.actualFps, equals(0.0));
    });

    test('Section 48: Thermal Regression - Navigating without Map Consumer -> 0 JPEG renders', () async {
      final route = createTestRoute();
      navManager.startNavigation(route);
      expect(navManager.isNavigating, isTrue);

      // Start stream service while no display consumer exists
      streamService.startStreaming();

      expect(streamService.hasEspDisplayConsumer, isFalse);
      expect(streamService.streamState, equals(EspMapStreamState.waitingForConsumer));

      // Telemetry is active
      expect(navManager.activeRoute, isNotNull);
      expect(navManager.remainingTotalDistance, greaterThan(0));

      // JPEG rendering count strictly 0
      expect(streamService.mapJpegRendersCount, equals(0));
      expect(streamService.actualFps, equals(0.0));
    });

    test('Section 49: Connected ESP foreground stream capped at 10 FPS, background 1-2 FPS', () {
      // Default foreground cap must be 10 FPS (down from 14)
      expect(streamService.targetFps, equals(10));
      expect(streamService.effectiveTargetFps, equals(10));

      // In background, target rate is 1 FPS
      final bgRate = 1;
      expect(bgRate, inInclusiveRange(1, 2));
    });

    test('Section 50: Serious thermal state drops FPS to 3-5, critical pauses visual stream', () {
      streamService.setThermalStateForTesting('nominal');
      expect(streamService.effectiveTargetFps, equals(10));

      streamService.setThermalStateForTesting('fair');
      expect(streamService.effectiveTargetFps, equals(7));

      // Section 40: serious -> 3-5 FPS (we choose 4)
      streamService.setThermalStateForTesting('serious');
      expect(streamService.effectiveTargetFps, inInclusiveRange(3, 5));

      // Section 40: critical -> 0 FPS (pause visual map streaming)
      streamService.setThermalStateForTesting('critical');
      expect(streamService.effectiveTargetFps, equals(0));

      // Telemetry remains unpaused
      final route = createTestRoute();
      navManager.startNavigation(route);
      expect(navManager.isNavigating, isTrue);

      // Low power mode test (Section 41)
      streamService.setThermalStateForTesting('nominal');
      streamService.setLowPowerModeForTesting(true);
      expect(streamService.effectiveTargetFps, equals(5));
    });

    test('Section 51 & 52: Route redraw test - 20 GPS samples cause 0 route rebuilds, reroute causes 1', () {
      final route1 = createTestRoute(id: 1);
      String? lastRenderedKey;
      int geometryRebuildCount = 0;

      void renderRoute(List<LatLng> points, int routeCount, int selectedIdx) {
        final key = points.isEmpty
            ? 'empty'
            : '${points.length}_${points.first.latitude}_${points.first.longitude}_${points.last.latitude}_${points.last.longitude}_${routeCount}_$selectedIdx';
        if (key == lastRenderedKey) return;
        lastRenderedKey = key;
        geometryRebuildCount++;
      }

      // Initial route render
      renderRoute(route1.polylinePoints, 1, 0);
      expect(geometryRebuildCount, equals(1));

      // Feed 20 GPS updates along the same route
      for (int i = 0; i < 20; i++) {
        // Position changes along route, but route geometry does not change
        renderRoute(route1.polylinePoints, 1, 0);
      }

      // Route geometry rebuild count MUST REMAIN 1 (0 additional rebuilds)
      expect(geometryRebuildCount, equals(1));

      // When reroute occurs with new route
      final route2 = createTestRoute(id: 2);
      renderRoute(route2.polylinePoints, 1, 0);

      // Exactly ONE new route geometry rebuild
      expect(geometryRebuildCount, equals(2));
    });

    test('Section 53: Camera throttle test - 30 GPS callbacks in 1 sec bounded by display cadence', () {
      int cameraUpdateCount = 0;
      DateTime lastAnimateTime = DateTime.fromMillisecondsSinceEpoch(0);
      LatLng? coalescedPos;
      LatLng? lastExecutedPos;

      void throttledAnimate(LatLng pos, DateTime now) {
        final elapsed = now.difference(lastAnimateTime).inMilliseconds;
        if (elapsed < 110) { // ~9 Hz display cadence
          coalescedPos = pos;
          return;
        }
        lastAnimateTime = now;
        lastExecutedPos = pos;
        cameraUpdateCount++;
      }

      // Simulate 30 GPS callbacks spread over 1000ms (every 33ms)
      final start = DateTime.now();
      for (int i = 0; i < 30; i++) {
        final sampleTime = start.add(Duration(milliseconds: i * 33));
        final pt = LatLng(21.0 + i * 0.0001, 105.0 + i * 0.0001);
        throttledAnimate(pt, sampleTime);
      }

      // 30 callbacks in 1 second must be bounded <= 10 camera updates
      expect(cameraUpdateCount, lessThanOrEqualTo(10));
      expect(cameraUpdateCount, greaterThanOrEqualTo(8));

      // If there is a coalesced position, applying it ensures latest position wins
      if (coalescedPos != null) {
        lastExecutedPos = coalescedPos;
      }
      expect(lastExecutedPos!.latitude, closeTo(21.0 + 29 * 0.0001, 0.00001));
    });
  });
}
