import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../models/esp_payload.dart';

class BleDeviceItem {
  final BluetoothDevice device;
  final String name;
  final int rssi;

  BleDeviceItem({
    required this.device,
    required this.name,
    required this.rssi,
  });
}

class BleLogItem {
  final DateTime timestamp;
  final String message;
  final bool isError;
  final bool isTx;

  BleLogItem({
    required this.message,
    this.isError = false,
    this.isTx = true,
  }) : timestamp = DateTime.now();
}

class BleService extends ChangeNotifier {
  // Custom Navigation Service & Characteristic UUIDs (Standard 16-bit UUID / Custom)
  static final Guid navServiceUuid = Guid('0000FFE0-0000-1000-8000-00805F9B34FB');
  static final Guid navCharUuid = Guid('0000FFE1-0000-1000-8000-00805F9B34FB');

  // Nordic UART Service as secondary fallback
  static final Guid nusServiceUuid = Guid('6E400001-B5A3-F393-E0A9-E50E24DCCA9E');
  static final Guid nusRxCharUuid = Guid('6E400002-B5A3-F393-E0A9-E50E24DCCA9E');

  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _writeCharacteristic;
  bool _isScanning = false;
  bool _isConnected = false;
  bool _isConnecting = false;
  String? _connectedDeviceName;

  final List<BleDeviceItem> _discoveredDevices = [];
  final List<BleLogItem> _logs = [];

  StreamSubscription? _scanSubscription;
  StreamSubscription? _adapterStateSubscription;
  StreamSubscription? _connectionSubscription;
  Timer? _heartbeatTimer;
  Timer? _wifiProbeTimer;
  DateTime _lastTxTime = DateTime.now();

  // ESP32 WiFi SoftAP Streaming State (Default: ysiduc navi / 192.168.4.1:8080)
  String _wifiStatus = 'disconnected'; // 'disconnected', 'connecting', 'connected'
  String? _wifiIp;
  int _wifiPort = 8080;
  final String _wifiSsid = 'ysiduc navi';
  final String _wifiPass = '00000000';

  // Getters
  bool get isScanning => _isScanning;
  bool get isConnected => _isConnected;
  bool get isConnecting => _isConnecting;
  String? get connectedDeviceName => _connectedDeviceName;
  BluetoothDevice? get connectedDevice => _connectedDevice;
  List<BleDeviceItem> get discoveredDevices => List.unmodifiable(_discoveredDevices);
  List<BleLogItem> get logs => List.unmodifiable(_logs);
  String get wifiStatus => _wifiStatus;
  String? get wifiIp => _wifiIp;
  int get wifiPort => _wifiPort;
  String get wifiSsid => _wifiSsid;
  String get wifiPass => _wifiPass;
  bool get isWifiConnected => _wifiStatus == 'connected' && _wifiIp != null && _wifiIp!.isNotEmpty;

  BleService() {
    _initBle();
    _startWifiProbe();
  }

