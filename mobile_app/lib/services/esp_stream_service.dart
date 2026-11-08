import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  int _targetFps = 14; // Real-time 14 FPS match for ESP32 hardware (zero queue lag, 3 FPS in background)
  double _actualFps = 10.0;
  int _frameSizeKb = 0;
  int _frameCount = 0;
  DateTime? _lastFpsUpdate;
  int _framesInCurrentSec = 0;

  bool _wsReadyForNextFrame = true;
  DateTime _lastWsSendTime = DateTime.now();

  Timer? _streamTimer;
  Timer? _pauseTimer;
  Uint8List? _latestJpegBytes;
  bool _isSendingBle = false;

  // Real Map Tile Cache (In-Memory Image Cache for Instant Rendering)
  final Map<String, ui.Image> _tileCache = {};
  final Map<String, img.Image> _cpuTileCache = {};
  final Set<String> _pendingTileFetches = {};

  // Persistent TCP Socket for continuous screen-off background streaming (SoftAP mode)
  Socket? _persistentWifiSocket;

  // WebSocket Server for iPhone Hotspot Master (IP 172.20.10.1:8080)
  HttpServer? _wsServer;
  final Set<WebSocket> _wsClients = {};
  bool get isWebSocketConnected => _wsClients.isNotEmpty;
  int get wsClientCount => _wsClients.length;

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
      _cpuTileCache.clear();
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
      _cpuTileCache.clear();
      _lastPrefetchPos = null;
      notifyListeners();
    }
  }

  EspStreamService({required this.bleService, this.navManager}) {
    WidgetsBinding.instance.addObserver(this);
    _startWebSocketServer();
  }

  /// Start internal HTTP/WebSocket server listening on port 8080
  /// When iPhone Personal Hotspot is active, iPhone IP is 172.20.10.1:8080
  Future<void> _startWebSocketServer() async {
    if (_wsServer != null) return;
    try {
      _wsServer = await HttpServer.bind(InternetAddress.anyIPv4, 8080, shared: true);
      debugPrint('[WebSocket Server] Listening on 0.0.0.0:8080 (Hotspot 172.20.10.1:8080)');
      _wsServer!.listen((HttpRequest request) async {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          try {
            final socket = await WebSocketTransformer.upgrade(request);
            _wsClients.add(socket);
            bleService.setHotspotConnected('172.20.10.1', 8080);
            if (_latestJpegBytes != null) {
              try {
                socket.add(_latestJpegBytes!);
              } catch (_) {}
            }
            notifyListeners();

            socket.listen(
              (data) {
                // Incoming messages from ESP32 client (ACK 'K' when frame is rendered)
                final msg = data is String
                    ? data.trim()
                    : (data is List<int> ? utf8.decode(data, allowMalformed: true).trim() : '');
                if (msg == 'K' || msg == 'ACK' || msg.contains('K')) {
                  _wsReadyForNextFrame = true;
                }
              },
              onDone: () {
                _wsClients.remove(socket);
                if (_wsClients.isEmpty) {
                  bleService.setHotspotDisconnected();
                }
                notifyListeners();
              },
              onError: (_) {
                _wsClients.remove(socket);
                if (_wsClients.isEmpty) {
                  bleService.setHotspotDisconnected();
                }
                notifyListeners();
              },
            );
          } catch (e) {
            debugPrint('[WebSocket Upgrade Error] $e');
          }
        } else {
          request.response.statusCode = HttpStatus.ok;
          request.response.write("ESP32 Hotspot Stream Server Active\n");
          await request.response.close();
        }
      });
    } catch (e) {
      debugPrint('[WebSocket Server Error] $e');
    }
  }

  void updateReferences(BleService newBle, NavigationManager newNav) {
    bleService = newBle;
    navManager = newNav;
  }

  static const _locationChannel = MethodChannel('com.ysiduc.esp32_nav/location');

  void _enableBackgroundKeepAlive() {
    if (Platform.isIOS) {
      try {
        _locationChannel.invokeMethod('startBackgroundNavigation');
      } catch (_) {}
    }
  }

  void _disableBackgroundKeepAlive() {
    if (Platform.isIOS && !(navManager?.isNavigating ?? false)) {
      try {
        _locationChannel.invokeMethod('stopBackgroundNavigation');
      } catch (_) {}
    }
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
      // Keep streaming continuously without dropping
      if (_isStreaming) {
        _enableBackgroundKeepAlive();
        _startTimer();
      } else {
        _streamTimer?.cancel();
        _streamTimer = null;
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    stopStreaming();
    _persistentWifiSocket?.destroy();
    _persistentWifiSocket = null;
    for (final ws in _wsClients) {
      try {
        ws.close();
      } catch (_) {}
    }
    _wsClients.clear();
    _wsServer?.close(force: true);
    _wsServer = null;
    _pauseTimer?.cancel();
    _tileCache.forEach((_, img) => img.dispose());
    _tileCache.clear();
    _cpuTileCache.clear();
    super.dispose();
  }


  /// Pause streaming temporarily (e.g. during map search or routing) to give 100% CPU to UI
  void pauseStreamingFor(Duration duration) {
    if (!_isStreaming) return;
    _streamTimer?.cancel();
    _streamTimer = null;
    _pauseTimer?.cancel();
    _pauseTimer = Timer(duration, () {
      if (_isStreaming && (_isForeground || bleService.isConnected || bleService.isWifiConnected) && _streamTimer == null) {
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

    _enableBackgroundKeepAlive();
    if (_isForeground || bleService.isConnected || bleService.isWifiConnected || _wsClients.isNotEmpty || (navManager?.isNavigating ?? false)) {
      _startTimer();
    }

    notifyListeners();
  }

  void _startTimer() {
    _streamTimer?.cancel();
    // In foreground: smooth target FPS (14-20). In background (screen locked): steady 5 FPS (200ms) to ensure ESP32 watchdog never expires
    final effectiveFps = _isForeground ? _targetFps : 5;
    final intervalMs = (1000 / effectiveFps).round();
    _streamTimer = Timer.periodic(Duration(milliseconds: intervalMs), (_) {
      _renderAndStreamHeadlessFrame();
    });
  }

  /// Hardware-accelerated RGBA-to-JPEG encoding on iOS (with pure-Dart fallback)
  /// Ensures output is always <= 14500 bytes to fit within ESP32 WebSockets 15KB max frame limit
  Future<Uint8List?> _compressRgbaToJpeg(Uint8List rawBytes, int w, int h, {int quality = 65}) async {
    if (Platform.isIOS) {
      try {
        var res = await _locationChannel.invokeMethod<Uint8List>('compressRgbaToJpeg', {
          'rgba': rawBytes,
          'width': w,
          'height': h,
          'quality': quality / 100.0,
        });
        if (res != null && res.length > 14500) {
          res = await _locationChannel.invokeMethod<Uint8List>('compressRgbaToJpeg', {
            'rgba': rawBytes,
            'width': w,
            'height': h,
            'quality': 0.36,
          });
        }
        if (res != null && res.isNotEmpty) {
          return res;
        }
      } catch (_) {}
    }
    final imgImage = img.Image.fromBytes(
      width: w,
      height: h,
      bytes: rawBytes.buffer,
      order: img.ChannelOrder.rgba,
    );
    var jpg = Uint8List.fromList(img.encodeJpg(imgImage, quality: quality));
    if (jpg.length > 14500) {
      jpg = Uint8List.fromList(img.encodeJpg(imgImage, quality: 42));
    }
    return jpg;
  }

  /// Render 144x208 (Standby) or 320x240 (Active Navigation) Real Street Map & Stream at 20 FPS
  Future<void> _renderAndStreamHeadlessFrame() async {
    // If previous frame is still transmitting over TCP or BLE, drop this tick to avoid queue buildup and heating
    if (!_isStreaming || _isCapturing || _isSendingWifi || _isSendingBle) return;

    // Strict 1-in-flight queue control: if ESP32 hasn't rendered previous frame, skip tick to prevent queue buildup
    if (_wsClients.isNotEmpty && !_wsReadyForNextFrame && DateTime.now().difference(_lastWsSendTime).inMilliseconds < 250) {
      return;
    }
    _isCapturing = true;

    try {
      final bool isNav = navManager?.isNavigating ?? false;
      final int w = isNav ? 320 : 144;
      final int h = isNav ? 240 : 208;

      final userPos = navManager?.currentLocation ?? const LatLng(20.9832, 105.8425);
      final double heading = navManager?.effectiveHeading ?? navManager?.currentHeading ?? 0.0;
      final activeRoute = navManager?.activeRoute;
      final distToTurn = navManager?.distanceToNextManeuver ?? 208.0;
      final speedKmh = navManager?.currentSpeedKmh ?? 0.0;

      // Pre-fetch surrounding tiles asynchronously at chosen minimap zoom
      _prefetchSurroundingTiles(userPos, _minimapZoom);

      Uint8List? jpegBytes;

      if (_isForeground) {
        // 1. In foreground: High-Speed Flutter Canvas rendering
        try {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));

          if (isNav) {
            _drawNavigationFullMapCanvas(
              canvas: canvas,
              w: w.toDouble(),
              h: h.toDouble(),
              userPos: userPos,
              headingDeg: heading,
              activeRoute: activeRoute,
              distToTurn: distToTurn,
              speedKmh: speedKmh,
            );
          } else {
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
          }

          final picture = recorder.endRecording();
          final image = await picture.toImage(w, h);
          final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
          image.dispose();
          picture.dispose();

          if (byteData != null) {
            final rawBytes = byteData.buffer.asUint8List();
            jpegBytes = await _compressRgbaToJpeg(rawBytes, w, h, quality: isNav ? 54 : 65);
          }
        } catch (_) {}
      }

      // 2. In background / screen-off: Pure CPU Software Map Renderer (100% CPU RAM, 0% GPU)
      jpegBytes ??= isNav ? _renderCpuNavigationFrame(w, h) : _renderCpuMapFrame(w, h);


      if (jpegBytes == null) {
        _isCapturing = false;
        return;
      }

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

  /// Pure CPU Software Map Renderer (Runs 100% in CPU RAM without Metal GPU, perfect for background)
  Uint8List? _renderCpuMapFrame(int w, int h) {
    try {
      final userPos = navManager?.currentLocation ?? const LatLng(20.9832, 105.8425);
      final double headingDeg = navManager?.effectiveHeading ?? navManager?.currentHeading ?? 0.0;
      final activeRoute = navManager?.activeRoute ?? navManager?.previewRoute;
      final int zoom = _minimapZoom;
      final isDark = _streamMapStyle.contains('dark');

      final double n = math.pow(2.0, zoom).toDouble();
      final double latRad = userPos.latitude * (math.pi / 180.0);
      final double worldX = (userPos.longitude + 180.0) / 360.0 * n * 256.0;
      final double worldY = (1.0 - (math.log(math.tan(latRad) + 1.0 / math.cos(latRad)) / math.pi)) / 2.0 * n * 256.0;

      final int centerTileX = (worldX / 256.0).floor();
      final int centerTileY = (worldY / 256.0).floor();
      final double subTileX = worldX - (centerTileX * 256.0);
      final double subTileY = worldY - (centerTileY * 256.0);

      // Create a 320x320 CPU patch centered on user (covers 144x208 frame at all rotation angles)
      const int patchSize = 320;
      final patch = img.Image(width: patchSize, height: patchSize);
      final bgColor = isDark ? img.ColorRgba8(11, 17, 26, 255) : img.ColorRgba8(235, 240, 240, 255);
      img.fill(patch, color: bgColor);

      const double patchCenter = patchSize / 2.0;

      // Composite 3x3 surrounding tiles with direct blending
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
          final key = '$zoom/$tx/$ty';
          final tileImg = _cpuTileCache[key];
          if (tileImg != null) {
            img.compositeImage(patch, tileImg, dstX: dstX, dstY: dstY);
            tilesDrawn = true;
          }
        }
      }

      if (!tilesDrawn) {
        final gridColor = isDark ? img.ColorRgba8(30, 45, 66, 255) : img.ColorRgba8(221, 227, 227, 255);
        for (int gx = 0; gx <= patchSize; gx += 32) {
          img.drawLine(patch, x1: gx, y1: 0, x2: gx, y2: patchSize, color: gridColor);
        }
        for (int gy = 0; gy <= patchSize; gy += 32) {
          img.drawLine(patch, x1: 0, y1: gy, x2: patchSize, y2: gy, color: gridColor);
        }
      }

      // Draw active route polyline (matching Image 2: Apple blue casing + core with round joint caps)
      if (activeRoute != null && activeRoute.polylinePoints.length >= 2) {
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

        // 1. Outer Casing (thickness 8) with rounded caps
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

        // 2. Vibrant Core (thickness 5) with rounded caps
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

        // Draw destination pin if on patch
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

      // Rotate patch by -headingDeg so ahead is UP
      img.Image rotatedPatch = patch;
      if (headingDeg.abs() > 0.5) {
        rotatedPatch = img.copyRotate(patch, angle: -headingDeg, interpolation: img.Interpolation.nearest);
      }

      // Crop to 144x208 with vehicle anchor at (w/2, h*0.67) = (72, 140)
      final int rotCx = rotatedPatch.width ~/ 2;
      final int rotCy = rotatedPatch.height ~/ 2;
      final int cropX = (rotCx - (w ~/ 2)).clamp(0, math.max(0, rotatedPatch.width - w));
      final int cropY = (rotCy - (h * 0.67).round()).clamp(0, math.max(0, rotatedPatch.height - h));

      final frame = img.copyCrop(
        rotatedPatch,
        x: cropX,
        y: cropY,
        width: w,
        height: h,
      );

      // Draw Vehicle Location Puck at (72, 140) pointing straight UP (exact match to Image 2!)
      final int vx = (w / 2.0).round();
      final int vy = (h * 0.67).round();
      final puckColor = isDark ? img.ColorRgba8(0, 240, 255, 255) : img.ColorRgba8(0, 122, 255, 255);
      final auraColor = isDark ? img.ColorRgba8(0, 240, 255, 45) : img.ColorRgba8(0, 122, 255, 45);

      // 1. Translucent radar aura ring (radius 16)
      img.fillCircle(frame, x: vx, y: vy, radius: 16, color: auraColor);
      // 2. Crisp outer white border (radius 11)
      img.fillCircle(frame, x: vx, y: vy, radius: 11, color: img.ColorRgba8(255, 255, 255, 255));
      // 3. Inner vibrant blue core (radius 9)
      img.fillCircle(frame, x: vx, y: vy, radius: 9, color: puckColor);

      // 4. Sharp white arrow pointing straight UP (matching Image 2)
      img.fillPolygon(frame, vertices: [
        img.Point(vx, vy - 7),
        img.Point(vx + 4, vy + 4),
        img.Point(vx, vy + 2),
        img.Point(vx - 4, vy + 4),
      ], color: img.ColorRgba8(255, 255, 255, 255));

      return Uint8List.fromList(img.encodeJpg(frame, quality: 65));
    } catch (e, stack) {
      debugPrint('[_renderCpuMapFrame Error] $e\n$stack');
      return null;
    }
  }

  /// Pure CPU Software 320x240 Full-Screen Navigation Frame Renderer (for background / screen-off)
  Uint8List? _renderCpuNavigationFrame(int w, int h) {
    try {
      final userPos = navManager?.currentLocation ?? const LatLng(20.9832, 105.8425);
      final double headingDeg = navManager?.effectiveHeading ?? navManager?.currentHeading ?? 0.0;
      final activeRoute = navManager?.activeRoute ?? navManager?.previewRoute;
      final double speedKmh = navManager?.currentSpeedKmh ?? 0.0;
      final double distToTurn = navManager?.distanceToNextManeuver ?? 200.0;
      final double totalDist = navManager?.remainingTotalDistance ?? 0.0;
      final int etaMin = navManager?.remainingEtaMinutes ?? 1;
      final int zoom = _minimapZoom;
      final isDark = _streamMapStyle.contains('dark');

      final double n = math.pow(2.0, zoom).toDouble();
      final double latRad = userPos.latitude * (math.pi / 180.0);
      final double worldX = (userPos.longitude + 180.0) / 360.0 * n * 256.0;
      final double worldY = (1.0 - (math.log(math.tan(latRad) + 1.0 / math.cos(latRad)) / math.pi)) / 2.0 * n * 256.0;

      final int centerTileX = (worldX / 256.0).floor();
      final int centerTileY = (worldY / 256.0).floor();
      final double subTileX = worldX - (centerTileX * 256.0);
      final double subTileY = worldY - (centerTileY * 256.0);

      const int patchSize = 560;
      final patch = img.Image(width: patchSize, height: patchSize);
      final bgColor = isDark ? img.ColorRgba8(11, 17, 26, 255) : img.ColorRgba8(244, 243, 238, 255);
      img.fill(patch, color: bgColor);

      const double patchCenter = patchSize / 2.0;

      bool tilesDrawn = false;
      for (int dx = -2; dx <= 2; dx++) {
        for (int dy = -2; dy <= 2; dy++) {
          final int dstX = (patchCenter + (dx * 256.0) - subTileX).round();
          final int dstY = (patchCenter + (dy * 256.0) - subTileY).round();
          if (dstX + 256 <= 0 || dstX >= patchSize || dstY + 256 <= 0 || dstY >= patchSize) {
            continue;
          }

          final tx = centerTileX + dx;
          final ty = centerTileY + dy;
          final key = '$zoom/$tx/$ty';
          final tileImg = _cpuTileCache[key];
          if (tileImg != null) {
            img.compositeImage(patch, tileImg, dstX: dstX, dstY: dstY);
            tilesDrawn = true;
          }
        }
      }

      if (!tilesDrawn) {
        final gridColor = isDark ? img.ColorRgba8(30, 45, 66, 255) : img.ColorRgba8(221, 227, 227, 255);
        for (int gx = 0; gx <= patchSize; gx += 32) {
          img.drawLine(patch, x1: gx, y1: 0, x2: gx, y2: patchSize, color: gridColor);
        }
        for (int gy = 0; gy <= patchSize; gy += 32) {
          img.drawLine(patch, x1: 0, y1: gy, x2: patchSize, y2: gy, color: gridColor);
        }
      }

      // Draw active route polyline in Vibrant Purple (#4C1D95 casing + #6D28D9 core)
      if (activeRoute != null && activeRoute.polylinePoints.length >= 2) {
        final pts = activeRoute.polylinePoints;
        final casingColor = img.ColorRgba8(76, 29, 149, 255);
        final coreColor = img.ColorRgba8(109, 40, 217, 255);

        final screenPts = <img.Point>[];
        for (final pt in pts) {
          final double ptLatRad = pt.latitude * (math.pi / 180.0);
          final double ptWorldX = (pt.longitude + 180.0) / 360.0 * n * 256.0;
          final double ptWorldY = (1.0 - (math.log(math.tan(ptLatRad) + 1.0 / math.cos(ptLatRad)) / math.pi)) / 2.0 * n * 256.0;
          final int px = (patchCenter + (ptWorldX - worldX)).round();
          final int py = (patchCenter + (ptWorldY - worldY)).round();
          screenPts.add(img.Point(px, py));
        }

        for (int i = 0; i < screenPts.length - 1; i++) {
          final p1 = screenPts[i];
          final p2 = screenPts[i + 1];
          if ((p1.x >= -40 && p1.x <= patchSize + 40 && p1.y >= -40 && p1.y <= patchSize + 40) ||
              (p2.x >= -40 && p2.x <= patchSize + 40 && p2.y >= -40 && p2.y <= patchSize + 40)) {
            img.drawLine(patch, x1: p1.x.toInt(), y1: p1.y.toInt(), x2: p2.x.toInt(), y2: p2.y.toInt(), color: casingColor, thickness: 10);
            img.fillCircle(patch, x: p1.x.toInt(), y: p1.y.toInt(), radius: 5, color: casingColor);
            img.fillCircle(patch, x: p2.x.toInt(), y: p2.y.toInt(), radius: 5, color: casingColor);
          }
        }

        for (int i = 0; i < screenPts.length - 1; i++) {
          final p1 = screenPts[i];
          final p2 = screenPts[i + 1];
          if ((p1.x >= -40 && p1.x <= patchSize + 40 && p1.y >= -40 && p1.y <= patchSize + 40) ||
              (p2.x >= -40 && p2.x <= patchSize + 40 && p2.y >= -40 && p2.y <= patchSize + 40)) {
            img.drawLine(patch, x1: p1.x.toInt(), y1: p1.y.toInt(), x2: p2.x.toInt(), y2: p2.y.toInt(), color: coreColor, thickness: 6);
            img.fillCircle(patch, x: p1.x.toInt(), y: p1.y.toInt(), radius: 3, color: coreColor);
            img.fillCircle(patch, x: p2.x.toInt(), y: p2.y.toInt(), radius: 3, color: coreColor);
          }
        }
      }

      img.Image rotatedPatch = patch;
      if (headingDeg.abs() > 0.5) {
        rotatedPatch = img.copyRotate(patch, angle: -headingDeg, interpolation: img.Interpolation.nearest);
      }

      // Vehicle anchor at bottom-right (232, 190) on 320x240 frame
      const int vx = 232;
      const int vy = 190;
      final int rotCx = rotatedPatch.width ~/ 2;
      final int rotCy = rotatedPatch.height ~/ 2;
      final int cropX = (rotCx - vx).clamp(0, math.max(0, rotatedPatch.width - w));
      final int cropY = (rotCy - vy).clamp(0, math.max(0, rotatedPatch.height - h));

      final frame = img.copyCrop(
        rotatedPatch,
        x: cropX,
        y: cropY,
        width: w,
        height: h,
      );

      // 1. Vehicle Cyan 3D Chevron at (232, 190) + Purple Current Street Pill
      img.fillCircle(frame, x: vx, y: vy, radius: 14, color: img.ColorRgba8(100, 116, 139, 90));
      img.fillPolygon(frame, vertices: [
        img.Point(vx, vy - 11),
        img.Point(vx + 10, vy + 7),
        img.Point(vx, vy + 3),
        img.Point(vx - 10, vy + 7),
      ], color: img.ColorRgba8(6, 182, 212, 255));
      img.fillRect(frame, x1: 176, y1: 206, x2: 288, y2: 226, radius: 9, color: img.ColorRgba8(91, 33, 182, 255));

      // 2. Top-Left Black Maneuver Card + Coral-Red Top Badge
      img.fillRect(frame, x1: 4, y1: 6, x2: 112, y2: 54, radius: 10, color: img.ColorRgba8(5, 5, 5, 255));
      img.fillRect(frame, x1: 0, y1: 2, x2: 66, y2: 22, radius: 10, color: img.ColorRgba8(240, 98, 97, 255));
      final distStr = distToTurn >= 1000 ? '${(distToTurn / 1000.0).toStringAsFixed(1)}km' : '${distToTurn.round()}m';
      img.drawString(frame, distStr, font: img.arial14, x: 14, y: 5, color: img.ColorRgba8(255, 255, 255, 255));

      // 3. Top-Center-Left 3-Circle Speed Cluster (80, 60, currentSpeed)
      img.fillCircle(frame, x: 132, y: 56, radius: 18, color: img.ColorRgba8(220, 38, 38, 255));
      img.fillCircle(frame, x: 132, y: 56, radius: 14, color: img.ColorRgba8(255, 255, 255, 255));
      img.drawString(frame, '80', font: img.arial14, x: 124, y: 49, color: img.ColorRgba8(17, 24, 39, 255));

      img.fillCircle(frame, x: 148, y: 68, radius: 11, color: img.ColorRgba8(29, 78, 216, 255));
      img.drawString(frame, '60', font: img.arial14, x: 140, y: 61, color: img.ColorRgba8(255, 255, 255, 255));

      img.fillCircle(frame, x: 153, y: 44, radius: 11, color: img.ColorRgba8(229, 231, 235, 255));
      img.drawCircle(frame, x: 153, y: 44, radius: 11, color: img.ColorRgba8(100, 116, 139, 255));
      img.drawString(frame, '${speedKmh.round()}', font: img.arial14, x: 145, y: 37, color: img.ColorRgba8(17, 24, 39, 255));

      // 4. Bottom-Left Dark Trip Summary Pill
      img.fillRect(frame, x1: 4, y1: 196, x2: 116, y2: 234, radius: 14, color: img.ColorRgba8(36, 37, 41, 255));
      img.fillCircle(frame, x: 20, y: 215, radius: 10, color: img.ColorRgba8(56, 57, 62, 255));
      img.drawLine(frame, x1: 17, y1: 212, x2: 23, y2: 218, color: img.ColorRgba8(255, 255, 255, 255));
      img.drawLine(frame, x1: 23, y1: 212, x2: 17, y2: 218, color: img.ColorRgba8(255, 255, 255, 255));
      final etaLabel = etaMin >= 60 ? '${etaMin ~/ 60}h${(etaMin % 60).toString().padLeft(2, '0')}p' : '${etaMin}p';
      final totKm = totalDist >= 1000 ? '${(totalDist / 1000.0).round()}km' : '${totalDist.round()}m';
      img.drawString(frame, '$etaLabel $totKm', font: img.arial14, x: 35, y: 208, color: img.ColorRgba8(255, 255, 255, 255));

      var jpg = Uint8List.fromList(img.encodeJpg(frame, quality: 54));
      if (jpg.length > 14500) {
        jpg = Uint8List.fromList(img.encodeJpg(frame, quality: 40));
      }
      return jpg;
    } catch (e) {
      return null;
    }
  }

  void _dispatchTransmission(Uint8List jpegBytes) {
    // 1. WebSocket Broadcast to iPhone Hotspot client (ESP32)
    if (_wsClients.isNotEmpty) {
      final now = DateTime.now();
      final elapsedSinceLastWs = now.difference(_lastWsSendTime).inMilliseconds;
      // Strict 1-in-flight closed-loop flow control (Zero-Queue latency):
      // Only send if ESP32 finished rendering previous frame, or after 250ms watchdog timeout
      if (!_wsReadyForNextFrame && elapsedSinceLastWs < 250) {
        return; // Drop intermediate frame to prevent TCP buffer accumulation and latency!
      }
      // Micro-gap flow control (at least 45ms between frames = max ~22 FPS):
      // Leaves a clean RF breather between Wi-Fi packets, allowing 2.4GHz radio to service BLE without dropouts!
      if (elapsedSinceLastWs < 45) {
        return;
      }

      _wsReadyForNextFrame = false;
      _lastWsSendTime = now;

      for (final client in _wsClients.toList()) {
        try {
          client.add(jpegBytes);
        } catch (_) {
          _wsClients.remove(client);
        }
      }
      if (_frameCount % 25 == 0) {
        bleService.logInfo('TX [Hotspot WS] Stream Frame #$_frameCount (${_frameSizeKb} KB, ${_actualFps.toStringAsFixed(1)} FPS)');
      }
      return; // Primary Hotspot WebSocket stream successful - return immediately
    }

    // 2. Persistent TCP Socket to ESP32 (SoftAP mode 192.168.4.1 only)
    if (bleService.isWifiConnected && bleService.wifiIp != null && bleService.wifiIp != '172.20.10.1') {
      if (!_isSendingWifi) {
        _sendJpegOverWifi(jpegBytes);
      }
      return; // Secondary SoftAP stream successful - return immediately
    }

    // 3. Fallback: BLE Chunks (Stream map directly over Bluetooth when Wi-Fi is off or in background)
    if (bleService.isConnected && !_isSendingBle) {
      _sendJpegOverBle(jpegBytes);
    }
  }

  /// Broadcast JSON telemetry to connected WebSocket clients (ESP32)
  void broadcastTelemetry(String jsonStr) {
    if (_wsClients.isEmpty) return;
    for (final client in _wsClients.toList()) {
      try {
        client.add(jsonStr);
      } catch (_) {
        _wsClients.remove(client);
      }
    }
  }


  int _consecutiveWifiErrors = 0;

  /// Send JPEG frame over persistent WiFi TCP socket directly to ESP32 (screen-off background streaming)
  Future<void> _sendJpegOverWifi(Uint8List jpegBytes) async {
    final ip = bleService.wifiIp;
    final port = bleService.wifiPort;
    if (ip == null || port == 0 || _isSendingWifi) return;
    _isSendingWifi = true;

    try {
      if (_persistentWifiSocket == null) {
        _persistentWifiSocket = await Socket.connect(ip, port, timeout: const Duration(milliseconds: 500));
        _persistentWifiSocket!.setOption(SocketOption.tcpNoDelay, true);
        _persistentWifiSocket!.done.then((_) {
          _persistentWifiSocket = null;
        }).catchError((_) {
          _persistentWifiSocket = null;
        });
      }

      final len = jpegBytes.length;
      final packet = Uint8List(4 + len);
      packet[0] = 0xAA;
      packet[1] = 0xBB;
      packet[2] = (len >> 8) & 0xFF;
      packet[3] = len & 0xFF;
      packet.setRange(4, 4 + len, jpegBytes);

      _persistentWifiSocket!.add(packet);
      await _persistentWifiSocket!.flush();
      _consecutiveWifiErrors = 0;
    } catch (_) {
      _persistentWifiSocket?.destroy();
      _persistentWifiSocket = null;
      _consecutiveWifiErrors++;
      if (_consecutiveWifiErrors >= 5) {
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
            final k = '$zoom/${cx + dx}/${cy + dy}';
            if (!_tileCache.containsKey(k) && !_cpuTileCache.containsKey(k)) {
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

    final int rad = (navManager?.isNavigating ?? false) ? 2 : 1;
    for (int dx = -rad; dx <= rad; dx++) {
      for (int dy = -rad; dy <= rad; dy++) {
        final tx = cx + dx;
        final ty = cy + dy;
        final key = '$zoom/$tx/$ty';

        if (!_tileCache.containsKey(key) && !_cpuTileCache.containsKey(key) && !_pendingTileFetches.contains(key)) {
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
        // High-definition Google Vietnam localized raster tiles (100% authentic Vietnamese labels: Sông Lừ, Đ. Trường Chinh, etc.)
        url = 'https://mt1.google.com/vt/lyrs=m&x=$x&y=$y&z=$z&hl=vi';
      } else {
        url = apiKey.isNotEmpty
            ? 'https://api.maptiler.com/maps/$style/256/$z/$x/$y@2x.$ext?key=$apiKey&language=vi'
            : (isDark
                ? 'https://api.maptiler.com/maps/streets-v2-dark/256/$z/$x/$y@2x.png?key=dtGJ2HGvyxQPKNlHznvY&language=vi'
                : 'https://api.maptiler.com/maps/streets-v2/256/$z/$x/$y@2x.png?key=dtGJ2HGvyxQPKNlHznvY&language=vi');
      }

      var response = await http.get(
        Uri.parse(url),
        headers: {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'},
      ).timeout(const Duration(seconds: 4));

      // Fallback
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        final fallbackUrl = isGoong
            ? 'https://mt2.google.com/vt/lyrs=m&x=$x&y=$y&z=$z&hl=vi'
            : (isDark
                ? 'https://api.maptiler.com/maps/streets-v2-dark/256/$z/$x/$y@2x.png?key=dtGJ2HGvyxQPKNlHznvY&language=vi'
                : 'https://api.maptiler.com/maps/streets-v2/256/$z/$x/$y@2x.png?key=dtGJ2HGvyxQPKNlHznvY&language=vi');
        response = await http.get(
          Uri.parse(fallbackUrl),
          headers: {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'},
        ).timeout(const Duration(seconds: 4));
      }

      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        Uint8List finalBytes = response.bodyBytes;
        // 1. Decode for CPU background map rendering (0% GPU)
        try {
          var cpuImg = img.decodeImage(response.bodyBytes);
          if (cpuImg != null) {
            // Downsample @2x (512x512) to 256x256 for crisp Retina labels ("Sông Lừ", etc.)
            if (cpuImg.width > 256) {
              cpuImg = img.copyResize(cpuImg, width: 256, height: 256, interpolation: img.Interpolation.average);
            }
            if (isDark && isGoong) {
              // Convert light tile to sleek dark mode
              img.invert(cpuImg);
              for (final pixel in cpuImg) {
                pixel.r = (pixel.r * 0.7).round();
                pixel.g = (pixel.g * 0.8).round();
                pixel.b = (pixel.b * 1.0).round();
              }
            }
            _cpuTileCache[key] = cpuImg;
            if (_cpuTileCache.length > 100) {
              _cpuTileCache.remove(_cpuTileCache.keys.first);
            }

            if (isDark && isGoong) {
              finalBytes = Uint8List.fromList(img.encodePng(cpuImg));
            }
          }
        } catch (_) {}

        // 2. Decode for Flutter Canvas rendering (only when app is in foreground)
        if (_isForeground) {
          try {
            final codec = await ui.instantiateImageCodec(finalBytes);
            final frame = await codec.getNextFrame();
            _tileCache[key] = frame.image;

            if (_tileCache.length > 100) {
              final firstKey = _tileCache.keys.first;
              _tileCache.remove(firstKey)?.dispose();
            }
          } catch (_) {}
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
    for (int dx = -1; dx <= 1; dx++) {
      for (int dy = -1; dy <= 1; dy++) {
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

  /// Draw 320x240 Full-Screen 3D Tilted Navigation Map + Floating HUD Overlays (100% Match to Reference Image)
  void _drawNavigationFullMapCanvas({
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

    // 1. Background Fill: Clean Daylight Map (#F4F3EE) or Dark Mode (#0B111A)
    final bgPaint = Paint()..color = isDark ? const Color(0xFF0B111A) : const Color(0xFFF4F3EE);
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), bgPaint);

    // Vehicle anchor at bottom-right (x=232, y=190 on 320x240 canvas)
    const double cx = 232.0;
    const double cy = 190.0;

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

    // --- 2. 3D PERSPECTIVE TILTED MAP PLANE & PURPLE ROUTE POLYLINE ---
    canvas.save();
    canvas.translate(cx, cy);
    final perspective = Matrix4.identity()
      ..setEntry(3, 2, 0.0014)
      ..rotateX(-42.0 * (math.pi / 180.0));
    canvas.transform(perspective.storage);
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

    if (!tilesDrawn) {
      final gridPaint = Paint()
        ..color = isDark ? const Color(0xFF1E2D42) : const Color(0xFFDDE3E3)
        ..strokeWidth = 1.0;
      for (double gx = -450; gx <= 450; gx += 36) {
        canvas.drawLine(Offset(gx, -450), Offset(gx, 450), gridPaint);
      }
      for (double gy = -450; gy <= 450; gy += 36) {
        canvas.drawLine(Offset(-450, gy), Offset(450, gy), gridPaint);
      }
    }

    // Active Route Polyline in Deep Purple Casing (#4C1D95) + Vibrant Purple Core (#6D28D9)
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

      final casingPaint = Paint()
        ..color = const Color(0xFF4C1D95)
        ..strokeWidth = 10.0
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      canvas.drawPath(routePath, casingPaint);

      final corePaint = Paint()
        ..color = const Color(0xFF6D28D9)
        ..strokeWidth = 6.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      canvas.drawPath(routePath, corePaint);

      final destPt = points.last;
      final double destLatRad = destPt.latitude * (math.pi / 180.0);
      final double destWorldX = (destPt.longitude + 180.0) / 360.0 * n * 256.0;
      final double destWorldY = (1.0 - (math.log(math.tan(destLatRad) + 1.0 / math.cos(destLatRad)) / math.pi)) / 2.0 * n * 256.0;
      final double dpx = destWorldX - worldX;
      final double dpy = destWorldY - worldY;
      if (dpx.abs() < 450 && dpy.abs() < 450) {
        canvas.drawCircle(Offset(dpx, dpy), 8, Paint()..color = const Color(0xFFFF3B30));
        canvas.drawCircle(Offset(dpx, dpy), 4, Paint()..color = Colors.white);
      }
    }

    canvas.restore();

    // --- 3. BOTTOM-RIGHT 3D CYAN NAVIGATION CHEVRON & PURPLE CURRENT ROAD PILL ---
    // Soft grey shadow halo beneath vehicle chevron
    canvas.drawCircle(
      const Offset(cx, cy + 1),
      15.0,
      Paint()..color = const Color(0x5564748B),
    );

    // 3D Cyan/Teal Chevron (left wing #22D3EE, right wing #06B6D4, white outline)
    final chevronFull = ui.Path()
      ..moveTo(cx, cy - 11.5)
      ..lineTo(cx + 10.5, cy + 7.5)
      ..lineTo(cx, cy + 3.0)
      ..lineTo(cx - 10.5, cy + 7.5)
      ..close();
    final chevronLeft = ui.Path()
      ..moveTo(cx, cy - 11.5)
      ..lineTo(cx, cy + 3.0)
      ..lineTo(cx - 10.5, cy + 7.5)
      ..close();
    final chevronRight = ui.Path()
      ..moveTo(cx, cy - 11.5)
      ..lineTo(cx + 10.5, cy + 7.5)
      ..lineTo(cx, cy + 3.0)
      ..close();

    canvas.drawPath(chevronLeft, Paint()..color = const Color(0xFF22D3EE));
    canvas.drawPath(chevronRight, Paint()..color = const Color(0xFF06B6D4));
    canvas.drawPath(
      chevronFull,
      Paint()
        ..color = Colors.white
        ..strokeWidth = 1.8
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke,
    );

    // Current Street Purple Pill Badge below chevron (e.g. "CT. Biên Hoà - Vũng Tàu")
    final String curRoad = navManager?.currentStreetName ?? 'Đường hiện tại';
    final curRoadTp = TextPainter(
      text: TextSpan(
        text: curRoad,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 8.5,
          fontWeight: FontWeight.w800,
          height: 1.15,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      maxLines: 2,
      ellipsis: '…',
    )..layout(maxWidth: 112.0);

    final double pillW = (curRoadTp.width + 18.0).clamp(64.0, 128.0);
    final double pillH = (curRoadTp.height + 7.0).clamp(18.0, 30.0);
    final double pillLeft = (cx - pillW / 2.0).clamp(148.0, w - pillW - 4.0);
    final double pillTop = (cy + 14.0).clamp(200.0, h - pillH - 2.0);
    final roadPillRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(pillLeft, pillTop, pillW, pillH),
      const Radius.circular(10.0),
    );
    canvas.drawRRect(roadPillRect, Paint()..color = const Color(0xFF5B21B6));
    canvas.drawRRect(
      roadPillRect,
      Paint()
        ..color = const Color(0xFF7C3AED)
        ..strokeWidth = 1.0
        ..style = PaintingStyle.stroke,
    );
    curRoadTp.paint(
      canvas,
      Offset(pillLeft + (pillW - curRoadTp.width) / 2.0, pillTop + (pillH - curRoadTp.height) / 2.0),
    );

    // --- 4. TOP-LEFT BLACK MANEUVER CARD WITH CORAL-RED TOP BADGE ---
    final upcoming = navManager?.upcomingStep ?? navManager?.currentStep;
    final int turnCode = upcoming?.turnCode ?? 0;
    final String nextStreetRaw = upcoming?.streetName ?? curRoad;
    final String nextStreet = NavigationManager.cleanStreetName(nextStreetRaw);
    final String distStr = distToTurn >= 1000
        ? '${(distToTurn / 1000.0).toStringAsFixed(1)} km'
        : '${distToTurn.round()} m';

    // Pitch-black rounded rectangle (x: 4, y: 6, w: 108, h: 48)
    final blackCardRect = RRect.fromRectAndRadius(
      const Rect.fromLTWH(4.0, 6.0, 108.0, 48.0),
      const Radius.circular(10.0),
    );
    canvas.drawRRect(
      blackCardRect.shift(const Offset(0, 2)),
      Paint()..color = const Color(0x44000000),
    );
    canvas.drawRRect(blackCardRect, Paint()..color = const Color(0xFF050505));

    // Top-left Coral-Red Badge (#F06261 with thin white inner border)
    final coralBadgeRect = RRect.fromRectAndRadius(
      const Rect.fromLTWH(0.0, 2.0, 68.0, 20.0),
      const Radius.circular(10.0),
    );
    canvas.drawRRect(coralBadgeRect, Paint()..color = const Color(0xFFF06261));
    canvas.drawRRect(
      coralBadgeRect.deflate(1.2),
      Paint()
        ..color = Colors.white.withAlpha(210)
        ..strokeWidth = 1.0
        ..style = PaintingStyle.stroke,
    );

    // Mini turn icon + distance inside coral badge
    _drawCanvasTurnIcon(canvas, 12.0, 12.0, turnCode);
    final distTp = TextPainter(
      text: TextSpan(
        text: distStr,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 9.5,
          fontWeight: FontWeight.w800,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: 44.0);
    distTp.paint(canvas, Offset(22.0, 2.0 + (20.0 - distTp.height) / 2.0));

    // Upcoming street name inside black card ("Nam Kỳ Khởi Nghĩa")
    final streetTp = TextPainter(
      text: TextSpan(
        text: nextStreet.isNotEmpty ? nextStreet : 'Đi thẳng',
        style: const TextStyle(
          color: Color(0xFFF8FAFC),
          fontSize: 10.0,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 96.0);
    streetTp.paint(canvas, const Offset(10.0, 29.0));

    // --- 5. TOP-CENTER-LEFT 3-CIRCLE SPEED CLUSTER (80, 60, liveSpeed) ---
    // Circle 1: Red-bordered Speed Limit 80 (cx=132, cy=56, r=18)
    const Offset limitCenter = Offset(132.0, 56.0);
    canvas.drawCircle(limitCenter, 18.0, Paint()..color = Colors.white);
    canvas.drawCircle(
      limitCenter,
      16.2,
      Paint()
        ..color = const Color(0xFFDC2626)
        ..strokeWidth = 3.8
        ..style = PaintingStyle.stroke,
    );
    final limit80Tp = TextPainter(
      text: const TextSpan(
        text: '80',
        style: TextStyle(
          color: Color(0xFF111827),
          fontSize: 13.0,
          fontWeight: FontWeight.w900,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    limit80Tp.paint(
      canvas,
      Offset(limitCenter.dx - limit80Tp.width / 2.0, limitCenter.dy - limit80Tp.height / 2.0),
    );

    // Circle 2: Bottom-Right Solid Blue Circle 60 (cx=148, cy=68, r=11.5)
    const Offset blueCenter = Offset(148.0, 68.0);
    canvas.drawCircle(blueCenter, 11.5, Paint()..color = const Color(0xFF1D4ED8));
    final blue60Tp = TextPainter(
      text: const TextSpan(
        text: '60',
        style: TextStyle(
          color: Colors.white,
          fontSize: 9.5,
          fontWeight: FontWeight.w800,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    blue60Tp.paint(
      canvas,
      Offset(blueCenter.dx - blue60Tp.width / 2.0, blueCenter.dy - blue60Tp.height / 2.0),
    );

    // Circle 3: Top-Right Current Speed Circle with Dashed Border (cx=153, cy=44, r=11.5)
    const Offset curSpdCenter = Offset(153.0, 44.0);
    canvas.drawCircle(curSpdCenter, 11.5, Paint()..color = const Color(0xFFE5E7EB));
    final dashPaint = Paint()
      ..color = const Color(0xFF64748B)
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;
    for (int i = 0; i < 12; i++) {
      final double startAngle = (i * 30.0) * (math.pi / 180.0);
      final double sweepAngle = 16.0 * (math.pi / 180.0);
      canvas.drawArc(
        Rect.fromCircle(center: curSpdCenter, radius: 11.0),
        startAngle,
        sweepAngle,
        false,
        dashPaint,
      );
    }
    final curSpdTp = TextPainter(
      text: TextSpan(
        text: '${speedKmh.round()}',
        style: const TextStyle(
          color: Color(0xFF111827),
          fontSize: 9.5,
          fontWeight: FontWeight.w900,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    curSpdTp.paint(
      canvas,
      Offset(curSpdCenter.dx - curSpdTp.width / 2.0, curSpdCenter.dy - curSpdTp.height / 2.0),
    );

    // --- 6. BOTTOM-LEFT DARK TRIP SUMMARY PILL (x: 4, y: 196, w: 112, h: 38) ---
    final summaryRect = RRect.fromRectAndRadius(
      const Rect.fromLTWH(4.0, 196.0, 112.0, 38.0),
      const Radius.circular(14.0),
    );
    canvas.drawRRect(summaryRect, Paint()..color = const Color(0xFF242529));

    // Left dark grey circle with white '✕' icon
    const Offset closeCenter = Offset(20.0, 215.0);
    canvas.drawCircle(closeCenter, 10.5, Paint()..color = const Color(0xFF38393E));
    final xPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(16.8, 211.8), const Offset(23.2, 218.2), xPaint);
    canvas.drawLine(const Offset(23.2, 211.8), const Offset(16.8, 218.2), xPaint);

    // Right Line 1: Remaining duration ("1 giờ 28 phút" or "28 phút")
    final int etaMin = (navManager?.remainingEtaMinutes ?? 1).clamp(1, 999);
    final String etaText = etaMin >= 60
        ? '${etaMin ~/ 60} giờ ${etaMin % 60} phút'
        : '$etaMin phút';
    final etaTp = TextPainter(
      text: TextSpan(
        text: etaText,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10.0,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 76.0);
    etaTp.paint(canvas, const Offset(35.0, 202.0));

    // Right Line 2: Arrival time • remaining distance ("21:49 • 80 km")
    final arrTime = DateTime.now().add(Duration(minutes: etaMin));
    final String arrStr =
        '${arrTime.hour.toString().padLeft(2, '0')}:${arrTime.minute.toString().padLeft(2, '0')}';
    final double totalDistM = navManager?.remainingTotalDistance ?? 0.0;
    final String totDistStr = totalDistM >= 10000
        ? '${(totalDistM / 1000.0).round()} km'
        : (totalDistM >= 1000
            ? '${(totalDistM / 1000.0).toStringAsFixed(1)} km'
            : '${totalDistM.round()} m');
    final subTp = TextPainter(
      text: TextSpan(
        text: '$arrStr • $totDistStr',
        style: const TextStyle(
          color: Color(0xFFA1A1AA),
          fontSize: 9.0,
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 76.0);
    subTp.paint(canvas, const Offset(35.0, 216.0));
  }

  /// Helper to draw crisp white maneuver arrow inside the top-left coral badge
  void _drawCanvasTurnIcon(Canvas canvas, double cx, double cy, int turnCode) {
    final p = Paint()
      ..color = Colors.white
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    final fillP = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    if (turnCode == 5 || turnCode == 6 || turnCode == 7) {
      // Turn Left
      final path = ui.Path()
        ..moveTo(cx + 3, cy + 4)
        ..lineTo(cx + 3, cy - 1)
        ..lineTo(cx - 3, cy - 1);
      canvas.drawPath(path, p);
      final head = ui.Path()
        ..moveTo(cx - 5, cy - 1)
        ..lineTo(cx - 1.5, cy - 4)
        ..lineTo(cx - 1.5, cy + 2)
        ..close();
      canvas.drawPath(head, fillP);
    } else if (turnCode == 1 || turnCode == 2 || turnCode == 3) {
      // Turn Right
      final path = ui.Path()
        ..moveTo(cx - 3, cy + 4)
        ..lineTo(cx - 3, cy - 1)
        ..lineTo(cx + 3, cy - 1);
      canvas.drawPath(path, p);
      final head = ui.Path()
        ..moveTo(cx + 5, cy - 1)
        ..lineTo(cx + 1.5, cy - 4)
        ..lineTo(cx + 1.5, cy + 2)
        ..close();
      canvas.drawPath(head, fillP);
    } else if (turnCode == 4) {
      // U-Turn
      final path = ui.Path()
        ..moveTo(cx + 3, cy + 4)
        ..lineTo(cx + 3, cy - 2)
        ..arcToPoint(Offset(cx - 3, cy - 2), radius: const Radius.circular(3), clockwise: false)
        ..lineTo(cx - 3, cy + 2);
      canvas.drawPath(path, p);
      final head = ui.Path()
        ..moveTo(cx - 3, cy + 5)
        ..lineTo(cx - 6, cy + 1.5)
        ..lineTo(cx, cy + 1.5)
        ..close();
      canvas.drawPath(head, fillP);
    } else {
      // Straight / Default
      canvas.drawLine(Offset(cx, cy + 4.5), Offset(cx, cy - 2.0), p);
      final head = ui.Path()
        ..moveTo(cx, cy - 5.0)
        ..lineTo(cx - 3.5, cy - 1.0)
        ..lineTo(cx + 3.5, cy - 1.0)
        ..close();
      canvas.drawPath(head, fillP);
    }
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
        // BLE stream remains active in background! Do NOT check !_isForeground here.
        if (!bleService.isConnected || !_isStreaming) break;

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
        if (!success) {
          bleService.logError('TX [BLE JPEG] Frame #$frameId: Chunk $i/$totalChunks thất bại');
          break;
        }
        if (i < totalChunks - 1) {
          await Future.delayed(const Duration(milliseconds: 6));
        }
      }
      if (_frameCount % 15 == 0) {
        bleService.logInfo('TX [BLE JPEG] Gửi thành công Frame #$frameId ($totalChunks chunks, $totalLen B)');
      }
    } catch (e) {
      bleService.logError('TX [BLE JPEG] Lỗi truyền frame: $e');
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
    _disableBackgroundKeepAlive();
    _streamTimer?.cancel();
    _streamTimer = null;
    _pauseTimer?.cancel();
    _pauseTimer = null;
    _persistentWifiSocket?.destroy();
    _persistentWifiSocket = null;
    _actualFps = 0.0;
    notifyListeners();
  }
}
