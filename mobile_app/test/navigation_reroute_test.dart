import 'package:mobile_app/services/route_render_controller.dart';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile_app/models/route_model.dart';
import 'package:mobile_app/services/ble_service.dart';
import 'package:mobile_app/services/navigation_manager.dart';
import 'package:mobile_app/services/off_route_detector.dart';
import 'package:mobile_app/services/route_geometry.dart';
import 'package:mobile_app/services/routing_service.dart';

class MockRoutingService implements RoutingService {
  int callCount = 0;
  String? lastCosting;
  LatLng? lastStart;
  LatLng? lastDestination;
  Completer<NavRoute?>? pendingCompleter;
  Completer<NavRoute?>? primaryCompleter;
  Completer<NavRoute?>? secondaryCompleter;

  NavRoute? nextRouteToReturn;
  NavRoute? secondaryRouteToReturn;

  @override
  Future<NavRoute?> calculateSingleRoute(
    LatLng start,
    LatLng destination, {
    String costing = 'motorcycle',
  }) {
    callCount++;
    lastCosting = costing;
    lastStart = start;
    lastDestination = destination;

    final isDest = (destination.latitude == 21.000 && destination.longitude == 105.810);
    if (isDest && primaryCompleter != null) {
      return primaryCompleter!.future;
    }
    if (!isDest && secondaryCompleter != null) {
      return secondaryCompleter!.future;
    }
    if (!isDest && secondaryRouteToReturn != null) {
      return Future.value(secondaryRouteToReturn);
    }
    if (pendingCompleter != null) {
      return pendingCompleter!.future;
    }
    return Future.value(nextRouteToReturn);
  }
}

class MockMapLineDrawer implements MapLineDrawer {
  int clearLinesCallCount = 0;
  int drawActiveRouteCallCount = 0;
  int drawPreviewRoutesCallCount = 0;

  List<LatLng> lastDrawnActivePolyline = [];
  List<LatLng>? lastDrawnSecondaryPolyline;

  @override
  Future<void> clearLines() async {
    clearLinesCallCount++;
  }

  @override
  Future<void> drawActiveRoute({
    required List<LatLng> remainingPolyline,
    List<LatLng>? secondaryPolyline,
  }) async {
    drawActiveRouteCallCount++;
    lastDrawnActivePolyline = List.unmodifiable(remainingPolyline);
    lastDrawnSecondaryPolyline = secondaryPolyline != null ? List.unmodifiable(secondaryPolyline) : null;
  }

