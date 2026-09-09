import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import '../models/route_model.dart';

class ValhallaService {
  // Public Valhalla Server (or your self-hosted server: http://localhost:8002/route)
  static const String _valhallaBaseUrl = 'https://valhalla1.openstreetmap.de';

  /// Calculate Turn-by-Turn Route using Valhalla Routing Engine
  Future<NavRoute?> calculateRoute(
    LatLng start,
    LatLng destination, {
    String costing = 'auto', // 'auto', 'motorcycle', 'bicycle', 'pedestrian'
  }) async {
    try {
      final url = Uri.parse('$_valhallaBaseUrl/route');
      final requestBody = jsonEncode({
        'locations': [
          {'lat': start.latitude, 'lon': start.longitude, 'type': 'break'},
          {'lat': destination.latitude, 'lon': destination.longitude, 'type': 'break'}
        ],
        'costing': costing,
        'costing_options': {
          'auto': {'country_crossing_penalty': 2000.0}
        },
        'directions_options': {
          'units': 'kilometers',
          'language': 'vi-VN' // Vietnamese turn instructions
        }
      });

      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'User-Agent': 'ESP32_Valhalla_Navigator/1.0',
        },
        body: requestBody,
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        return null;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final trip = data['trip'] as Map<String, dynamic>?;
      if (trip == null || (trip['legs'] as List).isEmpty) {
        return null;
      }

      final leg = trip['legs'][0] as Map<String, dynamic>;
      final summary = trip['summary'] as Map<String, dynamic>;
      final totalDistanceMeters = ((summary['length'] as num).toDouble()) * 1000.0;
      final totalDurationSeconds = (summary['time'] as num).toDouble();

      // Decode Valhalla Encoded Shape (Polyline6)
      final shapeStr = leg['shape'] as String;
      final polylinePoints = _decodePolyline6(shapeStr);

      // Parse Valhalla Maneuvers for Turn-by-Turn & ESP32
      final steps = <NavStep>[];
      final maneuvers = leg['maneuvers'] as List;

      int globalIndex = 0;
      for (final m in maneuvers) {
        final instruction = (m['instruction'] as String? ?? '').trim();
        final streetNames = (m['street_names'] as List?)?.map((e) => e.toString()).toList() ?? [];
        final streetName = streetNames.isNotEmpty ? streetNames.first : 'Tiếp tục đi thẳng';
        final distanceMeters = ((m['length'] as num).toDouble()) * 1000.0;
        final durationSeconds = (m['time'] as num).toDouble();

        // Maneuver Type code mapping (Valhalla maneuver types 1..38)
        final valhallaType = m['type'] as int? ?? 0;
        final shapeIndex = m['begin_shape_index'] as int? ?? 0;
        final coord = (shapeIndex < polylinePoints.length)
            ? polylinePoints[shapeIndex]
            : (polylinePoints.isNotEmpty ? polylinePoints.last : start);

        final mappedTypeStr = _mapValhallaTypeToString(valhallaType);

        steps.add(NavStep(
          stepIndex: globalIndex++,
          instruction: instruction.isNotEmpty ? instruction : 'Tiếp tục trên $streetName',
          streetName: streetName,
          distanceMeters: distanceMeters,
          durationSeconds: durationSeconds,
          coordinate: coord,
          maneuverTypeStr: mappedTypeStr,
          maneuverModifier: _mapValhallaTypeToModifier(valhallaType),
        ));
      }

      return NavRoute(
        totalDistanceMeters: totalDistanceMeters,
        totalDurationSeconds: totalDurationSeconds,
        polylinePoints: polylinePoints,
        steps: steps,
        summary: leg['summary']?['name'] ?? 'Lộ trình Valhalla',
      );
    } catch (_) {
      return null;
    }
  }

  /// Decode Valhalla Precision 6 Polyline
  List<LatLng> _decodePolyline6(String encoded) {
    final poly = <LatLng>[];
    int index = 0, len = encoded.length;
    int lat = 0, lng = 0;

    while (index < len) {
      int b, shift = 0, result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lat += dlat;

      shift = 0;
      result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lng += dlng;

      poly.add(LatLng(lat / 1e6, lng / 1e6));
    }
    return poly;
  }

  String _mapValhallaTypeToString(int type) {
    if (type == 4 || type == 5 || type == 6) return 'arrive';
    if (type == 1 || type == 2 || type == 3) return 'depart';
    if (type >= 24 && type <= 27) return 'roundabout';
    return 'turn';
  }

  String _mapValhallaTypeToModifier(int type) {
    switch (type) {
      case 10: return 'slight right';
      case 11: return 'right';
      case 12: return 'sharp right';
      case 13: return 'u-turn';
      case 14: return 'sharp left';
      case 15: return 'left';
      case 16: return 'slight left';
      case 7:
      case 8:
      case 9:
      default: return 'straight';
    }
  }
}
