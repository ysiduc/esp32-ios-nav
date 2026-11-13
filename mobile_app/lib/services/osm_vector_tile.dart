import 'dart:math' as math;
import 'dart:typed_data';
import 'package:archive/archive.dart';

/// Parsed OpenStreetMap vector tile geometry in normalized [0..1] tile coordinates.
class OsmVectorTile {
  final int z;
  final int x;
  final int y;
  final List<OsmArea> areas;
  final List<OsmRoad> roads;
  final List<OsmBuilding> buildings;

  const OsmVectorTile({
    required this.z,
    required this.x,
    required this.y,
    required this.areas,
    required this.roads,
    required this.buildings,
  });

  /// Decodes raw or gzip/zlib-compressed Mapbox Vector Tile (.pbf) bytes.
  static OsmVectorTile? parsePbf(Uint8List rawBytes, int z, int x, int y) {
    if (rawBytes.isEmpty) return null;

    Uint8List bytes = rawBytes;
    if (bytes.length >= 2 && bytes[0] == 0x1F && bytes[1] == 0x8B) {
      bytes = Uint8List.fromList(const GZipDecoder().decodeBytes(bytes));
    } else if (bytes.length >= 2 && bytes[0] == 0x78) {
      try {
        bytes = Uint8List.fromList(const ZLibDecoder().decodeBytes(bytes));
      } catch (_) {}
    }

    final areas = <OsmArea>[];
    final roads = <OsmRoad>[];
    final buildings = <OsmBuilding>[];

    final reader = _ProtoReader(bytes);
    while (!reader.isAtEnd) {
      final tag = reader.readVarint();
      final field = tag >> 3;
      final wire = tag & 0x7;
      if (field == 3 && wire == 2) {
        final len = reader.readVarint();
        final end = (reader.pos + len).clamp(0, bytes.length);
        _parseLayer(bytes, reader.pos, end, areas, roads, buildings);
        reader.pos = end;
      } else {
        reader.skipField(wire);
      }
    }

    roads.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    areas.sort((a, b) => a.kind.compareTo(b.kind));

    return OsmVectorTile(
      z: z,
      x: x,
      y: y,
      areas: areas,
      roads: roads,
      buildings: buildings,
    );
  }

  static void _parseLayer(
    Uint8List buf,
    int start,
    int end,
    List<OsmArea> areas,
    List<OsmRoad> roads,
    List<OsmBuilding> buildings,
  ) {
    String layerName = '';
    int extent = 4096;
    final keys = <String>[];
    final values = <Object?>[];
    final featureStarts = <int>[];
    final featureEnds = <int>[];

    final r = _ProtoReader(buf, start, end);
    while (!r.isAtEnd) {
      final tag = r.readVarint();
      final field = tag >> 3;
      final wire = tag & 0x7;
      if (field == 1 && wire == 2) {
        layerName = r.readString();
      } else if (field == 2 && wire == 2) {
        final len = r.readVarint();
        final fStart = r.pos;
        final fEnd = (fStart + len).clamp(start, end);
        featureStarts.add(fStart);
        featureEnds.add(fEnd);
        r.pos = fEnd;
      } else if (field == 3 && wire == 2) {
        keys.add(r.readString());
      } else if (field == 4 && wire == 2) {
        final len = r.readVarint();
        final vEnd = (r.pos + len).clamp(start, end);
        values.add(_parseValue(buf, r.pos, vEnd));
        r.pos = vEnd;
      } else if (field == 5 && wire == 0) {
        final v = r.readVarint();
        if (v > 0) extent = v;
      } else {
        r.skipField(wire);
      }
    }

    final int layerKind;
    switch (layerName) {
      case 'building':
        layerKind = 1;
        break;
      case 'transportation':
        layerKind = 2;
        break;
      case 'water':
      case 'waterway':
        layerKind = 3;
        break;
      case 'park':
      case 'landcover':
      case 'landuse':
        layerKind = 4;
        break;
      default:
        return;
    }

    final invExt = 1.0 / extent;
    for (int i = 0; i < featureStarts.length; i++) {
      _parseFeature(
        buf,
        featureStarts[i],
        featureEnds[i],
        layerName,
        layerKind,
        keys,
        values,
        invExt,
        areas,
        roads,
        buildings,
      );
    }
  }

  static Object? _parseValue(Uint8List buf, int start, int end) {
    final r = _ProtoReader(buf, start, end);
    Object? result;
    while (!r.isAtEnd) {
      final tag = r.readVarint();
      final field = tag >> 3;
      final wire = tag & 0x7;
      switch (field) {
        case 1:
          result = wire == 2 ? r.readString() : null;
          break;
        case 2:
          if (wire == 5 && r.pos + 4 <= end) {
            final bd = ByteData.sublistView(buf, r.pos, r.pos + 4);
            result = bd.getFloat32(0, Endian.little);
            r.pos += 4;
          } else {
            r.skipField(wire);
          }
          break;
        case 3:
          if (wire == 1 && r.pos + 8 <= end) {
            final bd = ByteData.sublistView(buf, r.pos, r.pos + 8);
            result = bd.getFloat64(0, Endian.little);
            r.pos += 8;
          } else {
            r.skipField(wire);
          }
          break;
        case 4:
        case 5:
          result = wire == 0 ? r.readVarint() : null;
          break;
        case 6:
          result = wire == 0 ? _zigzag(r.readVarint()) : null;
          break;
        case 7:
          result = wire == 0 ? (r.readVarint() != 0) : null;
          break;
        default:
          r.skipField(wire);
      }
    }
    return result;
  }

