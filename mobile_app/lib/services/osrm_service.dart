import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import '../models/route_model.dart';
import 'valhalla_service.dart';

class OsrmService {
  static const String _primaryOsrmBaseUrl = 'https://router.project-osrm.org';
  static const String _secondaryOsrmBaseUrl = 'https://routing.openstreetmap.de/routed-car';
  final ValhallaService _valhallaService = ValhallaService();

  /// Calculate multiple genuine alternative routes between start and end
  Future<List<NavRoute>> calculateMultipleRoutes(
    LatLng start,
    LatLng destination, {
    String mode = 'bike', // 'bike' (motorcycle), 'driving' (car), 'foot' (walk)
    bool avoidTolls = false,
    bool avoidHighways = false,
  }) async {
    // 1. Try Primary OSRM Server
    List<NavRoute> routes = await _fetchFromOsrm(
      _primaryOsrmBaseUrl,
      start,
      destination,
      mode: mode,
    );

    // 2. Fallback to Secondary OSRM Server if primary returned empty
    if (routes.isEmpty) {
      routes = await _fetchFromOsrm(
        _secondaryOsrmBaseUrl,
        start,
        destination,
        mode: mode,
        useDirectProfile: true,
      );
    }

    // 3. Fallback to Valhalla if OSRM failed
    if (routes.isEmpty) {
      final valhallaCosting = mode == 'bike' ? 'motorcycle' : (mode == 'foot' ? 'pedestrian' : 'auto');
      final valhallaRoute = await _valhallaService.calculateRoute(start, destination, costing: valhallaCosting);
      if (valhallaRoute != null) {
        routes = [valhallaRoute];
      }
    }

    if (routes.isEmpty) return [];

    // -------------------------------------------------------------
    // Classify & Rank Routes (Fastest vs Shortest vs Alternative)
    // -------------------------------------------------------------
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

    return classifiedRoutes;
  }

  Future<List<NavRoute>> _fetchFromOsrm(
    String baseUrl,
    LatLng start,
    LatLng destination, {
    required String mode,
    bool useDirectProfile = false,
  }) async {
    try {
      // For Vietnam motorbike routing: We use OSRM driving profile with customized Vietnamese motorbike speeds (38 km/h)
      // because OSRM 'bike' is pedal bicycle (12km/h, walking paths, stairs).
      String profile = 'driving';
      if (mode == 'foot') {
        profile = 'foot';
      }

      final urlStr = useDirectProfile
          ? '$baseUrl/route/v1/driving/${start.longitude},${start.latitude};${destination.longitude},${destination.latitude}?overview=full&geometries=geojson&steps=true&alternatives=3'
          : '$baseUrl/route/v1/$profile/${start.longitude},${start.latitude};${destination.longitude},${destination.latitude}?overview=full&geometries=geojson&steps=true&alternatives=3&annotations=false';

      final response = await http.get(Uri.parse(urlStr), headers: {
        'User-Agent': 'ESP32_Smart_Navigator/2.0 (contact@esp32nav.app)',
      }).timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        return [];
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (data['code'] != 'Ok' || (data['routes'] as List).isEmpty) {
        return [];
      }

      final rawRoutes = data['routes'] as List;
      final parsedRoutes = <NavRoute>[];

      for (int rIdx = 0; rIdx < rawRoutes.length; rIdx++) {
        final routeJson = rawRoutes[rIdx] as Map<String, dynamic>;
        final totalDistance = (routeJson['distance'] as num).toDouble();
        var totalDuration = (routeJson['duration'] as num).toDouble();

        // Adjust duration for Vietnamese motorbike speed if mode == 'bike'
        if (mode == 'bike') {
          // Average motorbike speed in Vietnam cities ~32 km/h, suburbs ~45 km/h
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
        final legs = routeJson['legs'] as List;
        int globalStepIndex = 0;

        for (final leg in legs) {
          final legSteps = leg['steps'] as List;
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

            final instruction = _buildInstruction(manType, manModifier, streetName, maneuver);

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
          totalDistanceMeters: totalDistance,
          totalDurationSeconds: totalDuration,
          polylinePoints: polylinePoints,
          steps: steps,
          summary: summary,
        ));
      }

      return parsedRoutes;
    } catch (_) {
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
  String _buildInstruction(String type, String? modifier, String street, [Map<String, dynamic>? maneuver]) {
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
}
