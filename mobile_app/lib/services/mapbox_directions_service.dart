import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import '../config/mapbox_config.dart';
import '../models/route_model.dart';
import 'osrm_service.dart';

/// Navigation Directions Service
/// Supports MapTiler/OSRM with automatic multi-route alternatives and turn-by-turn maneuvers.
class MapboxDirectionsService {
  // In-Memory Route Cache (instant retrieval for repeated queries)
  static final Map<String, List<NavRoute>> _routeCache = {};
  final OsrmService _osrmService = OsrmService();

  /// Calculate multiple alternative routes
  Future<List<NavRoute>> calculateMultipleRoutes(
    LatLng start,
    LatLng destination, {
    String mode = 'bike', // 'bike' (motorcycle→driving-traffic), 'driving', 'foot'
    bool avoidTolls = false,
    bool avoidHighways = false,
  }) async {
    final cacheKey =
        '${start.latitude.toStringAsFixed(4)},${start.longitude.toStringAsFixed(4)}'
        '-${destination.latitude.toStringAsFixed(4)},${destination.longitude.toStringAsFixed(4)}-$mode';
    if (_routeCache.containsKey(cacheKey)) {
      return _routeCache[cacheKey]!;
    }

    List<NavRoute> routes = [];

    if (MapboxConfig.accessToken.isNotEmpty && !MapboxConfig.accessToken.startsWith('YOUR_')) {
      routes = await _fetchFromMapbox(start, destination, mode: mode);
    }

    // High-performance routing via OSRM (free, reliable, real road network)
    if (routes.isEmpty) {
      routes = await _osrmService.calculateMultipleRoutes(
        start,
        destination,
        mode: mode,
        avoidTolls: avoidTolls,
        avoidHighways: avoidHighways,
      );
    }

    // Fallback: offline emergency route if remote servers fail
    if (routes.isEmpty) {
      routes = [_generateEmergencyRoute(start, destination, mode: mode)];
    }

    // Classify routes
    routes = _classifyAndRankRoutes(routes, mode);

    _routeCache[cacheKey] = routes;
    if (_routeCache.length > 50) {
      _routeCache.remove(_routeCache.keys.first);
    }
    return routes;
  }

  Future<List<NavRoute>> _fetchFromMapbox(
    LatLng start,
    LatLng destination, {
    required String mode,
  }) async {
    try {
      // Map app transport mode to Mapbox profile
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
          .timeout(const Duration(seconds: 10));

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

      // Parse polyline (GeoJSON format)
      final geometry = routeJson['geometry'] as Map<String, dynamic>;
      final coordsList = geometry['coordinates'] as List;
      final polylinePoints = coordsList.map<LatLng>((coord) {
        return LatLng(
          (coord[1] as num).toDouble(),
          (coord[0] as num).toDouble(),
        );
      }).toList();

      // Parse turn-by-turn steps from legs
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
        // Motorcycle in Vietnam: use driving-traffic for road accuracy
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

    // Move fastest to front
    if (fastestIdx != 0 && classified.length > fastestIdx) {
      final fastest = classified.removeAt(fastestIdx);
      classified.insert(0, fastest);
    }

    return classified;
  }

  /// Single route calculation
  Future<NavRoute?> calculateRoute(
    LatLng start,
    LatLng destination, {
    String profile = 'bike',
  }) async {
    final list =
        await calculateMultipleRoutes(start, destination, mode: profile);
    return list.isNotEmpty ? list.first : null;
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

  NavRoute _generateEmergencyRoute(LatLng start, LatLng dest,
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
      title: 'Lộ trình tối ưu (Offline)',
      subtitle: 'Tuyến đường ngắn nhất',
      summary: 'Tuyến đường ngắn nhất',
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
    );
  }
}
