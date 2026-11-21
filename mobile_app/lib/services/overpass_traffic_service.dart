import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import '../models/route_model.dart';

/// Loại điểm cảnh báo giao thông
enum TrafficHazardType {
  speedCamera,
  trafficSign,
  stopSign,
  railwayCrossing,
}

extension TrafficHazardTypeExt on TrafficHazardType {
  String get wireKey {
    switch (this) {
      case TrafficHazardType.speedCamera:
        return 'speed_camera';
      case TrafficHazardType.trafficSign:
        return 'traffic_sign';
      case TrafficHazardType.stopSign:
        return 'stop';
      case TrafficHazardType.railwayCrossing:
        return 'railway';
    }
  }

  String get labelVi {
    switch (this) {
      case TrafficHazardType.speedCamera:
        return 'Camera phạt nguội';
      case TrafficHazardType.trafficSign:
        return 'Biển báo nguy hiểm';
      case TrafficHazardType.stopSign:
        return 'Biển báo dừng lại';
      case TrafficHazardType.railwayCrossing:
        return 'Đường sắt cắt ngang';
    }
  }
}

/// Một đoạn đường OSM kèm tốc độ giới hạn thực tế hoặc nội suy từ phân loại `highway`
class SpeedRoadSegment {
  final int wayId;
  final int speedLimitKmh;
  final bool hasExplicitMaxspeed;
  final String highwayType;
  final String? roadName;
  final List<LatLng> points;

  const SpeedRoadSegment({
    required this.wayId,
    required this.speedLimitKmh,
    required this.hasExplicitMaxspeed,
    required this.highwayType,
    this.roadName,
    required this.points,
  });
}

/// Một điểm cảnh báo (Camera phạt nguội / Biển báo / Đường sắt)
class TrafficHazardNode {
  final String id;
  final LatLng coordinate;
  final TrafficHazardType type;
  final int? speedLimitKmh;
  final String description;
  final String source; // 'osm' | 'local_vn' | 'remote_vn'

  const TrafficHazardNode({
    required this.id,
    required this.coordinate,
    required this.type,
    this.speedLimitKmh,
    required this.description,
    required this.source,
  });
}

/// Tập dữ liệu giao thông cho một tuyến đường hoặc khu vực hiện tại
class RouteTrafficData {
  final List<SpeedRoadSegment> roadSegments;
  final List<TrafficHazardNode> hazards;
  final DateTime fetchedAt;

  const RouteTrafficData({
    required this.roadSegments,
    required this.hazards,
    required this.fetchedAt,
  });

  static RouteTrafficData empty() => RouteTrafficData(
        roadSegments: const [],
        hazards: const [],
        fetchedAt: DateTime.fromMillisecondsSinceEpoch(0),
      );
}

/// Bounding Box địa lý (Nam, Tây, Bắc, Đông)
class GeoBBox {
  final double south;
  final double west;
  final double north;
  final double east;

  const GeoBBox({
    required this.south,
    required this.west,
    required this.north,
    required this.east,
  });

  bool contains(LatLng pt) =>
      pt.latitude >= south &&
      pt.latitude <= north &&
      pt.longitude >= west &&
      pt.longitude <= east;

  String toOverpassBBox() =>
      '${south.toStringAsFixed(5)},${west.toStringAsFixed(5)},${north.toStringAsFixed(5)},${east.toStringAsFixed(5)}';
}

/// Service truy vấn dữ liệu Tốc độ giới hạn, Camera phạt nguội, Biển báo & Tiện ích từ OSM Overpass API
/// kết hợp kho dữ liệu camera Việt Nam (`assets/data/cameras_vn.json` + cập nhật từ GitHub raw URL).
class OverpassTrafficService {
  static final OverpassTrafficService _instance = OverpassTrafficService._internal();
  factory OverpassTrafficService() => _instance;
  OverpassTrafficService._internal();

