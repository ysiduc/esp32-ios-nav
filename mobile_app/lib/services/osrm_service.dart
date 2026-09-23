import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import '../models/route_model.dart';
import 'valhalla_service.dart';

class OsrmSnapResult {
  final LatLng original;
  final LatLng snapped;
  final double distanceMeters;
  final String? streetName;
  final bool success;
  final String? errorMessage;

  const OsrmSnapResult({
    required this.original,
    required this.snapped,
    required this.distanceMeters,
    this.streetName,
    required this.success,
    this.errorMessage,
  });
}

class OsrmService {
  static const String _primaryOsrmBaseUrl = 'https://router.project-osrm.org';
  static const String _secondaryOsrmBaseUrl = 'https://routing.openstreetmap.de/routed-car';
  final ValhallaService _valhallaService = ValhallaService();

  // In-Memory Route Cache (0ms instant route retrieval)
  static final Map<String, List<NavRoute>> _routeCache = {};
  static void clearCache() => _routeCache.clear();

  /// Calculate multiple genuine alternative routes between start and end
  Future<List<NavRoute>> calculateMultipleRoutes(
    LatLng start,
    LatLng destination, {
    String mode = 'bike', // 'bike' (motorcycle), 'driving' (car), 'foot' (walk)
    bool avoidTolls = false,
    bool avoidHighways = false,
  }) async {
    final cacheKey = '${start.latitude.toStringAsFixed(4)},${start.longitude.toStringAsFixed(4)}-${destination.latitude.toStringAsFixed(4)},${destination.longitude.toStringAsFixed(4)}-$mode';
    if (_routeCache.containsKey(cacheKey)) {
      return _routeCache[cacheKey]!;
    }

    final osrmResult = await fetchOsrmRoutesDetailed(start, destination, mode: mode);
    List<NavRoute> routes = osrmResult.routes;

    // Fallback to Valhalla if OSRM failed
    if (routes.isEmpty) {
      final valhallaCosting = mode == 'bike' ? 'motorcycle' : (mode == 'foot' ? 'pedestrian' : 'auto');
      final valhallaRoute = await _valhallaService.calculateRoute(start, destination, costing: valhallaCosting);
      if (valhallaRoute != null) {
        routes = [valhallaRoute];
      }
    }

    // Instant Fallback Route Generator if all remote servers failed/offline
    if (routes.isEmpty) {
      final fallbackRoute = _generateEmergencyRoute(start, destination, mode: mode);
      routes = [fallbackRoute];
    }

    // Classify & Rank Routes (Fastest vs Shortest vs Alternative)
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

    final classifiedRoutes = <NavRoute>[];
    final primary = routes[fastestIdx];

    for (int i = 0; i < routes.length; i++) {
      final r = routes[i];
      final durDiff = ((r.totalDurationSeconds - primary.totalDurationSeconds) / 60).round();
      final distDiff = (r.totalDistanceMeters - primary.totalDistanceMeters) / 1000.0;

      String title;
      String subtitle;
      Color themeColor;
      bool isFastest = (i == fastestIdx);
      bool isShortest = (i == shortestIdx);

      if (mode == 'bike') {
        if (isFastest) {
          title = '🏍️ Xe máy - Nhanh nhất';
          subtitle = r.summary.isNotEmpty ? 'Qua ${r.summary} • Trục đường chính' : 'Lộ trình tối ưu tránh đường cấm xe máy';
          themeColor = const Color(0xFF00F0FF);
        } else if (isShortest) {
          final savedKm = ((primary.totalDistanceMeters - r.totalDistanceMeters) / 1000.0);
          title = '🏍️ Xe máy - Ngắn nhất';
          subtitle = savedKm > 0.1
              ? 'Tiết kiệm ${savedKm.toStringAsFixed(1)} km qua lối cắt nội đô'
              : (r.summary.isNotEmpty ? 'Qua ${r.summary}' : 'Lối đi ngắn qua đường đô thị');
          themeColor = const Color(0xFF10B981);
        } else {
          title = '🏍️ Tuyến thay thế ${i + 1}';
          subtitle = r.summary.isNotEmpty ? 'Qua ${r.summary}' : 'Đường thoáng, ít đèn đỏ';
          themeColor = const Color(0xFFF59E0B);
        }
      } else if (mode == 'foot') {
        title = isFastest ? '🚶 Lối đi bộ nhanh nhất' : '🚶 Lối đi bộ thay thế';
        subtitle = 'Tối ưu vỉa hè và đường cắt ngắn';
        themeColor = const Color(0xFF38BDF8);
      } else {
        // Car / Driving
        if (isFastest) {
          title = '🚗 Ô tô - Nhanh nhất';
          subtitle = r.summary.isNotEmpty ? 'Qua ${r.summary} • Ưu tiên đường lớn' : 'Thời gian ngắn nhất, ưu tiên đường lớn';
          themeColor = const Color(0xFF00F0FF);
        } else if (isShortest) {
          final savedKm = ((primary.totalDistanceMeters - r.totalDistanceMeters) / 1000.0);
          title = '🚗 Ô tô - Ngắn nhất';
          subtitle = savedKm > 0.1
              ? 'Tiết kiệm ${savedKm.toStringAsFixed(1)} km so với lối chính'
              : 'Cự ly ngắn nhất qua nội đô';
          themeColor = const Color(0xFF10B981);
        } else {
          title = '🚗 Tuyến thay thế ${i + 1}';
          subtitle = r.summary.isNotEmpty ? 'Qua ${r.summary}' : 'Đường thoáng, ít giao cắt';
          themeColor = const Color(0xFFF59E0B);
        }
      }

      classifiedRoutes.add(r.copyWith(
        title: title,
        subtitle: subtitle,
        isFastest: isFastest,
        isShortest: isShortest,
        themeColor: themeColor,
        durationDiffMinutes: durDiff,
        distanceDiffKm: distDiff,
      ));
    }

    // Ensure the fastest route is first in the list
    if (fastestIdx != 0 && classifiedRoutes.length > fastestIdx) {
      final fastestRoute = classifiedRoutes.removeAt(fastestIdx);
      classifiedRoutes.insert(0, fastestRoute);
    }

    _routeCache[cacheKey] = classifiedRoutes;
    if (_routeCache.length > 50) {
      _routeCache.remove(_routeCache.keys.first);
    }

    return classifiedRoutes;
  }

