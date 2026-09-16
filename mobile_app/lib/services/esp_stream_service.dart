import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart' hide Path;
import '../config/goong_config.dart';
import '../config/mapbox_config.dart';
import '../models/route_model.dart';
import 'ble_service.dart';
import 'navigation_manager.dart';

class EspStreamService extends ChangeNotifier with WidgetsBindingObserver {
  BleService bleService;
  NavigationManager? navManager;

  bool _isSendingWifi = false;

  /// Optional hook to take live vector snapshots from MapLibre Goong map
  Future<Uint8List?> Function({int? width, int? height})? mapSnapshotProvider;

  bool _isStreaming = false;
  bool _isCapturing = false;
  bool _isForeground = true;
  int _targetFps = 20; // High-speed 20 FPS stream over Wi-Fi (throttled to 4 FPS in background)
  double _actualFps = 10.0;
  int _frameSizeKb = 0;
  int _frameCount = 0;
  DateTime? _lastFpsUpdate;
  int _framesInCurrentSec = 0;

  Timer? _streamTimer;
  Timer? _pauseTimer;
  Uint8List? _latestJpegBytes;
  bool _isSendingBle = false;

  // Real Map Tile Cache (In-Memory Image Cache for Instant Rendering)
  final Map<String, ui.Image> _tileCache = {};
  final Set<String> _pendingTileFetches = {};

  // Getters
  bool get isStreaming => _isStreaming;
  int get targetFps => _targetFps;
  double get actualFps => _actualFps;
  int get frameSizeKb => _frameSizeKb;
  Uint8List? get latestJpegBytes => _latestJpegBytes;

  String _streamMapStyle = GoongConfig.isConfigured ? 'goong-streets' : 'streets-v2';
  String get streamMapStyle => _streamMapStyle;
  set streamMapStyle(String val) {
    if (_streamMapStyle != val) {
      _streamMapStyle = val;
      _tileCache.forEach((_, img) => img.dispose());
      _tileCache.clear();
      _lastPrefetchPos = null;
      notifyListeners();
    }
  }

  int _minimapZoom = 17; // 14 to 18 (default 17 for detailed building polygons & POIs like Image 2)
  int get minimapZoom => _minimapZoom;
  set minimapZoom(int val) {
    final clamped = val.clamp(14, 18);
    if (_minimapZoom != clamped) {
      _minimapZoom = clamped;
      _tileCache.forEach((_, img) => img.dispose());
      _tileCache.clear();
      _lastPrefetchPos = null;
      notifyListeners();
    }
  }

  EspStreamService({required this.bleService, this.navManager}) {
    WidgetsBinding.instance.addObserver(this);
  }

