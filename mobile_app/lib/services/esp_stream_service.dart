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
import '../config/mapbox_config.dart';
import '../models/route_model.dart';
import 'ble_service.dart';
import 'navigation_manager.dart';


enum EspMapStreamState {
  idle,
  waitingForConsumer,
  streamingForeground,
  streamingBackground,
}

class EspStreamService extends ChangeNotifier with WidgetsBindingObserver {

  EspMapStreamState _streamState = EspMapStreamState.idle;
  EspMapStreamState get streamState => _streamState;

  bool get hasEspDisplayConsumer =>
      _wsClients.isNotEmpty ||
      (_persistentWifiSocket != null);

  String _thermalState = 'nominal';
  String get thermalState => _thermalState;
  void setThermalStateForTesting(String state) {
    _thermalState = state;
    _updateStreamDemand();
  }

  bool _isLowPowerMode = false;
  bool get isLowPowerMode => _isLowPowerMode;
  void setLowPowerModeForTesting(bool enabled) {
    _isLowPowerMode = enabled;
    _updateStreamDemand();
  }

  int get effectiveTargetFps {
    if (_thermalState == 'critical') return 0;
    int fps = _targetFps;
    if (_thermalState == 'serious') {
      fps = math.min(fps, 4); // 3-5 FPS cap for serious thermal (Section 40)
    } else if (_thermalState == 'fair') {
      fps = math.min(fps, 7);
    }
    if (_isLowPowerMode) {
      fps = math.min(fps, 5); // Clamped for Low Power Mode (Section 41)
    }
    return fps;
  }

  LatLng? _lastRenderedPos;
  double? _lastRenderedHeading;
  String? _lastRenderedRouteId;
  String? _lastRenderedTheme;
  int? _lastRenderedZoom;

  int _mapJpegRendersCount = 0;
  int get mapJpegRendersCount => _mapJpegRendersCount;

  int _framesCoalescedCount = 0;
  int get framesCoalescedCount => _framesCoalescedCount;

  void resetCountersForTesting() {
    _mapJpegRendersCount = 0;
    _framesCoalescedCount = 0;
    _frameCount = 0;
    _actualFps = 0.0;
  }
  BleService bleService;
  NavigationManager? navManager;

  bool _isSendingWifi = false;

  /// Optional hook to take live vector snapshots from MapLibre map
  Future<Uint8List?> Function({int? width, int? height})? mapSnapshotProvider;

  bool _isStreaming = false;
  bool _isCapturing = false;
  bool _isForeground = true;
  int _targetFps = 10; // P5.4.1.2: Default 10 FPS foreground (down from 14) // Real-time 14 FPS match for ESP32 hardware (zero queue lag, 3 FPS in background)
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

