import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image/image.dart' as img;
import 'ble_service.dart';

class EspStreamService extends ChangeNotifier {
  final BleService bleService;

  bool _isStreaming = false;
  bool _isCapturing = false;
  int _targetFps = 20; // 20 FPS target (smooth & high speed)
  double _actualFps = 0.0;
  int _frameSizeKb = 0;
  int _frameCount = 0;
  DateTime? _lastFpsUpdate;
  int _framesInCurrentSec = 0;

  Timer? _streamTimer;
  HttpServer? _mjpegServer;
  int _serverPort = 8080;
  final List<HttpResponse> _mjpegClients = [];

  Uint8List? _latestJpegBytes;

  // Getters
  bool get isStreaming => _isStreaming;
  int get targetFps => _targetFps;
  double get actualFps => _actualFps;
  int get frameSizeKb => _frameSizeKb;
  int get serverPort => _serverPort;
  Uint8List? get latestJpegBytes => _latestJpegBytes;

  EspStreamService({required this.bleService});

  /// Set target FPS (e.g. 12, 15, 20, 24, 30)
  void setTargetFps(int fps) {
    _targetFps = fps.clamp(1, 30);
    if (_isStreaming) {
      startStreaming(boundaryKey: _lastBoundaryKey);
    }
    notifyListeners();
  }

  GlobalKey? _lastBoundaryKey;

  /// Start 20 FPS JPEG Streaming from a RepaintBoundary widget
  Future<void> startStreaming({GlobalKey? boundaryKey}) async {
    _lastBoundaryKey = boundaryKey ?? _lastBoundaryKey;
    if (_lastBoundaryKey == null) return;

    stopStreaming();
    _isStreaming = true;
    _frameCount = 0;
    _framesInCurrentSec = 0;
    _lastFpsUpdate = DateTime.now();

    // Start local MJPEG HTTP Server on port 8080 for Wi-Fi streaming
    _startMjpegServer();

    final intervalMs = (1000 / _targetFps).round();
    _streamTimer = Timer.periodic(Duration(milliseconds: intervalMs), (_) async {
      await _captureAndStreamFrame(_lastBoundaryKey!);
    });

    notifyListeners();
  }

  /// High-Speed Frame Capture and Fast JPEG Encoding (50ms pipeline for 20 FPS)
  Future<void> _captureAndStreamFrame(GlobalKey boundaryKey) async {
    if (!_isStreaming || _isCapturing) return;
    _isCapturing = true;

    try {
      final boundary = boundaryKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null || boundary.debugNeedsPaint) {
        _isCapturing = false;
        return;
      }

      // Capture at 1.0 pixel ratio (350x220 native resolution)
      final ui.Image image = await boundary.toImage(pixelRatio: 1.0);
      final ByteData? byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();

      if (byteData == null) {
        _isCapturing = false;
        return;
      }

      final width = boundary.size.width.toInt();
      final height = boundary.size.height.toInt();
      final rawBytes = byteData.buffer.asUint8List();

      // Convert raw RGBA to img.Image and encode as fast baseline JPEG (quality: 55 for optimal throughput)
      final imgImage = img.Image.fromBytes(
        width: width,
        height: height,
        bytes: rawBytes.buffer,
        order: img.ChannelOrder.rgba,
      );

      final jpegBytes = Uint8List.fromList(img.encodeJpg(imgImage, quality: 55));
      _latestJpegBytes = jpegBytes;
      _frameSizeKb = (jpegBytes.length / 1024).round();
      _frameCount++;
      _framesInCurrentSec++;

      // Update actual FPS metric every second
      final now = DateTime.now();
      if (_lastFpsUpdate != null && now.difference(_lastFpsUpdate!).inMilliseconds >= 1000) {
        final elapsed = now.difference(_lastFpsUpdate!).inMilliseconds / 1000.0;
        _actualFps = (_framesInCurrentSec / elapsed);
        _framesInCurrentSec = 0;
        _lastFpsUpdate = now;
        notifyListeners();
      }

      // 1. Broadcast frame to all connected Wi-Fi / MJPEG clients
      _broadcastMjpegFrame(jpegBytes);

      // 2. Send over BLE in chunked MTU packets if BLE is connected
      if (bleService.isConnected) {
        _sendJpegOverBle(jpegBytes);
      }
    } catch (_) {
    } finally {
      _isCapturing = false;
    }
  }

  /// Send JPEG frame over BLE in chunks
  void _sendJpegOverBle(Uint8List jpegBytes) async {
    if (!bleService.isConnected) return;

    const chunkSize = 240; // Fit in 256 MTU
    final totalLen = jpegBytes.length;
    final totalChunks = (totalLen / chunkSize).ceil();
    final frameId = (_frameCount % 255);

    for (int i = 0; i < totalChunks; i++) {
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
      packet.setRange(5, packet.length, slice);

      try {
        await bleService.connectedDevice?.requestMtu(256);
      } catch (_) {}
    }
  }

  /// Start HTTP MJPEG Stream Server (Accessible at http://<phone_ip>:8080/stream.mjpg)
  Future<void> _startMjpegServer() async {
    if (_mjpegServer != null) return;

    try {
      _mjpegServer = await HttpServer.bind(InternetAddress.anyIPv4, _serverPort);
      _mjpegServer!.listen((HttpRequest request) {
        final path = request.uri.path;

        if (path == '/stream.mjpg' || path == '/mjpg') {
          // Continuous MJPEG Stream
          request.response.headers.set('Content-Type', 'multipart/x-mixed-replace; boundary=--myboundary');
          request.response.headers.set('Cache-Control', 'no-cache, private');
          request.response.headers.set('Connection', 'close');

          _mjpegClients.add(request.response);
        } else if (path == '/frame.jpg' || path == '/esp32.jpg' || path == '/') {
          // Single Snapshot Frame
          if (_latestJpegBytes != null) {
            request.response.headers.set('Content-Type', 'image/jpeg');
            request.response.headers.set('Content-Length', _latestJpegBytes!.length.toString());
            request.response.add(_latestJpegBytes!);
          }
          request.response.close();
        } else {
          request.response.statusCode = HttpStatus.notFound;
          request.response.close();
        }
      });
    } catch (_) {}
  }

  void _broadcastMjpegFrame(Uint8List jpegBytes) {
    if (_mjpegClients.isEmpty) return;

    final header = utf8.encode('--myboundary\r\nContent-Type: image/jpeg\r\nContent-Length: ${jpegBytes.length}\r\n\r\n');
    final footer = utf8.encode('\r\n');

    final deadClients = <HttpResponse>[];

    for (final client in _mjpegClients) {
      try {
        client.add(header);
        client.add(jpegBytes);
        client.add(footer);
      } catch (_) {
        deadClients.add(client);
      }
    }

    _mjpegClients.removeWhere((c) => deadClients.contains(c));
  }

  /// Stop Streaming
  void stopStreaming() {
    _isStreaming = false;
    _isCapturing = false;
    _streamTimer?.cancel();
    _streamTimer = null;
    _actualFps = 0.0;

    for (final client in _mjpegClients) {
      try {
        client.close();
      } catch (_) {}
    }
    _mjpegClients.clear();

    _mjpegServer?.close(force: true);
    _mjpegServer = null;

    notifyListeners();
  }

  @override
  void dispose() {
    stopStreaming();
    super.dispose();
  }
}
