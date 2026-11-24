import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import '../config/goong_config.dart';
import '../models/route_model.dart';
import 'overpass_traffic_service.dart';

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
    int? radiusMeters,
    int limit = 12,
  }) async {
    if (!GoongConfig.hasRestApiKey) return [];
    final clean = query.trim();
    if (clean.length < 2) return [];

    final cacheKey =
        '${clean.toLowerCase()}_${nearLocation?.latitude.toStringAsFixed(2)}_${nearLocation?.longitude.toStringAsFixed(2)}_${radiusMeters ?? 0}';
    if (_autocompleteCache.containsKey(cacheKey)) {
      return _autocompleteCache[cacheKey]!;
    }

    try {
      var urlStr =
          '${GoongConfig.placeAutoCompleteUrl}?api_key=${GoongConfig.restApiKey}&input=${Uri.encodeComponent(clean)}&limit=$limit';
      if (nearLocation != null) {
        urlStr += '&location=${nearLocation.latitude},${nearLocation.longitude}';
        if (radiusMeters != null && radiusMeters > 0) {
          urlStr += '&radius=$radiusMeters';
        }
      }

      final res = await http.get(Uri.parse(urlStr)).timeout(const Duration(milliseconds: 4500));
      if (res.statusCode != 200) return [];

      final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
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

  /// Tìm nhanh tiện ích quanh tọa độ [center] trong bán kính [radiusMeters] (mặc định 5000m):
  /// Kết hợp Goong Place AutoComplete (`location=$lat,$lng&radius=5000`) + Overpass API (`amenity=...`),
  /// giải mã tọa độ chính xác và gộp lọc trùng trong bán kính 60m.
  Future<List<MapPlace>> searchNearbyUtilities(
    LatLng center, {
    required String keyword,
    required String amenityTag,
    required String categoryLabel,
    int radiusMeters = 5000,
    int limit = 12,
  }) async {
    const distCalc = Distance();
    final overpassFuture = OverpassTrafficService().searchNearbyAmenities(
      center,
      amenityTag: amenityTag,
      defaultName: categoryLabel,
      radiusMeters: radiusMeters,
      limit: limit,
    );

    final goongFuture = () async {
      final raw = await searchPlaces(
        keyword,
        nearLocation: center,
        radiusMeters: radiusMeters,
        limit: 6,
      );
      if (raw.isEmpty) return const <MapPlace>[];
      final detailFutures = raw.take(5).map((p) async {
        if (p.placeId == null || p.placeId!.isEmpty) return null;
        final d = await getPlaceDetail(
          p.placeId!,
          fallbackName: p.name,
          fallbackDisplay: p.displayName,
          userLocation: center,
        );
        if (d == null) return null;
        if (d.coordinate.latitude == 0 && d.coordinate.longitude == 0) return null;
        final distM = distCalc.as(LengthUnit.Meter, center, d.coordinate);
        if (distM > radiusMeters * 1.6) return null;
        return MapPlace(
          displayName: d.displayName,
          name: d.name,
          coordinate: d.coordinate,
          type: amenityTag,
          category: categoryLabel,
          placeId: d.placeId,
          distanceMeters: distM,
        );
      });
      final resolved = await Future.wait(detailFutures);
      return resolved.whereType<MapPlace>().toList();
    }();

    final results = await Future.wait([goongFuture, overpassFuture]);
    final merged = <MapPlace>[];

    for (final list in results) {
      for (final item in list) {
        final isDup = merged.any(
          (e) => distCalc.as(LengthUnit.Meter, e.coordinate, item.coordinate) <= 60.0,
        );
        if (!isDup) {
          merged.add(item);
        }
      }
    }

    merged.sort((a, b) => (a.distanceMeters ?? 999999).compareTo(b.distanceMeters ?? 999999));
    return merged.take(limit).toList();
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
      final res = await http.get(url).timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return null;

      final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
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

  /// Trả về tên con đường sạch tại tọa độ [point] (bỏ số nhà & phường/quận).
  Future<String?> reverseGeocodeStreet(LatLng point) async {
    final place = await reverseGeocode(point);
    if (place == null) return null;
    final firstSeg = place.displayName.split(',').first.trim();
    if (firstSeg.isEmpty || firstSeg == 'Vị trí đã chọn') return null;
    final withoutNumber =
        firstSeg.replaceFirst(RegExp(r'^(?:Số\s+)?\d+[A-Za-z0-9/\-\.]*\s+'), '').trim();
    return withoutNumber.isNotEmpty ? withoutNumber : null;
  }

  /// 4. Dẫn đường & Tìm lộ trình (Direction API)
  /// Phương tiện hỗ trợ: 'bike' (xe máy Việt Nam), 'car' (ô tô), 'taxi', 'truck'
  Future<NavRoute?> calculateRoute(
    LatLng start,
    LatLng destination, {
    String vehicle = 'bike',
  }) async {
    final routes = await calculateMultipleRoutes(start, destination, vehicle: vehicle);
    return routes.isNotEmpty ? routes.first : null;
  }

  /// Lấy danh sách lộ trình độ phân giải cao (ghép polyline chi tiết từ từng bước rẽ để bám sát mặt đường).
  Future<List<NavRoute>> calculateMultipleRoutes(
    LatLng start,
    LatLng destination, {
    String vehicle = 'bike',
  }) async {
    if (!GoongConfig.hasRestApiKey) return [];
    final cacheKey =
        '${start.latitude.toStringAsFixed(4)},${start.longitude.toStringAsFixed(4)}'
        '-${destination.latitude.toStringAsFixed(4)},${destination.longitude.toStringAsFixed(4)}-$vehicle';
    if (_directionsCache.containsKey(cacheKey)) {
      return [_directionsCache[cacheKey]!];
    }

    try {
      final url = Uri.parse(
        '${GoongConfig.directionUrl}?origin=${start.latitude},${start.longitude}'
        '&destination=${destination.latitude},${destination.longitude}'
        '&vehicle=$vehicle&language=vi&api_key=${GoongConfig.restApiKey}',
      );

      final res = await http.get(url).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return [];

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final parsed = parseDirectionResponse(
        data,
        fallbackStart: start,
        vehicle: vehicle,
      );
      if (parsed.isNotEmpty) {
        _directionsCache[cacheKey] = parsed.first;
      }
      return parsed;
    } catch (e) {
      debugPrint('[GoongService] calculateRoute error: $e');
      return [];
    }
  }

  /// Giải mã phản hồi Direction API thành danh sách [NavRoute] với polyline chi tiết ghép từ từng step.
  @visibleForTesting
  static List<NavRoute> parseDirectionResponse(
    Map<String, dynamic> data, {
    required LatLng fallbackStart,
    String vehicle = 'bike',
  }) {
    final rawRoutes = data['routes'] as List? ?? [];
    if (rawRoutes.isEmpty) return [];

    const distCalc = Distance();
    final parsedRoutes = <NavRoute>[];

    for (final rawRoute in rawRoutes) {
      if (rawRoute is! Map<String, dynamic>) continue;
      final legs = rawRoute['legs'] as List? ?? [];
      if (legs.isEmpty) continue;

      final leg = legs.first as Map<String, dynamic>;
      final distanceVal = (leg['distance']?['value'] as num?)?.toDouble() ?? 0.0;
      final durationVal = (leg['duration']?['value'] as num?)?.toDouble() ?? 0.0;

      // Ưu tiên ghép polyline độ phân giải cao từ từng step để đường dẫn bám sát từng khúc cua
      final overviewStr = rawRoute['overview_polyline']?['points'] as String? ?? '';
      final overviewPoints = decodePolyline(overviewStr);
      final stitchedPoints = <LatLng>[];

      final steps = <NavStep>[];
      final rawSteps = leg['steps'] as List? ?? [];
      int idx = 0;
      for (final s in rawSteps) {
        if (s is! Map<String, dynamic>) continue;
        final stepPolyStr = s['polyline']?['points'] as String? ?? '';
        final stepPolyPts = stepPolyStr.isNotEmpty ? decodePolyline(stepPolyStr) : const <LatLng>[];
        for (final pt in stepPolyPts) {
          if (stitchedPoints.isEmpty ||
              distCalc.as(LengthUnit.Meter, stitchedPoints.last, pt) >= 0.5) {
            stitchedPoints.add(pt);
          }
        }

        final htmlInstruction =
            s['html_instructions'] as String? ?? s['instruction'] as String? ?? '';
        final cleanInstruction =
            htmlInstruction.replaceAll(RegExp(r'<[^>]*>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
        final stepDist = (s['distance']?['value'] as num?)?.toDouble() ?? 0.0;
        final stepDur = (s['duration']?['value'] as num?)?.toDouble() ?? 0.0;
        final startLoc = s['start_location'] as Map<String, dynamic>?;
        final stepCoord = (startLoc != null)
            ? LatLng((startLoc['lat'] as num).toDouble(), (startLoc['lng'] as num).toDouble())
            : (stepPolyPts.isNotEmpty
                ? stepPolyPts.first
                : (overviewPoints.isNotEmpty ? overviewPoints.first : fallbackStart));

        final maneuver = s['maneuver'] as String? ?? 'turn-straight';
        final (mType, mMod) = _parseGoongManeuverStatic(maneuver);

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

      final polylinePoints = (stitchedPoints.length >= 2 && stitchedPoints.length >= overviewPoints.length)
          ? stitchedPoints
          : overviewPoints;

      final rawSummary = (leg['summary'] as String? ?? '').trim();
      parsedRoutes.add(NavRoute(
        totalDistanceMeters: distanceVal,
        totalDurationSeconds: durationVal,
        polylinePoints: polylinePoints,
        steps: steps,
        summary: rawSummary.isNotEmpty ? rawSummary : 'Lộ trình đề xuất',
      ));
    }

    return parsedRoutes;
  }

  static (String, String) _parseGoongManeuverStatic(String maneuver) {
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

  /// Giải mã chuỗi Google Encoded Polyline chuẩn 5 chữ số thập phân.
  @visibleForTesting
  static List<LatLng> decodePolyline(String encoded) {
    final poly = <LatLng>[];
    int index = 0, len = encoded.length;
    int lat = 0, lng = 0;

    while (index < len) {
      int b, shift = 0, result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20 && index < len);
      int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lat += dlat;

      if (index >= len) break;
      shift = 0;
      result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20 && index < len);
      int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lng += dlng;

      poly.add(LatLng(lat / 1e5, lng / 1e5));
    }
    return poly;
  }
}
