import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import '../config/goong_config.dart';
import '../models/route_model.dart';

/// Dịch vụ Goong Map: Tìm kiếm địa điểm, Geocoding & Tính toán đường đi (Routing)
class GoongService {
  // Bộ nhớ đệm (In-Memory Cache) tối ưu quota Goong API (1000 requests/ngày cho 3-4 người dùng)
  static final Map<String, List<MapPlace>> _autocompleteCache = {};
  static final Map<String, MapPlace> _detailCache = {};
  static final Map<String, MapPlace> _reverseGeocodeCache = {};
  static final Map<String, NavRoute> _directionsCache = {};

  /// 1. Tìm kiếm địa điểm & Gợi ý (Place AutoComplete)
  /// TỐI ƯU HÓA:
  /// - Dùng cache kết quả truy vấn.
  /// - TUYỆT ĐỐI KHÔNG lặp gọi 5 lần Place Detail như trước (tránh tiêu tốn 300+ requests).
  /// - Chỉ trả về danh sách gợi ý kèm `placeId`, khi nào người dùng bấm chọn địa chỉ cụ thể
  ///   mới gọi Place Detail 1 lần duy nhất!
  Future<List<MapPlace>> searchPlaces(
    String query, {
    LatLng? nearLocation,
    int limit = 10,
  }) async {
    if (!GoongConfig.hasRestApiKey) return [];
    final clean = query.trim();
    if (clean.length < 2) return [];

    final cacheKey =
        '${clean.toLowerCase()}_${nearLocation?.latitude.toStringAsFixed(2)}_${nearLocation?.longitude.toStringAsFixed(2)}';
    if (_autocompleteCache.containsKey(cacheKey)) {
      return _autocompleteCache[cacheKey]!;
    }

    try {
      var urlStr =
          '${GoongConfig.placeAutoCompleteUrl}?api_key=${GoongConfig.restApiKey}&input=${Uri.encodeComponent(clean)}&limit=$limit';
      if (nearLocation != null) {
        urlStr += '&location=${nearLocation.latitude},${nearLocation.longitude}';
      }

      final res = await http.get(Uri.parse(urlStr)).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return [];

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final predictions = data['predictions'] as List? ?? [];
      if (predictions.isEmpty) return [];

      final places = <MapPlace>[];

      for (final p in predictions) {
        final placeId = p['place_id'] as String?;
        final description = p['description'] as String? ?? '';
        final structFormatting = p['structured_formatting'] as Map<String, dynamic>?;
        final mainText = structFormatting?['main_text'] as String? ?? description.split(',').first;
        final secondaryText = structFormatting?['secondary_text'] as String? ?? '';

        places.add(MapPlace(
          displayName: description,
          name: mainText,
          coordinate: const LatLng(0, 0), // Tọa độ tải lười (lazy) khi người dùng ấn vào
          placeId: placeId,
          type: 'place',
          category: secondaryText.isNotEmpty ? secondaryText : 'Địa điểm',
        ));
      }

      _autocompleteCache[cacheKey] = places;
      return places;
    } catch (e) {
      debugPrint('[GoongService] searchPlaces error: $e');
      return [];
    }
  }

  /// 2. Lấy tọa độ chi tiết của địa điểm (Place Detail)
  /// Được gọi duy nhất 1 lần khi người dùng CHỌN địa điểm từ danh sách gợi ý.
  Future<MapPlace?> getPlaceDetail(
    String placeId, {
    String? fallbackName,
    String? fallbackDisplay,
    LatLng? userLocation,
  }) async {
    if (!GoongConfig.hasRestApiKey) return null;
    if (_detailCache.containsKey(placeId)) {
      return _detailCache[placeId]!;
    }

    try {
      final url = Uri.parse('${GoongConfig.placeDetailUrl}?place_id=$placeId&api_key=${GoongConfig.restApiKey}');
      final res = await http.get(url).timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return null;

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final result = data['result'] as Map<String, dynamic>?;
      if (result == null) return null;

      final name = result['name'] as String? ?? fallbackName ?? 'Địa điểm';
      final formattedAddress = result['formatted_address'] as String? ?? fallbackDisplay ?? name;
      final geometry = result['geometry'] as Map<String, dynamic>?;
      final location = geometry?['location'] as Map<String, dynamic>?;

      if (location != null) {
        final lat = (location['lat'] as num).toDouble();
        final lng = (location['lng'] as num).toDouble();
        final coord = LatLng(lat, lng);

        double? dist;
        if (userLocation != null) {
          const distCalc = Distance();
          dist = distCalc.as(LengthUnit.Meter, userLocation, coord);
        }

        final place = MapPlace(
          displayName: formattedAddress,
          name: name,
          coordinate: coord,
          placeId: placeId,
          type: 'place',
          category: 'place',
          distanceMeters: dist,
        );
        _detailCache[placeId] = place;
        return place;
      }
      return null;
    } catch (e) {
      debugPrint('[GoongService] getPlaceDetail error: $e');
      return null;
    }
  }