  String _streamMapStyle = 'streets-v2';
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
    if (!Platform.environment.containsKey("FLUTTER_TEST")) {
      _startWebSocketServer();
    }
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
            _updateStreamDemand();
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
                _updateStreamDemand();
              },
              onError: (_) {
                _wsClients.remove(socket);
                if (_wsClients.isEmpty) {
                  bleService.setHotspotDisconnected();
                }
                _updateStreamDemand();
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
      _updateStreamDemand();
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _isForeground = false;
      _updateStreamDemand();
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
    _actualFps = 0.0;
    _lastFpsUpdate = DateTime.now();

    _updateStreamDemand();
  }


  /// Manage stream state machine & demand-driven rendering (Sections 19, 20, 21, 38)
  void _updateStreamDemand() {
    if (!_isStreaming) {
      _streamState = EspMapStreamState.idle;
      _streamTimer?.cancel();
      _streamTimer = null;
      _actualFps = 0.0;
      _disableBackgroundKeepAlive();
      notifyListeners();
      return;
    }

    if (!hasEspDisplayConsumer) {
      // Idle app or navigating without consumer -> effective stream FPS = 0 (Section 21 & 22)
      _streamState = EspMapStreamState.waitingForConsumer;
      _streamTimer?.cancel();
      _streamTimer = null;
      _actualFps = 0.0;
      _disableBackgroundKeepAlive();
      notifyListeners();
      return;
    }

    if (_isForeground) {
      _streamState = EspMapStreamState.streamingForeground;
      _disableBackgroundKeepAlive(); // No audio keep-alive in foreground (Section 36)
      _startTimer();
    } else {
      _streamState = EspMapStreamState.streamingBackground;
      _enableBackgroundKeepAlive(); // Enabled only when background + required stream (Section 36)
      _startTimer();
    }
    notifyListeners();
  }

  void _startTimer() {
    _streamTimer?.cancel();
    if (!hasEspDisplayConsumer) {
      _streamTimer = null;
      _actualFps = 0.0;
      return;
    }

    // P5.4.1.2 Section 23 & 24: 10 FPS foreground cap, 1-2 FPS in background
    final fps = _isForeground ? effectiveTargetFps : 1;
    if (fps <= 0) {
      _streamTimer = null;
      _actualFps = 0.0;
      return;
    }

    final intervalMs = (1000 / fps).round();
    _streamTimer = Timer.periodic(Duration(milliseconds: intervalMs), (_) {
      _renderAndStreamHeadlessFrame();
    });
  }

  /// Render 144x208 High-Definition Real Street Map in Memory & Stream at 20 FPS (with Pure CPU Background Support)
  Future<void> _renderAndStreamHeadlessFrame() async {
    // If previous frame is still transmitting over TCP or BLE, drop this tick to avoid queue buildup and heating
    if (!_isStreaming || _isCapturing || _isSendingWifi || _isSendingBle) return;

    // Strict 1-in-flight queue control: if ESP32 hasn't rendered previous frame, skip tick to prevent queue buildup
    if (_wsClients.isNotEmpty && !_wsReadyForNextFrame && DateTime.now().difference(_lastWsSendTime).inMilliseconds < 250) {
      return;
    }
    _isCapturing = true;

    try {
      const int w = 144;
      const int h = 208;

      final userPos = navManager?.currentLocation ?? const LatLng(20.9832, 105.8425);
      final double heading = navManager?.effectiveHeading ?? navManager?.currentHeading ?? 0.0;
      final activeRoute = navManager?.activeRoute;
      final distToTurn = navManager?.distanceToNextManeuver ?? 208.0;
      final speedKmh = navManager?.currentSpeedKmh ?? 0.0;

      // P5.4.1.2 Section 26 & 27: Map Frame Dirty Check
      final currentRouteId = activeRoute == null ? null : "${activeRoute.polylinePoints.length}_${activeRoute.totalDistanceMeters}";
      bool isDirty = false;
      if (_latestJpegBytes == null || _lastRenderedPos == null) {
        isDirty = true;
      } else {
        const distCalc = Distance();
        final dist = distCalc.as(LengthUnit.Meter, _lastRenderedPos!, userPos);
        final headingDelta = (_lastRenderedHeading! - heading).abs();
        final normalizedHeadingDelta = headingDelta > 180 ? 360 - headingDelta : headingDelta;

        if (dist >= 2.5 ||
            normalizedHeadingDelta >= 2.5 ||
            currentRouteId != _lastRenderedRouteId ||
            _streamMapStyle != _lastRenderedTheme ||
            _minimapZoom != _lastRenderedZoom) {
          isDirty = true;
        }
      }

      if (!isDirty && _latestJpegBytes != null) {
        _framesCoalescedCount++;
        _dispatchTransmission(_latestJpegBytes!);
        _isCapturing = false;
        return;
      }

      _lastRenderedPos = userPos;
      _lastRenderedHeading = heading;
      _lastRenderedRouteId = currentRouteId;
      _lastRenderedTheme = _streamMapStyle;
      _lastRenderedZoom = _minimapZoom;
      _mapJpegRendersCount++;

      // Pre-fetch surrounding tiles asynchronously at chosen minimap zoom
      _prefetchSurroundingTiles(userPos, _minimapZoom);

      Uint8List? jpegBytes;

      if (_isForeground) {
        // 1. In foreground: High-Speed Flutter Canvas rendering (Real Map Tiles, Route Polyline, Blue Arrow Puck)
        try {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, 144, 208));

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
          final image = await picture.toImage(w, h);
          final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
          image.dispose();
          picture.dispose();

          if (byteData != null) {
            final rawBytes = byteData.buffer.asUint8List();
            final imgImage = img.Image.fromBytes(
              width: w,
              height: h,
              bytes: rawBytes.buffer,
              order: img.ChannelOrder.rgba,
            );
            jpegBytes = Uint8List.fromList(img.encodeJpg(imgImage, quality: 65));
          }
        } catch (_) {}
      }

      // 2. In background / screen-off: Pure CPU Software Map Renderer (100% CPU RAM, 0% GPU)
      // Runs seamlessly without touching Metal rasterizer, upgraded to match Image 2 visual styling!
      jpegBytes ??= _renderCpuMapFrame(w, h);


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

    if (_pendingTileFetches.length >= 6) return; // P5.4.1.2 Section 42: Bounded pending fetches
    for (int dx = -1; dx <= 1; dx++) {
      for (int dy = -1; dy <= 1; dy++) {
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
      final ext = style == 'hybrid' ? 'jpg' : 'png';

      final apiKey = MapboxConfig.maptilerApiKey;
      final String url = apiKey.isNotEmpty
          ? 'https://api.maptiler.com/maps/$style/256/$z/$x/$y@2x.$ext?key=$apiKey&language=vi'
          : (isDark
              ? 'https://api.maptiler.com/maps/streets-v2-dark/256/$z/$x/$y@2x.png?key=dtGJ2HGvyxQPKNlHznvY&language=vi'
              : 'https://api.maptiler.com/maps/streets-v2/256/$z/$x/$y@2x.png?key=dtGJ2HGvyxQPKNlHznvY&language=vi');

      var response = await http.get(
        Uri.parse(url),
        headers: {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'},
      ).timeout(const Duration(seconds: 4));

      // Fallback
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        final fallbackUrl = (isDark
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

            _cpuTileCache[key] = cpuImg;
            if (_cpuTileCache.length > 100) {
              _cpuTileCache.remove(_cpuTileCache.keys.first);
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

    // 1. Background Fill: Clean Light Cream for Apple Maps (#F4F6F8) or Dark Navy (#0B111A)
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
    _streamState = EspMapStreamState.idle;
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
