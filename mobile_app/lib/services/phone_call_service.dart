import 'dart:async';
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

  // Last received SMS notification
  String _lastSmsSender = '';
  String _lastSmsMessage = '';
  bool _showSmsNotification = false;
  Timer? _smsDismissTimer;

  PhoneCallService(this._bleService) {
    _initChannel();
  }

  bool get isRinging => _isRinging;
  bool get isInCall => _isInCall;
  String get callerName => _callerName.isNotEmpty ? _callerName : 'Cuộc gọi đến';
  String get phoneNumber => _phoneNumber;
  bool get showSmsNotification => _showSmsNotification;
  String get lastSmsSender => _lastSmsSender;
  String get lastSmsMessage => _lastSmsMessage;

  void _initChannel() {
    _callChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onIncomingCall':
          final args = call.arguments != null ? Map<String, dynamic>.from(call.arguments as Map) : {};
          final name = args['name'] as String? ?? 'Cuộc gọi đến';
          final number = args['number'] as String? ?? '';
          _onIncomingCall(name, number);
          break;
        case 'onCallAnswered':
          _isRinging = false;
          _isInCall = true;
          notifyListeners();
          break;
        case 'onCallEnded':
          _onCallEnded();
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
    final msg = hasRealNumber && !isGeneric ? number : 'Đang đổ chuông...';
    _bleService.sendRawString('{"type":"CALL","title":"$title","msg":"$msg"}');
  }

  void _onCallEnded() {
    _isRinging = false;
    _isInCall = false;
    notifyListeners();

    // Clear alert on ESP32
    _bleService.sendRawString('{"type":"CALL_END"}');
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
    _bleService.sendRawString('{"type":"SMS","title":"$_lastSmsSender","msg":"$_lastSmsMessage"}');

    _smsDismissTimer?.cancel();
    _smsDismissTimer = Timer(const Duration(seconds: 6), () {
      _showSmsNotification = false;
      notifyListeners();
    });
  }

  /// End the call
  void endCall() {
    _onCallEnded();
  }
}
