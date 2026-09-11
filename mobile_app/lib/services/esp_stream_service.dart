import 'dart:async';
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
  Uint8List? _latestJpegBytes;

  // Getters
  bool get isStreaming => _isStreaming;
  int get targetFps => _targetFps;
  double get actualFps => _actualFps;
  int get frameSizeKb => _frameSizeKb;
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

  /// Start 20 FPS JPEG Streaming from a RepaintBoundary widget
  Future<void> startStreaming({GlobalKey? boundaryKey}) async {
    _lastBoundaryKey = boundaryKey ?? _lastBoundaryKey;
    if (_lastBoundaryKey == null) return;

    stopStreaming();
    _isStreaming = true;
    _frameCount = 0;
    _framesInCurrentSec = 0;
    _lastFpsUpdate = DateTime.now();

    final intervalMs = (1000 / _targetFps).round();
    _streamTimer = Timer.periodic(Duration(milliseconds: intervalMs), (_) async {
      await _captureAndStreamFrame(_lastBoundaryKey!);
    });

    notifyListeners();
  }

  /// High-Speed Frame Capture with Isolate Multithreading (20 FPS)
  Future<void> _captureAndStreamFrame(GlobalKey boundaryKey) async {
    if (!_isStreaming || _isCapturing) return;
    _isCapturing = true;

    try {
      final boundary = boundaryKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null || boundary.debugNeedsPaint) {
        _isCapturing = false;
        return;
      }

      // Exact 144px width scaling (9 x 16 MCU blocks for zero tearing)
      final double targetRatio = (144.0 / boundary.size.width).clamp(0.2, 1.2);
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

      // Run pure JPEG encoding on background isolate worker
      final jpegBytes = await compute(_encodeJpegWorker, {
        'width': actualWidth,
        'height': actualHeight,
        'rawBytes': rawBytes,
        'quality': 38,
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

      // Direct BLE stream to ESP32
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
      const chunkSize = 160; // 160 bytes fits in standard iOS/Android MTU without drop
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
        packet.setRange(5, 5 + slice.length, slice);

        await bleService.sendRawBytes(packet);
        if (totalChunks > 1) {
          await Future.delayed(const Duration(milliseconds: 2));
        }
      }
    } catch (_) {
    } finally {
      _isSendingBle = false;
    }
  }

  /// Stop Streaming
  void stopStreaming() {
    _isStreaming = false;
    _isCapturing = false;
    _streamTimer?.cancel();
    _streamTimer = null;
    _actualFps = 0.0;
    notifyListeners();
  }

  @override
  void dispose() {
    stopStreaming();
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
