import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile_app/services/route_render_controller.dart';

class MockMapLineDrawer implements MapLineDrawer {
  int clearLinesCallCount = 0;
  int drawActiveRouteCallCount = 0;
  int drawPreviewRoutesCallCount = 0;

  List<LatLng> lastDrawnActivePolyline = [];
  List<LatLng>? lastDrawnSecondaryPolyline;
  List<LatLng> lastDrawnMainRoute = [];
  List<List<LatLng>> lastDrawnAltRoutes = [];

  Duration clearDelay = Duration.zero;
  Duration drawDelay = Duration.zero;

  Completer<void>? onClearStarted;
  Completer<void>? onDrawStarted;

  @override
  Future<void> clearLines() async {
    clearLinesCallCount++;
    if (onClearStarted != null && !onClearStarted!.isCompleted) {
      onClearStarted!.complete();
    }
    if (clearDelay > Duration.zero) {
      await Future.delayed(clearDelay);
    }
  }

  @override
  Future<void> drawActiveRoute({
    required List<LatLng> remainingPolyline,
    List<LatLng>? secondaryPolyline,
  }) async {
    drawActiveRouteCallCount++;
    lastDrawnActivePolyline = List.unmodifiable(remainingPolyline);
    lastDrawnSecondaryPolyline = secondaryPolyline != null ? List.unmodifiable(secondaryPolyline) : null;
    if (onDrawStarted != null && !onDrawStarted!.isCompleted) {
      onDrawStarted!.complete();
    }
    if (drawDelay > Duration.zero) {
      await Future.delayed(drawDelay);
    }
  }

  @override
  Future<void> drawPreviewRoutes({
    required List<LatLng> mainRoute,
    required List<List<LatLng>> alternativeRoutes,
  }) async {
    drawPreviewRoutesCallCount++;
    lastDrawnMainRoute = List.unmodifiable(mainRoute);
    lastDrawnAltRoutes = alternativeRoutes.map((l) => List<LatLng>.unmodifiable(l)).toList();
    onDrawStarted?.complete();
    if (drawDelay > Duration.zero) {
      await Future.delayed(drawDelay);
    }
  }
}

