import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/esp_payload.dart';
import '../models/route_model.dart';
import 'apple_maps_service.dart';
import 'ble_service.dart';
import 'goong_service.dart';
import 'mapbox_directions_service.dart';
import 'phone_media_service.dart';

class NavigationManager extends ChangeNotifier {
  final BleService bleService;
  final MapboxDirectionsService _directionsService = MapboxDirectionsService();
  PhoneMediaService? _mediaService;

  // Active navigation state
  bool _isNavigating = false;
  bool _isSimulating = false;
  bool _isRerouting = false;
  bool _isDisposed = false;
  bool _externalBleNavMode = false;
  bool _externalBleHasActiveNav = false;
  int _externalTurnCode = 0;
  double _externalDistanceToTurn = 0.0;
  double _externalTotalDistance = 0.0;
  int _externalEtaMinutes = 0;
  String _externalStreetName = '';
  String? _externalArrivalTime;
  NavRoute? _activeRoute;
  NavRoute? _previewRoute;
  int _currentStepIndex = 0;
  LatLng? _currentLocation;
  LatLng? _rawGpsLocation;
  LatLng? _targetLocation;
  double _gpsAccuracy = 12.0;
  double _lastLiveAccuracyM = 999.0;
  DateTime? _lastAccurateFixTime;
  double _currentSpeedKmh = 0.0;
  double _currentHeading = 0.0;
  double _targetHeading = 0.0;
  double _smoothedHeading = 0.0;
  bool _hasHeadingLock = false;
  double _distanceToNextManeuver = 0.0;
  double _remainingTotalDistance = 0.0;
  int _currentBattery = 85;
  int _remainingEtaMinutes = 0;
  int _consecutiveOffRouteCount = 0;
  int _closestPointIndex = 0;
  double _minSegmentDistance = 0.0;
  double _closestSegmentBearing = 0.0;
  DateTime? _lastRerouteTime;
  DateTime _lastGpsFixTime = DateTime.now();
  DateTime _lastUiNotifyTime = DateTime.now();
  LatLng? _lastSpeedCalcLoc;
  DateTime? _lastSpeedCalcTime;
  LatLng? _lastCourseCalcLoc;

  // Live reverse-geocoded street name under the vehicle
  String _liveReverseStreetName = '';
  LatLng? _lastStreetGeocodeLoc;
  DateTime? _lastStreetGeocodeTime;
  bool _isStreetGeocoding = false;

  // Voice guidance (TTS) state & initial GPS fix tracking
  static const String _prefVoiceKey = 'ysiducnaga_voice_guidance_enabled';
  bool _isVoiceEnabled = true;
  int _lastSpokenStepIndex = -1;
  int _lastSpokenStage = 0; // 0: chưa đọc, 1: báo trước ~180m, 2: báo rẽ ngay <= 45m
  bool _hasInitialLiveGpsFix = false;
  bool _isInitializingGps = false;
  bool _needsLocationPermission = false;
  bool _needsLocationServiceEnabled = false;
  bool _useForceLocationManagerFallback = false;
  String? _gpsStatusMessage;

  StreamSubscription<Position>? _positionStream;
  Timer? _blePushTimer;
  Timer? _simulationTimer;
  Timer? _smoothMotionTimer;
  Timer? _idleHeartbeatTimer;
  int _simulatedPolylineIndex = 0;

  // Callback for MapScreen when location updates to center vehicle (driven at 30 FPS during navigation)
  void Function(LatLng location, double heading)? onLocationChanged;
  // Callback when active route is replaced (e.g. seamless off-route rerouting)
  void Function()? onRouteChanged;

  // Getters
  bool get isNavigating => _isNavigating;
  bool get isSimulating => _isSimulating;
  bool get isRerouting => _isRerouting;
  bool get isExternalBleNavMode => _externalBleNavMode;

  void setExternalBleNavActive(
    bool active, {
    bool hasActiveNav = false,
    int turnCode = 0,
    double distanceToTurn = 0.0,
    double totalDistance = 0.0,
    int etaMinutes = 0,
    String streetName = '',
    String? arrivalTime,
  }) {
    final bool effectiveActiveNav = active && hasActiveNav;
    final int nextTurnCode = effectiveActiveNav ? turnCode : 0;
    final double nextDist = effectiveActiveNav ? distanceToTurn : 0.0;
    final double nextTot = effectiveActiveNav ? totalDistance : 0.0;
    final int nextEta = effectiveActiveNav ? etaMinutes : 0;
    final String nextStreet = effectiveActiveNav ? streetName.trim() : '';
    final String? nextArr =
        effectiveActiveNav && (arrivalTime?.trim().isNotEmpty ?? false)
            ? arrivalTime!.trim()
            : null;

    final bool modeChanged = _externalBleNavMode != active;
    final bool changed = modeChanged ||
        _externalBleHasActiveNav != effectiveActiveNav ||
        _externalTurnCode != nextTurnCode ||
        (_externalDistanceToTurn - nextDist).abs() >= 0.5 ||
        (_externalTotalDistance - nextTot).abs() >= 0.5 ||
        _externalEtaMinutes != nextEta ||
        _externalStreetName != nextStreet ||
        _externalArrivalTime != nextArr;

    _externalBleNavMode = active;
    _externalBleHasActiveNav = effectiveActiveNav;
    _externalTurnCode = nextTurnCode;
    _externalDistanceToTurn = nextDist;
    _externalTotalDistance = nextTot;
    _externalEtaMinutes = nextEta;
    _externalStreetName = nextStreet;
    _externalArrivalTime = nextArr;

    if (modeChanged && !kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      if (active) {
        if (_positionStream != null || !_needsLocationPermission) {
          _startContinuousGpsStream(allowForeground: true);
        } else {
          unawaited(refreshGpsPermissionAndStart(promptIfNeeded: false));
        }
      } else if (!_isNavigating) {
        if (_positionStream != null) {
          _startContinuousGpsStream(allowForeground: false);
        }
      }
    }

    if (active) {
      _targetLocation ??= _currentLocation;
      _targetHeading = _hasHeadingLock ? _smoothedHeading : _currentHeading;
      if (_smoothMotionTimer == null || !_smoothMotionTimer!.isActive) {
        _startSmoothMotionLoop();
      }
    } else if (!_isNavigating && !_isSimulating) {
      _smoothMotionTimer?.cancel();
      _smoothMotionTimer = null;
    }

    if (changed) {
      notifyListeners();
    }
  }

  /// True when an external guidance source (e.g. Google Maps notifications) has active turn data.
  bool get isExternalNavTelemetryActive =>
      _externalBleNavMode && _externalBleHasActiveNav;

  /// True when either built-in turn-by-turn or active external guidance is driving ESP32 Man 3.
  bool get isAnyNavActive => _isNavigating || isExternalNavTelemetryActive;

  int get effectiveTurnCode => _isNavigating
      ? (upcomingStep?.turnCode ?? 0)
      : (isExternalNavTelemetryActive ? _externalTurnCode : 0);

  double get effectiveDistanceToNextManeuver => _isNavigating
      ? _distanceToNextManeuver
      : (isExternalNavTelemetryActive ? _externalDistanceToTurn : 0.0);

  double get effectiveRemainingTotalDistance => _isNavigating
      ? _remainingTotalDistance
      : (isExternalNavTelemetryActive ? _externalTotalDistance : 0.0);

  int get effectiveRemainingEtaMinutes => _isNavigating
      ? _remainingEtaMinutes
      : (isExternalNavTelemetryActive ? _externalEtaMinutes : 1);

  String get effectiveNextStreetName {
    if (_isNavigating) {
      return cleanStreetName(upcomingStep?.streetName ?? currentStreetName);
    }
    if (isExternalNavTelemetryActive && _externalStreetName.isNotEmpty) {
      return cleanStreetName(_externalStreetName);
    }
    return currentStreetName;
  }

  String? get effectiveArrivalTime =>
      (!_isNavigating && isExternalNavTelemetryActive) ? _externalArrivalTime : null;

  /// Route points rendered on the streamed ESP32 map (built-in nav / preview only; empty in Google Maps stream).
  List<LatLng> get effectiveRoutePolylinePoints {
    if (_isNavigating && remainingPolylinePoints.length >= 2) {
      return remainingPolylinePoints;
    }
    if (isExternalNavTelemetryActive) {
      return const <LatLng>[];
    }
    return (_activeRoute ?? _previewRoute)?.polylinePoints ?? const <LatLng>[];
  }

  /// Synthesizes a local upcoming-maneuver guide polyline ahead of the vehicle from external turn telemetry.
  static List<LatLng> computeExternalTurnPreviewPolyline({
    required LatLng origin,
    required double headingDeg,
    required double distanceMeters,
    required int turnCode,
  }) {
    LatLng offsetByMeters(LatLng base, double meters, double bearingDeg) {
      final bRad = bearingDeg * (math.pi / 180.0);
      final latRad = base.latitude * (math.pi / 180.0);
      final cosLat = math.cos(latRad).abs().clamp(0.15, 1.0);
      final dLat = (meters * math.cos(bRad)) / 111320.0;
      final dLon = (meters * math.sin(bRad)) / (111320.0 * cosLat);
      return LatLng(base.latitude + dLat, base.longitude + dLon);
    }

    final bool hasTurnDist = distanceMeters > 0;
    if (turnCode == 0 || turnCode == 1 || !hasTurnDist || distanceMeters > 240.0) {
      final double straightLen =
          hasTurnDist ? distanceMeters.clamp(14.0, 220.0) : 140.0;
      return [origin, offsetByMeters(origin, straightLen, headingDeg)];
    }

    final double leg = distanceMeters.clamp(12.0, 220.0);
    final LatLng turnPt = offsetByMeters(origin, leg, headingDeg);

    if (turnCode == 5) {
      // Smooth U-turn turnaround loop
      final p1 = offsetByMeters(turnPt, 14.0, headingDeg - 85.0);
      final p2 = offsetByMeters(p1, 55.0, headingDeg - 175.0);
      return [origin, turnPt, p1, p2];
    }

    if (turnCode == 9) {
      // Smooth roundabout arc exit
      final r1 = offsetByMeters(turnPt, 16.0, headingDeg - 35.0);
      final r2 = offsetByMeters(r1, 18.0, headingDeg + 25.0);
      final r3 = offsetByMeters(r2, 55.0, headingDeg + 75.0);
      return [origin, turnPt, r1, r2, r3];
    }

    const Map<int, double> turnAngleDeltas = {
      2: 90.0, // right
      3: 40.0, // slight right
      4: 135.0, // sharp right
      6: -90.0, // left
      7: -40.0, // slight left
      8: -135.0, // sharp left
    };
    final double deltaDeg = turnAngleDeltas[turnCode] ?? 0.0;
    if (deltaDeg == 0.0) {
      return [origin, turnPt];
    }
    return [origin, turnPt, offsetByMeters(turnPt, 70.0, headingDeg + deltaDeg)];
  }

  @visibleForTesting
  void debugSetTelemetryKinematics({
    required LatLng location,
    required double headingDeg,
    double speedKmh = 0.0,
  }) {
    _currentLocation = location;
    _currentHeading = headingDeg;
    _smoothedHeading = headingDeg;
    _hasHeadingLock = true;
    _currentSpeedKmh = speedKmh;
  }
  bool get isVoiceEnabled => _isVoiceEnabled;
  bool get hasInitialLiveGpsFix => _hasInitialLiveGpsFix;
  bool get needsLocationPermission => _needsLocationPermission;
  bool get needsLocationServiceEnabled => _needsLocationServiceEnabled;
  String? get gpsStatusMessage => _gpsStatusMessage;
  NavRoute? get activeRoute => _activeRoute;
  NavRoute? get previewRoute => _previewRoute;
  int get closestPointIndex => _closestPointIndex;

  /// Danh sách các điểm polyline còn lại phía trước đầu xe (đã cắt bỏ phần đường đã đi qua)
  List<LatLng> get remainingPolylinePoints {
    final route = _activeRoute;
    if (route == null || route.polylinePoints.isEmpty) return [];
    final pts = route.polylinePoints;
    if (!_isNavigating || _currentLocation == null || pts.length < 2) {
      return pts;
    }
    final segIdx = _closestPointIndex.clamp(0, pts.length - 2);
    return [_currentLocation!, ...pts.sublist(segIdx + 1)];
  }