  void updateReferences(BleService newBle, NavigationManager newNav) {
    bleService = newBle;
    navManager = newNav;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _isForeground = true;
      if (_isStreaming) {
        _startTimer();
      }
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _isForeground = false;
      // When app is in background or screen is locked:
      // If Wi-Fi is connected, throttle to cool 4 FPS to prevent device heating
      if (_isStreaming && bleService.isWifiConnected) {
        _startTimer();
      } else if (!bleService.isWifiConnected && !(navManager?.isNavigating ?? false)) {
        _streamTimer?.cancel();
        _streamTimer = null;
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    stopStreaming();
    _pauseTimer?.cancel();
    _tileCache.forEach((_, img) => img.dispose());
    _tileCache.clear();
    super.dispose();
  }

  /// Pause streaming temporarily (e.g. during map search or routing) to give 100% CPU to UI
  void pauseStreamingFor(Duration duration) {
    if (!_isStreaming) return;
    _streamTimer?.cancel();
    _streamTimer = null;
    _pauseTimer?.cancel();
    _pauseTimer = Timer(duration, () {
      if (_isStreaming && (_isForeground || bleService.isWifiConnected) && _streamTimer == null) {
        _startTimer();
      }
    });
  }

  /// Change target FPS (5 - 30)
  void setTargetFps(int fps) {
    _targetFps = fps.clamp(5, 30);
    if (_isStreaming && _isForeground) {
      startStreaming();
    }
    notifyListeners();
  }

  /// Start High-Speed Headless 20-30 FPS JPEG Streaming
  void startStreaming({GlobalKey? boundaryKey}) {
    stopStreaming();
    _isStreaming = true;
    _frameCount = 0;
    _framesInCurrentSec = 0;
    _actualFps = _targetFps.toDouble();
    _lastFpsUpdate = DateTime.now();

    if (_isForeground || bleService.isWifiConnected) {
      _startTimer();
    }

    notifyListeners();
  }

  void _startTimer() {
    _streamTimer?.cancel();
    // In foreground: smooth 20 FPS. In background (screen locked): cool 4 FPS to prevent heating
    final effectiveFps = _isForeground ? _targetFps : 4;
    final intervalMs = (1000 / effectiveFps).round();
    _streamTimer = Timer.periodic(Duration(milliseconds: intervalMs), (_) {
      _renderAndStreamHeadlessFrame();
    });
  }

  /// Render 144x208 High-Definition Real Street Map in Memory & Stream at 20 FPS
  Future<void> _renderAndStreamHeadlessFrame() async {
    // If previous frame is still transmitting over TCP or BLE, drop this tick to avoid queue buildup and heating
    if (!_isStreaming || _isCapturing || _isSendingWifi || _isSendingBle || (!_isForeground && !bleService.isWifiConnected)) return;
    _isCapturing = true;

    try {
      const int w = 144;
      const int h = 208;

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, 144, 208));

      // Extract current navigation telemetry
      final userPos = navManager?.currentLocation ?? const LatLng(20.9832, 105.8425);
      final double heading = navManager?.effectiveHeading ?? navManager?.currentHeading ?? 0.0;
      final activeRoute = navManager?.activeRoute;
      final distToTurn = navManager?.distanceToNextManeuver ?? 208.0;
      final speedKmh = navManager?.currentSpeedKmh ?? 0.0;

      // 0. Check live vector snapshot from MapLibre Goong map if provider hooked
      if (mapSnapshotProvider != null) {
        try {
          final snapshotBytes = await mapSnapshotProvider!(width: w, height: h);
          if (snapshotBytes != null && snapshotBytes.isNotEmpty) {
            final decoded = img.decodeImage(snapshotBytes);
            if (decoded != null) {
              final jpegBytes = Uint8List.fromList(img.encodeJpg(decoded, quality: 72));
              _latestJpegBytes = jpegBytes;
              _frameSizeKb = (jpegBytes.length / 1024).round();
              _frameCount++;
              _framesInCurrentSec++;
              _dispatchTransmission(jpegBytes);
              notifyListeners();
              _isCapturing = false;
              return;
            }
          }
        } catch (_) {}
      }

      // Pre-fetch surrounding tiles asynchronously at chosen minimap zoom
      _prefetchSurroundingTiles(userPos, _minimapZoom);

      // 1. Draw Real Map Canvas (< 0.5ms)
      _drawRealMapCanvas(
        canvas: canvas,
        w: w.toDouble(),
        h: h.toDouble(),
        userPos: userPos,
        headingDeg: heading,
        activeRoute: activeRoute,
        distToTurn: distToTurn,
        speedKmh: speedKmh,
      );

      final picture = recorder.endRecording();
      final ui.Image image = await picture.toImage(w, h);
      final ByteData? byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      picture.dispose();

      if (byteData == null) {
        _isCapturing = false;
        return;
      }

      final rawBytes = byteData.buffer.asUint8List();

      // 2. Direct Fast In-Memory JPEG Encoding (144x208 with high efficiency quality ~1.3KB)
      final imgImage = img.Image.fromBytes(
        width: w,
        height: h,
        bytes: rawBytes.buffer,
        order: img.ChannelOrder.rgba,
      );
      final jpegBytes = Uint8List.fromList(img.encodeJpg(imgImage, quality: 70));

      _latestJpegBytes = jpegBytes;
      _frameSizeKb = (jpegBytes.length / 1024).round();
      _frameCount++;
      _framesInCurrentSec++;

      final now = DateTime.now();
      if (_lastFpsUpdate != null && now.difference(_lastFpsUpdate!).inMilliseconds >= 800) {
        final elapsed = now.difference(_lastFpsUpdate!).inMilliseconds / 1000.0;
        final calcFps = (_framesInCurrentSec / elapsed);
        _actualFps = calcFps.clamp(1.0, 30.0);
        _framesInCurrentSec = 0;
        _lastFpsUpdate = now;
        notifyListeners();
      }

      // 3. Decoupled Asynchronous Transmission
      _dispatchTransmission(jpegBytes);
    } catch (_) {
    } finally {
      _isCapturing = false;
    }
  }

  void _dispatchTransmission(Uint8List jpegBytes) {
    if (bleService.isWifiConnected && bleService.wifiIp != null) {
      if (!_isSendingWifi) {
        _sendJpegOverWifi(jpegBytes);
      }
    } else {
      if (!_isSendingBle) {
        _sendJpegOverBle(jpegBytes);
      }
    }
  }

  int _consecutiveWifiErrors = 0;

  /// Send JPEG frame over WiFi TCP socket directly to ESP32 (screen-off background streaming)
  Future<void> _sendJpegOverWifi(Uint8List jpegBytes) async {
    final ip = bleService.wifiIp;
    final port = bleService.wifiPort;
    if (ip == null || port == 0 || _isSendingWifi) return;
    _isSendingWifi = true;

    try {
      final socket = await Socket.connect(ip, port, timeout: const Duration(milliseconds: 300));
      socket.add(jpegBytes);
      await socket.flush();
      await socket.close();
      _consecutiveWifiErrors = 0;
    } catch (_) {
      _consecutiveWifiErrors++;
      if (_consecutiveWifiErrors >= 3) {
        bleService.setWifiDisconnected();
      }
    } finally {
      _isSendingWifi = false;
    }
  }

  LatLng? _lastPrefetchPos;

  /// Asynchronously pre-fetch surrounding MapTiler / OSM HD tiles
  void _prefetchSurroundingTiles(LatLng pos, int zoom) {
    final double n = math.pow(2.0, zoom).toDouble();
    final double latRad = pos.latitude * (math.pi / 180.0);
    final int cx = ((pos.longitude + 180.0) / 360.0 * n).floor();
    final int cy = ((1.0 - (math.log(math.tan(latRad) + 1.0 / math.cos(latRad)) / math.pi)) / 2.0 * n).floor();

    // If surrounding 25 tiles are already cached and position hasn't moved significantly, skip
    if (_lastPrefetchPos != null) {
      final dLat = (pos.latitude - _lastPrefetchPos!.latitude).abs();
      final dLon = (pos.longitude - _lastPrefetchPos!.longitude).abs();
      if (dLat < 0.0003 && dLon < 0.0003) {
        bool allCached = true;
        for (int dx = -2; dx <= 2; dx++) {
          for (int dy = -2; dy <= 2; dy++) {
            if (!_tileCache.containsKey('$zoom/${cx + dx}/${cy + dy}')) {
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

    for (int dx = -2; dx <= 2; dx++) {
      for (int dy = -2; dy <= 2; dy++) {
        final tx = cx + dx;
        final ty = cy + dy;
        final key = '$zoom/$tx/$ty';

        if (!_tileCache.containsKey(key) && !_pendingTileFetches.contains(key)) {
          _fetchTileImage(key, tx, ty, zoom);
        }
      }
    }
  }

  Future<void> _fetchTileImage(String key, int x, int y, int z) async {
    _pendingTileFetches.add(key);
    try {
      final style = _streamMapStyle;
      final isDark = style.contains('dark');
      final isGoong = style.contains('goong');
      final ext = style == 'hybrid' ? 'jpg' : 'png';

      final apiKey = MapboxConfig.maptilerApiKey;
      String url;
      if (isGoong) {
        // High-definition clean vector-based raster tiles with bright sky-blue water & white roads (Goong style)
        url = isDark
            ? 'https://api.maptiler.com/maps/streets-v2-dark/256/$z/$x/$y@2x.png?key=$apiKey&language=vi'
            : 'https://api.maptiler.com/maps/bright-v2/256/$z/$x/$y@2x.png?key=$apiKey&language=vi';
      } else {
        url = apiKey.isNotEmpty
            ? 'https://api.maptiler.com/maps/$style/256/$z/$x/$y@2x.$ext?key=$apiKey'
            : (isDark
                ? 'https://api.maptiler.com/maps/streets-v2-dark/256/$z/$x/$y@2x.png?key=dtGJ2HGvyxQPKNlHznvY&language=vi'
                : 'https://api.maptiler.com/maps/bright-v2/256/$z/$x/$y@2x.png?key=dtGJ2HGvyxQPKNlHznvY&language=vi');
      }

      var response = await http.get(
        Uri.parse(url),
        headers: {'User-Agent': 'ESP32NavApp/2.0'},
      ).timeout(const Duration(seconds: 4));

      // Fallback
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        final fallbackUrl = isDark
            ? 'https://api.maptiler.com/maps/streets-v2-dark/256/$z/$x/$y.png?key=dtGJ2HGvyxQPKNlHznvY'
            : 'https://api.maptiler.com/maps/bright-v2/256/$z/$x/$y.png?key=dtGJ2HGvyxQPKNlHznvY';
        response = await http.get(
          Uri.parse(fallbackUrl),
          headers: {'User-Agent': 'ESP32NavApp/2.0'},
        ).timeout(const Duration(seconds: 4));
      }

      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        final codec = await ui.instantiateImageCodec(response.bodyBytes);
        final frame = await codec.getNextFrame();
        _tileCache[key] = frame.image;

        if (_tileCache.length > 100) {
          final firstKey = _tileCache.keys.first;
          _tileCache.remove(firstKey)?.dispose();
        }

        // Trigger immediate redraw so map is updated as soon as tile loads
        _latestJpegBytes = null;
        notifyListeners();
      }
    } catch (_) {
    } finally {
      _pendingTileFetches.remove(key);
    }
  }

  /// Draw Real Street Map Canvas with Rotating Map & Overlaid Route Polyline
  void _drawRealMapCanvas({
    required Canvas canvas,
    required double w,
    required double h,
    required LatLng userPos,
    required double headingDeg,
    required NavRoute? activeRoute,
    required double distToTurn,
    required double speedKmh,
  }) {
    final isDark = _streamMapStyle.contains('dark');

    // 1. Background Fill: Clean Light Cream for Apple Maps / Goong (#F4F6F8) or Dark Navy (#0B111A)
    final bgPaint = Paint()..color = isDark ? const Color(0xFF0B111A) : const Color(0xFFEBF0F0);
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), bgPaint);

    // Vehicle screen anchor (lower center: x=72, y=140)
    final double cx = w / 2.0;
    final double cy = h * 0.67;

    // Dynamic Zoom level (14 to 18): controlled via simulator screen slider
    final int zoom = _minimapZoom;
    final double n = math.pow(2.0, zoom).toDouble();
    final double latRad = userPos.latitude * (math.pi / 180.0);
    final double worldX = (userPos.longitude + 180.0) / 360.0 * n * 256.0;
    final double worldY = (1.0 - (math.log(math.tan(latRad) + 1.0 / math.cos(latRad)) / math.pi)) / 2.0 * n * 256.0;

    final int centerTileX = (worldX / 256.0).floor();
    final int centerTileY = (worldY / 256.0).floor();
    final double subTileX = worldX - (centerTileX * 256.0);
    final double subTileY = worldY - (centerTileY * 256.0);

    final double headingRad = headingDeg * (math.pi / 180.0);

    // --- DRAW ROTATING MAP TILES & ROUTE ---
    canvas.save();
    canvas.translate(cx, cy);
    canvas.rotate(-headingRad);

    bool tilesDrawn = false;
    for (int dx = -2; dx <= 2; dx++) {
      for (int dy = -2; dy <= 2; dy++) {
        final tx = centerTileX + dx;
        final ty = centerTileY + dy;
        final key = '$zoom/$tx/$ty';

        final tileImg = _tileCache[key];
        if (tileImg != null) {
          final double drawX = (dx * 256.0) - subTileX;
          final double drawY = (dy * 256.0) - subTileY;
          canvas.drawImageRect(
            tileImg,
            Rect.fromLTWH(0, 0, tileImg.width.toDouble(), tileImg.height.toDouble()),
            Rect.fromLTWH(drawX, drawY, 256.0, 256.0),
            Paint()..filterQuality = FilterQuality.medium,
          );
          tilesDrawn = true;
        }
      }
    }

    // High-visibility clean placeholder if tiles still downloading
    if (!tilesDrawn) {
      final gridPaint = Paint()
        ..color = isDark ? const Color(0xFF1E2D42) : const Color(0xFFDDE3E3)
        ..strokeWidth = 1.0;
      for (double gx = -220; gx <= 220; gx += 32) {
        canvas.drawLine(Offset(gx, -220), Offset(gx, 220), gridPaint);
      }
      for (double gy = -220; gy <= 220; gy += 32) {
        canvas.drawLine(Offset(-220, gy), Offset(220, gy), gridPaint);
      }
    }

    // Draw Route Polyline whenever an active route or preview route exists
    final effectiveRoute = activeRoute ?? navManager?.previewRoute;
    final points = (effectiveRoute != null && effectiveRoute.polylinePoints.isNotEmpty)
        ? effectiveRoute.polylinePoints
        : <LatLng>[];

    if (points.length >= 2) {
      final routePath = ui.Path();
      bool first = true;

      for (final pt in points) {
        final double ptLatRad = pt.latitude * (math.pi / 180.0);
        final double ptWorldX = (pt.longitude + 180.0) / 360.0 * n * 256.0;
        final double ptWorldY = (1.0 - (math.log(math.tan(ptLatRad) + 1.0 / math.cos(ptLatRad)) / math.pi)) / 2.0 * n * 256.0;

        final double px = ptWorldX - worldX;
        final double py = ptWorldY - worldY;

        if (first) {
          routePath.moveTo(px, py);
          first = false;
        } else {
          routePath.lineTo(px, py);
        }
      }

      // Route Outer Glow / Casing (Vibrant Apple Blue Casing #0051B3)
      final casingPaint = Paint()
        ..color = isDark ? const Color(0xFF003D66) : const Color(0xFF0051B3)
        ..strokeWidth = 8.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      canvas.drawPath(routePath, casingPaint);

      // Route Core: Apple Maps Vibrant Blue (#007AFF)
      final corePaint = Paint()
        ..color = isDark ? const Color(0xFF00F0FF) : const Color(0xFF007AFF)
        ..strokeWidth = 5.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      canvas.drawPath(routePath, corePaint);

      // Destination Pin on Route
      final destPt = points.last;
      final double destLatRad = destPt.latitude * (math.pi / 180.0);
      final double destWorldX = (destPt.longitude + 180.0) / 360.0 * n * 256.0;
      final double destWorldY = (1.0 - (math.log(math.tan(destLatRad) + 1.0 / math.cos(destLatRad)) / math.pi)) / 2.0 * n * 256.0;
      final double dpx = destWorldX - worldX;
      final double dpy = destWorldY - worldY;
      if (dpx.abs() < 240 && dpy.abs() < 240) {
        canvas.drawCircle(Offset(dpx, dpy), 8, Paint()..color = const Color(0xFFFF3B30));
        canvas.drawCircle(Offset(dpx, dpy), 4, Paint()..color = Colors.white);
      }
    }

    canvas.restore();

    // 2. Navigation Vehicle Indicator (Stationary at center cx, cy pointing straight UP)
    final vehicleColor = isDark ? const Color(0xFF00F0FF) : const Color(0xFF007AFF);
    final radarRing = Paint()
      ..color = vehicleColor.withAlpha(45)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(cx, cy), 16, radarRing);

    final vehicleBg = Paint()
      ..color = vehicleColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(cx, cy), 10, vehicleBg);

    final vehicleBorder = Paint()
      ..color = Colors.white
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(Offset(cx, cy), 10, vehicleBorder);

    // Direction Arrow pointing straight UP
    final arrowPath = ui.Path()
      ..moveTo(cx, cy - 7)
      ..lineTo(cx + 4.5, cy + 4)
      ..lineTo(cx, cy + 1.5)
      ..lineTo(cx - 4.5, cy + 4)
      ..close();
    final arrowPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    canvas.drawPath(arrowPath, arrowPaint);
  }

  /// Send JPEG frame over BLE in MTU-safe sequential chunks with micro-pacing
  Future<void> _sendJpegOverBle(Uint8List jpegBytes) async {
    if (!bleService.isConnected || _isSendingBle) return;
    _isSendingBle = true;

    try {
      final chunkSize = bleService.safeChunkSize;
      final totalLen = jpegBytes.length;
      final totalChunks = (totalLen / chunkSize).ceil();
      final frameId = (_frameCount % 255);

      for (int i = 0; i < totalChunks; i++) {
        if (!bleService.isConnected || !_isStreaming || !_isForeground) break;

        final start = i * chunkSize;
        final end = (start + chunkSize > totalLen) ? totalLen : start + chunkSize;
        final slice = jpegBytes.sublist(start, end);

        // Packet format: [0xAA, 0xBB, frameId, totalChunks, chunkIdx, ...bytes]
        final packet = Uint8List(5 + slice.length);
        packet[0] = 0xAA;
        packet[1] = 0xBB;
        packet[2] = frameId;
        packet[3] = totalChunks;
        packet[4] = i;
        packet.setRange(5, 5 + slice.length, slice);

        final success = await bleService.sendRawBytes(packet);
        if (!success) break;
        if (i < totalChunks - 1) {
          await Future.delayed(const Duration(milliseconds: 3));
        }
      }
    } catch (_) {
    } finally {
      _isSendingBle = false;
    }
  }

  /// Pause streaming temporarily (alias for backward compatibility)
  void pauseForDuration(Duration duration) => pauseStreamingFor(duration);

  /// Stop Streaming
  void stopStreaming() {
    _isStreaming = false;
    _isCapturing = false;
    _streamTimer?.cancel();
    _streamTimer = null;
    _pauseTimer?.cancel();
    _pauseTimer = null;
    _actualFps = 0.0;
    notifyListeners();
  }
}