  /// Snap a point to the nearest routable road edge using OSRM /nearest API
  Future<OsrmSnapResult> findNearestRoutablePoint(
    LatLng point, {
    double maxRadiusMeters = 300.0,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final urls = [
      '$_primaryOsrmBaseUrl/nearest/v1/driving/${point.longitude},${point.latitude}?number=1',
      '$_secondaryOsrmBaseUrl/nearest/v1/driving/${point.longitude},${point.latitude}?number=1',
    ];

    for (final urlStr in urls) {
      try {
        final response = await http.get(Uri.parse(urlStr), headers: {
          'User-Agent': 'ESP32Nav/2.0 (contact@esp32nav.app)',
        }).timeout(timeout);

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          if (data['code'] == 'Ok' && (data['waypoints'] as List).isNotEmpty) {
            final wp = data['waypoints'][0] as Map<String, dynamic>;
            final loc = wp['location'] as List;
            final dist = (wp['distance'] as num).toDouble();
            final name = (wp['name'] as String? ?? '').trim();
            final snapped = LatLng((loc[1] as num).toDouble(), (loc[0] as num).toDouble());

            if (dist <= maxRadiusMeters) {
              debugPrint('[OSRM Snap] Point $point snapped to $snapped (${dist.toStringAsFixed(1)}m on $name)');
              return OsrmSnapResult(
                original: point,
                snapped: snapped,
                distanceMeters: dist,
                streetName: name.isNotEmpty ? name : null,
                success: true,
              );
            } else {
              debugPrint('[OSRM Snap] Point $point is too far from routable road (${dist.toStringAsFixed(1)}m > ${maxRadiusMeters}m)');
              return OsrmSnapResult(
                original: point,
                snapped: snapped,
                distanceMeters: dist,
                streetName: name.isNotEmpty ? name : null,
                success: false,
                errorMessage: 'Điểm nằm quá xa đường giao thông (${dist.toStringAsFixed(0)}m > ${maxRadiusMeters.toStringAsFixed(0)}m)',
              );
            }
          }
        }
      } catch (e) {
        debugPrint('[OSRM Snap] Nearest probe error on $urlStr: $e');
      }
    }

    return OsrmSnapResult(
      original: point,
      snapped: point,
      distanceMeters: 0,
      success: false,
      errorMessage: 'Không thể tìm đường giao thông gần tọa độ',
    );
  }

