import 'dart:convert';
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
  final List<OsmRoadLabel> roadLabels;
  final bool isSupplemental;

  const OsmVectorTile({
    required this.z,
    required this.x,
    required this.y,
    required this.areas,
    required this.roads,
    required this.buildings,
    this.roadLabels = const <OsmRoadLabel>[],
    this.isSupplemental = false,
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
    final roadLabels = <OsmRoadLabel>[];

    final reader = _ProtoReader(bytes);
    while (!reader.isAtEnd) {
      final tag = reader.readVarint();
      final field = tag >> 3;
      final wire = tag & 0x7;
      if (field == 3 && wire == 2) {
        final len = reader.readVarint();
        final end = (reader.pos + len).clamp(0, bytes.length);
        _parseLayer(bytes, reader.pos, end, areas, roads, buildings, roadLabels);
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
      roadLabels: roadLabels,
    );
  }

  /// Extracts clean CW vector 3D building footprints from a pre-styled RGBA
  /// building mask (bright magenta fill separated by dark outline borders).
  static OsmVectorTile extractBuildingsFromMask(
    Uint8List rgba,
    int width,
    int height,
    int z,
    int x,
    int y,
  ) {
    final buildings = <OsmBuilding>[];
    final int total = width * height;
    if (rgba.length < total * 4 || width < 4 || height < 4) {
      return OsmVectorTile(
        z: z,
        x: x,
        y: y,
        areas: const <OsmArea>[],
        roads: const <OsmRoad>[],
        buildings: buildings,
        isSupplemental: true,
      );
    }

    final isBld = Uint8List(total);
    for (int i = 0; i < total; i++) {
      final int off = i * 4;
      final int r = rgba[off];
      final int g = rgba[off + 1];
      final int b = rgba[off + 2];
      // Strictly match magenta interior (#E45CA8) while rejecting #000000 AA borders & background.
      if (r >= 175 && b >= 115 && (r - g) >= 70 && (b - g) >= 30) {
        isBld[i] = 1;
      }
    }

    final compId = Int32List(total);
    final queue = Int32List(total);
    int nextCid = 1;

    // Clockwise 8-neighbor offsets (N, NE, E, SE, S, SW, W, NW) for Moore-Neighbor contour trace.
    const List<int> dx8 = [0, 1, 1, 1, 0, -1, -1, -1];
    const List<int> dy8 = [-1, -1, 0, 1, 1, 1, 0, -1];

    final contourX = <int>[];
    final contourY = <int>[];
    final simplifiedX = <double>[];
    final simplifiedY = <double>[];

    for (int sy = 0; sy < height; sy++) {
      final int rowBase = sy * width;
      for (int sx = 0; sx < width; sx++) {
        final int seed = rowBase + sx;
        if (isBld[seed] != 1 || compId[seed] != 0) continue;

        final int cid = nextCid++;
        compId[seed] = cid;
        int qHead = 0;
        int qTail = 0;
        queue[qTail++] = seed;

        int minPx = sx, maxPx = sx, minPy = sy, maxPy = sy;
        while (qHead < qTail) {
          final int cur = queue[qHead++];
          final int cx = cur % width;
          final int cy = cur ~/ width;
          if (cx < minPx) minPx = cx;
          if (cx > maxPx) maxPx = cx;
          if (cy < minPy) minPy = cy;
          if (cy > maxPy) maxPy = cy;

          if (cx + 1 < width) {
            final int ni = cur + 1;
            if (isBld[ni] == 1 && compId[ni] == 0) {
              compId[ni] = cid;
              queue[qTail++] = ni;
            }
          }
          if (cx - 1 >= 0) {
            final int ni = cur - 1;
            if (isBld[ni] == 1 && compId[ni] == 0) {
              compId[ni] = cid;
              queue[qTail++] = ni;
            }
          }
          if (cy + 1 < height) {
            final int ni = cur + width;
            if (isBld[ni] == 1 && compId[ni] == 0) {
              compId[ni] = cid;
              queue[qTail++] = ni;
            }
          }
          if (cy - 1 >= 0) {
            final int ni = cur - width;
            if (isBld[ni] == 1 && compId[ni] == 0) {
              compId[ni] = cid;
              queue[qTail++] = ni;
            }
          }
        }

        final int pixCount = qTail;
        if (pixCount < 20 || (maxPx - minPx) < 3 || (maxPy - minPy) < 3) {
          continue;
        }

        // Row-major scan guarantees (sx, sy) is the topmost-leftmost pixel with N (0) outside.
        contourX.clear();
        contourY.clear();
        int curX = sx;
        int curY = sy;
        int enterIdx = 0;
        int secondX = -1;
        int secondY = -1;

        for (int step = 0; step < 4096; step++) {
          int foundIdx = -1;
          int nextX = 0;
          int nextY = 0;
          for (int k = 1; k <= 8; k++) {
            final int cand = (enterIdx + k) & 7;
            final int nx = curX + dx8[cand];
            final int ny = curY + dy8[cand];
            if (nx >= 0 && nx < width && ny >= 0 && ny < height && compId[ny * width + nx] == cid) {
              foundIdx = cand;
              nextX = nx;
              nextY = ny;
              break;
            }
          }
          if (foundIdx < 0) break;

          if (contourX.isNotEmpty &&
              curX == sx &&
              curY == sy &&
              nextX == secondX &&
              nextY == secondY) {
            break;
          }
          contourX.add(curX);
          contourY.add(curY);
          if (secondX < 0) {
            secondX = nextX;
            secondY = nextY;
          }
          curX = nextX;
          curY = nextY;
          enterIdx = ((foundIdx >> 1) * 2 + 6) & 7;
        }

        if (contourX.length < 4) continue;

        simplifiedX.clear();
        simplifiedY.clear();
        _simplifyClosedContour(contourX, contourY, 1.5, simplifiedX, simplifiedY);
        if (simplifiedX.length > 16) {
          simplifiedX.clear();
          simplifiedY.clear();
          _simplifyClosedContour(contourX, contourY, 2.3, simplifiedX, simplifiedY);
        }
        if (simplifiedX.length < 3) continue;

        final int nVerts = simplifiedX.length;
        final pts = Float32List(nVerts * 2);
        final double invW = 1.0 / width;
        final double invH = 1.0 / height;
        double minX = 1.0, maxX = 0.0, minY = 1.0, maxY = 0.0;
        double sumX = 0.0, sumY = 0.0;
        for (int v = 0; v < nVerts; v++) {
          final double nx = ((simplifiedX[v] + 0.5) * invW).clamp(0.0, 1.0);
          final double ny = ((simplifiedY[v] + 0.5) * invH).clamp(0.0, 1.0);
          pts[v * 2] = nx;
          pts[v * 2 + 1] = ny;
          if (nx < minX) minX = nx;
          if (nx > maxX) maxX = nx;
          if (ny < minY) minY = ny;
          if (ny > maxY) maxY = ny;
          sumX += nx;
          sumY += ny;
        }

        double area2 = _signedArea(pts);
        if (area2.abs() < 1e-7) continue;
        if (area2 < 0) {
          // Enforce clockwise winding in (x right, y down) tile space.
          for (int l = 0, r = nVerts - 1; l < r; l++, r--) {
            final double tx = pts[l * 2];
            final double ty = pts[l * 2 + 1];
            pts[l * 2] = pts[r * 2];
            pts[l * 2 + 1] = pts[r * 2 + 1];
            pts[r * 2] = tx;
            pts[r * 2 + 1] = ty;
          }
          area2 = -area2;
        }

        final int bHash = ((sx * 73856093) ^ (sy * 19349663) ^ pixCount).abs();
        final double hMeters;
        if (pixCount >= 950) {
          hMeters = 26.0 + (bHash % 5) * 3.5;
        } else if (pixCount >= 420) {
          hMeters = 19.0 + (bHash % 6) * 2.4;
        } else if (pixCount >= 160) {
          hMeters = 13.0 + (bHash % 5) * 1.8;
        } else {
          hMeters = 8.5 + (bHash % 4) * 1.5;
        }

        buildings.add(
          OsmBuilding(
            pts: pts,
            minX: minX,
            minY: minY,
            maxX: maxX,
            maxY: maxY,
            cx: sumX / nVerts,
            cy: sumY / nVerts,
            heightMeters: hMeters,
            minHeightMeters: 0.0,
          ),
        );
      }
    }

    return OsmVectorTile(
      z: z,
      x: x,
      y: y,
      areas: const <OsmArea>[],
      roads: const <OsmRoad>[],
      buildings: buildings,
      isSupplemental: true,
    );
  }

  static void _simplifyClosedContour(
    List<int> cx,
    List<int> cy,
    double eps,
    List<double> outX,
    List<double> outY,
  ) {
    final int n = cx.length;
    if (n <= 4) {
      for (int i = 0; i < n; i++) {
        outX.add(cx[i].toDouble());
        outY.add(cy[i].toDouble());
      }
      return;
    }

    // Remove consecutive collinear grid steps first.
    final vx = <double>[];
    final vy = <double>[];
    for (int i = 0; i < n; i++) {
      final int prev = (i - 1 + n) % n;
      final int next = (i + 1) % n;
      final int dx1 = cx[i] - cx[prev];
      final int dy1 = cy[i] - cy[prev];
      final int dx2 = cx[next] - cx[i];
      final int dy2 = cy[next] - cy[i];
      if (dx1 * dy2 != dy1 * dx2) {
        vx.add(cx[i].toDouble());
        vy.add(cy[i].toDouble());
      }
    }
    final int m = vx.length;
    if (m <= 4) {
      outX.addAll(vx);
      outY.addAll(vy);
      return;
    }

    int splitIdx = 1;
    double bestDistSq = -1.0;
    for (int i = 1; i < m; i++) {
      final double ddx = vx[i] - vx[0];
      final double ddy = vy[i] - vy[0];
      final double dSq = ddx * ddx + ddy * ddy;
      if (dSq > bestDistSq) {
        bestDistSq = dSq;
        splitIdx = i;
      }
    }

    final keepA = List<bool>.filled(splitIdx + 1, false);
    keepA[0] = true;
    keepA[splitIdx] = true;
    _dpRecurse(vx, vy, 0, splitIdx, eps * eps, keepA);

    final chainBx = <double>[];
    final chainBy = <double>[];
    for (int i = splitIdx; i < m; i++) {
      chainBx.add(vx[i]);
      chainBy.add(vy[i]);
    }
    chainBx.add(vx[0]);
    chainBy.add(vy[0]);
    final keepB = List<bool>.filled(chainBx.length, false);
    keepB[0] = true;
    keepB[chainBx.length - 1] = true;
    _dpRecurse(chainBx, chainBy, 0, chainBx.length - 1, eps * eps, keepB);

    for (int i = 0; i <= splitIdx; i++) {
      if (keepA[i]) {
        outX.add(vx[i]);
        outY.add(vy[i]);
      }
    }
    for (int i = 1; i < chainBx.length - 1; i++) {
      if (keepB[i]) {
        outX.add(chainBx[i]);
        outY.add(chainBy[i]);
      }
    }
  }

  static void _dpRecurse(
    List<double> px,
    List<double> py,
    int s,
    int e,
    double epsSq,
    List<bool> keep,
  ) {
    if (e - s <= 1) return;
    final double ax = px[s];
    final double ay = py[s];
    final double abx = px[e] - ax;
    final double aby = py[e] - ay;
    final double abLenSq = abx * abx + aby * aby;

    double maxDistSq = 0.0;
    int maxIdx = s;
    for (int i = s + 1; i < e; i++) {
      final double apx = px[i] - ax;
      final double apy = py[i] - ay;
      final double dSq;
      if (abLenSq <= 1e-9) {
        dSq = apx * apx + apy * apy;
      } else {
        final double cross = apx * aby - apy * abx;
        dSq = (cross * cross) / abLenSq;
      }
      if (dSq > maxDistSq) {
        maxDistSq = dSq;
        maxIdx = i;
      }
    }
    if (maxDistSq > epsSq) {
      keep[maxIdx] = true;
      _dpRecurse(px, py, s, maxIdx, epsSq, keep);
      _dpRecurse(px, py, maxIdx, e, epsSq, keep);
    }
  }

  /// Returns a copy excluding extracted buildings whose footprints already overlap
  /// mapped 3D buildings in [primaryTiles], avoiding duplicate overlapping towers.
  OsmVectorTile withoutOverlapsFrom(Iterable<OsmVectorTile> primaryTiles) {
    if (buildings.isEmpty) return this;
    final primaryList = primaryTiles.where((t) => t.buildings.isNotEmpty).toList();
    if (primaryList.isEmpty) return this;

    final filtered = <OsmBuilding>[];
    for (final b in buildings) {
      bool overlaps = false;
      for (final pTile in primaryList) {
        final double scale = math.pow(2.0, pTile.z - z).toDouble();
        final double bCx = (x + b.cx) * scale - pTile.x;
        final double bCy = (y + b.cy) * scale - pTile.y;
        final double bMinX = (x + b.minX) * scale - pTile.x;
        final double bMaxX = (x + b.maxX) * scale - pTile.x;
        final double bMinY = (y + b.minY) * scale - pTile.y;
        final double bMaxY = (y + b.maxY) * scale - pTile.y;
        if (bMaxX < -0.02 || bMinX > 1.02 || bMaxY < -0.02 || bMinY > 1.02) {
          continue;
        }
        const double tol = 0.0018;
        for (final ob in pTile.buildings) {
          final bool cxInside = bCx >= ob.minX - tol &&
              bCx <= ob.maxX + tol &&
              bCy >= ob.minY - tol &&
              bCy <= ob.maxY + tol;
          final bool ocxInside = ob.cx >= bMinX - tol &&
              ob.cx <= bMaxX + tol &&
              ob.cy >= bMinY - tol &&
              ob.cy <= bMaxY + tol;
          if (cxInside || ocxInside) {
            overlaps = true;
            break;
          }
        }
        if (overlaps) break;
      }
      if (!overlaps) filtered.add(b);
    }

    return OsmVectorTile(
      z: z,
      x: x,
      y: y,
      areas: areas,
      roads: roads,
      buildings: filtered,
      roadLabels: roadLabels,
      isSupplemental: isSupplemental,
    );
  }

  static void _parseLayer(
    Uint8List buf,
    int start,
    int end,
    List<OsmArea> areas,
    List<OsmRoad> roads,
    List<OsmBuilding> buildings,
    List<OsmRoadLabel> roadLabels,
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
      case 'transportation_name':
        layerKind = 5;
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
        roadLabels,
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
    List<OsmRoadLabel> roadLabels,
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
    String featName = '';
    String featNameVi = '';

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
        } else if (k == 'name:vi' && v is String && v.isNotEmpty) {
          featNameVi = v;
        } else if (k == 'name' && v is String && v.isNotEmpty) {
          featName = v;
        }
      }
    }

    if (layerKind == 1 && hide3d) return;
    final String resolvedName = featNameVi.isNotEmpty ? featNameVi : featName;
    if (layerKind == 5 && resolvedName.isEmpty) return;

    final rings = _decodeGeometry(buf, geomStart, geomEnd, invExt);
    if (rings.isEmpty) return;

    if (layerKind == 5) {
      if (geomType == 2) {
        // Pick the longest polyline arc and sample its geometric midpoint + tangent.
        Float32List? bestPts;
        double bestLen = 0.0;
        for (final pts in rings) {
          if (pts.length < 4) continue;
          double totalLen = 0.0;
          for (int i = 2; i < pts.length; i += 2) {
            final double ddx = pts[i] - pts[i - 2];
            final double ddy = pts[i + 1] - pts[i - 1];
            totalLen += math.sqrt(ddx * ddx + ddy * ddy);
          }
          if (totalLen > bestLen) {
            bestLen = totalLen;
            bestPts = pts;
          }
        }
        if (bestPts != null && bestLen > 0.025) {
          double target = bestLen * 0.5;
          for (int i = 2; i < bestPts.length; i += 2) {
            final double x0 = bestPts[i - 2];
            final double y0 = bestPts[i - 1];
            final double dx = bestPts[i] - x0;
            final double dy = bestPts[i + 1] - y0;
            final double segLen = math.sqrt(dx * dx + dy * dy);
            if (target <= segLen || i + 2 >= bestPts.length) {
              if (segLen > 1e-6) {
                final double t = (target / segLen).clamp(0.0, 1.0);
                roadLabels.add(
                  OsmRoadLabel(
                    name: resolvedName,
                    midX: x0 + dx * t,
                    midY: y0 + dy * t,
                    dirX: dx / segLen,
                    dirY: dy / segLen,
                    tier: _classifyRoadTier(cls),
                  ),
                );
              }
              break;
            }
            target -= segLen;
          }
        }
      }
      return;
    }

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

