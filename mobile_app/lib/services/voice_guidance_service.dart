import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import '../models/route_model.dart';

/// Dịch vụ đọc chỉ dẫn dẫn đường bằng giọng nói tiếng Việt chuẩn
class VoiceGuidanceService extends ChangeNotifier {
  static final VoiceGuidanceService _instance = VoiceGuidanceService._internal();
  factory VoiceGuidanceService() => _instance;
  VoiceGuidanceService._internal() {
    _initTts();
  }

  final FlutterTts _flutterTts = FlutterTts();
  bool _isInitialized = false;
  bool _isMuted = false;
  bool get isMuted => _isMuted;
  int get lastSpokenStepIndex => _lastSpokenStepIndex;
  String get lastSpokenText => _lastSpokenText;

  // Trackers to prevent repeating the same speech in the same step
  final Set<int> _announced200mSteps = {};
  final Set<int> _announced50mSteps = {};
  int _lastSpokenStepIndex = -1;
  String _lastSpokenText = '';
  DateTime? _lastSpokenTime;

  Future<void> _initTts() async {
    if (_isInitialized) return;
    try {
      // 1. Configure audio category for iOS (play through speaker/bluetooth headset, duck music)
      await _flutterTts.setIosAudioCategory(
        IosTextToSpeechAudioCategory.playback,
        [
          IosTextToSpeechAudioCategoryOptions.duckOthers,
          IosTextToSpeechAudioCategoryOptions.allowBluetooth,
          IosTextToSpeechAudioCategoryOptions.allowBluetoothA2DP,
        ],
        IosTextToSpeechAudioMode.voicePrompt,
      );

      // 2. Select Vietnamese language (vi-VN)
      final languages = await _flutterTts.getLanguages;
      String selectedLang = 'vi-VN';
      if (languages is List) {
        final hasViVN = languages.any((l) => l.toString().toLowerCase().contains('vi-vn'));
        final hasVi = languages.any((l) => l.toString().toLowerCase().startsWith('vi'));
        if (hasViVN) {
          selectedLang = 'vi-VN';
        } else if (hasVi) {
          selectedLang = 'vi';
        }
      }
      await _flutterTts.setLanguage(selectedLang);

      // 3. Cadence & Tone Settings
      await _flutterTts.setSpeechRate(0.5); // Natural speaking rate
      await _flutterTts.setVolume(1.0);     // Full clear volume
      await _flutterTts.setPitch(1.0);      // Normal pitch
      await _flutterTts.awaitSynthCompletion(true);

      _isInitialized = true;
      debugPrint('[TTS] Initialized with language: $selectedLang');
    } catch (e) {
      debugPrint('[TTS] Init error: $e');
    }
  }

  /// Bật / Tắt giọng nói
  void toggleMute() {
    _isMuted = !_isMuted;
    if (_isMuted) {
      stop();
    } else {
      speak('Bật chỉ dẫn giọng nói');
    }
    notifyListeners();
  }

  void setMuted(bool muted) {
    if (_isMuted == muted) return;
    _isMuted = muted;
    if (_isMuted) {
      stop();
    }
    notifyListeners();
  }

  /// Dừng câu nói hiện tại
  Future<void> stop() async {
    try {
      await _flutterTts.stop();
    } catch (_) {}
  }

  /// Đọc câu nói bất kỳ (có chống spam câu giống nhau trong 3 giây)
  Future<void> speak(String text) async {
    if (_isMuted || text.trim().isEmpty) return;
    final now = DateTime.now();
    if (_lastSpokenText == text && _lastSpokenTime != null && now.difference(_lastSpokenTime!).inSeconds < 3) {
      return;
    }
    _lastSpokenText = text;
    _lastSpokenTime = now;

    if (!_isInitialized) {
      await _initTts();
    }
    try {
      await _flutterTts.stop();
      await _flutterTts.speak(text);
      debugPrint('[TTS Speak] "$text"');
    } catch (e) {
      debugPrint('[TTS] Speak error: $e');
    }
  }

  /// Xóa bộ nhớ thông báo khi kết thúc hoặc đổi lộ trình
  void resetNavigation() {
    _announced200mSteps.clear();
    _announced50mSteps.clear();
    _lastSpokenStepIndex = -1;
    _lastSpokenText = '';
    _lastSpokenTime = null;
    stop();
  }

