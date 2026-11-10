import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';
import '../models/route_model.dart';

/// Dịch vụ Apple Maps Native (MKLocalSearch và MKDirections) cho iOS
class AppleMapsService {
  static const MethodChannel _channel = MethodChannel('com.ysiduc.esp32_nav/apple_maps');

  static final AppleMapsService _instance = AppleMapsService._internal();
  factory AppleMapsService() => _instance;
  AppleMapsService._internal();

  /// Kiểm tra thiết bị có hỗ trợ Apple Maps Native (chỉ iOS thật hoặc Simulator)
  static bool get isSupported => !kIsWeb && Platform.isIOS;

  /// 1. Tìm kiếm địa điểm bằng Apple MapKit (MKLocalSearch)
  Future<List<MapPlace>> searchPlaces(
    String query, {
    LatLng? nearLocation,
    int limit = 10,
  }) async {
    if (!isSupported) return [];
    final clean = query.trim();
    if (clean.length < 2) return [];

    try {
      final List<dynamic>? results = await _channel.invokeMethod('searchPlaces', {
        'query': clean,
        'lat': nearLocation?.latitude ?? 0.0,
        'lng': nearLocation?.longitude ?? 0.0,
      });

      if (results == null) return [];

      return results.take(limit).map<MapPlace>((item) {
        final map = Map<String, dynamic>.from(item as Map);
        final lat = (map['lat'] as num?)?.toDouble() ?? 0.0;
        final lng = (map['lng'] as num?)?.toDouble() ?? 0.0;
        final coord = LatLng(lat, lng);
        final name = map['name'] as String? ?? 'Địa điểm';
        final subtitle = map['subtitle'] as String? ?? '';
        final displayName = subtitle.isNotEmpty ? '$name, $subtitle' : name;

        double? dist;
        if (nearLocation != null) {
          const distanceCalculator = Distance();
          dist = distanceCalculator.as(LengthUnit.Meter, nearLocation, coord);
        }

        return MapPlace(
          displayName: displayName,
          name: name,
          coordinate: coord,
          category: map['category'] as String?,
          distanceMeters: dist,
        );
      }).toList();
    } catch (e) {
      debugPrint('[AppleMapsService] Lỗi tìm kiếm địa điểm: $e');
      return [];
    }
  }

  /// 2. Gợi ý từ khóa bằng MKLocalSearchCompleter
  Future<List<Map<String, String>>> searchAutocomplete(
    String query, {
    LatLng? nearLocation,
  }) async {
    if (!isSupported) return [];
    final clean = query.trim();
    if (clean.isEmpty) return [];

    try {
      final List<dynamic>? results = await _channel.invokeMethod('searchAutocomplete', {
        'query': clean,
        'lat': nearLocation?.latitude ?? 0.0,
        'lng': nearLocation?.longitude ?? 0.0,
      });

      if (results == null) return [];

      return results.map<Map<String, String>>((item) {
        final map = Map<String, dynamic>.from(item as Map);
        return {
          'title': (map['title'] as String?) ?? '',
          'subtitle': (map['subtitle'] as String?) ?? '',
        };
      }).toList();
    } catch (e) {
      debugPrint('[AppleMapsService] Lỗi gợi ý từ khóa: $e');
      return [];
    }
  }

  /// 3. Tính toán 1 tuyến đường tối ưu (MKDirections)
  Future<NavRoute?> calculateRoute({
    required LatLng origin,
    required LatLng destination,
    String vehicle = 'automobile',
  }) async {
    if (!isSupported) return null;

    try {
      final Map<dynamic, dynamic>? data = await _channel.invokeMethod('getRoute', {
        'startLat': origin.latitude,
        'startLng': origin.longitude,
        'endLat': destination.latitude,
        'endLng': destination.longitude,
        'mode': (vehicle == 'foot' || vehicle == 'walking') ? 'walking' : 'automobile',
      });

      if (data == null || data['routes'] == null) return null;
      final routesList = data['routes'] as List;
      if (routesList.isEmpty) return null;

      final primary = Map<String, dynamic>.from(routesList.first as Map);
      return _parseAppleRoute(primary);
    } catch (e) {
      debugPrint('[AppleMapsService] Lỗi tính lộ trình: $e');
      return null;
    }
  }

  /// 4. Tính toán nhiều tuyến đường (MKDirections với Alternate Routes)
  Future<List<NavRoute>> calculateMultipleRoutes(
    LatLng origin,
    LatLng destination, {
    String mode = 'bike',
  }) async {
    if (!isSupported) return [];

    try {
      final Map<dynamic, dynamic>? data = await _channel.invokeMethod('getRoute', {
        'startLat': origin.latitude,
        'startLng': origin.longitude,
        'endLat': destination.latitude,
        'endLng': destination.longitude,
        'mode': (mode == 'foot' || mode == 'walking') ? 'walking' : 'automobile',
      });

      if (data == null || data['routes'] == null) return [];
      final routesList = data['routes'] as List;

      final parsedRoutes = <NavRoute>[];
      for (int i = 0; i < routesList.length; i++) {
        final r = Map<String, dynamic>.from(routesList[i] as Map);
        final route = _parseAppleRoute(r, routeIndex: i);
        if (route != null) parsedRoutes.add(route);
      }
      return parsedRoutes;
    } catch (e) {
      debugPrint('[AppleMapsService] Lỗi tính nhiều lộ trình: $e');
      return [];
    }
  }

