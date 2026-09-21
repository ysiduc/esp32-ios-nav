import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';
import '../models/route_model.dart';
import 'background_navigation_coordinator.dart';
import 'ble_service.dart';
import 'esp_map_frame_renderer.dart';
import 'navigation_manager.dart';

/// Explicit JPEG Transport Capability & Priority (Sections 3 & 4)
/// Priority: WebSocket Wi-Fi > persistent Wi-Fi TCP > BLE > none
enum EspJpegTransport {
  none,
  ble,
  wifiTcp,
  wifiWebSocket,
}

enum EspMapStreamState {
  idle,
  waitingForConsumer,
  streamingForeground,
  streamingBackground,
}

class EspStreamService extends ChangeNotifier with WidgetsBindingObserver {
  EspMapStreamState _streamState = EspMapStreamState.idle;
  EspMapStreamState get streamState => _streamState;

  BleService bleService;
  NavigationManager? navManager;

  final EspMapFrameRenderer _frameRenderer = EspMapFrameRenderer();
  EspMapFrameRenderer get frameRenderer => _frameRenderer;

  Future<Uint8List?> Function({int? width, int? height})? get mapSnapshotProvider =>
      _frameRenderer.mapSnapshotProvider;
  set mapSnapshotProvider(Future<Uint8List?> Function({int? width, int? height})? provider) {
    _frameRenderer.mapSnapshotProvider = provider;
  }

  EspJpegTransport? _mockTransportForTesting;
  @visibleForTesting
  void setMockTransportForTesting(EspJpegTransport? transport) {
    _mockTransportForTesting = transport;
    _updateStreamDemand();
  }

  @visibleForTesting
  void setForegroundForTesting(bool isForeground) {
    _isForeground = isForeground;
    _updateStreamDemand();
  }

  // Active Transport Detection (Sections 2, 3, 4)
  EspJpegTransport get activeJpegTransport {
    if (_mockTransportForTesting != null) return _mockTransportForTesting!;
    if (_wsClients.isNotEmpty) {
      return EspJpegTransport.wifiWebSocket;
    }
    if (_persistentWifiSocket != null ||
        (bleService.isWifiConnected && bleService.wifiIp != null && bleService.wifiIp != '172.20.10.1')) {
      return EspJpegTransport.wifiTcp;
    }
    if (bleService.isConnected) {
      return EspJpegTransport.ble;
    }
    return EspJpegTransport.none;
  }

  /// JPEG consumer exists when WebSocket, persistent TCP, or BLE is connected (Section 4)
  bool get hasEspDisplayConsumer => activeJpegTransport != EspJpegTransport.none;

  // Thermal & Low-Power States
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

  /// Transport-Specific Target Frame Rates (Sections 6, 7, 8, 9, 31, 32)
  int get effectiveTargetFps {
    if (!hasEspDisplayConsumer) return 0;
    if (_thermalState == 'critical') return _isForeground ? 1 : 0; // minimal or pause

    final transport = activeJpegTransport;
    int baseFps;

    switch (transport) {
      case EspJpegTransport.wifiWebSocket:
        baseFps = _isForeground ? 14 : 6;
        break;
      case EspJpegTransport.wifiTcp:
        baseFps = _isForeground ? 13 : 5;
        break;
      case EspJpegTransport.ble:
        if (_isForeground) {
          // Adaptive 2-5 FPS based on measured BLE chunk transfer throughput (Section 13)
          final lastTransfer = bleService.lastBleTransferDurationMs;
          if (lastTransfer <= 0) {
            baseFps = 3;
          } else {
            baseFps = (1000 / (lastTransfer + 30)).clamp(2.0, 5.0).round();
          }
        } else {
          baseFps = 2; // BLE background (Section 6)
        }
        break;
      case EspJpegTransport.none:
        return 0;
    }

    // Gradual thermal scaling (Section 31):
    // nominal: 100%, fair: ~80%, serious: ~50%
    if (_thermalState == 'serious') {
      baseFps = (baseFps * 0.5).round().clamp(1, 4);
    } else if (_thermalState == 'fair') {
      baseFps = (baseFps * 0.8).round().clamp(2, 11);
    }

    // Low Power Mode reduction (Section 32)
    if (_isLowPowerMode) {
      baseFps = _isForeground ? math.min(baseFps, 8) : math.min(baseFps, 4);
    }

    return baseFps.clamp(1, 14);
  }

