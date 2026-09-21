import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart';
import '../config/mapbox_config.dart';
import '../models/route_model.dart';

/// Proven Raster Map Renderer for ESP32 left display panel (144x208)
/// Restores stable pre-thermal baseline pipeline (Sections 11-24)
/// - Pure raster tile composition (MapTiler / OSM)
/// - In-memory bounded cache (100 tiles max)
/// - 3x3 patch composition around GPS position
/// - Route polyline casing + core overlay
/// - Heading rotation (-headingDeg) and crop to 144x208
/// - Sanity rejection: detects uniform white/black frames and preserves lastGoodJpeg
class EspRasterMapRenderer {
  static const int frameWidth = 144;
  static const int frameHeight = 208;
  static const int patchSize = 320;

  final Map<String, img.Image> _tileCache = {};
  Map<String, img.Image> get tileCache => _tileCache;

  final Set<String> _pendingTileFetches = {};
  Set<String> get pendingTileFetches => _pendingTileFetches;

  Uint8List? _lastGoodJpeg;
  Uint8List? get lastGoodJpeg => _lastGoodJpeg;

  http.Client? httpClient;

  String streamMapStyle = 'streets-v2';
  int minimapZoom = 16;
  bool isDark = true;

  LatLng? _lastPrefetchPos;
  int _renderCount = 0;
  int get renderCount => _renderCount;

  /// Lightweight sanity validation (Section 17)
  /// Rejects near-uniform white (>90% pixels >= 245) or near-uniform black (>90% pixels <= 15)
  bool isSanityValid(img.Image frame) {
    int brightPixels = 0;
    int darkPixels = 0;
    int totalChecked = 0;

    for (int y = 10; y < frame.height; y += 16) {
      for (int x = 10; x < frame.width; x += 16) {
        final p = frame.getPixel(x, y);
        final r = p.r.toInt();
        final g = p.g.toInt();
        final b = p.b.toInt();
        totalChecked++;

        if (r >= 245 && g >= 245 && b >= 245) {
          brightPixels++;
        } else if (r <= 15 && g <= 15 && b <= 15) {
          darkPixels++;
        }
      }
    }

    if (totalChecked == 0) return true;
    if ((brightPixels / totalChecked) > 0.90) return false;
    if ((darkPixels / totalChecked) > 0.90) return false;
    return true;
  }

  /// Asynchronously prefetch 3x3 surrounding tiles around user position (Section 15)
  void prefetchSurroundingTiles(LatLng pos, int zoom) {
    final double n = math.pow(2.0, zoom).toDouble();
    final double latRad = pos.latitude * (math.pi / 180.0);
    final int cx = ((pos.longitude + 180.0) / 360.0 * n).floor();
    final int cy = ((1.0 - (math.log(math.tan(latRad) + 1.0 / math.cos(latRad)) / math.pi)) / 2.0 * n).floor();

    if (_lastPrefetchPos != null) {
      final dLat = (pos.latitude - _lastPrefetchPos!.latitude).abs();
      final dLon = (pos.longitude - _lastPrefetchPos!.longitude).abs();
      if (dLat < 0.0003 && dLon < 0.0003) {
        bool allCached = true;
        for (int dx = -1; dx <= 1; dx++) {
          for (int dy = -1; dy <= 1; dy++) {
            final k = '$zoom/${cx + dx}/${cy + dy}';
            if (!_tileCache.containsKey(k)) {
              allCached = false;
              break;
            }
          }
          if (!allCached) break;
        }
        if (allCached) return;
      }
    }
    _lastPrefetchPos = pos;

    for (int dx = -1; dx <= 1; dx++) {
      for (int dy = -1; dy <= 1; dy++) {
        final tx = cx + dx;
        final ty = cy + dy;
        final key = '$zoom/$tx/$ty';

        if (!_tileCache.containsKey(key) && !_pendingTileFetches.contains(key)) {
          fetchTileImage(key, tx, ty, zoom);
        }
      }
    }
  }

