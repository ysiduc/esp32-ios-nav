import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import '../models/esp_payload.dart';
import '../models/route_model.dart';
import 'ble_service.dart';
import 'osrm_service.dart';

class NavigationManager extends ChangeNotifier {
  final BleService bleService;
  final OsrmService _osrmService = OsrmService();

  // Active navigation state
  bool _isNavigating = false;
  bool _isSimulating = false;
  bool _isRerouting = false;
  NavRoute? _activeRoute;
  int _currentStepIndex = 0;
  LatLng? _currentLocation;
  double _currentSpeedKmh = 0.0;
  double _currentHeading = 0.0;
  double _distanceToNextManeuver = 0.0;
  double _remainingTotalDistance = 0.0;
  int _remainingEtaMinutes = 0;
  int _consecutiveOffRouteCount = 0;

  StreamSubscription<Position>? _positionStream;
  Timer? _blePushTimer;
  Timer? _simulationTimer;
  int _simulatedPolylineIndex = 0;

  // Callback for MapScreen when location updates to center vehicle
  void Function(LatLng location, double heading)? onLocationChanged;

  // Getters
  bool get isNavigating => _isNavigating;
  bool get isSimulating => _isSimulating;
  bool get isRerouting => _isRerouting;
  NavRoute? get activeRoute => _activeRoute;
  int get currentStepIndex => _currentStepIndex;
  LatLng? get currentLocation => _currentLocation;
  double get currentSpeedKmh => _currentSpeedKmh;
  double get currentHeading => _currentHeading;
  double get distanceToNextManeuver => _distanceToNextManeuver;
  double get remainingTotalDistance => _remainingTotalDistance;
  int get remainingEtaMinutes => _remainingEtaMinutes;

  NavStep? get currentStep {
    if (_activeRoute == null || _currentStepIndex >= _activeRoute!.steps.length) {
      return null;
    }
    return _activeRoute!.steps[_currentStepIndex];
  }