  static void _parseFeature(
    Uint8List buf,
    int start,
    int end,
    String layerName,
    int layerKind,
    List<String> keys,
    List<Object?> values,
    double invExt,
    List<OsmArea> areas,
    List<OsmRoad> roads,
    List<OsmBuilding> buildings,
  ) {
    int geomType = 0;
    int tagsStart = -1;
    int tagsEnd = -1;
    int geomStart = -1;
    int geomEnd = -1;

    final r = _ProtoReader(buf, start, end);
    while (!r.isAtEnd) {
      final tag = r.readVarint();
      final field = tag >> 3;
      final wire = tag & 0x7;
      if (field == 2 && wire == 2) {
        final len = r.readVarint();
        tagsStart = r.pos;
        tagsEnd = (r.pos + len).clamp(start, end);
        r.pos = tagsEnd;
      } else if (field == 3 && wire == 0) {
        geomType = r.readVarint();
      } else if (field == 4 && wire == 2) {
        final len = r.readVarint();
        geomStart = r.pos;
        geomEnd = (r.pos + len).clamp(start, end);
        r.pos = geomEnd;
      } else {
        r.skipField(wire);
      }
    }

    if (geomStart < 0 || geomEnd <= geomStart) return;

    double renderHeight = 10.0;
    double renderMinHeight = 0.0;
    bool hide3d = false;
    String cls = '';
    String brunnel = '';

    if (tagsStart >= 0 && tagsEnd > tagsStart) {
      final tr = _ProtoReader(buf, tagsStart, tagsEnd);
      while (!tr.isAtEnd) {
        final kIdx = tr.readVarint();
        if (tr.isAtEnd) break;
        final vIdx = tr.readVarint();
        if (kIdx >= keys.length || vIdx >= values.length) continue;
        final k = keys[kIdx];
        final v = values[vIdx];
        if (k == 'render_height' && v is num) {
          renderHeight = v.toDouble();
        } else if (k == 'render_min_height' && v is num) {
          renderMinHeight = v.toDouble();
        } else if (k == 'hide_3d' && (v == true || v == 1)) {
          hide3d = true;
        } else if (k == 'class' && v is String) {
          cls = v;
        } else if (k == 'brunnel' && v is String) {
          brunnel = v;
        }
      }
    }

    if (layerKind == 1 && hide3d) return;

    final rings = _decodeGeometry(buf, geomStart, geomEnd, invExt);
    if (rings.isEmpty) return;

    if (layerKind == 1 && geomType == 3) {
      // Buildings: exterior rings in MVT v2 have positive signed area (CW in Y-down).
      final h = renderHeight.clamp(4.0, 200.0);
      final minH = renderMinHeight.clamp(0.0, h - 1.0);
      for (final pts in rings) {
        if (pts.length < 6) continue;
        if (_signedArea(pts) <= 1e-11) continue;
        double minX = pts[0], maxX = pts[0], minY = pts[1], maxY = pts[1];
        double sumX = 0, sumY = 0;
        final nPts = pts.length ~/ 2;
        for (int i = 0; i < pts.length; i += 2) {
          final px = pts[i];
          final py = pts[i + 1];
          if (px < minX) minX = px;
          if (px > maxX) maxX = px;
          if (py < minY) minY = py;
          if (py > maxY) maxY = py;
          sumX += px;
          sumY += py;
        }
        buildings.add(
          OsmBuilding(
            pts: pts,
            minX: minX,
            minY: minY,
            maxX: maxX,
            maxY: maxY,
            cx: sumX / nPts,
            cy: sumY / nPts,
            heightMeters: h,
            minHeightMeters: minH,
          ),
        );
      }
      return;
    }

    if (layerKind == 2 && geomType == 2) {
      if (brunnel == 'tunnel' || cls == 'rail' || cls == 'ferry' || cls == 'aerialway') {
        return;
      }
      final roadTier = _classifyRoadTier(cls);
      final isBridge = brunnel == 'bridge' || cls == 'bridge';
      for (final pts in rings) {
        if (pts.length < 4) continue;
        double minX = pts[0], maxX = pts[0], minY = pts[1], maxY = pts[1];
        for (int i = 2; i < pts.length; i += 2) {
          final px = pts[i];
          final py = pts[i + 1];
          if (px < minX) minX = px;
          if (px > maxX) maxX = px;
          if (py < minY) minY = py;
          if (py > maxY) maxY = py;
        }
        roads.add(
          OsmRoad(
            pts: pts,
            minX: minX,
            minY: minY,
            maxX: maxX,
            maxY: maxY,
            tier: roadTier,
            isBridge: isBridge,
          ),
        );
      }
      return;
    }

    if (layerKind == 3 && geomType == 2) {
      // Waterway lines (rivers/canals) treated as water channels
      for (final pts in rings) {
        if (pts.length < 4) continue;
        double minX = pts[0], maxX = pts[0], minY = pts[1], maxY = pts[1];
        for (int i = 2; i < pts.length; i += 2) {
          final px = pts[i];
          final py = pts[i + 1];
          if (px < minX) minX = px;
          if (px > maxX) maxX = px;
          if (py < minY) minY = py;
          if (py > maxY) maxY = py;
        }
        roads.add(
          OsmRoad(
            pts: pts,
            minX: minX,
            minY: minY,
            maxX: maxX,
            maxY: maxY,
            tier: -1, // waterway channel
            isBridge: false,
          ),
        );
      }
      return;
    }

    if ((layerKind == 3 || layerKind == 4) && geomType == 3) {
      final int areaKind;
      if (layerName == 'water') {
        areaKind = 2; // drawn on top of parks & landuse
      } else if (layerName == 'park' ||
          layerName == 'landcover' ||
          cls == 'grass' ||
          cls == 'wood' ||
          cls == 'forest' ||
          cls == 'park' ||
          cls == 'cemetery' ||
          cls == 'playground' ||
          cls == 'pitch') {
        areaKind = 1; // green spaces
      } else {
        areaKind = 0; // urban landuse tint
      }
      for (final pts in rings) {
        if (pts.length < 6) continue;
        if (_signedArea(pts) <= 1e-11) continue;
        double minX = pts[0], maxX = pts[0], minY = pts[1], maxY = pts[1];
        for (int i = 2; i < pts.length; i += 2) {
          final px = pts[i];
          final py = pts[i + 1];
          if (px < minX) minX = px;
          if (px > maxX) maxX = px;
          if (py < minY) minY = py;
          if (py > maxY) maxY = py;
        }
        areas.add(
          OsmArea(
            pts: pts,
            minX: minX,
            minY: minY,
            maxX: maxX,
            maxY: maxY,
            kind: areaKind,
          ),
        );
      }
    }
  }

