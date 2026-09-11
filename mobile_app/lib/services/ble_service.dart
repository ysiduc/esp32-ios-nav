import 'dart:async';
import 'dart:convert';
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

  // Getters
  bool get isScanning => _isScanning;
  bool get isConnected => _isConnected;
  bool get isConnecting => _isConnecting;
  String? get connectedDeviceName => _connectedDeviceName;
  BluetoothDevice? get connectedDevice => _connectedDevice;
  List<BleDeviceItem> get discoveredDevices => List.unmodifiable(_discoveredDevices);
  List<BleLogItem> get logs => List.unmodifiable(_logs);

  BleService() {
    _initBle();
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

  /// Automatically detect and attach to any BLE device that iOS has already connected
  /// (e.g. via Settings > Bluetooth). If found & already connected, skip device.connect()
  /// and go straight to discoverServices() so the app shows map immediately.
  Future<void> _autoConnectIfSystemConnected() async {
    if (_isConnected || _isConnecting) return;
    try {
      final sysDevices = await FlutterBluePlus.systemDevices([]);
      for (final d in sysDevices) {
        final state = await d.connectionState.first;
        if (state == BluetoothConnectionState.connected) {
          final name = d.platformName.isNotEmpty ? d.platformName : 'ESP32-S3 Navi';
          _addLog('Tự động nhận kết nối iOS: $name', isTx: false);

          _connectedDevice = d;
          _connectedDeviceName = name;
          _isConnected = true;
          notifyListeners();

          // Setup disconnect listener + auto-reconnect
          _connectionSubscription?.cancel();
          _connectionSubscription = d.connectionState.listen((cs) async {
            if (cs == BluetoothConnectionState.disconnected) {
              _addLog('Mất kết nối BLE, đang tự động kết nối lại...', isTx: false);
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
                  _addLog('Đã tự động kết nối lại!', isTx: false);
                }
              } catch (_) {
                _handleDisconnect();
              }
            }
          });

          try { await d.requestMtu(512); } catch (_) {}
          await _discoverServices(d);
          notifyListeners();
          return; // Connected to first found device, stop
        }
      }
    } catch (_) {}
  }

  void _addLog(String msg, {bool isError = false, bool isTx = true}) {
    final item = BleLogItem(message: msg, isError: isError, isTx: isTx);
    _logs.insert(0, item);
    if (_logs.length > 100) _logs.removeLast();
    if (isError) {
      notifyListeners();
    }
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

      // 1. Retrieve ALL devices currently connected at iOS system level (Settings > Bluetooth)
      // IMPORTANT: Pass empty list [] to get ALL connected peripherals regardless of service UUID.
      // Custom service UUIDs (FFE0) are NOT returned by iOS ANCS/AMS filters.
      try {
        final sysDevices = await FlutterBluePlus.systemDevices([]);
        for (final d in sysDevices) {
          final name = d.platformName.isNotEmpty ? d.platformName : 'ESP32-S3 Navi (Đã kết nối)';
          if (!_discoveredDevices.any((item) => item.device.remoteId == d.remoteId)) {
            _discoveredDevices.add(BleDeviceItem(device: d, name: name, rssi: -35));
            _addLog('Phát hiện thiết bị đang kết nối iOS: $name', isTx: false);
          }
          // Auto-connect if not already connected in app
          if (!_isConnected && !_isConnecting) {
            final cs = await d.connectionState.first;
            if (cs == BluetoothConnectionState.connected) {
              _addLog('Tự động kết nối qua iOS Settings: $name', isTx: false);
              _isScanning = false;
              await connectToDevice(d, displayName: name);
              _isScanning = true;
            }
          }
        }
        notifyListeners();
      } catch (_) {}

      // 2. Also retrieve bonded/known devices
      try {
        final bonded = await FlutterBluePlus.bondedDevices;
        for (final d in bonded) {
          final name = d.platformName.isNotEmpty ? d.platformName : 'ESP32-S3 Navi';
          if (!_discoveredDevices.any((item) => item.device.remoteId == d.remoteId)) {
            _discoveredDevices.add(BleDeviceItem(device: d, name: name, rssi: -40));
          }
        }
        notifyListeners();
      } catch (_) {}

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

      // Check if device is already connected at the iOS system level (via Settings > Bluetooth)
      // In that case, skip device.connect() to avoid error/timeout and jump directly to services.
      final currentState = await device.connectionState.first;
      final alreadyConnected = currentState == BluetoothConnectionState.connected;

      if (alreadyConnected) {
        _addLog('Thiết bị đã kết nối qua iOS Settings. Đang khám phá dịch vụ...', isTx: false);
      } else {
        await device.connect(
          license: License.nonprofit,
          timeout: const Duration(seconds: 15),
          autoConnect: false,
        );
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
      } else {
        _addLog('Không tìm thấy Characteristic ghi dữ liệu!', isError: true);
      }
    } catch (e) {
      _addLog('Lỗi dò dịch vụ BLE: $e', isError: true);
    }
  }

  /// Send Navigation Payload to ESP32
  Future<bool> sendNavPayload(EspNavPayload payload) async {
    if (!_isConnected || _writeCharacteristic == null) {
      return false;
    }

    try {
      final jsonStr = payload.toJsonString();
      final bytes = utf8.encode(jsonStr);

      await _writeCharacteristic!.write(
        bytes,
        withoutResponse: _writeCharacteristic!.properties.writeWithoutResponse,
      );

      _addLog('TX [${payload.turnCode}|${payload.distanceToTurn}m]: $jsonStr');
      return true;
    } catch (e) {
      _addLog('Lỗi gửi BLE: $e', isError: true);
      return false;
    }
  }

  /// Send custom raw JSON or string
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
      _addLog('TX RAW: $text');
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
    _isConnected = false;
    _isConnecting = false;
    _connectedDevice = null;
    _writeCharacteristic = null;
    _connectedDeviceName = null;
    _addLog('Đã ngắt kết nối BLE', isTx: false);
    notifyListeners();
  }

  void clearLogs() {
    _logs.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _scanSubscription?.cancel();
    _adapterStateSubscription?.cancel();
    _connectionSubscription?.cancel();
    super.dispose();
  }
}
