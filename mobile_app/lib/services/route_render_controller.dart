import 'dart:async';
import 'package:latlong2/latlong.dart';

enum RoutePresentationMode {
  none,
  preview,
  navigating,
  arrived,
}

/// Abstract line drawing interface allowing deterministic mocking in tests
/// and binding to MapLibreMapController in production.
abstract class MapLineDrawer {
  Future<void> clearLines();
  Future<void> drawPreviewRoutes({
    required List<LatLng> mainRoute,
    required List<List<LatLng>> alternativeRoutes,
  });
  Future<void> drawActiveRoute({
    required List<LatLng> remainingPolyline,
    List<LatLng>? secondaryPolyline,
  });
}

/// Representation of a route render request snapshot.
class RouteRenderRequest {
  final int generation;
  final int routeRevision;
  final RoutePresentationMode mode;
  final List<LatLng> mainPoints;
  final List<List<LatLng>> altPoints;

  RouteRenderRequest({
    required this.generation,
    required this.routeRevision,
    required this.mode,
    required this.mainPoints,
    this.altPoints = const [],
  });
}

/// Deterministic, single-flight, coalescing route render controller.
/// Guarantees:
/// 1. Stale render completions never overwrite newer state.
/// 2. Intermediate renders are dropped/coalesced so latest GPS state always wins.
/// 3. Route revision changes force an immediate redraw even if point counts or start coordinates match.
/// 4. Zero unbounded queues (at most 1 pending request).
class RouteRenderController {
  final MapLineDrawer _drawer;

  int _latestSubmittedGeneration = 0;
  int get latestSubmittedGeneration => _latestSubmittedGeneration;

  int _latestCommittedGeneration = 0;
  int get latestCommittedGeneration => _latestCommittedGeneration;

  int _lastRenderedRouteRevision = -1;
  int get lastRenderedRouteRevision => _lastRenderedRouteRevision;

  RoutePresentationMode _lastRenderedMode = RoutePresentationMode.none;
  RoutePresentationMode get lastRenderedMode => _lastRenderedMode;

  int _lastRenderedPointsCount = 0;
  int get lastRenderedPointsCount => _lastRenderedPointsCount;

  int _lastRenderedAltPointsCount = 0;
  int get lastRenderedAltPointsCount => _lastRenderedAltPointsCount;

  bool get hasPendingRequest => _pendingRequest != null;

  LatLng? _lastRenderedStartCoord;
  LatLng? get lastRenderedStartCoord => _lastRenderedStartCoord;

  int _renderCount = 0;
  int get renderCount => _renderCount;

  bool _isRendering = false;
  bool get isRendering => _isRendering;

  RouteRenderRequest? _pendingRequest;
  Completer<void>? _currentDrainCompleter;

  RouteRenderController(this._drawer);

  /// Determines if the proposed state requires a visual map update.
  bool shouldRender({
    required int routeRevision,
    required RoutePresentationMode mode,
    required List<LatLng> points,
    List<List<LatLng>> altPoints = const [],
    bool forceRedraw = false,
  }) {
    if (forceRedraw) return true;
    // Route revision change must ALWAYS trigger update
    if (routeRevision != _lastRenderedRouteRevision) return true;
    if (mode != _lastRenderedMode) return true;

    final altCount = altPoints.fold<int>(0, (sum, l) => sum + l.length);
    if (altCount != _lastRenderedAltPointsCount) return true;

    if (points.isEmpty) {
      return _lastRenderedPointsCount > 0;
    }
    if (points.length != _lastRenderedPointsCount) return true;

    if (_lastRenderedStartCoord != null && points.isNotEmpty) {
      const distCalc = Distance();
      final d = distCalc.as(LengthUnit.Meter, _lastRenderedStartCoord!, points.first);
      if (d >= 2.5) return true;
      return false;
    }

    return true;
  }