  static int _classifyRoadTier(String cls) {
    switch (cls) {
      case 'motorway':
      case 'trunk':
        return 5;
      case 'primary':
        return 4;
      case 'secondary':
        return 3;
      case 'tertiary':
        return 2;
      case 'minor':
      case 'street':
      case 'unclassified':
      case 'residential':
      case 'raceway':
      case 'busway':
        return 1;
      default:
        return 0; // service, alley, path, track
    }
  }

  static List<Float32List> _decodeGeometry(Uint8List buf, int start, int end, double invExt) {
    final result = <Float32List>[];
    final current = <double>[];
    int cx = 0;
    int cy = 0;

    final r = _ProtoReader(buf, start, end);
    while (!r.isAtEnd) {
      final cmdLen = r.readVarint();
      final cmd = cmdLen & 0x7;
      final count = cmdLen >> 3;
      if (cmd == 1) {
        // MoveTo starts a new ring / linestring
        if (current.length >= 4) {
          result.add(Float32List.fromList(current));
        }
        current.clear();
        for (int i = 0; i < count && !r.isAtEnd; i++) {
          cx += _zigzag(r.readVarint());
          if (r.isAtEnd) break;
          cy += _zigzag(r.readVarint());
          current.add(cx * invExt);
          current.add(cy * invExt);
        }
      } else if (cmd == 2) {
        // LineTo appends vertices
        for (int i = 0; i < count && !r.isAtEnd; i++) {
          cx += _zigzag(r.readVarint());
          if (r.isAtEnd) break;
          cy += _zigzag(r.readVarint());
          current.add(cx * invExt);
          current.add(cy * invExt);
        }
      } else if (cmd == 7) {
        // ClosePath finishes current ring
        if (current.length >= 6) {
          result.add(Float32List.fromList(current));
        }
        current.clear();
      } else {
        break;
      }
    }
    if (current.length >= 4) {
      result.add(Float32List.fromList(current));
    }
    return result;
  }

  static double _signedArea(Float32List pts) {
    double sum = 0.0;
    final n = pts.length;
    for (int i = 0; i < n; i += 2) {
      final j = (i + 2) < n ? (i + 2) : 0;
      sum += pts[i] * pts[j + 1] - pts[j] * pts[i + 1];
    }
    return sum * 0.5;
  }

  static int _zigzag(int n) => (n >> 1) ^ -(n & 1);
}

class OsmArea {
  final Float32List pts;
  final double minX;
  final double minY;
  final double maxX;
  final double maxY;
  final int kind; // 0: urban landuse, 1: park/grass, 2: water

  const OsmArea({
    required this.pts,
    required this.minX,
    required this.minY,
    required this.maxX,
    required this.maxY,
    required this.kind,
  });
}

class OsmRoad {
  final Float32List pts;
  final double minX;
  final double minY;
  final double maxX;
  final double maxY;
  final int tier; // -1 waterway, 0 service/path, 1 minor, 2 tertiary, 3 secondary, 4 primary, 5 trunk/motorway
  final bool isBridge;

  const OsmRoad({
    required this.pts,
    required this.minX,
    required this.minY,
    required this.maxX,
    required this.maxY,
    required this.tier,
    required this.isBridge,
  });

  int get sortOrder => (isBridge ? 10 : 0) + tier;
}

class OsmBuilding {
  final Float32List pts;
  final double minX;
  final double minY;
  final double maxX;
  final double maxY;
  final double cx;
  final double cy;
  final double heightMeters;
  final double minHeightMeters;

