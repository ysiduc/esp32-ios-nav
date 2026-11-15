import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'ble_service.dart';

class PhoneCallService extends ChangeNotifier {
  static const MethodChannel _callChannel = MethodChannel('com.ysiduc.esp32_nav/calls');

  final BleService _bleService;

  bool _isRinging = false;
  bool _isInCall = false;
  String _callerName = '';
  String _phoneNumber = '';
  bool _notificationAccessGranted = false;

  // Last received SMS notification
  String _lastSmsSender = '';
  String _lastSmsMessage = '';
  bool _showSmsNotification = false;
  Timer? _smsDismissTimer;

  PhoneCallService(this._bleService) {
    _initChannel();
    refreshNotificationAccessStatus();
  }

  bool get isRinging => _isRinging;
  bool get isInCall => _isInCall;
  String get callerName => _callerName.isNotEmpty ? _callerName : 'Cuộc gọi đến';
  String get phoneNumber => _phoneNumber;
  bool get showSmsNotification => _showSmsNotification;
  String get lastSmsSender => _lastSmsSender;
  String get lastSmsMessage => _lastSmsMessage;
  bool get notificationAccessGranted => _notificationAccessGranted;

  Future<void> refreshNotificationAccessStatus() async {
    if (kIsWeb || !Platform.isAndroid) {
      _notificationAccessGranted = true;
      return;
    }
    try {
      final enabled = await _callChannel.invokeMethod<bool>('isNotificationListenerEnabled') ?? false;
      if (_notificationAccessGranted != enabled) {
        _notificationAccessGranted = enabled;
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> openNotificationAccessSettings() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _callChannel.invokeMethod('openNotificationListenerSettings');
    } catch (_) {}
  }

  void _initChannel() {
    _callChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onIncomingCall':
          final args = call.arguments != null ? Map<String, dynamic>.from(call.arguments as Map) : {};
          final name = (args['name'] as String?) ?? (args['caller'] as String?) ?? 'Cuộc gọi đến';
          final number = args['number'] as String? ?? '';
          _onIncomingCall(name, number);
          break;
        case 'onCallAnswered':
          _isRinging = false;
          _isInCall = true;
          _bleService.sendRawString(jsonEncode({'type': 'CALL_END'}));
          notifyListeners();
          break;
        case 'onCallEnded':
          _onCallEnded();
          break;
        case 'onIncomingNotification':
          final args = call.arguments != null ? Map<String, dynamic>.from(call.arguments as Map) : {};
          final app = (args['app'] as String?)?.trim() ?? 'sms';
          final title = (args['title'] as String?)?.trim() ?? 'Thông báo';
          final msg = (args['msg'] as String?)?.trim() ?? '';
          _onIncomingNotification(app, title, msg);
          break;
      }
    });
  }

  void _onIncomingCall(String name, String number) {
    _isRinging = true;
    _isInCall = false;
    _callerName = name;
    _phoneNumber = number;
    notifyListeners();

    final isGeneric = name.toLowerCase() == 'cuoc goi den' ||
        name.toLowerCase() == 'cuộc gọi đến' ||
        name.toLowerCase() == 'unknown' ||
        name.isEmpty;
    final hasRealNumber = number.isNotEmpty && number != 'unknown';

    final title = !isGeneric ? name : 'Cuộc gọi đến';
    final msg = hasRealNumber && !isGeneric ? number : (hasRealNumber ? number : 'Đang đổ chuông...');
    _bleService.sendRawString(jsonEncode({
      'type': 'CALL',
      'app': 'call',
      'title': title,
      'msg': msg,
    }));
  }

  void _onIncomingNotification(String appType, String title, String message) {
    if (title.isEmpty && message.isEmpty) return;
    _lastSmsSender = title.isNotEmpty ? title : appType.toUpperCase();
    _lastSmsMessage = message;
    _showSmsNotification = true;
    notifyListeners();

    final cleanTitle = _lastSmsSender.length > 42 ? '${_lastSmsSender.substring(0, 39)}...' : _lastSmsSender;
    final cleanMsg = message.length > 96 ? '${message.substring(0, 93)}...' : message;
    _bleService.sendRawString(jsonEncode({
      'type': 'SMS',
      'app': appType,
      'title': cleanTitle,
      'msg': cleanMsg,
    }));

    _smsDismissTimer?.cancel();
    _smsDismissTimer = Timer(const Duration(seconds: 5), () {
      _showSmsNotification = false;
      notifyListeners();
    });
  }

  void _onCallEnded() {
    _isRinging = false;
    _isInCall = false;
    notifyListeners();

    // Clear alert on ESP32
    _bleService.sendRawString(jsonEncode({'type': 'CALL_END'}));
  }

  /// Trigger a simulated or user-tested incoming call
  void triggerMockCall({String? name, String? number}) {
    final cName = name?.trim().isNotEmpty == true ? name!.trim() : 'Mẹ (0912.345.678)';
    final cNum = number?.trim().isNotEmpty == true ? number!.trim() : '0912 345 678';
    _onIncomingCall(cName, cNum);

    // Auto dismiss after 10s if not answered
    Timer(const Duration(seconds: 10), () {
      if (_isRinging && !_isInCall) {
        _onCallEnded();
      }
    });
  }

  /// Trigger a simulated or user-tested incoming SMS / Zalo message
  void triggerMockSms({String? sender, String? message}) {
    _lastSmsSender = sender?.trim().isNotEmpty == true ? sender!.trim() : 'Zalo: Anh Nam';
    _lastSmsMessage = message?.trim().isNotEmpty == true ? message!.trim() : 'Bạn đang ở đâu đấy?';
    _showSmsNotification = true;
    notifyListeners();

    // Send to ESP32 via BLE
    final sLower = _lastSmsSender.toLowerCase();
    final appType = sLower.contains('zalo')
        ? 'zalo'
        : (sLower.contains('messenger') ? 'messenger' : 'sms');
    _bleService.sendRawString('{"type":"SMS","app":"$appType","title":"$_lastSmsSender","msg":"$_lastSmsMessage"}');

    _smsDismissTimer?.cancel();
    _smsDismissTimer = Timer(const Duration(seconds: 5), () {
      _showSmsNotification = false;
      notifyListeners();
    });
  }

  /// End the call
  void endCall() {
    _onCallEnded();
  }
}
