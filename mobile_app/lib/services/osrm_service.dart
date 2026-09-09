import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import '../models/route_model.dart';

class OsrmService {
  static const String _osrmBaseUrl = 'https://router.project-osrm.org';
  static const String _nominatimBaseUrl = 'https://nominatim.openstreetmap.org';

  /// Calculate route between start and end coordinates using OSRM
  Future<NavRoute?> calculateRoute(
    LatLng start,
    LatLng destination, {
    String profile = 'driving',
  }) async {
    try {
      final url = Uri.parse(
        '$_osrmBaseUrl/route/v1/$profile/'
        '${start.longitude},${start.latitude};${destination.longitude},${destination.latitude}'
        '?overview=full&geometries=geojson&steps=true&annotations=false',
      );

      final response = await http.get(url, headers: {
        'User-Agent': 'ESP32_IOS_Navigator/1.0',
      }).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        return null;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (data['code'] != 'Ok' || (data['routes'] as List).isEmpty) {
        return null;
      }

      final routeJson = data['routes'][0] as Map<String, dynamic>;
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

          // Generate Vietnamese instruction
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

      final summary = routeJson['legs'][0]['summary'] as String? ?? 'Lộ trình tối ưu';

      return NavRoute(
        totalDistanceMeters: totalDistance,
        totalDurationSeconds: totalDuration,
        polylinePoints: polylinePoints,
        steps: steps,
        summary: summary,
      );
    } catch (e) {
      // Return null on failure
      return null;
    }
  }

  /// Search places via OpenStreetMap Nominatim API
  Future<List<MapPlace>> searchPlaces(String query, {LatLng? nearLocation}) async {
    if (query.trim().isEmpty) return [];

    try {
      var urlStr = '$_nominatimBaseUrl/search?q=${Uri.encodeComponent(query)}&format=json&addressdetails=1&limit=8';
      if (nearLocation != null) {
        // Bias search towards user location
        urlStr += '&viewbox=${nearLocation.longitude - 0.5},${nearLocation.latitude + 0.5},'
                  '${nearLocation.longitude + 0.5},${nearLocation.latitude - 0.5}&bounded=0';
      }

      final response = await http.get(Uri.parse(urlStr), headers: {
        'User-Agent': 'ESP32_IOS_Navigator/1.0',
        'Accept-Language': 'vi,en;q=0.9',
      }).timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        final list = jsonDecode(response.body) as List;
        return list.map((item) => MapPlace.fromJson(item)).toList();
      }
    } catch (_) {}
    return [];
  }

  /// Reverse geocoding for coordinates
  Future<String> getAddressFromCoordinate(LatLng location) async {
    try {
      final url = Uri.parse(
        '$_nominatimBaseUrl/reverse?lat=${location.latitude}&lon=${location.longitude}&format=json',
      );
      final response = await http.get(url, headers: {
        'User-Agent': 'ESP32_IOS_Navigator/1.0',
        'Accept-Language': 'vi,en;q=0.9',
      }).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['display_name'] as String? ?? 'Vị trí đã chọn';
      }
    } catch (_) {}
    return 'Vị trí (${location.latitude.toStringAsFixed(4)}, ${location.longitude.toStringAsFixed(4)})';
  }

  /// Helper to create localized turn instructions
  String _buildInstruction(String type, String? modifier, String street) {
    if (type == 'depart') return 'Bắt đầu di chuyển trên $street';
    if (type == 'arrive') return 'Bạn đã đến điểm đến!';
    if (type == 'roundabout') return 'Đi vào vòng xuyến, tiếp tục theo $street';

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
