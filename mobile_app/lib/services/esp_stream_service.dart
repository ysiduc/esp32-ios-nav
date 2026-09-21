import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';
import '../models/route_model.dart';
import 'ble_service.dart';
import 'esp_raster_map_renderer.dart';
import 'navigation_manager.dart';

/// Explicit JPEG Transport Capability & Priority (Sections 5 & 6)
/// Priority: WebSocket Wi-Fi > persistent Wi-Fi TCP > BLE > none
enum EspJpegTransport {
  none,
  ble,
  wifiTcp,
  wifiWebSocket,
}

/// Authoritative ESP Display Mode State Matrix (Sections 1-5, 67)
/// Mode A: Standby + No WiFi -> standbyStatic (Static bg_map.jpg, NO continuous JPEG over BLE)
/// Mode B: Standby + WiFi -> standbyWifiMap (Live current-location map at 8-15 FPS)
/// Mode C: Navigation + No WiFi -> navigationBleMap (Live navigation map at 5-12 FPS over BLE)
/// Mode D: Navigation + WiFi -> navigationWifiMap (Live navigation map at 12-25 FPS ACK-driven)
enum EspDisplayMode {
  standbyStatic,
  standbyWifiMap,
  navigationBleMap,
  navigationWifiMap,
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

  final EspRasterMapRenderer _frameRenderer = EspRasterMapRenderer();
  EspRasterMapRenderer get frameRenderer => _frameRenderer;

  String get streamMapStyle => _frameRenderer.streamMapStyle;
  set streamMapStyle(String style) {
    _frameRenderer.streamMapStyle = style;
    notifyListeners();
  }

  void pauseForDuration(Duration duration) => pauseStreamingFor(duration);

  int get targetFps => effectiveTargetFps;
  void setTargetFps(int fps) {
    notifyListeners();
  }

  int get minimapZoom => _frameRenderer.minimapZoom;
  set minimapZoom(int val) {
    _frameRenderer.minimapZoom = val;
    notifyListeners();
  }

  Uint8List? get latestJpegBytes => _frameRenderer.lastGoodJpeg;

  EspJpegTransport? _mockTransportForTesting;
  @visibleForTesting
  void setMockTransportForTesting(EspJpegTransport? transport) {
    _mockTransportForTesting = transport;
    _updateStreamDemand();
  }

  bool _isForeground = true;
  bool get isForeground => _isForeground;

  @visibleForTesting
  void setForegroundForTesting(bool isForeground) {
    _isForeground = isForeground;
    _updateStreamDemand();
  }

  String _thermalState = 'nominal';
  String get thermalState => _thermalState;

  @visibleForTesting
  void setThermalStateForTesting(String state) {
    _thermalState = state;
    notifyListeners();
  }

  bool _isLowPowerMode = false;
  bool get isLowPowerMode => _isLowPowerMode;

  @visibleForTesting
  void setLowPowerModeForTesting(bool enabled) {
    _isLowPowerMode = enabled;
    notifyListeners();
  }

  /// Pure display mode calculation (Sections 1-5, 67)
  static EspDisplayMode calculateDisplayMode({
    required bool isNavigating,
    required bool isWifiAvailable,
    required bool isBleAvailable,
  }) {
    if (!isNavigating) {
      if (isWifiAvailable) {
        return EspDisplayMode.standbyWifiMap;
      } else {
        return EspDisplayMode.standbyStatic;
      }
    } else {
      if (isWifiAvailable) {
        return EspDisplayMode.navigationWifiMap;
      } else if (isBleAvailable) {
        return EspDisplayMode.navigationBleMap;
      } else {
        return EspDisplayMode.standbyStatic;
      }
    }
  }

  /// Evaluates current active display mode
  EspDisplayMode get currentDisplayMode {
    final isNav = navManager?.isNavigating ?? false;
    final isWifi = isWifiUsable;
    final isBle = bleService.isConnected || _mockTransportForTesting == EspJpegTransport.ble;
    return calculateDisplayMode(
      isNavigating: isNav,
      isWifiAvailable: isWifi,
      isBleAvailable: isBle,
    );
  }

  /// Wi-Fi connection availability
  bool get isWifiUsable {
    if (_mockTransportForTesting == EspJpegTransport.wifiWebSocket ||
        _mockTransportForTesting == EspJpegTransport.wifiTcp) {
      return true;
    }
    return _wsClients.isNotEmpty || _persistentWifiSocket != null || bleService.isWifiConnected;
  }