  @override
  Future<void> drawPreviewRoutes({
    required List<LatLng> mainRoute,
    required List<List<LatLng>> alternativeRoutes,
  }) async {
    drawPreviewRoutesCallCount++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Navigation Reroute Tests (P5.5 Sections 21 - 44, 54 - 57, 60, 62, 63)', () {
    late NavigationManager navManager;
    late BleService bleService;
    late MockRoutingService mockRouter;

    // Planned Route A: starts at (21.000, 105.800) and heads East to (21.000, 105.810) (~1000m)
    const startCoord = LatLng(21.000, 105.800);
    const destCoord = LatLng(21.000, 105.810);
    final routeAPoints = [startCoord, destCoord];

    late NavRoute routeA;

    setUp(() {
      bleService = BleService();
      mockRouter = MockRoutingService();
      navManager = NavigationManager(
        bleService: bleService,
        routingService: mockRouter,
      );

      final geomA = RouteGeometry(routeAPoints);
      routeA = NavRoute(
        totalDistanceMeters: geomA.totalDistanceMeters,
        totalDurationSeconds: 120.0,
        polylinePoints: routeAPoints,
        steps: [
          NavStep(
            stepIndex: 0,
            instruction: 'Đi về hướng Đông',
            streetName: 'Đường A',
            distanceMeters: geomA.totalDistanceMeters,
            durationSeconds: 120.0,
            coordinate: startCoord,
            maneuverTypeStr: 'depart',
            beginShapeIndex: 0,
            endShapeIndex: 1,
          ),
        ],
        summary: 'Tuyến đường A',
      );
    });

    tearDown(() {
      navManager.dispose();
    });

    test('Section 54: Exact field regression from user screenshot (bends away, separation <45m)', () async {
      navManager.startNavigation(routeA);
      final startTime = DateTime(2026, 9, 22, 8, 0, 0);

      // In the real defect: vehicle leaves route onto a parallel road separated by only 18m (< 45m).
      // Old detector checked distance to vertices with >45m threshold and NEVER rerouted!
      // New detector must detect moderate deviation, confirm, and trigger Valhalla motorcycle reroute.
      const parallelCoord = LatLng(21.00016, 105.803); // ~18m North of Route A

      // Sample at t0: triggers suspicion
      navManager.updatePositionForTesting(
        parallelCoord,
        speedKmh: 30.0, // ~8.3 m/s
        heading: 90.0,
        horizontalAccuracy: 4.0,
        timestamp: startTime,
      );

      expect(navManager.lastOffRouteDecision?.state, equals(OffRouteState.suspected));
      expect(mockRouter.callCount, equals(0));

      // Advance synthetic time by 2.2 seconds (exceeds moderate deviation dwell of 2.0s)
      final tConfirm = startTime.add(const Duration(milliseconds: 2600));
      navManager.updatePositionForTesting(
        const LatLng(21.00016, 105.8035),
        speedKmh: 30.0,
        heading: 90.0,
        horizontalAccuracy: 4.0,
        timestamp: tConfirm,
      );

      expect(navManager.lastOffRouteDecision?.state, equals(OffRouteState.confirmed));
      expect(navManager.isRerouting, isTrue);
      // Confirmed within bounded moving latency (~2.2s)!
      expect(mockRouter.callCount, equals(1));
      expect(mockRouter.lastCosting, equals('motorcycle'));
    });

    test('Section 55: Parallel road test (12m apart, speed 8m/s, acc 4m -> confirmed, 1 reroute)', () async {
      navManager.startNavigation(routeA);
      final t0 = DateTime(2026, 9, 22, 9, 0, 0);

      // 12m separation (0.000108 lat is ~12.0m)
      const pWrong = LatLng(21.000108, 105.802);

      navManager.updatePositionForTesting(
        pWrong,
        speedKmh: 28.8, // 8.0 m/s
        heading: 90.0,
        horizontalAccuracy: 4.0,
        timestamp: t0,
      );

      expect(navManager.lastOffRouteDecision?.state, equals(OffRouteState.suspected));
      expect(navManager.lastOffRouteDecision?.reason, equals(OffRouteReason.persistentModerateLateralDeviation));
      expect(mockRouter.callCount, equals(0));

      // After 2.1s: confirmed!
      final t1 = t0.add(const Duration(milliseconds: 2100));
      navManager.updatePositionForTesting(
        const LatLng(21.000108, 105.8025),
        speedKmh: 28.8,
        heading: 90.0,
        horizontalAccuracy: 4.0,
        timestamp: t1,
      );

      expect(navManager.lastOffRouteDecision?.state, equals(OffRouteState.confirmed));
      expect(mockRouter.callCount, equals(1));
      expect(mockRouter.lastCosting, equals('motorcycle'));
    });

    test('Section 56: Poor GPS parallel test (12m apart, accuracy 15m -> no instant reroute)', () {
      navManager.startNavigation(routeA);
      final t0 = DateTime(2026, 9, 22, 9, 0, 0);
      const pWrong = LatLng(21.000108, 105.802);

      // Accuracy 15m: moderate threshold = max(10, 15 * 1.5) = 22.5m
      navManager.updatePositionForTesting(
        pWrong,
        speedKmh: 28.8,
        heading: 90.0,
        horizontalAccuracy: 15.0,
        timestamp: t0,
      );

      expect(navManager.lastOffRouteDecision?.state, equals(OffRouteState.onRoute));
      expect(mockRouter.callCount, equals(0));
    });

    test('Section 57: Cross-street wrong turn test (90° turn -> reroute in ~1.0-1.5s)', () async {
      navManager.startNavigation(routeA);
      final t0 = DateTime(2026, 9, 22, 9, 0, 0);

      // Vehicle turns 90° South onto cross street at (21.000, 105.804)
      const turnCoord = LatLng(20.99988, 105.804); // ~13m South, heading 180°

      navManager.updatePositionForTesting(
        turnCoord,
        speedKmh: 36.0, // 10 m/s
        heading: 180.0,
        horizontalAccuracy: 4.0,
        timestamp: t0,
      );

      expect(navManager.lastOffRouteDecision?.state, equals(OffRouteState.suspected));
      expect(navManager.lastOffRouteDecision?.reason, equals(OffRouteReason.courseDivergence));

      // After 1.1 seconds: confirmed fast track!
      final t1 = t0.add(const Duration(milliseconds: 1100));
      navManager.updatePositionForTesting(
        const LatLng(20.99975, 105.804),
        speedKmh: 36.0,
        heading: 180.0,
        horizontalAccuracy: 4.0,
        timestamp: t1,
      );

      expect(navManager.lastOffRouteDecision?.state, equals(OffRouteState.confirmed));
      expect(mockRouter.callCount, equals(1));
    });

    test('Section 60: Sharp turn test (correct 90° planned turn -> matcher advances, no false reroute)', () {
      // Planned route with a sharp 90° turn: East then North
      const p0 = LatLng(21.000, 105.800);
      const pTurn = LatLng(21.000, 105.805); // Turn point
      const pEnd = LatLng(21.005, 105.805); // North
      final sharpRoute = NavRoute(
        totalDistanceMeters: 1000.0,
        totalDurationSeconds: 120.0,
        polylinePoints: [p0, pTurn, pEnd],
        steps: [
          NavStep(
            stepIndex: 0,
            instruction: 'Đi thẳng',
            streetName: 'Đường 1',
            distanceMeters: 500,
            durationSeconds: 60,
            coordinate: p0,
            maneuverTypeStr: 'depart',
            beginShapeIndex: 0,
            endShapeIndex: 1,
          ),
          NavStep(
            stepIndex: 1,
            instruction: 'Rẽ trái lên Đường 2',
            streetName: 'Đường 2',
            distanceMeters: 500,
            durationSeconds: 60,
            coordinate: pTurn,
            maneuverTypeStr: 'turn left',
            beginShapeIndex: 1,
            endShapeIndex: 2,
          ),
        ],
        summary: 'Góc rẽ vuông',
      );

      navManager.startNavigation(sharpRoute);

      // Advance vehicle right through the turn point and onto the North segment
      navManager.updatePositionForTesting(
        const LatLng(21.001, 105.805), // On segment 2 going North
        speedKmh: 25.0,
        heading: 0.0, // North
        horizontalAccuracy: 4.0,
      );

      // Matcher should advance to segment 1 (going North)
      expect(navManager.matchedProjection?.segmentIndex, equals(1));
      expect(navManager.lastOffRouteDecision?.state, equals(OffRouteState.onRoute));
      expect(mockRouter.callCount, equals(0)); // NO false reroute!
    });

    test('Section 62: Reroute atomicity test (pending route keeps trimming, Route B commits atomically)', () async {
      navManager.startNavigation(routeA);
      
      // Setup pending completer for reroute request
      final completer = Completer<NavRoute?>();
      mockRouter.pendingCompleter = completer;

      // Trigger off-route to start reroute
      final t0 = DateTime(2026, 9, 22, 10, 0, 0);
      navManager.updatePositionForTesting(
        const LatLng(21.0004, 105.803), // 44m off route (strong deviation)
        speedKmh: 30.0,
        heading: 90.0,
        horizontalAccuracy: 4.0,
        timestamp: t0,
      );
      final t1 = t0.add(const Duration(milliseconds: 1100));
      navManager.updatePositionForTesting(
        const LatLng(21.00045, 105.8035),
        speedKmh: 30.0,
        heading: 90.0,
        horizontalAccuracy: 4.0,
        timestamp: t1,
      );

      // Reroute request is in flight!
      expect(navManager.isRerouting, isTrue);
      expect(navManager.rerouteStatus, equals('requesting'));
      expect(mockRouter.callCount, equals(1));

      // While reroute is in flight: Route A MUST remain active and keep trimming! (Section 40, 41)
      expect(navManager.activeRoute, equals(routeA));

      // Vehicle continues moving along
      final prevProgress = navManager.displayProgressMeters;
      navManager.updatePositionForTesting(
        const LatLng(21.00045, 105.8050),
        speedKmh: 30.0,
        heading: 90.0,
        horizontalAccuracy: 4.0,
        timestamp: t1.add(const Duration(seconds: 1)),
      );

      expect(navManager.activeRoute, equals(routeA));
      expect(navManager.isRerouting, isTrue);
      expect(navManager.displayProgressMeters, greaterThanOrEqualTo(prevProgress));

      // Now create Route B (calculated by Valhalla to the same frozen destination)
      const bStart = LatLng(21.00045, 105.8050);
      final routeBPoints = [bStart, destCoord];
      final geomB = RouteGeometry(routeBPoints);
      final routeB = NavRoute(
        totalDistanceMeters: geomB.totalDistanceMeters,
        totalDurationSeconds: 90.0,
        polylinePoints: routeBPoints,
        steps: [
          NavStep(
            stepIndex: 0,
            instruction: 'Tiếp tục lộ trình mới',
            streetName: 'Đường Mới',
            distanceMeters: geomB.totalDistanceMeters,
            durationSeconds: 90.0,
            coordinate: bStart,
            maneuverTypeStr: 'depart',
            beginShapeIndex: 0,
            endShapeIndex: 1,
          ),
        ],
        summary: 'Lộ trình mới B',
      );

      // Resolve Route B
      completer.complete(routeB);
      await pumpEventQueue();

      // ATOMIC REPLACEMENT VERIFICATION (Section 42):
      expect(navManager.activeRoute, equals(routeB));
      expect(navManager.isRerouting, isFalse);
      expect(navManager.rerouteStatus, equals('applied'));
      expect(navManager.navigationDestination, equals(destCoord)); // Destination frozen!
      expect(navManager.currentStepIndex, equals(0));
      expect(navManager.remainingPolyline.isNotEmpty, isTrue);
      expect(navManager.lastOffRouteDecision?.state, equals(OffRouteState.onRoute));
    });

    test('Section 63: Production motorcycle reroute uses Valhalla, not Mapbox', () async {
      navManager.startNavigation(routeA);

      // Trigger reroute
      navManager.triggerRerouteForTesting(const LatLng(21.0002, 105.802));
      expect(mockRouter.callCount, equals(1));
      expect(mockRouter.lastCosting, equals('motorcycle'));

      // Assert router is RoutingService (Valhalla stack) and costing is motorcycle
      expect(mockRouter.lastCosting, isNot(equals('bike')));
      expect(mockRouter.lastCosting, isNot(equals('bicycle')));
      expect(mockRouter.lastCosting, isNot(equals('auto')));
    });

    test('Generation guard: late reroute response does not overwrite stopped navigation', () async {
      navManager.startNavigation(routeA);
      final completer = Completer<NavRoute?>();
      mockRouter.pendingCompleter = completer;

      navManager.triggerRerouteForTesting(const LatLng(21.0002, 105.802));
      expect(navManager.isRerouting, isTrue);

      // User stops navigation while reroute is in flight
      navManager.stopNavigation();
      expect(navManager.isNavigating, isFalse);

      // Late response returns
      completer.complete(routeA);
      await pumpEventQueue();

      // Navigation remains stopped, not revived by stale response!
      expect(navManager.isNavigating, isFalse);
      expect(navManager.activeRoute, isNull);
    });
    test('P5.5.1 Section 6: Reroute network failure triggers backoff cooldown and prevents spamming', () async {
      mockRouter.nextRouteToReturn = null;
      navManager.startNavigation(routeA);
      DateTime t = DateTime(2026, 9, 22, 12, 0, 0);
      navManager.nowProvider = () => t;
      final offRouteCoord = const LatLng(21.00041, 105.8010);

      navManager.updatePositionForTesting(
        offRouteCoord,
        speedKmh: 35.0,
        heading: 0.0,
        horizontalAccuracy: 4.0,
        timestamp: t,
      );
      expect(mockRouter.callCount, equals(0));

      t = t.add(const Duration(milliseconds: 1200));
      navManager.updatePositionForTesting(
        offRouteCoord,
        speedKmh: 35.0,
        heading: 0.0,
        horizontalAccuracy: 4.0,
        timestamp: t,
      );

      await Future.delayed(Duration.zero);

      expect(mockRouter.callCount, equals(1));
      expect(navManager.rerouteStatus, equals('failed'));
      expect(navManager.rerouteRetryCount, equals(1));
      expect(navManager.lastRerouteFailureAt, isNotNull);
      expect(navManager.currentRerouteCooldown.inSeconds, equals(3));

      // Sample at t + 1.0s (in 3s cooldown)
      t = t.add(const Duration(seconds: 1));
      navManager.updatePositionForTesting(
        offRouteCoord,
        speedKmh: 35.0,
        heading: 0.0,
        horizontalAccuracy: 4.0,
        timestamp: t,
      );
      await Future.delayed(Duration.zero);

      expect(mockRouter.callCount, equals(1));
      expect(navManager.rerouteStatus, equals('cooldown'));

      // Sample at t + 4.0s (elapsed 4.0s > 3.0s cooldown) -> retry 2
      t = t.add(const Duration(seconds: 3));
      navManager.updatePositionForTesting(
        offRouteCoord,
        speedKmh: 35.0,
        heading: 0.0,
        horizontalAccuracy: 4.0,
        timestamp: t,
      );
      await Future.delayed(Duration.zero);

      expect(mockRouter.callCount, equals(2));
      expect(navManager.rerouteRetryCount, equals(2));
      expect(navManager.currentRerouteCooldown.inSeconds, equals(6));
    });

    test('P5.5.1 Section 7: Reroute commit with identical point count & close start bumps routeRevision', () async {
      navManager.startNavigation(routeA);
      final initialRevision = navManager.routeRevision;

      final closeStart = const LatLng(21.000004, 105.800004);
      final routeB = NavRoute(
        totalDistanceMeters: 800.0,
        totalDurationSeconds: 80.0,
        polylinePoints: [closeStart, const LatLng(21.008, 105.808)],
        steps: [],
        summary: 'Route B',
      );
      mockRouter.nextRouteToReturn = routeB;

      DateTime t = DateTime(2026, 9, 22, 12, 0, 0);
      final offRouteCoord = const LatLng(21.00041, 105.8010);

      navManager.updatePositionForTesting(
        offRouteCoord,
        speedKmh: 35.0,
        heading: 0.0,
        horizontalAccuracy: 4.0,
        timestamp: t,
      );
      t = t.add(const Duration(milliseconds: 1200));
      navManager.updatePositionForTesting(
        offRouteCoord,
        speedKmh: 35.0,
        heading: 0.0,
        horizontalAccuracy: 4.0,
        timestamp: t,
      );

      await Future.delayed(Duration.zero);

      expect(mockRouter.callCount, equals(1));
      expect(navManager.activeRoute, equals(routeB));
      expect(navManager.routeRevision, greaterThan(initialRevision));
      expect(navManager.rerouteStatus, equals('applied'));
      expect(navManager.rerouteRetryCount, equals(0));
      expect(navManager.lastOffRouteDecision?.state, equals(OffRouteState.onRoute));
    });

    test('P5.5.1 Section 6: Recovery to onRoute resets reroute failure backoff', () async {
      mockRouter.nextRouteToReturn = null;
      DateTime t = DateTime(2026, 9, 22, 12, 0, 0);
      navManager.nowProvider = () => t;
      navManager.startNavigation(routeA);
      final offRouteCoord = const LatLng(21.00041, 105.8010);

      navManager.updatePositionForTesting(offRouteCoord, speedKmh: 35.0, heading: 0.0, horizontalAccuracy: 4.0, timestamp: t);
      t = t.add(const Duration(milliseconds: 1200));
      navManager.updatePositionForTesting(offRouteCoord, speedKmh: 35.0, heading: 0.0, horizontalAccuracy: 4.0, timestamp: t);
      await Future.delayed(Duration.zero);

      expect(navManager.rerouteRetryCount, equals(1));
      expect(navManager.rerouteStatus, equals('failed'));

      // Vehicle steers back onto Route A (observation 1 starts recovery)
      t = t.add(const Duration(seconds: 1));
      navManager.updatePositionForTesting(startCoord, speedKmh: 35.0, heading: 90.0, horizontalAccuracy: 4.0, timestamp: t);

      // Observation 2 (1.2s later completes recoveryDwellSeconds)
      t = t.add(const Duration(milliseconds: 1200));
      navManager.updatePositionForTesting(startCoord, speedKmh: 35.0, heading: 90.0, horizontalAccuracy: 4.0, timestamp: t);

      expect(navManager.lastOffRouteDecision?.state, equals(OffRouteState.onRoute));
      expect(navManager.rerouteRetryCount, equals(0));
      expect(navManager.lastRerouteFailureAt, isNull);
      expect(navManager.rerouteStatus, equals('idle'));
    });
    test('P5.5.2 Section 4 & 5: Slow network failure anchors backoff cooldown to actual completion time', () async {
      DateTime syntheticTime = DateTime(2026, 9, 22, 12, 0, 0);
      navManager.nowProvider = () => syntheticTime;

      final completer = Completer<NavRoute?>();
      mockRouter.pendingCompleter = completer;

      navManager.startNavigation(routeA);
      final offRouteCoord = const LatLng(21.00041, 105.8010);

      // T0: suspected
      navManager.updatePositionForTesting(
        offRouteCoord,
        speedKmh: 35.0,
        heading: 0.0,
        horizontalAccuracy: 4.0,
        timestamp: syntheticTime,
      );
      expect(mockRouter.callCount, equals(0));

      // T0 + 1.2s: confirmed off-route -> Valhalla request starts
      syntheticTime = syntheticTime.add(const Duration(milliseconds: 1200));
      navManager.updatePositionForTesting(
        offRouteCoord,
        speedKmh: 35.0,
        heading: 0.0,
        horizontalAccuracy: 4.0,
        timestamp: syntheticTime,
      );

      expect(mockRouter.callCount, equals(1));
      expect(navManager.isRerouting, isTrue);
      expect(navManager.rerouteStatus, equals('requesting'));
      expect(navManager.requestStartedAt, equals(syntheticTime));

      final requestStartTime = syntheticTime;

      // Single-flight during slow request: send more GPS updates at T0+2s, T0+3s, T0+5s
      for (int i = 2; i <= 5; i++) {
        syntheticTime = requestStartTime.add(Duration(seconds: i));
        navManager.updatePositionForTesting(
          offRouteCoord,
          speedKmh: 35.0,
          heading: 0.0,
          horizontalAccuracy: 4.0,
          timestamp: syntheticTime,
        );
        expect(mockRouter.callCount, equals(1), reason: 'Must not dispatch second request while first is in-flight');
      }

      // Now at T0 + 7.0s: Valhalla request completes with failure (null)
      syntheticTime = requestStartTime.add(const Duration(seconds: 7));
      completer.complete(null);
      await Future.delayed(Duration.zero);

      // Verify failure state anchored to T0 + 7s
      expect(navManager.isRerouting, isFalse);
      expect(navManager.rerouteStatus, equals('failed'));
      expect(navManager.rerouteRetryCount, equals(1));
      expect(navManager.rerouteFailedAt, equals(syntheticTime));
      expect(navManager.lastRerouteFailureAt, equals(syntheticTime));
      expect(navManager.currentRerouteCooldown.inSeconds, equals(3));

      // At T0 + 8.0s (1s after failure): still in 3s cooldown
      syntheticTime = requestStartTime.add(const Duration(seconds: 8));
      navManager.updatePositionForTesting(
        offRouteCoord,
        speedKmh: 35.0,
        heading: 0.0,
        horizontalAccuracy: 4.0,
        timestamp: syntheticTime,
      );
      await Future.delayed(Duration.zero);

      expect(mockRouter.callCount, equals(1), reason: 'Cooldown must prevent request at 1s after failure');
      expect(navManager.rerouteStatus, equals('cooldown'));

      // At T0 + 9.9s (2.9s after failure): still in cooldown
      syntheticTime = requestStartTime.add(const Duration(milliseconds: 9900));
      navManager.updatePositionForTesting(
        offRouteCoord,
        speedKmh: 35.0,
        heading: 0.0,
        horizontalAccuracy: 4.0,
        timestamp: syntheticTime,
      );
      await Future.delayed(Duration.zero);
      expect(mockRouter.callCount, equals(1));

      // Reset mock router completer for attempt 2
      mockRouter.pendingCompleter = null;
      mockRouter.nextRouteToReturn = null;

      // At T0 + 10.1s (3.1s after failure > 3.0s cooldown): second request permitted!
      syntheticTime = requestStartTime.add(const Duration(milliseconds: 10100));
      navManager.updatePositionForTesting(
        offRouteCoord,
        speedKmh: 35.0,
        heading: 0.0,
        horizontalAccuracy: 4.0,
        timestamp: syntheticTime,
      );
      await Future.delayed(Duration.zero);

      expect(mockRouter.callCount, equals(2), reason: 'Must permit retry 2 once 3.0s cooldown after failure elapses');
      expect(navManager.rerouteRetryCount, equals(2));
      expect(navManager.currentRerouteCooldown.inSeconds, equals(6));
    });

    test('P5.5.2 Section 4: Slow network Exception/Timeout anchors backoff cooldown to actual completion time', () async {
      DateTime syntheticTime = DateTime(2026, 9, 22, 12, 0, 0);
      navManager.nowProvider = () => syntheticTime;

      final completer = Completer<NavRoute?>();
      mockRouter.pendingCompleter = completer;

      navManager.startNavigation(routeA);
      final offRouteCoord = const LatLng(21.00041, 105.8010);

      // T0: suspected
      navManager.updatePositionForTesting(offRouteCoord, speedKmh: 35.0, heading: 0.0, horizontalAccuracy: 4.0, timestamp: syntheticTime);

      // T0 + 1.2s: confirmed
      syntheticTime = syntheticTime.add(const Duration(milliseconds: 1200));
      navManager.updatePositionForTesting(offRouteCoord, speedKmh: 35.0, heading: 0.0, horizontalAccuracy: 4.0, timestamp: syntheticTime);

      expect(mockRouter.callCount, equals(1));
      final requestStartTime = syntheticTime;

      // Network times out at T0 + 7s throwing Exception
      syntheticTime = requestStartTime.add(const Duration(seconds: 7));
      completer.completeError(TimeoutException('Valhalla timeout after 7s'));
      await Future.delayed(Duration.zero);

      expect(navManager.isRerouting, isFalse);
      expect(navManager.rerouteStatus, equals('failed'));
      expect(navManager.rerouteRetryCount, equals(1));
      expect(navManager.rerouteFailedAt, equals(syntheticTime));

      // At T0 + 8.5s: 1.5s after error, in cooldown
      syntheticTime = requestStartTime.add(const Duration(milliseconds: 8500));
      navManager.updatePositionForTesting(offRouteCoord, speedKmh: 35.0, heading: 0.0, horizontalAccuracy: 4.0, timestamp: syntheticTime);
      await Future.delayed(Duration.zero);

      expect(mockRouter.callCount, equals(1));
      expect(navManager.rerouteStatus, equals('cooldown'));

      // At T0 + 10.1s: > 3.0s cooldown elapsed, second attempt triggered
      mockRouter.pendingCompleter = null;
      mockRouter.nextRouteToReturn = null;
      syntheticTime = requestStartTime.add(const Duration(milliseconds: 10100));
      navManager.updatePositionForTesting(offRouteCoord, speedKmh: 35.0, heading: 0.0, horizontalAccuracy: 4.0, timestamp: syntheticTime);
      await Future.delayed(Duration.zero);

      expect(mockRouter.callCount, equals(2));
      expect(navManager.rerouteRetryCount, equals(2));
    });
  
    test('P5.6 Section 3, 4 & 6: Wrong-way movement fast reroute commits Route B as primary and Route A as secondary', () async {
      DateTime syntheticTime = DateTime(2026, 9, 22, 14, 0, 0);
      navManager.nowProvider = () => syntheticTime;
      navManager.startNavigation(routeA);

      final completer = Completer<NavRoute?>();
      mockRouter.pendingCompleter = completer;

      // Vehicle moves West (heading 270) along route that points East (heading 90)
      // Angle diff = 180° >= 120° wrongWayMismatchAngleDegrees
      final wrongWayCoord = const LatLng(21.00004, 105.8050);

      // T0: suspected wrong-way divergence
      navManager.updatePositionForTesting(
        wrongWayCoord,
        speedKmh: 36.0, // 10 m/s >= 3.0 m/s
        heading: 270.0,
        horizontalAccuracy: 4.0,
        timestamp: syntheticTime,
      );

      expect(navManager.lastOffRouteDecision?.state, equals(OffRouteState.suspected));
      expect(navManager.lastOffRouteDecision?.reason, equals(OffRouteReason.wrongWayDivergence));
      expect(navManager.isWrongWayDivergence, isTrue);
      expect(navManager.headingDeltaVsRouteDegrees, closeTo(180.0, 1.0));

      // T0 + 0.85s: exceeds wrongWayDwellSeconds (0.8s) -> confirmed!
      syntheticTime = syntheticTime.add(const Duration(milliseconds: 850));
      navManager.updatePositionForTesting(
        const LatLng(21.00004, 105.8048),
        speedKmh: 36.0,
        heading: 270.0,
        horizontalAccuracy: 4.0,
        timestamp: syntheticTime,
      );

      expect(navManager.lastOffRouteDecision?.state, equals(OffRouteState.confirmed));
      expect(navManager.isRerouting, isTrue);
      expect(mockRouter.callCount, equals(1));

      // Build Route B from current position to destCoord
      const bStart = LatLng(21.00004, 105.8048);
      final routeBPoints = [bStart, destCoord];
      final geomB = RouteGeometry(routeBPoints);
      final routeB = NavRoute(
        totalDistanceMeters: geomB.totalDistanceMeters,
        totalDurationSeconds: 85.0,
        polylinePoints: routeBPoints,
        steps: [
          NavStep(
            stepIndex: 0,
            instruction: 'Quay đầu rồi đi thẳng',
            streetName: 'Đường B',
            distanceMeters: geomB.totalDistanceMeters,
            durationSeconds: 85.0,
            coordinate: bStart,
            maneuverTypeStr: 'u-turn',
            beginShapeIndex: 0,
            endShapeIndex: 1,
          ),
        ],
        summary: 'Lộ trình mới B',
      );

      completer.complete(routeB);
      await pumpEventQueue();

      // Verify Primary + Secondary Dual-Route
      expect(navManager.activeRoute, equals(routeB), reason: 'Route B is the primary active route');
      expect(navManager.secondaryRoute, isNotNull, reason: 'Route A remains as secondary reference route');
      expect(navManager.secondaryPolyline.isNotEmpty, isTrue);

      // Verify authoritative maneuver is solely driven by Primary Route B
      expect(navManager.authoritativeCurrentManeuver, isNotNull);
      expect(navManager.bannerInstruction, equals('Quay đầu rồi đi thẳng'));
      expect(navManager.bannerTurnIcon, isNotNull);
    });

    test('P5.6 Section 8: Cancel navigation clears both active and secondary routes', () async {
      navManager.startNavigation(routeA);

      // Force a secondary route state
      final routeB = NavRoute(
        totalDistanceMeters: 500,
        totalDurationSeconds: 60,
        polylinePoints: [const LatLng(21.0, 105.8), const LatLng(21.0, 105.805)],
        steps: [],
        summary: 'B',
      );
      mockRouter.nextRouteToReturn = routeB;
      navManager.triggerRerouteForTesting(const LatLng(21.0004, 105.802));
      await pumpEventQueue();

      expect(navManager.activeRoute, isNotNull);

      // Cancel / stop navigation
      navManager.stopNavigation();

      expect(navManager.isNavigating, isFalse);
      expect(navManager.activeRoute, isNull);
      expect(navManager.secondaryRoute, isNull);
      expect(navManager.secondaryPolyline, isEmpty);
      expect(navManager.remainingPolyline, isEmpty);
      expect(navManager.authoritativeCurrentManeuver, isNull);
      expect(navManager.authoritativeCurrentManeuver, isNull);
      expect(navManager.bannerInstruction, equals('Tiếp tục đi thẳng'));
    });
  
    final multiRoute = NavRoute(
      totalDistanceMeters: 1000.0,
      totalDurationSeconds: 120.0,
      polylinePoints: [
        startCoord,
        const LatLng(21.000, 105.803),
        const LatLng(21.000, 105.806),
        destCoord,
      ],
      steps: [],
      summary: 'Multi route A',
    );

    test('P5.6.1 Gap B & Section 5: Secondary rejoin route connects vehicle to old route and updates secondaryPolyline', () async {
      navManager.startNavigation(multiRoute);

      final primComp = Completer<NavRoute?>();
      final secComp = Completer<NavRoute?>();
      mockRouter.primaryCompleter = primComp;
      mockRouter.secondaryCompleter = secComp;

      const vehiclePos = LatLng(21.0005, 105.803);
      navManager.triggerRerouteForTesting(vehiclePos);

      expect(mockRouter.callCount, equals(1), reason: 'Primary request launched first');

      // Primary Route B direct to destination arrives
      final routeB = NavRoute(
        totalDistanceMeters: 700.0,
        totalDurationSeconds: 80.0,
        polylinePoints: [vehiclePos, destCoord],
        steps: [
          NavStep(
            stepIndex: 0,
            instruction: 'Lộ trình mới B',
            streetName: 'Đường B',
            distanceMeters: 700.0,
            durationSeconds: 80.0,
            coordinate: vehiclePos,
            maneuverTypeStr: 'depart',
            beginShapeIndex: 0,
            endShapeIndex: 1,
          ),
        ],
        summary: 'Primary Route B',
      );

      primComp.complete(routeB);
      await pumpEventQueue();

      // Primary commits immediately; secondary rejoin launched in background
      expect(navManager.activeRoute, equals(routeB));
      expect(mockRouter.callCount, equals(2), reason: 'Secondary rejoin request launched on commit');
      expect(navManager.secondaryRerouteStatus, equals('requesting'));

      // Secondary rejoin arrives connecting vehiclePos to rejoin point on route A
      final rejoinTarget = LatLng(21.000, 105.805);
      final rejoinRoute = NavRoute(
        totalDistanceMeters: 150.0,
        totalDurationSeconds: 20.0,
        polylinePoints: [vehiclePos, const LatLng(21.0002, 105.804), rejoinTarget],
        steps: [],
        summary: 'Rejoin path',
      );

      secComp.complete(rejoinRoute);
      await pumpEventQueue();

      // Secondary route updated to start from vehicle
      expect(navManager.secondaryRerouteStatus, equals('applied'));
      expect(navManager.secondaryPolyline.first, equals(vehiclePos));
      expect(navManager.secondaryPolyline.contains(destCoord), isTrue);
      // Primary is unchanged!
      expect(navManager.activeRoute, equals(routeB));
      expect(navManager.bannerInstruction, equals('Lộ trình mới B'));
    });

    test('P5.6.1 Gap B: Secondary rejoin failure falls back to old remaining route without breaking primary', () async {
      navManager.startNavigation(multiRoute);

      final primComp = Completer<NavRoute?>();
      final secComp = Completer<NavRoute?>();
      mockRouter.primaryCompleter = primComp;
      mockRouter.secondaryCompleter = secComp;

      const vehiclePos = LatLng(21.0005, 105.803);
      navManager.triggerRerouteForTesting(vehiclePos);

      final routeB = NavRoute(
        totalDistanceMeters: 700.0,
        totalDurationSeconds: 80.0,
        polylinePoints: [vehiclePos, destCoord],
        steps: [],
        summary: 'Route B',
      );

      primComp.complete(routeB);
      await pumpEventQueue();
      expect(navManager.activeRoute, equals(routeB));
      expect(navManager.secondaryRerouteStatus, equals('requesting'));

      // Rejoin route calculation returns null (e.g. no viable rejoin path)
      secComp.complete(null);
      await pumpEventQueue();

      expect(navManager.secondaryRerouteStatus, equals('fallback'));
      expect(navManager.secondaryPolyline.isNotEmpty, isTrue);
      expect(navManager.activeRoute, equals(routeB));
    });

    test('P5.6.1 Section 11: Cancel navigation invalidates pending secondary request and prevents late restoration', () async {
      navManager.startNavigation(multiRoute);

      final primComp = Completer<NavRoute?>();
      final secComp = Completer<NavRoute?>();
      mockRouter.primaryCompleter = primComp;
      mockRouter.secondaryCompleter = secComp;

      const vehiclePos = LatLng(21.0005, 105.803);
      navManager.triggerRerouteForTesting(vehiclePos);

      final routeB = NavRoute(
        totalDistanceMeters: 700.0,
        totalDurationSeconds: 80.0,
        polylinePoints: [vehiclePos, destCoord],
        steps: [],
        summary: 'Route B',
      );
      primComp.complete(routeB);
      await pumpEventQueue();

      expect(navManager.activeRoute, equals(routeB));
      expect(navManager.secondaryRerouteStatus, equals('requesting'));

      // User cancels navigation while secondary is in-flight
      navManager.stopNavigation();

      expect(navManager.isNavigating, isFalse);
      expect(navManager.activeRoute, isNull);
      expect(navManager.secondaryRoute, isNull);
      expect(navManager.secondaryPolyline, isEmpty);

      // Late secondary response arrives after cancellation
      final lateRejoinRoute = NavRoute(
        totalDistanceMeters: 200,
        totalDurationSeconds: 30,
        polylinePoints: [vehiclePos, const LatLng(21.0, 105.805)],
        steps: [],
        summary: 'Late rejoin',
      );
      secComp.complete(lateRejoinRoute);
      await pumpEventQueue();

      // Generation guard ensures late response is discarded and state remains completely empty
      expect(navManager.isNavigating, isFalse);
      expect(navManager.activeRoute, isNull);
      expect(navManager.secondaryRoute, isNull);
      expect(navManager.secondaryPolyline, isEmpty);
      expect(navManager.secondaryRerouteStatus, equals('none'));
    });

    test('P5.6.2: Primary Route B rendered, zero GPS updates, async secondary arrives -> renderRevision bumps, map-render triggered, secondary appears, primary unchanged', () async {
      final mockDrawer = MockMapLineDrawer();
      final renderController = RouteRenderController(mockDrawer);

      // Start navigation with initial multiRoute
      navManager.startNavigation(multiRoute);
      await pumpEventQueue();

      // Vehicle is at vehiclePos along the route
      const vehiclePos = LatLng(21.0005, 105.803);
      navManager.updatePositionForTesting(
        vehiclePos,
        speedKmh: 0.0,
        heading: 90.0,
        horizontalAccuracy: 4.0,
      );

      // Wire up observer logic identical to MapScreen._onNavigationManagerChanged
      int lastObservedRenderRevision = navManager.renderRevision;
      bool lastObservedNavigating = navManager.isNavigating;
      int mapRenderCallbackCount = 0;

      void onNavigationManagerChanged() {
        final rev = navManager.renderRevision;
        final isNav = navManager.isNavigating;

        if (rev != lastObservedRenderRevision || isNav != lastObservedNavigating) {
          lastObservedRenderRevision = rev;
          lastObservedNavigating = isNav;

          if (!isNav) {
            renderController.reset();
          }

          mapRenderCallbackCount++;
          renderController.submitRequest(
            routeRevision: rev,
            mode: isNav ? RoutePresentationMode.navigating : RoutePresentationMode.none,
            mainPoints: navManager.remainingPolyline,
            altPoints: navManager.secondaryPolyline.length >= 2 ? [navManager.secondaryPolyline] : [],
            forceRedraw: true,
          );
        }
      }

      navManager.addListener(onNavigationManagerChanged);

      final primComp = Completer<NavRoute?>();
      final secComp = Completer<NavRoute?>();
      mockRouter.primaryCompleter = primComp;
      mockRouter.secondaryCompleter = secComp;

      navManager.triggerRerouteForTesting(vehiclePos);

      // Primary Route B arrives & commits
      final routeB = NavRoute(
        totalDistanceMeters: 700.0,
        totalDurationSeconds: 80.0,
        polylinePoints: [vehiclePos, destCoord],
        steps: [
          NavStep(
            stepIndex: 0,
            instruction: 'Lộ trình mới B',
            streetName: 'Đường B',
            distanceMeters: 700.0,
            durationSeconds: 80.0,
            coordinate: vehiclePos,
            maneuverTypeStr: 'depart',
            beginShapeIndex: 0,
            endShapeIndex: 1,
          ),
        ],
        summary: 'Primary Route B',
      );

      primComp.complete(routeB);
      await pumpEventQueue();

      // Primary Route B has committed and rendered
      expect(navManager.activeRoute, equals(routeB));
      expect(mockDrawer.lastDrawnActivePolyline, equals(routeB.polylinePoints));
      final revAfterPrimaryCommit = navManager.renderRevision;
      final renderCountAfterPrimaryCommit = mapRenderCallbackCount;
      final drawCountAfterPrimaryCommit = mockDrawer.drawActiveRouteCallCount;

      final snapshotInstruction = navManager.bannerInstruction;
      final snapshotStep = navManager.authoritativeCurrentManeuver;
      final snapshotRemainingDistance = navManager.remainingTotalDistance;
      final snapshotRemainingEta = navManager.remainingEtaMinutes;

      expect(snapshotInstruction, equals('Lộ trình mới B'));
      expect(snapshotStep?.instruction, equals('Lộ trình mới B'));

      // ZERO GPS updates sent (navManager.updateLocation NOT called!)

      // Secondary rejoin arrives asynchronously connecting vehicle to route A
      final rejoinTarget = LatLng(21.000, 105.805);
      final rejoinRoute = NavRoute(
        totalDistanceMeters: 150.0,
        totalDurationSeconds: 20.0,
        polylinePoints: [vehiclePos, const LatLng(21.0002, 105.804), rejoinTarget],
        steps: [],
        summary: 'Rejoin path',
      );

      secComp.complete(rejoinRoute);
      await pumpEventQueue();

      // EXPECTATIONS:
      // 1. renderRevision increased
      expect(navManager.renderRevision, greaterThan(revAfterPrimaryCommit),
          reason: 'renderRevision must increment when secondary rejoin completes');

      // 2. Map-render callback/request was triggered immediately without GPS updates
      expect(mapRenderCallbackCount, greaterThan(renderCountAfterPrimaryCommit),
          reason: 'MapScreen observer must trigger map render immediately upon secondary completion');
      expect(mockDrawer.drawActiveRouteCallCount, greaterThan(drawCountAfterPrimaryCommit),
          reason: 'MapLineDrawer must draw updated routes');

      // 3. Secondary pale route appears on map
      expect(mockDrawer.lastDrawnSecondaryPolyline, isNotNull,
          reason: 'Secondary route must be drawn on map');
      expect(mockDrawer.lastDrawnSecondaryPolyline!.first, equals(vehiclePos),
          reason: 'Secondary route starts at vehicle position');
      expect(mockDrawer.lastDrawnSecondaryPolyline!.contains(destCoord), isTrue,
          reason: 'Secondary route preserves tail to destination');

      // 4. Primary route is unchanged
      expect(navManager.activeRoute, equals(routeB),
          reason: 'Primary active route must remain Route B');
      expect(mockDrawer.lastDrawnActivePolyline, equals(routeB.polylinePoints),
          reason: 'Main drawn polyline must remain Route B');

      // 5. Guidance/ETA/step unchanged
      expect(navManager.bannerInstruction, equals(snapshotInstruction));
      expect(navManager.authoritativeCurrentManeuver, equals(snapshotStep));
      expect(navManager.remainingTotalDistance, equals(snapshotRemainingDistance));
      expect(navManager.remainingEtaMinutes, equals(snapshotRemainingEta));

      navManager.removeListener(onNavigationManagerChanged);
    });

    test('P5.6.2: Secondary throws exception but old remaining exists -> status fallback, secondaryPolyline is not empty', () async {
      navManager.startNavigation(multiRoute);

      final primComp = Completer<NavRoute?>();
      final secComp = Completer<NavRoute?>();
      mockRouter.primaryCompleter = primComp;
      mockRouter.secondaryCompleter = secComp;

      const vehiclePos = LatLng(21.0005, 105.803);
      navManager.triggerRerouteForTesting(vehiclePos);

      final routeB = NavRoute(
        totalDistanceMeters: 700.0,
        totalDurationSeconds: 80.0,
        polylinePoints: [vehiclePos, destCoord],
        steps: [],
        summary: 'Route B',
      );

      primComp.complete(routeB);
      await pumpEventQueue();
      expect(navManager.activeRoute, equals(routeB));
      expect(navManager.secondaryRerouteStatus, equals('requesting'));
      final revBeforeSecException = navManager.renderRevision;

      // Secondary rejoin throws an exception (e.g. Valhalla network timeout)
      secComp.completeError(Exception('Network timeout during secondary rejoin'));
      await pumpEventQueue();

      expect(navManager.secondaryRerouteStatus, equals('fallback'),
          reason: 'When secondary rejoin throws exception, status must be fallback if old remaining exists');
      expect(navManager.secondaryPolyline.isNotEmpty, isTrue,
          reason: 'secondaryPolyline must not be empty');
      expect(navManager.secondaryPolyline.length, greaterThanOrEqualTo(2));
      expect(navManager.renderRevision, greaterThan(revBeforeSecException),
          reason: 'renderRevision must increment on fallback to notify MapScreen immediately');
      expect(navManager.activeRoute, equals(routeB));
    });
  });
}
