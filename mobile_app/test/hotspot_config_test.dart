import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobile_app/services/ble_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Personal Hotspot Config & BLE Status Protocol Tests (iOS)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('Parses WIFI_STATUS for STA Hotspot mode vs SoftAP without false stream green', () {
      final ble = BleService();

      ble.handleIncomingBleMessageForTest(jsonEncode({
        'type': 'WIFI_STATUS',
        'mode': 'STA',
        'status': 'connected',
        'ip': '172.20.10.5',
        'gw': '172.20.10.1',
        'port': 8081,
      }));

      expect(ble.wifiMode, 'STA');
      expect(ble.espStaIp, '172.20.10.5');
      expect(ble.wifiGatewayIp, '172.20.10.1');
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
        'sta_ssid': 'iPhoneHotspot',
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
      expect(ble.hotspotSsid, 'iPhoneHotspot');
      expect(ble.hotspotPass, '12345678');
      expect(ble.wifiMode, 'STA');
      expect(ble.espStaIp, '172.20.10.4');
      expect(prefs.getBool('esp_hotspot_mode'), isTrue);
      expect(prefs.getString('esp_hotspot_ssid'), 'iPhoneHotspot');
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

