import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:latlong2/latlong.dart';
import 'overpass_traffic_service.dart';

/// Bộ máy cảnh báo tiền phương (Forward Cone Alert Engine):
/// - Khớp tốc độ giới hạn hiện tại từ dữ liệu đường OSM (hoặc fallback theo loại đường).
/// - Kiểm tra quá tốc độ (`speedKmh >= currentSpeedLimitKmh + 3.0`).
/// - Quét camera phạt nguội / biển báo nguy hiểm phía trước trong phạm vi `< 300m`
///   và góc phương vị lệch `<= 30°` so với hướng di chuyển hiện tại.
/// - Đọc cảnh báo Tiếng Việt đúng 1 lần duy nhất cho mỗi điểm bằng `flutter_tts`.
class NavigationAlertEngine extends ChangeNotifier {
  static const double defaultAlertDistanceMeters = 300.0;
  static const double defaultForwardConeHalfAngleDeg = 30.0;
  static const double overSpeedThresholdKmh = 3.0;

  final OverpassTrafficService _trafficService;
  final void Function(String text)? _fallbackSpeaker;
  FlutterTts? _tts;
  bool _ttsInitialized = false;
  bool _isVoiceEnabled = true;

  RouteTrafficData _trafficData = RouteTrafficData.empty();
  int _currentSpeedLimitKmh = 50;
  bool _hasMatchedRoadLimit = false;
  bool _isOverSpeed = false;
  TrafficHazardNode? _upcomingHazard;
  double? _upcomingHazardDistanceM;

  final Set<String> _announcedHazardIds = <String>{};
  DateTime? _lastOverSpeedVoiceAt;
  bool _isFetchingRouteData = false;

  NavigationAlertEngine({
    OverpassTrafficService? trafficService,
    void Function(String text)? fallbackSpeaker,
    bool enableTts = true,
  })  : _trafficService = trafficService ?? OverpassTrafficService(),
        _fallbackSpeaker = fallbackSpeaker {
    if (enableTts) {
      _initTts();
    }
  }

  // Getters cho UI & ESP32 HUD
  int get currentSpeedLimitKmh => _currentSpeedLimitKmh;
  bool get hasMatchedRoadLimit => _hasMatchedRoadLimit;
  bool get isOverSpeed => _isOverSpeed;
  TrafficHazardNode? get upcomingHazard => _upcomingHazard;
  double? get upcomingHazardDistanceM => _upcomingHazardDistanceM;
  bool get hasUpcomingCamera =>
      _upcomingHazard != null &&
      _upcomingHazard!.type == TrafficHazardType.speedCamera &&
      (_upcomingHazardDistanceM ?? 9999) < defaultAlertDistanceMeters;
  List<TrafficHazardNode> get loadedHazards => _trafficData.hazards;
  List<SpeedRoadSegment> get loadedSegments => _trafficData.roadSegments;
  bool get isFetchingRouteData => _isFetchingRouteData;

  void setVoiceEnabled(bool enabled) {
    _isVoiceEnabled = enabled;
    if (!enabled) {
      try {
        _tts?.stop();
      } catch (_) {}
    }
  }

  Future<void> _initTts() async {
    if (_ttsInitialized) return;
    try {
      final tts = FlutterTts();
      if (!kIsWeb && Platform.isIOS) {
        await tts.setSharedInstance(true);
        await tts.setIosAudioCategory(
          IosTextToSpeechAudioCategory.playback,
          [
            IosTextToSpeechAudioCategoryOptions.duckOthers,
            IosTextToSpeechAudioCategoryOptions.mixWithOthers,
            IosTextToSpeechAudioCategoryOptions.allowBluetooth,
            IosTextToSpeechAudioCategoryOptions.allowBluetoothA2DP,
          ],
          IosTextToSpeechAudioMode.voicePrompt,
        );
      }
      await tts.setLanguage('vi-VN');
      await tts.setSpeechRate(0.5);
      await tts.setVolume(1.0);
      await tts.setPitch(1.0);
      _tts = tts;
      _ttsInitialized = true;
    } catch (e) {
      debugPrint('[NavigationAlertEngine] flutter_tts init fallback: $e');
    }
  }

  /// Tải dữ liệu tốc độ giới hạn, camera phạt nguội & biển báo cho lộ trình mới (không chặn UI).
  Future<void> loadTrafficForRoute(List<LatLng> polyline) async {
    if (polyline.isEmpty) return;
    _isFetchingRouteData = true;
    _announcedHazardIds.clear();
    notifyListeners();
    try {
      final data = await _trafficService.fetchTrafficForRoute(polyline, marginMeters: 500.0);
      _trafficData = data;
    } catch (e) {
      debugPrint('[NavigationAlertEngine] loadTrafficForRoute error: $e');
    } finally {
      _isFetchingRouteData = false;
      notifyListeners();
    }
  }

