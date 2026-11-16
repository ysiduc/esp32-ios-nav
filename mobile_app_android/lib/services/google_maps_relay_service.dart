import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/esp_payload.dart';
import 'ble_service.dart';
import 'esp_stream_service.dart';
import 'navigation_manager.dart';
import 'phone_media_service.dart';

class GoogleMapsNavSnapshot {
  final int turnCode;
  final int distanceToTurn;
  final int totalDistance;
  final int etaMinutes;
  final String streetName;
  final String? arrivalTime;
  final String rawTitle;
  final String rawSubText;
  final DateTime updatedAt;

  const GoogleMapsNavSnapshot({
    required this.turnCode,
    required this.distanceToTurn,
    required this.totalDistance,
    required this.etaMinutes,
    required this.streetName,
    this.arrivalTime,
    required this.rawTitle,
    required this.rawSubText,
    required this.updatedAt,
  });

  String get formattedDistanceToTurn {
    if (distanceToTurn >= 1000) {
      return '${(distanceToTurn / 1000).toStringAsFixed(1)} km';
    }
    return '$distanceToTurn m';
  }

  String get formattedTotalDistance {
    if (totalDistance >= 1000) {
      return '${(totalDistance / 1000).toStringAsFixed(1)} km';
    }
    return '$totalDistance m';
  }

  IconData get icon {
    switch (turnCode) {
      case 1:
        return Icons.turn_slight_right_rounded;
      case 2:
        return Icons.turn_right_rounded;
      case 3:
        return Icons.turn_sharp_right_rounded;
      case 4:
        return Icons.u_turn_left_rounded;
      case 5:
        return Icons.turn_sharp_left_rounded;
      case 6:
        return Icons.turn_left_rounded;
      case 7:
        return Icons.turn_slight_left_rounded;
      case 8:
        return Icons.roundabout_right_rounded;
      case 9:
        return Icons.flag_rounded;
      case 0:
      default:
        return Icons.straight_rounded;
    }
  }
}

/// Captures active Google Maps notifications (via EspNotificationListenerService,
/// inspired by maisonsmd/esp32-google-maps) and relays turn-by-turn guidance over BLE
/// in pure BLE mode (without Wi-Fi map streaming).
class GoogleMapsRelayService extends ChangeNotifier {
  static const MethodChannel _gmapsChannel = MethodChannel('com.ysiduc.esp32_nav/gmaps');

  BleService _bleService;
  NavigationManager _navManager;
  EspStreamService _streamService;
  PhoneMediaService _mediaService;

  bool _isEnabled = false;
  bool _hasActiveNav = false;
  bool _streamMapEnabled = true;
  bool _notificationAccessGranted = false;
  GoogleMapsNavSnapshot? _latestSnapshot;
  Timer? _keepaliveTimer;
  int _lastSentSpeedKmh = -1;
  DateTime _lastBlePushTime = DateTime.fromMillisecondsSinceEpoch(0);

  bool get isEnabled => _isEnabled;
  bool get hasActiveNav => _hasActiveNav;
  bool get streamMapEnabled => _streamMapEnabled;
  bool get notificationAccessGranted => _notificationAccessGranted;
  GoogleMapsNavSnapshot? get latestSnapshot => _latestSnapshot;
  int get currentSpeedKmh => _navManager.currentSpeedKmh.round();

  GoogleMapsRelayService({
    required BleService bleService,
    required NavigationManager navManager,
    required EspStreamService streamService,
    required PhoneMediaService mediaService,
  })  : _bleService = bleService,
        _navManager = navManager,
        _streamService = streamService,
        _mediaService = mediaService {
    _navManager.addListener(_onNavManagerChanged);
    _gmapsChannel.setMethodCallHandler(_handleNativeMethodCall);
    refreshNotificationAccessStatus();
  }

  void updateReferences({
    required BleService bleService,
    required NavigationManager navManager,
    required EspStreamService streamService,
    required PhoneMediaService mediaService,
  }) {
    if (!identical(_navManager, navManager)) {
      _navManager.removeListener(_onNavManagerChanged);
      _navManager = navManager;
      _navManager.addListener(_onNavManagerChanged);
    }
    _bleService = bleService;
    _streamService = streamService;
    _mediaService = mediaService;
  }

