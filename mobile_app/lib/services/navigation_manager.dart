import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import '../models/esp_payload.dart';
import '../models/route_model.dart';
import 'background_navigation_coordinator.dart';
import 'ble_service.dart';
import 'off_route_detector.dart';
import 'phone_media_service.dart';
import 'route_geometry.dart';
import 'routing_service.dart';
import 'valhalla_service.dart';
import 'voice_guidance_service.dart';

class NavigationManager extends ChangeNotifier {
  final BleService bleService;
  final RoutingService _routingService;
  PhoneMediaService? _mediaService;
  bool _disposed = false;

  // Active navigation state
  bool _isNavigating = false;
  bool _isSimulating = false;
  bool _isRerouting = false;
  NavRoute? _activeRoute;
  NavRoute? _previewRoute;
  int _currentStepIndex = 0;

  // Explicit Location Concepts (P5.5 Sections 8, 9, 10, 11)
  LatLng? _rawLocation;
  LatLng? _acceptedPhysicalLocation;
  RouteProjection? _matchedProjection;
  LatLng? _matchedLocation;
  double _horizontalAccuracy = 5.0;

  double _currentSpeedKmh = 0.0;
  double _currentHeading = 0.0;
  double _distanceToNextManeuver = 0.0;
  double _remainingTotalDistance = 0.0;
  int _currentBattery = 85;
  int _remainingEtaMinutes = 0;

  // Authoritative Route Geometry & Progress (P5.5 Sections 4, 7, 12, 13, 14)
  RouteGeometry? _activeRouteGeometry;
  double _rawMatchedProgressMeters = 0.0;
  double _displayProgressMeters = 0.0;
  LatLng? _navigationDestination;

  // Off-Route Detector & Reroute Engine (P5.5 Sections 19 - 44)
  final OffRouteDetector _offRouteDetector;
  OffRouteDecision? _lastOffRouteDecision;
  int _rerouteGeneration = 0;
  String _rerouteStatus = 'idle'; // idle, requesting, applied, failed

  // Reroute Latency Diagnostics (P5.5 Section 66 & P5.5.2)
  DateTime? suspectedAt;
  DateTime? confirmedAt;
  DateTime? requestStartedAt;
  DateTime? routeReceivedAt;
  DateTime? rerouteFailedAt;
  DateTime? routeCommittedAt;
  DateTime Function() nowProvider = DateTime.now;

  // Rolling travel vs matched advance for stuck matcher detection (P5.5 Section 27)
  double _recentPhysicalTravelMeters = 0.0;
  double _recentMatchedAdvanceMeters = 0.0;
  LatLng? _previousPhysicalCoordinate;
  double _previousMatchedProgress = 0.0;
  DateTime? _lastRollingResetAt;

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
  void setPreviewRoute(NavRoute? route) {
    _previewRoute = route;
    _routeRevision++;
    notifyListeners();
  }

  PhoneMediaService? get mediaService => _mediaService;
  int get currentStepIndex => _currentStepIndex;

  // Route revision & generation (P5.5.1 Section 7)
  int _routeRevision = 0;
  int get routeRevision => _routeRevision;

  DateTime? _lastLocationUpdateAt;

  // Reroute retry backoff state (P5.5.1 Section 6)
  int _rerouteRetryCount = 0;
  int get rerouteRetryCount => _rerouteRetryCount;

  DateTime? _lastRerouteFailureAt;
  DateTime? get lastRerouteFailureAt => _lastRerouteFailureAt;

  Duration get currentRerouteCooldown {
    if (_rerouteRetryCount <= 0) return Duration.zero;
    final seconds = math.min(30.0, 3.0 * math.pow(2.0, _rerouteRetryCount - 1));
    return Duration(milliseconds: (seconds * 1000).round());
  }

  double get rerouteCooldownRemainingSeconds {
    if (_rerouteStatus != 'cooldown' || _lastRerouteFailureAt == null) return 0.0;
    final now = nowProvider();
    final elapsed = now.difference(_lastRerouteFailureAt!).inMilliseconds / 1000.0;
    final totalSec = currentRerouteCooldown.inMilliseconds / 1000.0;
    return math.max(0.0, totalSec - elapsed);
  }

  // Location Getters
  LatLng? get rawLocation => _rawLocation;
  LatLng? get acceptedPhysicalLocation => _acceptedPhysicalLocation;
  RouteProjection? get matchedProjection => _matchedProjection;
  LatLng? get matchedLocation => _matchedLocation;

