import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
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

  // Real Map Tile Cache (In-Memory Image Cache for Instant Rendering)
  final Map<String, ui.Image> _tileCache = {};
  final Map<String, img.Image> _cpuTileCache = {};
  final Map<String, Uint8List> _tileMasks = {}; // 1 = building footprint (for pseudo-3D extrusion)
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
      _tileMasks.clear();
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
      _tileMasks.clear();
      _lastPrefetchPos = null;
      notifyListeners();
    }
  }

  EspStreamService({required this.bleService, this.navManager}) {
    WidgetsBinding.instance.addObserver(this);
    _startWebSocketServer();
    _startEspApConnector();
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
            _registerWsClient(socket);
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


  // ───────────────────────────────────────────────────────────────────────
  // ESP32 SoftAP mode: ESP32 phát Wi-Fi "ESP32-NAV" (không Internet) + WebSocket server 192.168.4.1:8080.
  // iPhone vào Wi-Fi đó (vẫn dùng 4G/5G để ra mạng) và app chủ động kết nối tới ESP32.
  // ───────────────────────────────────────────────────────────────────────
  static const String espApWsUrl = 'ws://192.168.4.1:8080';
  Timer? _apConnectTimer;
  WebSocket? _apSocket;
  bool _apConnecting = false;

  void _startEspApConnector() {
    _apConnectTimer?.cancel();
    _apConnectTimer = Timer.periodic(const Duration(seconds: 2), (_) => _tryConnectEspAp());
    _tryConnectEspAp();
  }

  Future<void> _tryConnectEspAp() async {
    if (_apSocket != null || _apConnecting) return;
    _apConnecting = true;
    try {
      final ws = await WebSocket.connect(espApWsUrl).timeout(const Duration(milliseconds: 1500));
      ws.pingInterval = const Duration(seconds: 5);
      _apSocket = ws;
      _registerWsClient(ws);
      bleService.logInfo('Đã kết nối Wi-Fi ESP32-NAV (192.168.4.1:8080)');
    } catch (_) {
      // Không ở trong Wi-Fi của ESP32 -> thử lại sau 2s
    } finally {
      _apConnecting = false;
    }
  }

  /// Register a WebSocket peer (either iPhone-hosted server client or ESP32 SoftAP connection)
  void _registerWsClient(WebSocket socket) {
    _wsClients.add(socket);
    _wsReadyForNextFrame = true;
    final ip = identical(socket, _apSocket) ? '192.168.4.1' : '172.20.10.1';
    bleService.setHotspotConnected(ip, 8080);
    if (_latestJpegBytes != null) {
      try {
        socket.add(_latestJpegBytes!);
      } catch (_) {}
    }
    notifyListeners();

    void onGone() {
      _wsClients.remove(socket);
      if (identical(_apSocket, socket)) _apSocket = null;
      if (_wsClients.isEmpty) {
        bleService.setHotspotDisconnected();
      }
      notifyListeners();
    }

    socket.listen(
      (data) {
        // ACK 'K' from ESP32 when frame is rendered
        final msg = data is String
            ? data.trim()
            : (data is List<int> ? utf8.decode(data, allowMalformed: true).trim() : '');
        if (msg == 'K' || msg == 'ACK' || msg.contains('K')) {
          _wsReadyForNextFrame = true;
        }
      },
      onDone: onGone,
      onError: (_) => onGone(),
    );
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
      _tryConnectEspAp();
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
    _apConnectTimer?.cancel();
    _apSocket = null;
    _wsServer?.close(force: true);
    _wsServer = null;
    _pauseTimer?.cancel();
    _tileCache.forEach((_, img) => img.dispose());
    _tileCache.clear();
    _cpuTileCache.clear();
      _tileMasks.clear();
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
  Future<Uint8List?> _compressRgbaToJpeg(
    Uint8List rawBytes,
    int w,
    int h, {
    int quality = 65,
    Map<String, dynamic>? hud,
  }) async {
    if (Platform.isIOS) {
      try {
        final args = <String, dynamic>{
          'rgba': rawBytes,
          'width': w,
          'height': h,
          'quality': quality / 100.0,
          if (hud != null) 'hud': hud,
        };
        var res = await _locationChannel.invokeMethod<Uint8List>('compressRgbaToJpeg', args);
        if (res != null && res.length > 14500) {
          args['quality'] = 0.38;
          res = await _locationChannel.invokeMethod<Uint8List>('compressRgbaToJpeg', args);
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
    if (!_isStreaming || _isCapturing || _isSendingWifi) return;

    // Do NOT stream map frames if user has not connected BLE in-app and is not navigating!
    // This keeps ESP32 quietly in Màn 1 (Watchface) without screen flickering or premature loading.
    if (!bleService.isConnected && !(navManager?.isNavigating ?? false)) {
      return;
    }

    // Strict 1-in-flight queue control: if ESP32 hasn't rendered previous frame, skip tick to prevent queue buildup
    if (_wsClients.isNotEmpty && !_wsReadyForNextFrame && DateTime.now().difference(_lastWsSendTime).inMilliseconds < 250) {
      return;
    }
    _isCapturing = true;

    try {
      final bool isNav = navManager?.isNavigating ?? false;
      final int w = isNav ? 320 : 144;
      final int h = isNav ? 216 : 224;

      final userPos = navManager?.currentLocation ?? const LatLng(20.9832, 105.8425);
      final double heading = navManager?.effectiveHeading ?? navManager?.currentHeading ?? 0.0;
      final activeRoute = navManager?.activeRoute;
      final distToTurn = navManager?.distanceToNextManeuver ?? 208.0;
      final speedKmh = navManager?.currentSpeedKmh ?? 0.0;

      // Pre-fetch surrounding tiles asynchronously at chosen minimap zoom
      _prefetchSurroundingTiles(userPos, _minimapZoom);

      Uint8List? jpegBytes;

      if (_isForeground && !isNav) {
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
            jpegBytes = await _compressRgbaToJpeg(rawBytes, w, h, quality: isNav ? 60 : 65);
          }
        } catch (_) {}
      }

      // 2. In background / screen-off: Pure CPU Software Map + CoreGraphics HUD Renderer (100% CPU RAM, 0% GPU)
      jpegBytes ??= isNav ? await _renderCpuNavigationFrame(w, h) : _renderCpuMapFrame(w, h);


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
      final patch = img.Image(width: patchSize, height: patchSize, numChannels: 4);
      final bgColor = isDark ? img.ColorRgba8(11, 17, 26, 255) : img.ColorRgba8(223, 245, 232, 255);
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
        rotatedPatch = img.copyRotate(patch, angle: -headingDeg, interpolation: img.Interpolation.linear);
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
  /// Uses CPU CoreGraphics + CoreText on iOS so background ("treo app") looks 100% identical to foreground ("trong app")!
  Future<Uint8List?> _renderCpuNavigationFrame(int w, int h) async {
    try {
      final userPos = navManager?.currentLocation ?? const LatLng(20.9832, 105.8425);
      final double headingDeg = navManager?.effectiveHeading ?? navManager?.currentHeading ?? 0.0;
      final activeRoute = navManager?.activeRoute ?? navManager?.previewRoute;
      final double speedKmh = navManager?.currentSpeedKmh ?? 0.0;
      final double distToTurn = navManager?.distanceToNextManeuver ?? 200.0;
      final double totalDistM = navManager?.remainingTotalDistance ?? 0.0;
      final int etaMin = (navManager?.remainingEtaMinutes ?? 1).clamp(1, 999);
      final int zoom = _minimapZoom;
      final isDark = _streamMapStyle.contains('dark');

      final double n = math.pow(2.0, zoom).toDouble();
      final double latRad = userPos.latitude * (math.pi / 180.0);
      final double worldX = (userPos.longitude + 180.0) / 360.0 * n * 256.0;
      final double worldY = (1.0 - (math.log(math.tan(latRad) + 1.0 / math.cos(latRad)) / math.pi)) / 2.0 * n * 256.0;

      // ===== Pseudo-3D "nổi khối" map: heading-up + tilt + extruded buildings (100% CPU) =====
      const int vx = 226;
      final int vy = (h * 0.74).round(); // ~160 for h=216
      const double tilt = 0.74; // vertical foreshortening (camera pitch)
      const int extrude = 10; // building height in screen px
      final double th = headingDeg * (math.pi / 180.0);
      final double cosT = math.cos(th);
      final double sinT = math.sin(th);
      final bool hasTiles3d = !isDark;

      final frame = img.Image(width: w, height: h, numChannels: 4);
      final Uint8List buf = frame.buffer.asUint8List();
      final int fh = h + extrude + 1; // footprint rows (buildings below frame still extrude into it)
      final Uint8List foot = Uint8List(w * fh);

      final int baseR = isDark ? 11 : 223;
      final int baseG = isDark ? 17 : 245;
      final int baseB = isDark ? 26 : 232;
      final int wallR = isDark ? 40 : 156, wallG = isDark ? 52 : 174, wallB = isDark ? 66 : 164;

      int lastTx = -999999, lastTy = -999999;
      img.Image? curTile;
      Uint8List? curMask;

      // 1. Ground + footprint (inverse mapping screen -> world tile pixel, no patch/rotate allocation)
      for (int sy = 0; sy < fh; sy++) {
        final double dy = (sy - vy) / tilt;
        for (int sx = 0; sx < w; sx++) {
          final double dx = (sx - vx).toDouble();
          final double wx = worldX + dx * cosT - dy * sinT;
          final double wy = worldY + dx * sinT + dy * cosT;
          final int tx = (wx / 256.0).floor();
          final int ty = (wy / 256.0).floor();
          if (tx != lastTx || ty != lastTy) {
            lastTx = tx;
            lastTy = ty;
            final String key = '$zoom/$tx/$ty';
            curTile = _cpuTileCache[key];
            curMask = _tileMasks[key];
          }
          final tile = curTile;
          int r = baseR, g = baseG, b = baseB;
          bool isBuilding = false;
          if (tile != null) {
            final int px = (wx - tx * 256.0).floor().clamp(0, 255);
            final int py = (wy - ty * 256.0).floor().clamp(0, 255);
            final pix = tile.getPixel(px, py);
            r = pix.r.toInt();
            g = pix.g.toInt();
            b = pix.b.toInt();
            if (hasTiles3d) {
              final mask = curMask;
              if (mask != null && mask[py * 256 + px] == 1) {
                isBuilding = true;
              }
            }
          }
          if (isBuilding) foot[sy * w + sx] = 1;
          if (sy < h) {
            final int o = (sy * w + sx) * 4;
            if (isBuilding) {
              buf[o] = wallR;
              buf[o + 1] = wallG;
              buf[o + 2] = wallB;
            } else {
              buf[o] = r;
              buf[o + 1] = g;
              buf[o + 2] = b;
            }
            buf[o + 3] = 255;
          }
        }
      }

      // 2. Route polyline projected through the same transform (drawn on the ground)
      if (activeRoute != null && activeRoute.polylinePoints.length >= 2) {
        final pts = activeRoute.polylinePoints;
        final casingColor = img.ColorRgba8(0, 62, 179, 255);
        final coreColor = img.ColorRgba8(0, 102, 255, 255);
        final screenPts = <img.Point>[];
        for (final pt in pts) {
          final double ptLatRad = pt.latitude * (math.pi / 180.0);
          final double ptWorldX = (pt.longitude + 180.0) / 360.0 * n * 256.0;
          final double ptWorldY = (1.0 - (math.log(math.tan(ptLatRad) + 1.0 / math.cos(ptLatRad)) / math.pi)) / 2.0 * n * 256.0;
          final double px = ptWorldX - worldX;
          final double py = ptWorldY - worldY;
          final double rx = px * cosT + py * sinT;
          final double ry = (-px * sinT + py * cosT) * tilt;
          screenPts.add(img.Point((vx + rx).round(), (vy + ry).round()));
        }
        bool inView(img.Point p) => p.x >= -40 && p.x <= w + 40 && p.y >= -40 && p.y <= h + 40;
        for (int i = 0; i < screenPts.length - 1; i++) {
          final p1 = screenPts[i];
          final p2 = screenPts[i + 1];
          if (inView(p1) || inView(p2)) {
            img.drawLine(frame, x1: p1.x.toInt(), y1: p1.y.toInt(), x2: p2.x.toInt(), y2: p2.y.toInt(), color: casingColor, thickness: 10);
            img.fillCircle(frame, x: p1.x.toInt(), y: p1.y.toInt(), radius: 5, color: casingColor);
            img.fillCircle(frame, x: p2.x.toInt(), y: p2.y.toInt(), radius: 5, color: casingColor);
          }
        }
        for (int i = 0; i < screenPts.length - 1; i++) {
          final p1 = screenPts[i];
          final p2 = screenPts[i + 1];
          if (inView(p1) || inView(p2)) {
            img.drawLine(frame, x1: p1.x.toInt(), y1: p1.y.toInt(), x2: p2.x.toInt(), y2: p2.y.toInt(), color: coreColor, thickness: 6);
            img.fillCircle(frame, x: p1.x.toInt(), y: p1.y.toInt(), radius: 3, color: coreColor);
            img.fillCircle(frame, x: p2.x.toInt(), y: p2.y.toInt(), radius: 3, color: coreColor);
          }
        }
      }

      // 3. Extrude buildings upward (painter's algorithm: far rows first, near rows overlap)
      if (hasTiles3d) {
        for (int sy = 0; sy < fh; sy++) {
          for (int sx = 0; sx < w; sx++) {
            if (foot[sy * w + sx] != 1) continue;
            // walls
            for (int dh = 1; dh < extrude; dh++) {
              final int ny = sy - dh;
              if (ny < 0 || ny >= h) continue;
              final int o = (ny * w + sx) * 4;
              buf[o] = wallR;
              buf[o + 1] = wallG;
              buf[o + 2] = wallB;
            }
            // roof
            final int ry = sy - extrude;
            if (ry >= 0 && ry < h) {
              final bool edge = sx == 0 ||
                  sx == w - 1 ||
                  sy == 0 ||
                  sy >= fh - 1 ||
                  foot[(sy - 1) * w + sx] == 0 ||
                  foot[(sy + 1) * w + sx] == 0 ||
                  foot[sy * w + sx - 1] == 0 ||
                  foot[sy * w + sx + 1] == 0;
              final int o = (ry * w + sx) * 4;
              if (edge) {
                buf[o] = 144;
                buf[o + 1] = 162;
                buf[o + 2] = 152;
              } else {
                buf[o] = 192;
                buf[o + 1] = 209;
                buf[o + 2] = 198;
              }
            }
          }
        }
      }

      final String curRoad = navManager?.currentStreetName ?? 'Đường hiện tại';
      final upcoming = navManager?.upcomingStep ?? navManager?.currentStep;
      final int turnCode = upcoming?.turnCode ?? 0;
      final String nextStreetRaw = upcoming?.streetName ?? curRoad;
      final String nextStreet = NavigationManager.cleanStreetName(nextStreetRaw);
      final String distStr = distToTurn >= 1000
          ? '${(distToTurn / 1000.0).toStringAsFixed(1)} km'
          : '${distToTurn.round()} m';
      final String etaText = etaMin >= 60
          ? '${etaMin ~/ 60} giờ ${etaMin % 60} phút'
          : '$etaMin phút';
      final arrTime = DateTime.now().add(Duration(minutes: etaMin));
      final String arrStr =
          '${arrTime.hour.toString().padLeft(2, '0')}:${arrTime.minute.toString().padLeft(2, '0')}';
      final String totDistStr = totalDistM >= 10000
          ? '${(totalDistM / 1000.0).round()} km'
          : (totalDistM >= 1000
              ? '${(totalDistM / 1000.0).toStringAsFixed(1)} km'
              : '${totalDistM.round()} m');

      final hudData = <String, dynamic>{
        'vx': vx.toDouble(),
        'vy': vy.toDouble(),
        'curRoad': curRoad,
        'nextStreet': nextStreet.isNotEmpty ? nextStreet : 'Đi thẳng',
        'distStr': distStr,
        'turnCode': turnCode,
        'speedStr': '${speedKmh.round()}',
        'etaText': etaText,
        'subText': '$arrStr • $totDistStr',
      };

      if (Platform.isIOS) {
        final rawRgba = frame.toUint8List();
        final iosJpg = await _compressRgbaToJpeg(rawRgba, w, h, quality: 60, hud: hudData);
        if (iosJpg != null && iosJpg.isNotEmpty) {
          return iosJpg;
        }
      }

      // Pure-Dart fallback if non-iOS
      var jpg = Uint8List.fromList(img.encodeJpg(frame, quality: 58));
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
        bleService.logInfo('TX [Hotspot WS] Stream Frame #$_frameCount ($_frameSizeKb KB, ${_actualFps.toStringAsFixed(1)} FPS)');
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

    // Never stream video/JPEG frames over BLE!
    // Streaming 60+ chunks over BLE saturates iOS CoreBluetooth buffers, causing connection drops
    // especially during phone calls or screen lock.
  }

  /// Transmit a single 320x240 simulator frame to ESP32 (via WebSocket or WiFi TCP)
  void transmitSimulatorFrame(Uint8List jpegBytes) {
    _latestJpegBytes = jpegBytes;
    _dispatchTransmission(jpegBytes);
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

        if (((_isForeground && !_tileCache.containsKey(key)) || !_cpuTileCache.containsKey(key)) && !_pendingTileFetches.contains(key)) {
          _fetchTileImage(key, tx, ty, zoom);
        }
      }
    }
  }

  static const String _goongMapApiStyle =
      's.e%3Al.t%7Cp.v%3Aoff%2Cs.t%3A2%7Cs.e%3Al.i%7Cp.v%3Aoff%2Cs.t%3A4%7Cs.e%3Al.i%7Cp.v%3Aoff%2Cs.t%3A5%7Cs.e%3Ag%7Cp.c%3A%23dff5e8%2Cs.t%3A81%7Cs.e%3Ag.f%7Cp.c%3A%23dff5e8%2Cs.t%3A1297%7Cs.e%3Ag.f%7Cp.c%3A%23d4b8c8%2Cs.t%3A1297%7Cs.e%3Ag.s%7Cp.v%3Aoff%2Cs.t%3A3%7Cs.e%3Ag.f%7Cp.c%3A%23e2e8f0%2Cs.t%3A3%7Cs.e%3Ag.s%7Cp.c%3A%2394a3b8%2Cs.t%3A2%7Cs.e%3Ag%7Cp.c%3A%23a7e3b8%2Cs.t%3A6%7Cs.e%3Ag%7Cp.c%3A%2360a5fa';

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
        // High-contrast Goong/iPhone-styled tiles (mint-green land #dff5e8, distinct buildings #b8c9be, crisp roads #e2e8f0, no upside-down text on rotation)
        url = 'https://mt1.google.com/vt/lyrs=m&x=$x&y=$y&z=$z&hl=vi&apistyle=$_goongMapApiStyle';
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
            ? 'https://mt2.google.com/vt/lyrs=m&x=$x&y=$y&z=$z&hl=vi&apistyle=$_goongMapApiStyle'
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
        // 1. Decode for CPU background map rendering (0% GPU, 4-channel RGBA)
        try {
          var cpuImg = img.decodeImage(response.bodyBytes);
          if (cpuImg != null) {
            // Convert palette / 3-channel PNG to direct 4-channel RGBA
            if (cpuImg.hasPalette || cpuImg.numChannels != 4) {
              cpuImg = cpuImg.convert(numChannels: 4);
            }
            // Downsample @2x (512x512) to 256x256 for crisp Retina labels
            if (cpuImg.width > 256) {
              cpuImg = img.copyResize(cpuImg, width: 256, height: 256, interpolation: img.Interpolation.average);
            }
            if (isGoong && cpuImg.width == 256 && cpuImg.height == 256) {
              // Building fill uses marker color #d4b8c8 (r > g); extract footprint mask, recolor to flat roof color
              final mask = Uint8List(256 * 256);
              for (int my = 0; my < 256; my++) {
                for (int mx = 0; mx < 256; mx++) {
                  final p = cpuImg.getPixel(mx, my);
                  if (p.r.toInt() - p.g.toInt() >= -3) {
                    mask[my * 256 + mx] = 1;
                    p.r = 192;
                    p.g = 209;
                    p.b = 198;
                  }
                }
              }
              _tileMasks[key] = mask;
              if (_tileMasks.length > 100) {
                _tileMasks.remove(_tileMasks.keys.first);
              }
              finalBytes = Uint8List.fromList(img.encodePng(cpuImg));
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

  /// Draw 320x240 Full-Screen Navigation Map + Enlarged Floating HUD Overlays
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

    // 1. Background Fill: Mint-Green Goong Daylight Map (#DFF5E8) or Dark Mode (#0B111A)
    final bgPaint = Paint()..color = isDark ? const Color(0xFF0B111A) : const Color(0xFFDFF5E8);
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), bgPaint);

    // Vehicle anchor at bottom-right (x=226, y=158 on 320x216 canvas)
    const double cx = 226.0;
    const double cy = 158.0;

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

    // --- 2. CRISP HEADING-UP MAP PLANE & VIBRANT BLUE ROUTE POLYLINE (Matches iPhone Map) ---
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

    if (!tilesDrawn) {
      final gridPaint = Paint()
        ..color = isDark ? const Color(0xFF1E2D42) : const Color(0xFFC3DACC)
        ..strokeWidth = 1.0;
      for (double gx = -450; gx <= 450; gx += 36) {
        canvas.drawLine(Offset(gx, -450), Offset(gx, 450), gridPaint);
      }
      for (double gy = -450; gy <= 450; gy += 36) {
        canvas.drawLine(Offset(-450, gy), Offset(450, gy), gridPaint);
      }
    }

    // Active Route Polyline in Vibrant iPhone Navigation Blue (#003EB3 casing + #0066FF core)
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
        ..color = const Color(0xFF003EB3)
        ..strokeWidth = 10.0
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      canvas.drawPath(routePath, casingPaint);

      final corePaint = Paint()
        ..color = const Color(0xFF0066FF)
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

    // --- 3. BOTTOM-RIGHT 3D CYAN/BLUE NAVIGATION CHEVRON & ENLARGED BLUE CURRENT ROAD PILL ---
    canvas.drawCircle(
      const Offset(cx, cy + 1),
      15.0,
      Paint()..color = const Color(0x472563EB),
    );

    final chevronFull = ui.Path()
      ..moveTo(cx, cy - 12.0)
      ..lineTo(cx + 10.5, cy + 7.5)
      ..lineTo(cx, cy + 3.0)
      ..lineTo(cx - 10.5, cy + 7.5)
      ..close();
    final chevronLeft = ui.Path()
      ..moveTo(cx, cy - 12.0)
      ..lineTo(cx, cy + 3.0)
      ..lineTo(cx - 10.5, cy + 7.5)
      ..close();
    final chevronRight = ui.Path()
      ..moveTo(cx, cy - 12.0)
      ..lineTo(cx + 10.5, cy + 7.5)
      ..lineTo(cx, cy + 3.0)
      ..close();

    canvas.drawPath(chevronLeft, Paint()..color = const Color(0xFF38BDF8));
    canvas.drawPath(chevronRight, Paint()..color = const Color(0xFF0284C7));
    canvas.drawPath(
      chevronFull,
      Paint()
        ..color = Colors.white
        ..strokeWidth = 2.0
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke,
    );

    // Current Street Blue Pill Badge below chevron (e.g. "Phố Nguyễn Cảnh Dị")
    final String curRoad = navManager?.currentStreetName ?? 'Đường hiện tại';
    final curRoadTp = TextPainter(
      text: TextSpan(
        text: curRoad,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10.5,
          fontWeight: FontWeight.w900,
          height: 1.15,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      maxLines: 2,
      ellipsis: '…',
    )..layout(maxWidth: 136.0);

    final double pillW = (curRoadTp.width + 18.0).clamp(78.0, 152.0);
    final double pillH = (curRoadTp.height + 8.0).clamp(22.0, 32.0);
    final double pillLeft = (cx - pillW / 2.0).clamp(150.0, w - pillW - 4.0);
    final double pillTop = (cy + 13.0).clamp(170.0, h - pillH - 3.0);
    final roadPillRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(pillLeft, pillTop, pillW, pillH),
      const Radius.circular(11.0),
    );
    canvas.drawRRect(roadPillRect, Paint()..color = const Color(0xFF1D63FF));
    canvas.drawRRect(
      roadPillRect,
      Paint()
        ..color = const Color(0xFF60A5FA)
        ..strokeWidth = 1.2
        ..style = PaintingStyle.stroke,
    );
    curRoadTp.paint(
      canvas,
      Offset(pillLeft + (pillW - curRoadTp.width) / 2.0, pillTop + (pillH - curRoadTp.height) / 2.0),
    );

    // --- 4. TOP-LEFT ENLARGED BLACK MANEUVER CARD WITH CORAL-RED TOP BADGE ---
    final upcoming = navManager?.upcomingStep ?? navManager?.currentStep;
    final int turnCode = upcoming?.turnCode ?? 0;
    final String nextStreetRaw = upcoming?.streetName ?? curRoad;
    final String nextStreet = NavigationManager.cleanStreetName(nextStreetRaw);
    final String distStr = distToTurn >= 1000
        ? '${(distToTurn / 1000.0).toStringAsFixed(1)} km'
        : '${distToTurn.round()} m';

    // Pitch-black rounded rectangle (x: 4, y: 6, w: 138, h: 50)
    final blackCardRect = RRect.fromRectAndRadius(
      const Rect.fromLTWH(4.0, 6.0, 138.0, 50.0),
      const Radius.circular(10.0),
    );
    canvas.drawRRect(
      blackCardRect.shift(const Offset(0, 2)),
      Paint()..color = const Color(0x4D000000),
    );
    canvas.drawRRect(blackCardRect, Paint()..color = const Color(0xF5090A0F));
    canvas.drawRRect(
      blackCardRect,
      Paint()
        ..color = const Color(0xFF2E3038)
        ..strokeWidth = 1.0
        ..style = PaintingStyle.stroke,
    );

    // Top-left Coral-Red Badge (#F06261 with thin white inner border)
    final coralBadgeRect = RRect.fromRectAndRadius(
      const Rect.fromLTWH(0.0, 2.0, 84.0, 24.0),
      const Radius.circular(11.0),
    );
    canvas.drawRRect(coralBadgeRect, Paint()..color = const Color(0xFFF06261));
    canvas.drawRRect(
      coralBadgeRect.deflate(1.2),
      Paint()
        ..color = Colors.white.withAlpha(216)
        ..strokeWidth = 1.0
        ..style = PaintingStyle.stroke,
    );

    // Turn icon + larger distance inside coral badge
    _drawCanvasTurnIcon(canvas, 15.0, 14.0, turnCode);
    final distTp = TextPainter(
      text: TextSpan(
        text: distStr,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12.0,
          fontWeight: FontWeight.w900,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: 56.0);
    distTp.paint(canvas, Offset(27.0, 2.0 + (24.0 - distTp.height) / 2.0));

    // Upcoming street name inside black card ("Phố Nguyễn Hữu Thọ", thả trôi khi dài)
    final streetTp = TextPainter(
      text: TextSpan(
        text: nextStreet.isNotEmpty ? nextStreet : 'Đi thẳng',
        style: const TextStyle(
          color: Color(0xFFF8FAFC),
          fontSize: 12.0,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();

    const double availW = 120.0;
    if (streetTp.width > availW) {
      final double textW = streetTp.width;
      final double loopDist = textW + 36.0;
      final int nowMs = DateTime.now().millisecondsSinceEpoch;
      final int cycleMs = (loopDist * 35).round();
      final int phaseMs = nowMs % (cycleMs + 2000);
      final double scrollX = (phaseMs < 1200)
          ? 0.0
          : (phaseMs > cycleMs + 1200)
              ? 0.0
              : (phaseMs - 1200) / 35.0;

      canvas.save();
      canvas.clipRRect(RRect.fromRectAndRadius(
        const Rect.fromLTWH(8.0, 26.0, availW + 4.0, 22.0),
        const Radius.circular(4.0),
      ));
      final double off = scrollX % loopDist;
      streetTp.paint(canvas, Offset(10.0 - off, 27.5));
      streetTp.paint(canvas, Offset(10.0 - off + loopDist, 27.5));
      canvas.restore();
    } else {
      streetTp.paint(canvas, const Offset(10.0, 27.5));
    }

    // --- 5. SPEEDOMETER BOX ABOVE BOTTOM-LEFT TIME CARD (x: 4, y: 118, w: 58, h: 42) ---
    final speedBoxRect = RRect.fromRectAndRadius(
      const Rect.fromLTWH(4.0, 118.0, 58.0, 42.0),
      const Radius.circular(12.0),
    );
    canvas.drawRRect(speedBoxRect, Paint()..color = const Color(0xF218191E));
    canvas.drawRRect(
      speedBoxRect,
      Paint()
        ..color = const Color(0xE638BDF8)
        ..strokeWidth = 1.4
        ..style = PaintingStyle.stroke,
    );

    final curSpdTp = TextPainter(
      text: TextSpan(
        text: '${speedKmh.round()}',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 16.5,
          fontWeight: FontWeight.w900,
          height: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    curSpdTp.paint(
      canvas,
      Offset(4.0 + (58.0 - curSpdTp.width) / 2.0, 122.0),
    );

    final unitTp = TextPainter(
      text: const TextSpan(
        text: 'km/h',
        style: TextStyle(
          color: Color(0xFF94A3B8),
          fontSize: 9.0,
          fontWeight: FontWeight.w700,
          height: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    unitTp.paint(
      canvas,
      Offset(4.0 + (58.0 - unitTp.width) / 2.0, 144.0),
    );

    // --- 6. ENLARGED BOTTOM-LEFT DARK TRIP SUMMARY PILL (x: 4, y: 166, w: 138, h: 44) ---
    final summaryRect = RRect.fromRectAndRadius(
      const Rect.fromLTWH(4.0, 166.0, 138.0, 44.0),
      const Radius.circular(13.0),
    );
    canvas.drawRRect(summaryRect, Paint()..color = const Color(0xF51E2025));
    canvas.drawRRect(
      summaryRect,
      Paint()
        ..color = const Color(0xFF3F3F46)
        ..strokeWidth = 1.0
        ..style = PaintingStyle.stroke,
    );

    // Left dark grey circle with white '✕' icon
    const Offset closeCenter = Offset(19.0, 188.0);
    canvas.drawCircle(closeCenter, 11.0, Paint()..color = const Color(0xFF38393E));
    final xPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(15.5, 184.5), const Offset(22.5, 191.5), xPaint);
    canvas.drawLine(const Offset(22.5, 184.5), const Offset(15.5, 191.5), xPaint);

    // Right Line 1: Remaining duration ("2 phút" or "1 giờ 28 phút")
    final int etaMin = (navManager?.remainingEtaMinutes ?? 1).clamp(1, 999);
    final String etaText = etaMin >= 60
        ? '${etaMin ~/ 60} giờ ${etaMin % 60} phút'
        : '$etaMin phút';
    final etaTp = TextPainter(
      text: TextSpan(
        text: etaText,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13.0,
          fontWeight: FontWeight.w900,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 98.0);
    etaTp.paint(canvas, const Offset(36.0, 171.0));

    // Right Line 2: Arrival time • remaining distance ("11:34 • 1.2 km")
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
          color: Color(0xFFE4E4E7),
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 98.0);
    subTp.paint(canvas, const Offset(36.0, 191.0));
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
