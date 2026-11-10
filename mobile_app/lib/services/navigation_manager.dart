import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import '../models/esp_payload.dart';
import '../models/route_model.dart';
import 'ble_service.dart';
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
  NavRoute? _activeRoute;
  NavRoute? _previewRoute;
  int _currentStepIndex = 0;
  LatLng? _currentLocation;
  double _currentSpeedKmh = 0.0;
  double _currentHeading = 0.0;
  double _distanceToNextManeuver = 0.0;
  double _remainingTotalDistance = 0.0;
  int _currentBattery = 85;
  int _remainingEtaMinutes = 0;
  int _consecutiveOffRouteCount = 0;
  int _closestPointIndex = 0;
  double _minSegmentDistance = 0.0;
  double _closestSegmentBearing = 0.0;
  DateTime? _lastRerouteTime;

  StreamSubscription<Position>? _positionStream;
  Timer? _blePushTimer;
  Timer? _simulationTimer;
  Timer? _idleHeartbeatTimer;
  int _simulatedPolylineIndex = 0;

  // Callback for MapScreen when location updates to center vehicle
  void Function(LatLng location, double heading)? onLocationChanged;

  // Getters
  bool get isNavigating => _isNavigating;
  bool get isSimulating => _isSimulating;
  bool get isRerouting => _isRerouting;
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
  double get currentSpeedKmh => _currentSpeedKmh;
  double get currentHeading => _currentHeading;
  double get effectiveHeading {
    if (_isNavigating && _minSegmentDistance <= 25.0 && _closestSegmentBearing > 0.0) {
      if (_currentSpeedKmh < 4.0 || _currentHeading <= 0.0) {
        return _closestSegmentBearing;
      }
      double diff = (_currentHeading - _closestSegmentBearing).abs() % 360.0;
      if (diff > 180.0) diff = 360.0 - diff;
      if (diff <= 50.0) {
        return _closestSegmentBearing;
      }
    }
    if (_currentHeading > 0.0 && _currentSpeedKmh >= 3.0) {
      return _currentHeading;
    }
    final targetRoute = _activeRoute ?? _previewRoute;
    if (targetRoute != null && targetRoute.polylinePoints.length >= 2 && _currentLocation != null) {
      const distanceCalc = Distance();
      final points = targetRoute.polylinePoints;
      int closestIdx = _isNavigating ? _closestPointIndex.clamp(0, points.length - 1) : 0;
      if (!_isNavigating) {
        double minD = double.infinity;
        for (int i = 0; i < points.length; i++) {
          final d = distanceCalc.as(LengthUnit.Meter, _currentLocation!, points[i]);
          if (d < minD) {
            minD = d;
            closestIdx = i;
          }
        }
      }
      final targetIdx = (closestIdx + 1 < points.length) ? closestIdx + 1 : closestIdx;
      if (targetIdx != closestIdx) {
        final b = distanceCalc.bearing(points[closestIdx], points[targetIdx]);
        return (b + 360.0) % 360.0;
      }
    }
    return _currentHeading;
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
    return lower.isEmpty ||
        lower == 'đường không tên' ||
        lower == 'đường chính' ||
        lower == 'điểm đến' ||
        lower == 'điểm đến phía trước' ||
        lower.contains('đến điểm đích') ||
        lower.contains('đến điểm đến') ||
        lower.contains('bên phải của bạn') ||
        lower.contains('bên trái của bạn') ||
        lower.startsWith('đích:');
  }

  /// Returns the clean name of the road currently being traveled on (for the bottom blue pill)
  String get currentStreetName {
    final route = _activeRoute ?? _previewRoute;
    if (route != null && route.steps.isNotEmpty) {
      if (_currentStepIndex > 0 && _currentStepIndex <= route.steps.length) {
        final prev = cleanStreetName(route.steps[_currentStepIndex - 1].streetName);
        if (!_isArrivalOrGenericLabel(prev)) {
          return prev;
        }
      }
      if (route.summary.isNotEmpty) {
        final sum = cleanStreetName(route.summary);
        if (!_isArrivalOrGenericLabel(sum) && !sum.toLowerCase().contains('apple maps')) {
          return sum;
        }
      }
      final cur = cleanStreetName(route.steps[_currentStepIndex.clamp(0, route.steps.length - 1)].streetName);
      if (!_isArrivalOrGenericLabel(cur)) {
        return cur;
      }
    }
    if (route != null && route.summary.isNotEmpty) {
      final sum = cleanStreetName(route.summary);
      if (!_isArrivalOrGenericLabel(sum)) {
        return sum;
      }
    }
    return 'Đường hiện tại';
  }

  /// Returns the upcoming turn maneuver step (for the top-left black maneuver card)
  NavStep? get upcomingStep => currentStep;

  NavigationManager({required this.bleService, PhoneMediaService? mediaService}) {
    _initGps();
    _startIdleHeartbeat();
    bleService.getBatteryLevel().then((b) => _currentBattery = b);
    if (mediaService != null) {
      attachMediaService(mediaService);
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
      if (!_isNavigating && bleService.isConnected) {
        sendPreviewPayloadToEsp32();
      }
    });
  }

  LocationSettings _buildLocationSettings({
    LocationAccuracy accuracy = LocationAccuracy.bestForNavigation,
    int distanceFilter = 0,
  }) {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return AppleSettings(
        accuracy: accuracy,
        activityType: ActivityType.automotiveNavigation,
        distanceFilter: distanceFilter,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: true,
        allowBackgroundLocationUpdates: true,
      );
    }
    return LocationSettings(
      accuracy: accuracy,
      distanceFilter: distanceFilter,
    );
  }

  Future<void> _initGps() async {
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.always || permission == LocationPermission.whileInUse) {
        final lastPos = await Geolocator.getLastKnownPosition();
        if (lastPos != null) {
          _currentLocation = LatLng(lastPos.latitude, lastPos.longitude);
          notifyListeners();
        }

        _startContinuousGpsStream();
      }
    } catch (_) {
      // Default fallback (Hanoi)
      _currentLocation ??= const LatLng(21.0285, 105.8542);
      notifyListeners();
    }
  }

  void _startContinuousGpsStream() {
    _positionStream?.cancel();
    final settings = _buildLocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0,
    );
    _positionStream = Geolocator.getPositionStream(locationSettings: settings).listen((pos) {
      if (_isSimulating) return;
      final rawLoc = LatLng(pos.latitude, pos.longitude);
      final spdKmh = (pos.speed >= 0 ? pos.speed * 3.6 : 0.0).clamp(0.0, 160.0);
      final hdg = pos.heading >= 0 ? pos.heading : _currentHeading;

      if (_isNavigating) {
        _updateUserPosition(rawLoc, spdKmh, hdg);
      } else {
        _currentLocation = rawLoc;
        _currentSpeedKmh = spdKmh;
        if (pos.heading >= 0 && spdKmh >= 2.0) {
          _currentHeading = pos.heading;
        }
        onLocationChanged?.call(_currentLocation!, effectiveHeading);
        notifyListeners();
      }
    });
  }

  static const _locationChannel = MethodChannel('com.ysiduc.esp32_nav/location');

  void _enableBackgroundNavigation() {
    if (Platform.isIOS) {
      try {
        _locationChannel.invokeMethod('startBackgroundNavigation');
      } catch (_) {}
    }
  }

  void _disableBackgroundNavigation() {
    if (Platform.isIOS) {
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
    List<LatLng> pts,
  ) {
    if (pts.length < 2) {
      return (
        snappedPoint: rawLocation,
        segmentIndex: 0,
        distanceMeters: 0.0,
        bearingDeg: _currentHeading,
      );
    }

    int bestIdx = _closestPointIndex.clamp(0, pts.length - 2);
    double minDist = double.infinity;
    LatLng bestPoint = rawLocation;
    double bestBearing = _currentHeading;

    // Ưu tiên tìm từ đoạn hiện tại về phía trước để không bị nhảy lùi ở các ngã tư
    final int startSearch = math.max(0, _closestPointIndex - 2);
    for (int i = startSearch; i < pts.length - 1; i++) {
      final proj = _projectPointOnSegment(rawLocation, pts[i], pts[i + 1]);
      // Cộng một lượng phạt nhỏ cho các đoạn quá xa phía trước để giữ tính liên tục
      final penalty = (i > _closestPointIndex + 8) ? (i - _closestPointIndex) * 0.4 : 0.0;
      if (proj.distanceMeters + penalty < minDist) {
        minDist = proj.distanceMeters;
        bestIdx = i;
        bestPoint = proj.point;
        bestBearing = proj.bearingDeg;
      }
    }

    // Nếu khoảng cách ở đoạn phía trước vẫn lớn (> 30m), quét lại toàn bộ tuyến đường
    if (minDist > 30.0 && startSearch > 0) {
      for (int i = 0; i < startSearch; i++) {
        final proj = _projectPointOnSegment(rawLocation, pts[i], pts[i + 1]);
        if (proj.distanceMeters < minDist) {
          minDist = proj.distanceMeters;
          bestIdx = i;
          bestPoint = proj.point;
          bestBearing = proj.bearingDeg;
        }
      }
    }

    return (
      snappedPoint: bestPoint,
      segmentIndex: bestIdx,
      distanceMeters: minDist,
      bearingDeg: bestBearing,
    );
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
    _currentStepIndex = _resolveInitialStepIndex(route);
    _consecutiveOffRouteCount = 0;
    _remainingTotalDistance = route.totalDistanceMeters;
    _remainingEtaMinutes = (route.totalDurationSeconds / 60).round();

    if (route.steps.isNotEmpty) {
      final startLoc = _currentLocation ?? (route.polylinePoints.isNotEmpty ? route.polylinePoints.first : route.steps.first.coordinate);
      _currentLocation ??= startLoc;
      final targetStep = route.steps[_currentStepIndex.clamp(0, route.steps.length - 1)];
      _distanceToNextManeuver = const Distance().as(LengthUnit.Meter, startLoc, targetStep.coordinate);
    }

    // Đảm bảo luồng GPS liên tục độ chính xác cao nhất luôn chạy
    _startContinuousGpsStream();
    if (_currentLocation != null) {
      _updateUserPosition(_currentLocation!, _currentSpeedKmh, _currentHeading);
    }

    // Start periodic BLE push timer (every 1.0 second)
    _blePushTimer = Timer.periodic(const Duration(milliseconds: 1000), (_) {
      _sendCurrentPayloadToEsp32();
    });

    notifyListeners();
    _sendCurrentPayloadToEsp32();
  }

  /// Start Simulation Mode (walks through polyline path automatically)
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
    _currentSpeedKmh = 38.0; // 38 km/h mock speed
    _consecutiveOffRouteCount = 0;

    final polyline = route.polylinePoints;
    if (polyline.isEmpty) return;

    _currentLocation = polyline.first;
    double initialHeading = _currentHeading;
    if (polyline.length > 1) {
      initialHeading = const Distance().bearing(polyline[0], polyline[1]);
    }
    _updateUserPosition(polyline.first, 38.0, initialHeading);

    _simulationTimer = Timer.periodic(const Duration(milliseconds: 150), (timer) {
      if (_simulatedPolylineIndex < polyline.length - 1) {
        _simulatedPolylineIndex++;
        _closestPointIndex = _simulatedPolylineIndex.clamp(0, math.max(0, polyline.length - 2));
        final nextCoord = polyline[_simulatedPolylineIndex];

        // Calculate heading
        final prevCoord = _currentLocation ?? nextCoord;
        const distanceCalculator = Distance();
        final dist = distanceCalculator.as(LengthUnit.Meter, prevCoord, nextCoord);

        double heading = _currentHeading;
        if (dist > 1.0) {
          heading = distanceCalculator.bearing(prevCoord, nextCoord);
        }

        _updateUserPosition(nextCoord, 42.0, heading);
      } else {
        // Reached destination in simulation
        timer.cancel();
        _currentStepIndex = _activeRoute!.steps.length - 1;
        _distanceToNextManeuver = 0.0;
        _remainingTotalDistance = 0.0;
        _remainingEtaMinutes = 0;
        _currentSpeedKmh = 0.0;
        notifyListeners();
        _sendCurrentPayloadToEsp32();
      }
    });

    _blePushTimer = Timer.periodic(const Duration(milliseconds: 1000), (_) {
      _sendCurrentPayloadToEsp32();
    });

    notifyListeners();
  }

  void _updateUserPosition(LatLng rawLocation, double speedKmh, double heading) {
    _currentSpeedKmh = speedKmh.clamp(0.0, 160.0);
    if (heading >= 0.0) {
      _currentHeading = heading;
    }

    if (_activeRoute == null || _activeRoute!.polylinePoints.isEmpty) {
      _currentLocation = rawLocation;
      onLocationChanged?.call(_currentLocation!, effectiveHeading);
      notifyListeners();
      return;
    }

    final pts = _activeRoute!.polylinePoints;

    // 1. Map-Matching (Snap vị trí xe vào vạch dẫn đường nếu sai số GPS <= 24m)
    if (!_isSimulating && pts.length >= 2) {
      final snap = _snapToRoute(rawLocation, pts);
      _minSegmentDistance = snap.distanceMeters;
      _closestSegmentBearing = snap.bearingDeg;

      if (snap.distanceMeters <= 24.0) {
        _currentLocation = snap.snappedPoint;
        _closestPointIndex = snap.segmentIndex;
      } else {
        _currentLocation = rawLocation;
      }
    } else {
      _currentLocation = rawLocation;
      _minSegmentDistance = 0.0;
    }

    final effectiveLoc = _currentLocation!;
    onLocationChanged?.call(effectiveLoc, effectiveHeading);

    if (_activeRoute!.steps.isEmpty) return;

    // 2. Tính khoảng cách dọc theo lộ trình tới điểm rẽ tiếp theo và tự động chuyển bước khi đi qua
    const distanceCalculator = Distance();
    _currentStepIndex = _currentStepIndex.clamp(0, _activeRoute!.steps.length - 1);
    var targetStep = _activeRoute!.steps[_currentStepIndex];

    double directDistToStep = distanceCalculator.as(
      LengthUnit.Meter,
      effectiveLoc,
      targetStep.coordinate,
    );

    // Tìm đỉnh polyline tương ứng với bước rẽ hiện tại
    int stepPolyIdx = pts.length - 1;
    double minStepVertexDist = double.infinity;
    for (int i = _closestPointIndex; i < pts.length; i++) {
      final d = distanceCalculator.as(LengthUnit.Meter, pts[i], targetStep.coordinate);
      if (d < minStepVertexDist) {
        minStepVertexDist = d;
        stepPolyIdx = i;
      }
    }

    // Chuyển sang bước tiếp theo khi đã tiến sát <= 22m hoặc đã đi vượt qua đỉnh rẽ trên polyline
    if (_currentStepIndex < _activeRoute!.steps.length - 1 &&
        (directDistToStep <= 22.0 || (_closestPointIndex > stepPolyIdx && minStepVertexDist < 30.0))) {
      _currentStepIndex++;
      targetStep = _activeRoute!.steps[_currentStepIndex];
      directDistToStep = distanceCalculator.as(
        LengthUnit.Meter,
        effectiveLoc,
        targetStep.coordinate,
      );
    }

    _distanceToNextManeuver = directDistToStep;

    // 3. Kiểm tra đi chệch lộ trình và tính lại đường tức thì (Auto-Rerouting)
    if (!_isSimulating && !_isRerouting) {
      _checkOffRouteAndReroute(rawLocation);
    }

    _updateRemainingMetrics();
    notifyListeners();
  }

  /// Tự động tính lại lộ trình nhanh khi người dùng đi sai hướng hoặc lệch khỏi vạch dẫn đường
  void _checkOffRouteAndReroute(LatLng rawLocation) async {
    if (_activeRoute == null || _activeRoute!.polylinePoints.isEmpty) return;

    // Cooldown 3 giây giữa các lần reroute để tránh gọi chồng chéo
    if (_lastRerouteTime != null &&
        DateTime.now().difference(_lastRerouteTime!).inMilliseconds < 3000) {
      return;
    }

    double headingDiff = 0.0;
    if (_currentSpeedKmh >= 8.0 && _currentHeading > 0.0 && _closestSegmentBearing > 0.0) {
      headingDiff = (_currentHeading - _closestSegmentBearing).abs() % 360.0;
      if (headingDiff > 180.0) headingDiff = 360.0 - headingDiff;
    }

    final bool isSeverelyOffRoute = _minSegmentDistance > 35.0;
    final bool isModeratelyOffRoute = _minSegmentDistance > 24.0;
    final bool isWrongDirectionOffRoute =
        _minSegmentDistance > 16.0 && _currentSpeedKmh >= 10.0 && headingDiff > 75.0;

    if (isSeverelyOffRoute || isModeratelyOffRoute || isWrongDirectionOffRoute) {
      _consecutiveOffRouteCount++;
      final int requiredCount = isSeverelyOffRoute ? 1 : 2;

      if (_consecutiveOffRouteCount >= requiredCount) {
        _isRerouting = true;
        _consecutiveOffRouteCount = 0;
        _lastRerouteTime = DateTime.now();
        notifyListeners();

        try {
          final destination = _activeRoute!.polylinePoints.last;
          final newRoute = await _directionsService.calculateRoute(
            rawLocation,
            destination,
            profile: 'bike',
            bypassCache: true,
          );

          if (newRoute != null && _isNavigating) {
            _activeRoute = newRoute;
            _closestPointIndex = 0;
            _minSegmentDistance = 0.0;
            _currentStepIndex = _resolveInitialStepIndex(newRoute);
            _updateRemainingMetrics();
            onLocationChanged?.call(_currentLocation ?? rawLocation, effectiveHeading);
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
      streetName: _isNavigating ? (currentStep?.streetName.isNotEmpty == true ? currentStep!.streetName : '') : 'SAN SANG',
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
    _isNavigating = false;
    _isSimulating = false;
    _isRerouting = false;
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
    _blePushTimer?.cancel();

    // Giữ luồng GPS chạy liên tục để vị trí hiện tại trên bản đồ luôn chuẩn xác khi tìm đường mới
    if (_positionStream == null) {
      _startContinuousGpsStream();
    }

    // Send standby idle dashboard packet to ESP32
    sendPreviewPayloadToEsp32();

    notifyListeners();
  }

  @override
  void dispose() {
    _idleHeartbeatTimer?.cancel();
    _positionStream?.cancel();
    _positionStream = null;
    stopNavigation();
    super.dispose();
  }
}
