import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile_app/models/esp_payload.dart';
import 'package:mobile_app/models/route_model.dart';
import 'package:mobile_app/services/ble_service.dart';
import 'package:mobile_app/services/navigation_manager.dart';
import 'package:mobile_app/services/route_geometry.dart';
import 'package:mobile_app/services/voice_guidance_service.dart';

class FakeBleService extends BleService {
  EspNavPayload? lastPayload;

  @override
  bool get isConnected => true;

  @override
  Future<bool> sendNavPayload(EspNavPayload payload) async {
    lastPayload = payload;
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('P5.9.5 Arrival Confirmation & Single Source of Truth Tests', () {
    late NavigationManager navManager;
    late FakeBleService bleService;
    late NavRoute testRoute;
    late LatLng pStart;
    late LatLng pMid;
    late LatLng pDest;

    setUp(() {
      bleService = FakeBleService();
      navManager = NavigationManager(bleService: bleService);
      VoiceGuidanceService().resetNavigation();

      // Route setup:
      // East-West straight line at latitude 21.00000
      // At lat 21.0, 1 deg lon is ~103,900 m (1m ~ 0.000009624 deg)
      pStart = const LatLng(21.00000, 105.80000); // 0m
      pMid = const LatLng(21.00000, 105.80100);   // ~104m
      pDest = const LatLng(21.00000, 105.80200);  // ~208m total

      final polyline = [pStart, pMid, pDest];
      final geom = RouteGeometry(polyline);
      final totalDist = geom.totalDistanceMeters;

      testRoute = NavRoute(
        totalDistanceMeters: totalDist,
        totalDurationSeconds: 120.0,
        polylinePoints: polyline,
        steps: [
          NavStep(
            stepIndex: 0,
            instruction: 'Đi thẳng trên Đường Thử Nghiệm',
            streetName: 'Đường Thử Nghiệm',
            distanceMeters: totalDist / 2,
            durationSeconds: 60.0,
            coordinate: pStart,
            maneuverTypeStr: 'depart',
            beginShapeIndex: 0,
            endShapeIndex: 1,
          ),
          NavStep(
            stepIndex: 1,
            instruction: 'Bạn đã tới nơi.',
            streetName: '',
            distanceMeters: totalDist / 2,
            durationSeconds: 60.0,
            coordinate: pDest,
            maneuverTypeStr: 'arrive',
            beginShapeIndex: 1,
            endShapeIndex: 2,
          ),
        ],
        summary: 'Điểm Đến Mẫu',
      );
    });

    tearDown(() {
      navManager.dispose();
      VoiceGuidanceService().resetNavigation();
    });

    test('1. Field regression case (86 meters): Upcoming arrive maneuver must NOT say "Bạn đã tới nơi."', () {
      navManager.startNavigation(testRoute);

      // Total route is ~208m. Target position ~86m from destination.
      // Progress is ~122m along route.
      // 122m / 103900m ~ 0.001174 deg longitude
      final p86m = LatLng(21.00000, 105.80000 + 0.001174);
      final physDist = RouteGeometry.distanceBetween(p86m, pDest);
      expect(physDist, closeTo(86.0, 5.0));

      navManager.updateUserPositionWithAccuracy(
        p86m,
        30.0,
        90.0,
        horizontalAccuracy: 5.0,
      );
      navManager.sendPreviewPayloadToEsp32();

      // Verify authoritative current maneuver is the upcoming arrive step
      expect(navManager.authoritativeCurrentManeuver?.maneuverType, equals(ManeuverType.arrive));

      // Arrival state must be FALSE
      expect(navManager.hasArrived, isFalse);
      expect(navManager.arrivalCandidateSamples, equals(0));

      // Banner must NOT display raw "Bạn đã tới nơi." when 86m away!
      expect(navManager.bannerInstruction, equals('Điểm đến ở phía trước'));
      expect(navManager.bannerInstruction, isNot(contains('Bạn đã tới nơi')));

      // Voice guidance must NOT announce arrival
      expect(VoiceGuidanceService().lastSpokenText, isNot(contains('hoàn tất')));
      expect(VoiceGuidanceService().lastSpokenText, isNot(contains('Bạn đã đến điểm đến')));

      // ESP32 payload must contain remaining distance and destination-ahead semantics
      expect(bleService.lastPayload, isNotNull);
      expect(bleService.lastPayload!.distanceToTurn, closeTo(86, 5));
      expect(bleService.lastPayload!.streetName, equals('Điểm đến ở phía trước'));
      expect(bleService.lastPayload!.streetName, isNot(contains('Bạn đã tới nơi')));
    });

    test('2. Approaching destination (35 meters): Approaching voice allowed, but announceArrival NOT called', () {
      navManager.startNavigation(testRoute);

      // ~35m from destination: progress ~173m
      final p35m = LatLng(21.00000, 105.80000 + 0.001665);
      final physDist = RouteGeometry.distanceBetween(p35m, pDest);
      expect(physDist, closeTo(35.0, 4.0));

      navManager.updateUserPositionWithAccuracy(
        p35m,
        20.0,
        90.0,
        horizontalAccuracy: 5.0,
      );

      expect(navManager.hasArrived, isFalse);
      expect(navManager.arrivalCandidateSamples, equals(0));
      expect(navManager.bannerInstruction, equals('Điểm đến ở phía trước'));

      // Check proximity announcement (15-45m trigger)
      final arriveStep = testRoute.steps[1];
      VoiceGuidanceService().checkAndAnnounceManeuver(
        step: arriveStep,
        distanceMeters: navManager.distanceToNextManeuver,
        stepIndex: 1,
      );

      expect(VoiceGuidanceService().lastSpokenText, equals('Điểm đến ở ngay phía trước.'));
      expect(VoiceGuidanceService().lastSpokenText, isNot(contains('hoàn tất')));
      expect(navManager.hasArrived, isFalse);
    });

    test('3. True arrival: Multi-condition check + 2 consecutive samples confirms arrival & single voice announcement', () {
      navManager.startNavigation(testRoute);

      // ~7m from destination (well within 20m threshold)
      final p7m = LatLng(21.00000, 105.80000 + 0.001934);
      final physDist = RouteGeometry.distanceBetween(p7m, pDest);
      expect(physDist, closeTo(7.0, 2.0));

      // First sample inside arrival zone
      navManager.updateUserPositionWithAccuracy(
        p7m,
        5.0,
        90.0,
        horizontalAccuracy: 5.0,
      );

      // Sample 1: candidate count = 1, but hasArrived still false (stability gate!)
      expect(navManager.arrivalCandidateSamples, equals(1));
      expect(navManager.hasArrived, isFalse);
      expect(navManager.bannerInstruction, equals('Điểm đến ở phía trước'));

      // Second sample inside arrival zone
      navManager.updateUserPositionWithAccuracy(
        p7m,
        2.0,
        90.0,
        horizontalAccuracy: 5.0,
      );

      // Sample 2: confirmed arrival!
      expect(navManager.arrivalCandidateSamples, greaterThanOrEqualTo(2));
      expect(navManager.hasArrived, isTrue);
      expect(navManager.bannerInstruction, equals('Bạn đã tới nơi.'));
      expect(VoiceGuidanceService().lastSpokenText, contains('Bạn đã đến điểm đến'));
      expect(VoiceGuidanceService().lastSpokenText, contains('hoàn tất'));

      // Remaining distance snaps to 0 upon arrival
      expect(navManager.remainingTotalDistance, equals(0.0));
      expect(navManager.distanceToNextManeuver, equals(0.0));

      // Third sample: verify no duplicate announcement
      final spokenBefore = VoiceGuidanceService().lastSpokenText;
      navManager.updateUserPositionWithAccuracy(
        p7m,
        0.0,
        90.0,
        horizontalAccuracy: 5.0,
      );
      expect(navManager.hasArrived, isTrue);
      expect(VoiceGuidanceService().lastSpokenText, equals(spokenBefore));
    });

    test('4. GPS noise reset: Candidate sample counter resets if distance spikes', () {
      navManager.startNavigation(testRoute);

      // Sample 1: valid candidate ~10m from dest
      final p10m = LatLng(21.00000, 105.80000 + 0.001905);
      navManager.updateUserPositionWithAccuracy(
        p10m,
        5.0,
        90.0,
        horizontalAccuracy: 5.0,
      );
      expect(navManager.arrivalCandidateSamples, equals(1));
      expect(navManager.hasArrived, isFalse);

      // Sample 2: GPS spike / jitter to 45m away
      final p45m = LatLng(21.00000, 105.80000 + 0.001568);
      navManager.updateUserPositionWithAccuracy(
        p45m,
        25.0,
        90.0,
        horizontalAccuracy: 8.0,
      );

      // Counter must reset back to 0, arrival rejected
      expect(navManager.arrivalCandidateSamples, equals(0));
      expect(navManager.hasArrived, isFalse);
      expect(navManager.bannerInstruction, equals('Điểm đến ở phía trước'));
    });

    test('5. Matched projection false-positive rejection: Physical GPS distance gates arrival', () {
      navManager.startNavigation(testRoute);

      // Physical location is 70m away
      final p70m = LatLng(21.00000, 105.80000 + 0.001328);
      final physDist = RouteGeometry.distanceBetween(p70m, pDest);
      expect(physDist, closeTo(70.0, 5.0));

      navManager.updateUserPositionWithAccuracy(
        p70m,
        15.0,
        90.0,
        horizontalAccuracy: 5.0,
      );

      // Even if matched projection is close to end of segment, physical GPS gates arrival
      expect(navManager.physicalDistanceToDestination, closeTo(70.0, 5.0));
      expect(navManager.hasArrived, isFalse);
      expect(navManager.arrivalCandidateSamples, equals(0));
      expect(navManager.bannerInstruction, equals('Điểm đến ở phía trước'));
    });

    test('6. Reroute and restart clears arrival state cleanly', () {
      navManager.startNavigation(testRoute);

      // Force arrival
      final pDestClose = LatLng(21.00000, 105.80000 + 0.001934);
      navManager.updateUserPositionWithAccuracy(pDestClose, 2.0, 90.0, horizontalAccuracy: 5.0);
      navManager.updateUserPositionWithAccuracy(pDestClose, 2.0, 90.0, horizontalAccuracy: 5.0);
      expect(navManager.hasArrived, isTrue);

      // Restarting navigation clears arrival state
      navManager.startNavigation(testRoute);
      expect(navManager.hasArrived, isFalse);
      expect(navManager.arrivalCandidateSamples, equals(0));

      // Stopping navigation clears arrival state
      navManager.stopNavigation();
      expect(navManager.hasArrived, isFalse);
      expect(navManager.arrivalCandidateSamples, equals(0));
    });

    test('7. ESP32 BLE Payload semantics before vs after arrival', () {
      navManager.startNavigation(testRoute);

      final now = DateTime(2026, 9, 23, 12, 0, 0);

      // Before arrival (at 86m)
      final p86m = LatLng(21.00000, 105.80000 + 0.001174);
      navManager.updateUserPositionWithAccuracy(p86m, 25.0, 90.0, horizontalAccuracy: 5.0, timestamp: now);
      navManager.sendPreviewPayloadToEsp32();

      expect(bleService.lastPayload, isNotNull);
      expect(bleService.lastPayload!.distanceToTurn, closeTo(86, 5));
      expect(bleService.lastPayload!.streetName, equals('Điểm đến ở phía trước'));

      // Confirm arrival (2 consecutive samples at 7m, 8 seconds later)
      final p7m = LatLng(21.00000, 105.80000 + 0.001934);
      navManager.updateUserPositionWithAccuracy(p7m, 10.0, 90.0, horizontalAccuracy: 5.0, timestamp: now.add(const Duration(seconds: 8)));
      navManager.updateUserPositionWithAccuracy(p7m, 2.0, 90.0, horizontalAccuracy: 5.0, timestamp: now.add(const Duration(seconds: 9)));

      expect(navManager.hasArrived, isTrue);
      expect(bleService.lastPayload!.distanceToTurn, equals(0));
      expect(bleService.lastPayload!.streetName, equals('Bạn đã tới nơi.'));
    });
  });
}