  /// Submits a route render request.
  /// If another render is currently in-flight, coalesces the request so that
  /// only the latest requested geometry executes when the current operation completes.
  Future<void> submitRequest({
    required int routeRevision,
    required RoutePresentationMode mode,
    required List<LatLng> mainPoints,
    List<List<LatLng>> altPoints = const [],
    bool forceRedraw = false,
  }) async {
    if (!shouldRender(
      routeRevision: routeRevision,
      mode: mode,
      points: mainPoints,
      altPoints: altPoints,
      forceRedraw: forceRedraw,
    )) {
      return;
    }

    final gen = ++_latestSubmittedGeneration;
    _pendingRequest = RouteRenderRequest(
      generation: gen,
      routeRevision: routeRevision,
      mode: mode,
      mainPoints: List.unmodifiable(mainPoints),
      altPoints: altPoints.map((l) => List<LatLng>.unmodifiable(l)).toList(),
    );

    if (_isRendering) {
      // An operation is already in flight.
      // The loop in _drainQueue will pick up _pendingRequest upon completion.
      return _currentDrainCompleter?.future ?? Future.value();
    }

    _isRendering = true;
    _currentDrainCompleter = Completer<void>();
    _drainQueue();
    return _currentDrainCompleter!.future;
  }

  Future<void> _drainQueue() async {
    while (_pendingRequest != null) {
      final req = _pendingRequest!;
      _pendingRequest = null;

      try {
        await _drawer.clearLines();

        if (req.mode == RoutePresentationMode.navigating) {
          if (req.mainPoints.length >= 2) {
            final sec = req.altPoints.isNotEmpty ? req.altPoints.first : null;
            await _drawer.drawActiveRoute(
              remainingPolyline: req.mainPoints,
              secondaryPolyline: sec,
            );
          }
        } else if (req.mode == RoutePresentationMode.preview) {
          if (req.mainPoints.length >= 2) {
            await _drawer.drawPreviewRoutes(
              mainRoute: req.mainPoints,
              alternativeRoutes: req.altPoints,
            );
          }
        }

        // P5.6.1 Section 8: Render transaction is an atomic unit (clearLines + drawActiveRoute).
        // Check if superseded during the transaction. If so, loop continues to execute newest request.
        if (req.generation < _latestSubmittedGeneration) {
          continue;
        }

        _latestCommittedGeneration = req.generation;
        _lastRenderedRouteRevision = req.routeRevision;
        _lastRenderedMode = req.mode;
        _lastRenderedPointsCount = req.mainPoints.length;
        _lastRenderedAltPointsCount = req.altPoints.fold<int>(0, (sum, l) => sum + l.length);
        _lastRenderedStartCoord = req.mainPoints.isNotEmpty ? req.mainPoints.first : null;
        _renderCount++;
      } catch (_) {
        // Tolerant to platform channel disposal during unmount
      }
    }

    _isRendering = false;
    final completer = _currentDrainCompleter;
    _currentDrainCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  /// Hard barrier that cancels and invalidates all current and queued renders,
  /// waits for any in-flight drawer operation to conclude, and executes a guaranteed
  /// final clearLines() to ensure MapLibre has zero remaining lines.
  Future<void> clearAndInvalidate() async {
    // 1. Invalidate all past and queued generations
    _latestSubmittedGeneration++;
    _pendingRequest = null;
    _lastRenderedRouteRevision = -1;
    _lastRenderedMode = RoutePresentationMode.none;
    _lastRenderedPointsCount = 0;
    _lastRenderedAltPointsCount = 0;
    _lastRenderedStartCoord = null;

    // 2. If a drain operation is currently running, wait for it to finish its current cycle
    final activeDrain = _currentDrainCompleter;
    if (_isRendering && activeDrain != null) {
      try {
        await activeDrain.future;
      } catch (_) {}
    }

    // 3. Guaranteed final barrier: execute clean clearLines on drawer
    try {
      await _drawer.clearLines();
    } catch (_) {}

    // 4. Double ensure controller state is fully reset
    _pendingRequest = null;
    _lastRenderedPointsCount = 0;
    _lastRenderedAltPointsCount = 0;
    _lastRenderedMode = RoutePresentationMode.none;
  }

  /// Resets state when leaving navigation or clearing map.
  /// Bumps _latestSubmittedGeneration to invalidate and abort any in-flight renders.
  void reset() {
    _latestSubmittedGeneration++;
    _lastRenderedRouteRevision = -1;
    _lastRenderedMode = RoutePresentationMode.none;
    _lastRenderedPointsCount = 0;
    _lastRenderedAltPointsCount = 0;
    _lastRenderedStartCoord = null;
    _pendingRequest = null;
  }
}