/// Road label anchor extracted from an OSM `transportation_name` polyline.
class OsmRoadLabel {
  final String name;
  final double midX;
  final double midY;
  final double dirX;
  final double dirY;
  final int tier;

  const OsmRoadLabel({
    required this.name,
    required this.midX,
    required this.midY,
    required this.dirX,
    required this.dirY,
    required this.tier,
  });
}

/// Screen-space road name placement returned by [Osm3dRenderer.collectVisibleRoadLabels].
class OsmScreenRoadLabel {
  final String text;
  final double sx;
  final double sy;
  final double angleDeg;
  final int tier;

  const OsmScreenRoadLabel({
    required this.text,
    required this.sx,
    required this.sy,
    required this.angleDeg,
    required this.tier,
  });
}

/// Heading-up 3D pinhole camera shared across map rasterizer, route projection, and labels.
class Osm3dCamera {
  final double width;
  final double height;
  final double anchorX;
  final double anchorY;
  final double headingDeg;
  final double cosH;
  final double sinH;
  final double tiltDeg;
  final double sinT;
  final double cosT;
  final double focal;
  final double nearCamZ;
  final bool perspective3d;
  final double pitchY;
  final double eyeRy;

  Osm3dCamera({
    required this.width,
    required this.height,
    required this.anchorX,
    required this.anchorY,
    required this.headingDeg,
    this.perspective3d = true,
    this.pitchY = 0.78,
    this.tiltDeg = 31.0,
    this.focal = 420.0,
    this.nearCamZ = 65.0,
  }) : cosH = math.cos(headingDeg * (math.pi / 180.0)),
       sinH = math.sin(headingDeg * (math.pi / 180.0)),
       sinT = math.sin(tiltDeg * (math.pi / 180.0)),
       cosT = math.cos(tiltDeg * (math.pi / 180.0)),
       eyeRy = math.cos(tiltDeg * (math.pi / 180.0)) * focal;

