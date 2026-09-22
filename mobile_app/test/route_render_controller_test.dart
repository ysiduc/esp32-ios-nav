import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile_app/services/route_render_controller.dart';

class MockMapLineDrawer implements MapLineDrawer {
  int clearLinesCallCount = 0;
  int drawActiveRouteCallCount = 0;
  int drawPreviewRoutesCallCount = 0;

  List<LatLng> lastDrawnActivePolyline = [];
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
  Future<void> drawActiveRoute({required List<LatLng> remainingPolyline}) async {
    drawActiveRouteCallCount++;
    lastDrawnActivePolyline = List.unmodifiable(remainingPolyline);
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

    test('Stale render race: Gen 1 in clearLines, Gen 2 requested -> Gen 1 draw aborted, Gen 2 commits', () async {
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

      // Gen 1 detected it was superseded (gen 1 < latestSubmitted 2), so drawActiveRoute was NOT called for Gen 1.
      // Gen 2 executed and committed.
      expect(controller.latestCommittedGeneration, 2);
      expect(drawer.lastDrawnActivePolyline, route2);
      expect(drawer.drawActiveRouteCallCount, 1); // Only Gen 2 drew lines!
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
  });
}