  NavRoute? _parseAppleRoute(Map<String, dynamic> r, {int routeIndex = 0}) {
    final distM = (r['distance'] as num?)?.toDouble() ?? 0.0;
    final durSec = (r['expectedTravelTime'] as num?)?.toDouble() ?? 0.0;
    final name = (r['name'] as String?) ?? 'Lộ trình Apple Maps';

    // Parse coordinates
    final rawCoords = r['coordinates'] as List? ?? [];
    final polylinePoints = <LatLng>[];
    for (final pt in rawCoords) {
      if (pt is List && pt.length >= 2) {
        polylinePoints.add(LatLng((pt[0] as num).toDouble(), (pt[1] as num).toDouble()));
      }
    }

    if (polylinePoints.isEmpty) return null;

    // Parse steps
    final rawSteps = r['steps'] as List? ?? [];
    final steps = <NavStep>[];

    for (int i = 0; i < rawSteps.length; i++) {
      final s = Map<String, dynamic>.from(rawSteps[i] as Map);
      final instruction = (s['instruction'] as String?) ?? '';
      final stepDist = (s['distance'] as num?)?.toDouble() ?? 0.0;
      final lat = (s['lat'] as num?)?.toDouble() ?? 0.0;
      final lng = (s['lng'] as num?)?.toDouble() ?? 0.0;

      final parsedManeuver = _parseManeuverFromInstruction(instruction, i, rawSteps.length);

      steps.add(NavStep(
        stepIndex: i,
        instruction: instruction.isNotEmpty ? instruction : 'Tiếp tục đi thẳng',
        streetName: _extractStreetName(instruction),
        distanceMeters: stepDist,
        durationSeconds: (durSec > 0 && distM > 0) ? (stepDist / distM * durSec) : 0,
        coordinate: LatLng(lat, lng),
        maneuverTypeStr: parsedManeuver.typeStr,
        maneuverModifier: parsedManeuver.modifier,
      ));
    }

    return NavRoute(
      totalDistanceMeters: distM,
      totalDurationSeconds: durSec,
      polylinePoints: polylinePoints,
      steps: steps,
      summary: name,
      title: routeIndex == 0 ? 'Nhanh nhất (Apple Maps)' : 'Lộ trình $routeIndex (Apple Maps)',
      subtitle: name,
      isFastest: routeIndex == 0,
      isShortest: false,
      isTollFree: true,
      themeColor: routeIndex == 0 ? const Color(0xFF00F0FF) : const Color(0xFF64748B),
    );
  }

  /// Phân tích câu lệnh của Apple Maps thành ManeuverType phù hợp với ESP32
  static ({String typeStr, String? modifier}) _parseManeuverFromInstruction(
    String instruction,
    int index,
    int totalSteps,
  ) {
    final lower = instruction.toLowerCase();

    if (index == 0) {
      return (typeStr: 'depart', modifier: null);
    }
    if (index == totalSteps - 1 ||
        lower.contains('đến') ||
        lower.contains('arrive') ||
        lower.contains('bên phải của bạn') ||
        lower.contains('bên trái của bạn')) {
      return (typeStr: 'arrive', modifier: null);
    }
    if (lower.contains('quay đầu') || lower.contains('u-turn') || lower.contains('uturn')) {
      return (typeStr: 'turn', modifier: 'u-turn');
    }
    if (lower.contains('bùng binh') || lower.contains('vòng xuyến') || lower.contains('roundabout') || lower.contains('rotary')) {
      return (typeStr: 'roundabout', modifier: null);
    }
    if (lower.contains('chếch sang phải') || lower.contains('hơi rẽ phải') || lower.contains('slight right') || lower.contains('nhập làn sang phải')) {
      return (typeStr: 'turn', modifier: 'slight right');
    }
    if (lower.contains('ngoặt sang phải') || lower.contains('sharp right')) {
      return (typeStr: 'turn', modifier: 'sharp right');
    }
    if (lower.contains('rẽ phải') || lower.contains('quẹo phải') || lower.contains('turn right')) {
      return (typeStr: 'turn', modifier: 'right');
    }
    if (lower.contains('chếch sang trái') || lower.contains('hơi rẽ trái') || lower.contains('slight left') || lower.contains('nhập làn sang trái')) {
      return (typeStr: 'turn', modifier: 'slight left');
    }
    if (lower.contains('ngoặt sang trái') || lower.contains('sharp left')) {
      return (typeStr: 'turn', modifier: 'sharp left');
    }
    if (lower.contains('rẽ trái') || lower.contains('quẹo trái') || lower.contains('turn left')) {
      return (typeStr: 'turn', modifier: 'left');
    }

    return (typeStr: 'straight', modifier: 'straight');
  }

  static String _extractStreetName(String instruction) {
    final prefixes = ['vào đường ', 'vào phố ', 'vào ', 'onto ', 'on '];
    for (final p in prefixes) {
      final idx = instruction.toLowerCase().indexOf(p);
      if (idx != -1) {
        return instruction.substring(idx + p.length).trim();
      }
    }
    return instruction;
  }
}