  /// Active JPEG transport based on state matrix & Wi-Fi priority (Section 6)
  EspJpegTransport get activeJpegTransport {
    if (_mockTransportForTesting != null) {
      return _mockTransportForTesting!;
    }
    final mode = currentDisplayMode;
    switch (mode) {
      case EspDisplayMode.standbyStatic:
        // Standby without Wi-Fi must NEVER stream JPEGs over BLE! (Sections 1, 49, 68)
        return EspJpegTransport.none;
      case EspDisplayMode.standbyWifiMap:
      case EspDisplayMode.navigationWifiMap:
        if (_wsClients.isNotEmpty) return EspJpegTransport.wifiWebSocket;
        if (_persistentWifiSocket != null) return EspJpegTransport.wifiTcp;
        if (bleService.isWifiConnected) return EspJpegTransport.wifiWebSocket;
        return EspJpegTransport.none;
      case EspDisplayMode.navigationBleMap:
        return bleService.isConnected ? EspJpegTransport.ble : EspJpegTransport.none;
    }
  }

  bool get hasEspDisplayConsumer => activeJpegTransport != EspJpegTransport.none;

  /// Effective target FPS based on mode, ACK latency, BLE throughput, and thermals (Sections 25-35)
  int get effectiveTargetFps {
    final mode = currentDisplayMode;
    int baseFps;

    switch (mode) {
      case EspDisplayMode.standbyStatic:
        return 0; // 0 FPS: Static image displayed by firmware (Section 1 & 68)

      case EspDisplayMode.standbyWifiMap:
        // Mode B: Standby + WiFi -> 8-15 FPS (Section 2 & 35)
        baseFps = 10;
        break;

      case EspDisplayMode.navigationBleMap:
        // Mode C: Navigation + BLE -> 5-12 FPS based on real BLE throughput (Section 3, 29, 70)
        final transferMs = bleService.lastBleTransferDurationMs;
        if (transferMs > 0) {
          final safeFps = (1000 / (transferMs + 20)).floor();
          baseFps = safeFps.clamp(5, 12);
        } else {
          baseFps = 7;
        }
        break;

      case EspDisplayMode.navigationWifiMap:
        // Mode D: Navigation + WiFi -> 12-25 FPS ACK-driven (Sections 4, 25, 26, 71)
        if (_avgAckLatencyMs > 0) {
          final achievableFps = (1000 / (_avgAckLatencyMs + 10)).floor();
          baseFps = achievableFps.clamp(12, 25);
        } else {
          baseFps = 20; // Nominal high-rate target
        }
        break;
    }

    // Thermal adaptation: quality reduced first, then FPS only on serious/critical (Sections 36 & 37)
    if (_thermalState == 'critical') {
      return 1;
    } else if (_thermalState == 'serious') {
      return (baseFps * 0.65).round().clamp(1, 14);
    }

    if (_isLowPowerMode) {
      return baseFps.clamp(1, 12);
    }

    return baseFps;
  }

  /// Effective JPEG quality (Sections 30, 31, 37)
  int get effectiveJpegQuality {
    final isBle = activeJpegTransport == EspJpegTransport.ble;
    int quality = isBle ? 45 : 70;

    switch (_thermalState) {
      case 'fair':
        quality -= isBle ? 10 : 10; // First action: reduce quality (Section 37)
        break;
      case 'serious':
        quality -= isBle ? 15 : 20;
        break;
      case 'critical':
        quality -= isBle ? 15 : 25;
        break;
    }

    if (_isLowPowerMode) {
      quality -= 10;
    }

    return quality.clamp(25, 80);
  }

  // Network & Transport State
  HttpServer? _wsServer;
  final List<WebSocket> _wsClients = [];
  Socket? _persistentWifiSocket;
  Timer? _streamTimer;
  Timer? _pauseTimer;
  bool _isStreaming = false;
  bool get isStreaming => _isStreaming;
  bool _isSendingBle = false;
  bool _isSendingWifi = false;
  bool _wsReadyForNextFrame = true;
  DateTime _lastWsSendTime = DateTime.fromMillisecondsSinceEpoch(0);

  int _avgAckLatencyMs = 35;
  int get avgAckLatencyMs => _avgAckLatencyMs;
  int get mapJpegRendersCount => _frameRenderer.renderCount;
  double get renderFps => _actualFps;
  int _frameSizeKb = 0;
  int get frameSizeKb => _frameSizeKb;
  int get ackLatencyMs => _avgAckLatencyMs;
  int get bleTransferMs => bleService.lastBleTransferDurationMs;
  int get snapshotAgeMs => 0;


  double _actualFps = 0.0;
  double get actualFps => _actualFps;
  int _frameCount = 0;
  int get frameCount => _frameCount;
  int _framesCoalescedCount = 0;
  int get framesCoalescedCount => _framesCoalescedCount;
  DateTime _lastFpsCheckTime = DateTime.now();
  int _framesSinceLastFpsCheck = 0;

  static const MethodChannel _thermalChannel = MethodChannel('com.ysiduc.esp32_nav/thermal');