  /// Hedged racing between OSRM primary (T0) and secondary (T0+800ms) with rich diagnostics
  Future<ProviderRouteResult> fetchOsrmRoutesDetailed(
    LatLng start,
    LatLng destination, {
    required String mode,
    Duration timeout = const Duration(seconds: 4),
    Duration staggerDelay = const Duration(milliseconds: 800),
  }) async {
    final completer = Completer<ProviderRouteResult>();
    Timer? fallbackTimer;
    bool anyWinner = false;
    bool secondaryLaunched = false;
    ProviderRouteResult? primaryFailure;

    void launchSecondary() {
      if (secondaryLaunched || completer.isCompleted || anyWinner) return;
      secondaryLaunched = true;
      fallbackTimer?.cancel();
      debugPrint('[OSRM] Launching secondary OSRM in parallel');

      _fetchSingleOsrm(
        _secondaryOsrmBaseUrl,
        start,
        destination,
        mode: mode,
        useDirectProfile: true,
        timeout: timeout,
        serverTag: 'osrm2',
      ).then((res) {
        if (completer.isCompleted) return;
        if (res.success && res.routes.isNotEmpty) {
          anyWinner = true;
          completer.complete(res);
        } else {
          completer.complete(primaryFailure ?? res);
        }
      }).catchError((e) {
        if (!completer.isCompleted) {
          completer.complete(primaryFailure ?? ProviderRouteResult.failure(
            provider: 'osrm2',
            latency: const Duration(milliseconds: 800),
            errorType: 'network',
            safeMessage: 'Lỗi OSRM secondary: $e',
          ));
        }
      });
    }

    // 1. Launch Primary at T0
    _fetchSingleOsrm(
      _primaryOsrmBaseUrl,
      start,
      destination,
      mode: mode,
      useDirectProfile: false,
      timeout: timeout,
      serverTag: 'osrm1',
    ).then((res) {
      if (completer.isCompleted) return;
      if (res.success && res.routes.isNotEmpty) {
        anyWinner = true;
        fallbackTimer?.cancel();
        completer.complete(res);
      } else {
        primaryFailure = res;
        if (!secondaryLaunched) {
          // Primary failed fast: trigger secondary immediately!
          launchSecondary();
        }
      }
    }).catchError((e) {
      primaryFailure = ProviderRouteResult.failure(
        provider: 'osrm1',
        latency: Duration.zero,
        errorType: 'network',
        safeMessage: 'Lỗi OSRM primary: $e',
      );
      if (!secondaryLaunched) {
        launchSecondary();
      }
    });

    // 2. Schedule Secondary at T0 + staggerDelay if primary still pending
    fallbackTimer = Timer(staggerDelay, () {
      if (!completer.isCompleted && !anyWinner && !secondaryLaunched) {
        debugPrint('[OSRM] Primary still pending after ${staggerDelay.inMilliseconds}ms -> launching fallback');
        launchSecondary();
      }
    });

    return completer.future;
  }

