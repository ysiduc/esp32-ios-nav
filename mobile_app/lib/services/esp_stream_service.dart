import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image/image.dart' as img;
import 'ble_service.dart';

class EspStreamService extends ChangeNotifier {
  final BleService bleService;

  bool _isStreaming = false;
  bool _isCapturing = false;
  int _targetFps = 20; // 20 FPS default high-speed stream
  double _actualFps = 0.0;
  int _frameSizeKb = 0;
  int _frameCount = 0;
  DateTime? _lastFpsUpdate;
  int _framesInCurrentSec = 0;

  Timer? _streamTimer;
  HttpServer? _mjpegServer;
  final int _serverPort = 8080;
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

  /// Set target FPS (12, 15, 20, 25, 30)
  void setTargetFps(int fps) {
    _targetFps = fps.clamp(5, 30);
    if (_isStreaming) {
      startStreaming(boundaryKey: _lastBoundaryKey);
    }
    notifyListeners();
  }

  GlobalKey? _lastBoundaryKey;

  /// Start 20-30 FPS JPEG Streaming from a RepaintBoundary widget
  Future<void> startStreaming({GlobalKey? boundaryKey}) async {
    _lastBoundaryKey = boundaryKey ?? _lastBoundaryKey;
    if (_lastBoundaryKey == null) return;

    stopStreaming();
    _isStreaming = true;
    _frameCount = 0;
    _framesInCurrentSec = 0;
    _lastFpsUpdate = DateTime.now();

    // Start local MJPEG HTTP Server on port 8080
    await _startMjpegServer();

    final intervalMs = (1000 / _targetFps).round();
    _streamTimer = Timer.periodic(Duration(milliseconds: intervalMs), (_) async {
      await _captureAndStreamFrame(_lastBoundaryKey!);
    });

    notifyListeners();
  }

  HttpClient? _httpClient;
  bool _isPostingHttp = false;

  Future<void> _postFrameToEsp32(Uint8List jpegBytes) async {
    if (_isPostingHttp) return;
    _isPostingHttp = true;
    try {
      _httpClient ??= HttpClient()
        ..connectionTimeout = const Duration(milliseconds: 300)
        ..idleTimeout = const Duration(seconds: 30);
      final request = await _httpClient!.postUrl(Uri.parse('http://192.168.4.1/api/frame'));
      request.persistentConnection = true;
      request.headers.set('Content-Type', 'image/jpeg');
      request.headers.set('Content-Length', jpegBytes.length.toString());
      request.add(jpegBytes);
      final response = await request.close();
      await response.drain();
    } catch (_) {
    } finally {
      _isPostingHttp = false;
    }
  }

  /// High-Speed Frame Capture with Isolate Multithreading (20-30 FPS)
  Future<void> _captureAndStreamFrame(GlobalKey boundaryKey) async {
    if (!_isStreaming || _isCapturing) return;
    _isCapturing = true;

    try {
      final boundary = boundaryKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null || boundary.debugNeedsPaint) {
        _isCapturing = false;
        return;
      }

      // High-definition scaling for ultra-crisp Retina map stream
      final double targetRatio = (200.0 / boundary.size.width).clamp(0.4, 1.0);
      final ui.Image image = await boundary.toImage(pixelRatio: targetRatio);
      final int actualWidth = image.width;
      final int actualHeight = image.height;
      final ByteData? byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();

      if (byteData == null) {
        _isCapturing = false;
        return;
      }

      final rawBytes = byteData.buffer.asUint8List();

      // Run pure JPEG encoding on background isolate worker with high-clarity quality
      final jpegBytes = await compute(_encodeJpegWorker, {
        'width': actualWidth,
        'height': actualHeight,
        'rawBytes': rawBytes,
        'quality': 65,
      });

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
        notifyListeners();
      }

      // Broadcast frame to MJPEG clients, non-blocking post to Wi-Fi & instant BLE stream
      _broadcastMjpegFrame(jpegBytes);
      unawaited(_postFrameToEsp32(jpegBytes));
      await _sendJpegOverBle(jpegBytes);
    } catch (_) {
    } finally {
      _isCapturing = false;
    }
  }

  bool _isSendingBle = false;

  /// Send JPEG frame over BLE in sequential paced chunks with mutex protection
  Future<void> _sendJpegOverBle(Uint8List jpegBytes) async {
    if (!bleService.isConnected || _isSendingBle) return;
    _isSendingBle = true;

    try {
      const chunkSize = 480; // Fit in 512 MTU for ultra-fast transfer (3-4 packets/frame)
      final totalLen = jpegBytes.length;
      final totalChunks = (totalLen / chunkSize).ceil();
      final frameId = (_frameCount % 255);

      for (int i = 0; i < totalChunks; i++) {
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
        packet.setRange(5, packet.length, slice);

        await bleService.sendRawBytes(packet);
        // Minimal 1ms delay between packets to prevent BLE hardware buffer overflow
        await Future.delayed(const Duration(milliseconds: 1));
      }
    } catch (_) {
    } finally {
      _isSendingBle = false;
    }
  }

  /// Start HTTP MJPEG Stream Server (Accessible at `http://<phone_ip>:8080/stream.mjpg`)
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
    _httpClient?.close();
    super.dispose();
  }
}

/// Top-level worker function running in background isolate for zero UI stutter
Uint8List _encodeJpegWorker(Map<String, dynamic> params) {
  final int width = params['width'] as int;
  final int height = params['height'] as int;
  final Uint8List rawBytes = params['rawBytes'] as Uint8List;
  final int quality = params['quality'] as int;

  final imgImage = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: rawBytes.buffer,
    order: img.ChannelOrder.rgba,
  );

  return Uint8List.fromList(img.encodeJpg(imgImage, quality: quality));
}