  EspStreamService({
    required this.bleService,
    this.navManager,
  }) {
    WidgetsBinding.instance.addObserver(this);
    _initWebSocketServer();
    _initThermalListener();

    bleService.addListener(_onDependenciesChanged);
    navManager?.addListener(_onDependenciesChanged);
    _updateStreamDemand();
  }

  void updateReferences(BleService ble, [NavigationManager? nav]) {
    updateDependencies(ble: ble, nav: nav);
  }

  void updateDependencies({required BleService ble, NavigationManager? nav}) {
    bleService.removeListener(_onDependenciesChanged);
    navManager?.removeListener(_onDependenciesChanged);

    bleService = ble;
    navManager = nav;

    bleService.addListener(_onDependenciesChanged);
    navManager?.addListener(_onDependenciesChanged);
    _updateStreamDemand();
  }

  void _onDependenciesChanged() {
    _updateStreamDemand();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isForeground = (state == AppLifecycleState.resumed);
    _updateStreamDemand();
  }

  void _initThermalListener() {
    _thermalChannel.setMethodCallHandler((call) async {
      if (call.method == 'onThermalStateChanged') {
        _thermalState = call.arguments['thermalState'] ?? 'nominal';
        _isLowPowerMode = call.arguments['isLowPowerMode'] ?? false;
        notifyListeners();
      }
    });
  }

