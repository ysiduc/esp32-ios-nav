import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart';
import '../models/route_model.dart';

/// Point helper for pixel plotting
class ScreenPoint {
  final int x;
  final int y;
  const ScreenPoint(this.x, this.y);
}

/// Unified Raster Snapshot Map Renderer for ESP32 Minimap (Sections 15-26)
/// Replaces legacy manual vector canvas and CPU tile renderers with a single raster pipeline.
class EspMapFrameRenderer {
  static const int frameWidth = 144;
  static const int frameHeight = 208;

  static const _locationChannel = MethodChannel('com.ysiduc.esp32_nav/location');

  /// Optional provider for live foreground MapLibre widget snapshot
  Future<Uint8List?> Function({int? width, int? height})? mapSnapshotProvider;

  // Cached raster snapshot
  img.Image? _cachedSnapshotImage;
  LatLng? _snapshotCenter;
  double? _snapshotHeading;
  int? _snapshotZoom;
  String? _snapshotRouteId;
  DateTime? _snapshotTimestamp;

  int _snapshotRefreshCount = 0;
  int get snapshotRefreshCount => _snapshotRefreshCount;

  DateTime? get snapshotTimestamp => _snapshotTimestamp;
  int get snapshotAgeMs => _snapshotTimestamp == null
      ? 0
      : DateTime.now().difference(_snapshotTimestamp!).inMilliseconds;

  Uint8List? _lastEncodedJpeg;
  Uint8List? get lastEncodedJpeg => _lastEncodedJpeg;

  /// Check if movement or orientation change justifies requesting a fresh raster snapshot (Section 20)
  bool shouldRefreshSnapshot({
    required LatLng currentPos,
    required double currentHeading,
    required int zoom,
    required String? routeId,
  }) {
    if (_cachedSnapshotImage == null || _snapshotCenter == null || _snapshotHeading == null) {
      return true;
    }

    // Distance threshold: >= 10 meters (Section 20: 8-15m)
    const distCalc = Distance();
    final dist = distCalc.as(LengthUnit.Meter, _snapshotCenter!, currentPos);
    if (dist >= 10.0) return true;

    // Heading delta threshold: >= 15 degrees
    final headingDelta = (_snapshotHeading! - currentHeading).abs();
    final normHeadingDelta = headingDelta > 180 ? 360 - headingDelta : headingDelta;
    if (normHeadingDelta >= 15.0) return true;

    // Zoom or route revision change
    if (_snapshotZoom != zoom) return true;
    if (_snapshotRouteId != routeId) return true;

    return false;
  }

  /// Request a fresh raster snapshot from foreground MapLibre provider or background native MKMapSnapshotter
  Future<img.Image?> _fetchFreshSnapshot({
    required bool isForeground,
    required LatLng center,
    required double heading,
    required int zoom,
    required String? routeId,
  }) async {
    Uint8List? rawBytes;

    // 1. In foreground: try mapSnapshotProvider first (Section 17)
    if (isForeground && mapSnapshotProvider != null) {
      try {
        rawBytes = await mapSnapshotProvider!(width: frameWidth, height: frameHeight);
      } catch (e) {
        debugPrint('[EspMapFrameRenderer] Foreground snapshot provider failed: $e');
      }
    }

    // 2. In background or fallback: call native iOS MKMapSnapshotter (Section 18)
    if (rawBytes == null && Platform.isIOS && !Platform.environment.containsKey('FLUTTER_TEST')) {
      try {
        rawBytes = await _locationChannel.invokeMethod<Uint8List>('renderMapSnapshot', {
          'lat': center.latitude,
          'lng': center.longitude,
          'width': frameWidth.toDouble(),
          'height': frameHeight.toDouble(),
          'spanMeters': 300.0,
        });
      } catch (e) {
        debugPrint('[EspMapFrameRenderer] Native MKMapSnapshotter failed: $e');
      }
    }

    img.Image? decoded;
    if (rawBytes != null && rawBytes.isNotEmpty) {
      try {
        decoded = img.decodeImage(rawBytes);
      } catch (_) {}
    }

    // Fallback neutral raster if snapshotter is unavailable (e.g. tests or initial start)
    if (decoded == null) {
      if (_cachedSnapshotImage != null) {
        return _cachedSnapshotImage;
      }
      decoded = img.Image(width: frameWidth, height: frameHeight);
      img.fill(decoded, color: img.ColorRgba8(240, 242, 245, 255));
    }

    _cachedSnapshotImage = decoded;
    _snapshotCenter = center;
    _snapshotHeading = heading;
    _snapshotZoom = zoom;
    _snapshotRouteId = routeId;
    _snapshotTimestamp = DateTime.now();
    _snapshotRefreshCount++;

    return decoded;
  }