  // P5.6 Section 9: When off-route, display physical location to prevent vehicle puck from sticking to old route
  LatLng? get currentLocation {
    if (_lastOffRouteDecision?.state == OffRouteState.confirmed ||
        _lastOffRouteDecision?.state == OffRouteState.suspected) {
      return _acceptedPhysicalLocation ?? _rawLocation ?? _matchedLocation;
    }
    return _matchedLocation ?? _acceptedPhysicalLocation ?? _rawLocation;
  }
  double get horizontalAccuracy => _horizontalAccuracy;

  // Progress Getters
  RouteGeometry? get activeRouteGeometry => _activeRouteGeometry;
  double get rawMatchedProgressMeters => _rawMatchedProgressMeters;
  double get displayProgressMeters => _displayProgressMeters;
  LatLng? get navigationDestination => _navigationDestination;

  // Secondary Reference Route (P5.6 BUG F)
  NavRoute? _secondaryRoute;
  NavRoute? get secondaryRoute => _secondaryRoute;
  List<LatLng> get secondaryPolyline => _secondaryRoute?.polylinePoints ?? const [];

  // Diagnostics Getters
  OffRouteDecision? get lastOffRouteDecision => _lastOffRouteDecision;
  String get rerouteStatus => _rerouteStatus;
  int get rerouteGeneration => _rerouteGeneration;

  // Telemetry Getters (P5.6 Section 12)
  double? get headingDeltaVsRouteDegrees {
    if (_currentHeading < 0.0 || _currentSpeedKmh < 3.0) return null;
    final routeBearing = _matchedProjection?.routeBearingDegrees;
    if (routeBearing == null) return null;
    return OffRouteDetector.angularDifferenceDegrees(effectiveHeading, routeBearing);
  }

  bool get isWrongWayDivergence {
    final d = headingDeltaVsRouteDegrees;
    return d != null && d >= 120.0 && _horizontalAccuracy <= 20.0;
  }

  /// Authoritative remaining polyline starting directly from _displayProgressMeters (Section 14).
  /// Passed vertices are promptly stripped; the first coordinate represents displayProgress.
  List<LatLng> get remainingPolyline {
    if (_activeRouteGeometry == null) {
      return _activeRoute?.polylinePoints ?? const [];
    }
    return _activeRouteGeometry!.trimmedPolyline(_displayProgressMeters);
  }

  double get currentSpeedKmh => _currentSpeedKmh;
  double get currentHeading => _currentHeading;
  double get effectiveHeading {
    if (_currentHeading > 0.0 && _currentSpeedKmh >= 3.0) {
      return _currentHeading;
    }
    if (_matchedProjection != null) {
      return _matchedProjection!.routeBearingDegrees;
    }
    final targetRoute = _activeRoute ?? _previewRoute;
    if (targetRoute != null && targetRoute.polylinePoints.length >= 2 && currentLocation != null) {
      const distanceCalc = Distance();
      final points = targetRoute.polylinePoints;
      int closestIdx = 0;
      double minD = double.infinity;
      for (int i = 0; i < points.length; i++) {
        final d = distanceCalc.as(LengthUnit.Meter, currentLocation!, points[i]);
        if (d < minD) {
          minD = d;
          closestIdx = i;
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
    if (_activeRoute == null || _currentStepIndex >= _activeRoute!.steps.length) {
      return null;
    }
    return _activeRoute!.steps[_currentStepIndex];
  }

  /// Authoritative current/upcoming maneuver for banner & ESP32 synchronization (P5.6 Section 6)
  /// When approaching next turn ahead, the upcoming action is step index + 1
  NavStep? get authoritativeCurrentManeuver {
    if (_activeRoute == null || _activeRoute!.steps.isEmpty) return null;
    if (_currentStepIndex + 1 < _activeRoute!.steps.length) {
      return _activeRoute!.steps[_currentStepIndex + 1];
    }
    return _activeRoute!.steps.last;
  }

  String get bannerInstruction {
    final m = authoritativeCurrentManeuver;
    if (m == null) return 'Tiếp tục đi thẳng';
    if (m.instruction.isNotEmpty) return m.instruction;
    if (m.streetName.isNotEmpty) return 'Đi vào ${m.streetName}';
    return 'Tiếp tục đi thẳng';
  }

  IconData get bannerTurnIcon {
    return authoritativeCurrentManeuver?.icon ?? Icons.arrow_upward_rounded;
  }

  NavigationManager({
    required this.bleService,
    PhoneMediaService? mediaService,
    RoutingService? routingService,
    OffRouteDetector? offRouteDetector,
    DateTime Function()? nowProvider,
  })  : _routingService = routingService ?? ValhallaService(),
        _offRouteDetector = offRouteDetector ?? OffRouteDetector(),
        nowProvider = nowProvider ?? DateTime.now {
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
    int distanceFilter = 2,
  }) {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return AppleSettings(
        accuracy: accuracy,
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
          _rawLocation = LatLng(lastPos.latitude, lastPos.longitude);
          _acceptedPhysicalLocation = _rawLocation;
          if (!_disposed) notifyListeners();
        }

        _positionStream?.cancel();
        final settings = _buildLocationSettings(
          accuracy: LocationAccuracy.medium,
          distanceFilter: 10,
        );
        _positionStream = Geolocator.getPositionStream(locationSettings: settings).listen((pos) {
          final loc = LatLng(pos.latitude, pos.longitude);
          _rawLocation = loc;
          _currentSpeedKmh = pos.speed * 3.6;
          _currentHeading = pos.heading;
          _horizontalAccuracy = pos.accuracy;

          if (_isNavigating) {
            updateUserPositionWithAccuracy(
              loc,
              _currentSpeedKmh,
              _currentHeading,
              horizontalAccuracy: pos.accuracy,
              timestamp: pos.timestamp,
            );
          } else {
            _acceptedPhysicalLocation = loc;
            notifyListeners();
          }
        });
      }
    } catch (_) {
      _rawLocation ??= const LatLng(21.0285, 105.8542);
      _acceptedPhysicalLocation ??= _rawLocation;
      if (!_disposed) notifyListeners();
    }
  }