  @pragma('vm:prefer-inline')
  double worldToRight(double wx, double wy) => wx * cosH + wy * sinH;

  @pragma('vm:prefer-inline')
  double worldToBack(double wx, double wy) => -wx * sinH + wy * cosH;

  @pragma('vm:prefer-inline')
  double camZAt(double ry, [double elevPx = 0.0]) =>
      perspective3d ? (focal - ry * cosT - elevPx * sinT) : focal;

  @pragma('vm:prefer-inline')
  double scaleAtCamZ(double camZ) {
    if (!perspective3d) return 1.0;
    final double safe = camZ > nearCamZ ? camZ : nearCamZ;
    return focal / safe;
  }

  /// Projects camera-local `(rx right, ry back, elevPx up)` coordinates to screen space.
  @pragma('vm:prefer-inline')
  ({double sx, double sy, double scale, double camZ}) projectLocal(
    double rx,
    double ry, [
    double elevPx = 0.0,
  ]) {
    if (!perspective3d) {
      return (
        sx: anchorX + rx,
        sy: anchorY + ry * pitchY - elevPx,
        scale: 1.0,
        camZ: focal,
      );
    }
    final double rawCamZ = focal - ry * cosT - elevPx * sinT;
    final double safeCamZ = rawCamZ > nearCamZ ? rawCamZ : nearCamZ;
    final double s = focal / safeCamZ;
    return (
      sx: anchorX + rx * s,
      sy: anchorY + (ry * sinT - elevPx * cosT) * s,
      scale: s,
      camZ: rawCamZ,
    );
  }