  static const String _primaryOverpassUrl = 'https://overpass-api.de/api/interpreter';
  static const String _fallbackOverpassUrl = 'https://overpass.kumi.systems/api/interpreter';
  static const String defaultRemoteCamerasUrl =
      'https://raw.githubusercontent.com/ysiduc/esp32-ios-nav/main/mobile_app/assets/data/cameras_vn.json';

  static final Map<String, RouteTrafficData> _routeCache = {};
  static List<TrafficHazardNode>? _cachedLocalVnCameras;
  static List<TrafficHazardNode>? _cachedRemoteVnCameras;
  static DateTime? _lastRemoteFetchTime;

  /// 1. Tính toán Bounding Box của danh sách điểm `polyline` và mở rộng thêm [marginMeters] (mặc định 500m) mỗi cạnh.
  @visibleForTesting
  static GeoBBox computeExpandedBBox(
    List<LatLng> polyline, {
    double marginMeters = 500.0,
  }) {
    if (polyline.isEmpty) {
      return const GeoBBox(south: 21.0, west: 105.8, north: 21.05, east: 105.85);
    }
    double minLat = polyline.first.latitude;
    double maxLat = polyline.first.latitude;
    double minLng = polyline.first.longitude;
    double maxLng = polyline.first.longitude;

    for (final p in polyline) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }

    final double midLat = (minLat + maxLat) * 0.5;
    final double cosLat = math.cos(midLat * (math.pi / 180.0)).abs().clamp(0.15, 1.0);
    final double dLat = marginMeters / 110540.0;
    final double dLng = marginMeters / (111320.0 * cosLat);

