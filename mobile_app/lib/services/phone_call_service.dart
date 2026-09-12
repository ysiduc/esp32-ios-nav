import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'ble_service.dart';

/// Trạng thái cuộc gọi
enum CallStatus {
  none,       // Không có cuộc gọi
  ringing,    // Đang đổ chuông (cuộc gọi đến)
  active,     // Đang nghe máy
  ended,      // Kết thúc
}

/// Service nhận sự kiện cuộc gọi từ iOS (CallKit CXCallObserver)
/// và tự động gửi thông báo JSON đến ESP32 qua BLE
class PhoneCallService extends ChangeNotifier {
  static const MethodChannel _channel =
      MethodChannel('com.ysiduc.esp32_nav/calls');

  final BleService _bleService;

  CallStatus _callStatus = CallStatus.none;
  String _callerName = '';
  String _callerNumber = '';
  Timer? _callEndTimer;

  CallStatus get callStatus => _callStatus;
  String get callerName => _callerName;
  String get callerNumber => _callerNumber;
  bool get isIncomingCall => _callStatus == CallStatus.ringing;
  bool get hasActiveCall =>
      _callStatus == CallStatus.ringing || _callStatus == CallStatus.active;

  PhoneCallService({required BleService bleService})
      : _bleService = bleService {
    _init();
  }

  void _init() {
    if (!kIsWeb && Platform.isIOS) {
      _channel.setMethodCallHandler(_handleNativeCall);
    }
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onIncomingCall':
        final data = Map<String, dynamic>.from(call.arguments as Map);
        _onCallRinging(
          name: (data['name'] as String?) ?? 'So khong ro',
          number: (data['number'] as String?) ?? '',
        );
        break;

      case 'onCallAnswered':
        final data = Map<String, dynamic>.from(call.arguments as Map);
        _onCallActive(
          name: (data['name'] as String?) ?? _callerName,
          number: (data['number'] as String?) ?? _callerNumber,
        );
        break;

      case 'onCallEnded':
        _onCallEnded();
        break;

      default:
        break;
    }
    return null;
  }

  void _onCallRinging({required String name, required String number}) {
    _callStatus = CallStatus.ringing;
    _callerName = name;
    _callerNumber = number;
    notifyListeners();

    // Gửi alert đến ESP32
    _sendCallAlertToBle(type: 'CALL', title: name, msg: number);

    // Tự động xoá popup sau 30 giây nếu không trả lời
    _callEndTimer?.cancel();
    _callEndTimer = Timer(const Duration(seconds: 30), () {
      if (_callStatus == CallStatus.ringing) {
        _onCallEnded();
      }
    });
  }

  void _onCallActive({required String name, required String number}) {
    _callStatus = CallStatus.active;
    _callerName = name;
    _callerNumber = number;
    _callEndTimer?.cancel();
    notifyListeners();

    // Gửi thông báo "đang nghe máy"
    _sendCallAlertToBle(type: 'CALL_ACTIVE', title: name, msg: 'Dang nghe may');
  }

  void _onCallEnded() {
    _callStatus = CallStatus.ended;
    _callEndTimer?.cancel();
    notifyListeners();

    // Xoá popup trên ESP32
    _sendCallEndToBle();

    // Sau 2 giây reset
    Future.delayed(const Duration(seconds: 2), () {
      _callStatus = CallStatus.none;
      _callerName = '';
      _callerNumber = '';
      notifyListeners();
    });
  }

  Future<void> _sendCallAlertToBle({
    required String type,
    required String title,
    required String msg,
  }) async {
    if (!_bleService.isConnected) return;
    final json = jsonEncode({
      'type': type,
      'title': _truncate(title, 20),
      'msg': _truncate(msg, 30),
    });
    await _bleService.sendRawString(json);
  }

  Future<void> _sendCallEndToBle() async {
    if (!_bleService.isConnected) return;
    final json = jsonEncode({'type': 'CALL_END'});
    await _bleService.sendRawString(json);
  }

  String _truncate(String s, int max) =>
      s.length > max ? s.substring(0, max) : s;

  /// Test thủ công từ UI
  Future<void> testIncomingCall({
    String name = 'Nguyen Van A',
    String number = '0912345678',
  }) async {
    _onCallRinging(name: name, number: number);

    // Tự kết thúc sau 8 giây
    await Future.delayed(const Duration(seconds: 8));
    if (_callStatus == CallStatus.ringing) {
      _onCallEnded();
    }
  }

  Future<void> testSmsAlert({
    String sender = 'Zalo',
    String content = 'Ban co tin nhan moi',
  }) async {
    if (!_bleService.isConnected) return;
    final json = jsonEncode({
      'type': 'SMS',
      'title': _truncate(sender, 20),
      'msg': _truncate(content, 30),
    });
    await _bleService.sendRawString(json);
  }

  @override
  void dispose() {
    _callEndTimer?.cancel();
    super.dispose();
  }
}
