import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import '../config/mapbox_config.dart';
import '../models/route_model.dart';
import 'osrm_service.dart';
import 'valhalla_service.dart';

typedef ValhallaRouteProvider = Future<NavRoute?> Function(
  LatLng start,
  LatLng destination, {
  required String costing,
});

typedef OsrmRouteProvider = Future<List<NavRoute>> Function(
  LatLng start,
  LatLng destination, {
  required String mode,
});

typedef MapboxRouteProvider = Future<List<NavRoute>> Function(
  LatLng start,
  LatLng destination, {
  required String mode,
});

typedef NearestSnapProvider = Future<OsrmSnapResult> Function(
  LatLng point, {
  double maxRadiusMeters,
});

class _CandidateResult {
  final List<NavRoute> routes;
  final RouteProvider provider;
  const _CandidateResult(this.routes, this.provider);
}

RouteProvider routeProviderFromString(String str) {
  switch (str.toLowerCase()) {
    case 'valhalla':
      return RouteProvider.valhalla;
    case 'osrm':
      return RouteProvider.osrm;
    case 'mapbox':
      return RouteProvider.mapbox;
    case 'synthetic':
    default:
      return RouteProvider.synthetic;
  }
}

/// Navigation Directions Service
/// Unifies Valhalla motorcycle routing with OSRM fallback and Mapbox fallback.
/// Enforces staggered concurrency (racing) and an 8-second hard deadline.
class MapboxDirectionsService {
  static final Map<String, List<NavRoute>> _routeCache = {};
  static void clearCache() => _routeCache.clear();
  final OsrmService _osrmService;
  final ValhallaService _valhallaService;

  // Test injection hooks
  ValhallaRouteProvider? valhallaProvider;
  OsrmRouteProvider? osrmProvider;
  MapboxRouteProvider? mapboxProvider;
  NearestSnapProvider? nearestSnapProvider;

  MapboxDirectionsService({
    OsrmService? osrmService,
    ValhallaService? valhallaService,
    this.valhallaProvider,
    this.osrmProvider,
    this.mapboxProvider,
    this.nearestSnapProvider,
  })  : _osrmService = osrmService ?? OsrmService(),
        _valhallaService = valhallaService ?? ValhallaService();

  /// Validate coordinates range: lat [-90, 90], lon [-180, 180]
  static bool isValidCoordinate(LatLng coord) {
    if (coord.latitude.isNaN || coord.latitude.isInfinite ||
        coord.longitude.isNaN || coord.longitude.isInfinite) {
      return false;
    }
    if (coord.latitude < -90.0 || coord.latitude > 90.0) return false;
    if (coord.longitude < -180.0 || coord.longitude > 180.0) return false;
    return true;
  }

