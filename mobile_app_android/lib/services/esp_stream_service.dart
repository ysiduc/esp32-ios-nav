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
import 'package:shared_preferences/shared_preferences.dart';
import '../config/mapbox_config.dart';
import '../models/route_model.dart';
import 'ble_service.dart';
import 'navigation_manager.dart';
import 'osm_road_guide_matcher.dart';
import 'osm_vector_tile.dart';

class EspStreamService extends ChangeNotifier with WidgetsBindingObserver {
  BleService bleService;
  NavigationManager? navManager;

  bool _isSendingWifi = false;

  /// Optional hook to take live vector snapshots from MapLibre Goong map
  Future<Uint8List?> Function({int? width, int? height})? mapSnapshotProvider;

  bool _isStreaming = false;
  bool _isCapturing = false;
  bool _isForeground = true;
  bool _suppressStreamForBleNav = false;
  bool _resumeStreamAfterBleNav = false;
  bool get isBleOnlyNavMode => _suppressStreamForBleNav;
  int _targetFps = 30; // High-speed 30 FPS target for Raw TCP / double-buffered ESP32 Wi-Fi streaming
  double _actualFps = 28.0;
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
  final Map<String, Uint32List> _cpuTileRgba32 = {}; // Fast 32-bit pixel view for 30 FPS software rasterizer
  final Map<String, Uint8List> _tileMasks = {}; // 1 = building footprint (for pseudo-3D extrusion)
  final Set<String> _pendingTileFetches = {};

  // OpenStreetMap 3D Vector Tile Cache & Software Block Renderer
  final Map<String, OsmVectorTile> _osmTileCache = {};
  final Map<String, OsmVectorTile> _osmSuppBuildingCache = {};
  final Set<String> _pendingOsmFetches = {};
  final Set<String> _pendingSuppFetches = {};
  final Osm3dRenderer _osm3dRenderer = Osm3dRenderer();
  String? _openFreeMapTileTemplate;
  double? _smoothedRenderHeading;

  // Persistent TCP Socket for continuous screen-off background streaming (SoftAP mode)
  Socket? _persistentWifiSocket;

  // WebSocket Server for iPhone Hotspot Master (IP 172.20.10.1:8080)
  HttpServer? _wsServer;
  // Reverse TCP Server for ESP32 STA Hotspot fallback (port 8082)
  ServerSocket? _reverseTcpServer;
  final Set<WebSocket> _wsClients = {};
  bool get isWebSocketConnected => _wsClients.isNotEmpty;
  int get wsClientCount => _wsClients.length;

  // Getters
  bool get isStreaming => _isStreaming;
  int get targetFps => _targetFps;
  double get actualFps => _actualFps;
  int get frameSizeKb => _frameSizeKb;
  Uint8List? get latestJpegBytes => _latestJpegBytes;

  static const Set<String> supportedMapStyles = {
    'osm-3d',
    'osm-3d-dark',
    'goong-streets',
    'goong-dark',
    'streets-v2',
    'streets-v2-dark',
    'hybrid',
  };

  String _streamMapStyle = 'osm-3d';
  bool _hasUserSelectedMapStyle = false;
  String get streamMapStyle => _streamMapStyle;
  bool get hasUserSelectedMapStyle => _hasUserSelectedMapStyle;
  bool get _isOsm3dStyle => _streamMapStyle == 'osm-3d' || _streamMapStyle == 'osm-3d-dark';

  void _clearTileCaches() {
    _tileCache.forEach((_, img) => img.dispose());
    _tileCache.clear();
    _cpuTileCache.clear();
    _cpuTileRgba32.clear();
    _tileMasks.clear();
    _lastPrefetchPos = null;
  }