  /// Initialize WebSocket Server (port 8080) for ESP32 Wi-Fi JPEG receiver
  Future<void> _initWebSocketServer() async {
    if (_wsServer != null) return;
    try {
      _wsServer = await HttpServer.bind(InternetAddress.anyIPv4, 8080, shared: true);
      _wsServer!.listen((HttpRequest request) async {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          try {
            final ws = await WebSocketTransformer.upgrade(request);
            _wsClients.add(ws);
            _wsReadyForNextFrame = true;
            bleService.setWifiConnected();
            _updateStreamDemand();

            ws.listen(
              (message) {
                // Section 26: Primary pacing signal - ESP sends 'K' after JPEG render
                if (message == 'K') {
                  final now = DateTime.now();
                  final latency = now.difference(_lastWsSendTime).inMilliseconds;
                  if (latency > 0 && latency < 500) {
                    _avgAckLatencyMs = ((_avgAckLatencyMs * 3 + latency) ~/ 4).clamp(10, 200);
                  }
                  _wsReadyForNextFrame = true;
                }
              },
              onDone: () {
                _wsClients.remove(ws);
                if (_wsClients.isEmpty && _persistentWifiSocket == null) {
                  bleService.setWifiDisconnected();
                }
                _updateStreamDemand();
              },
              onError: (_) {
                _wsClients.remove(ws);
                if (_wsClients.isEmpty && _persistentWifiSocket == null) {
                  bleService.setWifiDisconnected();
                }
                _updateStreamDemand();
              },
            );
          } catch (_) {}
        }
      });
    } catch (_) {}
  }

  /// Updates streaming timer & state demand based on pure state matrix (Sections 1-8, 48)
  void _updateStreamDemand() {
    final mode = currentDisplayMode;
    final transport = activeJpegTransport;

    if (transport == EspJpegTransport.none || mode == EspDisplayMode.standbyStatic) {
      // In standby without Wi-Fi: NO continuous JPEG over BLE (Sections 1, 49, 68)
      if (_streamTimer != null) {
        _streamTimer?.cancel();
        _streamTimer = null;
      }
      _streamState = (mode == EspDisplayMode.standbyStatic)
          ? EspMapStreamState.idle
          : EspMapStreamState.waitingForConsumer;
      _actualFps = 0.0;
      notifyListeners();
      return;
    }

    // Active streaming: standbyWifiMap, navigationBleMap, or navigationWifiMap
    _streamState = _isForeground
        ? EspMapStreamState.streamingForeground
        : EspMapStreamState.streamingBackground;

    _startCadenceTimer();
    notifyListeners();
  }

  void _startCadenceTimer() {
    _streamTimer?.cancel();
    final fps = effectiveTargetFps;
    if (fps <= 0) return;

    final intervalMs = (1000 / fps).round().clamp(35, 1000);
    _streamTimer = Timer.periodic(Duration(milliseconds: intervalMs), (_) {
      _dispatchStreamTick();
    });
  }

  /// Core stream tick: render raster frame & dispatch via active transport (Sections 19, 20, 21, 26, 29)
  Future<void> _dispatchStreamTick() async {
    if (!hasEspDisplayConsumer) return;

    final nav = navManager;
    final userPos = nav?.currentLocation ?? const LatLng(21.0285, 105.8542);
    final heading = nav?.currentHeading ?? 0.0;
    final route = nav?.activeRoute ?? nav?.previewRoute;
    final isNav = nav?.isNavigating ?? false;
    final transport = activeJpegTransport;
    final quality = effectiveJpegQuality;

    // Zero-queue backpressure: for Wi-Fi, only dispatch if previous frame is ACKed or watchdog expired
    if (transport == EspJpegTransport.wifiWebSocket || transport == EspJpegTransport.wifiTcp) {
      final now = DateTime.now();
      final elapsed = now.difference(_lastWsSendTime).inMilliseconds;
      if (!_wsReadyForNextFrame && elapsed < 220) {
        _framesCoalescedCount++;
        return; // Drop intermediate frame to prevent packet queuing
      }
    } else if (transport == EspJpegTransport.ble) {
      if (_isSendingBle) {
        _framesCoalescedCount++;
        return; // Drop intermediate frame while previous BLE frame is transferring
      }
    }

    final jpeg = _frameRenderer.renderFrame(
      userPos: userPos,
      headingDeg: heading,
      activeRoute: route,
      isNavigating: isNav,
      quality: quality,
    );

    if (jpeg == null || jpeg.isEmpty) return;

    _recordFrameSent(jpeg.length);

    if (transport == EspJpegTransport.wifiWebSocket || transport == EspJpegTransport.wifiTcp) {
      _sendJpegOverWifi(jpeg);
    } else if (transport == EspJpegTransport.ble) {
      _sendJpegOverBle(jpeg);
    }
  }

  void _recordFrameSent(int byteLength) {
    _frameSizeKb = (byteLength / 1024).round();
    _frameCount++;
    _framesSinceLastFpsCheck++;
    final now = DateTime.now();
    final elapsed = now.difference(_lastFpsCheckTime).inMilliseconds;
    if (elapsed >= 1000) {
      _actualFps = (_framesSinceLastFpsCheck * 1000.0) / elapsed;
      _framesSinceLastFpsCheck = 0;
      _lastFpsCheckTime = now;
      notifyListeners();
    }
  }

  /// Dispatch JPEG over Wi-Fi (WebSocket or raw TCP)
  void _sendJpegOverWifi(Uint8List jpegBytes) {
    if (_isSendingWifi) return;
    _isSendingWifi = true;
    _wsReadyForNextFrame = false;
    _lastWsSendTime = DateTime.now();

    try {
      if (_wsClients.isNotEmpty) {
        for (final ws in List.from(_wsClients)) {
          try {
            ws.add(jpegBytes);
          } catch (_) {
            _wsClients.remove(ws);
          }
        }
      } else if (_persistentWifiSocket != null) {
        try {
          final header = Uint8List(4);
          final byteData = ByteData.sublistView(header);
          byteData.setUint32(0, jpegBytes.length, Endian.big);
          _persistentWifiSocket!.add(header);
          _persistentWifiSocket!.add(jpegBytes);
        } catch (_) {
          _persistentWifiSocket?.destroy();
          _persistentWifiSocket = null;
        }
      }
    } finally {
      _isSendingWifi = false;
    }
  }

  /// Send JPEG frame over BLE in MTU-safe chunks with transfer duration tracking (Section 29 & 30)
  Future<void> _sendJpegOverBle(Uint8List jpegBytes) async {
    if (!bleService.isConnected || _isSendingBle) return;
    _isSendingBle = true;
    final startTime = DateTime.now();

    try {
      final chunkSize = bleService.safeChunkSize;
      final totalLen = jpegBytes.length;
      final totalChunks = (totalLen / chunkSize).ceil();
      final frameId = (_frameCount % 255);

      for (int i = 0; i < totalChunks; i++) {
        if (!bleService.isConnected) break;

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
        if (!success) break;

        if (i < totalChunks - 1) {
          await Future.delayed(const Duration(milliseconds: 6));
        }
      }

      final transferMs = DateTime.now().difference(startTime).inMilliseconds;
      bleService.recordBleTransferDuration(transferMs);
    } catch (_) {
    } finally {
      _isSendingBle = false;
    }
  }

  void startStreaming({GlobalKey? boundaryKey}) {
    _isStreaming = true;
    _updateStreamDemand();
  }

  void stopStreaming() {
    _isStreaming = false;
    _streamTimer?.cancel();
    _streamTimer = null;
    _pauseTimer?.cancel();
    _pauseTimer = null;
    _actualFps = 0.0;
    _streamState = EspMapStreamState.idle;
    notifyListeners();
  }

  void pauseStreamingFor(Duration duration) {
    _streamTimer?.cancel();
    _streamTimer = null;
    _pauseTimer?.cancel();
    _pauseTimer = Timer(duration, () {
      _updateStreamDemand();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    bleService.removeListener(_onDependenciesChanged);
    navManager?.removeListener(_onDependenciesChanged);
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
    super.dispose();
  }
}