  void setPreviewRoute(NavRoute? route) {
    _previewRoute = route;
    notifyListeners();
  }
  PhoneMediaService? get mediaService => _mediaService;
  int get currentStepIndex => _currentStepIndex;
  LatLng? get currentLocation => _currentLocation;
  LatLng? get rawGpsLocation => _rawGpsLocation;
  double get gpsAccuracy => _gpsAccuracy;
  double get lastLiveAccuracyM => _lastLiveAccuracyM;
  double get currentSpeedKmh => _currentSpeedKmh;
  double get currentHeading => _currentHeading;
  bool get hasHeadingLock => _hasHeadingLock;
  double get effectiveHeading {
    if (_isNavigating && _hasHeadingLock) {
      return _smoothedHeading;
    }
    if (_isNavigating && _minSegmentDistance <= 32.0 && _closestSegmentBearing > 0.0) {
      return _closestSegmentBearing;
    }
    if (_hasHeadingLock) {
      return _smoothedHeading;
    }
    final targetRoute = _activeRoute ?? _previewRoute;
    if (targetRoute != null && targetRoute.polylinePoints.length >= 2 && _currentLocation != null) {
      final points = targetRoute.polylinePoints;
      final segIdx = _isNavigating ? _closestPointIndex.clamp(0, points.length - 2) : 0;
      final lookPt = _pointAlongPolylineAhead(points, segIdx, _currentLocation!, 22.0);
      final b = const Distance().bearing(_currentLocation!, lookPt);
      if (b != 0.0) return (b + 360.0) % 360.0;
    }
    return _smoothedHeading > 0.0 ? _smoothedHeading : _currentHeading;
  }
  double get distanceToNextManeuver => _distanceToNextManeuver;
  double get remainingTotalDistance => _remainingTotalDistance;
  int get remainingEtaMinutes => _remainingEtaMinutes;

  NavStep? get currentStep {
    if (_activeRoute == null || _activeRoute!.steps.isEmpty) {
      return null;
    }
    final idx = _currentStepIndex.clamp(0, _activeRoute!.steps.length - 1);
    final rawStep = _activeRoute!.steps[idx];

    // Nếu đang ở chặng cuối hướng tới đích nhưng còn cách xa (> 50m),
    // hiển thị "Đi thẳng trên <tên đường>" thay vì báo sớm "Bạn đã đến điểm đích"
    if (rawStep.maneuverType == ManeuverType.arrive && _distanceToNextManeuver > 50.0) {
      final road = currentStreetName;
      return NavStep(
        stepIndex: rawStep.stepIndex,
        instruction: 'Đi thẳng trên $road',
        streetName: road,
        distanceMeters: rawStep.distanceMeters,
        durationSeconds: rawStep.durationSeconds,
        coordinate: rawStep.coordinate,
        maneuverTypeStr: 'straight',
        maneuverModifier: 'straight',
      );
    }
    return rawStep;
  }

  /// Strips verbose Vietnamese navigation instruction prefixes to leave only the clean street name
  static String cleanStreetName(String raw) {
    var s = raw.trim();
    const prefixes = [
      'Bắt đầu di chuyển trên ',
      'Bắt đầu đi từ ',
      'Tiếp tục đi thẳng trên ',
      'Tiếp tục đi theo ',
      'Đi thẳng trên ',
      'Đi thẳng vào ',
      'Rẽ trái vào ',
      'Rẽ phải vào ',
      'Rẽ gắt sang trái vào ',
      'Rẽ gắt sang phải vào ',
      'Chếch sang trái vào ',
      'Chếch sang phải vào ',
      'Quay đầu xe trên ',
      'Nhập làn vào đường ',
      'Rẽ vào lối ra đường ',
      'Đi vào đường nhánh nhập làn ',
      'Đi theo nhánh rẽ bên trái vào ',
      'Đi theo nhánh rẽ bên phải vào ',
      'Qua ',
    ];
    for (final p in prefixes) {
      if (s.toLowerCase().startsWith(p.toLowerCase())) {
        s = s.substring(p.length).trim();
        break;
      }
    }
    return s;
  }

  static bool _isArrivalOrGenericLabel(String s) {
    final lower = s.trim().toLowerCase();
    if (lower.isEmpty ||
        lower == 'đường không tên' ||
        lower == 'đường chính' ||
        lower == 'điểm đến' ||
        lower == 'điểm đến phía trước' ||
        lower.contains('đến điểm đích') ||
        lower.contains('đến điểm đến') ||
        lower.contains('bên phải của bạn') ||
        lower.contains('bên trái của bạn') ||
        lower.startsWith('đích:') ||
        lower.contains('+') ||
        RegExp(r'^\d+$').hasMatch(lower)) {
      return true;
    }
    const adminCities = {
      'hà nội', 'ha noi', 'hanoi', 'thành phố hà nội', 'tp hà nội', 'tp. hà nội',
      'hồ chí minh', 'ho chi minh', 'tp hcm', 'tp.hcm', 'sài gòn', 'sai gon',
      'đà nẵng', 'da nang', 'hải phòng', 'hai phong', 'cần thơ', 'can tho',
      'việt nam', 'vietnam', 'viet nam',
    };
    if (adminCities.contains(lower)) return true;
    return lower.startsWith('quận ') ||
        lower.startsWith('quan ') ||
        lower.startsWith('phường ') ||
        lower.startsWith('phuong ') ||
        lower.startsWith('huyện ') ||
        lower.startsWith('huyen ') ||
        lower.startsWith('thị xã ') ||
        lower.startsWith('thị trấn ') ||
        lower.startsWith('xã ') ||
        lower.startsWith('thành phố ') ||
        lower.startsWith('tp ') ||
        lower.startsWith('tp.') ||
        lower.startsWith('tỉnh ');
  }

  /// Normalizes a road name for compact bottom-pill display (e.g. "Phố Nguyễn Cảnh Dị" -> "Nguyễn Cảnh Dị").
  static String normalizeRoadPillName(String raw) {
    var s = cleanStreetName(raw)
        .replaceFirst(RegExp(r'^(?:Số\s+)?\d+[A-Za-z0-9/\-\.]*\s+(?=[A-Za-zÀ-ỹĐđ])'), '')
        .trim();
    for (final prefix in const ['Phố ', 'Đường ']) {
      if (s.toLowerCase().startsWith(prefix.toLowerCase())) {
        final rest = s.substring(prefix.length).trim();
        // Keep short names like "Đường Láng"; drop redundant prefix on multi-word names.
        if (rest.split(RegExp(r'\s+')).length >= 2) {
          s = rest;
        }
        break;
      }
    }
    return s;
  }

  /// Refreshes the real street name under [loc] using Apple CLGeocoder with Goong fallback.
  Future<void> _refreshCurrentStreetName(LatLng loc, {bool force = false}) async {
    if (!_isNavigating) return;
    final now = DateTime.now();
    if (!force) {
      if (_isStreetGeocoding) return;
      if (_lastStreetGeocodeTime != null &&
          now.difference(_lastStreetGeocodeTime!).inMilliseconds < 4000) {
        return;
      }
      if (_lastStreetGeocodeLoc != null &&
          const Distance().as(LengthUnit.Meter, _lastStreetGeocodeLoc!, loc) < 30.0) {
        return;
      }
    }

    _isStreetGeocoding = true;
    _lastStreetGeocodeTime = now;
    _lastStreetGeocodeLoc = loc;

    try {
      String? resolved = await AppleMapsService.reverseGeocodeStreet(loc);
      resolved ??= await GoongService().reverseGeocodeStreet(loc);
      if (!_isNavigating || resolved == null) return;
      final normalized = normalizeRoadPillName(resolved);
      if (!_isArrivalOrGenericLabel(normalized) && normalized != _liveReverseStreetName) {
        _liveReverseStreetName = normalized;
        notifyListeners();
      }
    } catch (_) {
    } finally {
      _isStreetGeocoding = false;
    }
  }

  /// Returns the clean name of the road currently being traveled on (for the bottom blue pill)
  String get currentStreetName {
    if (_liveReverseStreetName.isNotEmpty && !_isArrivalOrGenericLabel(_liveReverseStreetName)) {
      if (_lastStreetGeocodeLoc == null ||
          _currentLocation == null ||
          const Distance().as(LengthUnit.Meter, _lastStreetGeocodeLoc!, _currentLocation!) <= 300.0) {
        return _liveReverseStreetName;
      }
    }

    final route = _activeRoute ?? _previewRoute;
    if (route != null && route.steps.isNotEmpty) {
      if (_currentStepIndex > 0 && _currentStepIndex <= route.steps.length) {
        final prev = normalizeRoadPillName(route.steps[_currentStepIndex - 1].streetName);
        if (!_isArrivalOrGenericLabel(prev)) {
          return prev;
        }
      }
      final curIdx = _currentStepIndex.clamp(0, route.steps.length - 1);
      final cur = normalizeRoadPillName(route.steps[curIdx].streetName);
      if (!_isArrivalOrGenericLabel(cur)) {
        return cur;
      }
    }
    return 'Đường hiện tại';
  }

  /// Returns the upcoming turn maneuver step (for the top-left black maneuver card)
  NavStep? get upcomingStep => currentStep;

  NavigationManager({required this.bleService, PhoneMediaService? mediaService}) {
    _loadVoicePreference();
    _initGps();
    _startIdleHeartbeat();
    bleService.getBatteryLevel().then((b) => _currentBattery = b);
    if (mediaService != null) {
      attachMediaService(mediaService);
    }
  }