  const OsmBuilding({
    required this.pts,
    required this.minX,
    required this.minY,
    required this.maxX,
    required this.maxY,
    required this.cx,
    required this.cy,
    required this.heightMeters,
    required this.minHeightMeters,
  });
}

class _ProjectedBuilding {
  OsmBuilding building;
  double sortY;
  double tileOriginX;
  double tileOriginY;
  double tileSizePx;
  double extrudePx;
  double baseOffPx;

  _ProjectedBuilding(
    this.building,
    this.sortY,
    this.tileOriginX,
    this.tileOriginY,
    this.tileSizePx,
    this.extrudePx,
    this.baseOffPx,
  );
}

/// Pure-CPU OpenStreetMap 3D Block & Vector Road Rasterizer.
class Osm3dRenderer {
  // Pre-allocated scratch buffers so 30 FPS rendering creates minimal GC pressure.
  Float64List _polyX = Float64List(256);
  Float64List _polyY = Float64List(256);
  final List<double> _xsScratch = <double>[];
  final Float64List _quadX = Float64List(4);
  final Float64List _quadY = Float64List(4);

  void _ensurePolyCapacity(int count) {
    if (_polyX.length < count) {
      final next = math.max(count, _polyX.length * 2);
      _polyX = Float64List(next);
      _polyY = Float64List(next);
    }
  }

