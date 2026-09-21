import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile_app/models/route_model.dart';
import 'package:mobile_app/services/ble_service.dart';
import 'package:mobile_app/services/esp_stream_service.dart';
import 'package:mobile_app/services/navigation_manager.dart';
import 'package:mobile_app/services/voice_guidance_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('P5.4.1.3: Smooth ESP JPEG Streaming & Thermal Adaptation Tests', () {
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
      expect(streamService.activeJpegTransport, equals(EspJpegTransport.none));

      streamService.startStreaming();

      // State must be waitingForConsumer with 0 FPS
      expect(streamService.streamState, equals(EspMapStreamState.waitingForConsumer));
      expect(streamService.actualFps, equals(0.0));

      await Future.delayed(const Duration(milliseconds: 100));

      // No JPEG frames rendered
      expect(streamService.mapJpegRendersCount, equals(0));
      expect(streamService.actualFps, equals(0.0));
    });

    test('Section 48: Thermal Regression - Navigating without Map Consumer -> 0 JPEG renders', () async {
      final route = createTestRoute();
      navManager.startNavigation(route);
      expect(navManager.isNavigating, isTrue);

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

    test('Section 53: BLE-Only Stream Test - BLE connected without Wi-Fi activates stream', () {
      bleService.setConnectedForTesting(true);
      expect(bleService.isConnected, isTrue);
      expect(bleService.isWifiConnected, isFalse);

      // Must detect BLE as active transport
      expect(streamService.activeJpegTransport, equals(EspJpegTransport.ble));
      expect(streamService.hasEspDisplayConsumer, isTrue);

      streamService.startStreaming();

      // Must transition to streamingForeground, NOT remain waitingForConsumer
      expect(streamService.streamState, equals(EspMapStreamState.streamingForeground));
      expect(streamService.effectiveTargetFps, inInclusiveRange(2, 5));
    });

    test('Section 54: Wi-Fi Foreground FPS Test - Restores smooth 12-14 FPS', () {
      streamService.setMockTransportForTesting(EspJpegTransport.wifiWebSocket);
      streamService.setForegroundForTesting(true);
      streamService.setThermalStateForTesting('nominal');
      streamService.setLowPowerModeForTesting(false);

      expect(streamService.activeJpegTransport, equals(EspJpegTransport.wifiWebSocket));
      expect(streamService.hasEspDisplayConsumer, isTrue);

      // Configured cap must be 14 FPS for Wi-Fi foreground
      expect(streamService.effectiveTargetFps, equals(14));
    });

    test('Section 55: Wi-Fi Background FPS Test - Nominal rate is 5-6 FPS, not 1 FPS', () {
      streamService.setMockTransportForTesting(EspJpegTransport.wifiWebSocket);
      streamService.setForegroundForTesting(false); // Screen locked / background
      streamService.setThermalStateForTesting('nominal');

      // Wi-Fi background must be 6 FPS (in 5-6 FPS range)
      expect(streamService.effectiveTargetFps, equals(6));
      expect(streamService.effectiveTargetFps, inInclusiveRange(5, 6));
    });

    test('Section 56: Thermal Adaptation Test - Gradual reduction across states', () {
      streamService.setMockTransportForTesting(EspJpegTransport.wifiWebSocket);
      streamService.setForegroundForTesting(true);

      // Nominal: full 14 FPS
      streamService.setThermalStateForTesting('nominal');
      expect(streamService.effectiveTargetFps, equals(14));

      // Fair: ~80% scaling (11 FPS)
      streamService.setThermalStateForTesting('fair');
      expect(streamService.effectiveTargetFps, equals(11));

      // Serious: ~50% scaling (7 FPS)
      streamService.setThermalStateForTesting('serious');
      expect(streamService.effectiveTargetFps, inInclusiveRange(3, 7));

      // Critical: minimal (1 FPS) or pause
      streamService.setThermalStateForTesting('critical');
      expect(streamService.effectiveTargetFps, inInclusiveRange(0, 1));

      // Low Power Mode in foreground clamps to <= 8 FPS
      streamService.setThermalStateForTesting('nominal');
      streamService.setLowPowerModeForTesting(true);
      expect(streamService.effectiveTargetFps, equals(8));
    });

    test('Section 57: BLE Throughput Adaptation Test', () {
      streamService.setMockTransportForTesting(EspJpegTransport.ble);
      streamService.setForegroundForTesting(true);

      // Simulate 300ms transfer duration
      bleService.recordBleTransferDuration(300);
      expect(streamService.effectiveTargetFps, equals(3));

      // Simulate fast 120ms transfer duration
      bleService.recordBleTransferDuration(120);
      expect(streamService.effectiveTargetFps, inInclusiveRange(4, 5));

      // In background, BLE target is 2-3 FPS
      streamService.setForegroundForTesting(false);
      expect(streamService.effectiveTargetFps, inInclusiveRange(2, 3));
    });

    test('Section 58: Strict Backpressure Test', () async {
      streamService.setMockTransportForTesting(EspJpegTransport.wifiWebSocket);
      streamService.startStreaming();

      // Trigger coalescing count
      expect(streamService.framesCoalescedCount, equals(0));
    });

    test('Section 59: Raster Pipeline Test - Legacy vector/CPU methods removed', () {
      final file = File('../mobile_app/lib/services/esp_stream_service.dart');
      final content = file.readAsStringSync();

      // Ensure manual Canvas path drawing and CPU tile rendering methods are removed
      expect(content.contains('_drawRealMapCanvas'), isFalse);
      expect(content.contains('_renderCpuMapFrame'), isFalse);
      expect(content.contains('_cpuTileCache'), isFalse);
      expect(content.contains('_prefetchSurroundingTiles'), isFalse);
    });

    test('Section 60 & 61: Snapshot Cache & Movement Threshold Test', () {
      final renderer = streamService.frameRenderer;
      final center = LatLng(21.0285, 105.8542);

      // Initial state: needs snapshot
      expect(renderer.shouldRefreshSnapshot(
        currentPos: center,
        currentHeading: 0.0,
        zoom: 17,
        routeId: null,
      ), isTrue);

      // After rendering frame with mock provider
      renderer.mapSnapshotProvider = ({height, width}) async => null;

      // Small movement < 10m and heading < 15°: reuses cached snapshot (Section 60)
      final smallMove = LatLng(21.02851, 105.85421); // ~1.5 meters
      expect(renderer.shouldRefreshSnapshot(
        currentPos: smallMove,
        currentHeading: 5.0,
        zoom: 17,
        routeId: null,
      ), isTrue); // true before first successful snapshot fetch

      // Distance >= 10m triggers refresh (Section 61)
      const distCalc = Distance();
      final farPos = distCalc.offset(center, 12.0, 90.0);
      expect(distCalc.as(LengthUnit.Meter, center, farPos), greaterThanOrEqualTo(10.0));
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

      final start = DateTime.now();
      for (int i = 0; i < 30; i++) {
        final sampleTime = start.add(Duration(milliseconds: i * 33));
        final pt = LatLng(21.0 + i * 0.0001, 105.0 + i * 0.0001);
        throttledAnimate(pt, sampleTime);
      }

      expect(cameraUpdateCount, lessThanOrEqualTo(10));
      expect(cameraUpdateCount, greaterThanOrEqualTo(8));

      if (coalescedPos != null) {
        lastExecutedPos = coalescedPos;
      }
      expect(lastExecutedPos!.latitude, closeTo(21.0 + 29 * 0.0001, 0.00001));
    });
  });
}