    return GeoBBox(
      south: minLat - dLat,
      west: minLng - dLng,
      north: maxLat + dLat,
      east: maxLng + dLng,
    );
  }

  /// 2. Thuật toán nội suy tốc độ giới hạn từ thẻ `maxspeed` hoặc dự phòng từ thẻ `highway`:
  /// - Nếu có `maxspeed` hợp lệ ("60", "80", "60 km/h", "50 mph"...): dùng trực tiếp.
  /// - Nếu không có `maxspeed`: `motorway` -> 100, `trunk` -> 80, `primary` -> 60,
  ///   `secondary` -> 60, `tertiary`/`residential` -> 50.
  @visibleForTesting
  static ({int speedLimitKmh, bool hasExplicitMaxspeed})? resolveSpeedLimitKmh({
    String? maxspeedTag,
    String? highwayTag,
  }) {
    if (maxspeedTag != null && maxspeedTag.trim().isNotEmpty) {
      final raw = maxspeedTag.trim().toLowerCase();
      final match = RegExp(r'(\d+)').firstMatch(raw);
      if (match != null) {
        var val = int.tryParse(match.group(1)!) ?? 0;
        if (raw.contains('mph')) {
          val = (val * 1.60934).round();
        }
        if (val >= 15 && val <= 140) {
          return (speedLimitKmh: val, hasExplicitMaxspeed: true);
        }
      }
    }

    final hw = (highwayTag ?? '').trim().toLowerCase();
    switch (hw) {
      case 'motorway':
      case 'motorway_link':
        return (speedLimitKmh: 100, hasExplicitMaxspeed: false);
      case 'trunk':
      case 'trunk_link':
        return (speedLimitKmh: 80, hasExplicitMaxspeed: false);
      case 'primary':
      case 'primary_link':
      case 'secondary':
      case 'secondary_link':
        return (speedLimitKmh: 60, hasExplicitMaxspeed: false);
      case 'tertiary':
      case 'tertiary_link':
      case 'residential':
      case 'unclassified':
      case 'living_street':
        return (speedLimitKmh: 50, hasExplicitMaxspeed: false);
      default:
        return null;
    }
  }

  /// Xây dựng câu truy vấn Overpass QL lấy đồng thời đường (`maxspeed`/`highway`), camera phạt nguội và biển báo nguy hiểm.
  @visibleForTesting
  static String buildTrafficOverpassQuery(GeoBBox bbox) {
    final b = bbox.toOverpassBBox();
    return '''
[out:json][timeout:15];
(
  way["maxspeed"]($b);
  way["highway"~"^(motorway|trunk|primary|secondary|tertiary|residential|motorway_link|trunk_link|primary_link|secondary_link)\$"]($b);
  node["highway"="speed_camera"]($b);
  node["enforcement"="maxspeed"]($b);
  node["traffic_sign"]($b);
  node["highway"="stop"]($b);
  node["railway"="level_crossing"]($b);
);
out body geom;
''';
  }

  /// Giải mã JSON trả về từ Overpass API thành danh sách đoạn đường tốc độ và điểm cảnh báo.
  @visibleForTesting
  static ({List<SpeedRoadSegment> segments, List<TrafficHazardNode> hazards}) parseOverpassTrafficResponse(
    Map<String, dynamic> data,
  ) {
    final elements = data['elements'] as List? ?? [];
    final segments = <SpeedRoadSegment>[];
    final hazards = <TrafficHazardNode>[];

    for (final raw in elements) {
      if (raw is! Map<String, dynamic>) continue;
      final elemType = raw['type'] as String? ?? '';
      final tags = (raw['tags'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};

      if (elemType == 'way') {
        final geom = raw['geometry'] as List? ?? [];
        if (geom.length < 2) continue;
        final resolved = resolveSpeedLimitKmh(
          maxspeedTag: tags['maxspeed']?.toString(),
          highwayTag: tags['highway']?.toString(),
        );
        if (resolved == null) continue;

        final pts = <LatLng>[];
        for (final g in geom) {
          if (g is Map && g['lat'] is num && g['lon'] is num) {
            pts.add(LatLng((g['lat'] as num).toDouble(), (g['lon'] as num).toDouble()));
          }
        }
        if (pts.length < 2) continue;

        segments.add(SpeedRoadSegment(
          wayId: (raw['id'] as num?)?.toInt() ?? 0,
          speedLimitKmh: resolved.speedLimitKmh,
          hasExplicitMaxspeed: resolved.hasExplicitMaxspeed,
          highwayType: tags['highway']?.toString() ?? '',
          roadName: (tags['name'] ?? tags['ref'])?.toString(),
          points: pts,
        ));
      } else if (elemType == 'node') {
        final lat = (raw['lat'] as num?)?.toDouble();
        final lon = (raw['lon'] as num?)?.toDouble();
        if (lat == null || lon == null) continue;

        final id = 'osm_${raw['id']}';
        final highway = tags['highway']?.toString().toLowerCase() ?? '';
        final enforcement = tags['enforcement']?.toString().toLowerCase() ?? '';
        final railway = tags['railway']?.toString().toLowerCase() ?? '';
        final trafficSign = tags['traffic_sign']?.toString() ?? '';
        final maxspeedResolved = resolveSpeedLimitKmh(maxspeedTag: tags['maxspeed']?.toString());

        if (highway == 'speed_camera' || enforcement == 'maxspeed') {
          hazards.add(TrafficHazardNode(
            id: id,
            coordinate: LatLng(lat, lon),
            type: TrafficHazardType.speedCamera,
            speedLimitKmh: maxspeedResolved?.speedLimitKmh,
            description: tags['name']?.toString() ??
                tags['description']?.toString() ??
                'Camera giám sát tốc độ',
            source: 'osm',
          ));
        } else if (railway == 'level_crossing') {
          hazards.add(TrafficHazardNode(
            id: id,
            coordinate: LatLng(lat, lon),
            type: TrafficHazardType.railwayCrossing,
            speedLimitKmh: maxspeedResolved?.speedLimitKmh,
            description: tags['name']?.toString() ?? 'Giao cắt đường sắt',
            source: 'osm',
          ));
        } else if (highway == 'stop') {
          hazards.add(TrafficHazardNode(
            id: id,
            coordinate: LatLng(lat, lon),
            type: TrafficHazardType.stopSign,
            speedLimitKmh: maxspeedResolved?.speedLimitKmh,
            description: 'Biển báo dừng lại (STOP)',
            source: 'osm',
          ));
        } else if (trafficSign.isNotEmpty) {
          hazards.add(TrafficHazardNode(
            id: id,
            coordinate: LatLng(lat, lon),
            type: TrafficHazardType.trafficSign,
            speedLimitKmh: maxspeedResolved?.speedLimitKmh,
            description: _describeTrafficSign(trafficSign, maxspeedResolved?.speedLimitKmh),
            source: 'osm',
          ));
        }
      }
    }

    return (segments: segments, hazards: hazards);
  }

  static String _describeTrafficSign(String signTag, int? limitKmh) {
    final lower = signTag.toLowerCase();
    if (limitKmh != null || lower.contains('maxspeed')) {
      return limitKmh != null
          ? 'Biển giới hạn tốc độ $limitKmh km/h'
          : 'Biển báo giới hạn tốc độ';
    }
    if (lower.contains('city_limit') || lower.contains('urban')) {
      return 'Khu vực đông dân cư';
    }
    if (lower.contains('school') || lower.contains('children')) {
      return 'Khu vực trường học';
    }
    if (lower.contains('curve') || lower.contains('bend')) {
      return 'Đoạn đường cong nguy hiểm';
    }
    return 'Biển báo giao thông phía trước';
  }

  /// Giải mã danh sách camera từ định dạng `cameras_vn.json`.
  @visibleForTesting
  static List<TrafficHazardNode> parseVietnamCameraJson(
    String jsonStr, {
    String source = 'local_vn',
  }) {
    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is! List) return const [];
      final out = <TrafficHazardNode>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        final lat = (item['lat'] as num?)?.toDouble();
        final lng = (item['lng'] as num?)?.toDouble();
        if (lat == null || lng == null) continue;
        final typeStr = (item['type'] as String? ?? 'speed_camera').toLowerCase();
        final type = switch (typeStr) {
          'railway' || 'railway_crossing' || 'level_crossing' => TrafficHazardType.railwayCrossing,
          'stop' || 'stop_sign' => TrafficHazardType.stopSign,
          'traffic_sign' || 'sign' => TrafficHazardType.trafficSign,
          _ => TrafficHazardType.speedCamera,
        };
        out.add(TrafficHazardNode(
          id: (item['id'] as String?)?.trim().isNotEmpty == true
              ? item['id'] as String
              : '${source}_${lat.toStringAsFixed(4)}_${lng.toStringAsFixed(4)}',
          coordinate: LatLng(lat, lng),
          type: type,
          speedLimitKmh: (item['limit'] as num?)?.toInt(),
          description: (item['desc'] as String?)?.trim().isNotEmpty == true
              ? item['desc'] as String
              : type.labelVi,
          source: source,
        ));
      }
      return out;
    } catch (e) {
      debugPrint('[OverpassTrafficService] parseVietnamCameraJson error: $e');
      return const [];
    }
  }

  /// Tải danh sách camera Việt Nam tích hợp sẵn từ `assets/data/cameras_vn.json`.
  Future<List<TrafficHazardNode>> loadLocalVietnamCameras() async {
    if (_cachedLocalVnCameras != null) return _cachedLocalVnCameras!;
    try {
      final raw = await rootBundle.loadString('assets/data/cameras_vn.json');
      _cachedLocalVnCameras = parseVietnamCameraJson(raw, source: 'local_vn');
      return _cachedLocalVnCameras!;
    } catch (e) {
      debugPrint('[OverpassTrafficService] loadLocalVietnamCameras error: $e');
      return const [];
    }
  }

  /// Tải danh sách camera cập nhật mới nhất từ raw URL GitHub (nếu có mạng, cache 30 phút).
  Future<List<TrafficHazardNode>> fetchRemoteVietnamCameras({
    String rawUrl = defaultRemoteCamerasUrl,
  }) async {
    final now = DateTime.now();
    if (_cachedRemoteVnCameras != null &&
        _lastRemoteFetchTime != null &&
        now.difference(_lastRemoteFetchTime!).inMinutes < 30) {
      return _cachedRemoteVnCameras!;
    }
    try {
      final res = await http.get(Uri.parse(rawUrl)).timeout(const Duration(seconds: 5));
      if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
        final parsed = parseVietnamCameraJson(
          utf8.decode(res.bodyBytes),
          source: 'remote_vn',
        );
        if (parsed.isNotEmpty) {
          _cachedRemoteVnCameras = parsed;
          _lastRemoteFetchTime = now;
          return parsed;
        }
      }
    } catch (e) {
      debugPrint('[OverpassTrafficService] fetchRemoteVietnamCameras skipped: $e');
    }
    return _cachedRemoteVnCameras ?? const [];
  }

  /// Gộp các danh sách camera/biển báo (Local VN + Remote GitHub + Overpass OSM)
  /// và lọc trùng lặp các điểm cùng loại trong bán kính [dedupeRadiusMeters] (mặc định 50m).
  /// Ưu tiên giữ điểm có đầy đủ `speedLimitKmh` và mô tả tiếng Việt chi tiết.
  @visibleForTesting
  static List<TrafficHazardNode> mergeAndDeduplicateHazards(
    List<List<TrafficHazardNode>> sources, {
    double dedupeRadiusMeters = 50.0,
  }) {
    const distCalc = Distance();
    final merged = <TrafficHazardNode>[];

    int richnessScore(TrafficHazardNode n) {
      int score = 0;
      if (n.speedLimitKmh != null && n.speedLimitKmh! > 0) score += 3;
      if (n.source == 'remote_vn') score += 3;
      if (n.source == 'local_vn') score += 2;
      if (n.description.length > 22) score += 1;
      return score;
    }

    for (final list in sources) {
      for (final candidate in list) {
        int dupIdx = -1;
        for (int i = 0; i < merged.length; i++) {
          final existing = merged[i];
          if (existing.type != candidate.type) continue;
          final d = distCalc.as(LengthUnit.Meter, existing.coordinate, candidate.coordinate);
          if (d <= dedupeRadiusMeters) {
            dupIdx = i;
            break;
          }
        }
        if (dupIdx == -1) {
          merged.add(candidate);
        } else {
          final existing = merged[dupIdx];
          if (richnessScore(candidate) > richnessScore(existing)) {
            merged[dupIdx] = TrafficHazardNode(
              id: candidate.id,
              coordinate: candidate.coordinate,
              type: candidate.type,
              speedLimitKmh: candidate.speedLimitKmh ?? existing.speedLimitKmh,
              description: candidate.description,
              source: candidate.source,
            );
          } else if (existing.speedLimitKmh == null && candidate.speedLimitKmh != null) {
            merged[dupIdx] = TrafficHazardNode(
              id: existing.id,
              coordinate: existing.coordinate,
              type: existing.type,
              speedLimitKmh: candidate.speedLimitKmh,
              description: existing.description,
              source: existing.source,
            );
          }
        }
      }
    }
    return merged;
  }

  /// Lấy toàn bộ dữ liệu giao thông cho lộ trình [polyline] (Overpass API + `cameras_vn.json` + GitHub remote).
  Future<RouteTrafficData> fetchTrafficForRoute(
    List<LatLng> polyline, {
    double marginMeters = 500.0,
    bool includeRemoteVnUpdate = true,
  }) async {
    if (polyline.isEmpty) return RouteTrafficData.empty();

    final bbox = computeExpandedBBox(polyline, marginMeters: marginMeters);
    final cacheKey = bbox.toOverpassBBox();
    final cached = _routeCache[cacheKey];
    if (cached != null && DateTime.now().difference(cached.fetchedAt).inMinutes < 20) {
      return cached;
    }

    // Chạy song song: tải local VN cameras, remote GitHub cameras (nếu có mạng) và Overpass API
    final localFuture = loadLocalVietnamCameras();
    final remoteFuture =
        includeRemoteVnUpdate ? fetchRemoteVietnamCameras() : Future.value(const <TrafficHazardNode>[]);
    final overpassFuture = _queryOverpassTraffic(bbox);

    final results = await Future.wait([localFuture, remoteFuture, overpassFuture]);
    final localVn = (results[0] as List<TrafficHazardNode>).where((c) => bbox.contains(c.coordinate)).toList();
    final remoteVn = (results[1] as List<TrafficHazardNode>).where((c) => bbox.contains(c.coordinate)).toList();
    final overpassParsed =
        results[2] as ({List<SpeedRoadSegment> segments, List<TrafficHazardNode> hazards});

    final mergedHazards = mergeAndDeduplicateHazards(
      [remoteVn, localVn, overpassParsed.hazards],
      dedupeRadiusMeters: 50.0,
    );

    final data = RouteTrafficData(
      roadSegments: overpassParsed.segments,
      hazards: mergedHazards,
      fetchedAt: DateTime.now(),
    );

    _routeCache[cacheKey] = data;
    if (_routeCache.length > 16) {
      _routeCache.remove(_routeCache.keys.first);
    }
    return data;
  }

  /// Tải dữ liệu camera & tốc độ quanh một điểm GPS (dùng khi chạy tự do chưa bấm lộ trình).
  Future<RouteTrafficData> fetchTrafficAroundLocation(
    LatLng center, {
    double radiusMeters = 1500.0,
  }) async {
    return fetchTrafficForRoute([center], marginMeters: radiusMeters);
  }

  Future<({List<SpeedRoadSegment> segments, List<TrafficHazardNode> hazards})> _queryOverpassTraffic(
    GeoBBox bbox,
  ) async {
    final query = buildTrafficOverpassQuery(bbox);
    for (final endpoint in const [_primaryOverpassUrl, _fallbackOverpassUrl]) {
      try {
        final res = await http
            .post(
              Uri.parse(endpoint),
              headers: {
                'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
                'User-Agent': 'HoaHuongDuongNav/2.0 (Flutter iOS)',
              },
              body: {'data': query},
            )
            .timeout(const Duration(seconds: 12));
        if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
          final json = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
          return parseOverpassTrafficResponse(json);
        }
      } catch (e) {
        debugPrint('[OverpassTrafficService] endpoint $endpoint error: $e');
      }
    }
    return (segments: const <SpeedRoadSegment>[], hazards: const <TrafficHazardNode>[]);
  }

  /// Khớp tốc độ giới hạn của đoạn đường OSM gần vị trí [pos] nhất.
  static ({int speedLimitKmh, String? roadName, bool hasExplicitMaxspeed})? matchSpeedLimitAt(
    LatLng pos,
    List<SpeedRoadSegment> segments, {
    double maxDistanceMeters = 45.0,
  }) {
    if (segments.isEmpty) return null;

    double bestScore = double.infinity;
    SpeedRoadSegment? bestSeg;

    for (final seg in segments) {
      final pts = seg.points;
      if (pts.length < 2) continue;
      double segMinDist = double.infinity;
      for (int i = 0; i < pts.length - 1; i++) {
        final d = _pointToSegmentMeters(pos, pts[i], pts[i + 1]);
        if (d < segMinDist) segMinDist = d;
      }
      if (segMinDist > maxDistanceMeters) continue;
      // Ưu tiên nhẹ đoạn đường có gắn thẻ `maxspeed` rõ ràng khi chênh khoảng cách < 8m
      final double score = segMinDist - (seg.hasExplicitMaxspeed ? 6.0 : 0.0);
      if (score < bestScore) {
        bestScore = score;
        bestSeg = seg;
      }
    }

    if (bestSeg == null) return null;
    return (
      speedLimitKmh: bestSeg.speedLimitKmh,
      roadName: bestSeg.roadName,
      hasExplicitMaxspeed: bestSeg.hasExplicitMaxspeed,
    );
  }

  static double _pointToSegmentMeters(LatLng p, LatLng a, LatLng b) {
    final cosLat = math.cos(p.latitude * (math.pi / 180.0));
    final dx = (b.longitude - a.longitude) * cosLat * 111320.0;
    final dy = (b.latitude - a.latitude) * 110540.0;
    final px = (p.longitude - a.longitude) * cosLat * 111320.0;
    final py = (p.latitude - a.latitude) * 110540.0;
    final lenSq = dx * dx + dy * dy;
    final t = lenSq > 0.01 ? ((px * dx + py * dy) / lenSq).clamp(0.0, 1.0) : 0.0;
    final ex = px - t * dx;
    final ey = py - t * dy;
    return math.sqrt(ex * ex + ey * ey);
  }

  /// 3. Tìm tiện ích quanh vị trí hiện tại qua Overpass API (`fuel`, `charging_station`, `parking`)
  /// để bổ trợ / dự phòng cho Goong Place Search với đầy đủ tọa độ chính xác.
  Future<List<MapPlace>> searchNearbyAmenities(
    LatLng center, {
    required String amenityTag, // 'fuel' | 'charging_station' | 'parking'
    required String defaultName,
    int radiusMeters = 5000,
    int limit = 15,
  }) async {
    final query = '''
[out:json][timeout:10];
(
  node["amenity"="$amenityTag"](around:$radiusMeters,${center.latitude.toStringAsFixed(5)},${center.longitude.toStringAsFixed(5)});
  way["amenity"="$amenityTag"](around:$radiusMeters,${center.latitude.toStringAsFixed(5)},${center.longitude.toStringAsFixed(5)});
);
out center $limit;
''';
    for (final endpoint in const [_primaryOverpassUrl, _fallbackOverpassUrl]) {
      try {
        final res = await http
            .post(
              Uri.parse(endpoint),
              headers: {
                'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
                'User-Agent': 'HoaHuongDuongNav/2.0 (Flutter iOS)',
              },
              body: {'data': query},
            )
            .timeout(const Duration(seconds: 9));
        if (res.statusCode != 200 || res.bodyBytes.isEmpty) continue;
        final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
        final elements = data['elements'] as List? ?? [];
        const distCalc = Distance();
        final places = <MapPlace>[];

        for (final el in elements) {
          if (el is! Map<String, dynamic>) continue;
          final lat = (el['lat'] as num?)?.toDouble() ?? (el['center']?['lat'] as num?)?.toDouble();
          final lon = (el['lon'] as num?)?.toDouble() ?? (el['center']?['lon'] as num?)?.toDouble();
          if (lat == null || lon == null) continue;
          final tags = (el['tags'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
          final brand = (tags['brand'] ?? tags['operator'] ?? '').toString().trim();
          final rawName = (tags['name'] ?? '').toString().trim();
          final name = rawName.isNotEmpty
              ? rawName
              : (brand.isNotEmpty ? '$defaultName $brand' : defaultName);
          final street = (tags['addr:street'] ?? '').toString().trim();
          final district = (tags['addr:district'] ?? tags['addr:city'] ?? '').toString().trim();
          final addressParts = [if (street.isNotEmpty) street, if (district.isNotEmpty) district];
          final coord = LatLng(lat, lon);
          final distM = distCalc.as(LengthUnit.Meter, center, coord);

          places.add(MapPlace(
            name: name,
            displayName: addressParts.isNotEmpty ? '$name, ${addressParts.join(', ')}' : name,
            coordinate: coord,
            type: amenityTag,
            category: defaultName,
            distanceMeters: distM,
          ));
        }

        places.sort((a, b) => (a.distanceMeters ?? 999999).compareTo(b.distanceMeters ?? 999999));
        return places.take(limit).toList();
      } catch (e) {
        debugPrint('[OverpassTrafficService] searchNearbyAmenities($amenityTag) error: $e');
      }
    }
    return const [];
  }
}