  /// 1. Thông báo khi bắt đầu xuất phát
  void announceTripStart(String destination, double distanceKm, int durationMinutes) {
    if (_isMuted) return;
    resetNavigation();

    String distStr;
    if (distanceKm >= 1.0) {
      distStr = '${distanceKm.toStringAsFixed(1)} ki-lô-mét';
    } else {
      distStr = '${(distanceKm * 1000).round()} mét';
    }

    String durStr;
    if (durationMinutes >= 60) {
      final h = durationMinutes ~/ 60;
      final m = durationMinutes % 60;
      durStr = m > 0 ? '$h giờ $m phút' : '$h giờ';
    } else {
      durStr = '$durationMinutes phút';
    }

    final cleanDest = destination.split(',').first.trim();
    final text = 'Bắt đầu dẫn đường đến $cleanDest. Quãng đường $distStr, thời gian dự kiến $durStr.';
    speak(text);
  }

  /// 2. Theo dõi khoảng cách và đọc chỉ dẫn rẽ theo thời gian thực
  void checkAndAnnounceManeuver({
    required NavStep step,
    required double distanceMeters,
    required int stepIndex,
  }) {
    if (_isMuted) return;

    final int distRound = (distanceMeters / 10).round() * 10;
    final street = step.streetName.trim();
    final instruction = _cleanInstructionForSpeech(step.instruction, street);

    // Mốc 1: Cách điểm rẽ khoảng 120m - 220m
    if (distanceMeters <= 220 && distanceMeters >= 120) {
      if (!_announced200mSteps.contains(stepIndex)) {
        _announced200mSteps.add(stepIndex);
        _lastSpokenStepIndex = stepIndex;
        final String text = 'Sau $distRound mét nữa, $instruction';
        speak(text);
        return;
      }
    }

    // Mốc 2: Cách điểm rẽ khoảng 15m - 45m (chuẩn bị rẽ ngay)
    if (distanceMeters <= 45 && distanceMeters >= 15) {
      if (!_announced50mSteps.contains(stepIndex)) {
        _announced50mSteps.add(stepIndex);
        _lastSpokenStepIndex = stepIndex;
        String text;
        if (step.maneuverType == ManeuverType.arrive) {
          text = 'Điểm đến ở ngay phía trước.';
        } else if (step.maneuverType == ManeuverType.turnLeft || step.maneuverType == ManeuverType.sharpLeft) {
          text = street.isNotEmpty ? 'Chuẩn bị rẽ trái vào $street' : 'Chuẩn bị rẽ trái';
        } else if (step.maneuverType == ManeuverType.turnRight || step.maneuverType == ManeuverType.sharpRight) {
          text = street.isNotEmpty ? 'Chuẩn bị rẽ phải vào $street' : 'Chuẩn bị rẽ phải';
        } else if (step.maneuverType == ManeuverType.slightLeft) {
          text = street.isNotEmpty ? 'Rẽ chếch sang trái vào $street' : 'Rẽ chếch sang trái';
        } else if (step.maneuverType == ManeuverType.slightRight) {
          text = street.isNotEmpty ? 'Rẽ chếch sang phải vào $street' : 'Rẽ chếch sang phải';
        } else if (step.maneuverType == ManeuverType.uTurn) {
          text = 'Chuẩn bị quay đầu xe';
        } else if (step.maneuverType == ManeuverType.roundabout) {
          text = 'Chuẩn bị đi vào vòng xuyến';
        } else {
          text = instruction;
        }
        speak(text);
        return;
      }
    }
  }

  /// 3. Thông báo khi đi chệch đường và đang tính toán lại
  void announceReroute() {
    if (_isMuted) return;
    speak('Đang tính lại lộ trình.');
  }

  /// 4. Thông báo khi đã đến điểm đích
  void announceArrival([String? destinationName]) {
    if (_isMuted) return;
    if (destinationName != null && destinationName.isNotEmpty) {
      final clean = destinationName.split(',').first.trim();
      speak('Bạn đã đến điểm đến $clean. Chuyến đi hoàn tất.');
    } else {
      speak('Bạn đã đến điểm đến. Chuyến đi hoàn tất.');
    }
  }

  /// Chuẩn hóa câu chữ chỉ dẫn để đọc tiếng Việt mượt mà và tự nhiên
  String _cleanInstructionForSpeech(String raw, String street) {
    String text = raw.trim();
    // Bỏ thẻ HTML nếu có
    text = text.replaceAll(RegExp(r'<[^>]*>'), '');
    
    // Viết gọn câu
    if (text.isEmpty) {
      if (street.isNotEmpty) {
        return 'tiếp tục đi trên $street';
      }
      return 'tiếp tục đi thẳng';
    }
    
    // Chuyển chữ đầu thành chữ thường để ghép câu tự nhiên
    if (text.length > 1) {
      text = text[0].toLowerCase() + text.substring(1);
    }
    return text;
  }
}