  /// 3. Định vị ngược từ Tọa độ GPS ra Tên & Địa chỉ (Reverse Geocoding)
  Future<MapPlace?> reverseGeocode(LatLng point) async {
    if (!GoongConfig.hasRestApiKey) return null;
    final cacheKey = '${point.latitude.toStringAsFixed(4)},${point.longitude.toStringAsFixed(4)}';
    if (_reverseGeocodeCache.containsKey(cacheKey)) {
      return _reverseGeocodeCache[cacheKey]!;
    }

    try {
      final url = Uri.parse(
          '${GoongConfig.geocodeUrl}?latlng=${point.latitude},${point.longitude}&api_key=${GoongConfig.restApiKey}');
      final res = await http.get(url).timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return null;

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final results = data['results'] as List? ?? [];
      if (results.isEmpty) return null;

      final first = results.first as Map<String, dynamic>;
      final formattedAddress = first['formatted_address'] as String? ?? 'Vị trí đã chọn';
      final name = first['name'] as String? ?? formattedAddress.split(',').first;

      final place = MapPlace(
        displayName: formattedAddress,
        name: name,
        coordinate: point,
        type: 'address',
        category: 'place',
      );
      _reverseGeocodeCache[cacheKey] = place;
      return place;
    } catch (e) {
      debugPrint('[GoongService] reverseGeocode error: $e');
      return null;
    }
  }

  /// 4. Dẫn đường & Tìm lộ trình (Direction API)
  /// Phương tiện hỗ trợ: 'bike' (xe máy Việt Nam), 'car' (ô tô), 'taxi', 'truck'
  Future<NavRoute?> calculateRoute(
    LatLng start,
    LatLng destination, {
    String vehicle = 'bike',
  }) async {
    if (!GoongConfig.hasRestApiKey) return null;
    final cacheKey =
        '${start.latitude.toStringAsFixed(4)},${start.longitude.toStringAsFixed(4)}'
        '-${destination.latitude.toStringAsFixed(4)},${destination.longitude.toStringAsFixed(4)}-$vehicle';
    if (_directionsCache.containsKey(cacheKey)) {
      return _directionsCache[cacheKey]!;
    }

    try {
      final url = Uri.parse(
        '${GoongConfig.directionUrl}?origin=${start.latitude},${start.longitude}'
        '&destination=${destination.latitude},${destination.longitude}'
        '&vehicle=$vehicle&api_key=${GoongConfig.restApiKey}',
      );

      final res = await http.get(url).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final routes = data['routes'] as List? ?? [];
      if (routes.isEmpty) return null;

      final r = routes.first as Map<String, dynamic>;
      final legs = r['legs'] as List? ?? [];
      if (legs.isEmpty) return null;

      final leg = legs.first as Map<String, dynamic>;
      final distanceVal = (leg['distance']?['value'] as num?)?.toDouble() ?? 0.0;
      final durationVal = (leg['duration']?['value'] as num?)?.toDouble() ?? 0.0;

      // Giải mã Polyline chuẩn 5 chữ số thập phân
      final polylineStr = r['overview_polyline']?['points'] as String? ?? '';
      final polylinePoints = _decodePolyline(polylineStr);

      final steps = <NavStep>[];
      final rawSteps = leg['steps'] as List? ?? [];
      int idx = 0;
      for (final s in rawSteps) {
        final htmlInstruction = s['html_instructions'] as String? ?? s['instruction'] as String? ?? '';
        final cleanInstruction =
            htmlInstruction.replaceAll(RegExp(r'<[^>]*>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
        final stepDist = (s['distance']?['value'] as num?)?.toDouble() ?? 0.0;
        final stepDur = (s['duration']?['value'] as num?)?.toDouble() ?? 0.0;
        final startLoc = s['start_location'] as Map<String, dynamic>?;
        final stepCoord = (startLoc != null)
            ? LatLng((startLoc['lat'] as num).toDouble(), (startLoc['lng'] as num).toDouble())
            : (polylinePoints.isNotEmpty ? polylinePoints.first : start);

        final maneuver = s['maneuver'] as String? ?? 'turn-straight';
        final (mType, mMod) = _parseGoongManeuver(maneuver);

        steps.add(NavStep(
          stepIndex: idx++,
          instruction: cleanInstruction.isNotEmpty ? cleanInstruction : 'Tiếp tục đi thẳng',
          streetName: cleanInstruction,
          distanceMeters: stepDist,
          durationSeconds: stepDur,
          coordinate: stepCoord,
          maneuverTypeStr: mType,
          maneuverModifier: mMod,
        ));
      }

      final route = NavRoute(
        totalDistanceMeters: distanceVal,
        totalDurationSeconds: durationVal,
        polylinePoints: polylinePoints,
        steps: steps,
        summary: leg['summary'] as String? ?? 'Lộ trình Goong Map ($vehicle)',
      );
      _directionsCache[cacheKey] = route;
      return route;
    } catch (e) {
      debugPrint('[GoongService] calculateRoute error: $e');
      return null;
    }
  }

  (String, String) _parseGoongManeuver(String maneuver) {
    final m = maneuver.toLowerCase();
    if (m.contains('arrive')) return ('arrive', 'straight');
    if (m.contains('depart')) return ('depart', 'straight');
    if (m.contains('uturn') || m.contains('u-turn')) return ('turn', 'uturn');
    if (m.contains('sharp-right')) return ('turn', 'sharp right');
    if (m.contains('slight-right') || m.contains('keep-right')) return ('turn', 'slight right');
    if (m.contains('right')) return ('turn', 'right');
    if (m.contains('sharp-left')) return ('turn', 'sharp left');
    if (m.contains('slight-left') || m.contains('keep-left')) return ('turn', 'slight left');
    if (m.contains('left')) return ('turn', 'left');
    if (m.contains('roundabout')) return ('roundabout', 'straight');
    return ('turn', 'straight');
  }

  List<LatLng> _decodePolyline(String encoded) {
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

      poly.add(LatLng(lat / 1e5, lng / 1e5));
    }
    return poly;
  }
}