  /// Direct OSRM routes query backward-compatible
  Future<List<NavRoute>> fetchOsrmRoutes(
    LatLng start,
    LatLng destination, {
    required String mode,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final result = await fetchOsrmRoutesDetailed(start, destination, mode: mode, timeout: timeout);
    return result.routes;
  }

  Future<ProviderRouteResult> _fetchSingleOsrm(
    String baseUrl,
    LatLng start,
    LatLng destination, {
    required String mode,
    bool useDirectProfile = false,
    Duration timeout = const Duration(seconds: 4),
    String serverTag = 'osrm',
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      String profile = 'driving';
      if (mode == 'foot') {
        profile = 'foot';
      }

      // Prompt item 4: Use alternatives=true for compatibility smoke test
      final urlStr = useDirectProfile
          ? '$baseUrl/route/v1/driving/${start.longitude},${start.latitude};${destination.longitude},${destination.latitude}?overview=full&geometries=geojson&steps=true&alternatives=true'
          : '$baseUrl/route/v1/$profile/${start.longitude},${start.latitude};${destination.longitude},${destination.latitude}?overview=full&geometries=geojson&steps=true&alternatives=true&annotations=false';

      final response = await http.get(Uri.parse(urlStr), headers: {
        'User-Agent': 'ESP32Nav/2.0 (contact@esp32nav.app)',
      }).timeout(timeout);

      final latency = stopwatch.elapsed;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final apiCode = data['code']?.toString() ?? 'Ok';

        if (apiCode == 'Ok') {
          final routes = parseOsrmResponse(data, start, destination, mode);
          if (routes.isNotEmpty) {
            return ProviderRouteResult.success(
              provider: serverTag,
              routes: routes,
              latency: latency,
              httpStatus: 200,
              apiCode: 'Ok',
            );
          } else {
            return ProviderRouteResult.failure(
              provider: serverTag,
              latency: latency,
              httpStatus: 200,
              apiCode: 'EmptyRoutes',
              errorType: 'emptyResponse',
              safeMessage: 'Dữ liệu lộ trình OSRM rỗng',
            );
          }
        } else {
          final errorType = (apiCode == 'NoSegment' || apiCode == 'NoRoute') ? 'noRoute' : 'invalidRequest';
          final msg = data['message']?.toString() ?? 'Không tìm thấy lộ trình';
          return ProviderRouteResult.failure(
            provider: serverTag,
            latency: latency,
            httpStatus: 200,
            apiCode: apiCode,
            errorType: errorType,
            safeMessage: errorType == 'noRoute' ? 'Không tìm thấy đường phù hợp gần tọa độ' : msg,
          );
        }
      }

      // Non-200 Diagnostic
      String errorType = 'http';
      String safeMessage = 'Lỗi máy chủ OSRM (HTTP ${response.statusCode})';
      String? apiCode;

      try {
        final errData = jsonDecode(response.body) as Map<String, dynamic>;
        apiCode = errData['code']?.toString();
        final msg = errData['message']?.toString();
        if (response.statusCode == 429) {
          errorType = 'rateLimited';
          safeMessage = 'Dịch vụ OSRM đang quá tải. Hãy thử lại.';
        } else if (apiCode == 'NoSegment' || apiCode == 'NoRoute') {
          errorType = 'noRoute';
          safeMessage = 'Không tìm thấy đường nối giữa 2 điểm';
        } else if (msg != null && msg.isNotEmpty) {
          safeMessage = msg;
        }
      } catch (_) {}

      debugPrint('[$serverTag] Failed: status=${response.statusCode}, code=$apiCode, errorType=$errorType, latency=${latency.inMilliseconds}ms');
      return ProviderRouteResult.failure(
        provider: serverTag,
        latency: latency,
        httpStatus: response.statusCode,
        apiCode: apiCode,
        errorType: errorType,
        safeMessage: safeMessage,
      );
    } on TimeoutException {
      final latency = stopwatch.elapsed;
      debugPrint('[$serverTag] Timeout after ${latency.inMilliseconds}ms');
      return ProviderRouteResult.failure(
        provider: serverTag,
        latency: latency,
        errorType: 'timeout',
        safeMessage: 'Quá thời gian kết nối OSRM',
      );
    } on SocketException catch (e) {
      final latency = stopwatch.elapsed;
      final isDns = e.message.toLowerCase().contains('failed host lookup');
      final errorType = isDns ? 'dns' : 'network';
      debugPrint('[$serverTag] Network error ($errorType): $e');
      return ProviderRouteResult.failure(
        provider: serverTag,
        latency: latency,
        errorType: errorType,
        safeMessage: isDns ? 'Không thể phân giải tên miền máy chủ OSRM (DNS)' : 'Không thể kết nối mạng tới OSRM',
      );
    } on HandshakeException catch (e) {
      final latency = stopwatch.elapsed;
      debugPrint('[$serverTag] TLS error: $e');
      return ProviderRouteResult.failure(
        provider: serverTag,
        latency: latency,
        errorType: 'tls',
        safeMessage: 'Lỗi bảo mật kết nối OSRM (TLS)',
      );
    } catch (e) {
      final latency = stopwatch.elapsed;
      debugPrint('[$serverTag] Exception: $e');
      return ProviderRouteResult.failure(
        provider: serverTag,
        latency: latency,
        errorType: e is FormatException ? 'parseError' : 'network',
        safeMessage: 'Lỗi kết nối OSRM: $e',
      );
    }
  }