  /// Projects North-up world `(wx, wy)` pixel offsets relative to the user to screen space.
  @pragma('vm:prefer-inline')
  ({double sx, double sy, double scale, double camZ}) projectWorld(
    double wx,
    double wy, [
    double elevPx = 0.0,
  ]) {
    return projectLocal(wx * cosH + wy * sinH, -wx * sinH + wy * cosH, elevPx);
  }

  /// Unprojects a screen `(sx, sy)` pixel back onto the `z = 0` ground plane in world offset coords.
  ({double wx, double wy}) screenToWorldOffset(double sx, double sy) {
    final double rx;
    final double ry;
    if (!perspective3d) {
      rx = sx - anchorX;
      ry = (sy - anchorY) / pitchY;
    } else {
      final double dy = (sy - anchorY) / focal;
      final double denom = math.max(0.08, sinT + dy * cosT);
      ry = (dy * focal) / denom;
      final double safeCamZ = math.max(nearCamZ, focal - ry * cosT);
      rx = (sx - anchorX) * (safeCamZ / focal);
    }
    return (
      wx: rx * cosH - ry * sinH,
      wy: rx * sinH + ry * cosH,
    );
  }
}

class _ProjectedBuilding {
  OsmBuilding building;
  double sortDepth;
  double tileOriginX;
  double tileOriginY;
  double tileSizePx;
  double extrudePx;
  double baseOffPx;