  int get targetFps => effectiveTargetFps;

  // Diagnostics & Performance Counters (Section 45 & 63)
  int _mapJpegRendersCount = 0;
  int get mapJpegRendersCount => _mapJpegRendersCount;

  int _framesCoalescedCount = 0;
  int get framesCoalescedCount => _framesCoalescedCount;

  double _actualFps = 0.0;
  double get actualFps => _actualFps;

  double _renderFps = 0.0;
  double get renderFps => _renderFps;

  int _frameSizeKb = 0;
  int get frameSizeKb => _frameSizeKb;

  int _lastAckLatencyMs = 0;
  int get ackLatencyMs => _lastAckLatencyMs;

  int get bleTransferMs => bleService.lastBleTransferDurationMs;
  int get snapshotAgeMs => _frameRenderer.snapshotAgeMs;

  void resetCountersForTesting() {
    _mapJpegRendersCount = 0;
    _framesCoalescedCount = 0;
    _frameCount = 0;
    _actualFps = 0.0;
    _renderFps = 0.0;
    _frameRenderer.resetForTesting();
  }

  bool _isStreaming = false;
  bool get isStreaming => _isStreaming;

  bool _isCapturing = false;
  bool _isForeground = true;
  bool get isForeground => _isForeground;

  int _frameCount = 0;
  int _rendersInCurrentSec = 0;
  int _transmitsInCurrentSec = 0;
  DateTime? _lastFpsUpdate;

  // WebSocket Server & Sockets
  HttpServer? _wsServer;
  final Set<WebSocket> _wsClients = {};
  bool get isWebSocketConnected => _wsClients.isNotEmpty;
  int get wsClientCount => _wsClients.length;

  Socket? _persistentWifiSocket;
  bool _isSendingWifi = false;
  bool _isSendingBle = false;

  bool _wsReadyForNextFrame = true;
  DateTime _lastWsSendTime = DateTime.now();

  Timer? _streamTimer;
  Timer? _pauseTimer;
  Uint8List? _latestJpegBytes;
  Uint8List? get latestJpegBytes => _latestJpegBytes;

  String _streamMapStyle = 'streets-v2';
  String get streamMapStyle => _streamMapStyle;
  set streamMapStyle(String val) {
    if (_streamMapStyle != val) {
      _streamMapStyle = val;
      notifyListeners();
    }
  }

  int _minimapZoom = 17;
  int get minimapZoom => _minimapZoom;
  set minimapZoom(int val) {
    final clamped = val.clamp(14, 18);
    if (_minimapZoom != clamped) {
      _minimapZoom = clamped;
      notifyListeners();
    }
  }