  void _onNavManagerChanged() {
    if (!_isEnabled || !_hasActiveNav || _latestSnapshot == null) return;
    final int spd = _navManager.currentSpeedKmh.round();
    final now = DateTime.now();
    if (spd != _lastSentSpeedKmh &&
        now.difference(_lastBlePushTime).inMilliseconds >= 650) {
      _pushSnapshotOverBle(_latestSnapshot!);
      notifyListeners();
    }
  }

  Future<bool> refreshNotificationAccessStatus() async {
    if (kIsWeb || !Platform.isAndroid) {
      _notificationAccessGranted = false;
      return false;
    }
    try {
      final granted =
          await _gmapsChannel.invokeMethod<bool>('isNotificationListenerEnabled') ?? false;
      if (_notificationAccessGranted != granted) {
        _notificationAccessGranted = granted;
        notifyListeners();
      }
      return granted;
    } catch (_) {
      return _notificationAccessGranted;
    }
  }

  Future<void> openNotificationAccessSettings() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _gmapsChannel.invokeMethod('openNotificationListenerSettings');
    } catch (_) {}
  }

  Future<bool> launchGoogleMaps() async {
    if (kIsWeb || !Platform.isAndroid) return false;
    try {
      return await _gmapsChannel.invokeMethod<bool>('launchGoogleMaps') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Switches between streaming drawn Man 3 map over Wi-Fi (default) and BLE-only Man 2 mode.
  void setStreamMapEnabled(bool enabled) {
    if (_streamMapEnabled == enabled) return;
    _streamMapEnabled = enabled;
    if (_isEnabled) {
      _syncStreamMode();
    }
    notifyListeners();
  }

  void _syncStreamMode() {
    if (!_isEnabled) {
      _streamService.setBleOnlyNavMode(false);
      return;
    }
    if (_streamMapEnabled) {
      _streamService.setBleOnlyNavMode(false);
      _streamService.ensureExternalNavStreamingActive();
    } else {
      _streamService.setBleOnlyNavMode(true);
    }
  }

  /// Enables or disables Google Maps navigation relay mode (draws & streams Man 3 by default, or BLE-only Man 2).
  /// Returns `true` if mode applied, or `false` if Android Notification Access is missing.
  Future<bool> setEnabled(bool enabled, {bool checkPermission = true}) async {
    if (enabled == _isEnabled) {
      if (enabled) {
        _syncStreamMode();
        await scanActiveNotificationNow();
      }
      return true;
    }

    if (enabled) {
      if (checkPermission && !kIsWeb && Platform.isAndroid) {
        final granted = await refreshNotificationAccessStatus();
        if (!granted) {
          return false;
        }
      }
      _isEnabled = true;
      if (_navManager.isNavigating) {
        _navManager.stopNavigation();
      }
      _navManager.setExternalBleNavActive(true, hasActiveNav: false);
      _syncStreamMode();
      _startKeepaliveTimer();
      notifyListeners();
      await scanActiveNotificationNow();
      return true;
    }

    _disableRelayAndRestore();
    return true;
  }

  Future<void> scanActiveNotificationNow() async {
    if (!_isEnabled || kIsWeb || !Platform.isAndroid) return;
    try {
      final raw = await _gmapsChannel.invokeMethod<dynamic>('scanGoogleMapsNotification');
      if (raw is Map) {
        handleRawNotificationMap(Map<String, dynamic>.from(raw));
      }
    } catch (_) {}
  }

  Future<dynamic> _handleNativeMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onGoogleMapsNavigation':
        if (call.arguments is Map) {
          handleRawNotificationMap(Map<String, dynamic>.from(call.arguments as Map));
        }
        break;
      case 'onGoogleMapsNavEnded':
        handleNavigationEnded();
        break;
    }
  }

  @visibleForTesting
  void handleRawNotificationMap(Map<String, dynamic> raw) {
    final parsed = parseNotificationPayload(raw);
    if (parsed == null) return;
    _latestSnapshot = parsed;
    _hasActiveNav = true;
    if (_isEnabled) {
      _navManager.setExternalBleNavActive(
        true,
        hasActiveNav: true,
        turnCode: parsed.turnCode,
        distanceToTurn: parsed.distanceToTurn.toDouble(),
        totalDistance: parsed.totalDistance.toDouble(),
        etaMinutes: parsed.etaMinutes,
        streetName: parsed.streetName,
        arrivalTime: parsed.arrivalTime,
      );
      _pushSnapshotOverBle(parsed);
      if (_streamMapEnabled) {
        _streamService.ensureExternalNavStreamingActive();
      }
    }
    notifyListeners();
  }

  @visibleForTesting
  void handleNavigationEnded() {
    if (!_hasActiveNav && _latestSnapshot == null) return;
    _hasActiveNav = false;
    _latestSnapshot = null;
    if (_isEnabled) {
      _navManager.setExternalBleNavActive(true, hasActiveNav: false);
      _sendIdleRestoreToEsp();
    }
    notifyListeners();
  }

  void _disableRelayAndRestore() {
    _keepaliveTimer?.cancel();
    _keepaliveTimer = null;
    final wasNav = _hasActiveNav;
    _isEnabled = false;
    _hasActiveNav = false;
    _latestSnapshot = null;
    _navManager.setExternalBleNavActive(false, hasActiveNav: false);
    if (wasNav) {
      _sendIdleRestoreToEsp();
    } else {
      _navManager.sendPreviewPayloadToEsp32();
    }
    _streamService.setBleOnlyNavMode(false);
    notifyListeners();
  }

  void _sendIdleRestoreToEsp() {
    _navManager.sendPreviewPayloadToEsp32();
    if (_bleService.isConnected) {
      _bleService.sendRawJson(jsonEncode({'type': 'RESTORE_IDLE_MAP'}));
    }
  }

  void _startKeepaliveTimer() {
    _keepaliveTimer?.cancel();
    _keepaliveTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      if (!_isEnabled) return;
      unawaited(_navManager.refreshSpeedSampleIfStale());
      if (_hasActiveNav && _latestSnapshot != null) {
        _pushSnapshotOverBle(_latestSnapshot!);
      }
    });
  }

  void _pushSnapshotOverBle(GoogleMapsNavSnapshot snap) {
    if (!_bleService.isConnected) return;
    final now = DateTime.now();
    final curClock =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final int spdKmh = _navManager.currentSpeedKmh.round();
    _lastSentSpeedKmh = spdKmh;
    _lastBlePushTime = now;

    final payload = EspNavPayload(
      isNavigating: true,
      turnCode: snap.turnCode,
      distanceToTurn: snap.distanceToTurn,
      totalDistance: snap.totalDistance,
      etaMinutes: snap.etaMinutes,
      streetName: snap.streetName,
      currentSpeed: spdKmh,
      stepIndex: 0,
      totalSteps: 1,
      latitude: _navManager.currentLocation?.latitude,
      longitude: _navManager.currentLocation?.longitude,
      heading: _navManager.effectiveHeading.round(),
      currentClock: curClock,
      batteryLevel: _bleService.lastKnownBattery,
      songTitle: _mediaService.songTitle,
      songArtist: _mediaService.songArtist,
      songElapsed: _mediaService.elapsedTime.round(),
      songDuration: _mediaService.duration.round(),
    );
    _bleService.sendNavPayload(payload);
  }

  // ---------------------------------------------------------------------------
  // Pure Google Maps Notification Parser (Vietnamese & English, Extras & RemoteViews)
  // ---------------------------------------------------------------------------
  static final RegExp _actionOrFillerRegex = RegExp(
    r'^(google maps|maps|bản đồ|đang dẫn đường|navigating|navigation in progress|'
    r'exit navigation|thoát điều hướng|thoát|mute|tắt tiếng|bật tiếng|steps|các chặng|'
    r'recenter|về giữa|preview|xem trước|searching for gps|looking for gps|đang tìm gps)$',
    caseSensitive: false,
  );

  static final RegExp _distanceExprRegex = RegExp(
    r'(\d+(?:[.,]\d+)?)\s*(km|m|mi|mile|miles|dặm|ft|yd)\b',
    caseSensitive: false,
  );

  static final RegExp _etaOnlyLineRegex = RegExp(
    r'(?:phút|giờ|min|mins|minute|minutes|hr|hrs|hour|hours|giây|sec|secs)\b',
    caseSensitive: false,
  );

  @visibleForTesting
  static GoogleMapsNavSnapshot? parseNotificationPayload(Map<String, dynamic> raw) {
    final title = _normalizeSpace((raw['title'] as String?) ?? '');
    final text = _normalizeSpace((raw['text'] as String?) ?? '');
    final bigText = _normalizeSpace((raw['bigText'] as String?) ?? '');
    final subText = _normalizeSpace((raw['subText'] as String?) ?? '');
    final infoText = _normalizeSpace((raw['infoText'] as String?) ?? '');
    final bitmapTurnCode = (raw['bitmapTurnCode'] as num?)?.toInt() ?? -1;

    final rawTexts = (raw['texts'] as List?)
            ?.map((e) => _normalizeSpace(e?.toString() ?? ''))
            .where((s) => s.isNotEmpty)
            .toList() ??
        const <String>[];

    final allLines = <String>[];
    void addLine(String s) {
      if (s.isEmpty) return;
      if (_actionOrFillerRegex.hasMatch(s)) return;
      if (!allLines.contains(s)) allLines.add(s);
    }

    addLine(title);
    addLine(text);
    addLine(bigText);
    for (final s in rawTexts) {
      addLine(s);
    }
    addLine(subText);
    addLine(infoText);

    if (allLines.isEmpty) return null;

    // 1. Identify and parse the trip ETA/total-distance summary line
    int etaMinutes = 0;
    int totalDistance = 0;
    String? arrivalTime;
    String rawSubSummary = '';

    final etaCandidates = <String>[
      if (subText.isNotEmpty) subText,
      ...allLines.where((l) => l.contains('·') || l.contains('•') || _etaOnlyLineRegex.hasMatch(l)),
    ];
    for (final line in etaCandidates) {
      final summary = _parseEtaSummary(line);
      if (summary != null && (summary.etaMinutes > 0 || summary.totalDistance > 0)) {
        etaMinutes = summary.etaMinutes;
        totalDistance = summary.totalDistance;
        arrivalTime = summary.arrivalTime;
        rawSubSummary = line;
        break;
      }
    }

    // 2. Remaining lines describe current step (distance + turn instruction + street)
    final navLines = allLines.where((l) => l != rawSubSummary).toList();
    if (navLines.isEmpty && rawSubSummary.isEmpty) return null;

    int distanceToTurn = 0;
    String? consumedDistLine;
    String leftoverFromDistLine = '';

    for (final line in navLines) {
      final distParsed = _extractNextTurnDistance(line);
      if (distParsed != null) {
        distanceToTurn = distParsed.meters;
        consumedDistLine = line;
        leftoverFromDistLine = distParsed.remainder;
        break;
      }
    }

    // 3. Extract street name / instruction from non-summary lines
    final streetParts = <String>[];
    for (final line in navLines) {
      if (line == consumedDistLine) {
        if (leftoverFromDistLine.isNotEmpty) streetParts.add(leftoverFromDistLine);
        continue;
      }
      if (!_looksPureDistanceOrEta(line)) {
        streetParts.add(line);
      }
    }
    final combinedInstruction = streetParts.isNotEmpty
        ? streetParts.join(' · ')
        : (navLines.isNotEmpty ? navLines.first : '');

    // 4. Determine turnCode from explicit text instructions first, then fallback to bitmap classifier
    final combinedForTurn = navLines.join(' ');
    int turnCode = _classifyTurnFromText(combinedForTurn);
    if (turnCode < 0) {
      turnCode = (bitmapTurnCode >= 0 && bitmapTurnCode <= 9) ? bitmapTurnCode : 0;
    }

    String cleanStreet = _cleanStreetDisplay(
      streetParts.isNotEmpty ? streetParts.first : combinedInstruction,
    );
    if (cleanStreet.isEmpty) {
      cleanStreet = _defaultLabelForTurn(turnCode);
    }

    if (totalDistance == 0 && distanceToTurn > 0) {
      totalDistance = distanceToTurn;
    }

    return GoogleMapsNavSnapshot(
      turnCode: turnCode,
      distanceToTurn: distanceToTurn,
      totalDistance: totalDistance,
      etaMinutes: etaMinutes,
      streetName: cleanStreet,
      arrivalTime: arrivalTime,
      rawTitle: consumedDistLine ?? (navLines.isNotEmpty ? navLines.first : ''),
      rawSubText: rawSubSummary,
      updatedAt: DateTime.now(),
    );
  }

  static String _normalizeSpace(String s) =>
      s.replaceAll('\u00A0', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

  static ({int meters, String remainder})? _extractNextTurnDistance(String line) {
    final m = _distanceExprRegex.firstMatch(line);
    if (m == null) return null;
    // Skip lines that are actually ETA summary lines like "22 min (7.3 km)"
    if (_etaOnlyLineRegex.hasMatch(line) &&
        RegExp(r'\d+\s*(?:phút|giờ|min|mins|hr|hrs)', caseSensitive: false).hasMatch(line)) {
      return null;
    }
    final meters = _toMeters(m.group(1)!, m.group(2)!);
    var rem = '${line.substring(0, m.start)} ${line.substring(m.end)}'.trim();
    rem = rem
        .replaceFirst(RegExp(r'^(?:trong|sau|in|about)\b[\s:,-]*', caseSensitive: false), '')
        .replaceAll(RegExp(r'^[\s·•\-–:,]+|[\s·•\-–:,]+$'), '')
        .trim();
    return (meters: meters, remainder: rem);
  }

  static ({int etaMinutes, int totalDistance, String? arrivalTime})? _parseEtaSummary(String line) {
    int etaMin = 0;
    final hrMinMatch = RegExp(
      r'(\d+)\s*(?:giờ|g|hr|hrs|hour|hours|h)\s*(?:(\d+)\s*(?:phút|ph|p|min|mins|minute|minutes|m))?',
      caseSensitive: false,
    ).firstMatch(line);
    if (hrMinMatch != null) {
      final h = int.tryParse(hrMinMatch.group(1) ?? '') ?? 0;
      final min = int.tryParse(hrMinMatch.group(2) ?? '') ?? 0;
      etaMin = h * 60 + min;
    } else {
      final minMatch = RegExp(
        r'(\d+)\s*(?:phút|ph|min|mins|minute|minutes)\b',
        caseSensitive: false,
      ).firstMatch(line);
      if (minMatch != null) {
        etaMin = int.tryParse(minMatch.group(1) ?? '') ?? 0;
      } else if (RegExp(r'\d+\s*(?:giây|sec|secs|second)', caseSensitive: false).hasMatch(line)) {
        etaMin = 1;
      }
    }

    int totalMeters = 0;
    for (final dm in _distanceExprRegex.allMatches(line)) {
      final candidate = _toMeters(dm.group(1)!, dm.group(2)!);
      if (candidate > 0) {
        totalMeters = candidate;
        break;
      }
    }

    String? arrClock;
    final arrMatch = RegExp(r'\b(\d{1,2}):(\d{2})(?:\s*(AM|PM))?\b', caseSensitive: false)
        .firstMatch(line);
    if (arrMatch != null) {
      int hh = int.tryParse(arrMatch.group(1)!) ?? 0;
      final mm = int.tryParse(arrMatch.group(2)!) ?? 0;
      final ampm = arrMatch.group(3)?.toUpperCase();
      if (ampm == 'PM' && hh < 12) hh += 12;
      if (ampm == 'AM' && hh == 12) hh = 0;
      if (hh >= 0 && hh <= 23 && mm >= 0 && mm <= 59) {
        arrClock = '${hh.toString().padLeft(2, '0')}:${mm.toString().padLeft(2, '0')}';
      }
    }

    if (etaMin == 0 && totalMeters == 0) return null;
    return (etaMinutes: etaMin, totalDistance: totalMeters, arrivalTime: arrClock);
  }

  static bool _looksPureDistanceOrEta(String s) {
    final cleaned = s.replaceFirst(RegExp(r'^(?:trong|sau|in)\s+', caseSensitive: false), '').trim();
    return RegExp(r'^\d+(?:[.,]\d+)?\s*(?:km|m|mi|ft|yd)$', caseSensitive: false).hasMatch(cleaned);
  }

  static int _toMeters(String numStr, String unitStr) {
    final normalized = numStr.replaceAll(',', '.');
    final val = double.tryParse(normalized) ?? 0.0;
    final u = unitStr.toLowerCase();
    if (u == 'km') return (val * 1000.0).round();
    if (u == 'mi' || u == 'mile' || u == 'miles' || u == 'dặm') {
      return (val * 1609.34).round();
    }
    if (u == 'ft') return (val * 0.3048).round();
    if (u == 'yd') return (val * 0.9144).round();
    return val.round();
  }

  /// Maps text keywords (Vietnamese + English) to ESP32 turnCode (0..9), or -1 if ambiguous.
  static int _classifyTurnFromText(String rawText) {
    final t = rawText.toLowerCase();
    if (t.contains('đến nơi') ||
        t.contains('đã đến') ||
        t.contains('tới điểm đến') ||
        t.contains('arrived') ||
        t.contains('destination')) {
      return 9;
    }
    if (t.contains('quay đầu') ||
        t.contains('vòng lại') ||
        t.contains('u-turn') ||
        t.contains('uturn')) {
      return 4;
    }
    if (t.contains('vòng xuyến') ||
        t.contains('bùng binh') ||
        t.contains('vòng xoay') ||
        t.contains('roundabout') ||
        t.contains('rotary')) {
      return 8;
    }
    if (t.contains('ngoặt trái') ||
        t.contains('ngoặt sang trái') ||
        t.contains('sharp left')) {
      return 5;
    }
    if (t.contains('chếch sang trái') ||
        t.contains('chếch trái') ||
        t.contains('lách sang trái') ||
        t.contains('giữ bên trái') ||
        t.contains('slight left') ||
        t.contains('keep left') ||
        t.contains('bear left')) {
      return 7;
    }
    if (t.contains('rẽ trái') ||
        t.contains('quẹo trái') ||
        t.contains('sang trái') ||
        t.contains('turn left') ||
        t.contains('left onto') ||
        t.contains('left toward')) {
      return 6;
    }
    if (t.contains('ngoặt phải') ||
        t.contains('ngoặt sang phải') ||
        t.contains('sharp right')) {
      return 3;
    }
    if (t.contains('chếch sang phải') ||
        t.contains('chếch phải') ||
        t.contains('lách sang phải') ||
        t.contains('giữ bên phải') ||
        t.contains('slight right') ||
        t.contains('keep right') ||
        t.contains('bear right')) {
      return 1;
    }
    if (t.contains('rẽ phải') ||
        t.contains('quẹo phải') ||
        t.contains('sang phải') ||
        t.contains('turn right') ||
        t.contains('right onto') ||
        t.contains('right toward')) {
      return 2;
    }
    if (t.contains('đi thẳng') ||
        t.contains('tiếp tục đi') ||
        t.contains('go straight') ||
        t.contains('continue straight') ||
        t.startsWith('head ')) {
      return 0;
    }
    return -1;
  }

  static String _cleanStreetDisplay(String raw) {
    var s = _normalizeSpace(raw);
    if (s.isEmpty) return '';
    final targetedPrefix = RegExp(
      r'^(?:rẽ ngoặt sang trái|rẽ ngoặt sang phải|rẽ trái|rẽ phải|quẹo trái|quẹo phải|'
      r'chếch sang trái|chếch sang phải|chếch trái|chếch phải|đi thẳng|tiếp tục|quay đầu|vòng lại|'
      r'turn left|turn right|slight left|slight right|sharp left|sharp right|keep left|keep right|'
      r'continue|head\s+\w+|merge)\s+(?:vào|lên|theo|ra|sang|qua|về hướng|onto|on|toward|to)\s+',
      caseSensitive: false,
    );
    s = s.replaceFirst(targetedPrefix, '');
    s = s.replaceFirst(RegExp(r'^(?:đi từ|từ)\s+', caseSensitive: false), '');
    return s.replaceAll(RegExp(r'^[\s·•\-–:,]+|[\s·•\-–:,]+$'), '').trim();
  }

  static String _defaultLabelForTurn(int turnCode) {
    switch (turnCode) {
      case 1:
        return 'Chếch phải';
      case 2:
        return 'Rẽ phải';
      case 3:
        return 'Ngoặt phải';
      case 4:
        return 'Quay đầu';
      case 5:
        return 'Ngoặt trái';
      case 6:
        return 'Rẽ trái';
      case 7:
        return 'Chếch trái';
      case 8:
        return 'Vòng xuyến';
      case 9:
        return 'Đã đến nơi';
      default:
        return 'Đi thẳng';
    }
  }

  @override
  void dispose() {
    _navManager.removeListener(_onNavManagerChanged);
    _keepaliveTimer?.cancel();
    super.dispose();
  }
}

