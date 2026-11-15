import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart';
import 'package:mobile_app/services/ble_service.dart';
import 'package:mobile_app/services/esp_stream_service.dart';
import 'package:mobile_app/services/navigation_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('NavigationManager GPS accuracy & lag prevention', () {
    test('rejects stale or coarse getLastKnownPosition fixes', () {
      expect(
        NavigationManager.isAcceptableLastKnownPosition(
          accuracyMeters: 12.0,
          age: const Duration(seconds: 15),
        ),
        isTrue,
      );
      expect(
        NavigationManager.isAcceptableLastKnownPosition(
          accuracyMeters: 12.0,
          age: const Duration(seconds: 95),
        ),
        isFalse,
      );
      expect(
        NavigationManager.isAcceptableLastKnownPosition(
          accuracyMeters: 85.0,
          age: const Duration(seconds: 5),
        ),
        isFalse,
      );
      expect(
        NavigationManager.isAcceptableLastKnownPosition(
          accuracyMeters: -1.0,
          age: const Duration(seconds: 2),
        ),
        isFalse,
      );
    });

    test('filters cell-tower outliers and transient coarse bounces', () {
      // Cold start rejects cell-tower > 150m jumps
      expect(
        NavigationManager.isReliableLiveGpsFix(
          incomingAccuracyM: 320.0,
          recentAccuracyM: 999.0,
          msSinceLastAccurateFix: 999999,
        ),
        isFalse,
      );
      // Accepts moderate Wi-Fi fix on cold start
      expect(
        NavigationManager.isReliableLiveGpsFix(
          incomingAccuracyM: 65.0,
          recentAccuracyM: 999.0,
          msSinceLastAccurateFix: 999999,
        ),
        isTrue,
      );
      // Rejects coarse >55m bounce within 8s after a sharp 6m GPS lock
      expect(
        NavigationManager.isReliableLiveGpsFix(
          incomingAccuracyM: 62.0,
          recentAccuracyM: 6.0,
          msSinceLastAccurateFix: 2500,
        ),
        isFalse,
      );
      // Accepts sharp fix immediately
      expect(
        NavigationManager.isReliableLiveGpsFix(
          incomingAccuracyM: 5.0,
          recentAccuracyM: 6.0,
          msSinceLastAccurateFix: 1000,
        ),
        isTrue,
      );
    });

    test('snaps idle location directly on >15m jump or accuracy lock instead of leaving 45% lag', () {
      const coarseStart = LatLng(21.02850, 105.85420);
      const truePos = LatLng(21.02900, 105.85420); // ~55m north

      final resolvedJump = NavigationManager.resolveNextIdleLocation(
        currentLocation: coarseStart,
        hasInitialLiveGpsFix: true,
        incomingLocation: truePos,
        incomingAccuracyM: 6.0,
        previousAccuracyM: 50.0,
        speedKmh: 0.0,
      );
      expect(resolvedJump.latitude, closeTo(truePos.latitude, 1e-7));
      expect(resolvedJump.longitude, closeTo(truePos.longitude, 1e-7));

      // Even tiny move snaps when accuracy sharpens meaningfully (50m -> 10m)
      const slightlyAdjusted = LatLng(21.02855, 105.85422);
      final resolvedSharper = NavigationManager.resolveNextIdleLocation(
        currentLocation: coarseStart,
        hasInitialLiveGpsFix: true,
        incomingLocation: slightlyAdjusted,
        incomingAccuracyM: 10.0,
        previousAccuracyM: 50.0,
        speedKmh: 0.0,
      );
      expect(resolvedSharper.latitude, closeTo(slightlyAdjusted.latitude, 1e-7));

      // Micro-jitter (<15m, unchanged accuracy, stationary) smooths softly at 0.75
      final smoothedJitter = NavigationManager.resolveNextIdleLocation(
        currentLocation: coarseStart,
        hasInitialLiveGpsFix: true,
        incomingLocation: slightlyAdjusted,
        incomingAccuracyM: 8.0,
        previousAccuracyM: 7.0,
        speedKmh: 0.0,
      );
      expect(smoothedJitter.latitude, greaterThan(coarseStart.latitude));
      expect(smoothedJitter.latitude, lessThan(slightlyAdjusted.latitude));
    });

    test('clamps adaptive snap limit tightly between 24m and 38m', () {
      expect(NavigationManager.computeAdaptiveSnapLimitMeters(5.0), 24.0);
      expect(NavigationManager.computeAdaptiveSnapLimitMeters(26.0), closeTo(29.9, 0.01));
      expect(NavigationManager.computeAdaptiveSnapLimitMeters(65.0), 38.0);
    });
  });

  group('EspStreamService high-clarity JPEG encoding', () {
    test('uses 26.5KB frame budget matching ESP32 32KB pool and encodes crisp RGBA frame', () async {
      final ble = BleService();
      final stream = EspStreamService(bleService: ble);
      expect(stream.debugMaxJpegFrameBytes, 26500);

      // Build textured 144x208 map-like RGBA test image (roads + buildings)
      final canvas = img.Image(width: 144, height: 208, numChannels: 4);
      img.fill(canvas, color: img.ColorRgba8(226, 232, 240, 255));
      for (int i = 0; i < 180; i += 28) {
        img.fillRect(
          canvas,
          x1: (i * 3) % 110,
          y1: i,
          x2: ((i * 3) % 110) + 26,
          y2: i + 20,
          color: img.ColorRgba8(168, 178, 196, 255),
        );
      }
      img.drawLine(
        canvas,
        x1: 72,
        y1: 0,
        x2: 72,
        y2: 207,
        color: img.ColorRgba8(37, 99, 235, 255),
        thickness: 6,
      );
      final rgba = Uint8List.fromList(
        canvas.getBytes(order: img.ChannelOrder.rgba),
      );

      final jpg = await stream.debugCompressRgbaToJpeg(rgba, 144, 208, quality: 88);
      expect(jpg, isNotNull);
      expect(jpg!.length, lessThanOrEqualTo(stream.debugMaxJpegFrameBytes));
      expect(jpg[0], 0xFF);
      expect(jpg[1], 0xD8);

      final decoded = img.decodeJpg(jpg)!;
      expect(decoded.width, 144);
      expect(decoded.height, 208);

      stream.dispose();
      ble.dispose();
    });
  });
}

