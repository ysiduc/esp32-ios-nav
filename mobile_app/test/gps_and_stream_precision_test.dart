import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart';
import 'package:mobile_app/services/ble_service.dart';
import 'package:mobile_app/services/esp_stream_service.dart';
import 'package:mobile_app/services/goong_service.dart';
import 'package:mobile_app/services/navigation_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  navHeadingAndRouteLineTests();

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

void navHeadingAndRouteLineTests() {
  group('Nav heading & route line hugging', () {
    test('shouldFollowRouteBearing uses hysteresis and never follows a wrong-way course', () {
      // Facing the same way as the road -> follow the (smooth) road bearing
      expect(
        NavigationManager.shouldFollowRouteBearing(courseDeg: 92.0, routeBearingDeg: 100.0, wasFollowing: false),
        isTrue,
      );
      // Road turns 90 deg ahead but user has not turned yet -> keep real heading (no guessing)
      expect(
        NavigationManager.shouldFollowRouteBearing(courseDeg: 10.0, routeBearingDeg: 100.0, wasFollowing: true),
        isFalse,
      );
      // 30 deg diff: stays on road if already following, but does not newly lock on
      expect(
        NavigationManager.shouldFollowRouteBearing(courseDeg: 70.0, routeBearingDeg: 100.0, wasFollowing: true),
        isTrue,
      );
      expect(
        NavigationManager.shouldFollowRouteBearing(courseDeg: 70.0, routeBearingDeg: 100.0, wasFollowing: false),
        isFalse,
      );
      expect(NavigationManager.angleDiffDeg(350.0, 10.0), closeTo(20.0, 1e-6));
    });

    test('trimRemainingPolyline starts on the road, not a straight line from the puck to the corner', () {
      // Straight road going north then a 90 deg corner east
      final pts = <LatLng>[
        const LatLng(21.0000, 105.8000),
        const LatLng(21.0010, 105.8000),
        const LatLng(21.0020, 105.8000), // corner
        const LatLng(21.0020, 105.8010),
      ];
      // Puck sits ~45 m east of the road (off-route GPS), level with the first segment middle
      const puck = LatLng(21.0005, 105.80042);
      final trimmed = NavigationManager.trimRemainingPolyline(pts, 0, puck);
      // First point must lie ON the first segment (same longitude as the road), never the raw puck
      expect(trimmed.first.longitude, closeTo(105.8000, 1e-6));
      expect(trimmed.first.latitude, closeTo(21.0005, 5e-5));
      expect(trimmed[1], pts[1]);
      expect(trimmed.last, pts.last);
      // Every vertex of the drawn line is a real route vertex (apart from the projected start)
      for (final p in trimmed.skip(1)) {
        expect(pts.contains(p), isTrue);
      }
    });

    test('pointAlongPolylineAhead & advanceAlongPolyline stop at sharp >25 deg turn corners', () {
      // Road goes North 50m to corner, then turns 90 deg East for 100m
      final pts = <LatLng>[
        const LatLng(21.0000, 105.8000),
        const LatLng(21.00045, 105.8000), // ~50m North (corner)
        const LatLng(21.00045, 105.8010), // ~104m East
      ];
      // Vehicle is ~5m south of the corner, lookAhead is 10m -> must stop AT the corner, NOT peek East
      const nearCorner = LatLng(21.000405, 105.8000);
      final look = NavigationManager.pointAlongPolylineAhead(pts, 0, nearCorner, 10.0);
      expect(look.latitude, closeTo(pts[1].latitude, 1e-6));
      expect(look.longitude, closeTo(pts[1].longitude, 1e-6));

      // Live dead-reckoning (stopAtSharpTurn: true) must NOT creep around the 90 deg corner
      final advLive = NavigationManager.advanceAlongPolyline(
        pts,
        0,
        nearCorner,
        12.0,
        stopAtSharpTurn: true,
      );
      expect(advLive.segmentIndex, 0);
      expect(advLive.point.latitude, closeTo(pts[1].latitude, 1e-6));
      expect(advLive.point.longitude, closeTo(pts[1].longitude, 1e-6));

      // Simulation (stopAtSharpTurn: false) smoothly continues around the corner
      final advSim = NavigationManager.advanceAlongPolyline(
        pts,
        0,
        nearCorner,
        12.0,
        stopAtSharpTurn: false,
      );
      expect(advSim.segmentIndex, 1);
      expect(advSim.point.longitude, greaterThan(pts[1].longitude));
    });

    test('snapPointToPolyline does not jump onto 90 deg turn segment when driving straight past it', () {
      // Northbound approach to corner, then 90 deg East turn
      final pts = <LatLng>[
        const LatLng(21.0000, 105.8000),
        const LatLng(21.0010, 105.8000), // corner
        const LatLng(21.0010, 105.8010), // East turn
      ];
      // User missed the right turn and drove 5m straight North past the corner (course 0 deg, 25 km/h)
      const pastCornerGoingNorth = LatLng(21.001045, 105.8000);
      final snap = NavigationManager.snapPointToPolyline(
        pastCornerGoingNorth,
        pts,
        hintSegmentIndex: 0,
        speedKmh: 25.0,
        liveCourseDeg: 0.0,
        fallbackHeading: 0.0,
      );
      // Must stay on segment 0 (Northbound), NOT jump to segment 1 (Eastbound 90 deg)
      expect(snap.segmentIndex, 0);
      expect(NavigationManager.angleDiffDeg(snap.bearingDeg, 0.0), lessThan(15.0));
    });

    test('GoongService.parseDirectionResponse stitches high-res step polylines over coarse overview', () {
      // Helper encoder for test coordinates (5-decimal Google Polyline)
      String encodePoly(List<LatLng> coords) {
        final sb = StringBuffer();
        int prevLat = 0, prevLng = 0;
        void writeVal(int v) {
          int val = v < 0 ? ~(v << 1) : (v << 1);
          while (val >= 0x20) {
            sb.writeCharCode((0x20 | (val & 0x1f)) + 63);
            val >>= 5;
          }
          sb.writeCharCode(val + 63);
        }
        for (final c in coords) {
          final lat = (c.latitude * 1e5).round();
          final lng = (c.longitude * 1e5).round();
          writeVal(lat - prevLat);
          writeVal(lng - prevLng);
          prevLat = lat;
          prevLng = lng;
        }
        return sb.toString();
      }

      // Coarse overview has only 2 endpoints; steps together have 5 detailed curve vertices
      final overview = [
        const LatLng(21.0000, 105.8000),
        const LatLng(21.0020, 105.8020),
      ];
      final step1 = [
        const LatLng(21.0000, 105.8000),
        const LatLng(21.0005, 105.8001),
        const LatLng(21.0010, 105.8006),
      ];
      final step2 = [
        const LatLng(21.0010, 105.8006), // shared boundary vertex (should be deduplicated)
        const LatLng(21.0016, 105.8012),
        const LatLng(21.0020, 105.8020),
      ];

      final payload = {
        'routes': [
          {
            'overview_polyline': {'points': encodePoly(overview)},
            'legs': [
              {
                'distance': {'value': 350},
                'duration': {'value': 60},
                'summary': '',
                'steps': [
                  {
                    'html_instructions': 'Đi thẳng trên <b>Quốc Lộ 6</b>',
                    'distance': {'value': 180},
                    'duration': {'value': 30},
                    'maneuver': 'depart',
                    'start_location': {'lat': 21.0000, 'lng': 105.8000},
                    'polyline': {'points': encodePoly(step1)},
                  },
                  {
                    'html_instructions': 'Rẽ phải vào <b>Quang Trung</b>',
                    'distance': {'value': 170},
                    'duration': {'value': 30},
                    'maneuver': 'turn-right',
                    'start_location': {'lat': 21.0010, 'lng': 105.8006},
                    'polyline': {'points': encodePoly(step2)},
                  },
                ],
              },
            ],
          },
        ],
      };

      final routes = GoongService.parseDirectionResponse(
        payload,
        fallbackStart: overview.first,
        vehicle: 'bike',
      );
      expect(routes, hasLength(1));
      // 3 + 3 - 1 deduplicated junction = 5 detailed vertices (NOT 2 coarse overview points)
      expect(routes.first.polylinePoints.length, 5);
      expect(routes.first.summary.toLowerCase().contains('goong'), isFalse);
    });
  });
}