  Future<void> _persistMapPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('esp_stream_map_style', _streamMapStyle);
      await prefs.setBool('esp_stream_map_style_custom', _hasUserSelectedMapStyle);
      await prefs.setInt('esp_minimap_zoom', _minimapZoom);
    } catch (_) {}
  }

  Future<void> _loadSavedMapPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedZoom = prefs.getInt('esp_minimap_zoom');
      final savedCustom = prefs.getBool('esp_stream_map_style_custom') ?? false;
      final savedStyle = prefs.getString('esp_stream_map_style');
      var changed = false;
      if (savedZoom != null && savedZoom >= 14 && savedZoom <= 18 && savedZoom != _minimapZoom) {
        _minimapZoom = savedZoom;
        changed = true;
      }
      _hasUserSelectedMapStyle = savedCustom;
      if (savedCustom && savedStyle != null && supportedMapStyles.contains(savedStyle) && savedStyle != _streamMapStyle) {
        _streamMapStyle = savedStyle;
        changed = true;
      }
      if (changed) {
        _clearTileCaches();
        notifyListeners();
      }
    } catch (_) {}
  }

  set streamMapStyle(String val) {
    final normalized = supportedMapStyles.contains(val) ? val : 'osm-3d';
    if (_streamMapStyle != normalized) {
      final keepOsmCache = _isOsm3dStyle && (normalized == 'osm-3d' || normalized == 'osm-3d-dark');
      _streamMapStyle = normalized;
      if (!keepOsmCache) {
        _clearTileCaches();
      }
      if (_hasUserSelectedMapStyle) {
        _persistMapPrefs();
      }
      notifyListeners();
    }
  }

  Future<void> setUserMapStyle(String val) async {
    final normalized = supportedMapStyles.contains(val) ? val : 'osm-3d';
    final keepOsmCache = _isOsm3dStyle && (normalized == 'osm-3d' || normalized == 'osm-3d-dark');
    _hasUserSelectedMapStyle = true;
    _streamMapStyle = normalized;
    if (!keepOsmCache) {
      _clearTileCaches();
    }
    notifyListeners();
    await _persistMapPrefs();
  }

  int _minimapZoom = 17; // 14 to 18 (default 17 for detailed building polygons & POIs like Image 2)
  int get minimapZoom => _minimapZoom;
  set minimapZoom(int val) {
    final clamped = val.clamp(14, 18);
    if (_minimapZoom != clamped) {
      _minimapZoom = clamped;
      _clearTileCaches();
      _persistMapPrefs();
      notifyListeners();
    }
  }

  bool _lastBleConnected = false;

  bool _lastHotspotMode = false;
  String? _lastKnownStaIp;

  void _handleBleConnectionChange() {
    final nowConnected = bleService.isConnected;
    if (_lastBleConnected && !nowConnected) {
      broadcastTelemetry('{"type":"APP_DISCONNECT"}');
    }
    _lastBleConnected = nowConnected;

    final nowHotspotMode = bleService.hotspotModeEnabled;
    final nowStaIp = normalizeIpAddress(bleService.espStaIp);
    final bool modeChanged = nowHotspotMode != _lastHotspotMode;
    final String? normalizedActiveIp = normalizeIpAddress(_activeTcpTargetIp);
    final bool staIpChanged = nowStaIp != null &&
        nowStaIp.isNotEmpty &&
        nowStaIp != _lastKnownStaIp;

    _lastHotspotMode = nowHotspotMode;
    _lastKnownStaIp = nowStaIp;

    final bool activeDiffersFromSta =
        normalizedActiveIp != null && normalizedActiveIp != nowStaIp;
    if (modeChanged || (staIpChanged && activeDiffersFromSta)) {
      if (_tcpApSocket != null) {
        _closeTcpApSocket(_tcpApSocket!, notifyIfEmpty: true, scheduleReconnect: true);
      }
      if (_apSocket != null) {
        try {
          _apSocket!.close();
        } catch (_) {}
        _apSocket = null;
      }
      scheduleMicrotask(_tryConnectEspAp);
    } else if (_tcpApSocket == null && nowStaIp != null && nowStaIp.isNotEmpty) {
      scheduleMicrotask(_tryConnectEspAp);
    }
  }

  EspStreamService({required this.bleService, this.navManager}) {
    WidgetsBinding.instance.addObserver(this);
    _lastBleConnected = bleService.isConnected;
    _lastHotspotMode = bleService.hotspotModeEnabled;
    _lastKnownStaIp = bleService.espStaIp;
    bleService.addListener(_handleBleConnectionChange);
    _loadSavedMapPrefs();
    _startWebSocketServer();
    _startReverseTcpServer();
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
            final remoteIp = request.connectionInfo?.remoteAddress.address;
            final socket = await WebSocketTransformer.upgrade(request);
            _registerWsClient(socket, remoteIp: remoteIp);
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
  // ESP32 SoftAP mode: ESP32 phát Wi-Fi "ysiducnaga" (192.168.4.1).
  // Primary: High-speed Lock-Free Raw TCP Stream Server port 8081 (30 FPS, <=32KB JPEG).
  // Fallback: Legacy WebSocket ws://192.168.4.1:8080 if firmware < v2.
  // ───────────────────────────────────────────────────────────────────────
  static const String espApIp = '192.168.4.1';
  static const int espApTcpPort = 8081;
  static const int espHotspotReverseTcpPort = 8082;
  static const String espApWsUrl = 'ws://192.168.4.1:8080';
  Timer? _apConnectTimer;
  Timer? _apKeepaliveTimer;
  Timer? _apReconnectTimer;
  Timer? _apConnectTimeoutTimer;
  ConnectionTask<Socket>? _apConnectTask;
  Socket? _tcpApSocket;
  String? _activeTcpTargetIp;
  String? _lastHotspotPeerIp;
  StreamSubscription<Uint8List>? _tcpApSub;
  static const int maxTcpInFlightFrames = 2;
  int _tcpInFlightFrames = 0;
  DateTime _lastTcpSendTime = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _awaitingTcpAckSince;
  img.Image? _reusableCpuFrame;

  /// Decrements in-flight frame counter for each ESP32 'K' (0x4B) ACK byte received.
  @visibleForTesting
  static int computeRemainingTcpInFlight({
    required int currentInFlight,
    required List<int> rxChunk,
    int maxInFlight = maxTcpInFlightFrames,
  }) {
    int acks = 0;
    for (final b in rxChunk) {
      if (b == 0x4B) acks++;
    }
    return (currentInFlight - acks).clamp(0, maxInFlight);
  }

  /// Returns whether another TCP JPEG frame may be dispatched under bounded pipelining.
  @visibleForTesting
  static bool canSendNextTcpFrame({
    required int inFlight,
    required int elapsedSinceLastSendMs,
    required int staleAckTimeoutMs,
    int maxInFlight = maxTcpInFlightFrames,
  }) {
    if (inFlight < maxInFlight) return true;
    return elapsedSinceLastSendMs >= staleAckTimeoutMs;
  }

  img.Image _acquireReusableCpuFrame(int w, int h) {
    final existing = _reusableCpuFrame;
    if (existing != null &&
        existing.width == w &&
        existing.height == h &&
        existing.numChannels == 4) {
      return existing;
    }
    final created = img.Image(width: w, height: h, numChannels: 4);
    _reusableCpuFrame = created;
    return created;
  }

  static Uint8List _frameRawRgbaView(img.Image frame, int w, int h) {
    final expectedBytes = w * h * 4;
    if (frame.buffer.lengthInBytes >= expectedBytes) {
      return frame.buffer.asUint8List(0, expectedBytes);
    }
    return frame.toUint8List();
  }
  DateTime? _tcpDisconnectedAt;
  DateTime _lastWifiQueryOnDropAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastReverseRebindAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _lastDialErrorLogged = false;
  WebSocket? _apSocket;
  bool _apConnecting = false;
  bool _isDisposed = false;

  /// Normalizes IPv4-mapped IPv6 addresses (e.g. `::ffff:192.168.43.12`) to plain IPv4.
  @visibleForTesting
  static String? normalizeIpAddress(String? raw) {
    if (raw == null) return null;
    var clean = raw.trim();
    if (clean.isEmpty) return null;
    if (clean.toLowerCase().startsWith('::ffff:')) {
      clean = clean.substring(7);
    }
    return clean.isEmpty ? null : clean;
  }

  /// Returns true when a sent TCP frame/keepalive has gone without a 'K' ACK past [timeoutMs].
  @visibleForTesting
  static bool isTcpAckTimedOut({
    required DateTime? awaitingAckSince,
    required DateTime now,
    int timeoutMs = 6500,
  }) {
    if (awaitingAckSince == null) return false;
    return now.difference(awaitingAckSince).inMilliseconds >= timeoutMs;
  }

  /// Hotspot STA shares a single ESP32 radio with BLE and uses Wi-Fi modem sleep, so wait longer
  /// for 'K' ACKs before pushing another large JPEG to prevent OS TCP send-buffer congestion.
  @visibleForTesting
  static int selectTcpInFlightTimeoutMs({required bool hotspotMode}) =>
      hotspotMode ? 2400 : 650;

  @visibleForTesting
  static int selectTcpConnectTimeoutMs({required bool hotspotMode}) =>
      hotspotMode ? 2400 : 1100;

  /// Picks a local IPv4 address likely on the same Hotspot interface as [targetIp]
  /// (exact /24 first, then /16, then named tethering/hotspot interfaces).
  @visibleForTesting
  static InternetAddress? pickMatchingSubnetAddress(
    List<NetworkInterface> interfaces,
    String targetIp,
  ) {
    final normalized = normalizeIpAddress(targetIp);
    if (normalized == null) return null;
    final parts = normalized.split('.');
    if (parts.length != 4) return null;
    final prefix24 = '${parts[0]}.${parts[1]}.${parts[2]}.';
    final prefix16 = '${parts[0]}.${parts[1]}.';

    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        if (addr.type == InternetAddressType.IPv4 && addr.address.startsWith(prefix24)) {
          return addr;
        }
      }
    }
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        if (addr.type == InternetAddressType.IPv4 && addr.address.startsWith(prefix16)) {
          return addr;
        }
      }
    }
    for (final iface in interfaces) {
      final n = iface.name.toLowerCase();
      final looksHotspot = n.contains('ap') ||
          n.contains('swlan') ||
          n.contains('wlan') ||
          n.contains('tether') ||
          n.contains('rndis');
      if (!looksHotspot) continue;
      for (final addr in iface.addresses) {
        if (addr.type == InternetAddressType.IPv4 &&
            !addr.isLoopback &&
            (addr.address.startsWith('10.') || addr.address.startsWith('192.168.'))) {
          return addr;
        }
      }
    }
    return null;
  }

  Future<InternetAddress?> _findHotspotLocalBindAddress(String targetIp) async {
    try {
      final ifaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      return pickMatchingSubnetAddress(ifaces, targetIp);
    } catch (_) {
      return null;
    }
  }

  void _ensureServersListening() {
    if (_isDisposed) return;
    if (_wsServer == null) {
      unawaited(_startWebSocketServer());
    }
    if (_reverseTcpServer == null) {
      unawaited(_startReverseTcpServer());
    }
  }

  Future<void> _rebindReverseTcpServerIfStale() async {
    if (_isDisposed) return;
    final now = DateTime.now();
    if (now.difference(_lastReverseRebindAt).inSeconds < 12) return;
    _lastReverseRebindAt = now;
    final old = _reverseTcpServer;
    _reverseTcpServer = null;
    if (old != null) {
      try {
        await old.close();
      } catch (_) {}
    }
    await _startReverseTcpServer();
  }

  void _startEspApConnector() {
    _apConnectTimer?.cancel();
    _apConnectTimer = Timer.periodic(const Duration(seconds: 2), (_) => _tryConnectEspAp());
    _tryConnectEspAp();
  }

  /// Listen for inbound TCP stream connections from ESP32 in Hotspot STA mode (port 8082).
  Future<void> _startReverseTcpServer() async {
    if (_reverseTcpServer != null || _isDisposed) return;
    try {
      final server = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        espHotspotReverseTcpPort,
        shared: true,
      );
      if (_isDisposed) {
        await server.close();
        return;
      }
      _reverseTcpServer = server;
      debugPrint('[Reverse TCP Server] Listening on 0.0.0.0:$espHotspotReverseTcpPort');
      server.listen(
        (Socket client) {
          if (_isDisposed) {
            client.destroy();
            return;
          }
          // Cancel any competing outbound :8081 dial before attaching the reverse socket
          // so a late-completing outbound SYN doesn't knock this connection off ESP32.
          _apConnectTimeoutTimer?.cancel();
          _apConnectTimeoutTimer = null;
          try {
            _apConnectTask?.cancel();
          } catch (_) {}
          _apConnectTask = null;

          // Firmware only dials :8082 when its own stream client is disconnected,
          // so any lingering socket here is stale and can be replaced cleanly.
          if (_tcpApSocket != null) {
            _closeTcpApSocket(_tcpApSocket!, notifyIfEmpty: false);
          }
          if (_apSocket != null) {
            try {
              _apSocket!.close();
            } catch (_) {}
            _apSocket = null;
          }
          final peerIp = normalizeIpAddress(client.remoteAddress.address) ??
              client.remoteAddress.address;
          _attachTcpBinarySocket(
            client,
            displayIp: peerIp,
            displayPort: espHotspotReverseTcpPort,
            isReverseClient: true,
          );
        },
        onError: (e) {
          debugPrint('[Reverse TCP Server Error] $e');
          if (identical(_reverseTcpServer, server)) {
            _reverseTcpServer = null;
          }
        },
        onDone: () {
          if (identical(_reverseTcpServer, server)) {
            _reverseTcpServer = null;
          }
        },
      );
    } catch (e) {
      debugPrint('[Reverse TCP Server Bind Error] $e');
      _reverseTcpServer = null;
    }
  }

  void _closeTcpApSocket(
    Socket target, {
    bool notifyIfEmpty = true,
    bool scheduleReconnect = false,
    String? reason,
  }) {
    if (!identical(_tcpApSocket, target)) return;
    _apKeepaliveTimer?.cancel();
    _apKeepaliveTimer = null;
    _tcpApSub?.cancel();
    _tcpApSub = null;
    _tcpApSocket = null;
    _activeTcpTargetIp = null;
    _tcpInFlightFrames = 0;
    _awaitingTcpAckSince = null;
    if (scheduleReconnect) {
      _tcpDisconnectedAt ??= DateTime.now();
    }
    if (reason != null && reason.isNotEmpty) {
      bleService.logInfo('Wi-Fi stream đóng ($reason)');
    }
    try {
      target.destroy();
    } catch (_) {}
    if (!_isDisposed && notifyIfEmpty && _wsClients.isEmpty) {
      bleService.setHotspotDisconnected();
    }
    if (!_isDisposed && scheduleReconnect && !_suppressStreamForBleNav) {
      final now = DateTime.now();
      if (bleService.isConnected &&
          now.difference(_lastWifiQueryOnDropAt).inSeconds >= 4) {
        _lastWifiQueryOnDropAt = now;
        unawaited(bleService.requestDeviceConfig());
      }
      _apReconnectTimer?.cancel();
      _apReconnectTimer = Timer(const Duration(milliseconds: 250), () {
        _apReconnectTimer = null;
        if (!_isDisposed && _tcpApSocket == null) {
          unawaited(_tryConnectEspAp());
        }
      });
    }
    if (!_isDisposed) notifyListeners();
  }

  void _attachTcpBinarySocket(
    Socket sock, {
    required String displayIp,
    required int displayPort,
    bool isReverseClient = false,
  }) {
    try {
      sock.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}
    final normalizedDisplay = normalizeIpAddress(displayIp) ?? displayIp;
    if (isReverseClient || normalizedDisplay != espApIp) {
      _lastHotspotPeerIp = normalizedDisplay;
    }
    _tcpApSocket = sock;
    _activeTcpTargetIp = normalizedDisplay;
    _tcpInFlightFrames = 0;
    _lastTcpSendTime = DateTime.now();
    _awaitingTcpAckSince = null;
    _tcpDisconnectedAt = null;
    _lastDialErrorLogged = false;
    _consecutiveWifiErrors = 0;
    bleService.setHotspotConnected(normalizedDisplay, displayPort);
    bleService.logInfo(
      isReverseClient
          ? 'ESP32 đã kết nối Hotspot TCP ($normalizedDisplay:$displayPort)'
          : 'Đã kết nối Wi-Fi TCP tốc độ cao ($normalizedDisplay:$displayPort)',
    );

    unawaited(
      sock.done.then(
        (_) => _closeTcpApSocket(sock, notifyIfEmpty: true, scheduleReconnect: true, reason: 'sock.done'),
        onError: (e) => _closeTcpApSocket(sock, notifyIfEmpty: true, scheduleReconnect: true, reason: 'sock.done err: $e'),
      ),
    );

    _tcpApSub?.cancel();
    _tcpApSub = sock.listen(
      (chunk) {
        final receivedAck = chunk.contains(0x4B);
        _tcpInFlightFrames = computeRemainingTcpInFlight(
          currentInFlight: _tcpInFlightFrames,
          rxChunk: chunk,
        );
        _awaitingTcpAckSince = _tcpInFlightFrames > 0 ? DateTime.now() : null;
        if (receivedAck && !_isDisposed && _isStreaming && !_isCapturing) {
          scheduleMicrotask(_renderAndStreamHeadlessFrame);
        }
      },
      onDone: () => _closeTcpApSocket(sock, notifyIfEmpty: true, scheduleReconnect: true, reason: 'peer closed (EOF)'),
      onError: (e) => _closeTcpApSocket(sock, notifyIfEmpty: true, scheduleReconnect: true, reason: 'rx err: $e'),
      cancelOnError: true,
    );

    _apKeepaliveTimer?.cancel();
    _apKeepaliveTimer = Timer.periodic(const Duration(milliseconds: 2500), (_) {
      final s = _tcpApSocket;
      if (s == null || !identical(s, sock)) return;
      final now = DateTime.now();
      if (isTcpAckTimedOut(awaitingAckSince: _awaitingTcpAckSince, now: now, timeoutMs: 6500)) {
        bleService.logInfo('Wi-Fi stream mất phản hồi -> tự kết nối lại...');
        _closeTcpApSocket(s, notifyIfEmpty: true, scheduleReconnect: true, reason: 'ACK timeout 6.5s');
        return;
      }
      if (now.difference(_lastTcpSendTime).inMilliseconds >= 2000) {
        try {
          _awaitingTcpAckSince ??= now;
          s.add(const [0xAA, 0xDD]);
          _lastTcpSendTime = now;
        } catch (e) {
          _closeTcpApSocket(s, notifyIfEmpty: true, scheduleReconnect: true, reason: 'keepalive tx err: $e');
        }
      }
    });

    if (_latestJpegBytes != null) {
      _sendPacketOverTcpAp(sock, _latestJpegBytes!);
    }
    notifyListeners();
  }

  Future<Socket> _dialTcpWithTimeout(
    String host,
    int port, {
    required int timeoutMs,
    InternetAddress? sourceAddress,
  }) async {
    final task = await Socket.startConnect(
      host,
      port,
      sourceAddress: sourceAddress,
    );
    if (_isDisposed || _tcpApSocket != null) {
      unawaited(task.socket.then((s) => s.destroy(), onError: (_) {}));
      task.cancel();
      throw const SocketException('Aborted before connect completed');
    }
    _apConnectTask = task;
    _apConnectTimeoutTimer?.cancel();
    _apConnectTimeoutTimer = Timer(Duration(milliseconds: timeoutMs), () {
      try {
        task.cancel();
      } catch (_) {}
    });
    return task.socket;
  }

  bool get _isHotspotTransportActive =>
      bleService.hotspotModeEnabled ||
      bleService.espStaConnectedToHotspot ||
      (_lastHotspotPeerIp != null && _lastHotspotPeerIp != espApIp);

  Future<void> _tryConnectEspAp() async {
    _ensureServersListening();
    if (_isDisposed || _tcpApSocket != null || _apSocket != null || _apConnecting) return;

    final bool useHotspot = _isHotspotTransportActive;
    final String? targetIp =
        normalizeIpAddress(bleService.espStaIp) ?? (useHotspot ? _lastHotspotPeerIp : espApIp);

    // If disconnected in Hotspot mode for several seconds, proactively refresh :8082 listener
    // and break any confirmed ESP32 half-open zombie socket (where ESP32 still reports tcp=1).
    final disconnectedAt = _tcpDisconnectedAt;
    if (useHotspot && disconnectedAt != null) {
      final elapsedDropSec = DateTime.now().difference(disconnectedAt).inSeconds;
      if (elapsedDropSec >= 5) {
        unawaited(_rebindReverseTcpServerIfStale());
      }
      if (elapsedDropSec >= 6 &&
          bleService.isConnected &&
          bleService.hotspotSsid.isNotEmpty &&
          (bleService.espReportedTcpConnected == true || elapsedDropSec >= 10)) {
        unawaited(bleService.recoverHotspotWifiLink());
      }
    }

    if (targetIp == null || targetIp.isEmpty) return;

    _apConnecting = true;
    final connectTimeoutMs = selectTcpConnectTimeoutMs(hotspotMode: useHotspot);
    try {
      Socket? rawSock;
      if (Platform.isAndroid && useHotspot) {
        // In Hotspot mode (10.x / 192.168.x), bind the Hotspot local interface IP first so we
        // don't waste 2.4s hanging on 4G cellular routing, then fall back to default route.
        final localBindIp = await _findHotspotLocalBindAddress(targetIp);
        if (localBindIp != null && !_isDisposed && _tcpApSocket == null) {
          try {
            rawSock = await _dialTcpWithTimeout(
              targetIp,
              espApTcpPort,
              timeoutMs: 1600,
              sourceAddress: localBindIp,
            );
          } catch (_) {
            _apConnectTimeoutTimer?.cancel();
            _apConnectTimeoutTimer = null;
            _apConnectTask = null;
          }
        }
        if (rawSock == null && !_isDisposed && _tcpApSocket == null) {
          rawSock = await _dialTcpWithTimeout(
            targetIp,
            espApTcpPort,
            timeoutMs: 1600,
          );
        }
      } else {
        try {
          rawSock = await _dialTcpWithTimeout(
            targetIp,
            espApTcpPort,
            timeoutMs: connectTimeoutMs,
          );
        } on SocketException {
          _apConnectTimeoutTimer?.cancel();
          _apConnectTimeoutTimer = null;
          _apConnectTask = null;
          if (!Platform.isAndroid || useHotspot || _isDisposed || _tcpApSocket != null) rethrow;
          // On Android 10+, when 4G/5G Mobile Data stays active alongside no-internet ESP32 SoftAP,
          // connect via native Wi-Fi Network.socketFactory loopback relay so 4G tiles still work too.
          final relayPort = await _locationChannel.invokeMethod<int>('openWifiApTcpRelay', {
            'host': espApIp,
            'port': espApTcpPort,
          });
          if (relayPort == null || relayPort <= 0 || _isDisposed || _tcpApSocket != null) {
            rethrow;
          }
          rawSock = await Socket.connect(
            InternetAddress.loopbackIPv4,
            relayPort,
            timeout: Duration(milliseconds: connectTimeoutMs),
          );
        }
      }
      _apConnectTimeoutTimer?.cancel();
      _apConnectTimeoutTimer = null;
      _apConnectTask = null;
      final sock = rawSock;
      if (sock == null || _isDisposed || _tcpApSocket != null) {
        sock?.destroy();
        return;
      }
      _attachTcpBinarySocket(sock, displayIp: targetIp, displayPort: espApTcpPort);
    } on SocketException catch (e) {
      if (useHotspot && !_lastDialErrorLogged) {
        _lastDialErrorLogged = true;
        bleService.logInfo('Thử nối Hotspot TCP $targetIp:8081 thất bại ($e), chờ ESP32 nối :8082...');
      }
      if (_tcpApSocket == null && !_isDisposed) {
        final wsUrl = 'ws://$targetIp:8080';
        try {
          final ws = await WebSocket.connect(wsUrl).timeout(const Duration(milliseconds: 1400));
          if (_isDisposed || _tcpApSocket != null) {
            unawaited(ws.close());
            return;
          }
          _apSocket = ws;
          _registerWsClient(ws, remoteIp: targetIp);
          bleService.logInfo('Đã kết nối Wi-Fi WS dự phòng ($wsUrl)');
        } catch (_) {}
      }
    } catch (_) {
      // Chưa kết nối được Wi-Fi ESP32 -> thử lại mỗi 2s
    } finally {
      _apConnectTimeoutTimer?.cancel();
      _apConnectTimeoutTimer = null;
      _apConnectTask = null;
      _apConnecting = false;
    }
  }

  /// Register a WebSocket peer (either iPhone-hosted server client or ESP32 connection)
  void _registerWsClient(WebSocket socket, {String? remoteIp}) {
    _wsClients.add(socket);
    _wsReadyForNextFrame = true;
    final ip = (remoteIp != null && remoteIp.isNotEmpty)
        ? remoteIp
        : (identical(socket, _apSocket)
            ? (_lastKnownStaIp?.isNotEmpty == true ? _lastKnownStaIp! : espApIp)
            : (bleService.espStaIp?.isNotEmpty == true
                ? bleService.espStaIp!
                : (bleService.wifiGatewayIp?.isNotEmpty == true
                    ? bleService.wifiGatewayIp!
                    : '172.20.10.1')));
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
          if (!_isDisposed && _isStreaming && !_isCapturing) {
            scheduleMicrotask(_renderAndStreamHeadlessFrame);
          }
        }
      },
      onDone: onGone,
      onError: (_) => onGone(),
    );
  }

  void updateReferences(BleService newBle, NavigationManager newNav) {
    if (!identical(bleService, newBle)) {
      bleService.removeListener(_handleBleConnectionChange);
      bleService = newBle;
      _lastBleConnected = bleService.isConnected;
      _lastHotspotMode = bleService.hotspotModeEnabled;
      _lastKnownStaIp = bleService.espStaIp;
      bleService.addListener(_handleBleConnectionChange);
    }
    navManager = newNav;
  }

  static const _locationChannel = MethodChannel('com.ysiduc.esp32_nav/location');

  void _enableBackgroundKeepAlive() {
    if (Platform.isIOS || Platform.isAndroid) {
      try {
        _locationChannel.invokeMethod('startBackgroundNavigation', {'source': 'stream'});
      } catch (_) {}
    }
  }

  void _disableBackgroundKeepAlive() {
    if ((Platform.isIOS || Platform.isAndroid) &&
        !(navManager?.isAnyNavActive ?? false) &&
        !(navManager?.isExternalBleNavMode ?? false) &&
        !_suppressStreamForBleNav) {
      try {
        _locationChannel.invokeMethod('stopBackgroundNavigation', {'source': 'stream'});
      } catch (_) {}
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _isForeground = true;
      _ensureServersListening();
      _tryConnectEspAp();
      if (_isStreaming && !_suppressStreamForBleNav) {
        _startTimer();
      }
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _isForeground = false;
      // When app is in background or screen is locked:
      // Keep streaming continuously without dropping (unless BLE-only nav mode is active)
      if (_isStreaming && !_suppressStreamForBleNav) {
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
    _suppressStreamForBleNav = false;
    WidgetsBinding.instance.removeObserver(this);
    bleService.removeListener(_handleBleConnectionChange);
    stopStreaming();
    _persistentWifiSocket?.destroy();
    _persistentWifiSocket = null;
    for (final ws in _wsClients) {
      try {
        ws.close();
      } catch (_) {}
    }
    _wsClients.clear();
    _isDisposed = true;
    _apConnectTimer?.cancel();
    _apReconnectTimer?.cancel();
    _apReconnectTimer = null;
    _apConnectTimeoutTimer?.cancel();
    _apConnectTimeoutTimer = null;
    try {
      _apConnectTask?.cancel();
    } catch (_) {}
    _apConnectTask = null;
    _apKeepaliveTimer?.cancel();
    _tcpApSub?.cancel();
    _tcpApSocket?.destroy();
    _tcpApSocket = null;
    _apSocket = null;
    _wsServer?.close(force: true);
    _wsServer = null;
    _reverseTcpServer?.close();
    _reverseTcpServer = null;
    _pauseTimer?.cancel();
    _tileCache.forEach((_, img) => img.dispose());
    _tileCache.clear();
    _cpuTileCache.clear();
    _cpuTileRgba32.clear();
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

  /// Toggles BLE-only navigation mode (stops Wi-Fi map streaming while external Google Maps BLE relay runs without stream).
  void setBleOnlyNavMode(bool enabled) {
    if (enabled == _suppressStreamForBleNav) return;
    if (enabled) {
      _resumeStreamAfterBleNav = _isStreaming || _resumeStreamAfterBleNav;
      _suppressStreamForBleNav = true;
      stopStreaming();
      _enableBackgroundKeepAlive();
    } else {
      _suppressStreamForBleNav = false;
      if (_resumeStreamAfterBleNav &&
          (_isForeground || (navManager?.isAnyNavActive ?? false) || (navManager?.isExternalBleNavMode ?? false))) {
        _resumeStreamAfterBleNav = false;
        startStreaming();
      } else {
        _resumeStreamAfterBleNav = false;
        _disableBackgroundKeepAlive();
      }
    }
    notifyListeners();
  }

  /// Ensures 20-30 FPS foreground / 10 FPS background map streaming stays active
  /// when external guidance (e.g. Google Maps) streams Man 3 over Wi-Fi.
  void ensureExternalNavStreamingActive() {
    if (_suppressStreamForBleNav) return;
    if (!_isStreaming) {
      startStreaming();
      return;
    }
    _enableBackgroundKeepAlive();
    if (_streamTimer == null || !(_streamTimer!.isActive)) {
      _startTimer();
    }
    scheduleMicrotask(_renderAndStreamHeadlessFrame);
  }

  /// Start High-Speed Headless 20-30 FPS JPEG Streaming
  void startStreaming({GlobalKey? boundaryKey}) {
    if (_suppressStreamForBleNav) {
      _resumeStreamAfterBleNav = true;
      stopStreaming();
      return;
    }
    stopStreaming();
    _isStreaming = true;
    _frameCount = 0;
    _framesInCurrentSec = 0;
    _actualFps = _targetFps.toDouble();
    _lastFpsUpdate = DateTime.now();

    _enableBackgroundKeepAlive();
    if (_isForeground ||
        bleService.isConnected ||
        bleService.isWifiConnected ||
        _wsClients.isNotEmpty ||
        (navManager?.isAnyNavActive ?? false) ||
        (navManager?.isExternalBleNavMode ?? false)) {
      _startTimer();
    }

    notifyListeners();
  }

  void _startTimer() {
    _streamTimer?.cancel();
    // In foreground: full 25-30 FPS. In background during Google Maps / active nav or live TCP: smooth 20-25 FPS.
    final bool activeBgNav =
        (navManager?.isAnyNavActive ?? false) || (navManager?.isExternalBleNavMode ?? false);
    final effectiveFps = _isForeground
        ? _targetFps
        : (activeBgNav ? 25 : (_tcpApSocket != null ? 20 : 12));
    final intervalMs = (1000 / effectiveFps).round();
    _streamTimer = Timer.periodic(Duration(milliseconds: intervalMs), (_) {
      _renderAndStreamHeadlessFrame();
    });
  }

  /// Max JPEG payload bytes allowed for active transport
  int get _maxJpegFrameBytes {
    // ESP32 framePool supports up to 32,768 bytes per frame; allow crisp JPEGs without 0.40 crush.
    if (_tcpApSocket != null) return 26500;
    if (_wsClients.isEmpty) return 26500;
    return 22500;
  }

  @visibleForTesting
  int get debugMaxJpegFrameBytes => _maxJpegFrameBytes;

  @visibleForTesting
  bool get debugIsNavFrameMode => navManager?.isAnyNavActive ?? false;

  @visibleForTesting
  int get debugTargetRenderWidth => debugIsNavFrameMode ? 320 : 144;

  @visibleForTesting
  int get debugTargetRenderHeight => debugIsNavFrameMode ? 216 : 224;

  @visibleForTesting
  List<LatLng> get debugEffectiveRoutePoints =>
      _resolveMapRoutePoints(navManager?.activeRoute);

  @visibleForTesting
  Map<String, dynamic> get debugCurrentNavHudSnapshot => _buildNavHudPayload(
        vx: 226.0,
        vy: 160.0,
        isDark: _streamMapStyle.contains('dark'),
      );

  @visibleForTesting
  ({double headingDeg, List<LatLng> pts, LatLng userPos, bool matchedRoad})
      debugResolveExternalGuidedPose({
    required LatLng userPos,
    required int displayZoom,
    required double rawHeadingDeg,
    Iterable<OsmVectorTile>? tilesOverride,
  }) =>
          _resolveExternalGuidedPose(
            userPos: userPos,
            displayZoom: displayZoom,
            rawHeadingDeg: rawHeadingDeg,
            activeRoute: navManager?.activeRoute ?? navManager?.previewRoute,
            tilesOverride: tilesOverride,
          );

  /// Stabilizes external camera heading & snaps Google Maps guide geometry onto loaded OSM roads.
  ({double headingDeg, List<LatLng> pts, LatLng userPos, bool matchedRoad})
      _resolveExternalGuidedPose({
    required LatLng userPos,
    required int displayZoom,
    required double rawHeadingDeg,
    required dynamic activeRoute,
    Iterable<OsmVectorTile>? tilesOverride,
  }) {
    final nm = navManager;
    if (nm != null && nm.isNavigating) {
      _smoothedRenderHeading = rawHeadingDeg;
      return (
        headingDeg: rawHeadingDeg,
        pts: _resolveMapRoutePoints(activeRoute),
        userPos: userPos,
        matchedRoad: false,
      );
    }

    final tiles = tilesOverride ??
        _collectVisibleOsmTiles(userPos, radius: displayZoom <= 14 ? 2 : 1);
    final bool hasGpsLock = nm?.hasHeadingLock ?? false;
    final bool isExtNav = nm?.isExternalNavTelemetryActive ?? false;

    final match = OsmRoadGuideMatcher.matchAndTrace(
      tiles: tiles,
      userPos: userPos,
      displayZoom: displayZoom,
      rawHeadingDeg: rawHeadingDeg,
      hasHeadingLock: hasGpsLock,
      turnCode: isExtNav ? (nm?.effectiveTurnCode ?? 0) : 0,
      distanceToTurnMeters:
          isExtNav ? (nm?.effectiveDistanceToNextManeuver ?? 0.0) : 0.0,
      currentStreetName: nm?.currentStreetName ?? '',
      nextStreetName: isExtNav ? (nm?.effectiveNextStreetName ?? '') : '',
    );

    // Follow genuine movement bearing faithfully; only snap onto OSM street axis
    // when stationary before first motion lock (or trivial <14 deg straight-lane align).
    double targetHdg = rawHeadingDeg;
    if (!hasGpsLock && match.matchedRoad && match.snappedHeadingDeg != null) {
      targetHdg = match.snappedHeadingDeg!;
    } else if (hasGpsLock &&
        match.matchedRoad &&
        match.snappedHeadingDeg != null &&
        OsmRoadGuideMatcher.absAngleDiffDeg(match.snappedHeadingDeg!, rawHeadingDeg) <= 14.0) {
      targetHdg = OsmRoadGuideMatcher.lerpAngleDeg(
        rawHeadingDeg,
        match.snappedHeadingDeg!,
        0.35,
        maxStepDeg: 180.0,
      );
    }

    double stabilizedHdg;
    final prev = _smoothedRenderHeading;
    if (prev == null) {
      stabilizedHdg = targetHdg;
    } else {
      final double speedKmh = nm?.currentSpeedKmh ?? 0.0;
      final double diff = OsmRoadGuideMatcher.absAngleDiffDeg(prev, targetHdg);
      if (speedKmh < 4.5 && diff < 2.5) {
        stabilizedHdg = prev;
      } else {
        stabilizedHdg = OsmRoadGuideMatcher.lerpAngleDeg(
          prev,
          targetHdg,
          0.45,
          maxStepDeg: 24.0,
        );
      }
    }
    _smoothedRenderHeading = stabilizedHdg;

    final LatLng effectivePos =
        (!hasGpsLock && match.matchedRoad && match.snappedLocation != null)
            ? match.snappedLocation!
            : userPos;

    final List<LatLng> pts =
        isExtNav ? const <LatLng>[] : _resolveMapRoutePoints(activeRoute);

    return (
      headingDeg: stabilizedHdg,
      pts: pts,
      userPos: effectivePos,
      matchedRoad: match.matchedRoad,
    );
  }

  List<LatLng> _resolveMapRoutePoints(dynamic activeRoute) {
    final eff = navManager?.effectiveRoutePolylinePoints;
    if (eff != null && eff.length >= 2) return eff;
    final route = activeRoute ?? navManager?.previewRoute;
    if (route != null && route.polylinePoints is List<LatLng>) {
      return route.polylinePoints as List<LatLng>;
    }
    return const <LatLng>[];
  }

  Map<String, dynamic> _buildNavHudPayload({
    required double vx,
    required double vy,
    required bool isDark,
    double? distOverride,
  }) {
    final double speedKmh = navManager?.currentSpeedKmh ?? 0.0;
    final double distToTurn = distOverride ?? (navManager?.effectiveDistanceToNextManeuver ?? 200.0);
    final double totalDistM = navManager?.effectiveRemainingTotalDistance ?? 0.0;
    final int etaMin = (navManager?.effectiveRemainingEtaMinutes ?? 1).clamp(1, 999);
    final String curRoad = navManager?.currentStreetName ?? 'Đường hiện tại';
    final int turnCode = navManager?.effectiveTurnCode ?? 0;
    final String nextStreetRaw = navManager?.effectiveNextStreetName ?? curRoad;
    final String nextStreet = nextStreetRaw.trim().isNotEmpty ? nextStreetRaw.trim() : 'Đi thẳng';

    final String distStr = distToTurn >= 1000
        ? '${(distToTurn / 1000.0).toStringAsFixed(1)} km'
        : '${distToTurn.round()} m';
    final String etaText = etaMin >= 60
        ? '${etaMin ~/ 60} giờ ${etaMin % 60} phút'
        : '$etaMin phút';
    final arrTime = DateTime.now().add(Duration(minutes: etaMin));
    final String arrStr = (navManager?.effectiveArrivalTime?.isNotEmpty ?? false)
        ? navManager!.effectiveArrivalTime!
        : '${arrTime.hour.toString().padLeft(2, '0')}:${arrTime.minute.toString().padLeft(2, '0')}';
    final String totDistStr = totalDistM >= 10000
        ? '${(totalDistM / 1000.0).round()} km'
        : (totalDistM >= 1000
            ? '${(totalDistM / 1000.0).toStringAsFixed(1)} km'
            : '${totalDistM.round()} m');

    return <String, dynamic>{
      'vx': vx,
      'vy': vy,
      'curRoad': curRoad,
      'nextStreet': nextStreet,
      'distStr': distStr,
      'turnCode': turnCode,
      'speedStr': '${speedKmh.round()}',
      'etaText': etaText,
      'arrStr': arrStr,
      'totDistStr': totDistStr,
      'subText': '$arrStr • $totDistStr',
      'isDark': isDark,
    };
  }

  @visibleForTesting
  Future<Uint8List?> debugCompressRgbaToJpeg(
    Uint8List rawBytes,
    int w,
    int h, {
    int quality = 86,
  }) =>
      _compressRgbaToJpeg(rawBytes, w, h, quality: quality);

  /// Hardware-accelerated RGBA-to-JPEG encoding on iOS & Android (with pure-Dart fallback)
  Future<Uint8List?> _compressRgbaToJpeg(
    Uint8List rawBytes,
    int w,
    int h, {
    int quality = 86,
    Map<String, dynamic>? hud,
    List<Map<String, dynamic>>? roadLabels,
    bool isDark = false,
  }) async {
    final maxBytes = _maxJpegFrameBytes;
    if (Platform.isIOS || Platform.isAndroid) {
      try {
        final args = <String, dynamic>{
          'rgba': rawBytes,
          'width': w,
          'height': h,
          'quality': quality / 100.0,
          'isDark': isDark,
          if (hud != null) 'hud': hud,
          if (roadLabels != null && roadLabels.isNotEmpty) 'roadLabels': roadLabels,
        };
        var res = await _locationChannel.invokeMethod<Uint8List>('compressRgbaToJpeg', args);
        if (res != null && res.length > maxBytes) {
          for (final fallbackQ in const [0.78, 0.70, 0.62]) {
            if ((quality / 100.0) <= fallbackQ) continue;
            args['quality'] = fallbackQ;
            res = await _locationChannel.invokeMethod<Uint8List>('compressRgbaToJpeg', args);
            if (res == null || res.length <= maxBytes) break;
          }
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
    if (jpg.length > maxBytes) {
      for (final fallbackQ in const [78, 70, 62]) {
        if (quality <= fallbackQ) continue;
        jpg = Uint8List.fromList(img.encodeJpg(imgImage, quality: fallbackQ));
        if (jpg.length <= maxBytes) break;
      }
    }
    return jpg;
  }

  /// Render 144x224 (Standby) or 320x216 (Active Navigation) Real Street Map & Stream with Zero-Lag Flow Control
  Future<void> _renderAndStreamHeadlessFrame() async {
    if (!_isStreaming || _isCapturing || _isSendingWifi) return;

    if (!bleService.isConnected &&
        !bleService.isWifiConnected &&
        _tcpApSocket == null &&
        _wsClients.isEmpty &&
        !_isForeground) {
      return;
    }

    // Bounded 2-frame pipelined flow control: overlaps phone encode/TX with ESP32 SPI draw
    // so Wi-Fi never stalls between RTT/modem-sleep windows while keeping queue depth <= 1 frame.
    final staleAckTimeoutMs = selectTcpInFlightTimeoutMs(
      hotspotMode: _isHotspotTransportActive,
    );
    if (bleService.isConnected &&
        _tcpApSocket != null &&
        !canSendNextTcpFrame(
          inFlight: _tcpInFlightFrames,
          elapsedSinceLastSendMs: DateTime.now().difference(_lastTcpSendTime).inMilliseconds,
          staleAckTimeoutMs: staleAckTimeoutMs,
        )) {
      return;
    }
    if (bleService.isConnected &&
        _tcpApSocket == null &&
        _wsClients.isNotEmpty &&
        !_wsReadyForNextFrame &&
        DateTime.now().difference(_lastWsSendTime).inMilliseconds < 650) {
      return;
    }
    _isCapturing = true;

    try {
      final bool isNav = navManager?.isAnyNavActive ?? false;
      final int w = isNav ? 320 : 144;
      final int h = isNav ? 216 : 224;

      final userPos = navManager?.currentLocation ?? const LatLng(20.9832, 105.8425);
      final double heading = navManager?.effectiveHeading ?? navManager?.currentHeading ?? 0.0;
      final activeRoute = navManager?.activeRoute;
      final distToTurn = navManager?.effectiveDistanceToNextManeuver ?? 208.0;
      final speedKmh = navManager?.currentSpeedKmh ?? 0.0;

      // Pre-fetch surrounding tiles asynchronously at chosen minimap zoom
      _prefetchSurroundingTiles(userPos, _minimapZoom);

      Uint8List? jpegBytes;

      if (_isForeground && !isNav && !_isOsm3dStyle) {
        // 1. In foreground (raster modes): High-Speed Flutter Canvas rendering
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
            jpegBytes = await _compressRgbaToJpeg(rawBytes, w, h, quality: isNav ? 72 : 74);
          }
        } catch (_) {}
      }

      // 2. OSM 3D Vector Block Renderer (both foreground & background) or CPU background raster/HUD renderer
      jpegBytes ??= isNav ? await _renderCpuNavigationFrame(w, h) : await _renderCpuMapFrame(w, h);


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

      // 3. Transmit over Wi-Fi ONLY while BLE is actively connected (keeps Màn 1 undisturbed when disconnected)
      if (bleService.isConnected) {
        _dispatchTransmission(jpegBytes);
      }
    } catch (_) {
    } finally {
      _isCapturing = false;
    }
  }

  Osm3dCamera _buildOsm3dCamera({
    required int width,
    required int height,
    required double anchorX,
    required double anchorY,
    required double headingDeg,
  }) =>
      Osm3dCamera(
        width: width.toDouble(),
        height: height.toDouble(),
        anchorX: anchorX,
        anchorY: anchorY,
        headingDeg: headingDeg,
        perspective3d: true,
        tiltDeg: 31.0,
        focal: 420.0,
      );

  static List<Map<String, dynamic>> _serializeRoadLabels(
    List<OsmScreenRoadLabel> labels,
  ) =>
      labels
          .map(
            (l) => <String, dynamic>{
              'text': l.text,
              'sx': l.sx,
              'sy': l.sy,
              'angleDeg': l.angleDeg,
              'tier': l.tier,
            },
          )
          .toList(growable: false);

  List<OsmVectorTile> _collectVisibleOsmTiles(LatLng pos, {int radius = 1}) {
    const double n15 = 32768.0; // 2^15
    final double latRad = pos.latitude * (math.pi / 180.0);
    final int cx15 = ((pos.longitude + 180.0) / 360.0 * n15).floor();
    final int cy15 = ((1.0 - (math.log(math.tan(latRad) + 1.0 / math.cos(latRad)) / math.pi)) / 2.0 * n15).floor();
    final seen = <String>{};
    final out = <OsmVectorTile>[];
    for (int dx = -radius; dx <= radius; dx++) {
      for (int dy = -radius; dy <= radius; dy++) {
        final int tx = cx15 + dx;
        final int ty = cy15 + dy;
        final k15 = '15/$tx/$ty';
        final t15 = _osmTileCache[k15];
        if (t15 != null) {
          if (seen.add(k15)) out.add(t15);
          if (t15.buildings.length < 80 && _osmSuppBuildingCache.isNotEmpty) {
            for (int sx = 0; sx < 4; sx++) {
              for (int sy = 0; sy < 4; sy++) {
                final k17 = '17/${(tx << 2) + sx}/${(ty << 2) + sy}';
                final supp = _osmSuppBuildingCache[k17];
                if (supp != null && supp.buildings.isNotEmpty && seen.add(k17)) {
                  out.add(supp);
                }
              }
            }
          }
          continue;
        }
        final k14 = '14/${tx >> 1}/${ty >> 1}';
        final t14 = _osmTileCache[k14];
        if (t14 != null && seen.add(k14)) {
          out.add(t14);
        }
      }
    }
    return out;
  }

  void _drawProjectedRouteOnFrame({
    required img.Image frame,
    required int w,
    required int h,
    required LatLng userPos,
    required double worldX,
    required double worldY,
    required double n,
    required double anchorX,
    required double anchorY,
    required double pitchY,
    required double cosT,
    required double sinT,
    required List<LatLng> pts,
    required bool isDark,
    Osm3dCamera? camera,
  }) {
    if (pts.length < 2) return;
    final casingColor = isDark
        ? img.ColorRgba8(0, 66, 138, 255)
        : img.ColorRgba8(8, 66, 168, 255);
    final coreColor = isDark
        ? img.ColorRgba8(48, 136, 255, 255)
        : img.ColorRgba8(15, 98, 254, 255);
    final chevronColor = img.ColorRgba8(255, 255, 255, 240);

    const double geoMarginDeg = 0.06;
    final double minGeoLat = userPos.latitude - geoMarginDeg;
    final double maxGeoLat = userPos.latitude + geoMarginDeg;
    final double minGeoLng = userPos.longitude - geoMarginDeg;
    final double maxGeoLng = userPos.longitude + geoMarginDeg;

    final visibleSegs = <({int x1, int y1, int x2, int y2, double scale})>[];
    double? cachedRx;
    double? cachedRy;
    int cachedIdx = -1;

    (double, double) toCameraLocal(int index, LatLng pt) {
      if (cachedIdx == index && cachedRx != null && cachedRy != null) {
        return (cachedRx!, cachedRy!);
      }
      final double ptLatRad = pt.latitude * (math.pi / 180.0);
      final double ptWorldX = (pt.longitude + 180.0) / 360.0 * n * 256.0;
      final double ptWorldY =
          (1.0 - (math.log(math.tan(ptLatRad) + 1.0 / math.cos(ptLatRad)) / math.pi)) /
              2.0 *
              n *
              256.0;
      final double wx = ptWorldX - worldX;
      final double wy = ptWorldY - worldY;
      final double rx = camera != null ? camera.worldToRight(wx, wy) : (wx * cosT + wy * sinT);
      final double ry = camera != null ? camera.worldToBack(wx, wy) : (-wx * sinT + wy * cosT);
      cachedIdx = index;
      cachedRx = rx;
      cachedRy = ry;
      return (rx, ry);
    }

    final double clipMinX = -24.0;
    final double clipMaxX = w + 24.0;
    final double clipMinY = -24.0;
    final double clipMaxY = h + 24.0;

    void pushClippedSegment(double x1, double y1, double x2, double y2, double scale) {
      final double dx = x2 - x1;
      final double dy = y2 - y1;
      double t0 = 0.0;
      double t1 = 1.0;
      bool visible = true;
      for (int edge = 0; edge < 4; edge++) {
        final double p = edge == 0 ? -dx : (edge == 1 ? dx : (edge == 2 ? -dy : dy));
        final double q = edge == 0
            ? (x1 - clipMinX)
            : (edge == 1 ? (clipMaxX - x1) : (edge == 2 ? (y1 - clipMinY) : (clipMaxY - y1)));
        if (p.abs() < 1e-9) {
          if (q < 0) {
            visible = false;
            break;
          }
        } else {
          final double r = q / p;
          if (p < 0) {
            if (r > t1) {
              visible = false;
              break;
            }
            if (r > t0) t0 = r;
          } else {
            if (r < t0) {
              visible = false;
              break;
            }
            if (r < t1) t1 = r;
          }
        }
      }
      if (!visible) return;
      final cx1 = (x1 + t0 * dx).round();
      final cy1 = (y1 + t0 * dy).round();
      final cx2 = (x1 + t1 * dx).round();
      final cy2 = (y1 + t1 * dy).round();
      if (cx1 == cx2 && cy1 == cy2 && visibleSegs.isNotEmpty) return;
      visibleSegs.add((x1: cx1, y1: cy1, x2: cx2, y2: cy2, scale: scale));
    }

    for (int i = 0; i < pts.length - 1; i++) {
      final a = pts[i];
      final b = pts[i + 1];
      if ((a.latitude < minGeoLat && b.latitude < minGeoLat) ||
          (a.latitude > maxGeoLat && b.latitude > maxGeoLat) ||
          (a.longitude < minGeoLng && b.longitude < minGeoLng) ||
          (a.longitude > maxGeoLng && b.longitude > maxGeoLng)) {
        continue;
      }

      var (rx1, ry1) = toCameraLocal(i, a);
      var (rx2, ry2) = toCameraLocal(i + 1, b);

      if (camera != null && camera.perspective3d) {
        double cz1 = camera.camZAt(ry1);
        double cz2 = camera.camZAt(ry2);
        if (cz1 < camera.nearCamZ && cz2 < camera.nearCamZ) continue;
        if (cz1 < camera.nearCamZ) {
          final double t = (camera.nearCamZ - cz1) / (cz2 - cz1);
          rx1 = rx1 + t * (rx2 - rx1);
          ry1 = ry1 + t * (ry2 - ry1);
          cz1 = camera.nearCamZ;
        }
        if (cz2 < camera.nearCamZ) {
          final double t = (camera.nearCamZ - cz2) / (cz1 - cz2);
          rx2 = rx2 + t * (rx1 - rx2);
          ry2 = ry2 + t * (ry1 - ry2);
          cz2 = camera.nearCamZ;
        }
        final int parts = (cz1 - cz2).abs() > 38.0
            ? ((cz1 - cz2).abs() / 38.0).ceil().clamp(2, 6)
            : 1;
        for (int k = 0; k < parts; k++) {
          final double t0 = k / parts;
          final double t1 = (k + 1) / parts;
          final p0 = camera.projectLocal(rx1 + t0 * (rx2 - rx1), ry1 + t0 * (ry2 - ry1));
          final p1 = camera.projectLocal(rx1 + t1 * (rx2 - rx1), ry1 + t1 * (ry2 - ry1));
          pushClippedSegment(p0.sx, p0.sy, p1.sx, p1.sy, (p0.scale + p1.scale) * 0.5);
        }
      } else {
        pushClippedSegment(
          anchorX + rx1,
          anchorY + ry1 * pitchY,
          anchorX + rx2,
          anchorY + ry2 * pitchY,
          1.0,
        );
      }
    }

    for (int i = 0; i < visibleSegs.length; i++) {
      final seg = visibleSegs[i];
      final int caseW = (9.5 * seg.scale).round().clamp(5, 13);
      final int capR = math.max(2, caseW ~/ 2);
      img.drawLine(frame, x1: seg.x1, y1: seg.y1, x2: seg.x2, y2: seg.y2, color: casingColor, thickness: caseW);
      if (i == 0) img.fillCircle(frame, x: seg.x1, y: seg.y1, radius: capR, color: casingColor);
      img.fillCircle(frame, x: seg.x2, y: seg.y2, radius: capR, color: casingColor);
    }
    for (int i = 0; i < visibleSegs.length; i++) {
      final seg = visibleSegs[i];
      final int coreW = (5.5 * seg.scale).round().clamp(3, 8);
      final int capR = math.max(1, coreW ~/ 2);
      img.drawLine(frame, x1: seg.x1, y1: seg.y1, x2: seg.x2, y2: seg.y2, color: coreColor, thickness: coreW);
      if (i == 0) img.fillCircle(frame, x: seg.x1, y: seg.y1, radius: capR, color: coreColor);
      img.fillCircle(frame, x: seg.x2, y: seg.y2, radius: capR, color: coreColor);
    }

    // Directional white chevrons (>) along route matching Google Maps 3D navigation
    double accumPx = 0.0;
    double nextMarkPx = 28.0;
    const double chevronSpacingPx = 44.0;
    for (final seg in visibleSegs) {
      final double dx = (seg.x2 - seg.x1).toDouble();
      final double dy = (seg.y2 - seg.y1).toDouble();
      final double segLen = math.sqrt(dx * dx + dy * dy);
      if (segLen < 1.5) continue;
      final double tx = dx / segLen;
      final double ty = dy / segLen;
      final double nx = -ty;
      final double ny = tx;
      while (accumPx + segLen >= nextMarkPx) {
        final double t = (nextMarkPx - accumPx) / segLen;
        final double px = seg.x1 + dx * t;
        final double py = seg.y1 + dy * t;
        final double arm = (2.8 * seg.scale).clamp(1.6, 3.8);
        if ((px - anchorX).abs() >= 15.0 || (py - anchorY).abs() >= 15.0) {
          final int tipX = (px + tx * arm).round();
          final int tipY = (py + ty * arm).round();
          final int lX = (px - tx * arm * 0.8 + nx * arm * 0.95).round();
          final int lY = (py - ty * arm * 0.8 + ny * arm * 0.95).round();
          final int rX = (px - tx * arm * 0.8 - nx * arm * 0.95).round();
          final int rY = (py - ty * arm * 0.8 - ny * arm * 0.95).round();
          final int thick = seg.scale >= 0.72 ? 2 : 1;
          img.drawLine(frame, x1: lX, y1: lY, x2: tipX, y2: tipY, color: chevronColor, thickness: thick);
          img.drawLine(frame, x1: rX, y1: rY, x2: tipX, y2: tipY, color: chevronColor, thickness: thick);
        }
        nextMarkPx += chevronSpacingPx;
      }
      accumPx += segLen;
    }

    // Destination pin if close and ahead of near plane
    final (destRx, destRy) = toCameraLocal(pts.length - 1, pts.last);
    if (camera == null || !camera.perspective3d || camera.camZAt(destRy) >= camera.nearCamZ) {
      final double destSx;
      final double destSy;
      if (camera != null) {
        final dp = camera.projectLocal(destRx, destRy);
        destSx = dp.sx;
        destSy = dp.sy;
      } else {
        destSx = anchorX + destRx;
        destSy = anchorY + destRy * pitchY;
      }
      final int dx = destSx.round();
      final int dy = destSy.round();
      if (dx >= -10 && dx <= w + 10 && dy >= -10 && dy <= h + 10) {
        img.fillCircle(frame, x: dx, y: dy, radius: 7, color: img.ColorRgba8(255, 59, 48, 255));
        img.drawCircle(frame, x: dx, y: dy, radius: 7, color: img.ColorRgba8(255, 255, 255, 255));
        img.fillCircle(frame, x: dx, y: dy, radius: 3, color: img.ColorRgba8(255, 255, 255, 255));
      }
    }
  }

  /// Pure CPU Software Map Renderer (Runs 100% in CPU RAM without Metal GPU, perfect for background)
  Future<Uint8List?> _renderCpuMapFrame(int w, int h) async {
    try {
      final rawUserPos = navManager?.currentLocation ?? const LatLng(20.9832, 105.8425);
      final double rawHeadingDeg = navManager?.effectiveHeading ?? navManager?.currentHeading ?? 0.0;
      final activeRoute = navManager?.activeRoute ?? navManager?.previewRoute;
      final int zoom = _minimapZoom;
      final isDark = _streamMapStyle.contains('dark');

      final tiles = _collectVisibleOsmTiles(rawUserPos, radius: zoom <= 14 ? 2 : 1);
      final pose = _resolveExternalGuidedPose(
        userPos: rawUserPos,
        displayZoom: zoom,
        rawHeadingDeg: rawHeadingDeg,
        activeRoute: activeRoute,
        tilesOverride: tiles,
      );
      final userPos = pose.userPos;
      final double headingDeg = pose.headingDeg;
      final pts = pose.pts;

      final double n = math.pow(2.0, zoom).toDouble();
      final double latRad = userPos.latitude * (math.pi / 180.0);
      final double worldX = (userPos.longitude + 180.0) / 360.0 * n * 256.0;
      final double worldY = (1.0 - (math.log(math.tan(latRad) + 1.0 / math.cos(latRad)) / math.pi)) / 2.0 * n * 256.0;

      if (_isOsm3dStyle) {
        final double anchorX = w / 2.0;
        final double anchorY = h * 0.67;
        const double pitchY = 0.88;
        final double th = headingDeg * (math.pi / 180.0);
        final camera = _buildOsm3dCamera(
          width: w,
          height: h,
          anchorX: anchorX,
          anchorY: anchorY,
          headingDeg: headingDeg,
        );
        final frame = _acquireReusableCpuFrame(w, h);
        _osm3dRenderer.renderFrame(
          buf32: frame.buffer.asUint32List(),
          width: w,
          height: h,
          tiles: tiles,
          userWorldX: worldX,
          userWorldY: worldY,
          displayZoom: zoom,
          headingDeg: headingDeg,
          anchorX: anchorX,
          anchorY: anchorY,
          pitchY: pitchY,
          isDark: isDark,
          perspective3d: true,
          skyHorizonPx: 12,
        );
        _drawProjectedRouteOnFrame(
          frame: frame,
          w: w,
          h: h,
          userPos: userPos,
          worldX: worldX,
          worldY: worldY,
          n: n,
          anchorX: anchorX,
          anchorY: anchorY,
          pitchY: pitchY,
          cosT: math.cos(th),
          sinT: math.sin(th),
          pts: pts,
          isDark: isDark,
          camera: camera,
        );
        _drawStandbyVehiclePuck(frame, anchorX.round(), anchorY.round(), isDark);
        final labels = _osm3dRenderer.collectVisibleRoadLabels(
          width: w,
          height: h,
          tiles: tiles,
          userWorldX: worldX,
          userWorldY: worldY,
          displayZoom: zoom,
          camera: camera,
          skyHorizonPx: 12,
          avoidHudPills: false,
          maxLabels: 1,
          minTier: 2,
        );
        return await _compressRgbaToJpeg(
          _frameRawRgbaView(frame, w, h),
          w,
          h,
          quality: 74,
          roadLabels: _serializeRoadLabels(labels),
          isDark: isDark,
        );
      }

      final int centerTileX = (worldX / 256.0).floor();
      final int centerTileY = (worldY / 256.0).floor();
      final double subTileX = worldX - (centerTileX * 256.0);
      final double subTileY = worldY - (centerTileY * 256.0);

      // Create a 320x320 CPU patch centered on user (covers 144x208 frame at all rotation angles)
      const int patchSize = 320;
      final patch = img.Image(width: patchSize, height: patchSize, numChannels: 4);
      final bgColor = isDark ? img.ColorRgba8(11, 17, 26, 255) : img.ColorRgba8(240, 243, 246, 255);
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
      if (pts.length >= 2) {
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

      // Rotate patch by -headingDeg so ahead is UP (linear interpolation avoids slow cubic CPU stalls)
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

      _drawStandbyVehiclePuck(frame, (w / 2.0).round(), (h * 0.67).round(), isDark);
      return await _compressRgbaToJpeg(_frameRawRgbaView(frame, w, h), w, h, quality: 74);
    } catch (e, stack) {
      debugPrint('[_renderCpuMapFrame Error] $e\n$stack');
      return null;
    }
  }

  void _drawStandbyVehiclePuck(img.Image frame, int vx, int vy, bool isDark) {
    final auraColor = isDark ? img.ColorRgba8(48, 136, 255, 56) : img.ColorRgba8(26, 115, 232, 48);
    final rimColor = isDark ? img.ColorRgba8(100, 148, 210, 220) : img.ColorRgba8(186, 206, 232, 235);
    final arrowColor = isDark ? img.ColorRgba8(48, 136, 255, 255) : img.ColorRgba8(26, 115, 232, 255);
    img.fillCircle(frame, x: vx, y: vy, radius: 14, color: auraColor);
    img.fillCircle(frame, x: vx, y: vy, radius: 10, color: img.ColorRgba8(255, 255, 255, 255));
    img.drawCircle(frame, x: vx, y: vy, radius: 10, color: rimColor);
    img.fillPolygon(frame, vertices: [
      img.Point(vx, vy - 6),
      img.Point(vx + 5, vy + 5),
      img.Point(vx, vy + 2),
      img.Point(vx - 5, vy + 5),
    ], color: arrowColor);
  }

  /// Pure CPU Software 320x240 Full-Screen Navigation Frame Renderer (for background / screen-off)
  /// Uses CPU CoreGraphics + CoreText on iOS so background ("treo app") looks 100% identical to foreground ("trong app")!
  Future<Uint8List?> _renderCpuNavigationFrame(int w, int h) async {
    try {
      final rawUserPos = navManager?.currentLocation ?? const LatLng(20.9832, 105.8425);
      final double rawHeadingDeg = navManager?.effectiveHeading ?? navManager?.currentHeading ?? 0.0;
      final activeRoute = navManager?.activeRoute ?? navManager?.previewRoute;
      final int zoom = _minimapZoom;
      final isDark = _streamMapStyle.contains('dark');

      final tiles = _collectVisibleOsmTiles(rawUserPos, radius: zoom <= 14 ? 2 : 1);
      final pose = _resolveExternalGuidedPose(
        userPos: rawUserPos,
        displayZoom: zoom,
        rawHeadingDeg: rawHeadingDeg,
        activeRoute: activeRoute,
        tilesOverride: tiles,
      );
      final userPos = pose.userPos;
      final double headingDeg = pose.headingDeg;
      final pts = pose.pts;

      final double n = math.pow(2.0, zoom).toDouble();
      final double latRad = userPos.latitude * (math.pi / 180.0);
      final double worldX = (userPos.longitude + 180.0) / 360.0 * n * 256.0;
      final double worldY = (1.0 - (math.log(math.tan(latRad) + 1.0 / math.cos(latRad)) / math.pi)) / 2.0 * n * 256.0;

      // ===== Heading-up + 3D perspective projection (100% CPU) =====
      const int vx = 226;
      final int vy = (h * 0.74).round(); // ~160 for h=216
      const double tilt = 0.74;
      final double th = headingDeg * (math.pi / 180.0);
      final double cosT = math.cos(th);
      final double sinT = math.sin(th);

      final frame = _acquireReusableCpuFrame(w, h);
      final Uint32List buf32 = frame.buffer.asUint32List();
      List<Map<String, dynamic>>? osmNavRoadLabels;

      if (_isOsm3dStyle) {
        final camera = _buildOsm3dCamera(
          width: w,
          height: h,
          anchorX: vx.toDouble(),
          anchorY: vy.toDouble(),
          headingDeg: headingDeg,
        );
        _osm3dRenderer.renderFrame(
          buf32: buf32,
          width: w,
          height: h,
          tiles: tiles,
          userWorldX: worldX,
          userWorldY: worldY,
          displayZoom: zoom,
          headingDeg: headingDeg,
          anchorX: vx.toDouble(),
          anchorY: vy.toDouble(),
          pitchY: tilt,
          isDark: isDark,
          perspective3d: true,
          skyHorizonPx: 22,
        );
        _drawProjectedRouteOnFrame(
          frame: frame,
          w: w,
          h: h,
          userPos: userPos,
          worldX: worldX,
          worldY: worldY,
          n: n,
          anchorX: vx.toDouble(),
          anchorY: vy.toDouble(),
          pitchY: tilt,
          cosT: cosT,
          sinT: sinT,
          pts: pts,
          isDark: isDark,
          camera: camera,
        );
        final labels = _osm3dRenderer.collectVisibleRoadLabels(
          width: w,
          height: h,
          tiles: tiles,
          userWorldX: worldX,
          userWorldY: worldY,
          displayZoom: zoom,
          camera: camera,
          skyHorizonPx: 22,
          avoidHudPills: true,
          maxLabels: 1,
          targetStreetName: navManager?.effectiveNextStreetName,
          strictTargetStreetOnly: true,
        );
        osmNavRoadLabels = _serializeRoadLabels(labels);
      } else {
        const int extrude = 8;
        final bool hasTiles3d = !isDark;
        final int fh = h + extrude + 1;
        final Uint8List foot = Uint8List(w * fh);

        final int baseR = isDark ? 11 : 240;
        final int baseG = isDark ? 17 : 243;
        final int baseB = isDark ? 26 : 246;
        final int wallR = isDark ? 40 : 196, wallG = isDark ? 52 : 203, wallB = isDark ? 66 : 210;
        final int baseColor32 = 0xFF000000 | (baseB << 16) | (baseG << 8) | baseR;
        final int wallColor32 = 0xFF000000 | (wallB << 16) | (wallG << 8) | wallR;
        final int roofEdge32 = isDark
            ? (0xFF000000 | (84 << 16) | (66 << 8) | 50)
            : (0xFF000000 | (192 << 16) | (184 << 8) | 176);
        final int roofFlat32 = isDark
            ? (0xFF000000 | (68 << 16) | (52 << 8) | 38)
            : (0xFF000000 | (236 << 16) | (232 << 8) | 228);

        int lastTx = -999999, lastTy = -999999;
        Uint32List? curTile32;
        Uint8List? curMask;

        // 1. Ground + footprint
        for (int sy = 0; sy < fh; sy++) {
          final double dy = (sy - vy) / tilt;
          double wx = worldX - vx * cosT - dy * sinT;
          double wy = worldY - vx * sinT + dy * cosT;
          final int rowOff = sy * w;
          final bool inScreenY = sy < h;

          for (int sx = 0; sx < w; sx++) {
            final int iwx = wx.floor();
            final int iwy = wy.floor();
            wx += cosT;
            wy += sinT;

            final int tx = iwx >> 8;
            final int ty = iwy >> 8;
            if (tx != lastTx || ty != lastTy) {
              lastTx = tx;
              lastTy = ty;
              final String key = '$zoom/$tx/$ty';
              curTile32 = _cpuTileRgba32[key];
              curMask = _tileMasks[key];
            }

            int color32 = baseColor32;
            bool isBuilding = false;
            final tile32 = curTile32;
            if (tile32 != null) {
              final int pIdx = ((iwy & 255) << 8) | (iwx & 255);
              color32 = tile32[pIdx] | 0xFF000000;
              if (hasTiles3d) {
                final mask = curMask;
                if (mask != null && mask[pIdx] == 1) {
                  isBuilding = true;
                }
              }
            }
            final int idx = rowOff + sx;
            if (isBuilding) {
              foot[idx] = 1;
              if (inScreenY) buf32[idx] = wallColor32;
            } else if (inScreenY) {
              buf32[idx] = color32;
            }
          }
        }

        // 2. Route polyline projected through the same transform
        _drawProjectedRouteOnFrame(
          frame: frame,
          w: w,
          h: h,
          userPos: userPos,
          worldX: worldX,
          worldY: worldY,
          n: n,
          anchorX: vx.toDouble(),
          anchorY: vy.toDouble(),
          pitchY: tilt,
          cosT: cosT,
          sinT: sinT,
          pts: pts,
          isDark: isDark,
        );

        // 3. Extrude raster buildings upward
        if (hasTiles3d) {
          for (int sy = 0; sy < fh; sy++) {
            final int rowOff = sy * w;
            for (int sx = 0; sx < w; sx++) {
              if (foot[rowOff + sx] != 1) continue;
              for (int dh = 1; dh < extrude; dh++) {
                final int ny = sy - dh;
                if (ny >= 0 && ny < h) {
                  buf32[ny * w + sx] = wallColor32;
                }
              }
              final int ry = sy - extrude;
              if (ry >= 0 && ry < h) {
                final bool edge = sx == 0 ||
                    sx == w - 1 ||
                    sy == 0 ||
                    sy >= fh - 1 ||
                    foot[rowOff - w + sx] == 0 ||
                    foot[rowOff + w + sx] == 0 ||
                    foot[rowOff + sx - 1] == 0 ||
                    foot[rowOff + sx + 1] == 0;
                buf32[ry * w + sx] = edge ? roofEdge32 : roofFlat32;
              }
            }
          }
        }
      }

      final hudData = _buildNavHudPayload(
        vx: vx.toDouble(),
        vy: vy.toDouble(),
        isDark: isDark,
      );

      if (Platform.isIOS || Platform.isAndroid) {
        final rawRgba = _frameRawRgbaView(frame, w, h);
        final nativeJpg = await _compressRgbaToJpeg(
          rawRgba,
          w,
          h,
          quality: 72,
          hud: hudData,
          roadLabels: osmNavRoadLabels,
          isDark: isDark,
        );
        if (nativeJpg != null && nativeJpg.isNotEmpty) {
          return nativeJpg;
        }
      }

      // Pure-Dart fallback if non-iOS
      _drawStandbyVehiclePuck(frame, vx, vy, isDark);
      final maxBytes = _maxJpegFrameBytes;
      var jpg = Uint8List.fromList(img.encodeJpg(frame, quality: 72));
      if (jpg.length > maxBytes) {
        for (final q in const [66, 60, 54]) {
          jpg = Uint8List.fromList(img.encodeJpg(frame, quality: q));
          if (jpg.length <= maxBytes) break;
        }
      }
      return jpg;
    } catch (e) {
      return null;
    }
  }

  void _sendPacketOverTcpAp(Socket sock, Uint8List jpegBytes) {
    final len = jpegBytes.length;
    if (len == 0 || len > 32700) return;
    final packet = Uint8List(4 + len);
    packet[0] = 0xAA;
    packet[1] = 0xBB;
    packet[2] = (len >> 8) & 0xFF;
    packet[3] = len & 0xFF;
    packet.setRange(4, 4 + len, jpegBytes);
    try {
      final now = DateTime.now();
      _tcpInFlightFrames = (_tcpInFlightFrames + 1).clamp(1, maxTcpInFlightFrames);
      _lastTcpSendTime = now;
      _awaitingTcpAckSince ??= now;
      sock.add(packet);
      _consecutiveWifiErrors = 0;
      if (_frameCount % 50 == 0) {
        bleService.logInfo('TX [SoftAP TCP] Frame #$_frameCount ($_frameSizeKb KB, ${_actualFps.toStringAsFixed(1)} FPS)');
      }
    } catch (e) {
      _closeTcpApSocket(sock, notifyIfEmpty: true, scheduleReconnect: true, reason: 'tx err: $e');
    }
  }

  void _dispatchTransmission(Uint8List jpegBytes) {
    final now = DateTime.now();

    // 1. Primary Raw TCP Stream (SoftAP 8081 or Hotspot 8081/8082) -> Bounded 2-frame pipeline via 'K' ACK
    final tcpSock = _tcpApSocket;
    if (tcpSock != null) {
      final elapsed = now.difference(_lastTcpSendTime).inMilliseconds;
      final staleAckTimeoutMs = selectTcpInFlightTimeoutMs(
        hotspotMode: _isHotspotTransportActive,
      );
      if (!canSendNextTcpFrame(
        inFlight: _tcpInFlightFrames,
        elapsedSinceLastSendMs: elapsed,
        staleAckTimeoutMs: staleAckTimeoutMs,
      )) {
        return;
      }
      if (_tcpInFlightFrames >= maxTcpInFlightFrames && elapsed >= staleAckTimeoutMs) {
        _tcpInFlightFrames = 0;
      }
      if (elapsed < 16) {
        return;
      }
      _sendPacketOverTcpAp(tcpSock, jpegBytes);
      return;
    }

    // 2. WebSocket Broadcast (iPhone Hotspot 172.20.10.1:8080 or Legacy SoftAP WS 8080)
    if (_wsClients.isNotEmpty) {
      final elapsedSinceLastWs = now.difference(_lastWsSendTime).inMilliseconds;
      if (!_wsReadyForNextFrame && elapsedSinceLastWs < 650) {
        return;
      }
      if (elapsedSinceLastWs < 16) {
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
      if (_frameCount % 50 == 0) {
        bleService.logInfo('TX [WS] Frame #$_frameCount ($_frameSizeKb KB, ${_actualFps.toStringAsFixed(1)} FPS)');
      }
      return;
    }

    // 3. Fallback TCP if BLE reported WiFi IP other than Hotspot
    if (bleService.isWifiConnected && bleService.wifiIp != null && bleService.wifiIp != '172.20.10.1') {
      if (!_isSendingWifi) {
        _sendJpegOverWifi(jpegBytes);
      }
      return;
    }
  }

  /// Transmit a single 320x240 simulator frame to ESP32 (via TCP 8081 or WebSocket 8080)
  void transmitSimulatorFrame(Uint8List jpegBytes) {
    _latestJpegBytes = jpegBytes;
    _dispatchTransmission(jpegBytes);
  }

  /// Broadcast JSON telemetry to connected ESP32 peers (Raw TCP 8081 or WebSocket 8080)
  void broadcastTelemetry(String jsonStr) {
    final tcpSock = _tcpApSocket;
    if (tcpSock != null) {
      try {
        final payload = utf8.encode(jsonStr);
        final len = payload.length;
        if (len > 0 && len <= 8192) {
          final pkt = Uint8List(4 + len);
          pkt[0] = 0xAA;
          pkt[1] = 0xCC;
          pkt[2] = (len >> 8) & 0xFF;
          pkt[3] = len & 0xFF;
          pkt.setRange(4, 4 + len, payload);
          tcpSock.add(pkt);
          _lastTcpSendTime = DateTime.now();
          _awaitingTcpAckSince ??= _lastTcpSendTime;
        }
      } catch (e) {
        _closeTcpApSocket(
          tcpSock,
          notifyIfEmpty: true,
          scheduleReconnect: true,
          reason: 'telemetry tx err: $e',
        );
      }
    }
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

  /// Asynchronously pre-fetch surrounding OSM Vector 3D or MapTiler / Goong raster tiles
  void _prefetchSurroundingTiles(LatLng pos, int zoom) {
    final bool fetchCenterOsmForSnap =
        !_isOsm3dStyle && (navManager?.isExternalNavTelemetryActive ?? false);
    if (_isOsm3dStyle || fetchCenterOsmForSnap) {
      const int vZoom = 15;
      const double n15 = 32768.0;
      final double latRad = pos.latitude * (math.pi / 180.0);
      final int cx15 = ((pos.longitude + 180.0) / 360.0 * n15).floor();
      final int cy15 = ((1.0 - (math.log(math.tan(latRad) + 1.0 / math.cos(latRad)) / math.pi)) / 2.0 * n15).floor();
      final int rad = _isOsm3dStyle ? (zoom <= 14 ? 2 : 1) : 0;

      for (int dx = -rad; dx <= rad; dx++) {
        for (int dy = -rad; dy <= rad; dy++) {
          final int tx = cx15 + dx;
          final int ty = cy15 + dy;
          final String k15 = '15/$tx/$ty';
          final String k14 = '14/${tx >> 1}/${ty >> 1}';
          if (!_osmTileCache.containsKey(k15) &&
              !_osmTileCache.containsKey(k14) &&
              !_pendingOsmFetches.contains(k15)) {
            _fetchOsmVectorTile(k15, tx, ty, vZoom);
          }
        }
      }
      if (_isOsm3dStyle) {
        _maybePrefetchSupplementalBuildings(pos, latRad);
        return;
      }
    }

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

    final int rad = (navManager?.isAnyNavActive ?? false) ? 2 : 1;
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

  Future<String?> _resolveOpenFreeMapTemplate() async {
    if (_openFreeMapTileTemplate != null) return _openFreeMapTileTemplate;
    try {
      final resp = await http.get(
        Uri.parse('https://tiles.openfreemap.org/planet'),
        headers: {'User-Agent': 'Mozilla/5.0'},
      ).timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        final json = jsonDecode(resp.body) as Map<String, dynamic>;
        final tiles = json['tiles'] as List?;
        if (tiles != null && tiles.isNotEmpty) {
          _openFreeMapTileTemplate = tiles.first.toString();
          return _openFreeMapTileTemplate;
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> _fetchOsmVectorTile(String key15, int x15, int y15, int z15) async {
    _pendingOsmFetches.add(key15);
    try {
      final apiKey = MapboxConfig.maptilerApiKey;
      OsmVectorTile? parsed;

      if (apiKey.isNotEmpty) {
        try {
          final url = 'https://api.maptiler.com/tiles/v3/$z15/$x15/$y15.pbf?key=$apiKey';
          final resp = await http.get(
            Uri.parse(url),
            headers: {'User-Agent': 'Mozilla/5.0'},
          ).timeout(const Duration(seconds: 6));
          if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) {
            parsed = OsmVectorTile.parsePbf(resp.bodyBytes, z15, x15, y15);
            if (parsed != null) {
              _storeOsmTile(key15, parsed);
              return;
            }
          }
        } catch (_) {}
      }

      // Zero-key OpenFreeMap OSM MVT fallback at z14
      final x14 = x15 >> 1;
      final y14 = y15 >> 1;
      final k14 = '14/$x14/$y14';
      if (!_osmTileCache.containsKey(k14) && !_pendingOsmFetches.contains(k14)) {
        _pendingOsmFetches.add(k14);
        try {
          final tmpl = await _resolveOpenFreeMapTemplate();
          if (tmpl != null) {
            final url = tmpl
                .replaceAll('{z}', '14')
                .replaceAll('{x}', '$x14')
                .replaceAll('{y}', '$y14');
            final resp = await http.get(
              Uri.parse(url),
              headers: {'User-Agent': 'Mozilla/5.0'},
            ).timeout(const Duration(seconds: 6));
            if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) {
              parsed = OsmVectorTile.parsePbf(resp.bodyBytes, 14, x14, y14);
              if (parsed != null) {
                _storeOsmTile(k14, parsed);
              }
            }
          }
        } finally {
          _pendingOsmFetches.remove(k14);
        }
      }
    } catch (_) {
    } finally {
      _pendingOsmFetches.remove(key15);
    }
  }

  void _storeOsmTile(String key, OsmVectorTile tile) {
    _osmTileCache[key] = tile;
    if (_osmTileCache.length > 28) {
      _osmTileCache.remove(_osmTileCache.keys.first);
    }
    _latestJpegBytes = null;
    notifyListeners();
  }

  void _maybePrefetchSupplementalBuildings(LatLng pos, double latRad) {
    const double n17 = 131072.0; // 2^17
    final int cx17 = ((pos.longitude + 180.0) / 360.0 * n17).floor();
    final int cy17 =
        ((1.0 - (math.log(math.tan(latRad) + 1.0 / math.cos(latRad)) / math.pi)) / 2.0 * n17)
            .floor();
    for (int dx = -1; dx <= 1; dx++) {
      for (int dy = -1; dy <= 1; dy++) {
        if (_pendingSuppFetches.length >= 6) return;
        final int x17 = cx17 + dx;
        final int y17 = cy17 + dy;
        final String k17 = '17/$x17/$y17';
        if (_osmSuppBuildingCache.containsKey(k17) || _pendingSuppFetches.contains(k17)) {
          continue;
        }
        final String parentKey15 = '15/${x17 >> 2}/${y17 >> 2}';
        final parent15 = _osmTileCache[parentKey15];
        if (parent15 == null || parent15.buildings.length >= 80) {
          continue;
        }
        _fetchSupplementalBuildingTile(k17, x17, y17, parent15);
      }
    }
  }

  Future<void> _fetchSupplementalBuildingTile(
    String k17,
    int x17,
    int y17,
    OsmVectorTile parent15,
  ) async {
    _pendingSuppFetches.add(k17);
    try {
      final url =
          'https://mt1.google.com/vt/lyrs=m&x=$x17&y=$y17&z=17&hl=vi&apistyle='
          's.e%3Al|p.v%3Aoff%2C'
          's.t%3A2|p.v%3Aoff%2C'
          's.t%3A4|p.v%3Aoff%2C'
          's.t%3A5|s.e%3Ag|p.c%3A%23eff2f6%2C'
          's.t%3A81|s.e%3Ag.f|p.c%3A%23eff2f6%2C'
          's.t%3A1297|s.e%3Ag.f|p.c%3A%23e45ca8%2C'
          's.t%3A1297|s.e%3Ag.s|p.c%3A%23000000';
      final resp = await http.get(
        Uri.parse(url),
        headers: {'User-Agent': 'Mozilla/5.0'},
      ).timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) return;

      final decoded = img.decodePng(resp.bodyBytes);
      if (decoded == null) return;
      final rgba = decoded.numChannels == 4 ? decoded : decoded.convert(numChannels: 4);
      final rawExtracted = OsmVectorTile.extractBuildingsFromMask(
        rgba.toUint8List(),
        rgba.width,
        rgba.height,
        17,
        x17,
        y17,
      );
      final deduplicated = rawExtracted.withoutOverlapsFrom([parent15]);
      _osmSuppBuildingCache[k17] = deduplicated;
      if (_osmSuppBuildingCache.length > 64) {
        _osmSuppBuildingCache.remove(_osmSuppBuildingCache.keys.first);
      }
      _latestJpegBytes = null;
      notifyListeners();
    } catch (_) {
    } finally {
      _pendingSuppFetches.remove(k17);
    }
  }

  static const String _goongMapApiStyle =
      's.e%3Al.t%7Cp.v%3Aoff%2Cs.t%3A2%7Cs.e%3Al.i%7Cp.v%3Aoff%2Cs.t%3A4%7Cs.e%3Al.i%7Cp.v%3Aoff%2Cs.t%3A5%7Cs.e%3Ag%7Cp.c%3A%23eff2f6%2Cs.t%3A81%7Cs.e%3Ag.f%7Cp.c%3A%23eff2f6%2Cs.t%3A82%7Cs.e%3Ag%7Cp.c%3A%23cce8d0%2Cs.t%3A1297%7Cs.e%3Ag.f%7Cp.c%3A%23e45ca8%2Cs.t%3A1297%7Cs.e%3Ag.s%7Cp.v%3Aoff%2Cs.t%3A3%7Cs.e%3Ag.f%7Cp.c%3A%23ffffff%2Cs.t%3A3%7Cs.e%3Ag.s%7Cp.c%3A%23cbd5e1%2Cs.t%3A2%7Cs.e%3Ag%7Cp.c%3A%23c8e8cc%2Cs.t%3A6%7Cs.e%3Ag%7Cp.c%3A%239fd0fa';

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
              // Building fill uses magenta marker #e45ca8; extract footprint mask, recolor to soft light-gray building block
              final mask = Uint8List(256 * 256);
              for (int my = 0; my < 256; my++) {
                for (int mx = 0; mx < 256; mx++) {
                  final p = cpuImg.getPixel(mx, my);
                  if (p.r.toInt() - p.g.toInt() >= 18 && p.b.toInt() - p.g.toInt() >= 10) {
                    mask[my * 256 + mx] = 1;
                    p.r = 224;
                    p.g = 229;
                    p.b = 234;
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
            if (cpuImg.width == 256 && cpuImg.height == 256) {
              _cpuTileRgba32[key] = Uint32List.fromList(cpuImg.buffer.asUint32List());
            }
            if (_cpuTileCache.length > 100) {
              final firstK = _cpuTileCache.keys.first;
              _cpuTileCache.remove(firstK);
              _cpuTileRgba32.remove(firstK);
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
    final bgPaint = Paint()..color = isDark ? const Color(0xFF0B111A) : const Color(0xFFF0F3F6);
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
            Paint()..filterQuality = FilterQuality.high,
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

    // Draw Route Polyline whenever an active route, preview route, or external guidance guide exists
    final points = _resolveMapRoutePoints(activeRoute);

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
    final bgPaint = Paint()..color = isDark ? const Color(0xFF0B111A) : const Color(0xFFF0F3F6);
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
            Paint()..filterQuality = FilterQuality.high,
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
    final points = _resolveMapRoutePoints(activeRoute);

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
    final hudData = _buildNavHudPayload(
      vx: cx,
      vy: cy,
      isDark: isDark,
      distOverride: distToTurn,
    );
    final int turnCode = hudData['turnCode'] as int;
    final String nextStreet = hudData['nextStreet'] as String;
    final String distStr = hudData['distStr'] as String;

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
    final String etaText = hudData['etaText'] as String;
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
    final subTp = TextPainter(
      text: TextSpan(
        text: hudData['subText'] as String,
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