  /// Primary route calculation API returning detailed [RouteCalculationResult].
  /// Uses staggered concurrency:
  /// - T0: starts primary provider (Valhalla for bike, OSRM for driving)
  /// - T0 + 1.5s: if pending, starts secondary fallback in parallel
  /// - First valid non-empty real route wins
  /// - 8s hard deadline cancels and returns failure
  Future<RouteCalculationResult> calculateRoutesDetailed(
    LatLng start,
    LatLng destination, {
    String mode = 'bike',
    bool avoidTolls = false,
    bool avoidHighways = false,
    Duration staggeredDelay = const Duration(milliseconds: 1500),
    Duration hardDeadline = const Duration(milliseconds: 8000),
    bool allowSnapRecovery = true,
    double maxSnapMeters = 300.0,
  }) async {
    final stopwatch = Stopwatch()..start();
    final List<ProviderRouteResult> diagnostics = [];

    // 1. Coordinate Validation
    if (!isValidCoordinate(start) || !isValidCoordinate(destination)) {
      debugPrint('[Routing] Invalid coordinates: start=$start, dest=$destination');
      return RouteCalculationResult.failed(
        provider: RouteProvider.mapbox,
        latency: stopwatch.elapsed,
        failure: RouteFailureReason.invalidCoordinates,
        errorMessage: 'Tọa độ không hợp lệ',
      );
    }

    if ((start.latitude == 0.0 && start.longitude == 0.0) ||
        (destination.latitude == 0.0 && destination.longitude == 0.0)) {
      debugPrint('[Routing] Null island (0,0) coordinate rejected');
      return RouteCalculationResult.failed(
        provider: RouteProvider.mapbox,
        latency: stopwatch.elapsed,
        failure: RouteFailureReason.invalidCoordinates,
        errorMessage: 'Tọa độ vị trí (0,0) không hợp lệ',
      );
    }

    // Check in-memory cache
    final cacheKey =
        '${start.latitude.toStringAsFixed(4)},${start.longitude.toStringAsFixed(4)}'
        '-${destination.latitude.toStringAsFixed(4)},${destination.longitude.toStringAsFixed(4)}-$mode';
    if (_routeCache.containsKey(cacheKey)) {
      final cached = _routeCache[cacheKey]!;
      if (cached.isNotEmpty) {
        return RouteCalculationResult(
          routes: cached,
          provider: routeProviderFromString(cached.first.provider),
          latency: stopwatch.elapsed,
        );
      }
    }

    // Determine primary and fallback providers
    final RouteProvider primaryProvider;
    final RouteProvider secondaryProvider;
    final Future<List<NavRoute>> Function() fetchPrimary;
    final Future<List<NavRoute>> Function() fetchSecondary;

    if (mode == 'bike') {
      primaryProvider = RouteProvider.valhalla;
      secondaryProvider = RouteProvider.osrm;

      fetchPrimary = () async {
        if (valhallaProvider != null) {
          final r = await valhallaProvider!(start, destination, costing: 'motorcycle');
          if (r != null) {
            return [r.copyWith(provider: 'valhalla', isFallbackSynthetic: false)];
          }
          return [];
        } else {
          final res = await _valhallaService.calculateRouteDetailed(
            start,
            destination,
            costing: 'motorcycle',
            timeout: const Duration(seconds: 5),
          );
          diagnostics.add(res);
          return res.routes;
        }
      };

      fetchSecondary = () async {
        if (osrmProvider != null) {
          final list = await osrmProvider!(start, destination, mode: 'bike');
          return list.map((r) => r.copyWith(provider: 'osrm', isFallbackSynthetic: false)).toList();
        } else {
          final res = await _osrmService.fetchOsrmRoutesDetailed(
            start,
            destination,
            mode: 'bike',
            timeout: const Duration(seconds: 4),
          );
          diagnostics.add(res);
          return res.routes;
        }
      };
    } else if (mode == 'foot') {
      primaryProvider = RouteProvider.valhalla;
      secondaryProvider = RouteProvider.osrm;

      fetchPrimary = () async {
        if (valhallaProvider != null) {
          final r = await valhallaProvider!(start, destination, costing: 'pedestrian');
          if (r != null) {
            return [r.copyWith(provider: 'valhalla', isFallbackSynthetic: false)];
          }
          return [];
        } else {
          final res = await _valhallaService.calculateRouteDetailed(
            start,
            destination,
            costing: 'pedestrian',
            timeout: const Duration(seconds: 5),
          );
          diagnostics.add(res);
          return res.routes;
        }
      };

      fetchSecondary = () async {
        if (osrmProvider != null) {
          final list = await osrmProvider!(start, destination, mode: 'foot');
          return list.map((r) => r.copyWith(provider: 'osrm', isFallbackSynthetic: false)).toList();
        } else {
          final res = await _osrmService.fetchOsrmRoutesDetailed(
            start,
            destination,
            mode: 'foot',
            timeout: const Duration(seconds: 4),
          );
          diagnostics.add(res);
          return res.routes;
        }
      };
    } else {
      // 'driving'
      primaryProvider = RouteProvider.osrm;
      secondaryProvider = RouteProvider.valhalla;

      fetchPrimary = () async {
        if (osrmProvider != null) {
          final list = await osrmProvider!(start, destination, mode: 'driving');
          return list.map((r) => r.copyWith(provider: 'osrm', isFallbackSynthetic: false)).toList();
        } else {
          final res = await _osrmService.fetchOsrmRoutesDetailed(
            start,
            destination,
            mode: 'driving',
            timeout: const Duration(seconds: 4),
          );
          diagnostics.add(res);
          return res.routes;
        }
      };

      fetchSecondary = () async {
        if (valhallaProvider != null) {
          final r = await valhallaProvider!(start, destination, costing: 'auto');
          if (r != null) {
            return [r.copyWith(provider: 'valhalla', isFallbackSynthetic: false)];
          }
          return [];
        } else {
          final res = await _valhallaService.calculateRouteDetailed(
            start,
            destination,
            costing: 'auto',
            timeout: const Duration(seconds: 5),
          );
          diagnostics.add(res);
          return res.routes;
        }
      };
    }

    debugPrint(
      '[Routing] Start calculation: start=(${start.latitude.toStringAsFixed(4)}, ${start.longitude.toStringAsFixed(4)}) '
      'dest=(${destination.latitude.toStringAsFixed(4)}, ${destination.longitude.toStringAsFixed(4)}) '
      'mode=$mode primary=${primaryProvider.name}',
    );

    // Staggered race with hard deadline
    final completer = Completer<_CandidateResult>();
    Timer? fallbackTimer;
    bool anyWinner = false;
    bool primaryFinished = false;
    bool secondaryLaunched = false;
    bool secondaryFinished = false;

    void launchSecondary() {
      if (secondaryLaunched || completer.isCompleted || anyWinner) return;
      secondaryLaunched = true;
      fallbackTimer?.cancel();
      debugPrint('[Routing] Launching fallback ${secondaryProvider.name} in parallel');
      fetchSecondary().then((routes) {
        secondaryFinished = true;
        if (completer.isCompleted) return;
        if (routes.isNotEmpty && !routes.first.isFallbackSynthetic) {
          anyWinner = true;
          completer.complete(_CandidateResult(routes, secondaryProvider));
        } else if (primaryFinished && !anyWinner) {
          completer.complete(_CandidateResult(const [], secondaryProvider));
        }
      }).catchError((e) {
        debugPrint('[Routing] Fallback ${secondaryProvider.name} failed: $e');
        secondaryFinished = true;
        if (!completer.isCompleted && primaryFinished && !anyWinner) {
          completer.complete(_CandidateResult(const [], secondaryProvider));
        }
      });
    }

    void handlePrimaryResult(List<NavRoute> routes) {
      primaryFinished = true;
      if (completer.isCompleted) return;
      if (routes.isNotEmpty && !routes.first.isFallbackSynthetic) {
        anyWinner = true;
        completer.complete(_CandidateResult(routes, primaryProvider));
      } else {
        if (!secondaryLaunched) {
          launchSecondary();
        } else if (secondaryFinished && !anyWinner) {
          completer.complete(_CandidateResult(const [], primaryProvider));
        }
      }
    }

    // 1. Launch Primary at T0
    fetchPrimary().then((routes) {
      handlePrimaryResult(routes);
    }).catchError((e) {
      debugPrint('[Routing] Primary ${primaryProvider.name} failed: $e');
      handlePrimaryResult([]);
    });

    // 2. Schedule Secondary at T0 + staggeredDelay if primary still pending
    fallbackTimer = Timer(staggeredDelay, () {
      if (!completer.isCompleted && !anyWinner && !secondaryLaunched) {
        debugPrint('[Routing] Primary still pending after ${staggeredDelay.inMilliseconds}ms -> launching fallback ${secondaryProvider.name} in parallel');
        launchSecondary();
      }
    });

    try {
      final winner = await completer.future.timeout(hardDeadline);
      fallbackTimer.cancel();

      if (winner.routes.isNotEmpty) {
        final classified = _classifyAndRankRoutes(winner.routes, mode);
        _routeCache[cacheKey] = classified;
        if (_routeCache.length > 50) {
          _routeCache.remove(_routeCache.keys.first);
        }
        return RouteCalculationResult(
          routes: classified,
          provider: winner.provider,
          latency: stopwatch.elapsed,
          providerDiagnostics: diagnostics,
        );
      }

      // Check if both providers returned unroutable / noSegment / noRoute -> Attempt Snap Recovery (Item 6 & 7)
      if (allowSnapRecovery) {
        final hasRateLimit = diagnostics.any((d) => d.errorType == 'rateLimited');
        final hasDns = diagnostics.any((d) => d.errorType == 'dns');
        final hasTls = diagnostics.any((d) => d.errorType == 'tls');

        if (!hasRateLimit && !hasDns && !hasTls) {
          debugPrint('[Routing] Attempting routable snap recovery for destination $destination');
          final snapDest = nearestSnapProvider != null
              ? await nearestSnapProvider!(destination, maxRadiusMeters: maxSnapMeters)
              : await _osrmService.findNearestRoutablePoint(
                  destination,
                  maxRadiusMeters: maxSnapMeters,
                  timeout: const Duration(seconds: 2),
                );

          if (snapDest.success && snapDest.snapped != destination) {
            final remainingBudget = hardDeadline - stopwatch.elapsed;
            if (remainingBudget > const Duration(seconds: 2)) {
              debugPrint('[Routing] Snapped to nearest road (${snapDest.distanceMeters.toStringAsFixed(1)}m). Retrying route...');
              final retryResult = await calculateRoutesDetailed(
                start,
                snapDest.snapped,
                mode: mode,
                avoidTolls: avoidTolls,
                avoidHighways: avoidHighways,
                allowSnapRecovery: false, // Prevent multiple recursion
                hardDeadline: remainingBudget,
              );
              if (retryResult.isSuccess) {
                return RouteCalculationResult(
                  routes: retryResult.routes,
                  provider: retryResult.provider,
                  latency: stopwatch.elapsed,
                  providerDiagnostics: [...diagnostics, ...retryResult.providerDiagnostics],
                  snapDistanceMeters: snapDest.distanceMeters,
                  snappedDestination: snapDest.snapped,
                );
              }
            }
          } else if (!snapDest.success && snapDest.distanceMeters > maxSnapMeters) {
            return RouteCalculationResult.failed(
              provider: primaryProvider,
              latency: stopwatch.elapsed,
              failure: RouteFailureReason.noRoute,
              errorMessage: 'Điểm đến nằm quá xa đường giao thông (cách ${snapDest.distanceMeters.toStringAsFixed(0)}m, tối đa ${maxSnapMeters.toStringAsFixed(0)}m)',
              providerDiagnostics: diagnostics,
            );
          }
        }
      }

      // Try Mapbox if configured (Item 12: verified accessToken)
      if (MapboxConfig.accessToken.isNotEmpty || mapboxProvider != null) {
        final mapboxRoutes = mapboxProvider != null
            ? await mapboxProvider!(start, destination, mode: mode)
            : await _fetchFromMapbox(start, destination, mode: mode);
        if (mapboxRoutes.isNotEmpty) {
          final classified = _classifyAndRankRoutes(mapboxRoutes, mode);
          _routeCache[cacheKey] = classified;
          return RouteCalculationResult(
            routes: classified,
            provider: RouteProvider.mapbox,
            latency: stopwatch.elapsed,
            providerDiagnostics: diagnostics,
          );
        }
      }

      // Format diagnostic-rich user failure message (Item 11)
      String failureMsg = 'Không tìm thấy lộ trình phù hợp';
      RouteFailureReason failureReason = RouteFailureReason.noRoute;

      if (diagnostics.any((d) => d.errorType == 'rateLimited')) {
        failureReason = RouteFailureReason.providerRejected;
        failureMsg = 'Dịch vụ định tuyến đang quá tải. Vui lòng thử lại sau giây lát.';
      } else if (diagnostics.any((d) => d.errorType == 'dns' || d.errorType == 'network')) {
        failureReason = RouteFailureReason.noNetwork;
        failureMsg = 'Không thể kết nối máy chủ định tuyến. Kiểm tra mạng và thử lại.';
      } else if (diagnostics.any((d) => d.errorType == 'noSegment')) {
        failureReason = RouteFailureReason.noRoute;
        failureMsg = 'Không tìm thấy đường nối giữa vị trí của bạn và điểm đến.';
      }

      return RouteCalculationResult.failed(
        provider: primaryProvider,
        latency: stopwatch.elapsed,
        failure: failureReason,
        errorMessage: failureMsg,
        providerDiagnostics: diagnostics,
      );
    } on TimeoutException {
      fallbackTimer.cancel();
      debugPrint('[Routing] Hard deadline (${hardDeadline.inSeconds}s) reached without response');
      return RouteCalculationResult.failed(
        provider: primaryProvider,
        latency: stopwatch.elapsed,
        failure: RouteFailureReason.timeout,
        errorMessage: 'Quá thời gian tính toán lộ trình (${hardDeadline.inSeconds} giây). Kiểm tra mạng và thử lại.',
        providerDiagnostics: diagnostics,
      );
    } catch (e) {
      fallbackTimer.cancel();
      return RouteCalculationResult.failed(
        provider: primaryProvider,
        latency: stopwatch.elapsed,
        failure: RouteFailureReason.providerRejected,
        errorMessage: 'Lỗi định tuyến: $e',
        providerDiagnostics: diagnostics,
      );
    }
  }