  NavigationManager({required this.bleService}) {
    _initGps();
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

        const settings = LocationSettings(accuracy: LocationAccuracy.high);
        final currentPos = await Geolocator.getCurrentPosition(locationSettings: settings);
        _currentLocation = LatLng(currentPos.latitude, currentPos.longitude);
        notifyListeners();
      }
    } catch (_) {
      // Default fallback (Hanoi)
      _currentLocation ??= const LatLng(21.0285, 105.8542);
      notifyListeners();
    }
  }

  /// Start Real-World Turn-by-Turn Navigation with GPS
  void startNavigation(NavRoute route) {
    stopNavigation();
    _activeRoute = route;
    _isNavigating = true;
    _isSimulating = false;
    _isRerouting = false;
    _currentStepIndex = 0;
    _consecutiveOffRouteCount = 0;
    _remainingTotalDistance = route.totalDistanceMeters;
    _remainingEtaMinutes = (route.totalDurationSeconds / 60).round();

    // Start location tracking
    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 2, // 2 meters
    );

    _positionStream = Geolocator.getPositionStream(locationSettings: locationSettings).listen((pos) {
      _updateUserPosition(LatLng(pos.latitude, pos.longitude), pos.speed * 3.6, pos.heading);
    });

    // Start periodic BLE push timer (every 1.2 seconds)
    _blePushTimer = Timer.periodic(const Duration(milliseconds: 1200), (_) {
      _sendCurrentPayloadToEsp32();
    });

    notifyListeners();
    _sendCurrentPayloadToEsp32();
  }

  /// Start Simulation Mode (walks through polyline path automatically)
  void startSimulation(NavRoute route) {
    stopNavigation();
    _activeRoute = route;
    _isNavigating = true;
    _isSimulating = true;
    _isRerouting = false;
    _currentStepIndex = 0;
    _simulatedPolylineIndex = 0;
    _currentSpeedKmh = 38.0; // 38 km/h mock speed
    _consecutiveOffRouteCount = 0;

    final polyline = route.polylinePoints;
    if (polyline.isEmpty) return;

    _currentLocation = polyline.first;
    _updateRemainingMetrics();

    _simulationTimer = Timer.periodic(const Duration(milliseconds: 150), (timer) {
      if (_simulatedPolylineIndex < polyline.length - 1) {
        _simulatedPolylineIndex++;
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

  void _updateUserPosition(LatLng newLocation, double speedKmh, double heading) {
    _currentLocation = newLocation;
    _currentSpeedKmh = speedKmh.clamp(0.0, 160.0);
    _currentHeading = heading;

    onLocationChanged?.call(newLocation, heading);

    if (_activeRoute == null || _activeRoute!.steps.isEmpty) return;

    // Measure distance to current step maneuver point
    const distanceCalculator = Distance();
    final targetStep = _activeRoute!.steps[_currentStepIndex];
    _distanceToNextManeuver = distanceCalculator.as(
      LengthUnit.Meter,
      newLocation,
      targetStep.coordinate,
    );

    // If within 25m of current step, advance to next step
    if (_distanceToNextManeuver <= 25.0 && _currentStepIndex < _activeRoute!.steps.length - 1) {
      _currentStepIndex++;
      final nextStep = _activeRoute!.steps[_currentStepIndex];
      _distanceToNextManeuver = distanceCalculator.as(
        LengthUnit.Meter,
        newLocation,
        nextStep.coordinate,
      );
    }

    // Check for off-route condition (Auto-Rerouting)
    if (!_isSimulating && !_isRerouting) {
      _checkOffRouteAndReroute(newLocation);
    }

    _updateRemainingMetrics();
    notifyListeners();
  }

  /// Automatically recalculate route if user deviates more than 45m from polyline
  void _checkOffRouteAndReroute(LatLng location) async {
    if (_activeRoute == null || _activeRoute!.polylinePoints.isEmpty) return;

    const distanceCalculator = Distance();
    double minDistanceToPolyline = double.infinity;

    for (final point in _activeRoute!.polylinePoints) {
      final d = distanceCalculator.as(LengthUnit.Meter, location, point);
      if (d < minDistanceToPolyline) {
        minDistanceToPolyline = d;
      }
    }

    if (minDistanceToPolyline > 45.0) {
      _consecutiveOffRouteCount++;
      if (_consecutiveOffRouteCount >= 2) {
        _isRerouting = true;
        notifyListeners();

        final destination = _activeRoute!.polylinePoints.last;
        final newRoute = await _osrmService.calculateRoute(location, destination, profile: 'bike');

        if (newRoute != null && _isNavigating) {
          _activeRoute = newRoute;
          _currentStepIndex = 0;
          _consecutiveOffRouteCount = 0;
          _updateRemainingMetrics();
          _sendCurrentPayloadToEsp32();
        }
        _isRerouting = false;
        notifyListeners();
      }
    } else {
      _consecutiveOffRouteCount = 0;
    }
  }

  void _updateRemainingMetrics() {
    if (_activeRoute == null || _currentLocation == null) return;

    const distanceCalculator = Distance();
    final endCoord = _activeRoute!.polylinePoints.last;
    _remainingTotalDistance = distanceCalculator.as(
      LengthUnit.Meter,
      _currentLocation!,
      endCoord,
    );

    final speed = _currentSpeedKmh > 5 ? _currentSpeedKmh : 32.0;
    _remainingEtaMinutes = ((_remainingTotalDistance / 1000.0) / speed * 60.0).round().clamp(1, 999);
  }

  /// Construct and transmit the payload to ESP32
  void _sendCurrentPayloadToEsp32() {
    if (!_isNavigating || _activeRoute == null) return;

    final step = currentStep;
    if (step == null) return;

    final payload = EspNavPayload(
      turnCode: step.turnCode,
      distanceToTurn: _distanceToNextManeuver.round(),
      totalDistance: _remainingTotalDistance.round(),
      etaMinutes: _remainingEtaMinutes,
      streetName: step.streetName,
      currentSpeed: _currentSpeedKmh.round(),
      stepIndex: _currentStepIndex,
      totalSteps: _activeRoute!.steps.length,
    );

    bleService.sendNavPayload(payload);
  }

  /// Stop active navigation or simulation
  void stopNavigation() {
    _isNavigating = false;
    _isSimulating = false;
    _isRerouting = false;
    _positionStream?.cancel();
    _simulationTimer?.cancel();
    _blePushTimer?.cancel();

    // Send stop / idle packet to ESP32
    if (bleService.isConnected) {
      bleService.sendRawString('{"turn":0,"dist":0,"street":"San sang","speed":0,"eta":0}');
    }

    notifyListeners();
  }

  @override
  void dispose() {
    stopNavigation();
    super.dispose();
  }
}
