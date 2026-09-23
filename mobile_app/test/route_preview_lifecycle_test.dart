import 'package:mobile_app/screens/map_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile_app/models/route_model.dart';
import 'package:mobile_app/services/ble_service.dart';
import 'package:mobile_app/services/navigation_manager.dart';
import 'package:mobile_app/services/routing_service.dart';

class _DummyRoutingService implements RoutingService {
  @override
  Future<NavRoute?> calculateSingleRoute(LatLng start, LatLng destination, {String costing = 'motorcycle'}) async {
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final startPoint = const LatLng(20.9785, 105.8340); // Dinh Cong
  final endPoint = const LatLng(20.8950, 105.6550);   // Tan Tien

  NavRoute createSampleRoute() {
    return NavRoute(
      title: 'Lộ trình Định Công - Tân Tiến',
      subtitle: 'Lộ trình tối ưu',
      summary: 'Qua QL6',
      totalDistanceMeters: 27300,
      totalDurationSeconds: 2200,
      steps: [
        NavStep(
          stepIndex: 0,
          instruction: 'Bắt đầu từ Định Công',
          streetName: 'Đường Định Công',
          distanceMeters: 27300,
          durationSeconds: 2200,
          coordinate: startPoint,
          maneuverTypeStr: 'depart',
        ),
      ],
      polylinePoints: [startPoint, endPoint],
      provider: 'valhalla',
      isFallbackSynthetic: false,
    );
  }

  group('P5.9.4 Route Preview Self-Clear Fix & Lifecycle Tests', () {
    late NavigationManager navManager;

    setUp(() {
      navManager = NavigationManager(
        bleService: BleService(),
        routingService: _DummyRoutingService(),
      );
    });

    test('P5.9.4 Regression Test: setPreviewRoute() does NOT clear _routes when isNavigating is false', () {
      final sampleRoute = createSampleRoute();
      List<NavRoute> routes = [sampleRoute];

      int lastObservedRenderRevision = navManager.renderRevision;
      bool lastObservedNavigating = navManager.isNavigating;
      int redrawCount = 0;

      // MapScreen listener under P5.9.4 semantics
      void onNavManagerChanged() {
        final rev = navManager.renderRevision;
        final isNav = navManager.isNavigating;

        final revChanged = rev != lastObservedRenderRevision;
        final wasNavigating = lastObservedNavigating;
        final navigationStopped = wasNavigating && !isNav;
        final navigationStarted = !wasNavigating && isNav;

        lastObservedRenderRevision = rev;
        lastObservedNavigating = isNav;

        if (navigationStopped) {
          routes = [];
          return;
        }

        if (isNav && (revChanged || navigationStarted)) {
          redrawCount++;
          return;
        }

        if (!isNav && revChanged) {
          // Preview revision: DO NOT CLEAR routes!
          if (routes.isNotEmpty) {
            redrawCount++;
          }
        }
      }

      navManager.addListener(onNavManagerChanged);

      // Verify initial state: not navigating, routes populated
      expect(navManager.isNavigating, isFalse);
      expect(routes, isNotEmpty);

      // ACTION: calculateRoutesForPlace finishes and calls setPreviewRoute
      navManager.setPreviewRoute(sampleRoute);

      // ASSERTION: routes MUST NOT be cleared by the listener!
      expect(routes, isNotEmpty, reason: 'P5.9.4 fix: routes must NOT be wiped out by setPreviewRoute() notification');
      expect(routes.length, equals(1));
      expect(routes.first.summary, equals('Qua QL6'));
      expect(redrawCount, equals(1), reason: 'Map redraw should trigger without clearing routes');
      expect(navManager.previewRoute, equals(sampleRoute));

      navManager.removeListener(onNavManagerChanged);
    });

    test('P5.9.4 Navigation Stop: Transition from navigating -> stopped clears routes', () {
      final sampleRoute = createSampleRoute();
      List<NavRoute> routes = [sampleRoute];

      int lastObservedRenderRevision = navManager.renderRevision;
      bool lastObservedNavigating = navManager.isNavigating;

      void onNavManagerChanged() {
        final rev = navManager.renderRevision;
        final isNav = navManager.isNavigating;

        final revChanged = rev != lastObservedRenderRevision;
        final wasNavigating = lastObservedNavigating;
        final navigationStopped = wasNavigating && !isNav;
        final navigationStarted = !wasNavigating && isNav;

        lastObservedRenderRevision = rev;
        lastObservedNavigating = isNav;

        if (navigationStopped) {
          routes = [];
          return;
        }

        if (isNav && (revChanged || navigationStarted)) {
          return;
        }

        if (!isNav && revChanged) {
          if (routes.isNotEmpty) {}
        }
      }

      navManager.addListener(onNavManagerChanged);

      // Start navigation
      navManager.startNavigation(sampleRoute);
      expect(navManager.isNavigating, isTrue);

      // Stop navigation
      navManager.stopNavigation();
      expect(navManager.isNavigating, isFalse);

      // ASSERTION: routes MUST be cleared when navigation genuinely stops
      expect(routes, isEmpty, reason: 'Active route must be cleared when navigation is cancelled or stopped');
      expect(navManager.previewRoute, isNull);

      navManager.removeListener(onNavManagerChanged);
    });

    test('P5.9.4 Stop Navigation clears matched projection and resets matched location to physical', () {
      final sampleRoute = createSampleRoute();

      navManager.startNavigation(sampleRoute);
      expect(navManager.isNavigating, isTrue);

      // Stop navigation
      navManager.stopNavigation();

      expect(navManager.matchedProjection, isNull, reason: 'Matched projection must be reset on stop');
      expect(navManager.matchedLocation, equals(navManager.acceptedPhysicalLocation ?? navManager.rawLocation));
    });

    test('P5.9.4 Route planning prioritizes acceptedPhysicalLocation over stale matchedLocation', () {
      final physicalLoc = const LatLng(20.9785, 105.8340);
      final rawLoc = const LatLng(20.9780, 105.8335);
      final fallbackUserPos = const LatLng(21.0000, 105.8000);
      final staleMatchedLoc = const LatLng(21.5000, 106.5000);

      // 1. Accepted physical present -> accepted physical wins
      final start1 = MapScreen.selectRoutePlanningStart(
        acceptedPhysicalLocation: physicalLoc,
        rawLocation: rawLoc,
        fallbackLocation: fallbackUserPos,
      );
      expect(start1, equals(physicalLoc));
      expect(start1, isNot(equals(staleMatchedLoc)));

      // 2. Accepted null, raw present -> raw wins
      final start2 = MapScreen.selectRoutePlanningStart(
        acceptedPhysicalLocation: null,
        rawLocation: rawLoc,
        fallbackLocation: fallbackUserPos,
      );
      expect(start2, equals(rawLoc));
      expect(start2, isNot(equals(staleMatchedLoc)));

      // 3. Accepted null, raw null -> fallback wins
      final start3 = MapScreen.selectRoutePlanningStart(
        acceptedPhysicalLocation: null,
        rawLocation: null,
        fallbackLocation: fallbackUserPos,
      );
      expect(start3, equals(fallbackUserPos));
      expect(start3, isNot(equals(staleMatchedLoc)));

      // 4. Stale matchedLocation is never selected
      expect([start1, start2, start3], isNot(contains(staleMatchedLoc)));
    });
  });
}