  EspStreamService({required this.bleService, this.navManager}) {
    WidgetsBinding.instance.addObserver(this);
    if (!Platform.environment.containsKey("FLUTTER_TEST")) {
      _startWebSocketServer();
    }
  }

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
                final msg = data is String
                    ? data.trim()
                    : (data is List<int> ? utf8.decode(data, allowMalformed: true).trim() : '');
                if (msg == 'K' || msg == 'ACK' || msg.contains('K')) {
                  _lastAckLatencyMs = DateTime.now().difference(_lastWsSendTime).inMilliseconds;
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _isForeground = true;
      _updateStreamDemand();
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _isForeground = false;
      _updateStreamDemand();
    }
    // Update Central Background Keep-Alive Coordinator (Section 34)
    BackgroundNavigationCoordinator.instance.updateState(
      isBackground: !_isForeground,
      isEspStreamRequired: _isStreaming && hasEspDisplayConsumer,
    );
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
    _frameRenderer.resetForTesting();
    super.dispose();
  }

  void pauseStreamingFor(Duration duration) {
    if (!_isStreaming) return;
    _streamTimer?.cancel();
    _streamTimer = null;
    _pauseTimer?.cancel();
    _pauseTimer = Timer(duration, () {
      if (_isStreaming && hasEspDisplayConsumer && _streamTimer == null) {
        _startTimer();
      }
    });
  }

  void pauseForDuration(Duration duration) => pauseStreamingFor(duration);

  void setTargetFps(int fps) {
    // Deprecated setter preserved for API compatibility
    notifyListeners();
  }

  void startStreaming({GlobalKey? boundaryKey}) {
    stopStreaming();
    _isStreaming = true;
    _frameCount = 0;
    _rendersInCurrentSec = 0;
    _transmitsInCurrentSec = 0;
    _actualFps = 0.0;
    _renderFps = 0.0;
    _lastFpsUpdate = DateTime.now();

    _updateStreamDemand();
  }

  void _updateStreamDemand() {
    if (!_isStreaming) {
      _streamState = EspMapStreamState.idle;
      _streamTimer?.cancel();
      _streamTimer = null;
      _actualFps = 0.0;
      _renderFps = 0.0;
      BackgroundNavigationCoordinator.instance.updateState(
        isBackground: !_isForeground,
        isEspStreamRequired: false,
      );
      notifyListeners();
      return;
    }

    if (!hasEspDisplayConsumer) {
      _streamState = EspMapStreamState.waitingForConsumer;
      _streamTimer?.cancel();
      _streamTimer = null;
      _actualFps = 0.0;
      _renderFps = 0.0;
      BackgroundNavigationCoordinator.instance.updateState(
        isBackground: !_isForeground,
        isEspStreamRequired: false,
      );
      notifyListeners();
      return;
    }

    if (_isForeground) {
      _streamState = EspMapStreamState.streamingForeground;
    } else {
      _streamState = EspMapStreamState.streamingBackground;
    }

    BackgroundNavigationCoordinator.instance.updateState(
      isBackground: !_isForeground,
      isEspStreamRequired: true,
    );

    _startTimer();
    notifyListeners();
  }

  void _startTimer() {
    _streamTimer?.cancel();
    if (!hasEspDisplayConsumer) {
      _streamTimer = null;
      _actualFps = 0.0;
      _renderFps = 0.0;
      return;
    }

    final fps = effectiveTargetFps;
    if (fps <= 0) {
      _streamTimer = null;
      _actualFps = 0.0;
      _renderFps = 0.0;
      return;
    }

    final intervalMs = (1000 / fps).round();
    _streamTimer = Timer.periodic(Duration(milliseconds: intervalMs), (_) {
      _renderAndStreamHeadlessFrame();
    });
  }

  /// Unified Raster Snapshot Rendering & Backpressure Pacing (Sections 10, 11, 12, 16)
  Future<void> _renderAndStreamHeadlessFrame() async {
    if (!_isStreaming || _isCapturing) return;

    final transport = activeJpegTransport;
    if (transport == EspJpegTransport.none) return;

    // Strict Backpressure Check BEFORE rendering/encoding (Section 12)
    if (transport == EspJpegTransport.wifiWebSocket) {
      if (!_wsReadyForNextFrame && DateTime.now().difference(_lastWsSendTime).inMilliseconds < 200) {
        _framesCoalescedCount++;
        return;
      }
    } else if (transport == EspJpegTransport.wifiTcp) {
      if (_isSendingWifi) {
        _framesCoalescedCount++;
        return;
      }
    } else if (transport == EspJpegTransport.ble) {
      if (_isSendingBle) {
        _framesCoalescedCount++;
        return;
      }
    }

    _isCapturing = true;

    try {
      final userPos = navManager?.currentLocation ?? const LatLng(20.9832, 105.8425);
      final double heading = navManager?.effectiveHeading ?? navManager?.currentHeading ?? 0.0;
      final activeRoute = navManager?.activeRoute;
      final isBle = (transport == EspJpegTransport.ble);

      // Render raster frame via EspMapFrameRenderer (Sections 15-26)
      final jpegBytes = await _frameRenderer.renderFrame(
        isForeground: _isForeground,
        userPos: userPos,
        heading: heading,
        activeRoute: activeRoute,
        zoom: _minimapZoom,
        isBle: isBle,
        remainingStepIndex: navManager?.currentStepIndex,
      );

      if (jpegBytes == null) return;

      _mapJpegRendersCount++;
      _rendersInCurrentSec++;
      _latestJpegBytes = jpegBytes;
      _frameSizeKb = (jpegBytes.length / 1024).round();
      _frameCount++;
      _transmitsInCurrentSec++;

      final now = DateTime.now();
      if (_lastFpsUpdate != null && now.difference(_lastFpsUpdate!).inMilliseconds >= 800) {
        final elapsed = now.difference(_lastFpsUpdate!).inMilliseconds / 1000.0;
        _actualFps = (_transmitsInCurrentSec / elapsed).clamp(0.0, 30.0);
        _renderFps = (_rendersInCurrentSec / elapsed).clamp(0.0, 30.0);
        _transmitsInCurrentSec = 0;
        _rendersInCurrentSec = 0;
        _lastFpsUpdate = now;
        notifyListeners();
      }

      // Latest-Frame-Wins Transmission (Section 11)
      _dispatchTransmission(jpegBytes);
    } catch (_) {
    } finally {
      _isCapturing = false;
    }
  }

  void _dispatchTransmission(Uint8List jpegBytes) {
    final transport = activeJpegTransport;

    if (transport == EspJpegTransport.wifiWebSocket) {
      _lastWsSendTime = DateTime.now();
      _wsReadyForNextFrame = false;
      for (final client in _wsClients.toList()) {
        try {
          client.add(jpegBytes);
        } catch (_) {
          _wsClients.remove(client);
        }
      }
      return;
    }

    if (transport == EspJpegTransport.wifiTcp) {
      if (!_isSendingWifi) {
        _sendJpegOverWifi(jpegBytes);
      }
      return;
    }

    if (transport == EspJpegTransport.ble) {
      if (bleService.isConnected && !_isSendingBle) {
        _sendJpegOverBle(jpegBytes);
      }
      return;
    }
  }

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

      final header = ByteData(8);
      header.setUint32(0, 0xAA55AA55, Endian.big);
      header.setUint32(4, jpegBytes.length, Endian.big);

      final packet = Uint8List(8 + jpegBytes.length);
      packet.setRange(0, 8, header.buffer.asUint8List());
      packet.setRange(8, 8 + jpegBytes.length, jpegBytes);

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

  /// Send JPEG frame over BLE with measured transfer duration for adaptive throughput (Sections 13 & 14)
  Future<void> _sendJpegOverBle(Uint8List jpegBytes) async {
    if (!bleService.isConnected || _isSendingBle) return;
    _isSendingBle = true;
    final sw = Stopwatch()..start();

    try {
      final chunkSize = bleService.safeChunkSize;
      final totalLen = jpegBytes.length;
      final totalChunks = (totalLen / chunkSize).ceil();
      final frameId = (_frameCount % 255);

      for (int i = 0; i < totalChunks; i++) {
        if (!bleService.isConnected || !_isStreaming) break;

        final start = i * chunkSize;
        final end = (start + chunkSize > totalLen) ? totalLen : start + chunkSize;
        final slice = jpegBytes.sublist(start, end);

        final packet = Uint8List(5 + slice.length);
        packet[0] = 0xAA;
        packet[1] = 0xBB;
        packet[2] = frameId;
        packet[3] = totalChunks;
        packet[4] = i;
        packet.setRange(5, 5 + slice.length, slice);

        final success = await bleService.sendRawBytes(packet);
        if (!success) {
          bleService.logError('TX [BLE JPEG] Frame #$frameId: Chunk $i/$totalChunks failed');
          break;
        }
        if (i < totalChunks - 1) {
          await Future.delayed(const Duration(milliseconds: 6));
        }
      }
      sw.stop();
      bleService.recordBleTransferDuration(sw.elapsedMilliseconds);
      if (_frameCount % 15 == 0) {
        bleService.logInfo('TX [BLE JPEG] Frame #$frameId in ${sw.elapsedMilliseconds}ms ($totalChunks chunks, $totalLen B)');
      }
    } catch (e) {
      bleService.logError('TX [BLE JPEG] Error: $e');
    } finally {
      _isSendingBle = false;
    }
  }

  void stopStreaming() {
    _isStreaming = false;
    _isCapturing = false;
    _streamState = EspMapStreamState.idle;
    _streamTimer?.cancel();
    _streamTimer = null;
    _pauseTimer?.cancel();
    _pauseTimer = null;
    _persistentWifiSocket?.destroy();
    _persistentWifiSocket = null;
    _actualFps = 0.0;
    _renderFps = 0.0;
    BackgroundNavigationCoordinator.instance.updateState(
      isBackground: !_isForeground,
      isEspStreamRequired: false,
    );
    notifyListeners();
  }
}