  /// Fetch single tile image with deduplication and cache bounding (Section 14)
  Future<void> fetchTileImage(String key, int x, int y, int z) async {
    _pendingTileFetches.add(key);
    try {
      final style = streamMapStyle;
      final styleDark = style.contains('dark') || isDark;
      final ext = style == 'hybrid' ? 'jpg' : 'png';

      final apiKey = MapboxConfig.maptilerApiKey;
      final String url = apiKey.isNotEmpty
          ? 'https://api.maptiler.com/maps/$style/256/$z/$x/$y@2x.$ext?key=$apiKey&language=vi'
          : (styleDark
              ? 'https://api.maptiler.com/maps/streets-v2-dark/256/$z/$x/$y@2x.png?key=dtGJ2HGvyxQPKNlHznvY&language=vi'
              : 'https://api.maptiler.com/maps/streets-v2/256/$z/$x/$y@2x.png?key=dtGJ2HGvyxQPKNlHznvY&language=vi');

      final client = httpClient ?? http.Client();
      var response = await client.get(
        Uri.parse(url),
        headers: {'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)'},
      ).timeout(const Duration(seconds: 4));

      if (response.statusCode != 200 && apiKey.isNotEmpty) {
        final fallbackUrl = styleDark
            ? 'https://api.maptiler.com/maps/streets-v2-dark/256/$z/$x/$y@2x.png?key=dtGJ2HGvyxQPKNlHznvY&language=vi'
            : 'https://api.maptiler.com/maps/streets-v2/256/$z/$x/$y@2x.png?key=dtGJ2HGvyxQPKNlHznvY&language=vi';
        response = await client.get(
          Uri.parse(fallbackUrl),
          headers: {'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)'},
        ).timeout(const Duration(seconds: 4));
      }

      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        var cpuImg = img.decodeImage(response.bodyBytes);
        if (cpuImg != null) {
          if (cpuImg.width > 256) {
            cpuImg = img.copyResize(cpuImg, width: 256, height: 256, interpolation: img.Interpolation.average);
          }
          _tileCache[key] = cpuImg;
          if (_tileCache.length > 100) {
            _tileCache.remove(_tileCache.keys.first);
          }
        }
      }
    } catch (_) {
      // Network tile failure: silent fallback to last valid frame (Section 16)
    } finally {
      _pendingTileFetches.remove(key);
    }
  }

  /// Render 144x208 map frame from raster tiles, route polyline, and vehicle puck (Sections 19, 20, 21)
  Uint8List? renderFrame({
    required LatLng userPos,
    required double headingDeg,
    required NavRoute? activeRoute,
    required bool isNavigating,
    int quality = 70,
    int? zoom,
  }) {
    final effectiveZoom = zoom ?? minimapZoom;
    prefetchSurroundingTiles(userPos, effectiveZoom);

    try {
      final double n = math.pow(2.0, effectiveZoom).toDouble();
      final double latRad = userPos.latitude * (math.pi / 180.0);
      final double worldX = (userPos.longitude + 180.0) / 360.0 * n * 256.0;
      final double worldY = (1.0 - (math.log(math.tan(latRad) + 1.0 / math.cos(latRad)) / math.pi)) / 2.0 * n * 256.0;

      final int centerTileX = (worldX / 256.0).floor();
      final int centerTileY = (worldY / 256.0).floor();
      final double subTileX = worldX - (centerTileX * 256.0);
      final double subTileY = worldY - (centerTileY * 256.0);

      final patch = img.Image(width: patchSize, height: patchSize);
      final bgColor = isDark ? img.ColorRgba8(11, 17, 26, 255) : img.ColorRgba8(235, 240, 240, 255);
      img.fill(patch, color: bgColor);

      const double patchCenter = patchSize / 2.0;

      // 1. Composite 3x3 surrounding tiles
      bool tilesDrawn = false;
      for (int dx = -1; dx <= 1; dx++) {
        for (int dy = -1; dy <= 1; dy++) {
          final int dstX = (patchCenter + (dx * 256.0) - subTileX).round();
          final int dstY = (patchCenter + (dy * 256.0) - subTileY).round();
          if (dstX + 256 <= 0 || dstX >= patchSize || dstY + 256 <= 0 || dstY >= patchSize) {
            continue;
          }

          final tx = centerTileX + dx;
          final ty = centerTileY + dy;
          final key = '$effectiveZoom/$tx/$ty';
          final tileImg = _tileCache[key];
          if (tileImg != null) {
            img.compositeImage(patch, tileImg, dstX: dstX, dstY: dstY);
            tilesDrawn = true;
          }
        }
      }

      // If tiles not cached yet, draw clean placeholder grid (not white/black screen)
      if (!tilesDrawn) {
        final gridColor = isDark ? img.ColorRgba8(30, 45, 66, 255) : img.ColorRgba8(221, 227, 227, 255);
        for (int gx = 0; gx <= patchSize; gx += 32) {
          img.drawLine(patch, x1: gx, y1: 0, x2: gx, y2: patchSize, color: gridColor);
        }
        for (int gy = 0; gy <= patchSize; gy += 32) {
          img.drawLine(patch, x1: 0, y1: gy, x2: patchSize, y2: gy, color: gridColor);
        }
      }

      // 2. Draw active route polyline (Section 20)
      if (isNavigating && activeRoute != null && activeRoute.polylinePoints.length >= 2) {
        final pts = activeRoute.polylinePoints;
        final casingColor = isDark ? img.ColorRgba8(0, 61, 102, 255) : img.ColorRgba8(0, 81, 179, 255);
        final coreColor = isDark ? img.ColorRgba8(0, 240, 255, 255) : img.ColorRgba8(0, 122, 255, 255);

        final screenPts = <img.Point>[];
        for (final pt in pts) {
          final double ptLatRad = pt.latitude * (math.pi / 180.0);
          final double ptWorldX = (pt.longitude + 180.0) / 360.0 * n * 256.0;
          final double ptWorldY = (1.0 - (math.log(math.tan(ptLatRad) + 1.0 / math.cos(ptLatRad)) / math.pi)) / 2.0 * n * 256.0;
          final int px = (patchCenter + (ptWorldX - worldX)).round();
          final int py = (patchCenter + (ptWorldY - worldY)).round();
          screenPts.add(img.Point(px, py));
        }

        // Casing (thickness 8)
        for (int i = 0; i < screenPts.length - 1; i++) {
          final p1 = screenPts[i];
          final p2 = screenPts[i + 1];
          if ((p1.x >= -30 && p1.x <= patchSize + 30 && p1.y >= -30 && p1.y <= patchSize + 30) ||
              (p2.x >= -30 && p2.x <= patchSize + 30 && p2.y >= -30 && p2.y <= patchSize + 30)) {
            img.drawLine(patch, x1: p1.x.toInt(), y1: p1.y.toInt(), x2: p2.x.toInt(), y2: p2.y.toInt(), color: casingColor, thickness: 8);
            img.fillCircle(patch, x: p1.x.toInt(), y: p1.y.toInt(), radius: 4, color: casingColor);
            img.fillCircle(patch, x: p2.x.toInt(), y: p2.y.toInt(), radius: 4, color: casingColor);
          }
        }

        // Vibrant core (thickness 5)
        for (int i = 0; i < screenPts.length - 1; i++) {
          final p1 = screenPts[i];
          final p2 = screenPts[i + 1];
          if ((p1.x >= -30 && p1.x <= patchSize + 30 && p1.y >= -30 && p1.y <= patchSize + 30) ||
              (p2.x >= -30 && p2.x <= patchSize + 30 && p2.y >= -30 && p2.y <= patchSize + 30)) {
            img.drawLine(patch, x1: p1.x.toInt(), y1: p1.y.toInt(), x2: p2.x.toInt(), y2: p2.y.toInt(), color: coreColor, thickness: 5);
            img.fillCircle(patch, x: p1.x.toInt(), y: p1.y.toInt(), radius: 2, color: coreColor);
            img.fillCircle(patch, x: p2.x.toInt(), y: p2.y.toInt(), radius: 2, color: coreColor);
          }
        }

        // Destination pin
        final destPt = pts.last;
        final double destLatRad = destPt.latitude * (math.pi / 180.0);
        final double destWorldX = (destPt.longitude + 180.0) / 360.0 * n * 256.0;
        final double destWorldY = (1.0 - (math.log(math.tan(destLatRad) + 1.0 / math.cos(destLatRad)) / math.pi)) / 2.0 * n * 256.0;
        final int dx = (patchCenter + (destWorldX - worldX)).round();
        final int dy = (patchCenter + (destWorldY - worldY)).round();
        if (dx >= 10 && dx <= patchSize - 10 && dy >= 10 && dy <= patchSize - 10) {
          img.fillCircle(patch, x: dx, y: dy, radius: 8, color: img.ColorRgba8(255, 59, 48, 255));
          img.drawCircle(patch, x: dx, y: dy, radius: 8, color: img.ColorRgba8(255, 255, 255, 255));
          img.fillCircle(patch, x: dx, y: dy, radius: 3, color: img.ColorRgba8(255, 255, 255, 255));
        }
      }

      // 3. Rotation & Crop to 144x208 (Section 19)
      img.Image rotatedPatch = patch;
      if (isNavigating && headingDeg.abs() > 0.5) {
        rotatedPatch = img.copyRotate(patch, angle: -headingDeg, interpolation: img.Interpolation.nearest);
      }

      final int rotCx = rotatedPatch.width ~/ 2;
      final int rotCy = rotatedPatch.height ~/ 2;

      // In navigation: anchor at (72, 140) (lower third)
      // In standby: anchor at center (72, 104) (north-up)
      final int anchorX = frameWidth ~/ 2;
      final int anchorY = isNavigating ? (frameHeight * 0.67).round() : (frameHeight ~/ 2);

      final int cropX = (rotCx - anchorX).clamp(0, math.max(0, rotatedPatch.width - frameWidth));
      final int cropY = (rotCy - anchorY).clamp(0, math.max(0, rotatedPatch.height - frameHeight));

      final frame = img.copyCrop(
        rotatedPatch,
        x: cropX,
        y: cropY,
        width: frameWidth,
        height: frameHeight,
      );

      // 4. Vehicle / User Location Puck (Section 20 & 21)
      final int vx = anchorX;
      final int vy = anchorY;
      final puckColor = isDark ? img.ColorRgba8(0, 240, 255, 255) : img.ColorRgba8(0, 122, 255, 255);
      final auraColor = isDark ? img.ColorRgba8(0, 240, 255, 45) : img.ColorRgba8(0, 122, 255, 45);

      img.fillCircle(frame, x: vx, y: vy, radius: 16, color: auraColor);
      img.fillCircle(frame, x: vx, y: vy, radius: 11, color: img.ColorRgba8(255, 255, 255, 255));
      img.fillCircle(frame, x: vx, y: vy, radius: 9, color: puckColor);

      img.fillPolygon(frame, vertices: [
        img.Point(vx, vy - 7),
        img.Point(vx + 4, vy + 4),
        img.Point(vx, vy + 2),
        img.Point(vx - 4, vy + 4),
      ], color: img.ColorRgba8(255, 255, 255, 255));

      // 5. Sanity check: reject blank frame (Section 17)
      if (!isSanityValid(frame)) {
        debugPrint('[EspRasterMapRenderer] Rejecting blank frame, reusing lastGoodJpeg');
        return _lastGoodJpeg;
      }

      final encoded = Uint8List.fromList(img.encodeJpg(frame, quality: quality));
      _lastGoodJpeg = encoded;
      _renderCount++;
      return encoded;
    } catch (e, stack) {
      debugPrint('[EspRasterMapRenderer Error] $e\n$stack');
      return _lastGoodJpeg;
    }
  }

  void resetForTesting() {
    _tileCache.clear();
    _pendingTileFetches.clear();
    _lastGoodJpeg = null;
    _lastPrefetchPos = null;
    _renderCount = 0;
  }
}