  /// Tải dữ liệu camera xung quanh vị trí hiện tại khi đang xem bản đồ / chạy tự do.
  Future<void> loadTrafficAroundLocation(LatLng center) async {
    try {
      final data = await _trafficService.fetchTrafficAroundLocation(center, radiusMeters: 1500.0);
      if (data.hazards.isNotEmpty || data.roadSegments.isNotEmpty) {
        _trafficData = data;
        notifyListeners();
      }
    } catch (_) {}
  }

  /// Nạp trực tiếp dữ liệu giao thông (dùng cho kiểm thử đơn vị hoặc nạp trước).
  @visibleForTesting
  void setTrafficDataForTest(RouteTrafficData data) {
    _trafficData = data;
    _announcedHazardIds.clear();
    _upcomingHazard = null;
    _upcomingHazardDistanceM = null;
    _isOverSpeed = false;
    notifyListeners();
  }

  /// Xóa trạng thái cảnh báo của chuyến đi khi kết thúc dẫn đường (giữ lại danh sách camera đã tải).
  void resetTripAlerts() {
    _announcedHazardIds.clear();
    _upcomingHazard = null;
    _upcomingHazardDistanceM = null;
    _isOverSpeed = false;
    _lastOverSpeedVoiceAt = null;
    notifyListeners();
  }

  /// Tính chênh lệch góc ngắn nhất giữa hai góc phương vị (0..180 độ).
  @visibleForTesting
  static double angleDiffDeg(double a, double b) {
    return (((a - b + 540.0) % 360.0) - 180.0).abs();
  }

  /// Kiểm tra một điểm mục tiêu có nằm trong hình nón tiền phương (Forward Cone):
  /// - Khoảng cách `< maxDistanceMeters` (mặc định 300m)
  /// - Góc phương vị tới mục tiêu lệch `<= maxBearingDiffDeg` (mặc định 30°) so với `vehicleHeadingDeg`.
  @visibleForTesting
  static ({bool inCone, double distanceMeters, double bearingDiffDeg}) evaluateForwardCone({
    required LatLng vehiclePos,
    required double vehicleHeadingDeg,
    required LatLng targetPos,
    double maxDistanceMeters = defaultAlertDistanceMeters,
    double maxBearingDiffDeg = defaultForwardConeHalfAngleDeg,
  }) {
    const distCalc = Distance();
    final double distM = distCalc.as(LengthUnit.Meter, vehiclePos, targetPos);
    if (distM <= 0.5 || distM >= maxDistanceMeters) {
      return (inCone: false, distanceMeters: distM, bearingDiffDeg: 180.0);
    }
    final double targetBearing = (distCalc.bearing(vehiclePos, targetPos) + 360.0) % 360.0;
    final double diff = angleDiffDeg(vehicleHeadingDeg, targetBearing);
    return (
      inCone: diff <= maxBearingDiffDeg,
      distanceMeters: distM,
      bearingDiffDeg: diff,
    );
  }

  /// Tạo câu cảnh báo Tiếng Việt tự nhiên cho TTS.
  @visibleForTesting
  static String buildVietnameseAlertText(
    TrafficHazardNode hazard,
    double distanceMeters, {
    int fallbackSpeedLimitKmh = 50,
  }) {
    final int roundedDist = distanceMeters >= 100
        ? ((distanceMeters / 50.0).round() * 50).clamp(100, 300)
        : ((distanceMeters / 10.0).round() * 10).clamp(20, 90);
    final int effectiveLimit = hazard.speedLimitKmh ?? fallbackSpeedLimitKmh;

    switch (hazard.type) {
      case TrafficHazardType.speedCamera:
        return 'Phía trước $roundedDist mét có camera giám sát, tốc độ tối đa $effectiveLimit ki-lô-mét trên giờ';
      case TrafficHazardType.railwayCrossing:
        return 'Phía trước $roundedDist mét có đường ngang giao cắt đường sắt, chú ý giảm tốc độ';
      case TrafficHazardType.stopSign:
        return 'Phía trước $roundedDist mét có biển báo dừng lại';
      case TrafficHazardType.trafficSign:
        if (hazard.speedLimitKmh != null) {
          return 'Phía trước $roundedDist mét có biển báo tốc độ tối đa ${hazard.speedLimitKmh} ki-lô-mét trên giờ';
        }
        return 'Phía trước $roundedDist mét có ${hazard.description.toLowerCase()}';
    }
  }

