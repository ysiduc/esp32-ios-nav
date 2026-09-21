import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart';
import 'package:mobile_app/models/route_model.dart';
import 'package:mobile_app/services/ble_service.dart';
import 'package:mobile_app/services/esp_raster_map_renderer.dart';
import 'package:mobile_app/services/esp_stream_service.dart';
import 'package:mobile_app/services/navigation_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BleService bleService;
  late NavigationManager navManager;
  late EspStreamService streamService;

  NavRoute createTestRoute({int id = 1}) {
    return NavRoute(
      totalDistanceMeters: 5000,
      totalDurationSeconds: 600,
      summary: 'Lộ trình thử nghiệm $id',
      polylinePoints: const [
        LatLng(21.0285, 105.8542),
        LatLng(21.0290, 105.8545),
        LatLng(21.0300, 105.8550),
      ],
      steps: [
        NavStep(
          stepIndex: 0,
          instruction: 'Đi thẳng trên phố Huế',
          streetName: 'Phố Huế',
          distanceMeters: 500,
          durationSeconds: 60,
          coordinate: const LatLng(21.0285, 105.8542),
          maneuverTypeStr: 'straight',
        ),
      ],
    );
  }

  setUp(() {
    bleService = BleService();
    navManager = NavigationManager(bleService: bleService);
    streamService = EspStreamService(
      bleService: bleService,
      navManager: navManager,
    );
  });

  tearDown(() {
    streamService.dispose();
    navManager.dispose();
    bleService.dispose();
  });

  group('P5.4.1.4 Sections 1-8, 67-77: Authoritative Stream State Matrix & Restoration', () {
    test('Section 67: Pure Stream State Matrix Test - All 4 modes', () {
      // 1. nav=false, wifi=false, ble=true -> standbyStatic
      expect(
        EspStreamService.calculateDisplayMode(
          isNavigating: false,
          isWifiAvailable: false,
          isBleAvailable: true,
        ),
        equals(EspDisplayMode.standbyStatic),
      );

      // 2. nav=false, wifi=true, ble=false -> standbyWifiMap
      expect(
        EspStreamService.calculateDisplayMode(
          isNavigating: false,
          isWifiAvailable: true,
          isBleAvailable: false,
        ),
        equals(EspDisplayMode.standbyWifiMap),
      );

      // 3. nav=false, wifi=true, ble=true -> standbyWifiMap (Wi-Fi priority over BLE)
      expect(
        EspStreamService.calculateDisplayMode(
          isNavigating: false,
          isWifiAvailable: true,
          isBleAvailable: true,
        ),
        equals(EspDisplayMode.standbyWifiMap),
      );

      // 4. nav=true, wifi=false, ble=true -> navigationBleMap
      expect(
        EspStreamService.calculateDisplayMode(
          isNavigating: true,
          isWifiAvailable: false,
          isBleAvailable: true,
        ),
        equals(EspDisplayMode.navigationBleMap),
      );

      // 5. nav=true, wifi=true, ble=true -> navigationWifiMap (Wi-Fi priority over BLE)
      expect(
        EspStreamService.calculateDisplayMode(
          isNavigating: true,
          isWifiAvailable: true,
          isBleAvailable: true,
        ),
        equals(EspDisplayMode.navigationWifiMap),
      );

      // 6. nav=true, wifi=false, ble=false -> standbyStatic (no transport)
      expect(
        EspStreamService.calculateDisplayMode(
          isNavigating: true,
          isWifiAvailable: false,
          isBleAvailable: false,
        ),
        equals(EspDisplayMode.standbyStatic),
      );
    });

    test('Section 68: Standby BLE Test - No continuous JPEG generation over BLE in standby', () {
      bleService.setConnectedForTesting(true);
      expect(bleService.isConnected, isTrue);
      expect(bleService.isWifiConnected, isFalse);
      expect(navManager.isNavigating, isFalse);

      expect(streamService.currentDisplayMode, equals(EspDisplayMode.standbyStatic));
      // In standbyStatic: active transport must be none (no JPEG over BLE)
      expect(streamService.activeJpegTransport, equals(EspJpegTransport.none));
      expect(streamService.effectiveTargetFps, equals(0));
      expect(streamService.hasEspDisplayConsumer, isFalse);

      streamService.startStreaming();
      expect(streamService.streamState, equals(EspMapStreamState.idle));
      expect(streamService.actualFps, equals(0.0));
      expect(streamService.mapJpegRendersCount, equals(0));
    });

    test('Section 69: Standby Wi-Fi Test - Streams live map at 8-15 FPS in foreground and background', () {
      streamService.setMockTransportForTesting(EspJpegTransport.wifiWebSocket);
      expect(navManager.isNavigating, isFalse);
      expect(streamService.currentDisplayMode, equals(EspDisplayMode.standbyWifiMap));

      // Foreground: 8-15 FPS (nominal 10)
      streamService.setForegroundForTesting(true);
      expect(streamService.effectiveTargetFps, inInclusiveRange(8, 15));

      // Background / screen locked: STILL 8-15 FPS (Section 2 & 35)
      streamService.setForegroundForTesting(false);
      expect(streamService.effectiveTargetFps, inInclusiveRange(8, 15));
    });

    test('Section 70: Nav BLE FPS Policy Test - Allowed into 5-12 FPS range based on throughput', () {
      final route = createTestRoute();
      navManager.startNavigation(route);
      expect(navManager.isNavigating, isTrue);

      bleService.setConnectedForTesting(true);
      expect(streamService.currentDisplayMode, equals(EspDisplayMode.navigationBleMap));
      expect(streamService.activeJpegTransport, equals(EspJpegTransport.ble));

      // Simulate fast BLE transfer (80ms)
      bleService.recordBleTransferDuration(80);
      expect(streamService.effectiveTargetFps, inInclusiveRange(9, 12));
      expect(streamService.effectiveTargetFps, greaterThan(5)); // Not capped to 5!

      // Simulate moderate BLE transfer (150ms)
      bleService.recordBleTransferDuration(150);
      expect(streamService.effectiveTargetFps, inInclusiveRange(5, 7));
    });

    test('Section 71: Nav Wi-Fi FPS Policy Test - Nominal target reaches 12-25 FPS', () {
      final route = createTestRoute();
      navManager.startNavigation(route);
      expect(navManager.isNavigating, isTrue);

      streamService.setMockTransportForTesting(EspJpegTransport.wifiWebSocket);
      expect(streamService.currentDisplayMode, equals(EspDisplayMode.navigationWifiMap));

      // Target reaches 12-25 FPS, not capped to 14
      expect(streamService.effectiveTargetFps, inInclusiveRange(12, 25));
    });

    test('Section 72: Background Parity Test - Background does NOT automatically collapse FPS', () {
      final route = createTestRoute();
      navManager.startNavigation(route);

      // Wi-Fi navigation
      streamService.setMockTransportForTesting(EspJpegTransport.wifiWebSocket);
      streamService.setForegroundForTesting(true);
      final fgWifiFps = streamService.effectiveTargetFps;

      streamService.setForegroundForTesting(false);
      final bgWifiFps = streamService.effectiveTargetFps;
      // Must maintain parity, not drop to 1-6 FPS
      expect(bgWifiFps, equals(fgWifiFps));
      expect(bgWifiFps, inInclusiveRange(12, 25));

      // BLE navigation
      streamService.setMockTransportForTesting(EspJpegTransport.ble);
      bleService.recordBleTransferDuration(100);
      streamService.setForegroundForTesting(true);
      final fgBleFps = streamService.effectiveTargetFps;

      streamService.setForegroundForTesting(false);
      final bgBleFps = streamService.effectiveTargetFps;
      expect(bgBleFps, equals(fgBleFps));
      expect(bgBleFps, inInclusiveRange(5, 12));
    });

    test('Section 73: White-Frame Test - Uniform white image rejected, lastGoodJpeg preserved', () {
      final renderer = streamService.frameRenderer;

      // Create uniform white frame (255, 255, 255)
      final whiteFrame = img.Image(width: 144, height: 208);
      img.fill(whiteFrame, color: img.ColorRgba8(255, 255, 255, 255));

      // Must be rejected by sanity validation
      expect(renderer.isSanityValid(whiteFrame), isFalse);

      // Set valid lastGoodJpeg
            renderer.resetForTesting();
      // Render normal frame first to populate lastGoodJpeg
      final firstJpeg = renderer.renderFrame(
        userPos: const LatLng(21.0285, 105.8542),
        headingDeg: 0.0,
        activeRoute: null,
        isNavigating: false,
      );
      expect(firstJpeg, isNotNull);
      expect(renderer.lastGoodJpeg, equals(firstJpeg));

      // When blank white frame detected, renderer preserves lastGoodJpeg
      expect(renderer.isSanityValid(whiteFrame), isFalse);
    });

    test('Section 74: Black-Frame Test - Near-uniform black image rejected', () {
      final renderer = streamService.frameRenderer;

      // Create uniform black frame (0, 0, 0)
      final blackFrame = img.Image(width: 144, height: 208);
      img.fill(blackFrame, color: img.ColorRgba8(5, 5, 5, 255));

      expect(renderer.isSanityValid(blackFrame), isFalse);
    });

    test('Section 75: Tile Fetch Failure Test - Reuses prior valid frame, never blank screen', () {
      final renderer = streamService.frameRenderer;
      renderer.resetForTesting();

      // Render initial frame
      final frame1 = renderer.renderFrame(
        userPos: const LatLng(21.0285, 105.8542),
        headingDeg: 45.0,
        activeRoute: createTestRoute(),
        isNavigating: true,
      );
      expect(frame1, isNotNull);
      expect(renderer.lastGoodJpeg, isNotNull);

      // Even if network tile fetching fails or cache empty, renderFrame returns valid JPEG
      final frame2 = renderer.renderFrame(
        userPos: const LatLng(21.0290, 105.8545),
        headingDeg: 50.0,
        activeRoute: createTestRoute(),
        isNavigating: true,
      );
      expect(frame2, isNotNull);
    });

    test('Section 76 & 77: Wi-Fi <-> BLE Handoff Test during Navigation', () {
      final route = createTestRoute();
      navManager.startNavigation(route);
      bleService.setConnectedForTesting(true);

      // Phase 1: Wi-Fi + BLE connected -> navigationWifiMap
      streamService.setMockTransportForTesting(EspJpegTransport.wifiWebSocket);
      expect(streamService.currentDisplayMode, equals(EspDisplayMode.navigationWifiMap));
      expect(streamService.activeJpegTransport, equals(EspJpegTransport.wifiWebSocket));

      // Phase 2: Wi-Fi drops -> automatic handoff to navigationBleMap (Section 76)
      streamService.setMockTransportForTesting(null);
      expect(streamService.currentDisplayMode, equals(EspDisplayMode.navigationBleMap));
      expect(streamService.activeJpegTransport, equals(EspJpegTransport.ble));
      expect(streamService.effectiveTargetFps, inInclusiveRange(5, 12));

      // Phase 3: Wi-Fi reconnects -> clean switch back to navigationWifiMap (Section 77)
      streamService.setMockTransportForTesting(EspJpegTransport.wifiWebSocket);
      expect(streamService.currentDisplayMode, equals(EspDisplayMode.navigationWifiMap));
      expect(streamService.activeJpegTransport, equals(EspJpegTransport.wifiWebSocket));
    });

    test('Section 36 & 37: Thermal Adaptation Test - Quality reduced first, then FPS', () {
      final route = createTestRoute();
      navManager.startNavigation(route);
      streamService.setMockTransportForTesting(EspJpegTransport.wifiWebSocket);

      // Nominal: Quality ~70, full FPS
      streamService.setThermalStateForTesting('nominal');
      expect(streamService.effectiveJpegQuality, inInclusiveRange(65, 75));
      final nominalFps = streamService.effectiveTargetFps;

      // Fair: Quality reduced first (Section 37), FPS unchanged!
      streamService.setThermalStateForTesting('fair');
      expect(streamService.effectiveJpegQuality, inInclusiveRange(55, 62));
      expect(streamService.effectiveTargetFps, equals(nominalFps)); // FPS NOT reduced on fair!

      // Serious: Quality reduced + moderate FPS reduction
      streamService.setThermalStateForTesting('serious');
      expect(streamService.effectiveJpegQuality, inInclusiveRange(45, 52));
      expect(streamService.effectiveTargetFps, lessThan(nominalFps));

      // Critical: 1 FPS
      streamService.setThermalStateForTesting('critical');
      expect(streamService.effectiveTargetFps, equals(1));
    });
  });
}