  void _startWifiProbe() {
    _wifiProbeTimer?.cancel();
    _wifiProbeTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      // Only probe if currently disconnected to discover ESP32 AP without disrupting active streams
      if (_wifiStatus != 'connected') {
        probeEsp32Wifi();
      }
    });
  }

  /// Reset WiFi status to disconnected when stream socket fails
  void setWifiDisconnected() {
    if (_wifiStatus == 'connected' && _wifiIp != '172.20.10.1') {
      _wifiStatus = 'disconnected';
      _wifiIp = null;
      notifyListeners();
    }
  }

  /// Mark Hotspot WebSocket stream active from iPhone
  void setHotspotConnected(String ip, int port) {
    _wifiStatus = 'connected';
    _wifiIp = ip;
    _wifiPort = port;
    _addLog('Hotspot WebSocket: ESP32 đã kết nối vào iPhone ($ip:$port)', isTx: false);
    notifyListeners();
  }

  /// Mark Hotspot WebSocket disconnected
  void setHotspotDisconnected() {
    if (_wifiIp == '172.20.10.1') {
      _wifiStatus = 'disconnected';
      _wifiIp = null;
      _addLog('Hotspot WebSocket: ESP32 đã ngắt kết nối', isTx: false);
      notifyListeners();
    }
  }

  /// Send Wi-Fi credentials to ESP32 over BLE so it connects to iPhone Personal Hotspot
  Future<bool> sendWifiCredentials(String ssid, String pass) => sendWifiConfig(ssid, pass);

  /// Automatically probe ESP32 SoftAP TCP port on 192.168.4.1:8080 (fallback only)
  Future<void> probeEsp32Wifi() async {
    // If currently connected via Hotspot WebSocket (172.20.10.1), keep connected
    if (_wifiIp == '172.20.10.1' && _wifiStatus == 'connected') {
      return;
    }

    try {
      final socket = await Socket.connect('192.168.4.1', 8080, timeout: const Duration(milliseconds: 400));
      socket.destroy();
      if (_wifiStatus != 'connected') {
        _wifiStatus = 'connected';
        _wifiIp = '192.168.4.1';
        _wifiPort = 8080;
        _addLog('Đã kết nối Wi-Fi ESP32: ysiduc navi (192.168.4.1:8080)', isTx: false);
        notifyListeners();
      }
    } catch (_) {
      if (_wifiStatus == 'connected' && _wifiIp != '172.20.10.1') {
        _wifiStatus = 'disconnected';
        _wifiIp = null;
        notifyListeners();
      }
    }
  }


  void _initBle() {
    try {
      _adapterStateSubscription = FlutterBluePlus.adapterState.listen((state) {
        _addLog('Bluetooth Adapter State: $state', isTx: false);
        if (state == BluetoothAdapterState.on) {
          // BLE is ON: check if ESP32 is already connected via iOS Settings > Bluetooth
          Future.delayed(const Duration(milliseconds: 800), _autoConnectIfSystemConnected);
        } else {
          _handleDisconnect();
        }
      }, onError: (e) {
        // Handle platform error quietly
      });
    } catch (_) {
      // Platform unsupported in mock test environment
    }
  }

  /// Automatically detect and connect to any BLE device iOS has connected at system level.
  /// Uses Guid('1800') = Generic Access Profile, which ALL BLE devices advertise.
  /// IMPORTANT: flutter_blue_plus v2 requires device.connect() even for system-connected devices.
  Future<void> _autoConnectIfSystemConnected() async {
    if (_isConnected || _isConnecting) return;
    try {
      // Guid('1800') = Generic Access Profile - required on iOS, present on all BLE devices
      final sysDevices = await FlutterBluePlus.systemDevices([Guid('1800')]);
      _addLog('systemDevices found: ${sysDevices.length} devices', isTx: false);
      for (final d in sysDevices) {
        final name = d.platformName.isNotEmpty ? d.platformName : 'ESP32-S3 Navi';
        _addLog('Auto-connecting to system device: $name', isTx: false);
        // connectToDevice handles the connect() call correctly
        await connectToDevice(d, displayName: name);
        if (_isConnected) return; // success, stop
      }
    } catch (e) {
      _addLog('Auto-connect error: $e', isTx: false);
    }
  }

  void _addLog(String msg, {bool isError = false, bool isTx = true}) {
    final item = BleLogItem(message: msg, isError: isError, isTx: isTx);
    _logs.insert(0, item);
    if (_logs.length > 2000) _logs.removeLast();
    notifyListeners();
  }

  /// Public logger helpers for other services (e.g. EspStreamService)
  void logError(String msg) => _addLog(msg, isError: true, isTx: true);
  void logInfo(String msg) => _addLog(msg, isError: false, isTx: true);

  /// Export all TX/RX logs as formatted text for debugging
  String exportLogsAsText() {
    final sb = StringBuffer();
    sb.writeln('================================================================');
    sb.writeln('NHAT KY TRUYEN NHAN GOI TIN (TX/RX) - ESP32 NAVIGATOR');
    sb.writeln('Thoi gian xuat file: ${DateTime.now().toLocal().toString()}');
    sb.writeln('Trang thai BLE: ${_isConnected ? "Da ket noi (${_connectedDeviceName ?? "ESP32"})" : "Chua ket noi"}');
    sb.writeln('Device ID / MAC: ${_connectedDevice?.remoteId.str ?? "N/A"}');
    sb.writeln('ATT MTU: $currentMtu (Payload chunk an toan: $safeChunkSize bytes)');
    sb.writeln('Trang thai Wi-Fi: $_wifiStatus (IP: ${_wifiIp ?? "N/A"}:$_wifiPort)');
    sb.writeln('Tong so ban ghi log: ${_logs.length}');
    sb.writeln('================================================================\n');

    for (final log in _logs.reversed) {
      final timeStr = '${log.timestamp.hour.toString().padLeft(2, '0')}:${log.timestamp.minute.toString().padLeft(2, '0')}:${log.timestamp.second.toString().padLeft(2, '0')}.${log.timestamp.millisecond.toString().padLeft(3, '0')}';
      final tag = log.isError ? '[ERROR]' : (log.isTx ? '[TX]' : '[RX]');
      sb.writeln('$timeStr $tag ${log.message}');
    }
    return sb.toString();
  }

  /// Start scanning for BLE devices
  Future<void> startScan({int timeoutSeconds = 12}) async {
    if (_isScanning) return;

    try {
      final isSupported = await FlutterBluePlus.isSupported;
      if (!isSupported) {
        _addLog('Thiết bị không hỗ trợ BLE', isError: true);
        return;
      }

      _discoveredDevices.clear();
      _isScanning = true;
      notifyListeners();

      // 1. Retrieve devices connected at iOS system level (Settings > Bluetooth)
      // Guid('1800') = Generic Access Profile UUID - required by iOS, present on ALL BLE devices.
      // After finding them, must still call device.connect() to attach to the app.
      try {
        final sysDevices = await FlutterBluePlus.systemDevices([Guid('1800')]);
        _addLog('Scan: systemDevices found ${sysDevices.length}', isTx: false);
        for (final d in sysDevices) {
          final name = d.platformName.isNotEmpty ? d.platformName : 'ESP32-S3 Navi (Đã kết nối iOS)';
          if (!_discoveredDevices.any((item) => item.device.remoteId == d.remoteId)) {
            _discoveredDevices.add(BleDeviceItem(device: d, name: name, rssi: -35));
          }
          // Auto-connect if not already connected in app
          if (!_isConnected && !_isConnecting) {
            _addLog('Tự động kết nối: $name', isTx: false);
            _isScanning = false;
            await connectToDevice(d, displayName: name);
            if (_isConnected) {
              _isScanning = true;
              notifyListeners();
              break;
            }
            _isScanning = true;
          }
        }
        notifyListeners();
      } catch (e) {
        _addLog('systemDevices error: $e', isTx: false);
      }

      _scanSubscription?.cancel();
      _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        for (final r in results) {
          final name = r.advertisementData.advName.isNotEmpty
              ? r.advertisementData.advName
              : (r.device.platformName.isNotEmpty ? r.device.platformName : 'Thiết bị BLE (${r.device.remoteId.str.substring(0, 5)})');

          final index = _discoveredDevices.indexWhere((item) => item.device.remoteId == r.device.remoteId);
          if (index >= 0) {
            _discoveredDevices[index] = BleDeviceItem(device: r.device, name: name, rssi: r.rssi);
          } else {
            _discoveredDevices.add(BleDeviceItem(device: r.device, name: name, rssi: r.rssi));
          }
        }
        notifyListeners();
      });

      await FlutterBluePlus.startScan(
        timeout: Duration(seconds: timeoutSeconds),
      );

      _isScanning = false;
      notifyListeners();
    } catch (e) {
      _isScanning = false;
      _addLog('Lỗi khi quét BLE: $e', isError: true);
      notifyListeners();
    }
  }

  /// Stop scanning
  Future<void> stopScan() async {
    await FlutterBluePlus.stopScan();
    _isScanning = false;
    notifyListeners();
  }

  /// Connect to ESP32 BLE device
  Future<bool> connectToDevice(BluetoothDevice device, {String? displayName}) async {
    if (_isConnecting) return false;

    _isConnecting = true;
    _connectedDeviceName = displayName ?? (device.platformName.isNotEmpty ? device.platformName : 'ESP32 Device');
    notifyListeners();
    _addLog('Đang kết nối tới: $_connectedDeviceName...', isTx: false);

    try {
      await stopScan();

      // Per flutter_blue_plus v2: must always call connect() even for iOS system-connected devices.
      // If already connected to iOS system, connect() typically completes instantly or
      // throws an "already connected" error which we handle gracefully below.
      try {
        await device.connect(
          license: License.nonprofit,
          timeout: const Duration(seconds: 10),
          autoConnect: false,
        );
      } catch (connectErr) {
        final errMsg = connectErr.toString().toLowerCase();
        // If "already connected" error, that's fine — continue to discoverServices
        if (!errMsg.contains('already') && !errMsg.contains('connected') && !errMsg.contains('133')) {
          rethrow;
        }
        _addLog('Thiết bị đã kết nối iOS system, tiếp tục khám phá dịch vụ...', isTx: false);
      }

      _connectedDevice = device;
      _isConnected = true;
      _isConnecting = false;
      _addLog('Đã kết nối thành công với: $_connectedDeviceName!', isTx: false);

      // Listen for disconnections & auto-reconnect if app was suspended/idle
      _connectionSubscription?.cancel();
      _connectionSubscription = device.connectionState.listen((state) async {
        if (state == BluetoothConnectionState.disconnected) {
          _addLog('Tạm ngắt kết nối Bluetooth, đang tự động kết nối lại...', isTx: false);
          _isConnected = false;
          notifyListeners();
          try {
            await Future.delayed(const Duration(milliseconds: 1500));
            if (!_isConnected && _connectedDevice != null) {
              await _connectedDevice!.connect(
                license: License.nonprofit,
                timeout: const Duration(seconds: 20),
                autoConnect: true,
              );
              await _discoverServices(_connectedDevice!);
              _isConnected = true;
              notifyListeners();
              _addLog('Đã tự động kết nối lại thành công!', isTx: false);
            }
          } catch (_) {
            _handleDisconnect();
          }
        }
      });

      // Request maximum MTU (512) for high-speed BLE JPEG stream
      try {
        await device.requestMtu(512);
      } catch (_) {}

      // Discover GATT Services
      await _discoverServices(device);
      _startHeartbeat();
      notifyListeners();
      return true;
    } catch (e) {
      _isConnecting = false;
      _handleDisconnect();
      _addLog('Kết nối thất bại: $e', isError: true);
      notifyListeners();
      return false;
    }
  }

  /// Start periodic heartbeat to prevent BLE sleep/timeout on iOS
  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _lastTxTime = DateTime.now();
    _heartbeatTimer = Timer.periodic(const Duration(milliseconds: 2500), (_) {
      if (!_isConnected || _writeCharacteristic == null) return;
      final diff = DateTime.now().difference(_lastTxTime).inMilliseconds;
      if (diff >= 2000) {
        final now = DateTime.now();
        final h = now.hour.toString().padLeft(2, '0');
        final m = now.minute.toString().padLeft(2, '0');
        sendRawString('{"type":"PING","clock":"$h:$m"}');
      }
    });
  }

  /// Discover services and locate the RX Characteristic
  Future<void> _discoverServices(BluetoothDevice device) async {
    try {
      final services = await device.discoverServices();
      _writeCharacteristic = null;

      for (final service in services) {
        for (final characteristic in service.characteristics) {
          final uuidStr = characteristic.uuid.str.toUpperCase();
          final isWritable = characteristic.properties.write ||
              characteristic.properties.writeWithoutResponse;

          if (isWritable) {
            if (uuidStr.contains('FFE1') || uuidStr.contains('6E400002') || _writeCharacteristic == null) {
              _writeCharacteristic = characteristic;
            }
          }
        }
      }

      if (_writeCharacteristic != null) {
        _addLog('Đã tìm thấy cổng GATT RX (${_writeCharacteristic!.uuid.str.substring(0, 8)}...)', isTx: false);
        
        // Listen for incoming notifications from ESP32 (e.g. WiFi connection status)
        try {
          if (_writeCharacteristic!.properties.notify) {
            await _writeCharacteristic!.setNotifyValue(true);
            _writeCharacteristic!.lastValueStream.listen((data) {
              if (data.isNotEmpty) {
                final str = utf8.decode(data, allowMalformed: true);
                _handleIncomingBleMessage(str);
              }
            });
          }
        } catch (_) {}
      } else {
        _addLog('Không tìm thấy Characteristic ghi dữ liệu!', isError: true);
      }
    } catch (e) {
      _addLog('Lỗi dò dịch vụ BLE: $e', isError: true);
    }
  }

  /// Send Navigation Payload to ESP32 (ALWAYS via BLE per architecture)
  Future<bool> sendNavPayload(EspNavPayload payload) async {
    final jsonStr = payload.toJsonString();

    if (!_isConnected || _writeCharacteristic == null) {
      return false;
    }

    try {
      final bytes = utf8.encode(jsonStr);

      await _writeCharacteristic!.write(
        bytes,
        withoutResponse: _writeCharacteristic!.properties.writeWithoutResponse,
      );

      _lastTxTime = DateTime.now();
      _addLog('TX [BLE ${payload.turnCode}|${payload.distanceToTurn}m]: $jsonStr');
      return true;
    } catch (e) {
      _addLog('Lỗi gửi BLE: $e', isError: true);
      return false;
    }
  }

  /// Send custom raw JSON or string (calls, songs, SMS, pings ALWAYS via BLE)
  Future<bool> sendRawString(String text) async {
    if (!_isConnected || _writeCharacteristic == null) {
      _addLog('Chưa kết nối ESP32', isError: true);
      return false;
    }

    try {
      final bytes = utf8.encode(text);
      await _writeCharacteristic!.write(
        bytes,
        withoutResponse: _writeCharacteristic!.properties.writeWithoutResponse,
      );
      _lastTxTime = DateTime.now();
      if (!text.contains('"PING"')) {
        _addLog('TX RAW: $text');
      }
      return true;
    } catch (e) {
      _addLog('Lỗi gửi RAW: $e', isError: true);
      return false;
    }
  }

  /// Safe BLE packet payload size calculated from iOS CoreBluetooth ATT MTU (max 185 -> payload max 180)
  int get currentMtu => _connectedDevice?.mtuNow ?? 185;
  int get safeChunkSize => (currentMtu > 23 ? (currentMtu - 5).clamp(20, 180) : 175);

  /// Send binary byte array over BLE (e.g. JPEG frames)
  Future<bool> sendRawBytes(Uint8List bytes) async {
    if (!_isConnected || _writeCharacteristic == null) return false;
    try {
      await _writeCharacteristic!.write(
        bytes,
        withoutResponse: true,
      );
      _lastTxTime = DateTime.now();
      return true;
    } catch (e) {
      _addLog('Lỗi gửi BLE Raw: $e', isError: true);
      return false;
    }
  }

  /// Disconnect current device
  Future<void> disconnect() async {
    if (_connectedDevice != null) {
      try {
        await _connectedDevice!.disconnect();
      } catch (_) {}
    }
    _handleDisconnect();
  }

  void _handleDisconnect() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _isConnected = false;
    _isConnecting = false;
    _connectedDevice = null;
    _writeCharacteristic = null;
    _wifiStatus = 'disconnected';
    _wifiIp = null;
    _addLog('Đã ngắt kết nối BLE', isTx: false);
    notifyListeners();
  }

  /// Handle incoming BLE Notification from ESP32
  void _handleIncomingBleMessage(String msg) {
    try {
      final json = jsonDecode(msg) as Map<String, dynamic>;
      if (json['type'] == 'WIFI_STATUS') {
        _wifiStatus = json['status'] as String? ?? 'disconnected';
        _wifiIp = json['ip'] as String?;
        _wifiPort = (json['port'] as num?)?.toInt() ?? 8080;
        _addLog('ESP32 WiFi: $_wifiStatus (IP: $_wifiIp:$_wifiPort)', isTx: false);
        notifyListeners();
      }
    } catch (_) {}
  }

  /// Send iPhone Personal Hotspot WiFi Credentials to ESP32 over BLE
  Future<bool> sendWifiConfig(String ssid, String pass) async {
    if (!_isConnected || _writeCharacteristic == null) {
      _addLog('Chưa kết nối BLE với ESP32', isError: true);
      return false;
    }

    final payload = jsonEncode({
      'type': 'WIFI_CONFIG',
      'ssid': ssid.trim(),
      'pass': pass.trim(),
    });

    _wifiStatus = 'connecting';
    notifyListeners();
    _addLog('Gửi cấu hình WiFi Hotspot: $ssid');
    return await sendRawString(payload);
  }

  void clearLogs() {
    _logs.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _wifiProbeTimer?.cancel();
    _heartbeatTimer?.cancel();
    _scanSubscription?.cancel();
    _adapterStateSubscription?.cancel();
    _connectionSubscription?.cancel();
    super.dispose();
  }
}