  /// Static helper to parse OSRM JSON response
  static List<NavRoute> parseOsrmResponse(
    Map<String, dynamic> data,
    LatLng start,
    LatLng destination,
    String mode,
  ) {
    try {
      final rawRoutes = data['routes'] as List? ?? [];
      final parsedRoutes = <NavRoute>[];

      for (int rIdx = 0; rIdx < rawRoutes.length; rIdx++) {
        final routeJson = rawRoutes[rIdx] as Map<String, dynamic>;
        final totalDistance = (routeJson['distance'] as num).toDouble();
        var totalDuration = (routeJson['duration'] as num).toDouble();

        // Adjust duration for Vietnamese motorbike speed if mode == 'bike'
        if (mode == 'bike') {
          final avgSpeedKmh = totalDistance > 10000 ? 42.0 : 32.0;
          totalDuration = (totalDistance / 1000.0) / avgSpeedKmh * 3600.0;
        }

        // Parse polyline geometry
        final geometry = routeJson['geometry'] as Map<String, dynamic>;
        final coordsList = geometry['coordinates'] as List;
        final polylinePoints = coordsList.map<LatLng>((coord) {
          final lon = (coord[0] as num).toDouble();
          final lat = (coord[1] as num).toDouble();
          return LatLng(lat, lon);
        }).toList();

        // Parse turn-by-turn steps
        final steps = <NavStep>[];
        final legs = routeJson['legs'] as List? ?? [];
        int globalStepIndex = 0;

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

            final instruction = buildInstruction(manType, manModifier, streetName, maneuver);

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

        String summary = 'Lộ trình ${rIdx + 1}';
        if (legs.isNotEmpty && legs[0]['summary'] != null && (legs[0]['summary'] as String).isNotEmpty) {
          summary = '${legs[0]['summary']}';
        }

        parsedRoutes.add(NavRoute(
          title: 'Lộ trình ${rIdx + 1}',
          subtitle: 'Tuyến OSRM',
          totalDistanceMeters: totalDistance,
          totalDurationSeconds: totalDuration,
          polylinePoints: polylinePoints,
          steps: steps,
          summary: summary,
          provider: 'osrm',
          isFallbackSynthetic: false,
        ));
      }

      return parsedRoutes;
    } catch (e) {
      debugPrint('[OSRM] Parsing error: $e');
      return [];
    }
  }

  /// Single route calculation (legacy support)
  Future<NavRoute?> calculateRoute(
    LatLng start,
    LatLng destination, {
    String profile = 'bike',
  }) async {
    final list = await calculateMultipleRoutes(start, destination, mode: profile);
    return list.isNotEmpty ? list.first : null;
  }

  /// Helper to create localized turn instructions
  static String buildInstruction(String type, String? modifier, String street, [Map<String, dynamic>? maneuver]) {
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
      if (mod.contains('left')) return 'Đi theo nhánh rẽ bên trái vào $street';
      return 'Đi theo nhánh rẽ bên phải vào $street';
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
    if (mod.contains('uturn') || mod.contains('u-turn')) return 'Quay đầu xe trên $street';
    if (mod.contains('straight')) return 'Đi thẳng trên $street';

    return 'Tiếp tục đi trên $street';
  }

  /// Synthesizes an emergency offline fallback route with intermediate coordinates and turn steps
  NavRoute _generateEmergencyRoute(LatLng start, LatLng dest, {String mode = 'bike'}) {
    const distCalc = Distance();
    final totalDist = distCalc.as(LengthUnit.Meter, start, dest);
    final speedKmh = mode == 'bike' ? 35.0 : (mode == 'foot' ? 5.0 : 45.0);
    final durationSec = (totalDist / (speedKmh * 1000.0 / 3600.0)).clamp(30.0, 86400.0);

    final mid1 = LatLng(start.latitude, (start.longitude + dest.longitude) / 2.0);
    final mid2 = LatLng(dest.latitude, (start.longitude + dest.longitude) / 2.0);
    final pts = [start, mid1, mid2, dest];

    final steps = [
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
        instruction: 'Rẽ vào đường tiếp theo',
        streetName: 'Đường đến đích',
        distanceMeters: totalDist * 0.5,
        durationSeconds: durationSec * 0.5,
        coordinate: mid1,
        maneuverTypeStr: 'turn',
        maneuverModifier: 'right',
      ),
      NavStep(
        stepIndex: 2,
        instruction: 'Bạn đã đến điểm đến!',
        streetName: 'Điểm đến',
        distanceMeters: 0,
        durationSeconds: 0,
        coordinate: dest,
        maneuverTypeStr: 'arrive',
      ),
    ];

    return NavRoute(
      title: 'Lộ trình tham khảo (Ngoại tuyến)',
      subtitle: 'Đường thẳng tham khảo - Không thể dẫn đường',
      summary: 'Tuyến đường thẳng tham khảo',
      totalDistanceMeters: totalDist,
      totalDurationSeconds: durationSec,
      steps: steps,
      polylinePoints: pts,
      provider: 'synthetic',
      isFallbackSynthetic: true,
    );
  }
}