  /// Gọi ở mỗi nhịp cập nhật GPS để đánh giá tốc độ giới hạn, cảnh báo quá tốc độ và camera/biển báo phía trước.
  void updatePosition({
    required LatLng location,
    required double speedKmh,
    required double headingDeg,
    bool speakAlerts = true,
  }) {
    bool changed = false;

    // 1. Khớp tốc độ giới hạn hiện tại từ đoạn đường OSM gần nhất
    final matchedRoad = OverpassTrafficService.matchSpeedLimitAt(
      location,
      _trafficData.roadSegments,
      maxDistanceMeters: 45.0,
    );
    int nextLimit = _currentSpeedLimitKmh;
    bool nextHasRoadLimit = _hasMatchedRoadLimit;
    if (matchedRoad != null) {
      nextLimit = matchedRoad.speedLimitKmh;
      nextHasRoadLimit = true;
    }

    // 2. Quét các điểm Camera / Biển báo trong Forward Cone (< 300m & lệch góc <= 30°)
    TrafficHazardNode? nearestForward;
    double nearestDist = double.infinity;

    for (final hazard in _trafficData.hazards) {
      final cone = evaluateForwardCone(
        vehiclePos: location,
        vehicleHeadingDeg: headingDeg,
        targetPos: hazard.coordinate,
        maxDistanceMeters: defaultAlertDistanceMeters,
        maxBearingDiffDeg: defaultForwardConeHalfAngleDeg,
      );
      if (cone.inCone && cone.distanceMeters < nearestDist) {
        nearestDist = cone.distanceMeters;
        nearestForward = hazard;
      } else if (_announcedHazardIds.contains(hazard.id) && cone.distanceMeters > 450.0) {
        // Khi xe đã đi xa hẳn (> 450m) thì cho phép cảnh báo lại nếu vòng quay lại điểm đó
        _announcedHazardIds.remove(hazard.id);
      }
    }

    // Nếu sắp tới camera có quy định tốc độ rõ ràng, ưu tiên hiển thị giới hạn của camera đó
    if (nearestForward != null &&
        nearestForward.speedLimitKmh != null &&
        nearestForward.speedLimitKmh! > 0) {
      nextLimit = nearestForward.speedLimitKmh!;
      nextHasRoadLimit = true;
    }

    if (nextLimit != _currentSpeedLimitKmh || nextHasRoadLimit != _hasMatchedRoadLimit) {
      _currentSpeedLimitKmh = nextLimit;
      _hasMatchedRoadLimit = nextHasRoadLimit;
      changed = true;
    }

    // 3. Kiểm tra vượt tốc độ (>= 3 km/h so với giới hạn)
    final bool nextOverSpeed = speedKmh >= (_currentSpeedLimitKmh + overSpeedThresholdKmh);
    if (nextOverSpeed != _isOverSpeed) {
      _isOverSpeed = nextOverSpeed;
      changed = true;
    }

    final int? prevDistRounded = _upcomingHazardDistanceM?.round();
    final int? nextDistRounded = nearestForward != null ? nearestDist.round() : null;
    if (_upcomingHazard?.id != nearestForward?.id ||
        (prevDistRounded != null &&
            nextDistRounded != null &&
            (prevDistRounded - nextDistRounded).abs() >= 5) ||
        (prevDistRounded == null) != (nextDistRounded == null)) {
      _upcomingHazard = nearestForward;
      _upcomingHazardDistanceM = nearestForward != null ? nearestDist : null;
      changed = true;
    }

    // 4. Đọc cảnh báo Tiếng Việt đúng 1 lần duy nhất cho mỗi điểm camera/biển báo
    if (speakAlerts && nearestForward != null && !_announcedHazardIds.contains(nearestForward.id)) {
      _announcedHazardIds.add(nearestForward.id);
      final msg = buildVietnameseAlertText(
        nearestForward,
        nearestDist,
        fallbackSpeedLimitKmh: _currentSpeedLimitKmh,
      );
      _speakVietnamese(msg);
    } else if (speakAlerts && nextOverSpeed) {
      final now = DateTime.now();
      if (_lastOverSpeedVoiceAt == null ||
          now.difference(_lastOverSpeedVoiceAt!).inSeconds >= 25) {
        _lastOverSpeedVoiceAt = now;
        _speakVietnamese(
          'Bạn đang vượt quá tốc độ giới hạn $_currentSpeedLimitKmh ki-lô-mét trên giờ, vui lòng giảm tốc độ',
        );
      }
    }

    if (changed) {
      notifyListeners();
    }
  }

  Future<void> _speakVietnamese(String text) async {
    if (!_isVoiceEnabled || text.trim().isEmpty) return;
    try {
      if (_tts != null && _ttsInitialized) {
        await _tts!.stop();
        await _tts!.speak(text.trim());
        return;
      }
    } catch (e) {
      debugPrint('[NavigationAlertEngine] flutter_tts speak error: $e');
    }
    _fallbackSpeaker?.call(text.trim());
  }

  /// Trả về dữ liệu gọn để đính kèm vào gói HUD truyền sang màn hình ESP32 240x240.
  Map<String, dynamic> toEspHudPayload() {
    return {
      'speedLimit': _currentSpeedLimitKmh,
      'isOverSpeed': _isOverSpeed,
      'hazardType': _upcomingHazard?.type.wireKey ?? '',
      'hazardDistM': _upcomingHazardDistanceM?.round() ?? -1,
    };
  }

  @override
  void dispose() {
    try {
      _tts?.stop();
    } catch (_) {}
    super.dispose();
  }
}