  /// Render frame using cached raster snapshot + lightweight overlay (Sections 21 & 22)
  Future<Uint8List?> renderFrame({
    required bool isForeground,
    required LatLng userPos,
    required double heading,
    required NavRoute? activeRoute,
    required int zoom,
    required bool isBle,
    int? remainingStepIndex,
  }) async {
    final routeId = activeRoute == null
        ? null
        : "${activeRoute.polylinePoints.length}_${activeRoute.totalDistanceMeters}";

    img.Image? baseImage;
    if (shouldRefreshSnapshot(
      currentPos: userPos,
      currentHeading: heading,
      zoom: zoom,
      routeId: routeId,
    )) {
      baseImage = await _fetchFreshSnapshot(
        isForeground: isForeground,
        center: userPos,
        heading: heading,
        zoom: zoom,
        routeId: routeId,
      );
    } else {
      baseImage = _cachedSnapshotImage;
    }

    if (baseImage == null) return null;

    // Create mutable frame from cached base image
    final frame = img.Image.from(baseImage);

    // Apply lightweight overlay: remaining route polyline + vehicle puck (Section 21 & 23)
    _drawLightweightOverlay(
      frame: frame,
      userPos: userPos,
      heading: heading,
      activeRoute: activeRoute,
      remainingStepIndex: remainingStepIndex,
    );

    // Dynamic quality encoding (Section 14):
    // BLE: lower quality (45) to ensure transfer fits in ~2-3 KB
    // Wi-Fi: higher quality (70) for crisp TFT display
    final quality = isBle ? 45 : 70;
    final jpeg = Uint8List.fromList(img.encodeJpg(frame, quality: quality));
    _lastEncodedJpeg = jpeg;
    return jpeg;
  }

  /// Draw remaining route and vehicle puck directly on the raster frame (Sections 21 & 23)
  void _drawLightweightOverlay({
    required img.Image frame,
    required LatLng userPos,
    required double heading,
    required NavRoute? activeRoute,
    int? remainingStepIndex,
  }) {
    const cx = frameWidth ~/ 2;
    const cy = 140; // Center puck around lower third of TFT (like Apple Maps navigation)

    // 1. Draw remaining route polyline (Section 23)
    if (activeRoute != null && activeRoute.polylinePoints.isNotEmpty) {
      final points = activeRoute.polylinePoints;
      final startIndex = (remainingStepIndex ?? 0).clamp(0, points.length - 1);

      // Convert GPS lat/lon deltas to screen pixel coordinates around userPos
      const double metersPerDegreeLat = 111320.0;
      final double metersPerDegreeLon = 111320.0 * math.cos(userPos.latitude * math.pi / 180.0);
      const double pixelsPerMeter = 0.5; // ~300m span across 150px

      final rad = -heading * math.pi / 180.0;
      final cosH = math.cos(rad);
      final sinH = math.sin(rad);

      ScreenPoint? lastPt;
      final routeColor = img.ColorRgba8(0, 122, 255, 255); // Vibrant Apple blue
      final routeBorder = img.ColorRgba8(0, 60, 160, 255);

      for (int i = startIndex; i < points.length; i++) {
        final pt = points[i];
        final dEast = (pt.longitude - userPos.longitude) * metersPerDegreeLon;
        final dNorth = (pt.latitude - userPos.latitude) * metersPerDegreeLat;

        // Rotate by heading
        final rx = (dEast * cosH - dNorth * sinH) * pixelsPerMeter;
        final ry = -(dEast * sinH + dNorth * cosH) * pixelsPerMeter;

        final px = (cx + rx).round();
        final py = (cy + ry).round();

        if (lastPt != null) {
          // Draw bordered polyline
          img.drawLine(frame, x1: lastPt.x, y1: lastPt.y, x2: px, y2: py, color: routeBorder, thickness: 6);
          img.drawLine(frame, x1: lastPt.x, y1: lastPt.y, x2: px, y2: py, color: routeColor, thickness: 4);
        }
        lastPt = ScreenPoint(px, py);
      }
    }

    // 2. Draw vehicle puck arrow at (cx, cy)
    final puckBorder = img.ColorRgba8(255, 255, 255, 255);
    final puckCenter = img.ColorRgba8(0, 122, 255, 255);

    img.fillCircle(frame, x: cx, y: cy, radius: 7, color: puckBorder);
    img.fillCircle(frame, x: cx, y: cy, radius: 5, color: puckCenter);

    // Front arrow tip pointing up (relative to heading-aligned frame)
    img.fillCircle(frame, x: cx, y: cy - 9, radius: 2, color: puckBorder);
  }

  void resetForTesting() {
    _cachedSnapshotImage = null;
    _snapshotCenter = null;
    _snapshotHeading = null;
    _snapshotZoom = null;
    _snapshotRouteId = null;
    _snapshotTimestamp = null;
    _snapshotRefreshCount = 0;
    _lastEncodedJpeg = null;
  }
}