  void _enableBackgroundNavigation() {
    BackgroundNavigationCoordinator.instance.updateState(isNavigating: true);
  }

  void _disableBackgroundNavigation() {
    BackgroundNavigationCoordinator.instance.updateState(isNavigating: false);
  }

  /// Start Real-World Turn-by-Turn Navigation with GPS
  void startNavigation(NavRoute route) {
    stopNavigation();
    _enableBackgroundNavigation();
    _rerouteGeneration++;
    _routeRevision++;
    _rerouteRetryCount = 0;
    _lastRerouteFailureAt = null;
    _lastLocationUpdateAt = null;
    _activeRoute = route;
    _activeRouteGeometry = RouteGeometry(route.polylinePoints, steps: route.steps);
    // Freeze destination across all potential reroutes (Section 35)
    _navigationDestination = route.polylinePoints.isNotEmpty ? route.polylinePoints.last : null;

    final beginDists = _activeRouteGeometry!.maneuverBeginDistancesAlongRoute;
    if (beginDists.length > 1) {
      _distanceToNextManeuver = beginDists[1];
    } else {
      _distanceToNextManeuver = _activeRouteGeometry!.totalDistanceMeters;
    }

    _isNavigating = true;
    _isSimulating = false;
    _isRerouting = false;
    _rerouteStatus = 'idle';
    _currentStepIndex = 0;
    _displayProgressMeters = 0.0;
    _rawMatchedProgressMeters = 0.0;
    _recentPhysicalTravelMeters = 0.0;
    _recentMatchedAdvanceMeters = 0.0;
    _previousPhysicalCoordinate = null;
    _previousMatchedProgress = 0.0;
    _lastRollingResetAt = DateTime.now();

    suspectedAt = null;
    confirmedAt = null;
    requestStartedAt = null;
    routeReceivedAt = null;
    rerouteFailedAt = null;
    routeCommittedAt = null;

    _offRouteDetector.reset();
    _remainingTotalDistance = route.totalDistanceMeters;
    _remainingEtaMinutes = (route.totalDurationSeconds / 60).round();

    // Start location tracking with iOS background execution enabled
    final locationSettings = _buildLocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 2,
    );

    _positionStream = Geolocator.getPositionStream(locationSettings: locationSettings).listen((pos) {
      updateUserPositionWithAccuracy(
        LatLng(pos.latitude, pos.longitude),
        pos.speed * 3.6,
        pos.heading,
        horizontalAccuracy: pos.accuracy,
        timestamp: pos.timestamp,
      );
    });

    _blePushTimer = Timer.periodic(const Duration(milliseconds: 1200), (_) {
      _sendCurrentPayloadToEsp32();
    });

    notifyListeners();
    _sendCurrentPayloadToEsp32();

