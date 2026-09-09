import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import '../models/route_model.dart';

class OsrmService {
  static const String _osrmBaseUrl = 'https://router.project-osrm.org';

  /// Calculate multiple genuine alternative routes between start and end
  Future<List<NavRoute>> calculateMultipleRoutes(
    LatLng start,
    LatLng destination, {
    String mode = 'driving', // 'driving', 'bike', 'foot'
    bool avoidTolls = false,
    bool avoidHighways = false,
  }) async {
    try {
      // Profile mapping
      String profile = 'driving';
      if (mode == 'bike') {
        profile = 'bike';
      } else if (mode == 'foot') {
        profile = 'foot';
      }

      final url = Uri.parse(
        '$_osrmBaseUrl/route/v1/$profile/'
        '${start.longitude},${start.latitude};${destination.longitude},${destination.latitude}'
        '?overview=full&geometries=geojson&steps=true&alternatives=3&annotations=false',
      );

      final response = await http.get(url, headers: {
        'User-Agent': 'ESP32_Smart_Navigator/2.0',
      }).timeout(const Duration(seconds: 10));

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
        final totalDuration = (routeJson['duration'] as num).toDouble();

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

            final instruction = _buildInstruction(manType, manModifier, streetName);

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
          summary = 'Qua ${legs[0]['summary']}';
        }

        parsedRoutes.add(NavRoute(
          totalDistanceMeters: totalDistance,
          totalDurationSeconds: totalDuration,
          polylinePoints: polylinePoints,
          steps: steps,
          summary: summary,
        ));
      }

      if (parsedRoutes.isEmpty) return [];

      // Sort or classify routes
      // 1. Identify Fastest (min duration) and Shortest (min distance)
      int fastestIdx = 0;
      int shortestIdx = 0;
      double minDuration = parsedRoutes[0].totalDurationSeconds;
      double minDistance = parsedRoutes[0].totalDistanceMeters;

      for (int i = 0; i < parsedRoutes.length; i++) {
        if (parsedRoutes[i].totalDurationSeconds < minDuration) {
          minDuration = parsedRoutes[i].totalDurationSeconds;
          fastestIdx = i;
        }
        if (parsedRoutes[i].totalDistanceMeters < minDistance) {
          minDistance = parsedRoutes[i].totalDistanceMeters;
          shortestIdx = i;
        }
      }

      final classifiedRoutes = <NavRoute>[];
      final primary = parsedRoutes[fastestIdx];

      for (int i = 0; i < parsedRoutes.length; i++) {
        final r = parsedRoutes[i];
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
            subtitle = 'Lộ trình tối ưu tránh đường cấm xe máy';
            themeColor = const Color(0xFF00F0FF);
          } else if (isShortest) {
            title = '🏍️ Xe máy - Ngắn nhất';
            subtitle = 'Lối đi ngắn qua đường đô thị';
            themeColor = const Color(0xFF10B981);
          } else {
            title = '🏍️ Tuyến thay thế';
            subtitle = r.summary;
            themeColor = const Color(0xFFF59E0B);
          }
        } else if (mode == 'foot') {
          title = '🚶 Lối đi bộ';
          subtitle = 'Tối ưu vỉa hè và đường cắt ngắn';
          themeColor = const Color(0xFF38BDF8);
        } else {
          // Driving / Car
          if (isFastest) {
            title = '⚡ Nhanh nhất (Tránh tắc)';
            subtitle = 'Thời gian ngắn nhất, ưu tiên đường lớn';
            themeColor = const Color(0xFF00F0FF);
          } else if (isShortest) {
            final savedKm = ((primary.totalDistanceMeters - r.totalDistanceMeters) / 1000.0);
            title = '📏 Ngắn nhất';
            subtitle = savedKm > 0.1
                ? 'Tiết kiệm ${savedKm.toStringAsFixed(1)} km so với lối chính'
                : 'Cự ly ngắn nhất qua nội đô';
            themeColor = const Color(0xFF10B981);
          } else {
            title = '🛣️ Lộ trình thay thế';
            subtitle = r.summary.isNotEmpty ? r.summary : 'Đường thoáng, ít giao cắt';
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
    } catch (_) {
      return [];
    }
  }

  /// Single route calculation (legacy support)
  Future<NavRoute?> calculateRoute(
    LatLng start,
    LatLng destination, {
    String profile = 'driving',
  }) async {
    final list = await calculateMultipleRoutes(start, destination, mode: profile);
    return list.isNotEmpty ? list.first : null;
  }

  /// Helper to create localized turn instructions
  String _buildInstruction(String type, String? modifier, String street) {
    if (type == 'depart') return 'Bắt đầu di chuyển trên $street';
    if (type == 'arrive') return 'Bạn đã đến điểm đến!';
    if (type == 'roundabout' || type == 'rotary') {
      return 'Đi vào vòng xuyến, tiếp tục theo $street';
    }

    final mod = modifier?.toLowerCase() ?? '';
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