  /// Backward-compatible method returning route list
  Future<List<NavRoute>> calculateMultipleRoutes(
    LatLng start,
    LatLng destination, {
    String mode = 'bike',
    bool avoidTolls = false,
    bool avoidHighways = false,
  }) async {
    final result = await calculateRoutesDetailed(
      start,
      destination,
      mode: mode,
      avoidTolls: avoidTolls,
      avoidHighways: avoidHighways,
    );
    return result.routes;
  }

  /// Single route calculation
  Future<NavRoute?> calculateRoute(
    LatLng start,
    LatLng destination, {
    String profile = 'bike',
  }) async {
    final list = await calculateMultipleRoutes(start, destination, mode: profile);
    return list.isNotEmpty ? list.first : null;
  }

  Future<List<NavRoute>> _fetchFromMapbox(
    LatLng start,
    LatLng destination, {
    required String mode,
  }) async {
    try {
      final profile = _modeToMapboxProfile(mode);
      final url = MapboxConfig.directionsUrl(
        profile: profile,
        startLng: start.longitude,
        startLat: start.latitude,
        endLng: destination.longitude,
        endLat: destination.latitude,
        alternatives: true,
      );

      final response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 4));

      if (response.statusCode != 200) return [];

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final rawRoutes = data['routes'] as List? ?? [];
      if (rawRoutes.isEmpty) return [];

