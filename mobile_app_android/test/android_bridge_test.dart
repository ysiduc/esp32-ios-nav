import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobile_app/services/ble_service.dart';
import 'package:mobile_app/services/navigation_manager.dart';
import 'package:mobile_app/services/phone_call_service.dart';

class _RecordingBleService extends BleService {
  final List<String> sentPayloads = [];

  @override
  Future<bool> sendRawString(String text) async {
    sentPayloads.add(text);
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Android Native Bridge & ESP32 Protocol Tests', () {
    late _RecordingBleService ble;
    late PhoneCallService callService;

    setUp(() {
      ble = _RecordingBleService();
      callService = PhoneCallService(ble);
    });

    test('Forwards Android incoming call and call ended to ESP32 over BLE JSON', () async {
      const channel = MethodChannel('com.ysiduc.esp32_nav/calls');

      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(
          const MethodCall('onIncomingCall', {
            'caller': 'Anh Tuấn',
            'number': '0987654321',
          }),
        ),
        (_) {},
      );

      expect(callService.isRinging, isTrue);
      expect(callService.callerName, 'Anh Tuấn');
      expect(ble.sentPayloads, isNotEmpty);
      final callJson = jsonDecode(ble.sentPayloads.last) as Map<String, dynamic>;
      expect(callJson['type'], 'CALL');
      expect(callJson['app'], 'call');
      expect(callJson['title'], 'Anh Tuấn');
      expect(callJson['msg'], '0987654321');

      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(const MethodCall('onCallEnded')),
        (_) {},
      );

      expect(callService.isRinging, isFalse);
      final endJson = jsonDecode(ble.sentPayloads.last) as Map<String, dynamic>;
      expect(endJson['type'], 'CALL_END');
    });

    test('Forwards Android Zalo, Messenger & SMS notifications to ESP32 over BLE JSON', () async {
      const channel = MethodChannel('com.ysiduc.esp32_nav/calls');

      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(
          const MethodCall('onIncomingNotification', {
            'app': 'zalo',
            'title': 'Nguyễn Văn A',
            'msg': 'Đang chờ ở ngã tư Nguyễn Cảnh Dị nhé!',
          }),
        ),
        (_) {},
      );

      expect(callService.showSmsNotification, isTrue);
      expect(callService.lastSmsSender, 'Nguyễn Văn A');
      final smsJson = jsonDecode(ble.sentPayloads.last) as Map<String, dynamic>;
      expect(smsJson['type'], 'SMS');
      expect(smsJson['app'], 'zalo');
      expect(smsJson['title'], 'Nguyễn Văn A');
      expect(smsJson['msg'], 'Đang chờ ở ngã tư Nguyễn Cảnh Dị nhé!');
    });

    test('Parses Android native LocationManager fallback payloads safely', () {
      expect(NavigationManager.parseNativeLocationMap(null), isNull);
      expect(
        NavigationManager.parseNativeLocationMap({'lat': 0.0, 'lng': 0.0}),
        isNull,
      );

      final pos = NavigationManager.parseNativeLocationMap({
        'lat': 20.9832,
        'lng': 105.8425,
        'accuracy': 8.5,
        'speed': 5.0,
        'bearing': -1.0,
        'timestampMs': 1794625294000,
      });
      expect(pos, isNotNull);
      expect(pos!.latitude, closeTo(20.9832, 0.0001));
      expect(pos.longitude, closeTo(105.8425, 0.0001));
      expect(pos.accuracy, closeTo(8.5, 0.01));
      expect(pos.hasHeading, isFalse);
      expect(pos.hasSpeed, isTrue);
    });

    test('Matches ESP32 BLE advertisement by name, custom name, or FFE0 UUID', () {
      expect(
        BleService.matchesEspDeviceIdentity(
          remoteId: 'AA:BB:CC:DD:EE:FF',
          advName: 'Hoa hướng dương',
          platformName: '',
          serviceUuids: const [],
        ),
        isTrue,
      );
      expect(
        BleService.matchesEspDeviceIdentity(
          remoteId: 'AA:BB:CC:DD:EE:FF',
          advName: 'ysiducnaga',
          platformName: '',
          serviceUuids: const [],
        ),
        isTrue,
      );
      expect(
        BleService.matchesEspDeviceIdentity(
          remoteId: 'AA:BB:CC:DD:EE:FF',
          advName: '',
          platformName: '',
          serviceUuids: const ['0000ffe0-0000-1000-8000-00805f9b34fb'],
        ),
        isTrue,
      );
      expect(
        BleService.matchesEspDeviceIdentity(
          remoteId: 'AA:BB:CC:DD:EE:FF',
          advName: 'Random Speaker',
          platformName: 'Speaker',
          serviceUuids: const ['0000180d-0000-1000-8000-00805f9b34fb'],
        ),
        isFalse,
      );
    });
  });

  group('Personal Hotspot Config & BLE Status Protocol Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('Parses WIFI_STATUS for STA Hotspot mode vs SoftAP without false stream green', () {
      final ble = BleService();

      ble.handleIncomingBleMessageForTest(jsonEncode({
        'type': 'WIFI_STATUS',
        'mode': 'STA',
        'status': 'connected',
        'ip': '192.168.43.128',
        'gw': '192.168.43.1',
        'port': 8081,
      }));

      expect(ble.wifiMode, 'STA');
      expect(ble.espStaIp, '192.168.43.128');
      expect(ble.wifiGatewayIp, '192.168.43.1');
      expect(ble.espStaConnectedToHotspot, isTrue);
      expect(ble.isWifiConnected, isFalse);

      ble.handleIncomingBleMessageForTest(jsonEncode({
        'type': 'WIFI_STATUS',
        'mode': 'AP',
        'status': 'ready',
        'ip': '192.168.4.1',
        'port': 8081,
      }));

      expect(ble.wifiMode, 'AP');
      expect(ble.espStaIp, isNull);
      expect(ble.wifiGatewayIp, isNull);
      expect(ble.espStaConnectedToHotspot, isFalse);
    });

    test('Parses and persists DEVICE_CONFIG including Hotspot STA credentials', () async {
      final ble = BleService();

      ble.handleIncomingBleMessageForTest(jsonEncode({
        'type': 'DEVICE_CONFIG',
        'bleName': 'MyHUD',
        'ssid': 'MyAP',
        'pass': '87654321',
        'hotspot_mode': true,
        'sta_ssid': 'PhoneHotspot',
        'sta_pass': '12345678',
        'mode': 'STA',
        'ip': '172.20.10.4',
      }));

      await Future<void>.delayed(const Duration(milliseconds: 20));
      final prefs = await SharedPreferences.getInstance();

      expect(ble.customBleName, 'MyHUD');
      expect(ble.wifiSsid, 'MyAP');
      expect(ble.wifiPass, '87654321');
      expect(ble.hotspotModeEnabled, isTrue);
      expect(ble.hotspotSsid, 'PhoneHotspot');
      expect(ble.hotspotPass, '12345678');
      expect(ble.wifiMode, 'STA');
      expect(ble.espStaIp, '172.20.10.4');
      expect(prefs.getBool('esp_hotspot_mode'), isTrue);
      expect(prefs.getString('esp_hotspot_ssid'), 'PhoneHotspot');
      expect(prefs.getString('esp_hotspot_pass'), '12345678');
    });

    test('Persists offline Hotspot config edits and shields against stale DEVICE_CONFIG', () async {
      final ble = BleService();

      final sent = await ble.sendDeviceConfig(
        bleName: 'OfflineHUD',
        ssid: 'OfflineAP',
        pass: '11223344',
        hotspotMode: true,
        hotspotSsid: 'MyPhoneAP',
        hotspotPass: '99887766',
      );
      expect(sent, isFalse);
      expect(ble.hotspotModeEnabled, isTrue);
      expect(ble.hotspotSsid, 'MyPhoneAP');
      expect(ble.hotspotPass, '99887766');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('esp_pending_cfg_sync'), isTrue);
      expect(prefs.getBool('esp_hotspot_mode'), isTrue);
      expect(prefs.getString('esp_hotspot_ssid'), 'MyPhoneAP');
      expect(prefs.getString('esp_hotspot_pass'), '99887766');

      ble.handleIncomingBleMessageForTest(jsonEncode({
        'type': 'DEVICE_CONFIG',
        'ble_name': 'OldHUD',
        'ssid': 'OldAP',
        'pass': '00000000',
        'hotspot_mode': false,
        'sta_ssid': 'OldHotspot',
        'sta_pass': '00000000',
        'mode': 'AP',
      }));

      expect(ble.customBleName, 'OfflineHUD');
      expect(ble.hotspotModeEnabled, isTrue);
      expect(ble.hotspotSsid, 'MyPhoneAP');

      final modeOffSent = await ble.setHotspotMode(false);
      expect(modeOffSent, isFalse);
      expect(ble.hotspotModeEnabled, isFalse);
      expect(ble.wifiMode, 'AP');
      expect(ble.espStaIp, isNull);
    });
  });
}