  _ProjectedBuilding(
    this.building,
    this.sortDepth,
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
  Float64List _footRx = Float64List(256);
  Float64List _footRy = Float64List(256);
  Float64List _roofX = Float64List(256);
  Float64List _roofY = Float64List(256);
  Float64List _clipRx = Float64List(512);
  Float64List _clipRy = Float64List(512);
  Float64List _clipCz = Float64List(512);
  final List<double> _xsScratch = <double>[];
  final Float64List _quadX = Float64List(4);
  final Float64List _quadY = Float64List(4);

  void _ensurePolyCapacity(int count) {
    if (_polyX.length < count) {
      final next = math.max(count, _polyX.length * 2);
      _polyX = Float64List(next);
      _polyY = Float64List(next);
      _footRx = Float64List(next);
      _footRy = Float64List(next);
      _roofX = Float64List(next);
      _roofY = Float64List(next);
    }
    if (_clipRx.length < count * 2) {
      final next = math.max(count * 2, _clipRx.length * 2);
      _clipRx = Float64List(next);
      _clipRy = Float64List(next);
      _clipCz = Float64List(next);
    }
  }

  /// Computes visible world-space tile transforms covering the projected 3D viewport.
  ({
    List<_TileView> tileInfos,
    double wMinX,
    double wMaxX,
    double wMinY,
    double wMaxY,
  }) _collectVisibleTileViews(
    Iterable<OsmVectorTile> tiles,
    double userWorldX,
    double userWorldY,
    int displayZoom,
    Osm3dCamera camera, {
    int skyHorizonPx = 0,
  }) {
    final double skyTop = (skyHorizonPx > 4 ? (skyHorizonPx - 4) : -12).toDouble();
    final cDx = [-24.0, camera.width + 24.0, -24.0, camera.width + 24.0];
    final cDy = [skyTop, skyTop, camera.height + 56.0, camera.height + 56.0];
    double wMinX = double.infinity, wMaxX = -double.infinity;
    double wMinY = double.infinity, wMaxY = -double.infinity;
    for (int i = 0; i < 4; i++) {
      final w = camera.screenToWorldOffset(cDx[i], cDy[i]);
      if (w.wx < wMinX) wMinX = w.wx;
      if (w.wx > wMaxX) wMaxX = w.wx;
      if (w.wy < wMinY) wMinY = w.wy;
      if (w.wy > wMaxY) wMaxY = w.wy;
    }

    final tileInfos = <_TileView>[];
    for (final tile in tiles) {
      final double tileSizePx =
          256.0 * math.pow(2.0, displayZoom - tile.z).toDouble();
      final double ox = tile.x * tileSizePx - userWorldX;
      final double oy = tile.y * tileSizePx - userWorldY;
      if (ox + tileSizePx < wMinX - 30 ||
          ox > wMaxX + 30 ||
          oy + tileSizePx < wMinY - 30 ||
          oy > wMaxY + 30) {
        continue;
      }
      tileInfos.add(_TileView(tile, ox, oy, tileSizePx));
    }

    return (
      tileInfos: tileInfos,
      wMinX: wMinX,
      wMaxX: wMaxX,
      wMinY: wMinY,
      wMaxY: wMaxY,
    );
  }

  /// Renders a heading-up 3D perspective vector block map into [buf32] (0xAABBGGRR format).
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
    bool perspective3d = true,
    double tiltDeg = 31.0,
    double focal = 420.0,
    int skyHorizonPx = 0,
  }) {
    final _OsmPalette pal = isDark ? _OsmPalette.dark : _OsmPalette.light;
    buf32.fillRange(0, width * height, pal.ground);

    final camera = Osm3dCamera(
      width: width.toDouble(),
      height: height.toDouble(),
      anchorX: anchorX,
      anchorY: anchorY,
      headingDeg: headingDeg,
      perspective3d: perspective3d,
      pitchY: pitchY,
      tiltDeg: tiltDeg,
      focal: focal,
    );

    final double zoomScale = math.pow(2.0, displayZoom - 17.0).toDouble();
    final double heightScale = (0.48 * zoomScale).clamp(0.20, 0.85);
    final double roadWidthScale = zoomScale.clamp(0.55, 1.45);

    final visible = _collectVisibleTileViews(
      tiles,
      userWorldX,
      userWorldY,
      displayZoom,
      camera,
      skyHorizonPx: skyHorizonPx,
    );
    final tileInfos = visible.tileInfos;
    final wMinX = visible.wMinX;
    final wMaxX = visible.wMaxX;
    final wMinY = visible.wMinY;
    final wMaxY = visible.wMaxY;

    if (tileInfos.isEmpty) {
      _drawFallbackGrid(buf32, width, height, pal);
      if (skyHorizonPx > 0) {
        _blendSkyHorizon(buf32, width, height, skyHorizonPx, pal);
      }
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
            camera,
            areaColor,
          );
        }
      }
    }

    // 2. Waterway channels first, then perspective-tapered road hierarchy
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
          camera,
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
          if (baseR >= 1.4) {
            _strokeNormalizedPolyline(
              buf32,
              width,
              height,
              r.pts,
              ox,
              oy,
              sz,
              camera,
              baseR + 1.05,
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
            camera,
            baseR,
            fillColor,
          );
        }
      }
    }

    // 3. Soft sky horizon fade before foreground translucent 3D towers
    if (skyHorizonPx > 0) {
      _blendSkyHorizon(buf32, width, height, skyHorizonPx, pal);
    }

    // 4. Collect & painter-sort visible 3D buildings back-to-front by decreasing camera depth
    final visibleBuildings = <_ProjectedBuilding>[];
    for (final tv in tileInfos) {
      final blds = tv.tile.buildings;
      final ox = tv.originX;
      final oy = tv.originY;
      final sz = tv.tileSizePx;
      for (int i = 0; i < blds.length; i++) {
        final b = blds[i];
        if (ox + b.maxX * sz < wMinX - 24 ||
            ox + b.minX * sz > wMaxX + 24 ||
            oy + b.maxY * sz < wMinY - 24 ||
            oy + b.minY * sz > wMaxY + 24) {
          continue;
        }
        final wx = ox + b.cx * sz;
        final wy = oy + b.cy * sz;
        final rx = camera.worldToRight(wx, wy);
        final ry = camera.worldToBack(wx, wy);
        final camZ = camera.camZAt(ry);
        if (perspective3d && camZ < camera.nearCamZ - 28.0) {
          continue;
        }
        final p = camera.projectLocal(rx, ry);
        if (p.sx < -95 || p.sx > width + 95 || p.sy < -30 || p.sy > height + 95) {
          continue;
        }
        final extrudePx = (b.heightMeters * heightScale).clamp(3.5, 48.0);
        final baseOffPx = (b.minHeightMeters * heightScale).clamp(0.0, extrudePx - 1.5);
        visibleBuildings.add(
          _ProjectedBuilding(
            b,
            perspective3d ? camZ : -p.sy,
            ox,
            oy,
            sz,
            extrudePx,
            baseOffPx,
          ),
        );
      }
    }

    // Back-to-front painter order: farthest camZ first, nearest foreground buildings last.
    visibleBuildings.sort((a, b) => b.sortDepth.compareTo(a.sortDepth));

    // 5. Render translucent 3D extruded walls (3D eye-facing cull) + roof + crisp rim outlines
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
      double maxVertexCamZ = -double.infinity;
      for (int v = 0; v < n; v++) {
        final wx = ox + pts[v * 2] * sz;
        final wy = oy + pts[v * 2 + 1] * sz;
        final rx = camera.worldToRight(wx, wy);
        final ry = camera.worldToBack(wx, wy);
        _footRx[v] = rx;
        _footRy[v] = ry;

        final baseP = camera.projectLocal(rx, ry, baseOff);
        final roofP = camera.projectLocal(rx, ry, ext);
        if (baseP.camZ > maxVertexCamZ) maxVertexCamZ = baseP.camZ;
        _polyX[v] = baseP.sx;
        _polyY[v] = baseP.sy;
        _roofX[v] = roofP.sx;
        _roofY[v] = roofP.sy;

        if (roofP.sx < sMinX) sMinX = roofP.sx;
        if (roofP.sx > sMaxX) sMaxX = roofP.sx;
        if (baseP.sx < sMinX) sMinX = baseP.sx;
        if (baseP.sx > sMaxX) sMaxX = baseP.sx;
        if (roofP.sy < sMinY) sMinY = roofP.sy;
        if (baseP.sy > sMaxY) sMaxY = baseP.sy;
      }

      if (perspective3d && maxVertexCamZ < camera.nearCamZ) {
        continue;
      }
      if (sMaxX < 0 || sMinX >= width || sMaxY < 0 || sMinY >= height) {
        continue;
      }

      final bool isTall = b.heightMeters >= 20.0;
      final int roofColor = isTall ? pal.roofTall : pal.roofStandard;
      final int roofOutline = isTall ? pal.outlineTall : pal.outlineStandard;

      // Check front-facing walls against 3D eye position so opaque & translucent buildings avoid self-overlap.
      for (int v = 0; v < n; v++) {
        final next = (v + 1) < n ? (v + 1) : 0;
        final double dRx = _footRx[next] - _footRx[v];
        final double dRy = _footRy[next] - _footRy[v];
        final double edgeLen = math.sqrt(dRx * dRx + dRy * dRy);
        if (edgeLen < 0.4) continue;

        final double midRx = (_footRx[v] + _footRx[next]) * 0.5;
        final double midRy = (_footRy[v] + _footRy[next]) * 0.5;
        final double nx = dRy;
        final double ny = -dRx;
        final double toEye = perspective3d
            ? ((-midRx) * nx + (camera.eyeRy - midRy) * ny)
            : ny;
        if (toEye <= 0.0) continue;

        final double shade = (nx * -0.58 + ny * 0.81) / edgeLen;
        final int wallColor = shade > 0.22
            ? (isTall ? pal.wallSunTall : pal.wallSunStd)
            : (shade < -0.22
                ? (isTall ? pal.wallShadowTall : pal.wallShadowStd)
                : (isTall ? pal.wallMidTall : pal.wallMidStd));

        _quadX[0] = _roofX[v];
        _quadY[0] = _roofY[v];
        _quadX[1] = _roofX[next];
        _quadY[1] = _roofY[next];
        _quadX[2] = _polyX[next];
        _quadY[2] = _polyY[next];
        _quadX[3] = _polyX[v];
        _quadY[3] = _polyY[v];
        _scanlineFill(buf32, width, height, _quadX, _quadY, 4, wallColor);

        // Crisp vertical wall edge on left silhouette/front corner
        if ((sMaxX - sMinX) > 4.0) {
          _drawLineAa(
            buf32,
            width,
            height,
            _polyX[v],
            _polyY[v],
            _roofX[v],
            _roofY[v],
            roofOutline,
          );
        }
      }

      // Translucent roof cap sits strictly above front walls (zero overlap)
      _scanlineFill(buf32, width, height, _roofX, _roofY, n, roofColor);

      if ((sMaxX - sMinX) > 2.5 || (sMaxY - sMinY) > 2.5) {
        for (int v = 0; v < n; v++) {
          final next = (v + 1) < n ? (v + 1) : 0;
          _drawLineAa(
            buf32,
            width,
            height,
            _roofX[v],
            _roofY[v],
            _roofX[next],
            _roofY[next],
            roofOutline,
          );
        }
      }
    }
  }

  /// Collects de-duplicated, screen-projected street labels ordered by road importance.
  List<OsmScreenRoadLabel> collectVisibleRoadLabels({
    required int width,
    required int height,
    required Iterable<OsmVectorTile> tiles,
    required double userWorldX,
    required double userWorldY,
    required int displayZoom,
    required Osm3dCamera camera,
    int skyHorizonPx = 0,
    bool avoidHudPills = false,
    int maxLabels = 7,
  }) {
    final visible = _collectVisibleTileViews(
      tiles,
      userWorldX,
      userWorldY,
      displayZoom,
      camera,
      skyHorizonPx: skyHorizonPx,
    );
    if (visible.tileInfos.isEmpty) return const <OsmScreenRoadLabel>[];

    final double minX = 24.0;
    final double maxX = width - 24.0;
    final double minY = math.max(12.0, skyHorizonPx + 8.0);
    final double maxY = height - 12.0;

    final candidates = <({
      OsmScreenRoadLabel label,
      double anchorDistSq,
    })>[];

    for (final tv in visible.tileInfos) {
      final ox = tv.originX;
      final oy = tv.originY;
      final sz = tv.tileSizePx;
      for (final rl in tv.tile.roadLabels) {
        final wx = ox + rl.midX * sz;
        final wy = oy + rl.midY * sz;
        final rx = camera.worldToRight(wx, wy);
        final ry = camera.worldToBack(wx, wy);
        final cz = camera.camZAt(ry);
        if (camera.perspective3d && cz < camera.nearCamZ + 12.0) continue;

        final p = camera.projectLocal(rx, ry);
        if (p.sx < minX || p.sx > maxX || p.sy < minY || p.sy > maxY) continue;

        if (avoidHudPills) {
          // Keep clear of top-left maneuver card, bottom-left speed/ETA cards, and bottom road pill.
          if (p.sx < 148 && p.sy < 88) continue;
          if (p.sx < 146 && p.sy > 118) continue;
          if (p.sy > height - 50 && (p.sx - camera.anchorX).abs() < 68) continue;
        }

        final wx2 = wx + rl.dirX * 14.0;
        final wy2 = wy + rl.dirY * 14.0;
        final p2 = camera.projectWorld(wx2, wy2);
        final double ddx = p2.sx - p.sx;
        final double ddy = p2.sy - p.sy;
        double angleDeg = 0.0;
        if (ddx * ddx + ddy * ddy > 1e-4) {
          angleDeg = math.atan2(ddy, ddx) * (180.0 / math.pi);
          if (angleDeg > 90.0) {
            angleDeg -= 180.0;
          } else if (angleDeg <= -90.0) {
            angleDeg += 180.0;
          }
        }

        final String displayText = _formatStreetLabel(rl.name);
        final double dxA = p.sx - camera.anchorX;
        final double dyA = p.sy - camera.anchorY;
        candidates.add((
          label: OsmScreenRoadLabel(
            text: displayText,
            sx: p.sx,
            sy: p.sy,
            angleDeg: angleDeg,
            tier: rl.tier,
          ),
          anchorDistSq: dxA * dxA + dyA * dyA,
        ));
      }
    }

    candidates.sort((a, b) {
      final tCmp = b.label.tier.compareTo(a.label.tier);
      if (tCmp != 0) return tCmp;
      return a.anchorDistSq.compareTo(b.anchorDistSq);
    });

    final accepted = <OsmScreenRoadLabel>[];
    for (final c in candidates) {
      if (accepted.length >= maxLabels) break;
      final lab = c.label;
      bool collides = false;
      for (final prev in accepted) {
        final double ddx = lab.sx - prev.sx;
        final double ddy = lab.sy - prev.sy;
        final double distSq = ddx * ddx + ddy * ddy;
        final double minDist = prev.text == lab.text ? 120.0 : 44.0;
        if (distSq < minDist * minDist && (prev.text == lab.text || ddy.abs() < 16.0)) {
          collides = true;
          break;
        }
      }
      if (!collides) {
        accepted.add(lab);
      }
    }
    return accepted;
  }

  static String _formatStreetLabel(String raw) {
    final s = raw.trim();
    if (s.length <= 18) return s;
    if (s.startsWith('Đường ')) return s.substring(6);
    if (s.startsWith('Phố ')) return s.substring(4);
    return s;
  }

  void _blendSkyHorizon(
    Uint32List buf32,
    int width,
    int height,
    int skyHorizonPx,
    _OsmPalette pal,
  ) {
    final int maxY = math.min(height, skyHorizonPx);
    if (maxY <= 0) return;

    final int topR = pal.skyTop & 0xFF;
    final int topG = (pal.skyTop >> 8) & 0xFF;
    final int topB = (pal.skyTop >> 16) & 0xFF;
    final int horR = pal.skyHorizon & 0xFF;
    final int horG = (pal.skyHorizon >> 8) & 0xFF;
    final int horB = (pal.skyHorizon >> 16) & 0xFF;

    for (int y = 0; y < maxY; y++) {
      final double f = 1.0 - (y / maxY);
      final int sr = (horR + (topR - horR) * f).round();
      final int sg = (horG + (topG - horG) * f).round();
      final int sb = (horB + (topB - horB) * f).round();
      final int alpha = (f * f * 234.0).round().clamp(0, 234);
      final int inv = 255 - alpha;
      final int rowOff = y * width;
      for (int x = 0; x < width; x++) {
        final int dst = buf32[rowOff + x];
        final int r = (sr * alpha + (dst & 0xFF) * inv) >> 8;
        final int g = (sg * alpha + ((dst >> 8) & 0xFF) * inv) >> 8;
        final int b = (sb * alpha + ((dst >> 16) & 0xFF) * inv) >> 8;
        buf32[rowOff + x] = 0xFF000000 | (b << 16) | (g << 8) | r;
      }
    }
  }

  static double _roadRadiusForTier(int tier, double scale) {
    switch (tier) {
      case 5:
        return (4.2 * scale).clamp(2.4, 6.2);
      case 4:
        return (3.5 * scale).clamp(2.0, 5.4);
      case 3:
        return (3.0 * scale).clamp(1.7, 4.6);
      case 2:
        return (2.3 * scale).clamp(1.4, 3.6);
      case 1:
        return (1.65 * scale).clamp(1.1, 2.6);
      default:
        return (1.05 * scale).clamp(0.75, 1.7);
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
    Osm3dCamera camera,
    int color,
  ) {
    final n = pts.length ~/ 2;
    if (n < 3) return;
    _ensurePolyCapacity(n * 2);

    final double nearZ = camera.nearCamZ;
    double minCz = double.infinity;
    double maxCz = -double.infinity;
    for (int v = 0; v < n; v++) {
      final wx = ox + pts[v * 2] * sz;
      final wy = oy + pts[v * 2 + 1] * sz;
      final rx = camera.worldToRight(wx, wy);
      final ry = camera.worldToBack(wx, wy);
      final cz = camera.camZAt(ry);
      _clipRx[v] = rx;
      _clipRy[v] = ry;
      _clipCz[v] = cz;
      if (cz < minCz) minCz = cz;
      if (cz > maxCz) maxCz = cz;
    }
    if (camera.perspective3d && maxCz < nearZ) return;

    int outCount = 0;
    if (!camera.perspective3d || minCz >= nearZ) {
      for (int v = 0; v < n; v++) {
        _footRx[v] = _clipRx[v];
        _footRy[v] = _clipRy[v];
      }
      outCount = n;
    } else {
      // Sutherland-Hodgman single half-plane clip (camZ >= nearZ) prevents perspective fold-back.
      double pRx = _clipRx[n - 1];
      double pRy = _clipRy[n - 1];
      double pCz = _clipCz[n - 1];
      bool pIn = pCz >= nearZ;
      for (int v = 0; v < n; v++) {
        final double cRx = _clipRx[v];
        final double cRy = _clipRy[v];
        final double cCz = _clipCz[v];
        final bool cIn = cCz >= nearZ;
        if (cIn != pIn) {
          final double t = (nearZ - pCz) / (cCz - pCz);
          _footRx[outCount] = pRx + t * (cRx - pRx);
          _footRy[outCount] = pRy + t * (cRy - pRy);
          outCount++;
        }
        if (cIn) {
          _footRx[outCount] = cRx;
          _footRy[outCount] = cRy;
          outCount++;
        }
        pRx = cRx;
        pRy = cRy;
        pCz = cCz;
        pIn = cIn;
      }
      if (outCount < 3) return;
    }

    double sMinX = double.infinity, sMaxX = -double.infinity;
    double sMinY = double.infinity, sMaxY = -double.infinity;
    for (int v = 0; v < outCount; v++) {
      final p = camera.projectLocal(_footRx[v], _footRy[v]);
      _polyX[v] = p.sx;
      _polyY[v] = p.sy;
      if (p.sx < sMinX) sMinX = p.sx;
      if (p.sx > sMaxX) sMaxX = p.sx;
      if (p.sy < sMinY) sMinY = p.sy;
      if (p.sy > sMaxY) sMaxY = p.sy;
    }
    if (sMaxX < 0 || sMinX >= width || sMaxY < 0 || sMinY >= height) return;
    _scanlineFill(buf32, width, height, _polyX, _polyY, outCount, color);
  }

  void _strokeNormalizedPolyline(
    Uint32List buf32,
    int width,
    int height,
    Float32List pts,
    double ox,
    double oy,
    double sz,
    Osm3dCamera camera,
    double baseRadius,
    int color,
  ) {
    final n = pts.length ~/ 2;
    if (n < 2) return;

    final double nearZ = camera.nearCamZ;
    double prevRx = 0, prevRy = 0;
    for (int v = 0; v < n; v++) {
      final wx = ox + pts[v * 2] * sz;
      final wy = oy + pts[v * 2 + 1] * sz;
      final rx = camera.worldToRight(wx, wy);
      final ry = camera.worldToBack(wx, wy);
      if (v > 0) {
        double aRx = prevRx, aRy = prevRy;
        double bRx = rx, bRy = ry;
        double aCz = camera.camZAt(aRy);
        double bCz = camera.camZAt(bRy);
        bool drawSeg = true;

        if (camera.perspective3d) {
          if (aCz < nearZ && bCz < nearZ) {
            drawSeg = false;
          } else {
            if (aCz < nearZ) {
              final double t = (nearZ - aCz) / (bCz - aCz);
              aRx = aRx + t * (bRx - aRx);
              aRy = aRy + t * (bRy - aRy);
              aCz = nearZ;
            }
            if (bCz < nearZ) {
              final double t = (nearZ - bCz) / (aCz - bCz);
              bRx = bRx + t * (aRx - bRx);
              bRy = bRy + t * (aRy - bRy);
              bCz = nearZ;
            }
          }
        }

        if (drawSeg) {
          final int parts = (camera.perspective3d && (aCz - bCz).abs() > 38.0)
              ? ((aCz - bCz).abs() / 38.0).ceil().clamp(2, 6)
              : 1;
          for (int k = 0; k < parts; k++) {
            final double t0 = k / parts;
            final double t1 = (k + 1) / parts;
            final p0 = camera.projectLocal(
              aRx + t0 * (bRx - aRx),
              aRy + t0 * (bRy - aRy),
            );
            final p1 = camera.projectLocal(
              aRx + t1 * (bRx - aRx),
              aRy + t1 * (bRy - aRy),
            );
            final double segR = (baseRadius * (p0.scale + p1.scale) * 0.5).clamp(0.45, 9.0);
            if ((p0.sx < -segR - 1 && p1.sx < -segR - 1) ||
                (p0.sx > width + segR + 1 && p1.sx > width + segR + 1) ||
                (p0.sy < -segR - 1 && p1.sy < -segR - 1) ||
                (p0.sy > height + segR + 1 && p1.sy > height + segR + 1)) {
              continue;
            }
            _drawCapsule(buf32, width, height, p0.sx, p0.sy, p1.sx, p1.sy, segR, color);
          }
        }
      }
      prevRx = rx;
      prevRy = ry;
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

    final int alpha = (color >>> 24) & 0xFF;
    final bool opaque = alpha >= 254;
    final int sr = color & 0xFF;
    final int sg = (color >> 8) & 0xFF;
    final int sb = (color >> 16) & 0xFF;
    final int invAlpha = 255 - alpha;
    final int opaqueColor = 0xFF000000 | (sb << 16) | (sg << 8) | sr;

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
          if (opaque) {
            buf32.fillRange(rowOff + x0, rowOff + x1 + 1, opaqueColor);
          } else {
            for (int pxIdx = rowOff + x0; pxIdx <= rowOff + x1; pxIdx++) {
              final int dst = buf32[pxIdx];
              final int r = (sr * alpha + (dst & 0xFF) * invAlpha) >> 8;
              final int g = (sg * alpha + ((dst >> 8) & 0xFF) * invAlpha) >> 8;
              final int b = (sb * alpha + ((dst >> 16) & 0xFF) * invAlpha) >> 8;
              buf32[pxIdx] = 0xFF000000 | (b << 16) | (g << 8) | r;
            }
          }
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

    final int alpha = (color >>> 24) & 0xFF;
    final bool opaque = alpha >= 254;
    final int sr = color & 0xFF;
    final int sg = (color >> 8) & 0xFF;
    final int sb = (color >> 16) & 0xFF;
    final int invAlpha = 255 - alpha;
    final int opaqueColor = 0xFF000000 | (sb << 16) | (sg << 8) | sr;

    final double sx = (x1 - x0) / steps;
    final double sy = (y1 - y0) / steps;
    double cx = x0;
    double cy = y0;
    int prevIdx = -1;
    for (int i = 0; i <= steps; i++) {
      final int ix = cx.round();
      final int iy = cy.round();
      if (ix >= 0 && ix < width && iy >= 0 && iy < height) {
        final int pixIdx = iy * width + ix;
        if (pixIdx != prevIdx) {
          prevIdx = pixIdx;
          if (opaque) {
            buf32[pixIdx] = opaqueColor;
          } else {
            final int dst = buf32[pixIdx];
            final int r = (sr * alpha + (dst & 0xFF) * invAlpha) >> 8;
            final int g = (sg * alpha + ((dst >> 8) & 0xFF) * invAlpha) >> 8;
            final int b = (sb * alpha + ((dst >> 16) & 0xFF) * invAlpha) >> 8;
            buf32[pixIdx] = 0xFF000000 | (b << 16) | (g << 8) | r;
          }
        }
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
  final int skyTop;
  final int skyHorizon;
  final int ground;
  final int landuse;
  final int park;
  final int water;
  final int gridLine;
  final int roadCasingMinor;
  final int roadCasingMajor;
  final int roadCasingHighway;
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
    required this.skyTop,
    required this.skyHorizon,
    required this.ground,
    required this.landuse,
    required this.park,
    required this.water,
    required this.gridLine,
    required this.roadCasingMinor,
    required this.roadCasingMajor,
    required this.roadCasingHighway,
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

  static int _c(int r, int g, int b, [int a = 255]) =>
      ((a & 0xFF) << 24) | ((b & 0xFF) << 16) | ((g & 0xFF) << 8) | (r & 0xFF);

  int roadCasingForTier(int tier) {
    if (tier >= 4) return roadCasingHighway;
    if (tier >= 2) return roadCasingMajor;
    return roadCasingMinor;
  }

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

  // Google Maps 3D Daylight Navigation Palette (translucent sage-slate buildings & pale mint blocks)
  static final _OsmPalette light = _OsmPalette(
    skyTop: _c(134, 190, 232),          // #86BEE8 atmospheric horizon sky
    skyHorizon: _c(222, 236, 245),      // #DEECF5 soft mist transition
    ground: _c(236, 239, 239),          // #ECEFEF neutral Google canvas
    landuse: _c(215, 236, 224),         // #D7ECE0 pale mint urban block
    park: _c(188, 230, 189),            // #BCE6BD park mint
    water: _c(154, 208, 245),           // #9AD0F5 azure water
    gridLine: _c(220, 226, 228),
    roadCasingMinor: _c(210, 217, 224),
    roadCasingMajor: _c(196, 206, 216),
    roadCasingHighway: _c(219, 178, 84),
    roadService: _c(255, 255, 255),
    roadMinor: _c(255, 255, 255),
    roadTertiary: _c(244, 247, 250),
    roadSecondary: _c(228, 235, 242),   // clean ice-gray main avenue
    roadPrimary: _c(252, 235, 168),     // soft pale gold
    roadTrunk: _c(252, 219, 128),       // amber trunk highway
    roofStandard: _c(206, 216, 218, 138),
    roofTall: _c(192, 206, 214, 152),
    outlineStandard: _c(136, 150, 154, 182),
    outlineTall: _c(114, 132, 146, 196),
    wallSunStd: _c(184, 196, 198, 148),
    wallMidStd: _c(158, 172, 176, 162),
    wallShadowStd: _c(134, 148, 154, 174),
    wallSunTall: _c(168, 184, 196, 158),
    wallMidTall: _c(140, 158, 172, 172),
    wallShadowTall: _c(114, 132, 148, 184),
  );

  // Night Translucent 3D Slate Palette
  static final _OsmPalette dark = _OsmPalette(
    skyTop: _c(8, 17, 30),              // #08111E night sky
    skyHorizon: _c(18, 29, 46),         // #121D2E night mist
    ground: _c(20, 29, 43),             // #141D2B deep slate canvas
    landuse: _c(24, 36, 52),            // #182434 night block
    park: _c(22, 51, 43),               // #16332B night green
    water: _c(18, 52, 86),              // #123456 night water
    gridLine: _c(32, 46, 66),
    roadCasingMinor: _c(12, 18, 28),
    roadCasingMajor: _c(16, 26, 40),
    roadCasingHighway: _c(84, 66, 36),
    roadService: _c(36, 48, 66),
    roadMinor: _c(46, 61, 82),
    roadTertiary: _c(58, 76, 102),
    roadSecondary: _c(70, 92, 122),
    roadPrimary: _c(92, 114, 142),
    roadTrunk: _c(118, 128, 148),
    roofStandard: _c(64, 82, 104, 150),
    roofTall: _c(78, 102, 130, 165),
    outlineStandard: _c(96, 120, 148, 185),
    outlineTall: _c(122, 156, 192, 200),
    wallSunStd: _c(54, 70, 90, 158),
    wallMidStd: _c(42, 56, 74, 172),
    wallShadowStd: _c(32, 44, 60, 182),
    wallSunTall: _c(64, 86, 112, 168),
    wallMidTall: _c(48, 66, 90, 180),
    wallShadowTall: _c(36, 50, 70, 190),
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

  static const Utf8Decoder _utf8 = Utf8Decoder(allowMalformed: true);

  String readString() {
    final len = readVarint();
    final sEnd = (pos + len).clamp(pos, end);
    final str = _utf8.convert(buf, pos, sEnd);
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