  Future<void> _loadVoicePreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getBool(_prefVoiceKey);
      if (saved != null) {
        _isVoiceEnabled = saved;
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> setVoiceEnabled(bool enabled) async {
    _isVoiceEnabled = enabled;
    if (!enabled && (Platform.isIOS || Platform.isAndroid)) {
      try {
        _locationChannel.invokeMethod('stopGuidance');
      } catch (_) {}
    }
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefVoiceKey, enabled);
    } catch (_) {}
  }

  static String localizeInstructionToVietnamese(
    String raw, {
    String maneuverType = '',
    String? maneuverModifier,
    String streetName = '',
  }) {
    var s = raw.replaceAll(RegExp(r'<[^>]*>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (s.isEmpty) {
      return streetName.isNotEmpty ? 'Tiếp tục đi theo $streetName' : 'Tiếp tục đi thẳng';
    }

    // Translate leading "In 200 m, ..." or "Then ..." clauses cleanly
    s = s.replaceFirst(RegExp(r'^then\s+', caseSensitive: false), '');
    final inDistPrefix = RegExp(
      r'^in\s+(\d+(?:[.,]\d+)?)\s*(m|km|ft|mi|miles)\s*[,:]?\s*(.+)$',
      caseSensitive: false,
    ).firstMatch(s);
    if (inDistPrefix != null) {
      final numStr = inDistPrefix.group(1)!;
      final unit = inDistPrefix.group(2)!.toLowerCase();
      final tailVi = localizeInstructionToVietnamese(
        inDistPrefix.group(3)!,
        maneuverType: maneuverType,
        maneuverModifier: maneuverModifier,
        streetName: streetName,
      );
      final unitVi = unit == 'km' ? 'ki-lô-mét' : (unit == 'm' ? 'mét' : unit);
      return 'Trong $numStr $unitVi, $tailVi';
    }

    // Leave strings intact only if they do NOT contain English direction/routing verbs
    final bool looksEnglishNav = RegExp(
      r'\b(?:head|go straight|proceed|follow|stay on|bear|turn|slight|sharp|keep|continue|make a|at the roundabout|enter the roundabout|exit roundabout|merge|take\b.*?\b(?:exit|ramp)|destination will be|you have arrived|onto|toward)\b',
      caseSensitive: false,
    ).hasMatch(s);
    if (!looksEnglishNav &&
        RegExp(r'[àáạảãâầấậẩẫăằắặẳẵèéẹẻẽêềếệểễìíịỉĩòóọỏõôồốộổỗơờớợởỡùúụủũưừứựửữỳýỵỷỹđ]',
                caseSensitive: false)
            .hasMatch(s)) {
      return s;
    }

    final lower = s.toLowerCase();
    // Handle common English Goong / Google / Valhalla turn templates
    if (lower.contains('your destination') || lower.contains('have arrived')) {
      if (lower.contains('on the left')) return 'Điểm đến sẽ nằm ở bên trái';
      if (lower.contains('on the right')) return 'Điểm đến sẽ nằm ở bên phải';
      return 'Bạn đã đến điểm đến';
    }
    if (lower.contains('destination will be on the left')) {
      return 'Điểm đến sẽ nằm ở bên trái';
    }
    if (lower.contains('destination will be on the right')) {
      return 'Điểm đến sẽ nằm ở bên phải';
    }

    final roundaboutExit = RegExp(
      r'(?:at the roundabout|enter the roundabout).*?(\d+)(?:st|nd|rd|th)?\s+exit(?:\s+(?:onto|to|toward)\s+(.+))?',
      caseSensitive: false,
    ).firstMatch(s);
    if (roundaboutExit != null) {
      final exitNum = roundaboutExit.group(1) ?? '1';
      final road = (roundaboutExit.group(2) ?? streetName).trim();
      return road.isNotEmpty
          ? 'Vào vòng xuyến, đi theo lối ra thứ $exitNum vào $road'
          : 'Vào vòng xuyến, đi theo lối ra thứ $exitNum';
    }

    final uTurnMatch = RegExp(
      r'make a u-turn(?:\s+(?:at|on|onto)\s+(.+))?',
      caseSensitive: false,
    ).firstMatch(s);
    if (uTurnMatch != null) {
      final road = (uTurnMatch.group(1) ?? streetName).trim();
      return road.isNotEmpty ? 'Quay đầu xe tại $road' : 'Quay đầu xe';
    }

    final headMatch = RegExp(
      r'^head\s+(?:north|south|east|west|northeast|northwest|southeast|southwest)\s+(?:(on|toward)\s+(.+))?$',
      caseSensitive: false,
    ).firstMatch(s);
    if (headMatch != null) {
      final prep = (headMatch.group(1) ?? '').toLowerCase();
      var rest = (headMatch.group(2) ?? '').trim();
      rest = rest.replaceAll(RegExp(r'\s+toward\s+', caseSensitive: false), ' về hướng ');
      if (prep == 'toward') return 'Đi về hướng $rest';
      return rest.isNotEmpty ? 'Đi theo $rest' : 'Đi thẳng';
    }

    const prefixRules = <({String pattern, String verb, String prep})>[
      (pattern: r'^(?:turn\s+|bear\s+)?sharp\s+right\b', verb: 'Rẽ gắt sang phải', prep: 'vào'),
      (pattern: r'^(?:turn\s+|bear\s+)?slight\s+right\b', verb: 'Chếch sang phải', prep: 'vào'),
      (pattern: r'^keep\s+right\b', verb: 'Giữ bên phải', prep: 'vào'),
      (pattern: r'^(?:turn|bear)\s+right\b', verb: 'Rẽ phải', prep: 'vào'),
      (pattern: r'^(?:turn\s+|bear\s+)?sharp\s+left\b', verb: 'Rẽ gắt sang trái', prep: 'vào'),
      (pattern: r'^(?:turn\s+|bear\s+)?slight\s+left\b', verb: 'Chếch sang trái', prep: 'vào'),
      (pattern: r'^keep\s+left\b', verb: 'Giữ bên trái', prep: 'vào'),
      (pattern: r'^(?:turn|bear)\s+left\b', verb: 'Rẽ trái', prep: 'vào'),
      (pattern: r'^go\s+straight(?:\s+ahead)?\b', verb: 'Đi thẳng', prep: 'theo'),
      (pattern: r'^(?:continue(?:\s+straight)?|proceed|follow|stay)\b', verb: 'Tiếp tục đi', prep: 'theo'),
      (pattern: r'^merge\b', verb: 'Nhập làn', prep: 'vào'),
      (pattern: r'^exit(?:\s+the)?\s+roundabout\b', verb: 'Ra khỏi vòng xuyến', prep: 'vào'),
      (pattern: r'^take\s+(?:the\s+)?(?:\d+(?:st|nd|rd|th)?\s+)?(?:exit|ramp)(?:\s+(?:\d+[a-z]?))?\b', verb: 'Đi vào lối ra', prep: 'vào'),
    ];

    for (final rule in prefixRules) {
      final re = RegExp(rule.pattern, caseSensitive: false);
      if (!re.hasMatch(s)) continue;
      final rawTail = s.replaceFirst(re, '').trim();
      final bool isToward = RegExp(r'^toward\b', caseSensitive: false).hasMatch(rawTail);
      var tail = rawTail.replaceFirst(
        RegExp(r'^(?:onto|on|to|toward|at)\s+', caseSensitive: false),
        '',
      );
      tail = tail.replaceAll(RegExp(r'\s+toward\s+', caseSensitive: false), ' về hướng ').trim();
      if (tail.isEmpty) {
        return rule.verb == 'Tiếp tục đi' ? 'Tiếp tục đi thẳng' : rule.verb;
      }
      final String joiner = isToward ? 'về hướng' : rule.prep;
      return joiner.isEmpty ? '${rule.verb} $tail' : '${rule.verb} $joiner $tail';
    }

    // Fallback synthesis from maneuverType / maneuverModifier if unmatched English sentence
    if (looksEnglishNav ||
        RegExp(r'^(?:turn|head|continue|keep|make|take|merge|exit|go|bear|pass|proceed|follow|stay)\b',
                caseSensitive: false)
            .hasMatch(s)) {
      final mod = (maneuverModifier ?? '').toLowerCase();
      final mType = maneuverType.toLowerCase();
      final target = streetName.trim();
      final suffix = target.isNotEmpty ? ' vào $target' : '';
      if (mType == 'arrive') return 'Bạn đã đến điểm đến';
      if (mType == 'roundabout' || mType == 'rotary') return 'Đi vào vòng xuyến$suffix';
      if (mod.contains('uturn') || mod.contains('u-turn')) return 'Quay đầu xe$suffix';
      if (mod.contains('sharp right')) return 'Rẽ gắt sang phải$suffix';
      if (mod.contains('slight right')) return 'Chếch sang phải$suffix';
      if (mod.contains('right')) return 'Rẽ phải$suffix';
      if (mod.contains('sharp left')) return 'Rẽ gắt sang trái$suffix';
      if (mod.contains('slight left')) return 'Chếch sang trái$suffix';
      if (mod.contains('left')) return 'Rẽ trái$suffix';
      return target.isNotEmpty ? 'Tiếp tục đi thẳng theo $target' : 'Tiếp tục đi thẳng';
    }

    return s;
  }

  String _viStepPrompt(NavStep step) => localizeInstructionToVietnamese(
        step.instruction,
        maneuverType: step.maneuverTypeStr,
        maneuverModifier: step.maneuverModifier,
        streetName: step.streetName,
      );

  void speakVoicePrompt(String text, {bool force = false}) {
    if ((!_isVoiceEnabled && !force) || text.trim().isEmpty) return;
    final localized = localizeInstructionToVietnamese(text.trim());
    if (Platform.isIOS || Platform.isAndroid) {
      try {
        _locationChannel.invokeMethod('speakGuidance', {'text': localized});
      } catch (_) {}
    }
  }

  Future<({bool usingVietnamese, bool hasOfflineVietnamese, String voiceLocale})?>
      getTtsVoiceStatus() async {
    if (kIsWeb || !Platform.isAndroid) return null;
    try {
      final raw = await _locationChannel.invokeMethod<dynamic>('getTtsStatus');
      if (raw is Map) {
        return (
          usingVietnamese: raw['usingVietnamese'] == true,
          hasOfflineVietnamese: raw['hasOfflineVietnamese'] == true,
          voiceLocale: (raw['voiceLocale']?.toString() ?? ''),
        );
      }
    } catch (_) {}
    return null;
  }

  Future<bool> openVietnameseTtsInstaller() async {
    if (kIsWeb || !Platform.isAndroid) return false;
    try {
      return await _locationChannel.invokeMethod<bool>('installVietnameseTtsData') ?? false;
    } catch (_) {
      return false;
    }
  }

  void testVoiceGuidance() {
    if (_isNavigating && currentStep != null) {
      final dist = _distanceToNextManeuver.round();
      final stepText = _viStepPrompt(currentStep!);
      speakVoicePrompt(
        dist > 30 ? 'Còn $dist mét, $stepText' : stepText,
        force: true,
      );
    } else {
      speakVoicePrompt(
        'Hệ thống dẫn đường ysiducnaga đã sẵn sàng. Sau 150 mét, rẽ phải vào đường chính.',
        force: true,
      );
    }
  }

  void attachMediaService(PhoneMediaService mediaService) {
    _mediaService = mediaService;
    if (mediaService.hasMedia) {
      _currentSongTitle = mediaService.songTitle;
      _currentSongArtist = mediaService.songArtist;
      _isMusicPlaying = mediaService.isPlaying;
    }
    mediaService.onMediaChanged = (title, artist, isPlaying) {
      setSong(title, artist, isPlaying: isPlaying);
    };
  }

  void _startIdleHeartbeat() {
    _idleHeartbeatTimer?.cancel();
    _idleHeartbeatTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!_isNavigating &&
          !(_externalBleNavMode && _externalBleHasActiveNav) &&
          bleService.isConnected) {
        sendPreviewPayloadToEsp32();
      }
    });
  }

  @visibleForTesting
  static double computeAdaptiveSnapLimitMeters(double gpsAccuracyM) =>
      math.max(24.0, (gpsAccuracyM * 1.15).clamp(22.0, 38.0));

  @visibleForTesting
  static bool isAcceptableLastKnownPosition({
    required double accuracyMeters,
    required Duration age,
  }) {
    if (accuracyMeters < 0 || accuracyMeters > 65.0) return false;
    return age <= const Duration(seconds: 60);
  }

  @visibleForTesting
  static bool isReliableLiveGpsFix({
    required double incomingAccuracyM,
    required double recentAccuracyM,
    required int msSinceLastAccurateFix,
  }) {
    if (incomingAccuracyM < 0 || incomingAccuracyM > 150.0) return false;
    if (recentAccuracyM <= 100.0 && incomingAccuracyM > 100.0) return false;
    if (recentAccuracyM <= 25.0 &&
        msSinceLastAccurateFix >= 0 &&
        msSinceLastAccurateFix <= 8000 &&
        incomingAccuracyM > 55.0) {
      return false;
    }
    return true;
  }

  @visibleForTesting
  static LatLng resolveNextIdleLocation({
    required LatLng? currentLocation,
    required bool hasInitialLiveGpsFix,
    required LatLng incomingLocation,
    required double incomingAccuracyM,
    required double previousAccuracyM,
    required double speedKmh,
  }) {
    if (!hasInitialLiveGpsFix || currentLocation == null) {
      return incomingLocation;
    }
    final double distM = const Distance().as(LengthUnit.Meter, currentLocation, incomingLocation);
    final bool significantlySharper =
        incomingAccuracyM > 0 && incomingAccuracyM < previousAccuracyM - 5.0;
    if (distM > 15.0 || significantlySharper || speedKmh >= 5.0) {
      return incomingLocation;
    }
    return _lerpLatLng(currentLocation, incomingLocation, 0.75);
  }

  LocationSettings _buildLocationSettings({
    LocationAccuracy accuracy = LocationAccuracy.bestForNavigation,
    int distanceFilter = 0,
    bool allowForeground = false,
    bool forceLocationManager = false,
  }) {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return AppleSettings(
        accuracy: accuracy,
        // otherNavigation tránh CoreLocation tự bẻ/ghim vị trí vào trục đường ô tô gây lệch lớn khi đứng yên hoặc đi ngõ nhỏ
        activityType: ActivityType.otherNavigation,
        distanceFilter: distanceFilter,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: true,
        allowBackgroundLocationUpdates: true,
      );
    } else if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: accuracy,
        distanceFilter: distanceFilter,
        intervalDuration: const Duration(milliseconds: 500),
        forceLocationManager: forceLocationManager || _useForceLocationManagerFallback,
        foregroundNotificationConfig: allowForeground
            ? const ForegroundNotificationConfig(
                notificationTitle: 'ESP32 Nav đang dẫn đường',
                notificationText: 'Đang truyền lộ trình & bản đồ sang ESP32',
                enableWakeLock: true,
              )
            : null,
      );
    }
    return LocationSettings(
      accuracy: accuracy,
      distanceFilter: distanceFilter,
    );
  }

  @visibleForTesting
  static Position? parseNativeLocationMap(Map<dynamic, dynamic>? raw) {
    if (raw == null) return null;
    final lat = (raw['lat'] as num?)?.toDouble();
    final lng = (raw['lng'] as num?)?.toDouble();
    if (lat == null || lng == null || (lat == 0.0 && lng == 0.0)) return null;
    final acc = ((raw['accuracy'] as num?)?.toDouble() ?? 35.0).clamp(1.0, 500.0);
    final spd = ((raw['speed'] as num?)?.toDouble() ?? 0.0).clamp(0.0, 160.0);
    final brg = (raw['bearing'] as num?)?.toDouble() ?? -1.0;
    final tsMs = (raw['timestampMs'] as num?)?.toInt();
    final ts = tsMs != null && tsMs > 0
        ? DateTime.fromMillisecondsSinceEpoch(tsMs)
        : DateTime.now();
    return Position(
      longitude: lng,
      latitude: lat,
      timestamp: ts,
      accuracy: acc,
      altitude: 0.0,
      altitudeAccuracy: 0.0,
      heading: brg,
      headingAccuracy: 0.0,
      speed: spd,
      speedAccuracy: 0.0,
      hasAccuracy: true,
      hasHeading: brg >= 0.0,
      hasSpeed: spd > 0.0,
    );
  }

  @visibleForTesting
  static double computeFallbackSpeedKmh({
    required double reportedSpeedMs,
    required LatLng? prevLoc,
    required DateTime? prevTime,
    required LatLng newLoc,
    required DateTime newTime,
    required double accuracyM,
  }) {
    if (reportedSpeedMs > 0.25) {
      return (reportedSpeedMs * 3.6).clamp(0.0, 160.0);
    }
    if (prevLoc != null && prevTime != null && accuracyM <= 35.0) {
      final int dtMs = newTime.difference(prevTime).inMilliseconds;
      if (dtMs >= 700 && dtMs <= 8000) {
        final double distM = const Distance().as(LengthUnit.Meter, prevLoc, newLoc);
        final double minMoveM = math.max(3.5, accuracyM * 0.25);
        if (distM >= minMoveM) {
          return ((distM / (dtMs / 1000.0)) * 3.6).clamp(0.0, 160.0);
        }
      }
    }
    return 0.0;
  }

  /// Called periodically during external Google Maps BLE nav to keep live GPS speed fresh
  /// even when background GPS callbacks are throttled by OEM battery managers.
  Future<void> refreshSpeedSampleIfStale() async {
    if (_isNavigating || _isSimulating) return;
    final ageMs = DateTime.now().difference(_lastGpsFixTime).inMilliseconds;
    if (ageMs >= 2000 && !kIsWeb && Platform.isAndroid) {
      await _fetchNativeLocationFallback();
    }
    final afterAgeMs = DateTime.now().difference(_lastGpsFixTime).inMilliseconds;
    if (afterAgeMs > 8000 && _currentSpeedKmh > 0.0) {
      _currentSpeedKmh = 0.0;
      notifyListeners();
    }
  }

  Future<bool> _fetchNativeLocationFallback() async {
    if (!Platform.isAndroid) return false;
    try {
      final raw = await _locationChannel
          .invokeMethod('getNativeCurrentLocation')
          .timeout(const Duration(seconds: 6), onTimeout: () => null);
      if (raw is Map) {
        final pos = parseNativeLocationMap(raw);
        if (pos != null) {
          _ingestLiveGpsPosition(pos, isSingleShot: true);
          return _hasInitialLiveGpsFix;
        }
      }
    } catch (_) {}
    return false;
  }

  Future<void> _initGps() async {
    await refreshGpsPermissionAndStart(promptIfNeeded: true, isStartup: true);
  }

  static Future<T> _withMobileTimeout<T>(
    Future<T> future,
    Duration duration, {
    FutureOr<T> Function()? onTimeout,
  }) {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return future;
    }
    return future.timeout(duration, onTimeout: onTimeout);
  }

  /// Checks/requests GPS permission sequentially (avoiding Android startup dialog races),
  /// verifies Location Services, and starts live GPS acquisition with LocationManager fallback.
  Future<bool> refreshGpsPermissionAndStart({
    bool promptIfNeeded = true,
    bool isStartup = false,
  }) async {
    if (_isInitializingGps) {
      return _hasInitialLiveGpsFix;
    }
    _isInitializingGps = true;
    try {
      Map<String, dynamic> androidPerm = const {};
      if (Platform.isAndroid) {
        androidPerm = promptIfNeeded
            ? await BleService.ensureAndroidPermissions(
                mode: 'location',
                initialStartupOnlyOnce: isStartup,
              )
            : await BleService.getAndroidPermissionStatus();
      }

      LocationPermission permission = await _withMobileTimeout(
        Geolocator.checkPermission(),
        const Duration(seconds: 5),
        onTimeout: () => LocationPermission.denied,
      );
      if (permission == LocationPermission.denied && promptIfNeeded) {
        permission = await _withMobileTimeout(
          Geolocator.requestPermission(),
          const Duration(seconds: 12),
          onTimeout: () => LocationPermission.denied,
        );
      }

      final bool hasPermission = permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse ||
          androidPerm['locationGranted'] == true;

      if (!hasPermission) {
        _needsLocationPermission = true;
        _gpsStatusMessage = 'Chưa có quyền truy cập Vị trí (GPS).';
        _currentLocation ??= const LatLng(21.0285, 105.8542);
        notifyListeners();
        return false;
      }

      _needsLocationPermission = false;

      bool serviceEnabled = true;
      try {
        serviceEnabled = await _withMobileTimeout(
          Geolocator.isLocationServiceEnabled(),
          const Duration(seconds: 3),
          onTimeout: () => androidPerm['locationServiceEnabled'] == true,
        );
      } catch (_) {}

      if (!serviceEnabled && androidPerm['locationServiceEnabled'] != true) {
        _needsLocationServiceEnabled = true;
        _gpsStatusMessage = 'Vị trí (GPS) trên điện thoại đang tắt.';
        notifyListeners();
        // Still attempt native passive/network fix if any provider works
        unawaited(_fetchNativeLocationFallback());
        return false;
      }

      _needsLocationServiceEnabled = false;
      _gpsStatusMessage = null;

      try {
        final lastPos = await _withMobileTimeout<Position?>(
          Geolocator.getLastKnownPosition(),
          const Duration(seconds: 2),
          onTimeout: () => null,
        );
        if (lastPos != null && !_hasInitialLiveGpsFix) {
          final age = DateTime.now().difference(lastPos.timestamp);
          if (isAcceptableLastKnownPosition(
            accuracyMeters: lastPos.accuracy,
            age: age,
          )) {
            _currentLocation = LatLng(lastPos.latitude, lastPos.longitude);
            _rawGpsLocation = _currentLocation;
            onLocationChanged?.call(_currentLocation!, effectiveHeading);
            notifyListeners();
          }
        }
      } catch (_) {}

      _startContinuousGpsStream(allowForeground: _isNavigating || _externalBleNavMode);

      // Race Geolocator single-shot (with forceLocationManager fallback) against Android native LocationManager
      unawaited(
        _withMobileTimeout(
          Geolocator.getCurrentPosition(
            locationSettings: _buildLocationSettings(accuracy: LocationAccuracy.bestForNavigation),
          ),
          const Duration(seconds: 6),
        )
            .then((pos) => _ingestLiveGpsPosition(pos, isSingleShot: true))
            .catchError((_) async {
          if (defaultTargetPlatform == TargetPlatform.android) {
            try {
              final fallbackPos = await _withMobileTimeout(
                Geolocator.getCurrentPosition(
                  locationSettings: _buildLocationSettings(
                    accuracy: LocationAccuracy.high,
                    forceLocationManager: true,
                  ),
                ),
                const Duration(seconds: 6),
              );
              _useForceLocationManagerFallback = true;
              _ingestLiveGpsPosition(fallbackPos, isSingleShot: true);
              return;
            } catch (_) {}
          }
          await _fetchNativeLocationFallback();
        }),
      );

      if (Platform.isAndroid && !_hasInitialLiveGpsFix) {
        unawaited(_fetchNativeLocationFallback());
      }

      return true;
    } catch (_) {
      // Default fallback (Hanoi) in non-GPS/test environments
      _currentLocation ??= const LatLng(21.0285, 105.8542);
      notifyListeners();
      return _hasInitialLiveGpsFix;
    } finally {
      _isInitializingGps = false;
    }
  }

  void _startContinuousGpsStream({
    bool allowForeground = false,
    bool forceLocationManager = false,
  }) {
    _positionStream?.cancel();
    try {
      final settings = _buildLocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        allowForeground: allowForeground,
        forceLocationManager: forceLocationManager,
      );
      _positionStream = Geolocator.getPositionStream(locationSettings: settings).listen(
        (pos) => _ingestLiveGpsPosition(pos),
        onError: (_) {
          if (allowForeground) {
            _startContinuousGpsStream(
              allowForeground: false,
              forceLocationManager: forceLocationManager,
            );
          } else if (!forceLocationManager && defaultTargetPlatform == TargetPlatform.android) {
            _useForceLocationManagerFallback = true;
            _startContinuousGpsStream(
              allowForeground: false,
              forceLocationManager: true,
            );
          } else {
            unawaited(_fetchNativeLocationFallback());
          }
        },
      );
    } catch (_) {
      if (allowForeground) {
        _startContinuousGpsStream(
          allowForeground: false,
          forceLocationManager: forceLocationManager,
        );
      } else if (!forceLocationManager && defaultTargetPlatform == TargetPlatform.android) {
        _useForceLocationManagerFallback = true;
        _startContinuousGpsStream(
          allowForeground: false,
          forceLocationManager: true,
        );
      }
    }
  }

  void _ingestLiveGpsPosition(Position pos, {bool isSingleShot = false}) {
    if (_isSimulating) return;
    final now = DateTime.now();
    final double acc = pos.accuracy;
    final int msSinceAcc = _lastAccurateFixTime == null
        ? 999999
        : now.difference(_lastAccurateFixTime!).inMilliseconds;
    if (!isReliableLiveGpsFix(
      incomingAccuracyM: acc,
      recentAccuracyM: _lastLiveAccuracyM,
      msSinceLastAccurateFix: msSinceAcc,
    )) {
      return;
    }
    final bool isStrictlyNewer = pos.timestamp.isAfter(_lastGpsFixTime.add(const Duration(milliseconds: 450)));
    if (isSingleShot &&
        _hasInitialLiveGpsFix &&
        !isStrictlyNewer &&
        _lastAccurateFixTime != null &&
        acc > _lastLiveAccuracyM + 3.0) {
      return;
    }

    final double prevAcc = _lastLiveAccuracyM;
    final double effectiveAcc = acc > 0 ? acc : prevAcc;
    if (acc > 0) {
      _lastLiveAccuracyM = acc;
      _gpsAccuracy = acc.clamp(3.0, 65.0);
      if (acc <= 25.0) {
        _lastAccurateFixTime = now;
      }
    }

    final rawLoc = LatLng(pos.latitude, pos.longitude);
    _rawGpsLocation = rawLoc;
    final rawSpdKmh = computeFallbackSpeedKmh(
      reportedSpeedMs: pos.speed,
      prevLoc: _lastSpeedCalcLoc,
      prevTime: _lastSpeedCalcTime,
      newLoc: rawLoc,
      newTime: now,
      accuracyM: effectiveAcc,
    );
    _lastSpeedCalcLoc = rawLoc;
    _lastSpeedCalcTime = now;
    // Dừng về 0 ngay khi đứng yên để dead-reckoning không đẩy vị trí vượt quá ngã tư
    final spdKmh = rawSpdKmh < 1.5
        ? 0.0
        : (_currentSpeedKmh == 0.0 ? rawSpdKmh : (_currentSpeedKmh * 0.35 + rawSpdKmh * 0.65));
    final hdg = pos.heading >= 0 ? pos.heading : _currentHeading;
    _lastGpsFixTime = now;

    if (_isNavigating) {
      _hasInitialLiveGpsFix = true;
      _updateUserPosition(rawLoc, spdKmh, hdg);
      return;
    }

    final bool isFirstLiveFix = !_hasInitialLiveGpsFix || _currentLocation == null;
    final int prevRoundedKmh = _currentSpeedKmh.round();
    final nextLoc = resolveNextIdleLocation(
      currentLocation: _targetLocation ?? _currentLocation,
      hasInitialLiveGpsFix: _hasInitialLiveGpsFix,
      incomingLocation: rawLoc,
      incomingAccuracyM: effectiveAcc,
      previousAccuracyM: prevAcc,
      speedKmh: spdKmh,
    );
    _targetLocation = nextLoc;
    if (!_externalBleNavMode ||
        isFirstLiveFix ||
        _currentLocation == null ||
        const Distance().as(LengthUnit.Meter, _currentLocation!, nextLoc) > 45.0) {
      _currentLocation = nextLoc;
    }
    _hasInitialLiveGpsFix = true;
    _currentSpeedKmh = spdKmh;
    final headingState = resolveReliableExternalHeading(
      currentSmoothedHeading: _smoothedHeading,
      currentHasHeadingLock: _hasHeadingLock,
      rawSensorHeading: pos.heading,
      hasSensorHeading: pos.heading >= 0.0,
      speedKmh: spdKmh,
      accuracyM: effectiveAcc,
      prevCourseOrigin: _lastCourseCalcLoc,
      incomingLocation: rawLoc,
    );
    _lastCourseCalcLoc = headingState.nextCourseOrigin;
    _smoothedHeading = headingState.smoothedHeading;
    _targetHeading = headingState.targetHeading;
    _hasHeadingLock = headingState.hasHeadingLock;
    if (headingState.hasHeadingLock) {
      _currentHeading = headingState.targetHeading;
    }
    if (!_externalBleNavMode || isFirstLiveFix) {
      onLocationChanged?.call(_currentLocation!, effectiveHeading);
    }
    final bool speedChanged = _currentSpeedKmh.round() != prevRoundedKmh;
    if (isFirstLiveFix || speedChanged || now.difference(_lastUiNotifyTime).inMilliseconds >= 1500) {
      _lastUiNotifyTime = now;
      notifyListeners();
    }
  }

  /// Filters noisy low-speed GPS bearing spikes and locks heading using displacement course + damped EMA.
  @visibleForTesting
  static ({
    double smoothedHeading,
    double targetHeading,
    bool hasHeadingLock,
    LatLng? nextCourseOrigin,
  }) resolveReliableExternalHeading({
    required double currentSmoothedHeading,
    required bool currentHasHeadingLock,
    required double rawSensorHeading,
    required bool hasSensorHeading,
    required double speedKmh,
    required double accuracyM,
    required LatLng? prevCourseOrigin,
    required LatLng incomingLocation,
  }) {
    LatLng? nextOrigin = prevCourseOrigin;
    if (nextOrigin == null && accuracyM <= 30.0) {
      nextOrigin = incomingLocation;
    }

    double? displacementCourse;
    if (prevCourseOrigin != null && accuracyM <= 25.0) {
      final moveM = const Distance().as(LengthUnit.Meter, prevCourseOrigin, incomingLocation);
      if (moveM >= 7.5) {
        displacementCourse =
            (const Distance().bearing(prevCourseOrigin, incomingLocation) + 360.0) % 360.0;
        nextOrigin = incomingLocation;
      }
    }

    final bool validSensorHeading = hasSensorHeading &&
        rawSensorHeading >= 0.0 &&
        accuracyM <= 30.0 &&
        speedKmh >= 4.5 &&
        (rawSensorHeading > 0.0 || speedKmh >= 7.0);

    // Trust fresh sensor bearing immediately during turns so 1 Hz displacement vectors don't lag turns
    double? candidate;
    if (validSensorHeading) {
      candidate = rawSensorHeading;
    } else if (displacementCourse != null) {
      candidate = displacementCourse;
    }

    if (candidate == null) {
      return (
        smoothedHeading: currentSmoothedHeading,
        targetHeading: currentSmoothedHeading,
        hasHeadingLock: currentHasHeadingLock,
        nextCourseOrigin: nextOrigin,
      );
    }

    if (!currentHasHeadingLock) {
      return (
        smoothedHeading: candidate,
        targetHeading: candidate,
        hasHeadingLock: true,
        nextCourseOrigin: nextOrigin,
      );
    }

    final diff = ((candidate - currentSmoothedHeading + 540.0) % 360.0) - 180.0;
    if (speedKmh < 12.0 && diff.abs() < 5.0) {
      return (
        smoothedHeading: currentSmoothedHeading,
        targetHeading: currentSmoothedHeading,
        hasHeadingLock: true,
        nextCourseOrigin: nextOrigin,
      );
    }

    // Gentle outlier damper only when no displacement confirmed and very slow crawling
    if (speedKmh < 9.0 && displacementCourse == null && diff.abs() > 75.0) {
      final guarded = _lerpAngleDeg(currentSmoothedHeading, candidate, 0.15, maxStepDeg: 4.5);
      return (
        smoothedHeading: guarded,
        targetHeading: guarded,
        hasHeadingLock: true,
        nextCourseOrigin: nextOrigin,
      );
    }

    final double alpha = speedKmh >= 15.0 ? 0.45 : 0.30;
    final double maxStep = speedKmh >= 15.0 ? 45.0 : 24.0;
    final double nextSmoothed =
        _lerpAngleDeg(currentSmoothedHeading, candidate, alpha, maxStepDeg: maxStep);
    return (
      smoothedHeading: nextSmoothed,
      targetHeading: candidate,
      hasHeadingLock: true,
      nextCourseOrigin: nextOrigin,
    );
  }

  /// Nội suy góc ngắn nhất (0..360 độ) có giới hạn tốc độ xoay tối đa mỗi frame để cua góc mượt mà không giật
  static double _lerpAngleDeg(double current, double target, double t, {double maxStepDeg = 6.0}) {
    final diff = ((target - current + 540.0) % 360.0) - 180.0;
    double step = diff * t;
    if (maxStepDeg > 0 && step.abs() > maxStepDeg) {
      step = step.isNegative ? -maxStepDeg : maxStepDeg;
    }
    return (current + step + 360.0) % 360.0;
  }

  /// Nội suy tuyến tính tọa độ LatLng
  static LatLng _lerpLatLng(LatLng a, LatLng b, double t) {
    return LatLng(
      a.latitude + (b.latitude - a.latitude) * t,
      a.longitude + (b.longitude - a.longitude) * t,
    );
  }

  /// Tìm điểm nằm phía trước [lookAheadMeters] dọc theo polyline để tính góc hướng nhìn mượt mà trước khi vào cua
  static LatLng _pointAlongPolylineAhead(
    List<LatLng> pts,
    int segIdx,
    LatLng startPt,
    double lookAheadMeters,
  ) {
    if (pts.isEmpty) return startPt;
    if (pts.length == 1) return pts.first;

    const distCalc = Distance();
    double remaining = lookAheadMeters;
    LatLng cur = startPt;
    int idx = segIdx.clamp(0, pts.length - 2);

    while (idx < pts.length - 1) {
      final nextVertex = pts[idx + 1];
      final segRemaining = distCalc.as(LengthUnit.Meter, cur, nextVertex);
      if (segRemaining >= remaining && segRemaining > 0.05) {
        final f = (remaining / segRemaining).clamp(0.0, 1.0);
        return _lerpLatLng(cur, nextVertex, f);
      }
      remaining -= segRemaining;
      cur = nextVertex;
      idx++;
    }
    return pts.last;
  }

  /// Dịch chuyển vị trí xe tiến về phía trước [advanceMeters] dọc theo các đoạn polyline (Dead-Reckoning 30 FPS)
  static ({LatLng point, int segmentIndex}) _advanceAlongPolyline(
    List<LatLng> pts,
    int segIdx,
    LatLng startPt,
    double advanceMeters,
  ) {
    if (pts.length < 2 || advanceMeters <= 0.001) {
      return (point: startPt, segmentIndex: segIdx.clamp(0, math.max(0, pts.length - 2)));
    }

    const distCalc = Distance();
    double remaining = advanceMeters;
    LatLng cur = startPt;
    int idx = segIdx.clamp(0, pts.length - 2);

    while (idx < pts.length - 1) {
      final nextVertex = pts[idx + 1];
      final segRemaining = distCalc.as(LengthUnit.Meter, cur, nextVertex);
      if (segRemaining >= remaining && segRemaining > 0.05) {
        final f = (remaining / segRemaining).clamp(0.0, 1.0);
        return (point: _lerpLatLng(cur, nextVertex, f), segmentIndex: idx);
      }
      remaining -= segRemaining;
      cur = nextVertex;
      idx++;
    }
    return (point: pts.last, segmentIndex: pts.length - 2);
  }

  static const _locationChannel = MethodChannel('com.ysiduc.esp32_nav/location');

  void _enableBackgroundNavigation() {
    if (Platform.isIOS || Platform.isAndroid) {
      try {
        _locationChannel.invokeMethod('startBackgroundNavigation');
      } catch (_) {}
    }
  }

  void _disableBackgroundNavigation() {
    if (Platform.isIOS || Platform.isAndroid) {
      try {
        _locationChannel.invokeMethod('stopBackgroundNavigation');
      } catch (_) {}
    }
  }

  /// Chọn bước điều hướng đầu tiên thực sự phía trước xe (bỏ qua bước depart 0m ở ngay vị trí xuất phát)
  int _resolveInitialStepIndex(NavRoute route) {
    if (route.steps.length <= 1) return 0;
    final firstStep = route.steps[0];
    if (firstStep.maneuverType == ManeuverType.depart || firstStep.distanceMeters < 12.0) {
      if (route.polylinePoints.isNotEmpty) {
        final d = const Distance().as(LengthUnit.Meter, route.polylinePoints.first, firstStep.coordinate);
        if (d < 20.0) return 1;
      }
      if (firstStep.distanceMeters < 10.0) return 1;
    }
    return 0;
  }

  /// Phép chiếu vuông góc từ vị trí GPS xuống đoạn thẳng [a, b]
  static ({LatLng point, double distanceMeters, double t, double bearingDeg}) _projectPointOnSegment(
    LatLng p,
    LatLng a,
    LatLng b,
  ) {
    final cosLat = math.cos(p.latitude * (math.pi / 180.0));
    final dx = (b.longitude - a.longitude) * cosLat * 111320.0;
    final dy = (b.latitude - a.latitude) * 110540.0;
    final px = (p.longitude - a.longitude) * cosLat * 111320.0;
    final py = (p.latitude - a.latitude) * 110540.0;

    final lenSq = dx * dx + dy * dy;
    final t = lenSq > 0.01 ? ((px * dx + py * dy) / lenSq).clamp(0.0, 1.0) : 0.0;

    final projLat = a.latitude + t * (b.latitude - a.latitude);
    final projLng = a.longitude + t * (b.longitude - a.longitude);
    final distX = px - t * dx;
    final distY = py - t * dy;
    final distMeters = math.sqrt(distX * distX + distY * distY);
    final bearingDeg = lenSq > 0.001 ? ((math.atan2(dx, dy) * (180.0 / math.pi)) + 360.0) % 360.0 : 0.0;

    return (
      point: LatLng(projLat, projLng),
      distanceMeters: distMeters,
      t: t,
      bearingDeg: bearingDeg,
    );
  }

  /// Tìm đoạn polyline gần nhất và khớp (Map-Match) vị trí xe lên lộ trình
  ({LatLng snappedPoint, int segmentIndex, double distanceMeters, double bearingDeg}) _snapToRoute(
    LatLng rawLocation,
    List<LatLng> pts, {
    bool fullRouteScan = false,
  }) {
    if (pts.length < 2) {
      return (
        snappedPoint: rawLocation,
        segmentIndex: 0,
        distanceMeters: 0.0,
        bearingDeg: _currentHeading,
      );
    }

    int bestIdx = _closestPointIndex.clamp(0, pts.length - 2);
    double minScore = double.infinity;
    double bestRawDist = double.infinity;
    LatLng bestPoint = rawLocation;
    double bestBearing = _currentHeading;

    final int startSearch = fullRouteScan ? 0 : math.max(0, _closestPointIndex - 2);
    double cumulativeAheadMeters = 0.0;
    const distCalc = Distance();

    for (int i = startSearch; i < pts.length - 1; i++) {
      final proj = _projectPointOnSegment(rawLocation, pts[i], pts[i + 1]);
      if (i > _closestPointIndex) {
        cumulativeAheadMeters += distCalc.as(LengthUnit.Meter, pts[i - 1], pts[i]);
      }

      // Phạt nhẹ theo khoảng cách dọc tuyến (mét) thay vì chỉ số đỉnh để không bị nhảy cóc qua ngã tư
      double penalty = 0.0;
      if (!fullRouteScan && cumulativeAheadMeters > 65.0) {
        penalty += (cumulativeAheadMeters - 65.0) * 0.12;
      }
      // Nếu đang di chuyển có hướng rõ ràng, phạt các đoạn đường ngược chiều (> 100 độ)
      if (_currentSpeedKmh >= 6.0 && _currentHeading > 0.0) {
        double hDiff = (_currentHeading - proj.bearingDeg).abs() % 360.0;
        if (hDiff > 180.0) hDiff = 360.0 - hDiff;
        if (hDiff > 100.0) {
          penalty += 14.0;
        }
      }

      final score = proj.distanceMeters + penalty;
      if (score < minScore) {
        minScore = score;
        bestRawDist = proj.distanceMeters;
        bestIdx = i;
        bestPoint = proj.point;
        bestBearing = proj.bearingDeg;
      }
    }

    // Nếu khoảng cách ở đoạn phía trước vẫn lớn (> 20m), quét lại toàn bộ tuyến đường để tránh ghim nhầm đoạn song song
    if (bestRawDist > 20.0 && startSearch > 0) {
      for (int i = 0; i < startSearch; i++) {
        final proj = _projectPointOnSegment(rawLocation, pts[i], pts[i + 1]);
        if (proj.distanceMeters < bestRawDist) {
          bestRawDist = proj.distanceMeters;
          bestIdx = i;
          bestPoint = proj.point;
          bestBearing = proj.bearingDeg;
        }
      }
    }

    // Tính góc hướng nhìn vừa phải theo tốc độ (8m - 22m) để xoay camera êm ái qua góc cua mà không văng tâm
    final double lookAheadMeters = (_currentSpeedKmh * 0.35).clamp(8.0, 22.0);
    final LatLng lookAheadPt = _pointAlongPolylineAhead(pts, bestIdx, bestPoint, lookAheadMeters);
    final double dLook = distCalc.as(LengthUnit.Meter, bestPoint, lookAheadPt);
    if (dLook > 1.5) {
      bestBearing = (distCalc.bearing(bestPoint, lookAheadPt) + 360.0) % 360.0;
    }

    return (
      snappedPoint: bestPoint,
      segmentIndex: bestIdx,
      distanceMeters: bestRawDist,
      bearingDeg: bestBearing,
    );
  }

  /// Đồng bộ chỉ số bước rẽ (_currentStepIndex) với vị trí thực tế của xe trên polyline
  /// (Rất quan trọng khi tính lộ trình lúc đang di chuyển: bỏ qua ngay các bước rẽ đã lướt qua trong lúc chờ mạng)
  void _syncStepIndexWithPolylineProgress() {
    final route = _activeRoute;
    if (route == null || route.steps.isEmpty || route.polylinePoints.length < 2) return;
    final pts = route.polylinePoints;
    const distCalc = Distance();

    int newStepIdx = _resolveInitialStepIndex(route);
    for (int s = newStepIdx; s < route.steps.length - 1; s++) {
      final stepCoord = route.steps[s].coordinate;
      int stepVertexIdx = pts.length - 1;
      double minD = double.infinity;
      for (int i = 0; i < pts.length; i++) {
        final d = distCalc.as(LengthUnit.Meter, pts[i], stepCoord);
        if (d < minD) {
          minD = d;
          stepVertexIdx = i;
        }
      }
      if (_closestPointIndex > stepVertexIdx && minD < 35.0) {
        newStepIdx = s + 1;
      } else {
        break;
      }
    }
    _currentStepIndex = newStepIdx.clamp(0, route.steps.length - 1);
  }

  /// Bộ nội suy chuyển động 30 FPS (Dead-Reckoning + Exponential Smoothing)
  /// Giúp vị trí xe, vạch dẫn đường và góc xoay camera trôi mượt 30-60 FPS giữa các lần cập nhật GPS 1Hz
  void _startSmoothMotionLoop() {
    _smoothMotionTimer?.cancel();
    _smoothMotionTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      if (_isSimulating) return;

      // 30 FPS dead-reckoning & heading glide for external Google Maps stream mode
      if (!_isNavigating) {
        if (!_externalBleNavMode || _currentLocation == null) return;
        final now = DateTime.now();
        final msSinceGps = now.difference(_lastGpsFixTime).inMilliseconds;
        final double leadFromRawM = (_rawGpsLocation != null && _targetLocation != null)
            ? const Distance().as(LengthUnit.Meter, _rawGpsLocation!, _targetLocation!)
            : 0.0;
        if (_currentSpeedKmh >= 2.5 &&
            msSinceGps < 1000 &&
            _targetLocation != null &&
            leadFromRawM < 12.0) {
          final double stepMeters = (_currentSpeedKmh / 3.6) * 0.033 * 0.85;
          final double brgRad = effectiveHeading * (math.pi / 180.0);
          final double latRad = _targetLocation!.latitude * (math.pi / 180.0);
          final double dLat = (stepMeters * math.cos(brgRad)) / 111320.0;
          final double dLon =
              (stepMeters * math.sin(brgRad)) / (111320.0 * math.cos(latRad).abs().clamp(0.15, 1.0));
          _targetLocation = LatLng(
            _targetLocation!.latitude + dLat,
            _targetLocation!.longitude + dLon,
          );
        }
        if (_targetLocation != null) {
          final distDelta = const Distance().as(LengthUnit.Meter, _currentLocation!, _targetLocation!);
          if (distDelta > 45.0) {
            _currentLocation = _targetLocation;
          } else if (distDelta > 0.05) {
            _currentLocation = _lerpLatLng(_currentLocation!, _targetLocation!, 0.30);
          }
        }
        if (_hasHeadingLock) {
          _smoothedHeading = _lerpAngleDeg(_smoothedHeading, _targetHeading, 0.22, maxStepDeg: 10.0);
        }
        onLocationChanged?.call(_currentLocation!, effectiveHeading);
        if (now.difference(_lastUiNotifyTime).inMilliseconds >= 200) {
          _lastUiNotifyTime = now;
          notifyListeners();
        }
        return;
      }

      if (_activeRoute == null) return;
      final pts = _activeRoute!.polylinePoints;
      if (pts.length < 2 || _currentLocation == null) return;

      final now = DateTime.now();
      final msSinceGps = now.difference(_lastGpsFixTime).inMilliseconds;
      final double snapLimit = computeAdaptiveSnapLimitMeters(_gpsAccuracy);
      final bool isOnRoute = _minSegmentDistance <= snapLimit;

      // 1. Dead-Reckoning: Dự đoán vị trí tiến lên dọc theo lộ trình dựa trên vận tốc thực tế (< 1.0s & giới hạn <= 12m khỏi GPS thô)
      final double leadFromRawM = (_rawGpsLocation != null && _targetLocation != null)
          ? const Distance().as(LengthUnit.Meter, _rawGpsLocation!, _targetLocation!)
          : 0.0;
      if (isOnRoute &&
          _currentSpeedKmh >= 2.5 &&
          msSinceGps < 1000 &&
          _targetLocation != null &&
          leadFromRawM < 12.0) {
        final double stepMeters = (_currentSpeedKmh / 3.6) * 0.033 * 0.85;
        final adv = _advanceAlongPolyline(pts, _closestPointIndex, _targetLocation!, stepMeters);
        _targetLocation = adv.point;
        _closestPointIndex = adv.segmentIndex;

        final double lookAheadM = (_currentSpeedKmh * 0.35).clamp(8.0, 22.0);
        final lookPt = _pointAlongPolylineAhead(pts, _closestPointIndex, _targetLocation!, lookAheadM);
        final dLook = const Distance().as(LengthUnit.Meter, _targetLocation!, lookPt);
        if (dLook > 1.5) {
          _targetHeading = (const Distance().bearing(_targetLocation!, lookPt) + 360.0) % 360.0;
          _closestSegmentBearing = _targetHeading;
        }
      }

      // 2. Làm mượt vị trí hiển thị (_currentLocation -> _targetLocation)
      if (_targetLocation != null) {
        final distDelta = const Distance().as(LengthUnit.Meter, _currentLocation!, _targetLocation!);
        if (distDelta > 45.0) {
          _currentLocation = _targetLocation;
        } else if (distDelta > 0.05) {
          final blended = _lerpLatLng(_currentLocation!, _targetLocation!, 0.32);
          if (isOnRoute) {
            final proj = _projectPointOnSegment(
              blended,
              pts[_closestPointIndex.clamp(0, pts.length - 2)],
              pts[(_closestPointIndex + 1).clamp(1, pts.length - 1)],
            );
            _currentLocation = proj.point;
          } else {
            _currentLocation = blended;
          }
        }
      }

      // 3. Làm mượt góc xoay camera (_smoothedHeading -> _targetHeading) với giới hạn góc xoay tối đa
      if (_hasHeadingLock) {
        _smoothedHeading = _lerpAngleDeg(_smoothedHeading, _targetHeading, 0.14, maxStepDeg: 4.5);
      } else {
        _smoothedHeading = _targetHeading;
        _hasHeadingLock = true;
      }

      // 4. Đẩy vị trí & góc xoay 30 FPS sang MapScreen để cập nhật camera mượt mà
      onLocationChanged?.call(_currentLocation!, effectiveHeading);

      // 5. Giới hạn tần suất rebuild UI text (km/h, khoảng cách) ở mức 4Hz (250ms) để không làm nghẽn GPU
      if (now.difference(_lastUiNotifyTime).inMilliseconds >= 250) {
        _lastUiNotifyTime = now;
        _updateRemainingMetrics();
        notifyListeners();
      }
    });
  }

  /// Start Real-World Turn-by-Turn Navigation with GPS
  void startNavigation(NavRoute route) {
    stopNavigation();
    _enableBackgroundNavigation();
    _activeRoute = route;
    _isNavigating = true;
    _isSimulating = false;
    _isRerouting = false;
    _closestPointIndex = 0;
    _minSegmentDistance = 0.0;
    _consecutiveOffRouteCount = 0;
    _remainingTotalDistance = route.totalDistanceMeters;
    _remainingEtaMinutes = (route.totalDurationSeconds / 60).round();

    final liveStartLoc = _rawGpsLocation ??
        _currentLocation ??
        (route.polylinePoints.isNotEmpty ? route.polylinePoints.first : route.steps.first.coordinate);
    _currentLocation = liveStartLoc;
    _targetLocation = liveStartLoc;

    // Khớp ngay vị trí xe thực tế lên lộ trình mới (kể cả khi xe đã di chuyển 20-50m trong lúc tính đường)
    if (route.polylinePoints.length >= 2) {
      final snap = _snapToRoute(liveStartLoc, route.polylinePoints, fullRouteScan: true);
      _minSegmentDistance = snap.distanceMeters;
      _closestSegmentBearing = snap.bearingDeg;
      if (snap.distanceMeters <= 45.0) {
        _currentLocation = snap.snappedPoint;
        _targetLocation = snap.snappedPoint;
        _closestPointIndex = snap.segmentIndex;
      }
      _targetHeading = snap.bearingDeg;
      _smoothedHeading = snap.bearingDeg;
      _hasHeadingLock = true;
    }

    _syncStepIndexWithPolylineProgress();

    if (route.steps.isNotEmpty) {
      final targetStep = route.steps[_currentStepIndex.clamp(0, route.steps.length - 1)];
      _distanceToNextManeuver = const Distance().as(LengthUnit.Meter, _currentLocation!, targetStep.coordinate);
      _lastSpokenStepIndex = _currentStepIndex;
      _lastSpokenStage = 0;
      final distM = (_distanceToNextManeuver / 10).round() * 10;
      final stepText = _viStepPrompt(targetStep);
      if (distM > 50) {
        speakVoicePrompt('Bắt đầu dẫn đường. Sau $distM mét, $stepText');
      } else {
        speakVoicePrompt('Bắt đầu dẫn đường. $stepText');
      }
    }

    // Đảm bảo luồng GPS liên tục và bộ nội suy 30 FPS luôn chạy
    _startContinuousGpsStream(allowForeground: true);
    _startSmoothMotionLoop();
    _refreshCurrentStreetName(_currentLocation!, force: true);
    if (_currentLocation != null) {
      _updateUserPosition(liveStartLoc, _currentSpeedKmh, _currentHeading);
    }

    // Start periodic BLE push timer (every 1.0 second)
    _blePushTimer = Timer.periodic(const Duration(milliseconds: 1000), (_) {
      _sendCurrentPayloadToEsp32();
    });

    notifyListeners();
    _sendCurrentPayloadToEsp32();
  }

  /// Start Simulation Mode (glides smoothly along polyline at constant 42 km/h at 30 FPS)
  void startSimulation(NavRoute route) {
    stopNavigation();
    _enableBackgroundNavigation();
    _activeRoute = route;
    _isNavigating = true;
    _isSimulating = true;
    _isRerouting = false;
    _closestPointIndex = 0;
    _minSegmentDistance = 0.0;
    _currentStepIndex = _resolveInitialStepIndex(route);
    _simulatedPolylineIndex = 0;
    _currentSpeedKmh = 42.0; // 42 km/h smooth simulation speed
    _consecutiveOffRouteCount = 0;

    final polyline = route.polylinePoints;
    if (polyline.isEmpty) return;

    _currentLocation = polyline.first;
    _targetLocation = polyline.first;
    double initialHeading = _currentHeading;
    if (polyline.length > 1) {
      final lookPt = _pointAlongPolylineAhead(polyline, 0, polyline.first, 22.0);
      initialHeading = (const Distance().bearing(polyline.first, lookPt) + 360.0) % 360.0;
    }
    _targetHeading = initialHeading;
    _smoothedHeading = initialHeading;
    _closestSegmentBearing = initialHeading;
    _hasHeadingLock = true;
    _lastSpokenStepIndex = _currentStepIndex;
    _lastSpokenStage = 0;
    _refreshCurrentStreetName(_currentLocation!, force: true);
    if (route.steps.isNotEmpty) {
      final firstStep = route.steps[_currentStepIndex.clamp(0, route.steps.length - 1)];
      speakVoicePrompt('Bắt đầu mô phỏng lộ trình. ${_viStepPrompt(firstStep)}');
    }
    _updateUserPosition(polyline.first, 42.0, initialHeading);

    // Chạy mô phỏng ở tốc độ 30 FPS (33ms/tick, mỗi nhịp tiến ~0.39m dọc theo polyline)
    const double metersPerTick = (42.0 / 3.6) * 0.0333;
    _simulationTimer = Timer.periodic(const Duration(milliseconds: 33), (timer) {
      if (_currentLocation == null || polyline.length < 2) return;
      final adv = _advanceAlongPolyline(polyline, _closestPointIndex, _currentLocation!, metersPerTick);
      _currentLocation = adv.point;
      _targetLocation = adv.point;
      _closestPointIndex = adv.segmentIndex;
      _simulatedPolylineIndex = adv.segmentIndex;

      final distToEnd = const Distance().as(LengthUnit.Meter, _currentLocation!, polyline.last);
      if (_closestPointIndex >= polyline.length - 2 && distToEnd < 1.5) {
        timer.cancel();
        _currentLocation = polyline.last;
        _currentStepIndex = _activeRoute!.steps.length - 1;
        _distanceToNextManeuver = 0.0;
        _remainingTotalDistance = 0.0;
        _remainingEtaMinutes = 0;
        _currentSpeedKmh = 0.0;
        speakVoicePrompt('Bạn đã đến điểm đến.');
        onLocationChanged?.call(_currentLocation!, effectiveHeading);
        notifyListeners();
        _sendCurrentPayloadToEsp32();
        return;
      }

      final lookPt = _pointAlongPolylineAhead(polyline, _closestPointIndex, _currentLocation!, 18.0);
      final dLook = const Distance().as(LengthUnit.Meter, _currentLocation!, lookPt);
      if (dLook > 1.0) {
        _targetHeading = (const Distance().bearing(_currentLocation!, lookPt) + 360.0) % 360.0;
        _closestSegmentBearing = _targetHeading;
      }
      _smoothedHeading = _lerpAngleDeg(_smoothedHeading, _targetHeading, 0.14, maxStepDeg: 4.5);
      _currentHeading = _smoothedHeading;

      _updateStepAndMetricsOnTick(_currentLocation!);
      onLocationChanged?.call(_currentLocation!, effectiveHeading);

      final now = DateTime.now();
      if (now.difference(_lastUiNotifyTime).inMilliseconds >= 200) {
        _lastUiNotifyTime = now;
        notifyListeners();
      }
    });

    _blePushTimer = Timer.periodic(const Duration(milliseconds: 1000), (_) {
      _sendCurrentPayloadToEsp32();
    });

    notifyListeners();
  }

  void _updateStepAndMetricsOnTick(LatLng effectiveLoc) {
    if (_activeRoute == null || _activeRoute!.steps.isEmpty) return;
    final pts = _activeRoute!.polylinePoints;
    const distanceCalculator = Distance();

    _currentStepIndex = _currentStepIndex.clamp(0, _activeRoute!.steps.length - 1);
    var targetStep = _activeRoute!.steps[_currentStepIndex];

    double directDistToStep = distanceCalculator.as(
      LengthUnit.Meter,
      effectiveLoc,
      targetStep.coordinate,
    );

    int stepPolyIdx = pts.length - 1;
    double minStepVertexDist = double.infinity;
    for (int i = _closestPointIndex; i < pts.length; i++) {
      final d = distanceCalculator.as(LengthUnit.Meter, pts[i], targetStep.coordinate);
      if (d < minStepVertexDist) {
        minStepVertexDist = d;
        stepPolyIdx = i;
      }
    }

    if (_currentStepIndex < _activeRoute!.steps.length - 1 &&
        (directDistToStep <= 22.0 || (_closestPointIndex > stepPolyIdx && minStepVertexDist < 30.0))) {
      _currentStepIndex++;
      targetStep = _activeRoute!.steps[_currentStepIndex];
      directDistToStep = distanceCalculator.as(
        LengthUnit.Meter,
        effectiveLoc,
        targetStep.coordinate,
      );
      _lastSpokenStepIndex = _currentStepIndex;
      _lastSpokenStage = 0;
      if (directDistToStep > 240.0) {
        final roundedDist = (directDistToStep / 50).round() * 50;
        final viInst = localizeInstructionToVietnamese(
          targetStep.instruction,
          maneuverType: targetStep.maneuverTypeStr,
          maneuverModifier: targetStep.maneuverModifier,
          streetName: targetStep.streetName,
        );
        speakVoicePrompt('Tiếp tục đi $roundedDist mét, sau đó $viInst');
      }
      _refreshCurrentStreetName(effectiveLoc, force: true);
      notifyListeners();
    } else {
      _refreshCurrentStreetName(effectiveLoc);
    }

    final double snapLimit = computeAdaptiveSnapLimitMeters(_gpsAccuracy);
    double distToStep = directDistToStep;
    if (_minSegmentDistance <= snapLimit &&
        pts.length >= 2 &&
        stepPolyIdx > _closestPointIndex &&
        stepPolyIdx < pts.length) {
      double alongM = distanceCalculator.as(
        LengthUnit.Meter,
        effectiveLoc,
        pts[math.min(_closestPointIndex + 1, pts.length - 1)],
      );
      for (int i = _closestPointIndex + 1; i < stepPolyIdx; i++) {
        alongM += distanceCalculator.as(LengthUnit.Meter, pts[i], pts[i + 1]);
      }
      distToStep = alongM;
    }

    _distanceToNextManeuver = distToStep;
    _checkAndSpeakManeuver(targetStep, distToStep);
    _updateRemainingMetrics();
  }

  void _checkAndSpeakManeuver(NavStep targetStep, double distMeters) {
    if (!_isNavigating || !_isVoiceEnabled) return;
    if (_lastSpokenStepIndex != _currentStepIndex) {
      _lastSpokenStepIndex = _currentStepIndex;
      _lastSpokenStage = 0;
    }

    // Chặng cuối: thông báo khi sắp tới đích (<= 30m)
    if (targetStep.maneuverType == ManeuverType.arrive) {
      if (distMeters <= 30.0 && _lastSpokenStage < 2) {
        _lastSpokenStage = 2;
        speakVoicePrompt('Bạn đã đến điểm đến.');
      }
      return;
    }

    final viInst = localizeInstructionToVietnamese(
      targetStep.instruction,
      maneuverType: targetStep.maneuverTypeStr,
      maneuverModifier: targetStep.maneuverModifier,
      streetName: targetStep.streetName,
    );

    // 1. Báo trước khi cách điểm rẽ từ 130m - 200m
    if (distMeters <= 200.0 && distMeters >= 110.0 && _lastSpokenStage < 1) {
      _lastSpokenStage = 1;
      final roundedDist = (distMeters / 10).round() * 10;
      speakVoicePrompt('Còn $roundedDist mét, $viInst');
    }
    // 2. Báo rẽ trực tiếp khi cách điểm rẽ <= 45m
    else if (distMeters <= 45.0 && _lastSpokenStage < 2) {
      _lastSpokenStage = 2;
      speakVoicePrompt(viInst);
    }
  }

  void _updateUserPosition(LatLng rawLocation, double speedKmh, double heading) {
    _currentSpeedKmh = speedKmh.clamp(0.0, 160.0);
    if (heading >= 0.0) {
      _currentHeading = heading;
    }

    if (_activeRoute == null || _activeRoute!.polylinePoints.isEmpty) {
      _currentLocation = rawLocation;
      _targetLocation = rawLocation;
      if (heading >= 0.0) {
        _targetHeading = heading;
        _smoothedHeading = _hasHeadingLock ? _lerpAngleDeg(_smoothedHeading, heading, 0.35) : heading;
        _hasHeadingLock = true;
      }
      onLocationChanged?.call(_currentLocation!, effectiveHeading);
      notifyListeners();
      return;
    }

    final pts = _activeRoute!.polylinePoints;
    final double snapLimit = computeAdaptiveSnapLimitMeters(_gpsAccuracy);

    // 1. Map-Matching (Snap vị trí xe vào vạch dẫn đường với ngưỡng thích ứng theo sai số GPS)
    if (!_isSimulating && pts.length >= 2) {
      final snap = _snapToRoute(rawLocation, pts);
      _minSegmentDistance = snap.distanceMeters;
      _closestSegmentBearing = snap.bearingDeg;

      if (snap.distanceMeters <= snapLimit) {
        _targetLocation = snap.snappedPoint;
        _closestPointIndex = snap.segmentIndex;
        _targetHeading = snap.bearingDeg;
        if (_currentLocation == null) {
          _currentLocation = snap.snappedPoint;
        }
      } else {
        _targetLocation = rawLocation;
        if (heading >= 0.0 && _currentSpeedKmh >= 3.0) {
          _targetHeading = heading;
        }
        if (_currentLocation == null) {
          _currentLocation = rawLocation;
        }
      }
    } else {
      _currentLocation = rawLocation;
      _targetLocation = rawLocation;
      _minSegmentDistance = 0.0;
    }

    if (!_hasHeadingLock && _targetHeading > 0.0) {
      _smoothedHeading = _targetHeading;
      _hasHeadingLock = true;
    }

    final effectiveLoc = _currentLocation ?? _targetLocation ?? rawLocation;
    _updateStepAndMetricsOnTick(effectiveLoc);

    // 2. Kiểm tra đi chệch lộ trình và tính lại đường mượt mà (Auto-Rerouting)
    if (!_isSimulating && !_isRerouting) {
      _checkOffRouteAndReroute(rawLocation);
    }

    notifyListeners();
  }

  /// Tự động tính lại lộ trình nhanh và liền mạch khi người dùng thực sự đi chệch khỏi tuyến đường
  void _checkOffRouteAndReroute(LatLng rawLocation) async {
    if (_activeRoute == null || _activeRoute!.polylinePoints.isEmpty) return;

    // Cooldown 5 giây giữa các lần reroute để tránh tính lại liên tục khi GPS dao động
    if (_lastRerouteTime != null &&
        DateTime.now().difference(_lastRerouteTime!).inMilliseconds < 5000) {
      return;
    }

    double headingDiff = 0.0;
    if (_currentSpeedKmh >= 10.0 && _currentHeading > 0.0 && _closestSegmentBearing > 0.0) {
      headingDiff = (_currentHeading - _closestSegmentBearing).abs() % 360.0;
      if (headingDiff > 180.0) headingDiff = 360.0 - headingDiff;
    }

    // Trừ hao sai số ngang của cảm biến GPS để không báo lệch đường giả trong phố hẹp
    final double accuracyMargin = (_gpsAccuracy * 0.45).clamp(4.0, 18.0);
    final double effectiveOffDist = math.max(0.0, _minSegmentDistance - accuracyMargin);

    final bool isSeverelyOffRoute = _minSegmentDistance > 46.0 && effectiveOffDist > 30.0;
    final bool isModeratelyOffRoute = _minSegmentDistance > 32.0 && effectiveOffDist > 20.0;
    final bool isWrongDirectionOffRoute =
        _minSegmentDistance > 22.0 && _currentSpeedKmh >= 12.0 && headingDiff > 85.0;

    if (isSeverelyOffRoute || isModeratelyOffRoute || isWrongDirectionOffRoute) {
      _consecutiveOffRouteCount++;
      final int requiredCount = isSeverelyOffRoute ? 2 : 3;

      if (_consecutiveOffRouteCount >= requiredCount) {
        _isRerouting = true;
        _consecutiveOffRouteCount = 0;
        _lastRerouteTime = DateTime.now();
        notifyListeners();

        try {
          final destination = _activeRoute!.polylinePoints.last;
          // Lấy vị trí GPS mới nhất tại thời điểm gọi để tính đường chính xác khi đang chạy xe
          final origin = _rawGpsLocation ?? rawLocation;
          final newRoute = await _directionsService.calculateRoute(
            origin,
            destination,
            profile: 'bike',
            bypassCache: true,
          );

          if (newRoute != null && _isNavigating && newRoute.polylinePoints.length >= 2) {
            _activeRoute = newRoute;
            _closestPointIndex = 0;
            // Khớp ngay vị trí hiện tại mới nhất của xe lên lộ trình vừa tính xong
            // (tránh bị giật lùi về vị trí cũ lúc bắt đầu gửi request cách đó 0.5-1 giây!)
            final latestPos = _rawGpsLocation ?? _currentLocation ?? origin;
            final snap = _snapToRoute(latestPos, newRoute.polylinePoints, fullRouteScan: true);
            _minSegmentDistance = snap.distanceMeters;
            _closestSegmentBearing = snap.bearingDeg;
            if (snap.distanceMeters <= 45.0) {
              _currentLocation = snap.snappedPoint;
              _targetLocation = snap.snappedPoint;
              _closestPointIndex = snap.segmentIndex;
              _targetHeading = snap.bearingDeg;
            }
            _syncStepIndexWithPolylineProgress();
            _updateRemainingMetrics();
            _refreshCurrentStreetName(_currentLocation ?? latestPos, force: true);
            _lastSpokenStepIndex = _currentStepIndex;
            _lastSpokenStage = 0;
            if (currentStep != null) {
              speakVoicePrompt('Đã cập nhật lộ trình mới. ${_viStepPrompt(currentStep!)}');
            }
            onRouteChanged?.call();
            onLocationChanged?.call(_currentLocation ?? latestPos, effectiveHeading);
            _sendCurrentPayloadToEsp32();
          }
        } catch (_) {
        } finally {
          _isRerouting = false;
          notifyListeners();
        }
      }
    } else {
      _consecutiveOffRouteCount = 0;
    }
  }

  void _updateRemainingMetrics() {
    if (_activeRoute == null || _currentLocation == null) return;

    final points = _activeRoute!.polylinePoints;
    if (points.isEmpty) return;

    const distanceCalculator = Distance();

    final int segIdx = (_isSimulating ? _simulatedPolylineIndex : _closestPointIndex)
        .clamp(0, math.max(0, points.length - 2));

    // Tính tổng quãng đường còn lại dọc theo các đoạn polyline phía trước xe
    double polylineDist = distanceCalculator.as(
      LengthUnit.Meter,
      _currentLocation!,
      points[math.min(segIdx + 1, points.length - 1)],
    );
    for (int i = segIdx + 1; i < points.length - 1; i++) {
      polylineDist += distanceCalculator.as(LengthUnit.Meter, points[i], points[i + 1]);
    }
    _remainingTotalDistance = polylineDist;

    // Calculate accurate ETA based on initial route duration proportion
    final totalMeters = _activeRoute!.totalDistanceMeters;
    if (totalMeters > 0 && _activeRoute!.totalDurationSeconds > 0) {
      final ratio = (_remainingTotalDistance / totalMeters).clamp(0.0, 1.0);
      _remainingEtaMinutes = ((_activeRoute!.totalDurationSeconds / 60.0) * ratio).round().clamp(1, 999);
    } else {
      final speed = _currentSpeedKmh > 5 ? _currentSpeedKmh : 32.0;
      _remainingEtaMinutes = ((_remainingTotalDistance / 1000.0) / speed * 60.0).round().clamp(1, 999);
    }
  }

  String _currentSongTitle = '';
  String _currentSongArtist = '';
  bool _isMusicPlaying = false;
  String get currentSongTitle => _currentSongTitle;
  String get currentSongArtist => _currentSongArtist;
  bool get isMusicPlaying => _isMusicPlaying;

  void setSong(String title, String artist, {bool isPlaying = true}) {
    _currentSongTitle = title.trim();
    _currentSongArtist = artist.trim();
    _isMusicPlaying = isPlaying;
    sendPreviewPayloadToEsp32();
    notifyListeners();
  }

  /// Construct and transmit the payload to ESP32
  void _sendCurrentPayloadToEsp32() {
    _pushNavigationDataToBle();
  }

  /// Compute upcoming route waypoints rotated to vehicle heading
  /// Returns List of [dx, dy] relative to vehicle where forward is +y and right is +x
  List<List<int>> computeUpcomingRoutePoints() {
    final upcomingPts = <List<int>>[];
    if (_activeRoute == null || _activeRoute!.polylinePoints.isEmpty || _currentLocation == null) {
      return upcomingPts;
    }

    final curLoc = _currentLocation!;
    final points = _activeRoute!.polylinePoints;

    // 1. Find index of closest waypoint on route to current vehicle location
    int closestIdx = 0;
    double minDistanceSq = double.infinity;
    for (int i = 0; i < points.length; i++) {
      final dLat = points[i].latitude - curLoc.latitude;
      final dLon = points[i].longitude - curLoc.longitude;
      final distSq = dLat * dLat + dLon * dLon;
      if (distSq < minDistanceSq) {
        minDistanceSq = distSq;
        closestIdx = i;
      }
    }

    // 2. Rotate to align with vehicle heading so ahead is always UP on handlebars
    final hRad = effectiveHeading * (math.pi / 180.0);
    final cosH = math.cos(hRad);
    final sinH = math.sin(hRad);
    final cosLat = math.cos(curLoc.latitude * (math.pi / 180.0));

    // Adaptive scale so upcoming maneuver fits perfectly in the upper middle of the display
    final dist = distanceToNextManeuver;
    final scale = dist <= 120 ? 0.70 : (dist <= 300 ? 0.48 : 0.32);

    // Anchor point: Vehicle on the road itself [0, 0]
    final roadAnchor = points[closestIdx];
    upcomingPts.add([0, 0]);

    for (int i = closestIdx + 1; i < points.length && upcomingPts.length < 24; i++) {
      final pt = points[i];
      final dNorth = (pt.latitude - roadAnchor.latitude) * 111139.0;
      final dEast = (pt.longitude - roadAnchor.longitude) * 111139.0 * cosLat;

      // Coordinate transformation:
      // xRel (right) = dEast * cos(H) - dNorth * sin(H)
      // yRel (forward) = dNorth * cos(H) + dEast * sin(H)
      final xRel = dEast * cosH - dNorth * sinH;
      final yRel = dNorth * cosH + dEast * sinH;

      final sx = (xRel * scale).round().clamp(-125, 125);
      final sy = (yRel * scale).round().clamp(-125, 125);

      // Only track points advancing forward or sideways, not backwards behind handlebars
      if (sy < -5 && upcomingPts.length > 1) continue;

      final last = upcomingPts.last;
      if ((sx - last[0]).abs() >= 4 || (sy - last[1]).abs() >= 4) {
        upcomingPts.add([sx, sy]);
      }
    }

    return upcomingPts;
  }

  void _pushNavigationDataToBle() {
    if ((!bleService.isConnected && !bleService.isWifiConnected) || _activeRoute == null) return;

    final step = currentStep ?? _activeRoute!.steps.first;
    final upcomingPts = computeUpcomingRoutePoints();

    final now = DateTime.now();
    final h = now.hour.toString().padLeft(2, '0');
    final m = now.minute.toString().padLeft(2, '0');
    final curClock = '$h:$m';

    _currentBattery = bleService.lastKnownBattery;
    final payload = EspNavPayload(
      isNavigating: true,
      turnCode: step.turnCode,
      distanceToTurn: _distanceToNextManeuver.round(),
      totalDistance: _remainingTotalDistance.round(),
      etaMinutes: _remainingEtaMinutes,
      streetName: step.streetName,
      currentSpeed: _currentSpeedKmh.round(),
      stepIndex: _currentStepIndex,
      totalSteps: _activeRoute!.steps.length,
      latitude: _currentLocation?.latitude,
      longitude: _currentLocation?.longitude,
      heading: effectiveHeading.round(),
      routePoints: upcomingPts.isNotEmpty ? upcomingPts : null,
      currentClock: curClock,
      batteryLevel: _currentBattery,
      songTitle: _currentSongTitle,
      songArtist: _currentSongArtist,
      songElapsed: mediaService?.elapsedTime.round() ?? 0,
      songDuration: mediaService?.duration.round() ?? 0,
    );

    bleService.getBatteryLevel().then((b) => _currentBattery = b);
    bleService.sendNavPayload(payload);
  }

  /// Transmit preview / standby telemetry to ESP32 so display shows Clock, ysiduc & Song when not navigating
  void sendPreviewPayloadToEsp32() {
    if (!bleService.isConnected && !bleService.isWifiConnected) return;
    final now = DateTime.now();
    final h = now.hour.toString().padLeft(2, '0');
    final m = now.minute.toString().padLeft(2, '0');
    final curClock = '$h:$m';
    final upcomingPts = _isNavigating ? computeUpcomingRoutePoints() : <List<int>>[];

    _currentBattery = bleService.lastKnownBattery;
    final payload = EspNavPayload(
      isNavigating: _isNavigating,
      turnCode: _isNavigating ? (currentStep?.turnCode ?? 0) : 0,
      distanceToTurn: _isNavigating ? _distanceToNextManeuver.round() : 0,
      totalDistance: _isNavigating ? _remainingTotalDistance.round() : 0,
      etaMinutes: _isNavigating ? _remainingEtaMinutes : 0,
      streetName: _isNavigating ? (currentStep?.streetName.isNotEmpty == true ? currentStep!.streetName : '') : 'Sẵn sàng',
      currentSpeed: _currentSpeedKmh.round(),
      stepIndex: _isNavigating ? _currentStepIndex : 0,
      totalSteps: _isNavigating ? (_activeRoute?.steps.length ?? 1) : 0,
      latitude: _currentLocation?.latitude,
      longitude: _currentLocation?.longitude,
      heading: effectiveHeading.round(),
      routePoints: upcomingPts.isNotEmpty ? upcomingPts : null,
      currentClock: curClock,
      batteryLevel: _currentBattery,
      songTitle: _currentSongTitle,
      songArtist: _currentSongArtist,
      songElapsed: mediaService?.elapsedTime.round() ?? 0,
      songDuration: mediaService?.duration.round() ?? 0,
    );

    bleService.getBatteryLevel().then((b) => _currentBattery = b);
    bleService.sendNavPayload(payload);
  }

  /// Stop active navigation or simulation
  void stopNavigation() {
    _disableBackgroundNavigation();
    if (Platform.isIOS || Platform.isAndroid) {
      try {
        _locationChannel.invokeMethod('stopGuidance');
      } catch (_) {}
    }
    _isNavigating = false;
    _isSimulating = false;
    _isRerouting = false;
    _lastSpokenStepIndex = -1;
    _lastSpokenStage = 0;
    _liveReverseStreetName = '';
    _lastStreetGeocodeLoc = null;
    _lastStreetGeocodeTime = null;
    _isStreetGeocoding = false;
    _activeRoute = null; // Clear active route so minimap returns to standby mode!
    _previewRoute = null; // Also clear preview route to completely remove old route
    _currentStepIndex = 0;
    _closestPointIndex = 0;
    _minSegmentDistance = 0.0;
    _simulatedPolylineIndex = 0;
    _distanceToNextManeuver = 0.0;
    _remainingTotalDistance = 0.0;
    _remainingEtaMinutes = 0;
    _simulationTimer?.cancel();
    _smoothMotionTimer?.cancel();
    _blePushTimer?.cancel();

    // Giữ luồng GPS chạy liên tục để vị trí hiện tại trên bản đồ luôn chuẩn xác khi tìm đường mới
    if (!_isDisposed && _positionStream == null) {
      _startContinuousGpsStream();
    }

    // Send standby idle dashboard packet to ESP32
    sendPreviewPayloadToEsp32();

    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (!_isDisposed) {
      super.notifyListeners();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _idleHeartbeatTimer?.cancel();
    _positionStream?.cancel();
    _positionStream = null;
    stopNavigation();
    super.dispose();
  }
}
