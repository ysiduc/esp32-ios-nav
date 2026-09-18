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
  String _callApp = 'sim'; // 'sim' or 'zalo'

  // Last received message notification
  String _lastSmsSender = '';
  String _lastSmsMessage = '';
  String _smsApp = 'zalo'; // 'zalo', 'sim', 'messenger'
  bool _showSmsNotification = false;
  Timer? _smsDismissTimer;

  PhoneCallService(this._bleService) {
    _initChannel();
  }

  bool get isRinging => _isRinging;
  bool get isInCall => _isInCall;
  String get callerName => _callerName.isNotEmpty ? _callerName : 'Cuộc gọi đến';
  String get phoneNumber => _phoneNumber;
  String get callApp => _callApp;
  bool get showSmsNotification => _showSmsNotification;
  String get lastSmsSender => _lastSmsSender;
  String get lastSmsMessage => _lastSmsMessage;
  String get smsApp => _smsApp;

  void _initChannel() {
    _callChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onIncomingCall':
          final args = call.arguments != null ? Map<String, dynamic>.from(call.arguments as Map) : {};
          final name = args['name'] as String? ?? 'Cuộc gọi đến';
          final number = args['number'] as String? ?? '';
          final app = args['app'] as String? ?? 'sim';
          _onIncomingCall(name, number, app: app);
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

  void _onIncomingCall(String name, String number, {String app = 'sim'}) {
    _isRinging = true;
    _isInCall = false;
    _callerName = name;
    _phoneNumber = number;
    _callApp = app;
    notifyListeners();

    final isGeneric = name.toLowerCase() == 'cuoc goi den' ||
        name.toLowerCase() == 'cuộc gọi đến' ||
        name.toLowerCase() == 'unknown' ||
        name.isEmpty;
    final hasRealNumber = number.isNotEmpty && number != 'unknown';

    final title = !isGeneric ? name : (app == 'zalo' ? 'Zalo Audio Call' : 'Cuộc gọi đến');
    final msg = hasRealNumber && !isGeneric ? number : 'đang gọi đến...';
    _bleService.sendRawString('{"type":"CALL","app":"$app","title":"$title","msg":"$msg"}');
  }

  void _onCallEnded() {
    _isRinging = false;
    _isInCall = false;
    notifyListeners();

    // Clear alert on ESP32
    _bleService.sendRawString('{"type":"CALL_END"}');
  }

  /// Trigger a simulated or user-tested incoming call
  void triggerMockCall({String? name, String? number, String app = 'sim'}) {
    final cName = name?.trim().isNotEmpty == true
        ? name!.trim()
        : (app == 'zalo' ? 'Nguyễn Văn A' : 'Mẹ (0912.345.678)');
    final cNum = number?.trim().isNotEmpty == true
        ? number!.trim()
        : (app == 'zalo' ? 'Zalo Audio Call' : '0912 345 678');
    _onIncomingCall(cName, cNum, app: app);

    // Auto dismiss after 12s if not answered
    Timer(const Duration(seconds: 12), () {
      if (_isRinging && !_isInCall) {
        _onCallEnded();
      }
    });
  }

  /// Trigger a simulated or user-tested incoming SMS / Zalo message
  void triggerMockSms({String? sender, String? message, String app = 'zalo'}) {
    _lastSmsSender = sender?.trim().isNotEmpty == true
        ? sender!.trim()
        : (app == 'zalo' ? 'Anh Nam' : (app == 'messenger' ? 'Linh Hoàng' : '0988.123.456'));
    _lastSmsMessage = message?.trim().isNotEmpty == true
        ? message!.trim()
        : (app == 'zalo' ? 'Bạn đang ở đâu đấy? Chiều nay đi cà phê nhé!' : 'Mã xác thực OTP của bạn là 849201');
    _smsApp = app;
    _showSmsNotification = true;
    notifyListeners();

    // Send to ESP32 via BLE
    _bleService.sendRawString('{"type":"SMS","app":"$app","title":"$_lastSmsSender","msg":"$_lastSmsMessage"}');

    _smsDismissTimer?.cancel();
    _smsDismissTimer = Timer(const Duration(seconds: 8), () {
      _showSmsNotification = false;
      notifyListeners();
    });
  }

  /// End the call
  void endCall() {
    _onCallEnded();
  }
}
