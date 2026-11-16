import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobile_app/screens/map_screen.dart';
import 'package:mobile_app/services/ble_service.dart';
import 'package:mobile_app/services/esp_stream_service.dart';
import 'package:mobile_app/services/google_maps_relay_service.dart';
import 'package:mobile_app/services/navigation_manager.dart';
import 'package:mobile_app/services/osm_road_guide_matcher.dart';
import 'package:mobile_app/services/osm_vector_tile.dart';
import 'package:mobile_app/services/phone_media_service.dart';

class _RecordingBleService extends BleService {
  final List<String> sentPayloads = [];

  @override
  bool get isConnected => true;

  @override
  Future<bool> sendNavPayload(payload) async {
    sentPayloads.add(payload.toJsonString());
    return true;
  }

  @override
  Future<bool> sendRawString(String text) async {
    sentPayloads.add(text);
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Android Location Arrow Pixel-to-DP Conversion', () {
    test('Divides MapLibre Android physical pixels by devicePixelRatio so puck stays on screen', () {
      // On a 1080x2400 Android display with DPR 2.75, 1/3-bottom center (~196dp x ~567dp)
      // is returned by MapLibre Projection.toScreenLocation as (~540px, ~1560px).
      final logical = MapScreen.screenPointToLogicalOffset(
        540.0,
        1560.0,
        devicePixelRatio: 2.75,
        isAndroid: true,
      );
      expect(logical.dx, closeTo(196.36, 0.1));
      expect(logical.dy, closeTo(567.27, 0.1));

      // Non-Android platforms keep logical coordinates 1:1.
      final iosLogical = MapScreen.screenPointToLogicalOffset(
        196.0,
        567.0,
        devicePixelRatio: 3.0,
        isAndroid: false,
      );
      expect(iosLogical.dx, closeTo(196.0, 0.01));
      expect(iosLogical.dy, closeTo(567.0, 0.01));
    });
  });

  group('Google Maps Notification Parser (maisonsmd/esp32-google-maps style)', () {
    test('Parses Vietnamese Google Maps banner with comma decimals and arrow bitmap hint', () {
      final snap = GoogleMapsRelayService.parseNotificationPayload({
        'title': 'Trong 52 m',
        'text': 'Đi từ Đường ven sông Lừ',
        'subText': '22 phút · 7,3 km · 02:45',
        'bitmapTurnCode': 2,
      });

      expect(snap, isNotNull);
      expect(snap!.distanceToTurn, 52);
      expect(snap.streetName, 'Đường ven sông Lừ');
      expect(snap.etaMinutes, 22);
      expect(snap.totalDistance, 7300);
      expect(snap.arrivalTime, '02:45');
      expect(snap.turnCode, 2);
    });

    test('Parses RemoteViews multi-line Vietnamese guidance and strips action button labels', () {
      final snap = GoogleMapsRelayService.parseNotificationPayload({
        'title': '',
        'text': '',
        'texts': [
          '150 m',
          'Rẽ phải vào Phạm Hùng',
          '1 giờ 7 phút · 32 km · 22:42',
          'Thoát điều hướng',
          'Tắt tiếng',
        ],
        'bitmapTurnCode': 0,
      });

      expect(snap, isNotNull);
      expect(snap!.turnCode, 2); // Text "Rẽ phải" overrides bitmap hint if clearer
      expect(snap.distanceToTurn, 150);
      expect(snap.streetName, 'Phạm Hùng');
      expect(snap.etaMinutes, 67);
      expect(snap.totalDistance, 32000);
      expect(snap.arrivalTime, '22:42');
    });

    test('Parses English imperial/metric Google Maps notifications cleanly', () {
      final snap = GoogleMapsRelayService.parseNotificationPayload({
        'title': 'In 350 ft',
        'text': 'Turn left onto Broadway',
        'subText': '12 min (4.5 mi) · 6:30 PM',
        'bitmapTurnCode': -1,
      });

      expect(snap, isNotNull);
      expect(snap!.turnCode, 6);
      expect(snap.distanceToTurn, closeTo(107, 1));
      expect(snap.streetName, 'Broadway');
      expect(snap.etaMinutes, 12);
      expect(snap.totalDistance, closeTo(7242, 5));
      expect(snap.arrivalTime, '18:30');
    });

    test('Recognizes roundabout, U-turn, arrival, and ignores filler notifications', () {
      final roundabout = GoogleMapsRelayService.parseNotificationPayload({
        'title': '300 m',
        'text': 'Vào vòng xuyến Dân Chủ',
        'subText': '5 phút · 1,5 km',
        'bitmapTurnCode': -1,
      });
      expect(roundabout?.turnCode, 8);

      final uturn = GoogleMapsRelayService.parseNotificationPayload({
        'title': '80 m',
        'text': 'Quay đầu tại ngã tư',
        'subText': '3 phút · 800 m',
        'bitmapTurnCode': -1,
      });
      expect(uturn?.turnCode, 4);

      final arrived = GoogleMapsRelayService.parseNotificationPayload({
        'title': 'Bạn đã đến nơi',
        'text': '157 Nguyễn Cảnh Dị',
        'bitmapTurnCode': -1,
      });
      expect(arrived?.turnCode, 9);

      final filler = GoogleMapsRelayService.parseNotificationPayload({
        'title': 'Google Maps',
        'text': 'Đang tìm GPS',
        'bitmapTurnCode': -1,
      });
      expect(filler, isNull);
    });
  });

  group('GoogleMapsRelayService Man 3 Streaming & BLE Fallback Orchestration', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('Streams 320x216 Man 3 map with Google Maps HUD by default and supports BLE-only Man 2 switch', () async {
      final ble = _RecordingBleService();
      final media = PhoneMediaService();
      final nav = NavigationManager(bleService: ble, mediaService: media);
      final stream = EspStreamService(bleService: ble, navManager: nav);
      final relay = GoogleMapsRelayService(
        bleService: ble,
        navManager: nav,
        streamService: stream,
        mediaService: media,
      );

      nav.debugSetTelemetryKinematics(
        location: const LatLng(21.0285, 105.8542),
        headingDeg: 0.0,
        speedKmh: 38.0,
      );

      await relay.setEnabled(true, checkPermission: false);
      expect(relay.isEnabled, isTrue);
      expect(relay.streamMapEnabled, isTrue);
      expect(stream.isBleOnlyNavMode, isFalse);
      expect(stream.isStreaming, isTrue);
      expect(nav.isExternalBleNavMode, isTrue);
      expect(nav.isAnyNavActive, isFalse);
      // Waiting for Google Maps notification -> Standby Man 1 (144x224)
      expect(stream.debugTargetRenderWidth, 144);
      expect(stream.debugTargetRenderHeight, 224);

      ble.sentPayloads.clear();
      relay.handleRawNotificationMap({
        'title': 'Trong 120 m',
        'text': 'Rẽ trái vào Lê Lợi',
        'subText': '8 phút · 2,4 km · 14:40',
        'bitmapTurnCode': 6,
      });

      expect(relay.hasActiveNav, isTrue);
      expect(nav.isAnyNavActive, isTrue);
      expect(stream.isStreaming, isTrue);
      // Switches automatically to Man 3 fullscreen navigation frame size + HUD + guide polyline
      expect(stream.debugIsNavFrameMode, isTrue);
      expect(stream.debugTargetRenderWidth, 320);
      expect(stream.debugTargetRenderHeight, 216);

      final hud = stream.debugCurrentNavHudSnapshot;
      expect(hud['turnCode'], 6);
      expect(hud['distStr'], '120 m');
      expect(hud['nextStreet'], 'Lê Lợi');
      expect(hud['etaText'], '8 phút');
      expect(hud['arrStr'], '14:40');
      expect(hud['totDistStr'], '2.4 km');
      expect(hud['speedStr'], '38');

      // Streamed Google Maps frame draws zero synthetic/matched route line by design ("không cần vẽ nữa")
      final routePts = stream.debugEffectiveRoutePoints;
      expect(routePts, isEmpty);

      // Also keeps BLE telemetry updated in sync (supports instant Man 2 fallback if Wi-Fi drops)
      expect(ble.sentPayloads, isNotEmpty);
      final json = jsonDecode(ble.sentPayloads.last) as Map<String, dynamic>;
      expect(json['nav'], 1);
      expect(json['turn'], 6);
      expect(json['dist'], 120);
      expect(json['tot'], 2400);
      expect(json['eta'], 8);
      expect(json['street'], 'Lê Lợi');

      // Optional switch to BLE-only Man 2 mode stops Wi-Fi stream cleanly
      relay.setStreamMapEnabled(false);
      expect(relay.streamMapEnabled, isFalse);
      expect(stream.isBleOnlyNavMode, isTrue);
      expect(stream.isStreaming, isFalse);

      // Switching back to Stream resumes Man 3 streaming cleanly
      relay.setStreamMapEnabled(true);
      expect(relay.streamMapEnabled, isTrue);
      expect(stream.isBleOnlyNavMode, isFalse);
      expect(stream.isStreaming, isTrue);

      // Navigation ended restores Standby Man 1 (144x224) + idle BLE + RESTORE_IDLE_MAP
      ble.sentPayloads.clear();
      relay.handleNavigationEnded();
      expect(relay.hasActiveNav, isFalse);
      expect(nav.isAnyNavActive, isFalse);
      expect(stream.debugTargetRenderWidth, 144);
      expect(stream.debugTargetRenderHeight, 224);
      expect(
        ble.sentPayloads.any((s) => s.contains('"RESTORE_IDLE_MAP"')),
        isTrue,
      );

      // Re-receiving active nav then turning OFF directly also restores idle ESP32 + sends RESTORE_IDLE_MAP
      relay.handleRawNotificationMap({
        'title': 'Trong 50 m',
        'text': 'Đi thẳng qua Nguyễn Trãi',
        'subText': '2 phút · 500 m',
        'bitmapTurnCode': 0,
      });
      expect(relay.hasActiveNav, isTrue);

      ble.sentPayloads.clear();
      await relay.setEnabled(false);
      expect(relay.isEnabled, isFalse);
      expect(relay.hasActiveNav, isFalse);
      expect(stream.isBleOnlyNavMode, isFalse);
      expect(nav.isExternalBleNavMode, isFalse);
      expect(
        ble.sentPayloads.any((s) => s.contains('"nav":0') && s.contains('"street":"Sẵn sàng"')),
        isTrue,
      );
      expect(
        ble.sentPayloads.any((s) => s.contains('"RESTORE_IDLE_MAP"')),
        isTrue,
      );

      relay.dispose();
      stream.dispose();
      nav.dispose();
      media.dispose();
    });

    test('Synthesizes accurate local maneuver preview geometry across turn types', () {
      const origin = LatLng(21.0285, 105.8542);

      // Distant turn (>240m): capped straight guide line ahead along heading (North)
      final distant = NavigationManager.computeExternalTurnPreviewPolyline(
        origin: origin,
        headingDeg: 0.0,
        distanceMeters: 900.0,
        turnCode: 2,
      );
      expect(distant.length, 2);
      expect(distant.last.latitude, greaterThan(origin.latitude));

      // Right turn (turnCode 2) within 80m heading North -> bends East (higher longitude)
      final rightTurn = NavigationManager.computeExternalTurnPreviewPolyline(
        origin: origin,
        headingDeg: 0.0,
        distanceMeters: 80.0,
        turnCode: 2,
      );
      expect(rightTurn.length, 3);
      expect(rightTurn[2].longitude, greaterThan(rightTurn[1].longitude));

      // U-turn (turnCode 5) & Roundabout (turnCode 9) produce multi-point curves
      final uturn = NavigationManager.computeExternalTurnPreviewPolyline(
        origin: origin,
        headingDeg: 90.0,
        distanceMeters: 60.0,
        turnCode: 5,
      );
      expect(uturn.length, 4);

      final roundabout = NavigationManager.computeExternalTurnPreviewPolyline(
        origin: origin,
        headingDeg: 0.0,
        distanceMeters: 70.0,
        turnCode: 9,
      );
      expect(roundabout.length, 5);
    });
  });

  group('Vietnamese Voice Instruction Localization & Fallback GPS Speed', () {
    test('Translates English Goong/Google direction instructions into Vietnamese cleanly', () {
      expect(
        NavigationManager.localizeInstructionToVietnamese('Turn right onto Nguyễn Trãi'),
        'Rẽ phải vào Nguyễn Trãi',
      );
      expect(
        NavigationManager.localizeInstructionToVietnamese('Head southeast on Đường Láng toward Thái Hà'),
        'Đi theo Đường Láng về hướng Thái Hà',
      );
      expect(
        NavigationManager.localizeInstructionToVietnamese('Turn left toward Giải Phóng'),
        'Rẽ trái về hướng Giải Phóng',
      );
      expect(
        NavigationManager.localizeInstructionToVietnamese('Make a U-turn at Ngã Tư Sở'),
        'Quay đầu xe tại Ngã Tư Sở',
      );
      expect(
        NavigationManager.localizeInstructionToVietnamese('At the roundabout, take the 2nd exit onto Phạm Hùng'),
        'Vào vòng xuyến, đi theo lối ra thứ 2 vào Phạm Hùng',
      );
      expect(
        NavigationManager.localizeInstructionToVietnamese('Destination will be on the right'),
        'Điểm đến sẽ nằm ở bên phải',
      );
      expect(
        NavigationManager.localizeInstructionToVietnamese('Còn 150 mét, rẽ phải vào Nguyễn Trãi'),
        'Còn 150 mét, rẽ phải vào Nguyễn Trãi',
      );
    });

    test('Computes GPS delta speed fallback when Android omits instantaneous pos.speed', () {
      expect(
        NavigationManager.computeFallbackSpeedKmh(
          reportedSpeedMs: 10.0,
          prevLoc: null,
          prevTime: null,
          newLoc: const LatLng(21.0285, 105.8542),
          newTime: DateTime.now(),
          accuracyM: 8.0,
        ),
        closeTo(36.0, 0.01),
      );

      final t0 = DateTime(2026, 11, 16, 13, 30, 0);
      final t1 = DateTime(2026, 11, 16, 13, 30, 4);
      final movedKmh = NavigationManager.computeFallbackSpeedKmh(
        reportedSpeedMs: 0.0,
        prevLoc: const LatLng(21.0000, 105.8500),
        prevTime: t0,
        newLoc: const LatLng(21.00036, 105.8500), // ~40m north in 4s -> ~36 km/h
        newTime: t1,
        accuracyM: 8.0,
      );
      expect(movedKmh, closeTo(36.0, 1.5));

      // Stationary GPS drift (~1.1m) must stay 0 km/h
      final jitterKmh = NavigationManager.computeFallbackSpeedKmh(
        reportedSpeedMs: 0.0,
        prevLoc: const LatLng(21.0000, 105.8500),
        prevTime: t0,
        newLoc: const LatLng(21.00001, 105.8500),
        newTime: t1,
        accuracyM: 12.0,
      );
      expect(jitterKmh, 0.0);
    });
  });

  group('External Heading Stabilization & OSM Road-Hugging Guide Matcher', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('Rejects stationary/low-speed GPS bearing noise, locks course on real motion, and dampens spikes', () {
      const baseLoc = LatLng(21.0285, 105.8542);

      // 1. Low-speed noisy sensor bearing (2.5 km/h) -> ignored cleanly, no unlock spin
      final idleNoise = NavigationManager.resolveReliableExternalHeading(
        currentSmoothedHeading: 0.0,
        currentHasHeadingLock: false,
        rawSensorHeading: 147.0,
        hasSensorHeading: true,
        speedKmh: 2.5,
        accuracyM: 8.0,
        prevCourseOrigin: baseLoc,
        incomingLocation: baseLoc,
      );
      expect(idleNoise.hasHeadingLock, isFalse);
      expect(idleNoise.smoothedHeading, 0.0);

      // 2. Real displacement >= 7.5m East (~15m) even with invalid sensor heading -> locks East (~90 deg)
      const movedEast = LatLng(21.0285, 105.85435);
      final movedState = NavigationManager.resolveReliableExternalHeading(
        currentSmoothedHeading: idleNoise.smoothedHeading,
        currentHasHeadingLock: idleNoise.hasHeadingLock,
        rawSensorHeading: -1.0,
        hasSensorHeading: false,
        speedKmh: 16.0,
        accuracyM: 6.0,
        prevCourseOrigin: idleNoise.nextCourseOrigin,
        incomingLocation: movedEast,
      );
      expect(movedState.hasHeadingLock, isTrue);
      expect(movedState.smoothedHeading, closeTo(90.0, 3.0));

      // 3. Micro-wobble (93 deg at 9 km/h) stays deadband-locked at exact previous heading
      final wobble = NavigationManager.resolveReliableExternalHeading(
        currentSmoothedHeading: 90.0,
        currentHasHeadingLock: true,
        rawSensorHeading: 93.2,
        hasSensorHeading: true,
        speedKmh: 9.0,
        accuracyM: 8.0,
        prevCourseOrigin: movedEast,
        incomingLocation: movedEast,
      );
      expect(wobble.smoothedHeading, 90.0);

      // 4. Slow outlier jump (230 deg at 8 km/h without displacement) is damped to <= 4.5 deg step
      final outlier = NavigationManager.resolveReliableExternalHeading(
        currentSmoothedHeading: 90.0,
        currentHasHeadingLock: true,
        rawSensorHeading: 230.0,
        hasSensorHeading: true,
        speedKmh: 8.0,
        accuracyM: 12.0,
        prevCourseOrigin: movedEast,
        incomingLocation: movedEast,
      );
      final step = ((outlier.smoothedHeading - 90.0 + 540.0) % 360.0) - 180.0;
      expect(step.abs(), lessThanOrEqualTo(4.51));

      // 5. Real driving speed turn (180 deg South turn at 22 km/h) tracks prompt target immediately
      final turning = NavigationManager.resolveReliableExternalHeading(
        currentSmoothedHeading: 90.0,
        currentHasHeadingLock: true,
        rawSensorHeading: 180.0,
        hasSensorHeading: true,
        speedKmh: 22.0,
        accuracyM: 6.0,
        prevCourseOrigin: movedEast,
        incomingLocation: movedEast,
      );
      expect(turning.targetHeading, 180.0);
      expect(turning.smoothedHeading, greaterThan(120.0));
    });

    test('Snaps heading and traces Google Maps left turn directly onto real OSM road geometry', () {
      const origin = LatLng(21.0285, 105.8542);
      const z = 15;
      const n15 = 32768.0;
      final latRad = origin.latitude * (math.pi / 180.0);
      final ux15 = (origin.longitude + 180.0) / 360.0 * n15;
      final uy15 =
          (1.0 - (math.log(math.tan(latRad) + 1.0 / math.cos(latRad)) / math.pi)) / 2.0 * n15;
      final tx = ux15.floor();
      final ty = uy15.floor();
      final normUx = ux15 - tx;
      final normUy = uy15 - ty;

      // 1 meter in tile z=15 normalized coords (~1142 meters per z=15 tile at lat 21)
      const double m2Norm = 1.0 / 1142.0;

      // Diagonal Northeast street tilted ~20 degrees from North through user position
      final double bRad = 20.0 * (math.pi / 180.0);
      final double dirX = math.sin(bRad);
      final double dirY = -math.cos(bRad);

      final double s0x = normUx - dirX * 40.0 * m2Norm;
      final double s0y = normUy - dirY * 40.0 * m2Norm;
      final double jx = normUx + dirX * 100.0 * m2Norm;
      final double jy = normUy + dirY * 100.0 * m2Norm;
      final double s2x = normUx + dirX * 180.0 * m2Norm;
      final double s2y = normUy + dirY * 180.0 * m2Norm;

      // Cross street branching LEFT (-90 deg from 20 deg => 290 deg = West-Northwest) at ~100m ahead
      final double leftRad = -70.0 * (math.pi / 180.0);
      final double lEndX = jx + math.sin(leftRad) * 90.0 * m2Norm;
      final double lEndY = jy - math.cos(leftRad) * 90.0 * m2Norm;
      final double rEndX = jx - math.sin(leftRad) * 90.0 * m2Norm;
      final double rEndY = jy + math.cos(leftRad) * 90.0 * m2Norm;

      final mainPts = Float32List.fromList([s0x, s0y, jx, jy, s2x, s2y]);
      final crossPts = Float32List.fromList([rEndX, rEndY, jx, jy, lEndX, lEndY]);

      OsmRoad makeRoad(Float32List pts, int tier) {
        double minX = 1.0, minY = 1.0, maxX = 0.0, maxY = 0.0;
        for (int i = 0; i < pts.length; i += 2) {
          minX = math.min(minX, pts[i]);
          maxX = math.max(maxX, pts[i]);
          minY = math.min(minY, pts[i + 1]);
          maxY = math.max(maxY, pts[i + 1]);
        }
        return OsmRoad(
          pts: pts,
          minX: minX,
          minY: minY,
          maxX: maxX,
          maxY: maxY,
          tier: tier,
          isBridge: false,
        );
      }

      final tile = OsmVectorTile(
        z: z,
        x: tx,
        y: ty,
        areas: const [],
        roads: [makeRoad(mainPts, 3), makeRoad(crossPts, 2)],
        buildings: const [],
        roadLabels: [
          OsmRoadLabel(
            name: 'Đường Lê Lợi',
            midX: (jx + lEndX) * 0.5,
            midY: (jy + lEndY) * 0.5,
            dirX: math.sin(leftRad),
            dirY: -math.cos(leftRad),
            tier: 2,
          ),
        ],
      );

      // Even with slightly skewed GPS heading (32 deg vs real 20 deg street), snaps heading to ~20 deg
      // AND turns cleanly onto the real LEFT intersection branch ("Lê Lợi")!
      final match = OsmRoadGuideMatcher.matchAndTrace(
        tiles: [tile],
        userPos: origin,
        displayZoom: 17,
        rawHeadingDeg: 32.0,
        hasHeadingLock: true,
        turnCode: 6, // left turn
        distanceToTurnMeters: 108.0, // close enough to real junction at 100m
        nextStreetName: 'Lê Lợi',
      );
      expect(match.matchedRoad, isTrue);
      expect(match.usedIntersectionBranch, isTrue);
      expect(match.snappedHeadingDeg, isNotNull);
      expect(OsmRoadGuideMatcher.absAngleDiffDeg(match.snappedHeadingDeg!, 20.0), lessThan(4.0));
      expect(match.guidePolyline.length, greaterThanOrEqualTo(3));
      // Branch turned West (longitude of last point < junction longitude)
      expect(match.guidePolyline.last.longitude, lessThan(match.guidePolyline[1].longitude));

      // Also verify stationary two-way street (hasHeadingLock: false, skewed rawHeadingDeg: 0.0)
      // resolves the correct road axis AND direction toward the left turn intersection!
      final stationaryMatch = OsmRoadGuideMatcher.matchAndTrace(
        tiles: [tile],
        userPos: origin,
        displayZoom: 17,
        rawHeadingDeg: 0.0,
        hasHeadingLock: false,
        turnCode: 6,
        distanceToTurnMeters: 100.0,
        nextStreetName: 'Lê Lợi',
      );
      expect(stationaryMatch.matchedRoad, isTrue);
      expect(stationaryMatch.usedIntersectionBranch, isTrue);
      expect(
        OsmRoadGuideMatcher.absAngleDiffDeg(stationaryMatch.snappedHeadingDeg!, 20.0),
        lessThan(4.0),
      );

      // Verify EspStreamService temporal stabilizer + integration returns snapped guided pose
      final ble = _RecordingBleService();
      final media = PhoneMediaService();
      final nav = NavigationManager(bleService: ble, mediaService: media);
      final stream = EspStreamService(bleService: ble, navManager: nav);
      nav.debugSetTelemetryKinematics(location: origin, headingDeg: 30.0, speedKmh: 15.0);
      nav.setExternalBleNavActive(
        true,
        hasActiveNav: true,
        turnCode: 6,
        distanceToTurn: 105.0,
        totalDistance: 1200.0,
        etaMinutes: 4,
        streetName: 'Lê Lợi',
      );
      final resolved = stream.debugResolveExternalGuidedPose(
        userPos: origin,
        displayZoom: 17,
        rawHeadingDeg: 30.0,
        tilesOverride: [tile],
      );
      expect(resolved.matchedRoad, isTrue);
      // With live motion lock, follows travel bearing cleanly while mildly damping <14 deg skew
      expect(OsmRoadGuideMatcher.absAngleDiffDeg(resolved.headingDeg, 26.5), lessThan(4.0));
      // When turning >14 deg off street (e.g. 90 deg corner at 110 deg), tracks turn target directly!
      nav.debugSetTelemetryKinematics(location: origin, headingDeg: 110.0, speedKmh: 25.0);
      final cornering = stream.debugResolveExternalGuidedPose(
        userPos: origin,
        displayZoom: 17,
        rawHeadingDeg: 110.0,
        tilesOverride: [tile],
      );
      expect(cornering.headingDeg, greaterThan(45.0));
      // No route polyline drawn in Google Maps stream mode, while camera heading remains road-stabilized
      expect(resolved.pts, isEmpty);

      stream.dispose();
      nav.dispose();
      media.dispose();
    });

    test('Parses 1.0km U-turn / 1h21m / 31km Google Maps notification and mixed Vietnamese TTS cleanly', () {
      final snap = GoogleMapsRelayService.parseNotificationPayload({
        'title': 'Trong 1,0 km',
        'text': 'Nguyễn Hữu Thọ',
        'subText': '1 giờ 21 phút · 31 km · 16:41',
        'bitmapTurnCode': 4,
      });
      expect(snap, isNotNull);
      expect(snap!.turnCode, 4); // U-turn
      expect(snap.distanceToTurn, 1000);
      expect(snap.totalDistance, 31000);
      expect(snap.etaMinutes, 81);
      expect(snap.arrivalTime, '16:41');
      expect(snap.streetName, 'Nguyễn Hữu Thọ');

      expect(
        NavigationManager.localizeInstructionToVietnamese(
          'In 200 m, turn right onto Nguyễn Trãi',
        ),
        'Trong 200 mét, Rẽ phải vào Nguyễn Trãi',
      );
      expect(
        NavigationManager.localizeInstructionToVietnamese(
          'Go straight onto Phố Huế',
        ),
        'Đi thẳng theo Phố Huế',
      );
      expect(
        NavigationManager.localizeInstructionToVietnamese(
          'Take exit 2 onto Đường Láng',
        ),
        'Đi vào lối ra vào Đường Láng',
      );
    });
  });
}