void main() {
  group('P5.5.1 RouteRenderController Concurrency & Race Tests', () {
    test('Sequential renders execute cleanly and commit generation in order', () async {
      final drawer = MockMapLineDrawer();
      final controller = RouteRenderController(drawer);

      final route1 = [
        const LatLng(21.000, 105.000),
        const LatLng(21.001, 105.001),
      ];

      await controller.submitRequest(
        routeRevision: 1,
        mode: RoutePresentationMode.navigating,
        mainPoints: route1,
      );

      expect(controller.latestSubmittedGeneration, 1);
      expect(controller.latestCommittedGeneration, 1);
      expect(controller.lastRenderedRouteRevision, 1);
      expect(drawer.clearLinesCallCount, 1);
      expect(drawer.drawActiveRouteCallCount, 1);
      expect(drawer.lastDrawnActivePolyline, route1);
    });

    test('P5.6.1 Section 8: Render transaction is atomic unit: Gen 1 clears and draws without mid-channel abort, Gen 2 commits', () async {
      final drawer = MockMapLineDrawer();
      drawer.clearDelay = const Duration(milliseconds: 50);
      final controller = RouteRenderController(drawer);

      final route1 = [
        const LatLng(21.000, 105.000),
        const LatLng(21.001, 105.001),
      ];
      final route2 = [
        const LatLng(21.002, 105.002),
        const LatLng(21.003, 105.003),
      ];

      // Submit Gen 1 (starts clearing lines asynchronously)
      final fut1 = controller.submitRequest(
        routeRevision: 1,
        mode: RoutePresentationMode.navigating,
        mainPoints: route1,
      );

      expect(controller.isRendering, isTrue);
      expect(controller.latestSubmittedGeneration, 1);

      // Submit Gen 2 immediately while Gen 1 is still in clearDelay
      final fut2 = controller.submitRequest(
        routeRevision: 1,
        mode: RoutePresentationMode.navigating,
        mainPoints: route2,
      );

      expect(controller.latestSubmittedGeneration, 2);

      await Future.wait([fut1, fut2]);

      // Under atomic render transaction, Gen 1 draws its lines rather than leaving map blank, Gen 2 commits newest state.
      expect(controller.latestCommittedGeneration, 2);
      expect(drawer.lastDrawnActivePolyline, route2);
      expect(drawer.drawActiveRouteCallCount, 2);
    });

    test('Coalescing intermediate states: Updates 1, 2, 3 in rapid succession -> only latest update 3 runs', () async {
      final drawer = MockMapLineDrawer();
      drawer.clearDelay = const Duration(milliseconds: 40);
      drawer.drawDelay = const Duration(milliseconds: 40);
      final controller = RouteRenderController(drawer);

      final p1 = [const LatLng(21.0, 105.0), const LatLng(21.1, 105.1)];
      final p2 = [const LatLng(21.001, 105.001), const LatLng(21.1, 105.1)];
      final p3 = [const LatLng(21.002, 105.002), const LatLng(21.1, 105.1)];
      final p4 = [const LatLng(21.003, 105.003), const LatLng(21.1, 105.1)];

      // Start Request 1
      final f1 = controller.submitRequest(routeRevision: 1, mode: RoutePresentationMode.navigating, mainPoints: p1);

      // Rapidly submit requests 2, 3, 4 while Request 1 is working
      final f2 = controller.submitRequest(routeRevision: 1, mode: RoutePresentationMode.navigating, mainPoints: p2);
      final f3 = controller.submitRequest(routeRevision: 1, mode: RoutePresentationMode.navigating, mainPoints: p3);
      final f4 = controller.submitRequest(routeRevision: 1, mode: RoutePresentationMode.navigating, mainPoints: p4);

      await Future.wait([f1, f2, f3, f4]);

      // Request 1 aborted its draw. Requests 2 and 3 were coalesced. Request 4 won.
      expect(controller.latestCommittedGeneration, 4);
      expect(drawer.lastDrawnActivePolyline, p4);
      expect(controller.isRendering, isFalse);
    });

    test('Route revision change forces redraw even if point count and start coordinate match', () async {
      final drawer = MockMapLineDrawer();
      final controller = RouteRenderController(drawer);

      // Route A: 3 points starting at (21.0, 105.0)
      final routeA = [
        const LatLng(21.0000, 105.0000),
        const LatLng(21.0010, 105.0010),
        const LatLng(21.0020, 105.0020),
      ];

      await controller.submitRequest(
        routeRevision: 1,
        mode: RoutePresentationMode.navigating,
        mainPoints: routeA,
      );

      expect(drawer.drawActiveRouteCallCount, 1);
      expect(controller.lastRenderedRouteRevision, 1);

      // Route B: 3 points, starting less than 2.5m away (e.g. 0.5m displacement)
      final routeB = [
        const LatLng(21.000004, 105.000004),
        const LatLng(21.0050, 105.0050),
        const LatLng(21.0080, 105.0080),
      ];

      // If routeRevision is STILL 1: it would be skipped because point count matches and delta < 2.5m
      await controller.submitRequest(
        routeRevision: 1,
        mode: RoutePresentationMode.navigating,
        mainPoints: routeB,
      );
      expect(drawer.drawActiveRouteCallCount, 1, reason: 'Should skip if revision did not change');

      // Now with routeRevision: 2 (Route B committed by NavigationManager):
      await controller.submitRequest(
        routeRevision: 2,
        mode: RoutePresentationMode.navigating,
        mainPoints: routeB,
      );
      expect(drawer.drawActiveRouteCallCount, 2, reason: 'Revision bump must force redraw');
      expect(drawer.lastDrawnActivePolyline, routeB);
      expect(controller.lastRenderedRouteRevision, 2);
    });

    test('Mode transition to arrived or none clears lines and records empty geometry', () async {
      final drawer = MockMapLineDrawer();
      final controller = RouteRenderController(drawer);

      final route = [
        const LatLng(21.000, 105.000),
        const LatLng(21.001, 105.001),
      ];

      await controller.submitRequest(
        routeRevision: 1,
        mode: RoutePresentationMode.navigating,
        mainPoints: route,
      );
      expect(drawer.drawActiveRouteCallCount, 1);

      // Arrived mode
      await controller.submitRequest(
        routeRevision: 1,
        mode: RoutePresentationMode.arrived,
        mainPoints: [],
      );

      expect(drawer.clearLinesCallCount, 2);
      expect(drawer.drawActiveRouteCallCount, 1); // No new lines added
      expect(controller.lastRenderedPointsCount, 0);
      expect(controller.lastRenderedMode, RoutePresentationMode.arrived);
    });
    test('P5.5.2 Section 6: Stale render race: Gen 1 in drawActiveRoute, Gen 2 requested -> Gen 1 commit aborted, Gen 2 commits', () async {
      final drawer = MockMapLineDrawer();
      drawer.drawDelay = const Duration(milliseconds: 50);
      drawer.onDrawStarted = Completer<void>();
      final controller = RouteRenderController(drawer);

      final route1 = [
        const LatLng(21.000, 105.000),
        const LatLng(21.001, 105.001),
      ];
      final route2 = [
        const LatLng(21.002, 105.002),
        const LatLng(21.003, 105.003),
      ];

      // Submit Gen 1 (enters drawActiveRoute)
      final fut1 = controller.submitRequest(
        routeRevision: 1,
        mode: RoutePresentationMode.navigating,
        mainPoints: route1,
      );

      // Wait until Gen 1 has started drawing
      await drawer.onDrawStarted!.future;
      expect(controller.isRendering, isTrue);

      // Submit Gen 2 while Gen 1 is actively inside drawActiveRoute delay
      final fut2 = controller.submitRequest(
        routeRevision: 1,
        mode: RoutePresentationMode.navigating,
        mainPoints: route2,
      );

      await Future.wait([fut1, fut2]);

      // Gen 1 detected it was superseded after drawActiveRoute and skipped commit.
      // Gen 2 then cleared lines and committed its geometry.
      expect(controller.latestCommittedGeneration, 2);
      expect(drawer.lastDrawnActivePolyline, route2);
      expect(controller.isRendering, isFalse);
    });

    test('P5.5.2 Section 7: Reset invalidates in-flight render and prevents stale geometry commit', () async {
      final drawer = MockMapLineDrawer();
      drawer.drawDelay = const Duration(milliseconds: 50);
      drawer.onDrawStarted = Completer<void>();
      final controller = RouteRenderController(drawer);

      final route1 = [
        const LatLng(21.000, 105.000),
        const LatLng(21.001, 105.001),
      ];

      final fut1 = controller.submitRequest(
        routeRevision: 1,
        mode: RoutePresentationMode.navigating,
        mainPoints: route1,
      );

      await drawer.onDrawStarted!.future;

      // Reset called while Gen 1 is in flight
      controller.reset();

      await fut1;

      // Gen 1 was aborted by reset() generation bump
      expect(controller.latestCommittedGeneration, 0);
      expect(controller.lastRenderedMode, RoutePresentationMode.none);
      expect(controller.lastRenderedPointsCount, 0);
      expect(controller.isRendering, isFalse);
    });

    test('P5.5.2 Section 7: Stop navigation mode none supersedes pending render leaving map empty', () async {
      final drawer = MockMapLineDrawer();
      drawer.clearDelay = const Duration(milliseconds: 40);
      final controller = RouteRenderController(drawer);

      final route1 = [
        const LatLng(21.000, 105.000),
        const LatLng(21.001, 105.001),
      ];

      final fut1 = controller.submitRequest(
        routeRevision: 1,
        mode: RoutePresentationMode.navigating,
        mainPoints: route1,
      );

      // Navigation stops: mode none requested immediately
      final fut2 = controller.submitRequest(
        routeRevision: 2,
        mode: RoutePresentationMode.none,
        mainPoints: [],
        forceRedraw: true,
      );

      await Future.wait([fut1, fut2]);

      expect(controller.latestCommittedGeneration, 2);
      expect(controller.lastRenderedMode, RoutePresentationMode.none);
      expect(controller.lastRenderedPointsCount, 0);
      expect(controller.isRendering, isFalse);
    });
  
    test('P5.6 Section 10: Dual-route primary + secondary route drawing and persistence', () async {
      final drawer = MockMapLineDrawer();
      final controller = RouteRenderController(drawer);

      final primary = [
        const LatLng(21.000, 105.000),
        const LatLng(21.001, 105.001),
      ];
      final secondary = [
        const LatLng(21.000, 105.000),
        const LatLng(21.000, 105.002),
        const LatLng(21.000, 105.005),
      ];

      await controller.submitRequest(
        routeRevision: 2,
        mode: RoutePresentationMode.navigating,
        mainPoints: primary,
        altPoints: [secondary],
      );

      expect(drawer.drawActiveRouteCallCount, 1);
      expect(drawer.lastDrawnActivePolyline, primary);
      expect(drawer.lastDrawnSecondaryPolyline, secondary);
      expect(controller.lastRenderedRouteRevision, 2);

      // Now cancel navigation -> both must clear cleanly
      controller.reset();
      await controller.submitRequest(
        routeRevision: 3,
        mode: RoutePresentationMode.none,
        mainPoints: [],
        
        forceRedraw: true,
      );

      expect(controller.lastRenderedMode, RoutePresentationMode.none);
      expect(controller.lastRenderedPointsCount, 0);
    });

    test('P5.6 Section 5: Rapid 10 Hz GPS cadence does not starve or freeze render queue', () async {
      final drawer = MockMapLineDrawer();
      drawer.clearDelay = const Duration(milliseconds: 10);
      drawer.drawDelay = const Duration(milliseconds: 10);
      final controller = RouteRenderController(drawer);

      final futures = <Future<void>>[];
      for (int i = 0; i < 10; i++) {
        final pts = [
          LatLng(21.0 + i * 0.0001, 105.0 + i * 0.0001),
          const LatLng(21.01, 105.01),
        ];
        futures.add(controller.submitRequest(
          routeRevision: 1,
          mode: RoutePresentationMode.navigating,
          mainPoints: pts,
        ));
      }

      await Future.wait(futures);

      expect(controller.isRendering, isFalse);
      expect(controller.latestCommittedGeneration, 10);
      expect(drawer.lastDrawnActivePolyline.first.latitude, closeTo(21.0009, 0.00001));
    });
  
    test('P5.6.1 Section 9 Scenario A: High platform latency (clear 180ms, draw 120ms) with 100ms GPS does not starve', () async {
      final drawer = MockMapLineDrawer();
      drawer.clearDelay = const Duration(milliseconds: 18); // Scaled 10x for fast CI test execution
      drawer.drawDelay = const Duration(milliseconds: 12);
      final controller = RouteRenderController(drawer);

      final futures = <Future<void>>[];
      for (int i = 1; i <= 20; i++) {
        final pts = [
          LatLng(21.0 + i * 0.0001, 105.0 + i * 0.0001),
          const LatLng(21.05, 105.05),
        ];
        futures.add(controller.submitRequest(
          routeRevision: 1,
          mode: RoutePresentationMode.navigating,
          mainPoints: pts,
        ));
        await Future.delayed(const Duration(milliseconds: 10));
      }

      await Future.wait(futures);

      expect(controller.isRendering, isFalse);
      expect(controller.hasPendingRequest, isFalse);
      expect(drawer.drawActiveRouteCallCount, greaterThanOrEqualTo(2), reason: 'Must not be starved into 0 draws');
      expect(controller.latestCommittedGeneration, 20);
      expect(drawer.lastDrawnActivePolyline.first.latitude, closeTo(21.0020, 0.00001));
    });

    test('P5.6.1 Section 9 Scenario B: Update every 25ms (clear 30ms, draw 20ms) avoids endless clear loop', () async {
      final drawer = MockMapLineDrawer();
      drawer.clearDelay = const Duration(milliseconds: 30);
      drawer.drawDelay = const Duration(milliseconds: 20);
      final controller = RouteRenderController(drawer);

      final futures = <Future<void>>[];
      for (int i = 1; i <= 10; i++) {
        final pts = [
          LatLng(21.0 + i * 0.0002, 105.0 + i * 0.0002),
          const LatLng(21.05, 105.05),
        ];
        futures.add(controller.submitRequest(
          routeRevision: 1,
          mode: RoutePresentationMode.navigating,
          mainPoints: pts,
        ));
        await Future.delayed(const Duration(milliseconds: 25));
      }

      await Future.wait(futures);

      expect(controller.isRendering, isFalse);
      expect(controller.hasPendingRequest, isFalse);
      expect(drawer.drawActiveRouteCallCount, greaterThanOrEqualTo(2));
      expect(controller.latestCommittedGeneration, 10);
      expect(drawer.lastDrawnActivePolyline.first.latitude, closeTo(21.0020, 0.00001));
    });

    test('P5.6.1 Section 9 Scenario C: Stop navigation during active render leaves map cleanly empty', () async {
      final drawer = MockMapLineDrawer();
      drawer.clearDelay = const Duration(milliseconds: 40);
      drawer.drawDelay = const Duration(milliseconds: 40);
      drawer.onDrawStarted = Completer<void>();
      final controller = RouteRenderController(drawer);

      final pts = [
        const LatLng(21.0, 105.0),
        const LatLng(21.05, 105.05),
      ];

      final f1 = controller.submitRequest(
        routeRevision: 1,
        mode: RoutePresentationMode.navigating,
        mainPoints: pts,
      );

      await drawer.onDrawStarted!.future;

      // User cancels navigation during draw
      controller.reset();
      final f2 = controller.submitRequest(
        routeRevision: 2,
        mode: RoutePresentationMode.none,
        mainPoints: [],
        forceRedraw: true,
      );

      await Future.wait([f1, f2]);

      expect(controller.isRendering, isFalse);
      expect(controller.lastRenderedMode, RoutePresentationMode.none);
      expect(controller.lastRenderedPointsCount, 0);
    });

    test('P5.6.1 Section 10: Primary unchanged, secondary async result arrives triggers immediate redraw', () async {
      final drawer = MockMapLineDrawer();
      final controller = RouteRenderController(drawer);

      final primary = [
        const LatLng(21.0, 105.0),
        const LatLng(21.1, 105.1),
      ];

      // Initial render: Primary only (Secondary null / empty)
      await controller.submitRequest(
        routeRevision: 1,
        mode: RoutePresentationMode.navigating,
        mainPoints: primary,
        altPoints: [],
      );

      expect(drawer.drawActiveRouteCallCount, 1);
      expect(drawer.lastDrawnSecondaryPolyline, isNull);

      // Async secondary arrives later: primary points identical, but altPoints has secondary
      final secondary = [
        const LatLng(21.0, 105.0),
        const LatLng(21.02, 105.02),
      ];

      await controller.submitRequest(
        routeRevision: 2, // renderRevision bumped
        mode: RoutePresentationMode.navigating,
        mainPoints: primary,
        altPoints: [secondary],
      );

      expect(drawer.drawActiveRouteCallCount, 2, reason: 'Must redraw when secondary route arrives');
      expect(drawer.lastDrawnSecondaryPolyline, equals(secondary));
    });
    test('P5.7 Part B: clearAndInvalidate cancels in-flight draw and guarantees empty map', () async {
      final drawer = MockMapLineDrawer();
      final controller = RouteRenderController(drawer);

      drawer.drawDelay = const Duration(milliseconds: 60);
      final drawStarted = Completer<void>();
      drawer.onDrawStarted = drawStarted;

      // Submit a navigation render request
      final renderFuture = controller.submitRequest(
        routeRevision: 1,
        mode: RoutePresentationMode.navigating,
        mainPoints: [const LatLng(21.0, 105.0), const LatLng(21.1, 105.1)],
        forceRedraw: true,
      );

      // Wait until drawer has started drawing
      await drawStarted.future;
      expect(controller.isRendering, isTrue);

      // Hard cancel while draw is in progress
      final cancelFuture = controller.clearAndInvalidate();

      // Wait for both to complete
      await Future.wait([renderFuture, cancelFuture]);

      // Controller state must be none and map must be clean
      expect(controller.isRendering, isFalse);
      expect(controller.lastRenderedMode, equals(RoutePresentationMode.none));
      expect(drawer.clearLinesCallCount, greaterThanOrEqualTo(2));
      expect(controller.hasPendingRequest, isFalse);
    });

    test('P5.7 Part B: clearAndInvalidate while renderer is in clear phase guarantees clean state', () async {
      final drawer = MockMapLineDrawer();
      final controller = RouteRenderController(drawer);

      drawer.clearDelay = const Duration(milliseconds: 50);
      final clearStarted = Completer<void>();
      drawer.onClearStarted = clearStarted;

      final renderFuture = controller.submitRequest(
        routeRevision: 1,
        mode: RoutePresentationMode.navigating,
        mainPoints: [const LatLng(21.0, 105.0), const LatLng(21.1, 105.1)],
        forceRedraw: true,
      );

      await clearStarted.future;
      expect(controller.isRendering, isTrue);

      final cancelFuture = controller.clearAndInvalidate();
      await Future.wait([renderFuture, cancelFuture]);

      expect(controller.isRendering, isFalse);
      expect(controller.lastRenderedMode, equals(RoutePresentationMode.none));
    });

    test('P5.7 Part B: Rapid cancel/start/cancel sequence results in guaranteed empty map', () async {
      final drawer = MockMapLineDrawer();
      final controller = RouteRenderController(drawer);

      // Rapid flurry of requests
      controller.submitRequest(
        routeRevision: 1,
        mode: RoutePresentationMode.navigating,
        mainPoints: [const LatLng(21.0, 105.0), const LatLng(21.1, 105.1)],
      );
      controller.clearAndInvalidate();
      controller.submitRequest(
        routeRevision: 2,
        mode: RoutePresentationMode.navigating,
        mainPoints: [const LatLng(21.0, 105.0), const LatLng(21.2, 105.2)],
      );
      await controller.clearAndInvalidate();

      expect(controller.isRendering, isFalse);
      expect(controller.lastRenderedMode, equals(RoutePresentationMode.none));
      expect(controller.hasPendingRequest, isFalse);
    });
  });
}