  /// Renders a heading-up tilted OSM vector 3D block map into [buf32] (0xAABBGGRR format).
  void renderFrame({
    required Uint32List buf32,
    required int width,
    required int height,
    required Iterable<OsmVectorTile> tiles,
    required double userWorldX,
    required double userWorldY,
    required int displayZoom,
    required double headingDeg,
    required double anchorX,
    required double anchorY,
    required double pitchY,
    required bool isDark,
  }) {
    final _OsmPalette pal = isDark ? _OsmPalette.dark : _OsmPalette.light;
    buf32.fillRange(0, width * height, pal.ground);

    final double th = headingDeg * (math.pi / 180.0);
    final double cosH = math.cos(th);
    final double sinH = math.sin(th);
    final double zoomScale = math.pow(2.0, displayZoom - 17.0).toDouble();
    final double heightScale = (0.42 * zoomScale).clamp(0.18, 0.72);
    final double roadWidthScale = zoomScale.clamp(0.50, 1.35);

    // Compute world-space bounding box of viewport corners + bottom margin for tall roofs.
    final invPitch = 1.0 / pitchY;
    final cDx = [0.0, width.toDouble(), 0.0, width.toDouble()];
    final cDy = [-36.0, -36.0, height + 56.0, height + 56.0];
    double wMinX = double.infinity, wMaxX = -double.infinity;
    double wMinY = double.infinity, wMaxY = -double.infinity;
    for (int i = 0; i < 4; i++) {
      final rx = cDx[i] - anchorX;
      final ry = (cDy[i] - anchorY) * invPitch;
      final wx = rx * cosH - ry * sinH;
      final wy = rx * sinH + ry * cosH;
      if (wx < wMinX) wMinX = wx;
      if (wx > wMaxX) wMaxX = wx;
      if (wy < wMinY) wMinY = wy;
      if (wy > wMaxY) wMaxY = wy;
    }

    final tileInfos = <_TileView>[];
    for (final tile in tiles) {
      final double tileSizePx = 256.0 * math.pow(2.0, displayZoom - tile.z).toDouble();
      final double ox = tile.x * tileSizePx - userWorldX;
      final double oy = tile.y * tileSizePx - userWorldY;
      // Quick tile cull
      if (ox + tileSizePx < wMinX - 20 ||
          ox > wMaxX + 20 ||
          oy + tileSizePx < wMinY - 20 ||
          oy > wMaxY + 20) {
        continue;
      }
      tileInfos.add(_TileView(tile, ox, oy, tileSizePx));
    }

    if (tileInfos.isEmpty) {
      _drawFallbackGrid(buf32, width, height, pal);
      return;
    }

    // 1. Landuse -> Parks -> Water polygons (sorted by kind ascending across visible tiles)
    for (int targetKind = 0; targetKind <= 2; targetKind++) {
      final int areaColor = targetKind == 0
          ? pal.landuse
          : (targetKind == 1 ? pal.park : pal.water);
      for (final tv in tileInfos) {
        final areas = tv.tile.areas;
        final ox = tv.originX;
        final oy = tv.originY;
        final sz = tv.tileSizePx;
        for (int i = 0; i < areas.length; i++) {
          final a = areas[i];
          if (a.kind != targetKind) continue;
          if (ox + a.maxX * sz < wMinX ||
              ox + a.minX * sz > wMaxX ||
              oy + a.maxY * sz < wMinY ||
              oy + a.minY * sz > wMaxY) {
            continue;
          }
          _fillNormalizedPolygon(
            buf32,
            width,
            height,
            a.pts,
            ox,
            oy,
            sz,
            cosH,
            sinH,
            anchorX,
            anchorY,
            pitchY,
            0.0,
            areaColor,
          );
        }
      }
    }

    // 2. Waterway channels first, then Road hierarchy (casing then fill per tier so highways cross cleanly)
    for (final tv in tileInfos) {
      final roads = tv.tile.roads;
      final ox = tv.originX;
      final oy = tv.originY;
      final sz = tv.tileSizePx;
      for (int i = 0; i < roads.length; i++) {
        final r = roads[i];
        if (r.tier != -1) continue;
        if (ox + r.maxX * sz < wMinX - 16 ||
            ox + r.minX * sz > wMaxX + 16 ||
            oy + r.maxY * sz < wMinY - 16 ||
            oy + r.minY * sz > wMaxY + 16) {
          continue;
        }
        _strokeNormalizedPolyline(
          buf32,
          width,
          height,
          r.pts,
          ox,
          oy,
          sz,
          cosH,
          sinH,
          anchorX,
          anchorY,
          pitchY,
          (4.0 * roadWidthScale).clamp(2.5, 6.0),
          pal.water,
        );
      }
    }

    for (int tier = 0; tier <= 5; tier++) {
      final double baseR = _roadRadiusForTier(tier, roadWidthScale);
      final int casingColor = pal.roadCasingForTier(tier);
      final int fillColor = pal.roadFillForTier(tier);
      for (final tv in tileInfos) {
        final roads = tv.tile.roads;
        final ox = tv.originX;
        final oy = tv.originY;
        final sz = tv.tileSizePx;
        for (int i = 0; i < roads.length; i++) {
          final r = roads[i];
          if (r.tier != tier) continue;
          if (ox + r.maxX * sz < wMinX - 16 ||
              ox + r.minX * sz > wMaxX + 16 ||
              oy + r.maxY * sz < wMinY - 16 ||
              oy + r.minY * sz > wMaxY + 16) {
            continue;
          }
          if (baseR >= 1.5) {
            _strokeNormalizedPolyline(
              buf32,
              width,
              height,
              r.pts,
              ox,
              oy,
              sz,
              cosH,
              sinH,
              anchorX,
              anchorY,
              pitchY,
              baseR + 1.15,
              casingColor,
            );
          }
          _strokeNormalizedPolyline(
            buf32,
            width,
            height,
            r.pts,
            ox,
            oy,
            sz,
            cosH,
            sinH,
            anchorX,
            anchorY,
            pitchY,
            baseR,
            fillColor,
          );
        }
      }
    }

    // 3. Collect & Painter-Sort Visible 3D Buildings Back-to-Front
    final visibleBuildings = <_ProjectedBuilding>[];
    for (final tv in tileInfos) {
      final blds = tv.tile.buildings;
      final ox = tv.originX;
      final oy = tv.originY;
      final sz = tv.tileSizePx;
      for (int i = 0; i < blds.length; i++) {
        final b = blds[i];
        if (ox + b.maxX * sz < wMinX ||
            ox + b.minX * sz > wMaxX ||
            oy + b.maxY * sz < wMinY ||
            oy + b.minY * sz > wMaxY) {
          continue;
        }
        final wx = ox + b.cx * sz;
        final wy = oy + b.cy * sz;
        final rx = wx * cosH + wy * sinH;
        final ry = (-wx * sinH + wy * cosH) * pitchY;
        final sx = anchorX + rx;
        final sy = anchorY + ry;
        if (sx < -60 || sx > width + 60 || sy < -30 || sy > height + 65) {
          continue;
        }
        final extrudePx = (b.heightMeters * heightScale).clamp(3.0, 32.0);
        final baseOffPx = (b.minHeightMeters * heightScale).clamp(0.0, extrudePx - 1.5);
        visibleBuildings.add(
          _ProjectedBuilding(b, sy, ox, oy, sz, extrudePx, baseOffPx),
        );
      }
    }

    visibleBuildings.sort((a, b) => a.sortY.compareTo(b.sortY));

    // 4. Render 3D Extruded Walls (Directional Sunlit Shading) + Roof + Crisp Rim
    for (int i = 0; i < visibleBuildings.length; i++) {
      final pb = visibleBuildings[i];
      final b = pb.building;
      final pts = b.pts;
      final n = pts.length ~/ 2;
      _ensurePolyCapacity(n);

      final ox = pb.tileOriginX;
      final oy = pb.tileOriginY;
      final sz = pb.tileSizePx;
      final ext = pb.extrudePx;
      final baseOff = pb.baseOffPx;

      double sMinX = double.infinity, sMaxX = -double.infinity;
      double sMinY = double.infinity, sMaxY = -double.infinity;
      for (int v = 0; v < n; v++) {
        final wx = ox + pts[v * 2] * sz;
        final wy = oy + pts[v * 2 + 1] * sz;
        final sx = anchorX + (wx * cosH + wy * sinH);
        final sy = anchorY + ((-wx * sinH + wy * cosH) * pitchY) - baseOff;
        _polyX[v] = sx;
        _polyY[v] = sy;
        if (sx < sMinX) sMinX = sx;
        if (sx > sMaxX) sMaxX = sx;
        if (sy < sMinY) sMinY = sy;
        if (sy > sMaxY) sMaxY = sy;
      }

      if (sMaxX < 0 || sMinX >= width || sMaxY < 0 || (sMinY - ext) >= height) {
        continue;
      }

      // Tiny sub-pixel footprints skip expensive wall shading
      final bool isTall = b.heightMeters >= 24.0;
      final int roofColor = isTall ? pal.roofTall : pal.roofStandard;
      final int roofOutline = isTall ? pal.outlineTall : pal.outlineStandard;

      // Front-facing side wall quads (clockwise polygon -> outward normal ny = x0 - x1 > 0)
      for (int v = 0; v < n; v++) {
        final next = (v + 1) < n ? (v + 1) : 0;
        final x0 = _polyX[v];
        final y0 = _polyY[v];
        final x1 = _polyX[next];
        final y1 = _polyY[next];
        final dx = x1 - x0;
        if (dx >= -0.05) continue; // back-facing wall hidden behind roof

        final dy = y1 - y0;
        final len = math.sqrt(dx * dx + dy * dy);
        if (len < 0.4) continue;
        // Outward normal (nx, ny) = (dy/len, -dx/len), camera/sun from bottom-left (-0.75, +0.66)
        final nx = dy / len;
        final ny = -dx / len;
        final shade = (nx * -0.75 + ny * 0.66); // [-1 .. +1]
        final wallColor = shade > 0.20
            ? (isTall ? pal.wallSunTall : pal.wallSunStd)
            : (shade < -0.20
                ? (isTall ? pal.wallShadowTall : pal.wallShadowStd)
                : (isTall ? pal.wallMidTall : pal.wallMidStd));

        _quadX[0] = x0;
        _quadY[0] = y0 - ext;
        _quadX[1] = x1;
        _quadY[1] = y1 - ext;
        _quadX[2] = x1;
        _quadY[2] = y1;
        _quadX[3] = x0;
        _quadY[3] = y0;
        _scanlineFill(buf32, width, height, _quadX, _quadY, 4, wallColor);
      }

      // Shift polygon up in-place to draw elevated roof
      for (int v = 0; v < n; v++) {
        _polyY[v] -= ext;
      }
      _scanlineFill(buf32, width, height, _polyX, _polyY, n, roofColor);

      // Crisp roof edge outline
      if ((sMaxX - sMinX) > 2.5 || (sMaxY - sMinY) > 2.5) {
        for (int v = 0; v < n; v++) {
          final next = (v + 1) < n ? (v + 1) : 0;
          _drawLineAa(
            buf32,
            width,
            height,
            _polyX[v],
            _polyY[v],
            _polyX[next],
            _polyY[next],
            roofOutline,
          );
        }
      }
    }
  }

