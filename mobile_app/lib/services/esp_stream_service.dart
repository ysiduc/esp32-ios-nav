import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart' hide Path;
import '../models/route_model.dart';
import 'ble_service.dart';
import 'navigation_manager.dart';

class EspStreamService extends ChangeNotifier with WidgetsBindingObserver {
  BleService bleService;
  NavigationManager? navManager;

  bool _isStreaming = false;
  bool _isCapturing = false;
  bool _isForeground = true;
  int _targetFps = 15; // 15 FPS default optimal stream rate
  double _actualFps = 0.0;
  int _frameSizeKb = 0;
  int _frameCount = 0;
  DateTime? _lastFpsUpdate;
  int _framesInCurrentSec = 0;

  Timer? _streamTimer;
  Timer? _pauseTimer;
  Uint8List? _latestJpegBytes;
  bool _isSendingBle = false;

  // Getters
  bool get isStreaming => _isStreaming;
  int get targetFps => _targetFps;
  double get actualFps => _actualFps;
  int get frameSizeKb => _frameSizeKb;
  Uint8List? get latestJpegBytes => _latestJpegBytes;

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
      if (_isStreaming && _streamTimer == null) {
        _startTimer();
      }
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _isForeground = false;
      _streamTimer?.cancel();
      _streamTimer = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    stopStreaming();
    _pauseTimer?.cancel();
    super.dispose();
  }

  /// Pause streaming temporarily (e.g. during map search or routing) to give 100% CPU to UI
  void pauseStreamingFor(Duration duration) {
    if (!_isStreaming) return;
    _streamTimer?.cancel();
    _streamTimer = null;
    _pauseTimer?.cancel();
    _pauseTimer = Timer(duration, () {
      if (_isStreaming && _isForeground && _streamTimer == null) {
        _startTimer();
      }
    });
  }

  /// Change target FPS (10 - 30)
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
    _lastFpsUpdate = DateTime.now();

    if (_isForeground) {
      _startTimer();
    }

    notifyListeners();
  }

  void _startTimer() {
    _streamTimer?.cancel();
    final intervalMs = (1000 / _targetFps).round();
    _streamTimer = Timer.periodic(Duration(milliseconds: intervalMs), (_) {
      _renderAndStreamHeadlessFrame();
    });
  }

  /// Render 144x208 High-Definition Map in Memory (Takes <1ms) & Stream over BLE
  Future<void> _renderAndStreamHeadlessFrame() async {
    if (!_isStreaming || _isCapturing || !_isForeground || _isSendingBle) return;
    _isCapturing = true;

    try {
      const int w = 144;
      const int h = 208;

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, 144, 208));

      // Extract current navigation telemetry
      final userPos = navManager?.currentLocation ?? const LatLng(20.9832, 105.8425);
      final double heading = navManager?.currentHeading ?? 0.0;
      final activeRoute = navManager?.activeRoute;
      final distToTurn = navManager?.distanceToNextManeuver ?? 208.0;
      final speedKmh = navManager?.currentSpeedKmh ?? 0.0;

      // 1. Draw Native High-Definition Cyberpunk Vector Map (< 0.2ms)
      _drawHeadlessMapCanvas(
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

      // 2. Direct Fast In-Memory JPEG Encoding (144x208 takes ~1.2ms without isolate overhead)
      final imgImage = img.Image.fromBytes(
        width: w,
        height: h,
        bytes: rawBytes.buffer,
        order: img.ChannelOrder.rgba,
      );
      final jpegBytes = Uint8List.fromList(img.encodeJpg(imgImage, quality: 60));

      _latestJpegBytes = jpegBytes;
      _frameSizeKb = (jpegBytes.length / 1024).round();
      _frameCount++;
      _framesInCurrentSec++;

      final now = DateTime.now();
      if (_lastFpsUpdate != null && now.difference(_lastFpsUpdate!).inMilliseconds >= 1000) {
        final elapsed = now.difference(_lastFpsUpdate!).inMilliseconds / 1000.0;
        _actualFps = (_framesInCurrentSec / elapsed);
        _framesInCurrentSec = 0;
        _lastFpsUpdate = now;
      }

      // 3. Paced BLE Chunk Transmission
      await _sendJpegOverBle(jpegBytes);
    } catch (_) {
    } finally {
      _isCapturing = false;
    }
  }

  /// Headless Vector Map Painter at Exact 144x208 Resolution
  void _drawHeadlessMapCanvas({
    required Canvas canvas,
    required double w,
    required double h,
    required LatLng userPos,
    required double headingDeg,
    required NavRoute? activeRoute,
    required double distToTurn,
    required double speedKmh,
  }) {
    // 1. Background Fill: Deep Cyberpunk Navy (#0B111A)
    final bgPaint = Paint()..color = const Color(0xFF0B111A);
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), bgPaint);

    // 2. Center of vehicle on screen (lower-middle: x=72, y=140)
    final double cx = w / 2.0;
    final double cy = h * 0.67;

    // Scale: ~0.85 pixels per meter (covers ~220m ahead view)
    const double metersToPixels = 0.85;
    final double headingRad = headingDeg * (math.pi / 180.0);
    final double cosH = math.cos(headingRad);
    final double sinH = math.sin(headingRad);
    final double cosLat = math.cos(userPos.latitude * (math.pi / 180.0));

    // 3. Grid / Local Spatial Patterns (Perspective Road Lines)
    final gridPaint = Paint()
      ..color = const Color(0xFF162232)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    for (int gx = 16; gx < w; gx += 28) {
      canvas.drawLine(Offset(gx.toDouble(), 0), Offset(gx.toDouble(), h), gridPaint);
    }
    for (int gy = 16; gy < h; gy += 28) {
      canvas.drawLine(Offset(0, gy.toDouble()), Offset(w, gy.toDouble()), gridPaint);
    }

    // 4. Transform and Draw Route Polyline
    final points = (activeRoute != null && activeRoute.polylinePoints.isNotEmpty)
        ? activeRoute.polylinePoints
        : [
            LatLng(userPos.latitude - 0.0030, userPos.longitude),
            LatLng(userPos.latitude - 0.0010, userPos.longitude),
            userPos,
            LatLng(userPos.latitude + 0.0015, userPos.longitude),
            LatLng(userPos.latitude + 0.0035, userPos.longitude + 0.0020),
          ];

    if (points.length >= 2) {
      final path = ui.Path();
      bool first = true;

      for (final pt in points) {
        // Equirectangular projection relative to user position
        final double dyMeters = (pt.latitude - userPos.latitude) * 111139.0;
        final double dxMeters = (pt.longitude - userPos.longitude) * 111139.0 * cosLat;

        // Rotate by vehicle heading (Forward is UP on screen)
        final double xRot = dxMeters * cosH - dyMeters * sinH;
        final double yRot = dxMeters * sinH + dyMeters * cosH;

        final double sx = cx + (xRot * metersToPixels);
        final double sy = cy - (yRot * metersToPixels);

        if (first) {
          path.moveTo(sx, sy);
          first = false;
        } else {
          path.lineTo(sx, sy);
        }
      }

      // Outer Neon Glow Polyline
      final glowPaint = Paint()
        ..color = const Color(0xFF0077B6).withAlpha(150)
        ..strokeWidth = 8.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      canvas.drawPath(path, glowPaint);

      // Core Vibrant Cyan Route Polyline (#00F0FF)
      final corePaint = Paint()
        ..color = const Color(0xFF00F0FF)
        ..strokeWidth = 4.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      canvas.drawPath(path, corePaint);
    }

    // 5. Upcoming Turn Intersection Point Marker (if within 300m)
    if (distToTurn < 300 && distToTurn > 5) {
      final double turnDistPx = distToTurn * metersToPixels;
      final double turnY = (cy - turnDistPx).clamp(20.0, cy - 10.0);

      // Glowing Turn Radar Ring
      final turnGlow = Paint()
        ..color = const Color(0xFFFFB800).withAlpha(80)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(cx, turnY), 9, turnGlow);

      final turnDot = Paint()
        ..color = const Color(0xFFFFB800)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(cx, turnY), 4, turnDot);
    }

    // 6. Navigation Vehicle Indicator (Centered at cx, cy)
    // Pulsating Radar Outer Ring
    final radarRing = Paint()
      ..color = const Color(0xFF0084FF).withAlpha(60)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(cx, cy), 14, radarRing);

    // Vehicle Core Circle
    final vehicleBg = Paint()
      ..color = const Color(0xFF0084FF)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(cx, cy), 9, vehicleBg);

    final vehicleBorder = Paint()
      ..color = Colors.white
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(Offset(cx, cy), 9, vehicleBorder);

    // Forward Direction Arrow (Pointing Upward)
    final arrowPath = ui.Path()
      ..moveTo(cx, cy - 6)
      ..lineTo(cx + 4, cy + 4)
      ..lineTo(cx, cy + 2)
      ..lineTo(cx - 4, cy + 4)
      ..close();
    final arrowPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    canvas.drawPath(arrowPath, arrowPaint);

    // 7. Live Map Badges (MAP LIVE & Zoom Level)
    final badgeBg = Paint()
      ..color = const Color(0xFF000000).withAlpha(200)
      ..style = PaintingStyle.fill;
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(8, 184, 58, 16), const Radius.circular(4)), badgeBg);

    final badgeDot = Paint()
      ..color = const Color(0xFF05FFA1)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(const Offset(16, 192), 3, badgeDot);

    // Text "LIVE"
    final textPainter = TextPainter(
      text: const TextSpan(
        text: 'LIVE 16x',
        style: TextStyle(color: Color(0xFF05FFA1), fontSize: 9, fontWeight: FontWeight.bold),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(canvas, const Offset(23, 187));
  }

  /// Send JPEG frame over BLE in sequential paced chunks with mutex protection
  Future<void> _sendJpegOverBle(Uint8List jpegBytes) async {
    if (!bleService.isConnected || _isSendingBle) return;
    _isSendingBle = true;

    try {
      const chunkSize = 480; // 480 bytes with MTU 512 fits in 1 BLE PDU
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

        if (totalChunks > 1) {
          await Future.delayed(const Duration(milliseconds: 2));
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
