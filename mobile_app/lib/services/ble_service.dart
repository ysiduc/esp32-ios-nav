import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
  BluetoothDevice? _systemBondedDevice;
  BluetoothCharacteristic? _writeCharacteristic;
  bool _isScanning = false;
  bool _isConnected = false;
  bool _isConnecting = false;
  String? _connectedDeviceName;

  final List<BleDeviceItem> _discoveredDevices = [];
  final List<BleLogItem> _logs = [];
  final Battery _battery = Battery();

  StreamSubscription? _scanSubscription;
  StreamSubscription? _adapterStateSubscription;
  StreamSubscription? _connectionSubscription;
  Timer? _heartbeatTimer;
  Timer? _wifiProbeTimer;
  DateTime _lastTxTime = DateTime.now();

  // ESP32 WiFi SoftAP & Bluetooth Configuration State (Default: ysiducnaga / 192.168.4.1:8081)
  String _wifiStatus = 'disconnected'; // 'disconnected', 'connecting', 'connected'
  String? _wifiIp;
  int _wifiPort = 8081;
  String _customBleName = 'ysiducnaga';
  String _wifiSsid = 'ysiducnaga';
  String _wifiPass = '12345678';
  String? _lastConnectedDeviceId;

  // Getters
  bool get isScanning => _isScanning;
  bool get isConnected => _isConnected;
  bool get isConnecting => _isConnecting;
  String? get connectedDeviceName => _connectedDeviceName;
  String get customBleName => _customBleName;
  BluetoothDevice? get connectedDevice => _connectedDevice;
  BluetoothDevice? get systemBondedDevice => _systemBondedDevice;
  List<BleDeviceItem> get discoveredDevices => List.unmodifiable(_discoveredDevices);
  List<BleLogItem> get logs => List.unmodifiable(_logs);
  String get wifiStatus => _wifiStatus;
  String? get wifiIp => _wifiIp;
  int get wifiPort => _wifiPort;
  String get wifiSsid => _wifiSsid;
  String get wifiPass => _wifiPass;
  bool get isWifiConnected => _wifiStatus == 'connected' && _wifiIp != null && _wifiIp!.isNotEmpty;

  int _lastKnownBattery = 85;
  int get lastKnownBattery => _lastKnownBattery;

  Future<int> getBatteryLevel() async {
    int rawBat = -1;
    // 1. Try battery_plus plugin
    try {
      final level = await _battery.batteryLevel;
      if (level > 0 && level <= 100) {
        rawBat = level;
      }
    } catch (_) {}
    // 2. Direct native iOS UIKit battery query
    if (rawBat <= 0 && Platform.isIOS) {
      try {
        final res = await _locationChannel.invokeMethod('getBatteryLevel');
        if (res is int && res > 0 && res <= 100) {
          rawBat = res;
        }
      } catch (_) {}
    }
    if (rawBat > 0 && rawBat <= 100) {
      _lastKnownBattery = rawBat;
    }

    return _lastKnownBattery;
  }

  BleService() {
    _loadSavedDeviceConfig();
    _initBle();
    _initNativeChannels();
    _startWifiProbe();
    checkSystemDevices();
  }

  Future<void> _loadSavedDeviceConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedBle = prefs.getString('esp_custom_ble_name');
      final savedSsid = prefs.getString('esp_wifi_ssid');
      final savedPass = prefs.getString('esp_wifi_pass');
      final savedId = prefs.getString('esp_last_ble_id');
      if (savedBle != null && savedBle.trim().isNotEmpty) {
        _customBleName = savedBle.trim();
      }
      if (savedSsid != null && savedSsid.trim().isNotEmpty) {
        _wifiSsid = savedSsid.trim();
      }
      if (savedPass != null && savedPass.length >= 8) {
        _wifiPass = savedPass;
      }
      if (savedId != null && savedId.isNotEmpty) {
        _lastConnectedDeviceId = savedId;
      }
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _saveDeviceConfigPrefs({String? bleName, String? ssid, String? pass, String? lastId}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (bleName != null && bleName.trim().isNotEmpty) {
        await prefs.setString('esp_custom_ble_name', bleName.trim());
      }
      if (ssid != null && ssid.trim().isNotEmpty) {
        await prefs.setString('esp_wifi_ssid', ssid.trim());
      }
      if (pass != null && pass.length >= 8) {
        await prefs.setString('esp_wifi_pass', pass);
      }
      if (lastId != null && lastId.isNotEmpty) {
        await prefs.setString('esp_last_ble_id', lastId);
      }
    } catch (_) {}
  }

  void _initNativeChannels() {
    _locationChannel.setMethodCallHandler((call) async {
      if (call.method == 'onBatteryChanged') {
        final bat = call.arguments as int? ?? 0;
        if (bat > 0 && bat <= 100) {
          _lastKnownBattery = bat;
          notifyListeners();
        }
      }
    });
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
    if (_wifiStatus == 'connected') {
      _wifiStatus = 'disconnected';
      _wifiIp = null;
      _addLog('WiFi: Đã ngắt kết nối với ESP32', isTx: false);
      notifyListeners();
    }
  }

  /// Mark WebSocket stream active with ESP32 (SoftAP 192.168.4.1 or Hotspot 172.20.10.1)
  void setHotspotConnected(String ip, int port) {
    _wifiStatus = 'connected';
    _wifiIp = ip;
    _wifiPort = port;
    if (ip.startsWith('192.168.4')) {
      _addLog('WiFi SoftAP: iPhone đã kết nối với ESP32 ($ip:$port)', isTx: false);
    } else {
      _addLog('Hotspot WebSocket: ESP32 đã kết nối vào iPhone ($ip:$port)', isTx: false);
    }
    notifyListeners();
  }

  /// Mark Hotspot WebSocket disconnected
  void setHotspotDisconnected() {
    setWifiDisconnected();
  }

  /// Send Wi-Fi credentials to ESP32 over BLE so it connects to iPhone Personal Hotspot
  Future<bool> sendWifiCredentials(String ssid, String pass) => sendWifiConfig(ssid, pass);

  /// Automatically probe ESP32 SoftAP TCP port on 192.168.4.1:8080 (fallback only)
  Future<void> probeEsp32Wifi() async {
    // Disabled: the ESP32 SoftAP link (192.168.4.1:8080) is now a WebSocket managed by
    // EspStreamService. A raw TCP probe would only create a bogus 'connected' state.
    return;
  }


  void _initBle() {
    try {
      _adapterStateSubscription = FlutterBluePlus.adapterState.listen((state) {
        _addLog('Bluetooth Adapter State: $state', isTx: false);
        if (state == BluetoothAdapterState.on) {
          Future.delayed(const Duration(milliseconds: 500), checkSystemDevices);
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

  /// Retrieve devices already connected to iOS system (bonded / paired).
  /// Queries custom service FFE0, AMS, ANCS, 1800, and centralManager.connectedDevices.
  Future<List<BluetoothDevice>> checkSystemDevices() async {
    final List<BluetoothDevice> matched = [];
    try {
      final isSupported = await FlutterBluePlus.isSupported;
      if (!isSupported) return matched;

      final filterUuids = [
        navServiceUuid,
        Guid('FFE0'),
        Guid('1800'),
      ];
      final sysDevices = await FlutterBluePlus.systemDevices(filterUuids);
      final connectedDevs = FlutterBluePlus.connectedDevices;

      final allKnown = <String, BluetoothDevice>{};
      for (final d in [...sysDevices, ...connectedDevs]) {
        allKnown[d.remoteId.str] = d;
      }

      final customLower = _customBleName.trim().toLowerCase();
      for (final d in allKnown.values) {
        final pName = d.platformName;
        final lower = pName.toLowerCase();
        final isEsp = lower.contains('ysiducnaga') ||
            lower.contains('ysiduc') ||
            lower.contains('esp32') ||
            lower.contains('nav') ||
            (customLower.isNotEmpty && lower.contains(customLower)) ||
            (_lastConnectedDeviceId != null && d.remoteId.str == _lastConnectedDeviceId) ||
            pName.isEmpty; // iOS sometimes hides name until connected

        if (isEsp) {
          final name = pName.isNotEmpty ? pName : _customBleName;
          _systemBondedDevice = d;
          matched.add(d);

          final index = _discoveredDevices.indexWhere((item) => item.device.remoteId == d.remoteId);
          if (index >= 0) {
            _discoveredDevices[index] = BleDeviceItem(device: d, name: name, rssi: -30);
          } else {
            _discoveredDevices.insert(0, BleDeviceItem(device: d, name: name, rssi: -30));
          }
        }
      }
      if (matched.isNotEmpty) {
        _addLog('Phát hiện ${matched.length} thiết bị ESP32 đã ghép nối iOS Bluetooth', isTx: false);
      }
      notifyListeners();
    } catch (e) {
      debugPrint('[BLE] checkSystemDevices error: $e');
    }
    return matched;
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

      // 1. Immediately retrieve devices connected at iOS system level
      await checkSystemDevices();

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

  /// Kết nối nhanh 1 chạm tới thiết bị ysiducnaga (hoặc ESP32 đã ghép nối)
  Future<bool> quickConnectToYsiducnaga() async {
    if (_isConnected) return true;
    if (_isConnecting) return false;

    // 1. Ưu tiên kiểm tra thiết bị đã ghép nối sẵn trong hệ thống Bluetooth iOS
    final customLower = _customBleName.trim().toLowerCase();
    final sysList = await checkSystemDevices();
    if (sysList.isNotEmpty) {
      final preferred = sysList.firstWhere(
        (d) => (_lastConnectedDeviceId != null && d.remoteId.str == _lastConnectedDeviceId) ||
               d.platformName.toLowerCase().contains('ysiducnaga') ||
               d.platformName.toLowerCase().contains('ysiduc') ||
               (customLower.isNotEmpty && d.platformName.toLowerCase().contains(customLower)),
        orElse: () => sysList.first,
      );
      final name = preferred.platformName.isNotEmpty ? preferred.platformName : _customBleName;
      final ok = await connectToDevice(preferred, displayName: name);
      if (ok) return true;
    }

    // 2. Nếu chưa ghép nối sẵn, quét nhanh tối đa 5 giây và tự động kết nối ngay khi thấy thiết bị ESP32
    try {
      final isSupported = await FlutterBluePlus.isSupported;
      if (!isSupported) return false;

      _isScanning = true;
      notifyListeners();

      final completer = Completer<BluetoothDevice?>();
      String? foundName;

      _scanSubscription?.cancel();
      _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        for (final r in results) {
          final advName = r.advertisementData.advName;
          final platName = r.device.platformName;
          final name = advName.isNotEmpty ? advName : platName;
          final lower = name.toLowerCase();
          final hasNavUuid = r.advertisementData.serviceUuids.any(
            (u) => u.str.toUpperCase().contains('FFE0'),
          );

          if (name.isNotEmpty) {
            final index = _discoveredDevices.indexWhere((item) => item.device.remoteId == r.device.remoteId);
            if (index >= 0) {
              _discoveredDevices[index] = BleDeviceItem(device: r.device, name: name, rssi: r.rssi);
            } else {
              _discoveredDevices.add(BleDeviceItem(device: r.device, name: name, rssi: r.rssi));
            }
          }

          if ((_lastConnectedDeviceId != null && r.device.remoteId.str == _lastConnectedDeviceId) ||
              lower.contains('ysiducnaga') ||
              lower.contains('ysiduc') ||
              lower.contains('esp32') ||
              (customLower.isNotEmpty && lower.contains(customLower)) ||
              hasNavUuid) {
            if (!completer.isCompleted) {
              foundName = name.isNotEmpty ? name : _customBleName;
              completer.complete(r.device);
            }
          }
        }
        notifyListeners();
      });

      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));
      if (!completer.isCompleted) {
        completer.complete(null);
      }

      final targetDevice = await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => null,
      );
      await stopScan();

      if (targetDevice != null) {
        return await connectToDevice(targetDevice, displayName: foundName ?? _customBleName);
      }
    } catch (e) {
      _isScanning = false;
      notifyListeners();
    }
    return false;
  }

  /// Connect to ESP32 BLE device
  Future<bool> connectToDevice(BluetoothDevice device, {String? displayName}) async {
    if (_isConnecting) return false;

    _isConnecting = true;
    _connectedDeviceName = displayName ?? (device.platformName.isNotEmpty ? device.platformName : 'ysiducnaga');
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
      _isConnecting = false;

      // Request maximum MTU (512) for high-speed BLE JPEG stream
      try {
        await device.requestMtu(512);
      } catch (_) {}

      // Discover GATT Services
      await _discoverServices(device);

      if (_writeCharacteristic != null) {
        _isConnected = true;
        _lastConnectedDeviceId = device.remoteId.str;
        _saveDeviceConfigPrefs(lastId: _lastConnectedDeviceId);
        _enableBackgroundKeepAlive();
        _addLog('Đã kết nối thành công với: $_connectedDeviceName!', isTx: false);

        // Send handshake to tell ESP32 to switch from Standby screen to Navigation screen
        try {
          final now = DateTime.now();
          final timeStr = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
          final bat = await getBatteryLevel();
          final handshake = jsonEncode({
            'type': 'APP_CONNECT',
            'clock': timeStr,
            'bat': bat,
          });
          await sendRawJson(handshake);
          _addLog('Đã gửi gói tin kích hoạt Navigation sang ESP32 (Pin: $bat%)', isTx: true);
          await Future.delayed(const Duration(milliseconds: 120));
          await requestDeviceConfig();
        } catch (e) {
          _addLog('Lỗi gửi APP_CONNECT: $e', isError: true);
        }
      } else {
        _isConnected = false;
        _addLog('Không tìm thấy Characteristic ghi dữ liệu!', isError: true);
      }

      // Listen for disconnections & auto-reconnect if app was suspended/idle
      _connectionSubscription?.cancel();
      _connectionSubscription = device.connectionState.listen((state) async {
        if (state == BluetoothConnectionState.disconnected) {
          _addLog('Tạm ngắt kết nối Bluetooth, đang tự động kết nối lại...', isTx: false);
          _isConnected = false;
          _writeCharacteristic = null;
          notifyListeners();
          try {
            await Future.delayed(const Duration(milliseconds: 1500));
            if (!_isConnected && _connectedDevice != null) {
              await _connectedDevice!.connect(
                license: License.nonprofit,
                timeout: const Duration(seconds: 15),
                autoConnect: false,
              );
              try {
                await _connectedDevice!.connectionState
                    .firstWhere((s) => s == BluetoothConnectionState.connected)
                    .timeout(const Duration(seconds: 5));
              } catch (_) {}

              await _discoverServices(_connectedDevice!);
              if (_writeCharacteristic != null) {
                _isConnected = true;
                _enableBackgroundKeepAlive();
                notifyListeners();
                _addLog('Đã tự động kết nối lại thành công!', isTx: false);
                try {
                  final now = DateTime.now();
                  final clockStr = "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";
                  final bat = await getBatteryLevel();
                  final handshake = jsonEncode({
                    'type': 'APP_CONNECT',
                    'clock': clockStr,
                    'bat': bat,
                  });
                  await sendRawJson(handshake);
                  _addLog('Đã gửi lại APP_CONNECT sau auto-reconnect (Pin: $bat%)', isTx: true);
                } catch (_) {}
              } else {
                _handleDisconnect();
              }
            }
          } catch (_) {
            _handleDisconnect();
          }
        }
      });

      _startHeartbeat();
      notifyListeners();
      return _isConnected;
    } catch (e) {
      _isConnecting = false;
      _handleDisconnect();
      _addLog('Kết nối thất bại: $e', isError: true);
      notifyListeners();
      return false;
    }
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
    if (Platform.isIOS) {
      try {
        _locationChannel.invokeMethod('stopBackgroundNavigation');
      } catch (_) {}
    }
  }

  /// Start periodic heartbeat to prevent BLE sleep/timeout on iOS
  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _lastTxTime = DateTime.now();
    _heartbeatTimer = Timer.periodic(const Duration(milliseconds: 2500), (_) {
      if (!_isConnected || _writeCharacteristic == null) return;
      final diff = DateTime.now().difference(_lastTxTime).inMilliseconds;
      if (diff >= 3500) {
        final now = DateTime.now();
        final h = now.hour.toString().padLeft(2, '0');
        final m = now.minute.toString().padLeft(2, '0');
        getBatteryLevel().then((bat) {
          if (_isConnected && _writeCharacteristic != null) {
            sendRawString('{"type":"PING","clock":"$h:$m","bat":$bat}');
          }
        });
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
        final uStr = _writeCharacteristic!.uuid.str;
        final displayUuid = uStr.length > 8 ? uStr.substring(0, 8) : uStr;
        _addLog('Đã tìm thấy cổng GATT RX ($displayUuid...)', isTx: false);
        
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

  DateTime _lastNavPayloadTime = DateTime.now().subtract(const Duration(seconds: 1));
  bool? _lastSentIsNavigating;

  /// Send Navigation Payload to ESP32 (ALWAYS via BLE per architecture)
  Future<bool> sendNavPayload(EspNavPayload payload) async {
    final jsonStr = payload.toJsonString();

    if (!_isConnected || _writeCharacteristic == null) {
      return false;
    }

    final now = DateTime.now();
    if (_lastSentIsNavigating == payload.isNavigating &&
        now.difference(_lastNavPayloadTime).inMilliseconds < 80) {
      return false; // Skip burst write collision for same state
    }
    _lastNavPayloadTime = now;
    _lastSentIsNavigating = payload.isNavigating;

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

  /// Send raw JSON string helper
  Future<bool> sendRawJson(String json) => sendRawString(json);

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
    try {
      final handshake = jsonEncode({'type': 'APP_DISCONNECT'});
      await sendRawJson(handshake);
    } catch (_) {}
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
    _disableBackgroundKeepAlive();
    _addLog('Đã ngắt kết nối BLE', isTx: false);
    notifyListeners();
  }

  /// Handle incoming BLE Notification from ESP32
  void _handleIncomingBleMessage(String msg) {
    try {
      final json = jsonDecode(msg) as Map<String, dynamic>;
      final type = json['type'] as String? ?? '';
      if (type == 'WIFI_STATUS') {
        _wifiStatus = json['status'] as String? ?? 'disconnected';
        _wifiIp = json['ip'] as String?;
        _wifiPort = (json['port'] as num?)?.toInt() ?? 8081;
        _addLog('ESP32 WiFi: $_wifiStatus (IP: $_wifiIp:$_wifiPort)', isTx: false);
        notifyListeners();
      } else if (type == 'DEVICE_CONFIG' || type == 'DEVICE_CONFIG_ACK') {
        final bleName = (json['bleName'] as String?)?.trim();
        final ssid = (json['ssid'] as String?)?.trim();
        final pass = json['pass'] as String?;
        if (bleName != null && bleName.isNotEmpty) {
          _customBleName = bleName;
        }
        if (ssid != null && ssid.isNotEmpty) {
          _wifiSsid = ssid;
        }
        if (pass != null && pass.length >= 8) {
          _wifiPass = pass;
        }
        _saveDeviceConfigPrefs(bleName: bleName, ssid: ssid, pass: pass);
        _addLog('Đồng bộ cấu hình ESP32: BT="$_customBleName", WiFi="$_wifiSsid"', isTx: false);
        notifyListeners();
      }
    } catch (_) {}
  }

  /// Query current BLE name and Wi-Fi SoftAP credentials from ESP32 NVS
  Future<bool> requestDeviceConfig() async {
    if (!_isConnected || _writeCharacteristic == null) return false;
    return await sendRawString(jsonEncode({'type': 'DEVICE_QUERY'}));
  }

  /// Update ESP32 Bluetooth device name and/or SoftAP Wi-Fi SSID & password.
  /// Persists locally even before ESP32 applies & reboots if BLE name changed.
  Future<bool> sendDeviceConfig({
    String? bleName,
    String? ssid,
    String? pass,
  }) async {
    final cleanBle = bleName?.trim();
    final cleanSsid = ssid?.trim();
    final cleanPass = pass?.trim();

    if (cleanBle != null && cleanBle.isNotEmpty) _customBleName = cleanBle;
    if (cleanSsid != null && cleanSsid.isNotEmpty) _wifiSsid = cleanSsid;
    if (cleanPass != null && cleanPass.length >= 8) _wifiPass = cleanPass;
    await _saveDeviceConfigPrefs(bleName: cleanBle, ssid: cleanSsid, pass: cleanPass);
    notifyListeners();

    if (!_isConnected || _writeCharacteristic == null) {
      _addLog('Chưa kết nối BLE với ESP32 (đã lưu cấu hình cục bộ)', isError: true);
      return false;
    }

    final payloadMap = <String, dynamic>{'type': 'DEVICE_CONFIG'};
    if (cleanBle != null && cleanBle.isNotEmpty) payloadMap['bleName'] = cleanBle;
    if (cleanSsid != null && cleanSsid.isNotEmpty) payloadMap['ssid'] = cleanSsid;
    if (cleanPass != null && cleanPass.length >= 8) payloadMap['pass'] = cleanPass;

    final payload = jsonEncode(payloadMap);
    _addLog('Gửi cấu hình ESP32 (BT: ${cleanBle ?? '-'}, WiFi: ${cleanSsid ?? '-'})', isTx: true);
    return await sendRawString(payload);
  }

  /// Send Wi-Fi SSID & Password to ESP32 over BLE
  Future<bool> sendWifiConfig(String ssid, String pass) async {
    return sendDeviceConfig(ssid: ssid, pass: pass);
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