  static double _roadRadiusForTier(int tier, double scale) {
    switch (tier) {
      case 5:
        return (3.8 * scale).clamp(2.2, 5.5);
      case 4:
        return (3.2 * scale).clamp(1.9, 4.8);
      case 3:
        return (2.6 * scale).clamp(1.6, 4.0);
      case 2:
        return (2.1 * scale).clamp(1.3, 3.2);
      case 1:
        return (1.6 * scale).clamp(1.1, 2.5);
      default:
        return (1.0 * scale).clamp(0.8, 1.6);
    }
  }

  void _fillNormalizedPolygon(
    Uint32List buf32,
    int width,
    int height,
    Float32List pts,
    double ox,
    double oy,
    double sz,
    double cosH,
    double sinH,
    double anchorX,
    double anchorY,
    double pitchY,
    double extrudeY,
    int color,
  ) {
    final n = pts.length ~/ 2;
    if (n < 3) return;
    _ensurePolyCapacity(n);
    double sMinX = double.infinity, sMaxX = -double.infinity;
    double sMinY = double.infinity, sMaxY = -double.infinity;
    for (int v = 0; v < n; v++) {
      final wx = ox + pts[v * 2] * sz;
      final wy = oy + pts[v * 2 + 1] * sz;
      final sx = anchorX + (wx * cosH + wy * sinH);
      final sy = anchorY + ((-wx * sinH + wy * cosH) * pitchY) - extrudeY;
      _polyX[v] = sx;
      _polyY[v] = sy;
      if (sx < sMinX) sMinX = sx;
      if (sx > sMaxX) sMaxX = sx;
      if (sy < sMinY) sMinY = sy;
      if (sy > sMaxY) sMaxY = sy;
    }
    if (sMaxX < 0 || sMinX >= width || sMaxY < 0 || sMinY >= height) return;
    _scanlineFill(buf32, width, height, _polyX, _polyY, n, color);
  }

  void _strokeNormalizedPolyline(
    Uint32List buf32,
    int width,
    int height,
    Float32List pts,
    double ox,
    double oy,
    double sz,
    double cosH,
    double sinH,
    double anchorX,
    double anchorY,
    double pitchY,
    double radius,
    int color,
  ) {
    final n = pts.length ~/ 2;
    if (n < 2) return;
    double prevX = 0, prevY = 0;
    for (int v = 0; v < n; v++) {
      final wx = ox + pts[v * 2] * sz;
      final wy = oy + pts[v * 2 + 1] * sz;
      final sx = anchorX + (wx * cosH + wy * sinH);
      final sy = anchorY + ((-wx * sinH + wy * cosH) * pitchY);
      if (v > 0) {
        _drawCapsule(buf32, width, height, prevX, prevY, sx, sy, radius, color);
      }
      prevX = sx;
      prevY = sy;
    }
  }

