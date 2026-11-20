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
  final Set<String> _espMatchedIds = {};
  final List<BleLogItem> _logs = [];
  final Battery _battery = Battery();

  StreamSubscription? _scanSubscription;
  StreamSubscription? _adapterStateSubscription;
  StreamSubscription? _connectionSubscription;
  Timer? _heartbeatTimer;
  Timer? _wifiProbeTimer;
  DateTime _lastTxTime = DateTime.now();
  bool _scanStopRequested = false;
  String? _lastScanError;
  bool _needsBlePermission = false;
  bool _needsLocationServiceForBle = false;

  // ESP32 WiFi SoftAP & Bluetooth Configuration State (Default: ysiducnaga / 192.168.4.1:8081)
  String _wifiStatus = 'disconnected'; // 'disconnected', 'connecting', 'connected'
  String? _wifiIp;
  int _wifiPort = 8081;
  String _wifiMode = 'AP'; // 'AP' = ESP32 SoftAP, 'STA' = Phone Personal Hotspot
  String? _espStaIp;
  String? _wifiGatewayIp;
  bool? _espReportedTcpConnected;
  DateTime _lastHotspotRecoveryAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _hotspotRecoveryInFlight = false;
  String _customBleName = 'Hoa hướng dương';
  String _wifiSsid = 'Hoa hướng dương';
  String _wifiPass = '12345678';
  bool _hotspotModeEnabled = false;
  String _hotspotSsid = '';
  String _hotspotPass = '';
  bool _pendingConfigPushOnConnect = false;
  String? _lastConnectedDeviceId;
  int _brightnessPct = 100;
  String? _espFirmwareVersion;
  bool _espSupportsOta = false;

  // Getters
  bool get isScanning => _isScanning;
  bool get isConnected => _isConnected;
  bool get isConnecting => _isConnecting;
  String? get connectedDeviceName => _connectedDeviceName;
  String get customBleName => _customBleName;
  int get brightnessPct => _brightnessPct;
  String? get espFirmwareVersion => _espFirmwareVersion;
  bool get espSupportsOta => _espSupportsOta;
  String? get lastScanError => _lastScanError;
  bool get needsBlePermission => _needsBlePermission;
  bool get needsLocationServiceForBle => _needsLocationServiceForBle;
  BluetoothDevice? get connectedDevice => _connectedDevice;
  BluetoothDevice? get systemBondedDevice => _systemBondedDevice;
  List<BleDeviceItem> get discoveredDevices => List.unmodifiable(_discoveredDevices);
  List<BleLogItem> get logs => List.unmodifiable(_logs);
  String get wifiStatus => _wifiStatus;
  String? get wifiIp => _wifiIp;
  int get wifiPort => _wifiPort;
  String get wifiMode => _wifiMode;
  String? get espStaIp => _espStaIp;
  String? get wifiGatewayIp => _wifiGatewayIp;
  bool? get espReportedTcpConnected => _espReportedTcpConnected;
  bool get isHotspotRecoveryInFlight => _hotspotRecoveryInFlight;
  String get wifiSsid => _wifiSsid;
  String get wifiPass => _wifiPass;
  bool get hotspotModeEnabled => _hotspotModeEnabled;
  String get hotspotSsid => _hotspotSsid;
  String get hotspotPass => _hotspotPass;
  bool get espStaConnectedToHotspot =>
      _wifiMode == 'STA' && _espStaIp != null && _espStaIp!.isNotEmpty;
  bool get isWifiConnected => _wifiStatus == 'connected' && _wifiIp != null && _wifiIp!.isNotEmpty;

  static Completer<Map<String, dynamic>>? _androidPermLock;
  static bool _initialPermissionsPrompted = false;

  /// Reads current Android runtime permission & radio/location service status without prompting.
  static Future<Map<String, dynamic>> getAndroidPermissionStatus() async {
    if (!Platform.isAndroid) {
      return const {
        'locationGranted': true,
        'fineLocationGranted': true,
        'bleGranted': true,
        'locationServiceEnabled': true,
        'bluetoothEnabled': true,
        'sdkInt': 0,
      };
    }
    try {
      final raw = await _locationChannel.invokeMethod('getAndroidPermissionStatus');
      if (raw is Map) {
        return raw.map((k, v) => MapEntry(k.toString(), v));
      }
    } catch (_) {}
    return const {};
  }

  /// Serializes Android runtime permission requests across BleService and NavigationManager
  /// so overlapping ActivityCompat.requestPermissions dialogs never cancel each other.
  static Future<Map<String, dynamic>> ensureAndroidPermissions({
    String mode = 'all',
    bool initialStartupOnlyOnce = false,
  }) async {
    if (!Platform.isAndroid) {
      return const {
        'locationGranted': true,
        'fineLocationGranted': true,
        'bleGranted': true,
        'locationServiceEnabled': true,
        'bluetoothEnabled': true,
        'sdkInt': 0,
      };
    }
    while (_androidPermLock != null) {
      await _androidPermLock!.future;
    }
    final completer = Completer<Map<String, dynamic>>();
    _androidPermLock = completer;
    try {
      var effectiveMode = mode;
      if (initialStartupOnlyOnce) {
        if (_initialPermissionsPrompted) {
          effectiveMode = 'location';
        } else {
          _initialPermissionsPrompted = true;
          try {
            final prefs = await SharedPreferences.getInstance();
            final alreadyAsked = prefs.getBool('android_initial_perms_requested_v1') ?? false;
            if (alreadyAsked) {
              effectiveMode = 'location';
            } else {
              await prefs.setBool('android_initial_perms_requested_v1', true);
              effectiveMode = 'all';
            }
          } catch (_) {}
        }
      }
      final raw = await _locationChannel
          .invokeMethod('requestAndroidPermissions', {'mode': effectiveMode})
          .timeout(const Duration(seconds: 30), onTimeout: () => null);
      final map = raw is Map
          ? raw.map((k, v) => MapEntry(k.toString(), v))
          : await getAndroidPermissionStatus();
      if (!completer.isCompleted) completer.complete(map);
      return map;
    } catch (_) {
      final fallback = await getAndroidPermissionStatus();
      if (!completer.isCompleted) completer.complete(fallback);
      return fallback;
    } finally {
      _androidPermLock = null;
    }
  }

  static Future<void> openAndroidLocationSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _locationChannel.invokeMethod('openLocationSettings');
    } catch (_) {}
  }

  static Future<void> openAndroidAppSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _locationChannel.invokeMethod('openAppSettings');
    } catch (_) {}
  }

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
    // 2. Direct native iOS / Android battery query
    if (rawBat <= 0 && (Platform.isIOS || Platform.isAndroid)) {
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
    if (!Platform.isAndroid) {
      checkSystemDevices();
    } else {
      Future.microtask(() async {
        final st = await getAndroidPermissionStatus();
        if (st['bleGranted'] == true) {
          await checkSystemDevices();
        }
      });
    }
  }

  Future<void> _loadSavedDeviceConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedBle = prefs.getString('esp_custom_ble_name');
      final savedSsid = prefs.getString('esp_wifi_ssid');
      final savedPass = prefs.getString('esp_wifi_pass');
      final savedHotspotMode = prefs.getBool('esp_hotspot_mode');
      final savedHotspotSsid = prefs.getString('esp_hotspot_ssid');
      final savedHotspotPass = prefs.getString('esp_hotspot_pass');
      final savedPendingSync = prefs.getBool('esp_pending_cfg_sync');
      final savedId = prefs.getString('esp_last_ble_id');
      final savedBrightness = prefs.getInt('esp_brightness_pct');
      if (savedBle != null && savedBle.trim().isNotEmpty) {
        final v = savedBle.trim();
        _customBleName = v == 'ysiducnaga' ? 'Hoa hướng dương' : v;
      }
      if (savedSsid != null && savedSsid.trim().isNotEmpty) {
        final v = savedSsid.trim();
        _wifiSsid = v == 'ysiducnaga' ? 'Hoa hướng dương' : v;
      }
      if (savedPass != null && savedPass.length >= 8) {
        _wifiPass = savedPass;
      }
      if (savedHotspotMode != null) {
        _hotspotModeEnabled = savedHotspotMode;
        _wifiMode = savedHotspotMode ? 'STA' : 'AP';
      }
      if (savedHotspotSsid != null) {
        _hotspotSsid = savedHotspotSsid.trim();
      }
      if (savedHotspotPass != null) {
        _hotspotPass = savedHotspotPass;
      }
      if (savedPendingSync != null) {
        _pendingConfigPushOnConnect = savedPendingSync;
      }
      if (savedId != null && savedId.isNotEmpty) {
        _lastConnectedDeviceId = savedId;
      }
      if (savedBrightness != null) {
        _brightnessPct = savedBrightness.clamp(5, 100);
      }
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _saveDeviceConfigPrefs({
    String? bleName,
    String? ssid,
    String? pass,
    String? lastId,
    bool? hotspotMode,
    String? hotspotSsid,
    String? hotspotPass,
    bool? pendingCfgSync,
  }) async {
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
      if (hotspotMode != null) {
        await prefs.setBool('esp_hotspot_mode', hotspotMode);
      }
      if (hotspotSsid != null) {
        await prefs.setString('esp_hotspot_ssid', hotspotSsid.trim());
      }
      if (hotspotPass != null) {
        await prefs.setString('esp_hotspot_pass', hotspotPass);
      }
      if (pendingCfgSync != null) {
        await prefs.setBool('esp_pending_cfg_sync', pendingCfgSync);
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
      _addLog('WiFi SoftAP: Điện thoại đã kết nối với ESP32 ($ip:$port)', isTx: false);
    } else {
      _addLog('Hotspot WebSocket: ESP32 đã kết nối vào điện thoại ($ip:$port)', isTx: false);
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


  Future<void> _initBle() async {
    try {
      final isSupported = await FlutterBluePlus.isSupported;
      if (!isSupported) return;
      _adapterStateSubscription = FlutterBluePlus.adapterState.listen((state) {
        _addLog('Bluetooth Adapter State: $state', isTx: false);
        if (state == BluetoothAdapterState.on) {
          Future.delayed(const Duration(milliseconds: 500), () async {
            if (Platform.isAndroid) {
              final st = await getAndroidPermissionStatus();
              if (st['bleGranted'] != true) return;
            }
            await checkSystemDevices();
          });
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
      List<BluetoothDevice> bondedDevs = const [];
      if (Platform.isAndroid) {
        try {
          bondedDevs = await FlutterBluePlus.bondedDevices;
        } catch (_) {}
      }

      final allKnown = <String, BluetoothDevice>{};
      for (final d in [...sysDevices, ...connectedDevs, ...bondedDevs]) {
        allKnown[d.remoteId.str] = d;
      }

      final customLower = _customBleName.trim().toLowerCase();
      for (final d in allKnown.values) {
        final pName = d.platformName;
        final lower = pName.toLowerCase();
        final isEsp = lower.contains('hoa hướng dương') ||
            lower.contains('hoa huong duong') ||
            lower.contains('ysiducnaga') ||
            lower.contains('ysiduc') ||
            lower.contains('esp32') ||
            lower.contains('nav') ||
            (customLower.isNotEmpty && lower.contains(customLower)) ||
            (_lastConnectedDeviceId != null && d.remoteId.str == _lastConnectedDeviceId) ||
            pName.isEmpty; // iOS sometimes hides name until connected

        if (isEsp) {
          final name = pName.isNotEmpty ? pName : _customBleName;
          _systemBondedDevice = d;
          _espMatchedIds.add(d.remoteId.str);
          matched.add(d);

          final index = _discoveredDevices.indexWhere((item) => item.device.remoteId == d.remoteId);
          if (index >= 0) {
            _discoveredDevices[index] = BleDeviceItem(device: d, name: name, rssi: -30);
          } else {
            _discoveredDevices.insert(0, BleDeviceItem(device: d, name: name, rssi: -30));
          }
        }
      }
      _sortDiscoveredDevices();
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

  @visibleForTesting
  static bool matchesEspDeviceIdentity({
    required String remoteId,
    required String advName,
    required String platformName,
    required List<String> serviceUuids,
    String customBleName = 'Hoa hướng dương',
    String? lastConnectedDeviceId,
  }) {
    final advLower = advName.toLowerCase();
    final platLower = platformName.toLowerCase();
    final customLower = customBleName.trim().toLowerCase();
    final hasNavUuid = serviceUuids.any((u) => u.toUpperCase().contains('FFE0'));
    return (lastConnectedDeviceId != null && remoteId == lastConnectedDeviceId) ||
        advLower.contains('hoa hướng dương') ||
        advLower.contains('hoa huong duong') ||
        advLower.contains('ysiducnaga') ||
        advLower.contains('ysiduc') ||
        advLower.contains('esp32') ||
        platLower.contains('hoa hướng dương') ||
        platLower.contains('hoa huong duong') ||
        platLower.contains('ysiducnaga') ||
        platLower.contains('ysiduc') ||
        platLower.contains('esp32') ||
        (customLower.isNotEmpty && (advLower.contains(customLower) || platLower.contains(customLower))) ||
        hasNavUuid;
  }

  bool _isEspCandidateResult(ScanResult r) {
    return matchesEspDeviceIdentity(
      remoteId: r.device.remoteId.str,
      advName: r.advertisementData.advName,
      platformName: r.device.platformName,
      serviceUuids: r.advertisementData.serviceUuids.map((u) => u.str).toList(),
      customBleName: _customBleName,
      lastConnectedDeviceId: _lastConnectedDeviceId,
    );
  }

  void _sortDiscoveredDevices() {
    _discoveredDevices.sort((a, b) {
      final aMatch = _espMatchedIds.contains(a.device.remoteId.str);
      final bMatch = _espMatchedIds.contains(b.device.remoteId.str);
      if (aMatch != bMatch) return aMatch ? -1 : 1;
      final aNamed = !a.name.startsWith('Thiết bị BLE');
      final bNamed = !b.name.startsWith('Thiết bị BLE');
      if (aNamed != bNamed) return aNamed ? -1 : 1;
      return b.rssi.compareTo(a.rssi);
    });
  }

  Future<bool> _ensureBluetoothReadyForScan() async {
    try {
      final isSupported = await FlutterBluePlus.isSupported;
      if (!isSupported) {
        _lastScanError = 'Thiết bị không hỗ trợ Bluetooth BLE.';
        _addLog(_lastScanError!, isError: true);
        return false;
      }

      if (Platform.isAndroid) {
        final perm = await ensureAndroidPermissions(mode: 'ble');
        if (perm['bleGranted'] != true) {
          _needsBlePermission = true;
          _needsLocationServiceForBle = false;
          _lastScanError = 'Chưa được cấp quyền Bluetooth (Thiết bị ở gần).';
          _addLog(_lastScanError!, isError: true);
          return false;
        }
        _needsBlePermission = false;

        final sdkInt = (perm['sdkInt'] as int?) ?? 0;
        if (sdkInt > 0 && sdkInt < 31 && perm['locationServiceEnabled'] != true) {
          _needsLocationServiceForBle = true;
          _lastScanError = 'Android <= 11 cần bật Vị trí (GPS) để quét thiết bị BLE.';
          _addLog(_lastScanError!, isError: true);
          return false;
        }
        _needsLocationServiceForBle = false;
      }

      if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
        if (Platform.isAndroid) {
          try {
            await FlutterBluePlus.turnOn().timeout(const Duration(seconds: 8));
          } catch (_) {}
        }
        if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
          try {
            await FlutterBluePlus.adapterState
                .firstWhere((s) => s == BluetoothAdapterState.on)
                .timeout(const Duration(seconds: 3));
          } catch (_) {}
        }
      }

      if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
        _lastScanError = 'Bluetooth đang tắt — hãy bật Bluetooth để tìm ESP32.';
        _addLog(_lastScanError!, isError: true);
        return false;
      }

      _lastScanError = null;
      return true;
    } catch (e) {
      _lastScanError = 'Không thể khởi tạo Bluetooth: $e';
      _addLog(_lastScanError!, isError: true);
      return false;
    }
  }

  Future<void> _runBleScanPass(Duration timeout, {required bool androidLegacy}) async {
    await FlutterBluePlus.startScan(
      timeout: timeout,
      androidScanMode: AndroidScanMode.lowLatency,
      androidLegacy: androidLegacy,
      androidCheckLocationServices: false,
    );
    try {
      await FlutterBluePlus.isScanning
          .where((scanning) => !scanning)
          .first
          .timeout(timeout + const Duration(seconds: 2), onTimeout: () => false);
    } catch (_) {}
  }

  /// Start scanning for BLE devices
  Future<void> startScan({int timeoutSeconds = 12}) async {
    if (_isScanning) return;

    try {
      final ready = await _ensureBluetoothReadyForScan();
      if (!ready) {
        notifyListeners();
        return;
      }

      _scanStopRequested = false;
      _discoveredDevices.clear();
      _espMatchedIds.clear();
      _isScanning = true;
      notifyListeners();

      // 1. Immediately retrieve devices already connected/bonded at system level
      await checkSystemDevices();

      _scanSubscription?.cancel();
      _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        for (final r in results) {
          final idStr = r.device.remoteId.str;
          final shortId = idStr.length >= 5 ? idStr.substring(0, 5) : idStr;
          final hasNavUuid = r.advertisementData.serviceUuids.any(
            (u) => u.str.toUpperCase().contains('FFE0'),
          );
          final name = r.advertisementData.advName.isNotEmpty
              ? r.advertisementData.advName
              : (r.device.platformName.isNotEmpty
                  ? r.device.platformName
                  : (hasNavUuid ? 'Hoa hướng dương ($shortId)' : 'Thiết bị BLE ($shortId)'));

          if (_isEspCandidateResult(r)) {
            _espMatchedIds.add(idStr);
          }

          final index = _discoveredDevices.indexWhere((item) => item.device.remoteId == r.device.remoteId);
          if (index >= 0) {
            _discoveredDevices[index] = BleDeviceItem(device: r.device, name: name, rssi: r.rssi);
          } else {
            _discoveredDevices.add(BleDeviceItem(device: r.device, name: name, rssi: r.rssi));
          }
        }
        _sortDiscoveredDevices();
        notifyListeners();
      });

      if (Platform.isAndroid) {
        final pass1Sec = (timeoutSeconds * 0.6).round().clamp(4, 8);
        await _runBleScanPass(Duration(seconds: pass1Sec), androidLegacy: true);
        if (!_scanStopRequested && _espMatchedIds.isEmpty) {
          final pass2Sec = (timeoutSeconds - pass1Sec).clamp(3, 6);
          await _runBleScanPass(Duration(seconds: pass2Sec), androidLegacy: false);
        }
      } else {
        await _runBleScanPass(Duration(seconds: timeoutSeconds), androidLegacy: false);
      }

      if (Platform.isAndroid && _discoveredDevices.isEmpty) {
        final st = await getAndroidPermissionStatus();
        if (st['locationServiceEnabled'] != true) {
          _needsLocationServiceForBle = true;
          _lastScanError = 'Chưa thấy thiết bị BLE — hãy thử bật Vị trí (GPS) trên điện thoại.';
        }
      }

      _isScanning = false;
      notifyListeners();
    } catch (e) {
      _isScanning = false;
      _lastScanError = 'Lỗi khi quét BLE: $e';
      _addLog(_lastScanError!, isError: true);
      notifyListeners();
    }
  }

  /// Stop scanning
  Future<void> stopScan() async {
    _scanStopRequested = true;
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    _isScanning = false;
    notifyListeners();
  }

  /// Kết nối nhanh 1 chạm tới thiết bị Hoa hướng dương (hoặc ESP32 đã ghép nối)
  Future<bool> quickConnectToYsiducnaga() async {
    if (_isConnected) return true;
    if (_isConnecting) return false;

    final ready = await _ensureBluetoothReadyForScan();
    if (!ready) {
      notifyListeners();
      return false;
    }

    // 1. Ưu tiên kiểm tra thiết bị đã ghép nối sẵn trong hệ thống Bluetooth
    final customLower = _customBleName.trim().toLowerCase();
    final sysList = await checkSystemDevices();
    if (sysList.isNotEmpty) {
      final preferred = sysList.firstWhere(
        (d) => (_lastConnectedDeviceId != null && d.remoteId.str == _lastConnectedDeviceId) ||
               d.platformName.toLowerCase().contains('hoa hướng dương') ||
               d.platformName.toLowerCase().contains('hoa huong duong') ||
               d.platformName.toLowerCase().contains('ysiducnaga') ||
               d.platformName.toLowerCase().contains('ysiduc') ||
               (customLower.isNotEmpty && d.platformName.toLowerCase().contains(customLower)),
        orElse: () => sysList.first,
      );
      final name = preferred.platformName.isNotEmpty ? preferred.platformName : _customBleName;
      final ok = await connectToDevice(preferred, displayName: name);
      if (ok) return true;
    }

    // 2. Nếu chưa ghép nối sẵn, quét thực sự tới khi thấy ESP32 (tối đa 6s) rồi tự động kết nối
    try {
      _scanStopRequested = false;
      _isScanning = true;
      notifyListeners();

      final completer = Completer<BluetoothDevice?>();
      String? foundName;

      _scanSubscription?.cancel();
      _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        for (final r in results) {
          final idStr = r.device.remoteId.str;
          final advName = r.advertisementData.advName;
          final platName = r.device.platformName;
          final hasNavUuid = r.advertisementData.serviceUuids.any(
            (u) => u.str.toUpperCase().contains('FFE0'),
          );
          final name = advName.isNotEmpty
              ? advName
              : (platName.isNotEmpty ? platName : (hasNavUuid ? _customBleName : ''));

          final isMatch = _isEspCandidateResult(r);
          if (isMatch) {
            _espMatchedIds.add(idStr);
          }

          if (name.isNotEmpty) {
            final index = _discoveredDevices.indexWhere((item) => item.device.remoteId == r.device.remoteId);
            if (index >= 0) {
              _discoveredDevices[index] = BleDeviceItem(device: r.device, name: name, rssi: r.rssi);
            } else {
              _discoveredDevices.add(BleDeviceItem(device: r.device, name: name, rssi: r.rssi));
            }
          }

          if (isMatch && !completer.isCompleted) {
            foundName = name.isNotEmpty ? name : _customBleName;
            completer.complete(r.device);
          }
        }
        _sortDiscoveredDevices();
        notifyListeners();
      });

      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 6),
        androidScanMode: AndroidScanMode.lowLatency,
        androidLegacy: true,
        androidCheckLocationServices: false,
      );

      StreamSubscription<bool>? scanStateSub;
      scanStateSub = FlutterBluePlus.isScanning.listen((scanning) {
        if (!scanning && !completer.isCompleted) {
          completer.complete(null);
        }
      });

      final targetDevice = await completer.future.timeout(
        const Duration(seconds: 6),
        onTimeout: () => null,
      );
      await scanStateSub.cancel();
      await stopScan();

      if (targetDevice != null) {
        return await connectToDevice(targetDevice, displayName: foundName ?? _customBleName);
      }
    } catch (e) {
      _isScanning = false;
      _lastScanError = 'Lỗi quét nhanh BLE: $e';
      _addLog(_lastScanError!, isError: true);
      notifyListeners();
    }
    return false;
  }

  /// Connect to ESP32 BLE device
  Future<bool> connectToDevice(BluetoothDevice device, {String? displayName}) async {
    if (_isConnecting) return false;

    _isConnecting = true;
    _connectedDeviceName = displayName ?? (device.platformName.isNotEmpty ? device.platformName : 'Hoa hướng dương');
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

      // Request maximum MTU (512/517) and high connection priority on Android for high-speed BLE
      try {
        await device.requestMtu(Platform.isAndroid ? 517 : 512);
      } catch (_) {}
      if (Platform.isAndroid) {
        try {
          await device.requestConnectionPriority(
            connectionPriorityRequest: ConnectionPriority.high,
          );
        } catch (_) {}
      }

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
            'brightness': _brightnessPct,
          });
          await sendRawJson(handshake);
          _addLog('Đã gửi gói tin kích hoạt Navigation sang ESP32 (Pin: $bat%)', isTx: true);
          await Future.delayed(const Duration(milliseconds: 120));
          if (_pendingConfigPushOnConnect) {
            await sendDeviceConfig(
              bleName: _customBleName,
              ssid: _wifiSsid,
              pass: _wifiPass,
              hotspotMode: _hotspotModeEnabled,
              hotspotSsid: _hotspotSsid,
              hotspotPass: _hotspotPass,
            );
          } else {
            await requestDeviceConfig();
          }
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
                    'brightness': _brightnessPct,
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
    if (Platform.isIOS || Platform.isAndroid) {
      try {
        _locationChannel.invokeMethod('startBackgroundNavigation', {'source': 'ble'});
      } catch (_) {}
    }
  }

  void _disableBackgroundKeepAlive() {
    if (Platform.isIOS || Platform.isAndroid) {
      try {
        _locationChannel.invokeMethod('stopBackgroundNavigation', {'source': 'ble'});
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
      await Future.delayed(const Duration(milliseconds: 80));
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
    _espStaIp = null;
    _wifiGatewayIp = null;
    _disableBackgroundKeepAlive();
    _addLog('Đã ngắt kết nối BLE', isTx: false);
    notifyListeners();
  }

  /// Handle incoming BLE Notification from ESP32
  @visibleForTesting
  void handleIncomingBleMessageForTest(String msg) => _handleIncomingBleMessage(msg);

  void _handleIncomingBleMessage(String msg) {
    try {
      final json = jsonDecode(msg) as Map<String, dynamic>;
      final type = json['type'] as String? ?? '';
      if (type == 'WIFI_STATUS') {
        final mode = (json['mode'] as String?)?.trim().toUpperCase();
        final status = json['status'] as String? ?? 'disconnected';
        final ip = (json['ip'] as String?)?.trim();
        final gw = (json['gw'] as String?)?.trim();
        final port = (json['port'] as num?)?.toInt() ?? 8081;
        if (mode == 'STA') {
          _wifiMode = 'STA';
          if (gw != null && gw.isNotEmpty) _wifiGatewayIp = gw;
          if (status == 'connected' && ip != null && ip.isNotEmpty) {
            _espStaIp = ip;
            _wifiPort = port;
          } else {
            _espStaIp = null;
          }
          _addLog('ESP32 Hotspot STA: $status (ESP IP: ${_espStaIp ?? "-"}, GW: ${_wifiGatewayIp ?? "-"})', isTx: false);
        } else {
          _wifiMode = 'AP';
          _espStaIp = null;
          _wifiGatewayIp = null;
          _addLog('ESP32 SoftAP WiFi: $status (${ip ?? "192.168.4.1"}:$port)', isTx: false);
        }
        notifyListeners();
      } else if (type == 'DEVICE_CONFIG' || type == 'DEVICE_CONFIG_ACK') {
        final bleName = ((json['bleName'] ?? json['ble_name']) as String?)?.trim();
        final ssid = (json['ssid'] as String?)?.trim();
        final pass = json['pass'] as String?;
        final mode = (json['mode'] as String?)?.trim().toUpperCase();
        final ip = (json['ip'] as String?)?.trim();
        final rawHotspotMode = json['hotspot_mode'];
        final bool? hsMode = rawHotspotMode is bool
            ? rawHotspotMode
            : (rawHotspotMode is num ? rawHotspotMode != 0 : null);
        final staSsid = (json['sta_ssid'] as String?)?.trim();
        final staPass = json['sta_pass'] as String?;

        if (!_pendingConfigPushOnConnect) {
          if (bleName != null && bleName.isNotEmpty) {
            _customBleName = bleName;
          }
          if (ssid != null && ssid.isNotEmpty) {
            _wifiSsid = ssid;
          }
          if (pass != null && pass.length >= 8) {
            _wifiPass = pass;
          }
          if (hsMode != null) {
            _hotspotModeEnabled = hsMode;
            _wifiMode = hsMode ? 'STA' : 'AP';
          }
          if (staSsid != null) {
            _hotspotSsid = staSsid;
          }
          if (staPass != null) {
            _hotspotPass = staPass;
          }
          _saveDeviceConfigPrefs(
            bleName: bleName,
            ssid: ssid,
            pass: pass,
            hotspotMode: hsMode,
            hotspotSsid: staSsid,
            hotspotPass: staPass,
          );
        }
        final rawTcp = json['tcp'];
        if (rawTcp is bool) {
          _espReportedTcpConnected = rawTcp;
        } else if (rawTcp is num) {
          _espReportedTcpConnected = rawTcp != 0;
        }
        if (mode == 'STA' && ip != null && ip.isNotEmpty) {
          _wifiMode = 'STA';
          _espStaIp = ip;
        } else if (mode == 'AP') {
          _wifiMode = 'AP';
          _espStaIp = null;
        }
        final fwVer = (json['fw_ver'] as String?)?.trim();
        if (fwVer != null && fwVer.isNotEmpty) {
          _espFirmwareVersion = fwVer;
        }
        final rawOta = json['ota'];
        if (rawOta is bool) {
          _espSupportsOta = rawOta;
        } else if (rawOta is num) {
          _espSupportsOta = rawOta != 0;
        }
        _addLog(
          'Đồng bộ cấu hình ESP32: BT="$_customBleName", Mode=$_wifiMode'
          '${_espReportedTcpConnected != null ? ", TCP=${_espReportedTcpConnected! ? 1 : 0}" : ""}'
          '${_espFirmwareVersion != null ? ", FW=v$_espFirmwareVersion" : ""}',
          isTx: false,
        );
        notifyListeners();
      }
    } catch (_) {}
  }

  /// Query current BLE name and Wi-Fi SoftAP / Hotspot credentials from ESP32 NVS
  Future<bool> requestDeviceConfig() async {
    if (!_isConnected || _writeCharacteristic == null) return false;
    return await sendRawString(jsonEncode({'type': 'DEVICE_QUERY'}));
  }

  /// Self-heals a deadlocked half-open TCP socket on ESP32 in Hotspot STA mode when Phone lost
  /// TCP and cannot reach ESP32:8081 due to carrier/Hotspot routing while ESP32 still believes tcp=1.
  Future<bool> recoverHotspotWifiLink() async {
    if (!_isConnected || _writeCharacteristic == null) return false;
    if (_hotspotSsid.trim().isEmpty) return false;
    if (_hotspotRecoveryInFlight) return false;
    final now = DateTime.now();
    if (now.difference(_lastHotspotRecoveryAt).inSeconds < 25) return false;

    _hotspotRecoveryInFlight = true;
    _lastHotspotRecoveryAt = now;
    try {
      _addLog('Làm mới kết nối Hotspot Wi-Fi ESP32 do kẹt socket cũ...', isTx: true);
      await sendRawString(jsonEncode({
        'type': 'SET_HOTSPOT_MODE',
        'hotspot_mode': 0,
      }));
      await Future.delayed(const Duration(milliseconds: 350));
      if (!_isConnected || _writeCharacteristic == null) return false;
      final ok = await sendRawString(jsonEncode({
        'type': 'SET_HOTSPOT_MODE',
        'hotspot_mode': 1,
        'sta_ssid': _hotspotSsid,
        'sta_pass': _hotspotPass,
      }));
      return ok;
    } finally {
      _hotspotRecoveryInFlight = false;
    }
  }

  /// Update ESP32 Bluetooth name, SoftAP Wi-Fi credentials, and Personal Hotspot STA mode/credentials.
  /// Persists locally even before ESP32 applies & reboots if BLE name changed.
  Future<bool> sendDeviceConfig({
    String? bleName,
    String? ssid,
    String? pass,
    bool? hotspotMode,
    String? hotspotSsid,
    String? hotspotPass,
  }) async {
    final cleanBle = bleName?.trim();
    final cleanSsid = ssid?.trim();
    final cleanPass = pass?.trim();
    final cleanStaSsid = hotspotSsid?.trim();
    final cleanStaPass = hotspotPass;

    if (cleanBle != null && cleanBle.isNotEmpty) _customBleName = cleanBle;
    if (cleanSsid != null && cleanSsid.isNotEmpty) _wifiSsid = cleanSsid;
    if (cleanPass != null && cleanPass.length >= 8) _wifiPass = cleanPass;
    if (cleanStaSsid != null) _hotspotSsid = cleanStaSsid;
    if (cleanStaPass != null && (cleanStaPass.isEmpty || cleanStaPass.length >= 8)) {
      _hotspotPass = cleanStaPass;
    }
    if (hotspotMode != null) {
      _hotspotModeEnabled = hotspotMode;
      _wifiMode = hotspotMode ? 'STA' : 'AP';
      if (!hotspotMode) {
        _espStaIp = null;
        _wifiGatewayIp = null;
      }
    }

    final isOffline = !_isConnected || _writeCharacteristic == null;
    _pendingConfigPushOnConnect = isOffline;
    await _saveDeviceConfigPrefs(
      bleName: cleanBle,
      ssid: cleanSsid,
      pass: cleanPass,
      hotspotMode: hotspotMode,
      hotspotSsid: cleanStaSsid,
      hotspotPass: cleanStaPass,
      pendingCfgSync: _pendingConfigPushOnConnect,
    );
    notifyListeners();

    if (isOffline) {
      _addLog('Chưa kết nối BLE với ESP32 (đã lưu cấu hình chờ đồng bộ)', isError: true);
      return false;
    }

    final payloadMap = <String, dynamic>{'type': 'DEVICE_CONFIG'};
    if (cleanBle != null && cleanBle.isNotEmpty) {
      payloadMap['bleName'] = cleanBle;
      payloadMap['ble_name'] = cleanBle;
    }
    if (cleanSsid != null && cleanSsid.isNotEmpty) payloadMap['ssid'] = cleanSsid;
    if (cleanPass != null && cleanPass.length >= 8) payloadMap['pass'] = cleanPass;
    payloadMap['hotspot_mode'] = _hotspotModeEnabled ? 1 : 0;
    payloadMap['sta_ssid'] = _hotspotSsid;
    payloadMap['sta_pass'] = _hotspotPass;

    final payload = jsonEncode(payloadMap);
    _pendingConfigPushOnConnect = false;
    await _saveDeviceConfigPrefs(pendingCfgSync: false);
    _addLog(
      'Gửi cấu hình ESP32 (${_hotspotModeEnabled ? "Hotspot: $_hotspotSsid" : "SoftAP: $_wifiSsid"})',
      isTx: true,
    );
    return await sendRawString(payload);
  }

  /// Toggles whether ESP32 joins Phone Personal Hotspot (true) or hosts SoftAP (false).
  Future<bool> setHotspotMode(bool enabled) {
    return sendDeviceConfig(
      hotspotMode: enabled,
      hotspotSsid: _hotspotSsid,
      hotspotPass: _hotspotPass,
    );
  }

  /// Send Wi-Fi SSID & Password to ESP32 over BLE
  Future<bool> sendWifiConfig(String ssid, String pass) async {
    return sendDeviceConfig(ssid: ssid, pass: pass);
  }

  /// Updates ESP32 LCD backlight brightness (5..100%) and persists in prefs.
  Future<void> setBrightness(int pct, {bool sendToDevice = true}) async {
    final clamped = pct.clamp(5, 100);
    if (_brightnessPct != clamped) {
      _brightnessPct = clamped;
      notifyListeners();
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt('esp_brightness_pct', clamped);
      } catch (_) {}
    }
    if (sendToDevice && _isConnected && _writeCharacteristic != null) {
      await sendRawJson(jsonEncode({'type': 'SET_BRIGHTNESS', 'value': clamped}));
    }
  }

  /// Controls whether ESP32 locks Màn 1 (1), previews Màn 2 (2), or returns to auto (0).
  Future<bool> setPreviewScreenMode(int mode) async {
    if (!_isConnected || _writeCharacteristic == null) return false;
    return await sendRawJson(
      jsonEncode({'type': 'SET_PREVIEW_SCREEN', 'screen': mode.clamp(0, 2)}),
    );
  }

  Future<bool> _uploadSpiffsChunked(int magic2, Uint8List data) async {
    if (!_isConnected || _writeCharacteristic == null || data.isEmpty) {
      return false;
    }
    final payloadMax = (safeChunkSize - 5).clamp(40, 170);
    final totalChunks = (data.length / payloadMax).ceil();
    if (totalChunks > 255) {
      _addLog('File vượt quá giới hạn BLE 255 chunks', isError: true);
      return false;
    }
    final useWithoutResponse = !_writeCharacteristic!.properties.write;
    for (var idx = 0; idx < totalChunks; idx++) {
      final start = idx * payloadMax;
      final end = (start + payloadMax).clamp(0, data.length);
      final chunk = data.sublist(start, end);
      final pkt = Uint8List(5 + chunk.length);
      pkt[0] = 0xAA;
      pkt[1] = magic2;
      pkt[2] = 0x00;
      pkt[3] = totalChunks;
      pkt[4] = idx;
      pkt.setRange(5, pkt.length, chunk);

      await _writeCharacteristic!.write(pkt, withoutResponse: useWithoutResponse);
      _lastTxTime = DateTime.now();
      await Future.delayed(const Duration(milliseconds: 12));
    }
    return true;
  }

  Future<bool> _uploadThemeBundleToEsp32({
    required int bgMagic2,
    required int specMagic2,
    required Uint8List bgJpegBytes,
    required Map<String, dynamic> specJson,
    required Map<String, dynamic> selectCmd,
    required String label,
  }) async {
    if (!_isConnected || _writeCharacteristic == null) return false;
    try {
      if (bgJpegBytes.isNotEmpty) {
        final okBg = await _uploadSpiffsChunked(bgMagic2, bgJpegBytes);
        if (!okBg) return false;
      }
      final specBytes = Uint8List.fromList(utf8.encode(jsonEncode(specJson)));
      final okSpec = await _uploadSpiffsChunked(specMagic2, specBytes);
      if (!okSpec) return false;
      await Future.delayed(const Duration(milliseconds: 40));
      await sendRawJson(jsonEncode(selectCmd));
      _addLog(
        'Đã đồng bộ $label sang ESP32 (${bgJpegBytes.length ~/ 1024} KB)',
        isTx: true,
      );
      return true;
    } catch (e) {
      _addLog('Lỗi gửi $label sang ESP32: $e', isError: true);
      return false;
    }
  }

  Future<bool> _uploadWallpaperAndSelect({
    required int magic2,
    required Uint8List bgJpegBytes,
    required Map<String, dynamic> selectCmd,
    required String logPrefix,
  }) async {
    if (!_isConnected || _writeCharacteristic == null || bgJpegBytes.isEmpty) {
      return false;
    }
    try {
      final ok = await _uploadSpiffsChunked(magic2, bgJpegBytes);
      if (!ok) return false;
      await Future.delayed(const Duration(milliseconds: 40));
      await sendRawJson(jsonEncode(selectCmd));
      _addLog(
        '$logPrefix (${bgJpegBytes.length ~/ 1024} KB)',
        isTx: true,
      );
      return true;
    } catch (e) {
      _addLog('Lỗi gửi $logPrefix: $e', isError: true);
      return false;
    }
  }

  /// Uploads a custom JPEG wallpaper (/bg_wait.jpg) for Màn 1 default Waybar theme (index 0).
  Future<bool> sendDefaultWallpaperToEsp32(Uint8List bgJpegBytes) {
    return _uploadWallpaperAndSelect(
      magic2: 0xBC,
      bgJpegBytes: bgJpegBytes,
      selectCmd: const {'type': 'THEME_SELECT', 'theme': 0},
      logPrefix: 'Đã cập nhật ảnh nền Màn 1',
    );
  }

  /// Uploads a custom JPEG photo (/bg_map.jpg) for Màn 2 default idle slot (when Wi-Fi isn't streaming).
  Future<bool> sendMan2DefaultImageToEsp32(Uint8List mapJpegBytes) {
    return _uploadWallpaperAndSelect(
      magic2: 0xBD,
      bgJpegBytes: mapJpegBytes,
      selectCmd: const {'type': 'SET_MAN2_STYLE', 'theme': 0},
      logPrefix: 'Đã cập nhật ảnh thay map Màn 2',
    );
  }

  /// Uploads a Màn 1 ZIP theme's background image & JSON spec and activates style 250.
  Future<bool> sendCustomThemeToEsp32({
    required Uint8List bgJpegBytes,
    required Map<String, dynamic> specJson,
  }) {
    return _uploadThemeBundleToEsp32(
      bgMagic2: 0xBE,
      specMagic2: 0xBF,
      bgJpegBytes: bgJpegBytes,
      specJson: specJson,
      selectCmd: const {'type': 'THEME_SELECT', 'theme': 250},
      label: 'theme ZIP Màn 1',
    );
  }

  /// Switches ESP32 Màn 2 built-in style (0..3) or custom ZIP style (250).
  Future<bool> sendMan2StyleToEsp32(int style) async {
    if (!_isConnected || _writeCharacteristic == null) return false;
    return sendRawJson(
      jsonEncode({'type': 'SET_MAN2_STYLE', 'theme': style}),
    );
  }

  /// Uploads a Màn 2 ZIP theme's background image & JSON spec and activates style 250.
  Future<bool> sendCustomMan2ThemeToEsp32({
    required Uint8List bgJpegBytes,
    required Map<String, dynamic> specJson,
  }) {
    return _uploadThemeBundleToEsp32(
      bgMagic2: 0xC0,
      specMagic2: 0xC1,
      bgJpegBytes: bgJpegBytes,
      specJson: specJson,
      selectCmd: const {'type': 'SET_MAN2_STYLE', 'theme': 250},
      label: 'theme ZIP Màn 2',
    );
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