    VoiceGuidanceService().announceTripStart(
      route.title.isNotEmpty ? route.title : (currentStep?.streetName ?? 'Điểm đến'),
      route.totalDistanceMeters / 1000.0,
      (route.totalDurationSeconds / 60).round(),
    );
  }

  /// Start Simulation Mode (walks through polyline path automatically)
  void startSimulation(NavRoute route) {
    stopNavigation();
    _enableBackgroundNavigation();
    _rerouteGeneration++;
    _routeRevision++;
    _rerouteRetryCount = 0;
    _lastRerouteFailureAt = null;
    _lastLocationUpdateAt = null;
    _activeRoute = route;
    _activeRouteGeometry = RouteGeometry(route.polylinePoints, steps: route.steps);
    _navigationDestination = route.polylinePoints.isNotEmpty ? route.polylinePoints.last : null;

    _isNavigating = true;
    _isSimulating = true;
    _isRerouting = false;
    _rerouteStatus = 'idle';
    _currentStepIndex = 0;
    _simulatedPolylineIndex = 0;
    _displayProgressMeters = 0.0;
    _rawMatchedProgressMeters = 0.0;
    _currentSpeedKmh = 38.0;

    final polyline = route.polylinePoints;
    if (polyline.isEmpty) return;

    _rawLocation = polyline.first;
    _acceptedPhysicalLocation = _rawLocation;
    _matchedLocation = _rawLocation;
    _updateRemainingMetrics();

    _simulationTimer = Timer.periodic(const Duration(milliseconds: 150), (timer) {
      if (_simulatedPolylineIndex < polyline.length - 1) {
        _simulatedPolylineIndex++;
        final nextCoord = polyline[_simulatedPolylineIndex];

        final prevCoord = currentLocation ?? nextCoord;
        const distanceCalculator = Distance();
        final dist = distanceCalculator.as(LengthUnit.Meter, prevCoord, nextCoord);

        double heading = _currentHeading;
        if (dist > 1.0) {
          heading = distanceCalculator.bearing(prevCoord, nextCoord);
        }

        updateUserPositionWithAccuracy(
          nextCoord,
          42.0,
          heading,
          horizontalAccuracy: 5.0,
        );
      } else {
        timer.cancel();
        _currentStepIndex = _activeRoute!.steps.length - 1;
        _distanceToNextManeuver = 0.0;
        _remainingTotalDistance = 0.0;
        _remainingEtaMinutes = 0;
        _currentSpeedKmh = 0.0;
        _secondaryRoute = null;
        VoiceGuidanceService().announceArrival(_activeRoute?.title);
        notifyListeners();
        _sendCurrentPayloadToEsp32();
      }
    });

    _blePushTimer = Timer.periodic(const Duration(milliseconds: 1000), (_) {
      _sendCurrentPayloadToEsp32();
    });

    notifyListeners();

    VoiceGuidanceService().announceTripStart(
      route.title.isNotEmpty ? route.title : (currentStep?.streetName ?? 'Điểm đến'),
      route.totalDistanceMeters / 1000.0,
      (route.totalDurationSeconds / 60).round(),
    );
  }

  /// Core location update pipeline handling accuracy gating, map matching,
  /// monotonic progress tracking, step boundary advancement, and multi-signal off-route evaluation.
  void updateUserPositionWithAccuracy(
    LatLng newLocation,
    double speedKmh,
    double heading, {
    double horizontalAccuracy = 5.0,
    DateTime? timestamp,
  }) {
    final sampleTime = timestamp ?? nowProvider();
    _rawLocation = newLocation;
    _horizontalAccuracy = horizontalAccuracy;
    _currentSpeedKmh = speedKmh.clamp(0.0, 160.0);
    _currentHeading = heading;

    // GPS ACCURACY GATING (Section 10)
    // During active navigation, reject highly unreliable samples (accuracy > 20m)
    // from forcing route progress or off-route confirmation.
    if (_isNavigating && !_isSimulating && horizontalAccuracy > 20.0) {
      notifyListeners();
      return;
    }

    _acceptedPhysicalLocation = newLocation;

    if (_activeRoute == null || _activeRouteGeometry == null) {
      _lastLocationUpdateAt = sampleTime;
      onLocationChanged?.call(newLocation, effectiveHeading);
      notifyListeners();
      return;
    }

    final geom = _activeRouteGeometry!;

    // 1. ROUTE MATCHING (Sections 6, 8, 11)
    final matched = geom.matchLocation(
      newLocation,
      lastProjection: _matchedProjection,
    );

    if (matched != null) {
      _matchedProjection = matched;
      _matchedLocation = matched.coordinate;
      _rawMatchedProgressMeters = matched.distanceAlongRouteMeters;

      // PROGRESS ACCEPTANCE GATING (P5.5.1 Section 4)
      // Guard against impossible forward jumps due to GPS noise or distant parallel route snapping
      final deltaProgress = matched.distanceAlongRouteMeters - _displayProgressMeters;
      bool acceptForwardProgress = true;
      if (deltaProgress > 0 && _lastLocationUpdateAt != null) {
        final deltaSeconds = math.max(0.1, sampleTime.difference(_lastLocationUpdateAt!).inMilliseconds / 1000.0);
        final speedMps = _currentSpeedKmh / 3.6;
        final maxPlausibleForwardJump = math.max(60.0, (speedMps * 1.5 + 35.0) * math.max(1.0, deltaSeconds));
        if (deltaProgress > maxPlausibleForwardJump) {
          acceptForwardProgress = false;
        }
      }

      // 2. MONOTONIC DISPLAY PROGRESS (Sections 12, 13)
      // Display progress must NOT move backwards on GPS noise, nor leap forward impossibly
      if (acceptForwardProgress) {
        _displayProgressMeters = math.max(_displayProgressMeters, matched.distanceAlongRouteMeters);
      }
    } else {
      _matchedLocation = newLocation;
    }

    _lastLocationUpdateAt = sampleTime;

    onLocationChanged?.call(currentLocation ?? newLocation, effectiveHeading);

    // 3. ADVANCE MANEUVER STEPS BASED ON ROUTE PROGRESS (Sections 45 - 48)
    if (_activeRoute!.steps.isNotEmpty) {
      final beginDists = geom.maneuverBeginDistancesAlongRoute;
      while (_currentStepIndex < _activeRoute!.steps.length - 1 &&
          _currentStepIndex + 1 < beginDists.length &&
          _displayProgressMeters >= beginDists[_currentStepIndex + 1]) {
        _currentStepIndex++;
      }

      if (_currentStepIndex + 1 < beginDists.length) {
        _distanceToNextManeuver =
            math.max(0.0, beginDists[_currentStepIndex + 1] - _displayProgressMeters);
      } else {
        _distanceToNextManeuver =
            math.max(0.0, geom.totalDistanceMeters - _displayProgressMeters);
      }
    }

    // 4. OFF-ROUTE EVALUATION (Sections 19 - 31)
    if (!_isSimulating) {
      _evaluateOffRoute(newLocation, sampleTime);
    }

    // 5. UPDATE REMAINING METRICS (Sections 49, 50)
    _updateRemainingMetrics();

    // Voice announcement check for turns & maneuvers
    if (_currentStepIndex < _activeRoute!.steps.length) {
      final activeStep = _activeRoute!.steps[_currentStepIndex];
      VoiceGuidanceService().checkAndAnnounceManeuver(
        step: activeStep,
        distanceMeters: _distanceToNextManeuver,
        stepIndex: _currentStepIndex,
      );
    }

    notifyListeners();
  }

  void _evaluateOffRoute(LatLng physicalLocation, DateTime sampleTime) {
    if (_activeRouteGeometry == null) return;
    final geom = _activeRouteGeometry!;

    // Pure Euclidean nearest projection to route for physical distance evidence (Section 20)
    final physicalNearest = geom.nearestProjection(physicalLocation);

    // Rolling window update for stuck matcher detection (Section 27)
    if (_previousPhysicalCoordinate != null) {
      final dPhysical = RouteGeometry.distanceBetween(_previousPhysicalCoordinate!, physicalLocation);
      _recentPhysicalTravelMeters += dPhysical;
      final dAdvance = math.max(0.0, _displayProgressMeters - _previousMatchedProgress);
      _recentMatchedAdvanceMeters += dAdvance;
    }
    _previousPhysicalCoordinate = physicalLocation;
    _previousMatchedProgress = _displayProgressMeters;

    final now = sampleTime;
    _lastRollingResetAt ??= now;
    if (now.difference(_lastRollingResetAt!).inSeconds >= 10 || _recentPhysicalTravelMeters > 100.0) {
      _recentPhysicalTravelMeters = 0.0;
      _recentMatchedAdvanceMeters = 0.0;
      _lastRollingResetAt = now;
    }

    final isMatcherStuck = _recentPhysicalTravelMeters >= 30.0 && _recentMatchedAdvanceMeters < 5.0;

    final observation = OffRouteObservation(
      timestamp: sampleTime,
      matchedProjectionLateralDistanceMeters: _matchedProjection?.lateralDistanceMeters ?? 0.0,
      rawPhysicalRouteDistanceMeters: physicalNearest?.lateralDistanceMeters ?? 0.0,
      horizontalAccuracyMeters: _horizontalAccuracy,
      speedMetersPerSecond: _currentSpeedKmh / 3.6,
      courseDegrees: effectiveHeading,
      routeBearingDegrees: _matchedProjection?.routeBearingDegrees ?? physicalNearest?.routeBearingDegrees,
      distanceAlongRouteMeters: _displayProgressMeters,
      physicalTravelMeters: _recentPhysicalTravelMeters,
      matchedAdvanceMeters: _recentMatchedAdvanceMeters,
      isMatcherStuck: isMatcherStuck,
    );

    final decision = _offRouteDetector.evaluate(observation);
    _lastOffRouteDecision = decision;

    if (decision.state == OffRouteState.suspected && suspectedAt == null) {
      suspectedAt = sampleTime;
    } else if (decision.recovered || decision.state == OffRouteState.onRoute) {
      suspectedAt = null;
      confirmedAt = null;
      if (_rerouteRetryCount > 0) {
        _rerouteRetryCount = 0;
        _lastRerouteFailureAt = null;
        rerouteFailedAt = null;
        if (_rerouteStatus != 'requesting') {
          _rerouteStatus = 'idle';
        }
      }
    }

    if (decision.becameConfirmed || (decision.state == OffRouteState.confirmed && !_isRerouting)) {
      confirmedAt ??= sampleTime;

      // Cooldown / Backoff check (P5.5.1 Section 6, P5.5.2)
      if (_lastRerouteFailureAt != null) {
        final elapsedSinceFailure = nowProvider().difference(_lastRerouteFailureAt!);
        if (elapsedSinceFailure < currentRerouteCooldown) {
          _rerouteStatus = 'cooldown';
          notifyListeners();
          return;
        }
      }

      _triggerValhallaReroute(physicalLocation, sampleTime);
    }
  }

  /// Triggers single-flight Valhalla motorcycle reroute (Sections 32 - 44).
  /// Route A remains active and continues to progress and trim until Route B succeeds.
  void _triggerValhallaReroute(LatLng physicalLocation, DateTime requestTime) {
    if (_isRerouting || !_isNavigating || _navigationDestination == null) {
      return;
    }

    _isRerouting = true;
    _rerouteStatus = 'requesting';
    requestStartedAt = requestTime;
    final generation = ++_rerouteGeneration;

    VoiceGuidanceService().announceReroute();
    notifyListeners();

    _routingService.calculateSingleRoute(
      physicalLocation,
      _navigationDestination!,
      costing: 'motorcycle',
    ).then((newRoute) {
      final completionTime = nowProvider();

      if (_disposed || !_isNavigating || generation != _rerouteGeneration) {
        return;
      }

      if (newRoute != null && newRoute.polylinePoints.length >= 2) {
        routeReceivedAt = completionTime;

        // P5.6 BUG F: Preserve remaining portion of old route as secondary reference route
        if (_activeRoute != null && _activeRouteGeometry != null) {
          _secondaryRoute = NavRoute(
            totalDistanceMeters: _activeRoute!.totalDistanceMeters,
            totalDurationSeconds: _activeRoute!.totalDurationSeconds,
            polylinePoints: remainingPolyline,
            steps: const [],
            summary: 'Lộ trình cũ',
          );
        }

        // ATOMIC COMMIT OF ROUTE B (Sections 40, 42)
        _activeRoute = newRoute;
        _activeRouteGeometry = RouteGeometry(newRoute.polylinePoints, steps: newRoute.steps);
        _routeRevision++; // P5.5.1 Section 7: Force map screen to refresh Route B immediately

        final currentPhys = _acceptedPhysicalLocation ?? physicalLocation;
        final initProj = _activeRouteGeometry!.matchLocation(currentPhys);
        _matchedProjection = initProj;
        _matchedLocation = initProj?.coordinate ?? currentPhys;
        _rawMatchedProgressMeters = initProj?.distanceAlongRouteMeters ?? 0.0;
        _displayProgressMeters = _rawMatchedProgressMeters;

        _currentStepIndex = 0;
        _offRouteDetector.reset();
        _lastOffRouteDecision = OffRouteDecision(
          state: OffRouteState.onRoute,
          becameConfirmed: false,
          recovered: true,
          reason: OffRouteReason.none,
          lateralDistanceMeters: initProj?.lateralDistanceMeters ?? 0.0,
          activeThresholdMeters: 15.0,
        );
        _recentPhysicalTravelMeters = 0.0;
        _recentMatchedAdvanceMeters = 0.0;
        _isRerouting = false;
        _rerouteStatus = 'applied';
        _rerouteRetryCount = 0;
        _lastRerouteFailureAt = null;
        rerouteFailedAt = null;
        routeCommittedAt = completionTime;

        _updateRemainingMetrics();
        notifyListeners();
        _sendCurrentPayloadToEsp32();
      } else {
        // Reroute failure: anchor cooldown to actual completion time (P5.5.2)
        _isRerouting = false;
        _rerouteStatus = 'failed';
        _rerouteRetryCount++;
        _lastRerouteFailureAt = completionTime;
        rerouteFailedAt = completionTime;
        notifyListeners();
      }
    }).catchError((_) {
      if (generation == _rerouteGeneration) {
        final errorTime = nowProvider();
        _isRerouting = false;
        _rerouteStatus = 'failed';
        _rerouteRetryCount++;
        _lastRerouteFailureAt = errorTime;
        rerouteFailedAt = errorTime;
        notifyListeners();
      }
    });
  }

  void _updateRemainingMetrics() {
    if (_activeRoute == null) return;

    if (_activeRouteGeometry != null) {
      _remainingTotalDistance =
          math.max(0.0, _activeRouteGeometry!.totalDistanceMeters - _displayProgressMeters);

      final totalMeters = _activeRouteGeometry!.totalDistanceMeters;
      if (totalMeters > 0 && _activeRoute!.totalDurationSeconds > 0) {
        final ratio = (_remainingTotalDistance / totalMeters).clamp(0.0, 1.0);
        _remainingEtaMinutes =
            ((_activeRoute!.totalDurationSeconds / 60.0) * ratio).round().clamp(1, 999);
      } else {
        final speed = _currentSpeedKmh > 5 ? _currentSpeedKmh : 32.0;
        _remainingEtaMinutes =
            ((_remainingTotalDistance / 1000.0) / speed * 60.0).round().clamp(1, 999);
      }
    } else {
      _remainingTotalDistance = _activeRoute!.totalDistanceMeters;
      _remainingEtaMinutes = (_activeRoute!.totalDurationSeconds / 60.0).round().clamp(1, 999);
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

  void _sendCurrentPayloadToEsp32() {
    _pushNavigationDataToBle();
  }

  /// Compute upcoming route waypoints rotated to vehicle heading
  List<List<int>> computeUpcomingRoutePoints() {
    final upcomingPts = <List<int>>[];
    if (_activeRoute == null || _activeRoute!.polylinePoints.isEmpty || currentLocation == null) {
      return upcomingPts;
    }

    final curLoc = currentLocation!;
    final points = remainingPolyline.isNotEmpty ? remainingPolyline : _activeRoute!.polylinePoints;

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

    final hRad = effectiveHeading * (math.pi / 180.0);
    final cosH = math.cos(hRad);
    final sinH = math.sin(hRad);
    final cosLat = math.cos(curLoc.latitude * (math.pi / 180.0));

    final dist = distanceToNextManeuver;
    final scale = dist <= 120 ? 0.70 : (dist <= 300 ? 0.48 : 0.32);

    final roadAnchor = points[closestIdx];
    upcomingPts.add([0, 0]);

    for (int i = closestIdx + 1; i < points.length && upcomingPts.length < 24; i++) {
      final pt = points[i];
      final dNorth = (pt.latitude - roadAnchor.latitude) * 111139.0;
      final dEast = (pt.longitude - roadAnchor.longitude) * 111139.0 * cosLat;

      final xRel = dEast * cosH - dNorth * sinH;
      final yRel = dNorth * cosH + dEast * sinH;

      final sx = (xRel * scale).round().clamp(-125, 125);
      final sy = (yRel * scale).round().clamp(-125, 125);

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

    final step = authoritativeCurrentManeuver ?? currentStep ?? _activeRoute!.steps.first;
    final upcomingPts = computeUpcomingRoutePoints();

    final now = DateTime.now();
    final h = now.hour.toString().padLeft(2, '0');
    final m = now.minute.toString().padLeft(2, '0');
    final curClock = '$h:$m';

    final payload = EspNavPayload(
      isNavigating: true,
      turnCode: step.turnCode,
      distanceToTurn: _distanceToNextManeuver.round(),
      totalDistance: _remainingTotalDistance.round(),
      etaMinutes: _remainingEtaMinutes,
      streetName: step.streetName.isNotEmpty ? step.streetName : step.instruction,
      currentSpeed: _currentSpeedKmh.round(),
      stepIndex: _currentStepIndex,
      totalSteps: _activeRoute!.steps.length,
      latitude: currentLocation?.latitude,
      longitude: currentLocation?.longitude,
      heading: effectiveHeading.round(),
      routePoints: upcomingPts.isNotEmpty ? upcomingPts : null,
      currentClock: curClock,
      batteryLevel: _currentBattery,
      songTitle: _currentSongTitle,
      songArtist: _currentSongArtist,
    );

    bleService.getBatteryLevel().then((b) => _currentBattery = b);
    bleService.sendNavPayload(payload);
  }

  void sendPreviewPayloadToEsp32() {
    if (!bleService.isConnected && !bleService.isWifiConnected) return;
    final now = DateTime.now();
    final h = now.hour.toString().padLeft(2, '0');
    final m = now.minute.toString().padLeft(2, '0');
    final curClock = '$h:$m';
    final upcomingPts = _isNavigating ? computeUpcomingRoutePoints() : <List<int>>[];

    final mStep = authoritativeCurrentManeuver ?? currentStep;
    final payload = EspNavPayload(
      isNavigating: _isNavigating,
      turnCode: _isNavigating ? (mStep?.turnCode ?? 0) : 0,
      distanceToTurn: _isNavigating ? _distanceToNextManeuver.round() : 0,
      totalDistance: _isNavigating ? _remainingTotalDistance.round() : 0,
      etaMinutes: _isNavigating ? _remainingEtaMinutes : 0,
      streetName: _isNavigating
          ? (mStep?.streetName.isNotEmpty == true ? mStep!.streetName : (mStep?.instruction ?? ''))
          : 'SAN SANG',
      currentSpeed: _currentSpeedKmh.round(),
      stepIndex: _isNavigating ? _currentStepIndex : 0,
      totalSteps: _isNavigating ? (_activeRoute?.steps.length ?? 1) : 0,
      latitude: currentLocation?.latitude,
      longitude: currentLocation?.longitude,
      heading: effectiveHeading.round(),
      routePoints: upcomingPts.isNotEmpty ? upcomingPts : null,
      currentClock: curClock,
      batteryLevel: _currentBattery,
      songTitle: _currentSongTitle,
      songArtist: _currentSongArtist,
    );

    bleService.getBatteryLevel().then((b) => _currentBattery = b);
    bleService.sendNavPayload(payload);
  }

  /// Stop active navigation or simulation
  void stopNavigation() {
    VoiceGuidanceService().resetNavigation();
    _disableBackgroundNavigation();
    _rerouteGeneration++;
    _routeRevision++;
    _rerouteRetryCount = 0;
    _lastRerouteFailureAt = null;
    _lastLocationUpdateAt = null;
    _isNavigating = false;
    _isSimulating = false;
    _isRerouting = false;
    _rerouteStatus = 'idle';
    _activeRoute = null;
    _previewRoute = null;
    _secondaryRoute = null;
    _activeRouteGeometry = null;
    _navigationDestination = null;
    _currentStepIndex = 0;
    _simulatedPolylineIndex = 0;
    _displayProgressMeters = 0.0;
    _rawMatchedProgressMeters = 0.0;
    _distanceToNextManeuver = 0.0;
    _remainingTotalDistance = 0.0;
    _remainingEtaMinutes = 0;
    suspectedAt = null;
    confirmedAt = null;
    requestStartedAt = null;
    routeReceivedAt = null;
    rerouteFailedAt = null;
    routeCommittedAt = null;
    _offRouteDetector.reset();

    _positionStream?.cancel();
    _simulationTimer?.cancel();
    _blePushTimer?.cancel();

    try {
      final settings = _buildLocationSettings(
        accuracy: LocationAccuracy.medium,
        distanceFilter: 10,
      );
      _positionStream = Geolocator.getPositionStream(locationSettings: settings).listen((pos) {
        _rawLocation = LatLng(pos.latitude, pos.longitude);
        _acceptedPhysicalLocation = _rawLocation;
        _currentSpeedKmh = pos.speed * 3.6;
        _currentHeading = pos.heading;
        _horizontalAccuracy = pos.accuracy;
        notifyListeners();
      });
    } catch (_) {}

    sendPreviewPayloadToEsp32();
    notifyListeners();
  }

  @visibleForTesting
  void updatePositionForTesting(
    LatLng location, {
    double speedKmh = 30.0,
    double heading = 0.0,
    double horizontalAccuracy = 5.0,
    DateTime? timestamp,
  }) {
    updateUserPositionWithAccuracy(
      location,
      speedKmh,
      heading,
      horizontalAccuracy: horizontalAccuracy,
      timestamp: timestamp,
    );
  }

  @visibleForTesting
  void triggerRerouteForTesting(LatLng origin, {DateTime? timestamp}) {
    _triggerValhallaReroute(origin, timestamp ?? DateTime.now());
  }

  @override
  void dispose() {
    _disposed = true;
    _idleHeartbeatTimer?.cancel();
    stopNavigation();
    super.dispose();
  }
}