  void _scanlineFill(
    Uint32List buf32,
    int width,
    int height,
    Float64List px,
    Float64List py,
    int n,
    int color,
  ) {
    double minY = py[0], maxY = py[0];
    for (int i = 1; i < n; i++) {
      final y = py[i];
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
    final int yStart = math.max(0, minY.floor());
    final int yEnd = math.min(height - 1, maxY.ceil());
    if (yStart > yEnd) return;

    final xs = _xsScratch;
    for (int y = yStart; y <= yEnd; y++) {
      final double sy = y + 0.5;
      xs.clear();
      for (int i = 0; i < n; i++) {
        final int j = (i + 1) < n ? (i + 1) : 0;
        final double y0 = py[i];
        final double y1 = py[j];
        if ((y0 <= sy && y1 > sy) || (y1 <= sy && y0 > sy)) {
          final double t = (sy - y0) / (y1 - y0);
          xs.add(px[i] + t * (px[j] - px[i]));
        }
      }
      final int len = xs.length;
      if (len < 2) continue;
      if (len == 2) {
        if (xs[0] > xs[1]) {
          final tmp = xs[0];
          xs[0] = xs[1];
          xs[1] = tmp;
        }
      } else {
        for (int a = 1; a < len; a++) {
          final key = xs[a];
          int b = a - 1;
          while (b >= 0 && xs[b] > key) {
            xs[b + 1] = xs[b];
            b--;
          }
          xs[b + 1] = key;
        }
      }
      final int rowOff = y * width;
      for (int k = 0; k + 1 < len; k += 2) {
        final int x0 = math.max(0, xs[k].ceil());
        final int x1 = math.min(width - 1, xs[k + 1].floor());
        if (x0 <= x1) {
          buf32.fillRange(rowOff + x0, rowOff + x1 + 1, color);
        }
      }
    }
  }

  void _drawCapsule(
    Uint32List buf32,
    int width,
    int height,
    double x0,
    double y0,
    double x1,
    double y1,
    double r,
    int color,
  ) {
    final int minX = math.max(0, (math.min(x0, x1) - r - 1).floor());
    final int maxX = math.min(width - 1, (math.max(x0, x1) + r + 1).ceil());
    final int minY = math.max(0, (math.min(y0, y1) - r - 1).floor());
    final int maxY = math.min(height - 1, (math.max(y0, y1) + r + 1).ceil());
    if (minX > maxX || minY > maxY) return;

    final double vx = x1 - x0;
    final double vy = y1 - y0;
    final double lenSq = vx * vx + vy * vy;
    final double rSq = r * r;

    for (int py = minY; py <= maxY; py++) {
      final double wy = py + 0.5 - y0;
      final int rowOff = py * width;
      for (int px = minX; px <= maxX; px++) {
        final double wx = px + 0.5 - x0;
        double t = lenSq > 1e-6 ? (wx * vx + wy * vy) / lenSq : 0.0;
        if (t < 0.0) {
          t = 0.0;
        } else if (t > 1.0) {
          t = 1.0;
        }
        final double dx = wx - t * vx;
        final double dy = wy - t * vy;
        if (dx * dx + dy * dy <= rSq) {
          buf32[rowOff + px] = color;
        }
      }
    }
  }

  void _drawLineAa(
    Uint32List buf32,
    int width,
    int height,
    double x0,
    double y0,
    double x1,
    double y1,
    int color,
  ) {
    final int dx = (x1 - x0).abs().ceil();
    final int dy = (y1 - y0).abs().ceil();
    final int steps = math.max(dx, dy);
    if (steps == 0) return;
    if (steps > 600) return;
    final double sx = (x1 - x0) / steps;
    final double sy = (y1 - y0) / steps;
    double cx = x0;
    double cy = y0;
    for (int i = 0; i <= steps; i++) {
      final int ix = cx.round();
      final int iy = cy.round();
      if (ix >= 0 && ix < width && iy >= 0 && iy < height) {
        buf32[iy * width + ix] = color;
      }
      cx += sx;
      cy += sy;
    }
  }

  void _drawFallbackGrid(Uint32List buf32, int width, int height, _OsmPalette pal) {
    for (int y = 0; y < height; y++) {
      if (y % 32 == 0) {
        buf32.fillRange(y * width, (y + 1) * width, pal.gridLine);
      } else {
        final row = y * width;
        for (int x = 0; x < width; x += 32) {
          buf32[row + x] = pal.gridLine;
        }
      }
    }
  }
}

class _TileView {
  final OsmVectorTile tile;
  final double originX;
  final double originY;
  final double tileSizePx;
  const _TileView(this.tile, this.originX, this.originY, this.tileSizePx);
}

class _OsmPalette {
  final int ground;
  final int landuse;
  final int park;
  final int water;
  final int gridLine;
  final int roadCasingMinor;
  final int roadCasingMajor;
  final int roadService;
  final int roadMinor;
  final int roadTertiary;
  final int roadSecondary;
  final int roadPrimary;
  final int roadTrunk;
  final int roofStandard;
  final int roofTall;
  final int outlineStandard;
  final int outlineTall;
  final int wallSunStd;
  final int wallMidStd;
  final int wallShadowStd;
  final int wallSunTall;
  final int wallMidTall;
  final int wallShadowTall;