      final parsedRoutes = <NavRoute>[];
      for (int rIdx = 0; rIdx < rawRoutes.length; rIdx++) {
        final routeJson = rawRoutes[rIdx] as Map<String, dynamic>;
        final route = _parseMapboxRoute(routeJson, rIdx, mode: mode);
        if (route != null) parsedRoutes.add(route);
      }
      return parsedRoutes;
    } catch (_) {
      return [];
    }
  }

  NavRoute? _parseMapboxRoute(
    Map<String, dynamic> routeJson,
    int rIdx, {
    required String mode,
  }) {
    try {
      final totalDistance = (routeJson['distance'] as num).toDouble();
      var totalDuration = (routeJson['duration'] as num).toDouble();

      // Adjust for Vietnamese motorbike real-world speed
      if (mode == 'bike') {
        final avgSpeedKmh = totalDistance > 10000 ? 40.0 : 30.0;
        totalDuration = (totalDistance / 1000.0) / avgSpeedKmh * 3600.0;
      }

      final geometry = routeJson['geometry'] as Map<String, dynamic>;
      final coordsList = geometry['coordinates'] as List;
      final polylinePoints = coordsList.map<LatLng>((coord) {
        return LatLng(
          (coord[1] as num).toDouble(),
          (coord[0] as num).toDouble(),
        );
      }).toList();

      final steps = <NavStep>[];
      final legs = routeJson['legs'] as List? ?? [];
      int globalStepIndex = 0;

      String summary = 'Lộ trình ${rIdx + 1}';
      if (legs.isNotEmpty) {
        final legSummary = legs[0]['summary'] as String? ?? '';
        if (legSummary.isNotEmpty) summary = legSummary;

        for (final leg in legs) {
          final legSteps = leg['steps'] as List? ?? [];
          for (final step in legSteps) {
            final maneuver = step['maneuver'] as Map<String, dynamic>;
            final manType = maneuver['type'] as String? ?? 'straight';
            final manModifier = maneuver['modifier'] as String?;
            final manLocation = maneuver['location'] as List;
            final stepCoord = LatLng(
              (manLocation[1] as num).toDouble(),
              (manLocation[0] as num).toDouble(),
            );

            final distance = (step['distance'] as num).toDouble();
            final duration = (step['duration'] as num).toDouble();
            final name = (step['name'] as String? ?? '').trim();
            final streetName = name.isEmpty ? 'Đường không tên' : name;

            final instruction =
                _buildInstruction(manType, manModifier, streetName, maneuver);

            steps.add(NavStep(
              stepIndex: globalStepIndex++,
              instruction: instruction,
              streetName: streetName,
              distanceMeters: distance,
              durationSeconds: duration,
              coordinate: stepCoord,
              maneuverTypeStr: manType,
              maneuverModifier: manModifier,
            ));
          }
        }
      }

      return NavRoute(
        totalDistanceMeters: totalDistance,
        totalDurationSeconds: totalDuration,
        polylinePoints: polylinePoints,
        steps: steps,
        summary: summary,
        provider: 'mapbox',
        isFallbackSynthetic: false,
      );
    } catch (_) {
      return null;
    }
  }

  String _modeToMapboxProfile(String mode) {
    switch (mode) {
      case 'foot':
        return 'walking';
      case 'driving':
        return 'driving-traffic';
      case 'bike':
      default:
        return 'driving-traffic';
    }
  }

  List<NavRoute> _classifyAndRankRoutes(List<NavRoute> routes, String mode) {
    if (routes.isEmpty) return routes;

    int fastestIdx = 0;
    int shortestIdx = 0;
    double minDuration = routes[0].totalDurationSeconds;
    double minDistance = routes[0].totalDistanceMeters;

    for (int i = 0; i < routes.length; i++) {
      if (routes[i].totalDurationSeconds < minDuration) {
        minDuration = routes[i].totalDurationSeconds;
        fastestIdx = i;
      }
      if (routes[i].totalDistanceMeters < minDistance) {
        minDistance = routes[i].totalDistanceMeters;
        shortestIdx = i;
      }
    }

    final primary = routes[fastestIdx];
    final classified = <NavRoute>[];

    for (int i = 0; i < routes.length; i++) {
      final r = routes[i];
      final durDiff =
          ((r.totalDurationSeconds - primary.totalDurationSeconds) / 60)
              .round();
      final distDiff =
          (r.totalDistanceMeters - primary.totalDistanceMeters) / 1000.0;

      final bool isFastest = (i == fastestIdx);
      final bool isShortest = (i == shortestIdx);

      String title;
      String subtitle;
      Color themeColor;

      if (mode == 'bike') {
        if (isFastest) {
          title = '🏍️ Xe máy - Nhanh nhất';
          subtitle = r.summary.isNotEmpty
              ? 'Qua ${r.summary} • Tối ưu xe máy'
              : 'Lộ trình nhanh nhất tránh đường cấm';
          themeColor = const Color(0xFF00F0FF);
        } else if (isShortest) {
          final savedKm =
              (primary.totalDistanceMeters - r.totalDistanceMeters) / 1000.0;
          title = '🏍️ Xe máy - Ngắn nhất';
          subtitle = savedKm > 0.1
              ? 'Tiết kiệm ${savedKm.toStringAsFixed(1)} km'
              : (r.summary.isNotEmpty ? 'Qua ${r.summary}' : 'Đường ngắn nhất');
          themeColor = const Color(0xFF10B981);
        } else {
          title = '🏍️ Tuyến thay thế ${i + 1}';
          subtitle =
              r.summary.isNotEmpty ? 'Qua ${r.summary}' : 'Đường thoáng hơn';
          themeColor = const Color(0xFFF59E0B);
        }
      } else if (mode == 'foot') {
        title = isFastest ? '🚶 Đi bộ nhanh nhất' : '🚶 Đi bộ thay thế';
        subtitle = 'Tối ưu vỉa hè và đường ngắn';
        themeColor = const Color(0xFF38BDF8);
      } else {
        if (isFastest) {
          title = '🚗 Ô tô - Nhanh nhất';
          subtitle = r.summary.isNotEmpty
              ? 'Qua ${r.summary}'
              : 'Ưu tiên đường lớn, ít đèn đỏ';
          themeColor = const Color(0xFF00F0FF);
        } else if (isShortest) {
          final savedKm =
              (primary.totalDistanceMeters - r.totalDistanceMeters) / 1000.0;
          title = '🚗 Ô tô - Ngắn nhất';
          subtitle = savedKm > 0.1
              ? 'Tiết kiệm ${savedKm.toStringAsFixed(1)} km'
              : 'Cự ly ngắn nhất';
          themeColor = const Color(0xFF10B981);
        } else {
          title = '🚗 Tuyến thay thế ${i + 1}';
          subtitle =
              r.summary.isNotEmpty ? 'Qua ${r.summary}' : 'Đường thoáng';
          themeColor = const Color(0xFFF59E0B);
        }
      }

      classified.add(r.copyWith(
        title: title,
        subtitle: subtitle,
        isFastest: isFastest,
        isShortest: isShortest,
        themeColor: themeColor,
        durationDiffMinutes: durDiff,
        distanceDiffKm: distDiff,
      ));
    }

    if (fastestIdx != 0 && classified.length > fastestIdx) {
      final fastest = classified.removeAt(fastestIdx);
      classified.insert(0, fastest);
    }

    return classified;
  }

  String _buildInstruction(
      String type, String? modifier, String street, Map<String, dynamic>? maneuver) {
    if (type == 'depart') return 'Bắt đầu di chuyển trên $street';
    if (type == 'arrive') return 'Bạn đã đến điểm đến!';
    if (type == 'roundabout' || type == 'rotary') {
      final exit = maneuver?['exit'] as int?;
      if (exit != null && exit > 0) {
        return 'Vào vòng xuyến, đi theo lối ra thứ $exit vào $street';
      }
      return 'Đi vào vòng xuyến, tiếp tục theo $street';
    }

    final mod = modifier?.toLowerCase() ?? '';
    if (type == 'fork') {
      return mod.contains('left')
          ? 'Đi theo nhánh rẽ bên trái vào $street'
          : 'Đi theo nhánh rẽ bên phải vào $street';
    }
    if (type == 'on ramp') return 'Đi vào đường nhánh nhập làn $street';
    if (type == 'off ramp') return 'Rẽ vào lối ra đường $street';
    if (type == 'merge') return 'Nhập làn vào đường $street';

    if (mod.contains('sharp right')) return 'Rẽ gắt sang phải vào $street';
    if (mod.contains('slight right')) return 'Chếch sang phải vào $street';
    if (mod.contains('right')) return 'Rẽ phải vào $street';
    if (mod.contains('sharp left')) return 'Rẽ gắt sang trái vào $street';
    if (mod.contains('slight left')) return 'Chếch sang trái vào $street';
    if (mod.contains('left')) return 'Rẽ trái vào $street';
    if (mod.contains('uturn') || mod.contains('u-turn')) {
      return 'Quay đầu xe trên $street';
    }
    return 'Tiếp tục đi thẳng trên $street';
  }

  /// Emergency offline fallback route - strictly tagged synthetic and forbidden from real navigation.
  static NavRoute generateEmergencyRoute(LatLng start, LatLng dest,
      {String mode = 'bike'}) {
    const distCalc = Distance();
    final totalDist = distCalc.as(LengthUnit.Meter, start, dest);
    final speedKmh =
        mode == 'bike' ? 35.0 : (mode == 'foot' ? 5.0 : 45.0);
    final durationSec =
        (totalDist / (speedKmh * 1000.0 / 3600.0)).clamp(30.0, 86400.0);

    final mid1 = LatLng(start.latitude, (start.longitude + dest.longitude) / 2);
    final mid2 = LatLng(dest.latitude, (start.longitude + dest.longitude) / 2);

    return NavRoute(
      title: 'Lộ trình tham khảo (Ngoại tuyến)',
      subtitle: 'Đường thẳng tham khảo - Không thể dẫn đường',
      summary: 'Tuyến đường thẳng tham khảo',
      totalDistanceMeters: totalDist,
      totalDurationSeconds: durationSec,
      steps: [
        NavStep(
          stepIndex: 0,
          instruction: 'Bắt đầu di chuyển về hướng điểm đến',
          streetName: 'Đường chính',
          distanceMeters: totalDist * 0.5,
          durationSeconds: durationSec * 0.5,
          coordinate: start,
          maneuverTypeStr: 'depart',
        ),
        NavStep(
          stepIndex: 1,
          instruction: 'Bạn đã đến điểm đến!',
          streetName: 'Điểm đến',
          distanceMeters: 0,
          durationSeconds: 0,
          coordinate: dest,
          maneuverTypeStr: 'arrive',
        ),
      ],
      polylinePoints: [start, mid1, mid2, dest],
      provider: 'synthetic',
      isFallbackSynthetic: true,
    );
  }
}