  const _OsmPalette({
    required this.ground,
    required this.landuse,
    required this.park,
    required this.water,
    required this.gridLine,
    required this.roadCasingMinor,
    required this.roadCasingMajor,
    required this.roadService,
    required this.roadMinor,
    required this.roadTertiary,
    required this.roadSecondary,
    required this.roadPrimary,
    required this.roadTrunk,
    required this.roofStandard,
    required this.roofTall,
    required this.outlineStandard,
    required this.outlineTall,
    required this.wallSunStd,
    required this.wallMidStd,
    required this.wallShadowStd,
    required this.wallSunTall,
    required this.wallMidTall,
    required this.wallShadowTall,
  });

  static int _c(int r, int g, int b) =>
      0xFF000000 | ((b & 0xFF) << 16) | ((g & 0xFF) << 8) | (r & 0xFF);

  int roadCasingForTier(int tier) => tier >= 3 ? roadCasingMajor : roadCasingMinor;

  int roadFillForTier(int tier) {
    switch (tier) {
      case 5:
        return roadTrunk;
      case 4:
        return roadPrimary;
      case 3:
        return roadSecondary;
      case 2:
        return roadTertiary;
      case 1:
        return roadMinor;
      default:
        return roadService;
    }
  }

  // Crisp OSM Carto-inspired Daylight 3D Blocks
  static final _OsmPalette light = _OsmPalette(
    ground: _c(241, 239, 233),        // #F1EFE9 warm OSM canvas
    landuse: _c(231, 228, 220),       // #E7E4DC urban block base
    park: _c(199, 231, 173),          // #C7E7AD OSM park green
    water: _c(150, 206, 236),         // #96CEEC OSM lake/river blue
    gridLine: _c(216, 222, 220),
    roadCasingMinor: _c(196, 192, 184),
    roadCasingMajor: _c(214, 152, 66),
    roadService: _c(247, 246, 243),
    roadMinor: _c(255, 255, 255),
    roadTertiary: _c(255, 255, 255),
    roadSecondary: _c(252, 243, 184), // classic OSM pale yellow
    roadPrimary: _c(252, 214, 146),   // classic OSM amber
    roadTrunk: _c(248, 178, 108),     // classic OSM orange trunk
    roofStandard: _c(235, 227, 217),  // warm stone 3D block roof
    roofTall: _c(209, 221, 235),      // cool glass tower roof
    outlineStandard: _c(173, 162, 150),
    outlineTall: _c(128, 146, 168),
    wallSunStd: _c(214, 204, 192),
    wallMidStd: _c(191, 180, 167),
    wallShadowStd: _c(166, 154, 142),
    wallSunTall: _c(180, 196, 216),
    wallMidTall: _c(150, 169, 192),
    wallShadowTall: _c(122, 141, 166),
  );

  // High-Contrast Night OSM 3D Blocks
  static final _OsmPalette dark = _OsmPalette(
    ground: _c(13, 21, 34),           // #0D1522 midnight slate
    landuse: _c(19, 29, 46),          // #131D2E dark block
    park: _c(19, 49, 36),             // #133124 night green
    water: _c(13, 41, 68),            // #0D2944 night water
    gridLine: _c(28, 42, 62),
    roadCasingMinor: _c(10, 16, 26),
    roadCasingMajor: _c(16, 26, 42),
    roadService: _c(26, 38, 56),
    roadMinor: _c(37, 52, 74),
    roadTertiary: _c(48, 68, 96),
    roadSecondary: _c(64, 92, 128),
    roadPrimary: _c(92, 118, 148),
    roadTrunk: _c(126, 142, 164),
    roofStandard: _c(36, 51, 74),     // slate-blue block roof
    roofTall: _c(46, 68, 98),         // luminous skyscraper roof
    outlineStandard: _c(64, 90, 124),
    outlineTall: _c(92, 134, 178),
    wallSunStd: _c(31, 45, 66),
    wallMidStd: _c(23, 34, 51),
    wallShadowStd: _c(16, 25, 38),
    wallSunTall: _c(39, 59, 86),
    wallMidTall: _c(29, 45, 68),
    wallShadowTall: _c(20, 32, 49),
  );
}

class _ProtoReader {
  final Uint8List buf;
  int pos;
  final int end;

  _ProtoReader(this.buf, [this.pos = 0, int? end]) : end = end ?? buf.length;

  bool get isAtEnd => pos >= end;

  int readVarint() {
    int result = 0;
    int shift = 0;
    while (pos < end) {
      final b = buf[pos++];
      result |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) return result;
      shift += 7;
      if (shift > 63) break;
    }
    return result;
  }

  String readString() {
    final len = readVarint();
    final sEnd = (pos + len).clamp(pos, end);
    final str = String.fromCharCodes(buf, pos, sEnd);
    pos = sEnd;
    return str;
  }

  void skipField(int wireType) {
    switch (wireType) {
      case 0:
        readVarint();
        break;
      case 1:
        pos = math.min(end, pos + 8);
        break;
      case 2:
        final len = readVarint();
        pos = math.min(end, pos + len);
        break;
      case 5:
        pos = math.min(end, pos + 4);
        break;
      default:
        pos = end;
    }
  }
}
