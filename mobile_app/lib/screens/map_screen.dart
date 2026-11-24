import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;
import 'package:latlong2/latlong.dart' hide Path;
import 'package:provider/provider.dart';
import '../config/goong_config.dart';
import '../config/mapbox_config.dart';
import '../models/route_model.dart';
import '../services/ble_service.dart';
import '../services/esp_stream_service.dart';
import '../services/google_maps_parser.dart';
import '../services/goong_service.dart';
import '../services/apple_maps_service.dart';
import '../services/mapbox_directions_service.dart';
import '../services/navigation_manager.dart';
import '../services/overpass_traffic_service.dart';
import '../services/saved_places_service.dart';
import '../services/search_service.dart';
import '../services/map_settings_service.dart';
import '../widgets/map_provider_settings_sheet.dart';

enum MapThemeMode {
  streets,         // Apple / Goong Streets (clean light aesthetic)
  satellite,       // Hybrid Satellite Streets
  navigationNight, // Navigation Night (dark, driver-optimized)
  dark,            // Dark minimal
}

class MapScreen extends StatefulWidget {
  final VoidCallback? onOpenMenu;
  const MapScreen({super.key, this.onOpenMenu});

  @override
  State<MapScreen> createState() => MapScreenState();
}

class MapScreenState extends State<MapScreen> {
  ml.MapLibreMapController? _mapController;
  final SearchService _searchService = SearchService();
  final SavedPlacesService _savedPlacesService = SavedPlacesService();
  final MapboxDirectionsService _directionsService = MapboxDirectionsService();
  final GoogleMapsParser _googleMapsParser = GoogleMapsParser();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  bool _mapReady = false;
  bool _styleLoaded = false;
  bool _hasCenteredOnInitialUserLocation = false;
  double _lastCenteredAccuracyM = 999.0;
  LatLng? _lastCenteredLocation;
  bool _userInteractedBeforeGpsSettle = false;
  final DateTime _initialCenterDeadline = DateTime.now().add(const Duration(seconds: 20));
  bool _isNorthUpLocked = false;
  bool _isCameraMoveInFlight = false;
  DateTime _cameraLockUntil = DateTime.fromMillisecondsSinceEpoch(0);
  Offset? _mapPointerDownPos;
  double _currentCameraBearing = 0.0;
  bool _isSyncingPuckPos = false;
  LatLng? _lastLineTrimPos;
  final GlobalKey _directionsSheetKey = GlobalKey();
  MapPlace? _queuedFinalDestination;

  // Coordinates default (Hanoi)
  LatLng _userPosition = const LatLng(21.0285, 105.8542);
  MapPlace? _selectedPlace;
  List<NavRoute> _routes = [];
  int _selectedRouteIndex = 0;
  String _transportMode = 'bike'; // Default to Motorcycle in Vietnam
  bool _isLoadingRoutes = false;
  bool _isSearching = false;

  // Auto-follow Camera Centering State
  bool _isAutoCentering = true;
  Timer? _recenterTimer;

  // View state:
  // 0: Browse Map / Search
  // 1: Place Selected Inspector Sheet
  // 2: Route Comparison & Alternatives
  int _viewMode = 0;
  bool _isDrivingZoomOverview = false;
  MapThemeMode _currentTheme = MapThemeMode.streets; // Apple / Goong Streets (clean light)

  List<MapPlace> _searchResults = [];
  Timer? _debounceTimer;
  String? _clipboardGoogleMapsText;
  String? _lastDismissedClipboardText;
  StateSetter? _searchModalSetState;
  ml.Line? _activeCasingLine;
  ml.Line? _activeCoreLine;
  bool _isUpdatingRouteLine = false;
  DateTime _lastFastLineUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  final ValueNotifier<({Offset pos, double rotationRad})?> _vehiclePuckNotifier =
      ValueNotifier<({Offset pos, double rotationRad})?>(null);

  // Quick Utility Filter Chips (⛽ Cây xăng, ⚡ Trạm sạc, 🅿️ Bãi đỗ xe)
  String? _activeUtilityKey; // 'fuel' | 'charging_station' | 'parking'
  bool _isLoadingUtilities = false;
  List<MapPlace> _utilityResults = [];
  MapPlace? _selectedUtilityPoi;
  final Map<String, MapPlace> _utilityCircleIdToPlace = {};

  void _refreshSearchModal() {
    if (mounted) {
      setState(() {});
    }
    try {
      _searchModalSetState?.call(() {});
    } catch (_) {}
  }

  void _lockCameraDuringTransition([int milliseconds = 450]) {
    _cameraLockUntil = DateTime.now().add(Duration(milliseconds: milliseconds));
  }

  /// Dịch tâm camera về phía trước xe ~42m theo hướng di chuyển để xe nằm ở 1/3 dưới màn hình chuẩn Apple Maps
  LatLng _offsetCameraTarget(LatLng loc, double headingDeg, double offsetMeters) {
    final rad = headingDeg * (math.pi / 180.0);
    final cosLat = math.cos(loc.latitude * (math.pi / 180.0));
    final dLat = (offsetMeters * math.cos(rad)) / 110540.0;
    final dLng = cosLat > 0.01 ? (offsetMeters * math.sin(rad)) / (111320.0 * cosLat) : 0.0;
    return LatLng(loc.latitude + dLat, loc.longitude + dLng);
  }

  @override
  void initState() {
    super.initState();
    MapSettingsService().addListener(_onMapProviderChanged);
    _savedPlacesService.addListener(_refreshSearchModal);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final navManager = Provider.of<NavigationManager>(context, listen: false);
      if (navManager.currentLocation != null) {
        _userPosition = navManager.currentLocation!;
      }
      try {
        final ble = Provider.of<BleService>(context, listen: false);
        if (ble.isConnected) {
          ble.sendRawJson(jsonEncode({'type': 'RESTORE_IDLE_MAP'}));
        }
      } catch (_) {}

      navManager.onRouteChanged = () {
        if (!mounted) return;
        _updateRouteOnMap();
      };

      // Hook 30 FPS navigation position update callback for fluid 3D camera & road-snapped puck
      navManager.onLocationChanged = (loc, heading) async {
        if (!mounted) return;
        _userPosition = loc;
        if (!navManager.isNavigating) {
          _tryCenterOnInitialUserLocation(animate: true);
          return;
        }
        if (navManager.isNavigating) {
          final now = DateTime.now();
          final movedSinceTrim = _lastLineTrimPos == null
              ? 999.0
              : const Distance().as(LengthUnit.Meter, _lastLineTrimPos!, loc);
          if (!_isUpdatingRouteLine &&
              now.difference(_lastFastLineUpdate).inMilliseconds >= 380 &&
              movedSinceTrim >= 5.0) {
            _lastFastLineUpdate = now;
            _lastLineTrimPos = loc;
            unawaited(_updateRouteOnMap(isFastTrackingUpdate: true));
          }

          final ctrl = _mapController;
          if (ctrl != null && _mapReady && !_isCameraMoveInFlight) {
            _isCameraMoveInFlight = true;
            try {
              if (_isAutoCentering &&
                  !_isDrivingZoomOverview &&
                  DateTime.now().isAfter(_cameraLockUntil)) {
                final camTarget = _isNorthUpLocked
                    ? loc
                    : _offsetCameraTarget(loc, heading, 26.0);
                await ctrl.moveCamera(
                  ml.CameraUpdate.newCameraPosition(
                    ml.CameraPosition(
                      target: ml.LatLng(camTarget.latitude, camTarget.longitude),
                      zoom: _isNorthUpLocked ? 16.8 : 17.4,
                      tilt: _isNorthUpLocked ? 0.0 : 46.0,
                      bearing: _isNorthUpLocked ? 0.0 : heading,
                    ),
                  ),
                );
              }
              final pt = await ctrl.toScreenLocation(ml.LatLng(loc.latitude, loc.longitude));
              if (!mounted) return;
              final screenW = MediaQuery.of(context).size.width;
              final camBearing = (_isAutoCentering && !_isDrivingZoomOverview)
                  ? (_isNorthUpLocked ? 0.0 : heading)
                  : (ctrl.cameraPosition?.bearing ?? _currentCameraBearing);
              _currentCameraBearing = camBearing;
              final rotRad = (_isAutoCentering && !_isDrivingZoomOverview && !_isNorthUpLocked)
                  ? 0.0
                  : (heading - camBearing) * (math.pi / 180.0);
              final pos = (_isAutoCentering && !_isDrivingZoomOverview)
                  ? Offset(screenW / 2.0, pt.y.toDouble())
                  : Offset(pt.x.toDouble(), pt.y.toDouble());
              _vehiclePuckNotifier.value = (
                pos: pos,
                rotationRad: rotRad,
              );
            } catch (_) {
            } finally {
              _isCameraMoveInFlight = false;
            }
          }
        }
      };

      // Auto-start headless live map stream and sync initial style unless user picked one
      final streamService = Provider.of<EspStreamService>(context, listen: false);
      if (!streamService.hasUserSelectedMapStyle) {
        if (_currentTheme == MapThemeMode.dark || _currentTheme == MapThemeMode.navigationNight) {
          streamService.streamMapStyle = 'osm-3d-dark';
        } else {
          streamService.streamMapStyle = 'osm-3d';
        }
      }
      if (!streamService.isStreaming) {
        streamService.startStreaming();
      }

      _checkClipboardForGoogleMaps();
    });

    _searchFocusNode.addListener(() {
      if (_searchFocusNode.hasFocus) {
        _checkClipboardForGoogleMaps();
      }
      setState(() {});
    });
  }

  /// Đưa camera về vị trí hiện tại của người dùng ngay khi bản đồ & GPS sẵn sàng
  void _tryCenterOnInitialUserLocation({bool animate = true}) {
    if (!mounted ||
        _mapController == null ||
        !_mapReady ||
        !_styleLoaded ||
        _viewMode != 0 ||
        _selectedPlace != null) {
      return;
    }
    final navManager = Provider.of<NavigationManager>(context, listen: false);
    if (navManager.isNavigating) return;
    final loc = navManager.currentLocation;
    if (loc == null) return;

    final double incomingAccuracy = navManager.lastLiveAccuracyM;
    if (_hasCenteredOnInitialUserLocation) {
      if (_userInteractedBeforeGpsSettle || DateTime.now().isAfter(_initialCenterDeadline)) {
        return;
      }
      final prevLoc = _lastCenteredLocation;
      final double movedDist =
          prevLoc == null ? 999.0 : const Distance().as(LengthUnit.Meter, prevLoc, loc);
      final bool accuracyImproved = _lastCenteredAccuracyM > 30.0 && incomingAccuracy <= 25.0;
      if (!accuracyImproved && movedDist <= 25.0) {
        return;
      }
    }

    _userPosition = loc;
    if (navManager.hasInitialLiveGpsFix) {
      _hasCenteredOnInitialUserLocation = true;
      _lastCenteredAccuracyM = incomingAccuracy;
      _lastCenteredLocation = loc;
    }

    final update = ml.CameraUpdate.newCameraPosition(
      ml.CameraPosition(
        target: ml.LatLng(loc.latitude, loc.longitude),
        zoom: 16.5,
      ),
    );
    if (animate) {
      _mapController?.animateCamera(update);
    } else {
      _mapController?.moveCamera(update);
    }
  }

  /// Called when MaplibreMap is created and controller is ready
  void _onMapCreated(ml.MapLibreMapController controller) {
    _mapController?.removeListener(_onMapCameraChanged);
    _mapController?.onCircleTapped.remove(_onMapCircleTapped);
    _mapController = controller;
    controller.addListener(_onMapCameraChanged);
    controller.onCircleTapped.add(_onMapCircleTapped);
    _mapReady = true;

    final navManager = Provider.of<NavigationManager>(context, listen: false);
    if (navManager.currentLocation != null) {
      _userPosition = navManager.currentLocation!;
    }
    _tryCenterOnInitialUserLocation(animate: false);
  }

  void _onMapCircleTapped(ml.Circle circle) {
    final poi = _utilityCircleIdToPlace[circle.id];
    if (poi == null || !mounted) return;
    HapticFeedback.selectionClick();
    setState(() {
      _selectedUtilityPoi = poi;
    });
    _mapController?.animateCamera(
      ml.CameraUpdate.newLatLng(
        ml.LatLng(poi.coordinate.latitude, poi.coordinate.longitude),
      ),
    );
  }

  void _onMapCameraChanged() {
    final camPos = _mapController?.cameraPosition;
    if (camPos == null || !mounted) return;
    _currentCameraBearing = camPos.bearing;
    final navManager = Provider.of<NavigationManager>(context, listen: false);
    if (!navManager.isNavigating) return;
    if (!_isAutoCentering || _isDrivingZoomOverview) {
      final loc = navManager.currentLocation ?? _userPosition;
      _syncPuckToCamera(loc, navManager.effectiveHeading, camPos.bearing);
    }
  }

  void _syncPuckToCamera(LatLng loc, double heading, double camBearing) {
    final ctrl = _mapController;
    if (ctrl == null || !_mapReady || _isSyncingPuckPos) return;
    _isSyncingPuckPos = true;
    ctrl.toScreenLocation(ml.LatLng(loc.latitude, loc.longitude)).then((pt) {
      if (!mounted) return;
      _vehiclePuckNotifier.value = (
        pos: Offset(pt.x.toDouble(), pt.y.toDouble()),
        rotationRad: (heading - camBearing) * (math.pi / 180.0),
      );
    }).catchError((_) {}).whenComplete(() {
      _isSyncingPuckPos = false;
    });
  }

  /// Được gọi từ Menu 3 gạch khi người dùng chọn một địa điểm đã lưu
  void selectSavedPlace(MapPlace place, {bool autoRoute = false}) {
    _onPlaceClicked(place, autoCalculateRoutes: autoRoute);
  }

  /// Update route polyline on the MapLibre map using Apple Maps styling
  /// Automatically trims traveled polyline segments behind the vehicle during active navigation!
  Future<void> _updateRouteOnMap({bool isFastTrackingUpdate = false}) async {
    final ctrl = _mapController;
    if (ctrl == null || !_mapReady || _isUpdatingRouteLine) return;
    _isUpdatingRouteLine = true;

    final navManager = Provider.of<NavigationManager>(context, listen: false);
    List<LatLng> points = [];
    if (navManager.isNavigating && navManager.activeRoute != null) {
      points = navManager.remainingPolylinePoints;
    } else if (_routes.isNotEmpty && _selectedRouteIndex < _routes.length) {
      points = _routes[_selectedRouteIndex].polylinePoints;
    }

    try {
      if (points.length < 2) {
        await ctrl.clearLines();
        _activeCasingLine = null;
        _activeCoreLine = null;
        return;
      }

      final mlGeometry = points
          .map((p) => ml.LatLng(p.latitude, p.longitude))
          .toList();

      // Cắt vạch dẫn đường mượt mà theo thời gian thực đồng bộ 1 frame tránh nháy xanh/trắng
      if (isFastTrackingUpdate &&
          navManager.isNavigating &&
          _activeCasingLine != null &&
          _activeCoreLine != null) {
        await Future.wait([
          ctrl.updateLine(_activeCasingLine!, ml.LineOptions(geometry: mlGeometry)),
          ctrl.updateLine(_activeCoreLine!, ml.LineOptions(geometry: mlGeometry)),
        ]);
        return;
      }

      await ctrl.clearLines();
      _activeCasingLine = null;
      _activeCoreLine = null;

      // Draw alternative routes first in muted Apple slate (Screenshot 4)
      if (!navManager.isNavigating && _routes.length > 1) {
        for (int i = 0; i < _routes.length; i++) {
          if (i == _selectedRouteIndex) continue;
          final altPoints = _routes[i].polylinePoints;
          if (altPoints.length >= 2) {
            final altGeometry = altPoints.map((p) => ml.LatLng(p.latitude, p.longitude)).toList();
            await ctrl.addLine(
              ml.LineOptions(
                geometry: altGeometry,
                lineColor: '#8E8E93',
                lineWidth: 5.5,
                lineOpacity: 0.85,
                lineJoin: 'round',
              ),
            );
          }
        }
      }

      // 1. Casing / Glow outline (Apple Maps Deep Blue Casing #0051B3)
      _activeCasingLine = await ctrl.addLine(
        ml.LineOptions(
          geometry: mlGeometry,
          lineColor: '#0051B3',
          lineWidth: 8.5,
          lineOpacity: 0.9,
          lineJoin: 'round',
        ),
      );

      // 2. Core Apple Maps Vibrant Route Line (#007AFF)
      _activeCoreLine = await ctrl.addLine(
        ml.LineOptions(
          geometry: mlGeometry,
          lineColor: '#007AFF',
          lineWidth: 6.0,
          lineOpacity: 1.0,
          lineJoin: 'round',
        ),
      );
    } catch (e) {
      debugPrint('Error drawing route on MapLibre: $e');
    } finally {
      _isUpdatingRouteLine = false;
    }
  }

  /// Update native vector circle markers for destination pin + nearby utility POIs (⛽ / ⚡ / 🅿️)
  Future<void> _updateDestinationMarker() async {
    final ctrl = _mapController;
    if (ctrl == null || !_mapReady) return;
    try {
      await ctrl.clearCircles();
      _utilityCircleIdToPlace.clear();

      // 1. Vẽ marker tiện ích quanh vị trí hiện tại nếu đang lọc (Cây xăng / Trạm sạc / Bãi đỗ xe)
      if (_utilityResults.isNotEmpty) {
        final String hexColor = switch (_activeUtilityKey) {
          'fuel' => '#EF4444',
          'charging_station' => '#10B981',
          'parking' => '#2563EB',
          _ => '#F59E0B',
        };
        for (final poi in _utilityResults) {
          final isPicked = _selectedUtilityPoi?.coordinate == poi.coordinate;
          final pt = ml.LatLng(poi.coordinate.latitude, poi.coordinate.longitude);
          final outer = await ctrl.addCircle(
            ml.CircleOptions(
              geometry: pt,
              circleRadius: isPicked ? 16.0 : 12.0,
              circleColor: hexColor,
              circleOpacity: isPicked ? 0.35 : 0.22,
              circleStrokeWidth: 1.5,
              circleStrokeColor: hexColor,
            ),
          );
          final core = await ctrl.addCircle(
            ml.CircleOptions(
              geometry: pt,
              circleRadius: isPicked ? 9.5 : 7.5,
              circleColor: hexColor,
              circleOpacity: 1.0,
              circleStrokeWidth: 2.5,
              circleStrokeColor: '#FFFFFF',
            ),
          );
          _utilityCircleIdToPlace[outer.id] = poi;
          _utilityCircleIdToPlace[core.id] = poi;
        }
      }

      // 2. Vẽ điểm đích đang chọn
      if (_selectedPlace != null) {
        final pt = ml.LatLng(
          _selectedPlace!.coordinate.latitude,
          _selectedPlace!.coordinate.longitude,
        );
        // Outer pulsing halo (Apple Maps Orange #FF9500)
        await ctrl.addCircle(
          ml.CircleOptions(
            geometry: pt,
            circleRadius: 18.0,
            circleColor: '#FF9500',
            circleOpacity: 0.35,
            circleStrokeWidth: 1.5,
            circleStrokeColor: '#FF9500',
          ),
        );
        // Inner solid core (Apple Maps Orange with white border)
        await ctrl.addCircle(
          ml.CircleOptions(
            geometry: pt,
            circleRadius: 10.0,
            circleColor: '#FF9500',
            circleOpacity: 1.0,
            circleStrokeWidth: 3.0,
            circleStrokeColor: '#FFFFFF',
          ),
        );
      }
    } catch (e) {
      debugPrint('Error updating destination marker on MapLibre: $e');
    }
  }

  Future<void> _checkClipboardForGoogleMaps() async {

    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim();
      if (text != null && text.isNotEmpty && text != _lastDismissedClipboardText) {
        if (GoogleMapsParser.isGoogleMapsOrCoordInput(text)) {
          if (mounted && _clipboardGoogleMapsText != text) {
            setState(() {
              _clipboardGoogleMapsText = text;
            });
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _pasteFromClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim();
      if (text != null && text.isNotEmpty) {
        _searchController.text = text;
        if (GoogleMapsParser.isGoogleMapsOrCoordInput(text)) {
          await _handleGoogleMapsOrSharedInput(text);
        } else {
          _onSearchSubmitted(text);
        }
      }
    } catch (_) {}
  }

  Future<void> _handleGoogleMapsOrSharedInput(String rawInput) async {
    final clean = rawInput.trim();
    if (clean.isEmpty) return;

    _debounceTimer?.cancel();
    setState(() {
      _isSearching = true;
      _clipboardGoogleMapsText = null;
      _lastDismissedClipboardText = clean;
    });

    final navManager = Provider.of<NavigationManager>(context, listen: false);
    final currentPos = navManager.currentLocation ?? _userPosition;

    final place = await _googleMapsParser.parseInput(clean, userLocation: currentPos);

    if (mounted) {
      setState(() => _isSearching = false);
      if (place != null) {
        _searchController.text = place.name;
        _onPlaceClicked(place);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF0084FF),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            content: Row(
              children: [
                const Icon(Icons.check_circle_rounded, color: Colors.white, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Đã nhận điểm đến từ Google Maps: ${place.name}',
                    style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.white),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            duration: const Duration(seconds: 3),
          ),
        );
      } else {
        // Fallback to normal search
        _onSearchSubmitted(clean);
      }
    }
  }

  void _onMapProviderChanged() {
    if (!mounted) return;
    setState(() {});
    if (_selectedPlace != null && _viewMode == 2) {
      _calculateRoutesForPlace(_selectedPlace!);
    }
  }

  @override
  void dispose() {
    _mapController?.removeListener(_onMapCameraChanged);
    _mapController?.onCircleTapped.remove(_onMapCircleTapped);
    MapSettingsService().removeListener(_onMapProviderChanged);
    _savedPlacesService.removeListener(_refreshSearchModal);
    _debounceTimer?.cancel();
    _recenterTimer?.cancel();
    _vehiclePuckNotifier.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------
  // Search Logic
  // -------------------------------------------------------------
  void _onSearchChanged(String query) {
    _debounceTimer?.cancel();
    final clean = query.trim();
    if (clean.isEmpty) {
      _searchResults = [];
      _isSearching = false;
      _refreshSearchModal();
      return;
    }

    if (GoogleMapsParser.isGoogleMapsOrCoordInput(clean)) {
      _debounceTimer = Timer(const Duration(milliseconds: 250), () {
        _handleGoogleMapsOrSharedInput(clean);
      });
      return;
    }

    // Không gửi request mạng với từ khóa quá ngắn (dưới 2 ký tự)
    if (clean.length < 2) {
      _refreshSearchModal();
      return;
    }

    try {
      Provider.of<EspStreamService>(context, listen: false).pauseStreamingFor(const Duration(milliseconds: 300));
    } catch (_) {}

    final navManager = Provider.of<NavigationManager>(context, listen: false);
    final currentPos = navManager.currentLocation ?? _userPosition;

    // 1. Instant 0ms Local Offline Results (hiển thị ngay lập tức trong modal)
    final instantMatches = _searchService.searchInstantLocal(clean, nearLocation: currentPos);
    if (instantMatches.isNotEmpty) {
      _searchResults = instantMatches;
    }

    // 2. Debounce 200ms: Gọi Apple Maps / Goong và cập nhật trực tiếp vào Modal đang mở!
    _isSearching = true;
    _refreshSearchModal();
    _debounceTimer = Timer(const Duration(milliseconds: 200), () async {
      final results = await _searchService.searchPlaces(clean, nearLocation: currentPos);
      if (mounted && _searchController.text.trim() == clean) {
        _searchResults = results;
        _isSearching = false;
        _refreshSearchModal();
      }
    });
  }

  void _onSearchSubmitted(String query, {BuildContext? modalCtx}) async {
    final clean = query.trim();
    if (clean.isEmpty) return;

    if (GoogleMapsParser.isGoogleMapsOrCoordInput(clean)) {
      if (modalCtx != null && Navigator.canPop(modalCtx)) {
        Navigator.pop(modalCtx);
      }
      _handleGoogleMapsOrSharedInput(clean);
      return;
    }

    _debounceTimer?.cancel();
    _isSearching = true;
    _refreshSearchModal();

    final navManager = Provider.of<NavigationManager>(context, listen: false);
    final currentPos = navManager.currentLocation ?? _userPosition;
    final results = await _searchService.searchPlaces(clean, nearLocation: currentPos);

    if (mounted) {
      _searchResults = results;
      _isSearching = false;
      _refreshSearchModal();
      // Nếu người dùng bấm Tìm từ ngoài modal thì chọn luôn kết quả đầu tiên;
      // Nếu đang ở trong modal tìm kiếm thì giữ nguyên danh sách kết quả để người dùng nhìn thấy và chọn!
      if (_searchModalSetState == null && results.isNotEmpty) {
        _onPlaceClicked(results.first);
      }
    }
  }

  void _onSelectCategory(QuickSearchCategory category) async {
    final navManager = Provider.of<NavigationManager>(context, listen: false);
    final currentPos = navManager.currentLocation ?? _userPosition;
    _searchController.text = category.title;
    setState(() => _isSearching = true);

    final results = await _searchService.searchCategory(category, nearLocation: currentPos);
    if (mounted) {
      setState(() {
        _searchResults = results;
        _isSearching = false;
      });
      if (results.isNotEmpty) {
        _onPlaceClicked(results.first);
      }
    }
  }

  Future<MapPlace> _resolvePlaceCoordinateIfNeeded(MapPlace place) async {
    if (place.coordinate.latitude != 0 || place.coordinate.longitude != 0) {
      return place;
    }

    final navManager = Provider.of<NavigationManager>(context, listen: false);
    final currentPos = navManager.currentLocation ?? _userPosition;

    // 1. Lấy tọa độ chính xác từ Goong Place Detail nếu có placeId
    if (place.placeId != null && place.placeId!.isNotEmpty) {
      final detail = await GoongService().getPlaceDetail(
        place.placeId!,
        fallbackName: place.name,
        fallbackDisplay: place.displayName,
        userLocation: currentPos,
      );
      if (detail != null &&
          (detail.coordinate.latitude != 0 || detail.coordinate.longitude != 0)) {
        return detail;
      }
    }

    // 2. Dự phòng: Nếu Goong Place Detail lỗi mạng, phân giải tọa độ qua Apple Maps Native
    if (AppleMapsService.isSupported) {
      final queryText = place.displayName.isNotEmpty ? place.displayName : place.name;
      final appleMatches = await AppleMapsService().searchPlaces(
        queryText,
        nearLocation: currentPos,
        limit: 1,
      );
      if (appleMatches.isNotEmpty) {
        final matched = appleMatches.first;
        return MapPlace(
          name: place.name,
          displayName: place.displayName,
          coordinate: matched.coordinate,
          type: place.type,
          category: place.category,
          distanceMeters: matched.distanceMeters,
          placeId: place.placeId,
        );
      }
    }

    return place;
  }

  void _onPlaceClicked(MapPlace place, {bool autoCalculateRoutes = false}) async {
    _searchFocusNode.unfocus();
    if (!mounted) return;

    if (autoCalculateRoutes) {
      _calculateRoutesForPlace(place);
      return;
    }

    // Hiển thị ngay lập tức bảng thông tin địa điểm (0ms) trong lúc lấy tọa độ chi tiết & tính lộ trình Apple Maps
    setState(() {
      _selectedPlace = place;
      _searchResults = [];
      _routes = [];
      _isLoadingRoutes = true;
      _viewMode = 1; // Open Place Details Inspector
    });

    final resolvedPlace = await _resolvePlaceCoordinateIfNeeded(place);
    if (!mounted) return;

    _searchService.addRecentSearch(resolvedPlace);
    final navManager = Provider.of<NavigationManager>(context, listen: false);
    final startPos = navManager.currentLocation ?? _userPosition;

    setState(() {
      _selectedPlace = resolvedPlace;
    });

    if (resolvedPlace.coordinate.latitude != 0 || resolvedPlace.coordinate.longitude != 0) {
      _mapController?.animateCamera(
        ml.CameraUpdate.newLatLngZoom(
          ml.LatLng(resolvedPlace.coordinate.latitude, resolvedPlace.coordinate.longitude),
          16.5,
        ),
      );
      _updateDestinationMarker();

      // Tính sẵn lộ trình bằng Apple Maps (MKDirections) để bấm "Chỉ đường" hiện ra ngay lập tức (0ms)!
      final prewarmed = await _directionsService.calculateMultipleRoutes(
        startPos,
        resolvedPlace.coordinate,
        mode: _transportMode,
      );
      if (mounted && _selectedPlace?.coordinate == resolvedPlace.coordinate && _viewMode == 1) {
        setState(() {
          _routes = prewarmed;
          _isLoadingRoutes = false;
          _selectedRouteIndex = 0;
        });
      }
    } else if (mounted) {
      setState(() => _isLoadingRoutes = false);
    }
  }

  void _onMapTapped(LatLng point) async {
    if (Provider.of<NavigationManager>(context, listen: false).isNavigating) return;

    final place = await _searchService.reverseGeocode(point);
    if (mounted) {
      setState(() {
        _selectedPlace = place;
        _searchResults = [];
        _viewMode = 1;
      });
      _mapController?.animateCamera(
        ml.CameraUpdate.newLatLngZoom(
          ml.LatLng(point.latitude, point.longitude),
          16.5,
        ),
      );
      _updateDestinationMarker();
    }
  }

  // -------------------------------------------------------------
  // Route Calculation & Comparison Logic
  // -------------------------------------------------------------
  Future<void> _calculateRoutesForPlace(MapPlace place) async {
    try {
      Provider.of<EspStreamService>(context, listen: false).pauseStreamingFor(const Duration(milliseconds: 400));
    } catch (_) {}

    setState(() {
      _isLoadingRoutes = true;
      _selectedPlace = place;
      _viewMode = 2; // Open Route Comparison immediately (0ms)
      _selectedRouteIndex = 0;
    });

    final resolvedPlace = await _resolvePlaceCoordinateIfNeeded(place);
    if (!mounted) return;
    _searchService.addRecentSearch(resolvedPlace);

    final navManager = Provider.of<NavigationManager>(context, listen: false);
    final startPos = navManager.currentLocation ?? _userPosition;

    setState(() {
      _selectedPlace = resolvedPlace;
    });
    _updateDestinationMarker();

    final routes = await _directionsService.calculateMultipleRoutes(
      startPos,
      resolvedPlace.coordinate,
      mode: _transportMode,
    );

    if (mounted) {
      setState(() {
        _routes = routes;
        _isLoadingRoutes = false;
        _selectedRouteIndex = 0;
        _queuedFinalDestination = resolvedPlace;
      });

      if (routes.isNotEmpty) {
        context.read<NavigationManager>().setPreviewRoute(routes.first);
        _updateRouteOnMap();
        _updateDestinationMarker();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _routes.isNotEmpty) {
            _fitRouteBounds(_routes[_selectedRouteIndex].polylinePoints);
          }
        });
      }
    }
  }

  void _fitRouteBounds(
    List<LatLng> points, {
    double? topPadding,
    double? bottomPadding,
  }) {
    if (points.isEmpty || _mapController == null) return;

    double minLat = points.first.latitude;
    double maxLat = points.first.latitude;
    double minLng = points.first.longitude;
    double maxLng = points.first.longitude;

    for (final p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }

    if ((maxLat - minLat).abs() < 0.001) {
      minLat -= 0.0008;
      maxLat += 0.0008;
    }
    if ((maxLng - minLng).abs() < 0.001) {
      minLng -= 0.0008;
      maxLng += 0.0008;
    }

    double resolvedBottom = bottomPadding ?? 160.0;
    if (bottomPadding == null && _viewMode == 2) {
      final ctx = _directionsSheetKey.currentContext;
      final box = ctx?.findRenderObject() as RenderBox?;
      final screenH = MediaQuery.of(context).size.height;
      final sheetH = (box != null && box.hasSize && box.size.height > 100)
          ? box.size.height
          : (screenH * 0.56).clamp(420.0, 560.0);
      resolvedBottom = sheetH + 28.0;
    }

    // MapLibre camera bounds fitting cleanly above bottom sheet
    _mapController?.animateCamera(
      ml.CameraUpdate.newLatLngBounds(
        ml.LatLngBounds(
          southwest: ml.LatLng(minLat, minLng),
          northeast: ml.LatLng(maxLat, maxLng),
        ),
        top: topPadding ?? (_viewMode == 2 ? 96.0 : 120.0),
        bottom: resolvedBottom,
        left: 44,
        right: 44,
      ),
    );
  }

  void _startDriving({bool isSimulation = false}) {
    if (_routes.isEmpty) return;
    final chosenRoute = _routes[_selectedRouteIndex];
    final navManager = Provider.of<NavigationManager>(context, listen: false);

    _isAutoCentering = true;
    _isNorthUpLocked = false;
    _isDrivingZoomOverview = false;
    _isCameraMoveInFlight = false;
    _lastLineTrimPos = null;

    if (isSimulation) {
      navManager.startSimulation(chosenRoute);
    } else {
      navManager.startNavigation(chosenRoute);
    }

    setState(() {
      _viewMode = 0;
    });

    final startPos = navManager.currentLocation ?? _userPosition;
    final startHeading = navManager.effectiveHeading;
    final camTarget = _offsetCameraTarget(startPos, startHeading, 26.0);
    _mapController?.moveCamera(
      ml.CameraUpdate.newCameraPosition(
        ml.CameraPosition(
          target: ml.LatLng(camTarget.latitude, camTarget.longitude),
          zoom: 17.4,
          tilt: 46.0,
          bearing: startHeading,
        ),
      ),
    );
    _updateRouteOnMap();
  }

  void _recenterToVehicle() {
    final navManager = Provider.of<NavigationManager>(context, listen: false);
    final current = navManager.currentLocation ?? _userPosition;
    final heading = navManager.effectiveHeading;
    HapticFeedback.selectionClick();
    _lockCameraDuringTransition(450);
    setState(() {
      _isAutoCentering = true;
      _isDrivingZoomOverview = false;
    });
    final camTarget = _isNorthUpLocked ? current : _offsetCameraTarget(current, heading, 26.0);
    _mapController?.animateCamera(
      ml.CameraUpdate.newCameraPosition(
        ml.CameraPosition(
          target: ml.LatLng(camTarget.latitude, camTarget.longitude),
          zoom: _isNorthUpLocked ? 16.8 : 17.4,
          tilt: _isNorthUpLocked ? 0.0 : 46.0,
          bearing: _isNorthUpLocked ? 0.0 : heading,
        ),
      ),
    );
  }

  // -------------------------------------------------------------
  // Maplibre Style URL for current theme (Goong Map / MapTiler)
  // -------------------------------------------------------------
  String _buildMaplibreStyleString() {
    if (GoongConfig.hasMapTilesKey) {
      switch (_currentTheme) {
        case MapThemeMode.streets:
          return GoongConfig.styleStreets;
        case MapThemeMode.satellite:
          return GoongConfig.styleStreets;
        case MapThemeMode.navigationNight:
          return GoongConfig.styleNavigationNight;
        case MapThemeMode.dark:
          return GoongConfig.styleDark;
      }
    }

    switch (_currentTheme) {
      case MapThemeMode.streets:
        return MapboxConfig.styleStreets;
      case MapThemeMode.satellite:
        return MapboxConfig.styleSatelliteStreets;
      case MapThemeMode.navigationNight:
        return MapboxConfig.styleNavigationNight;
      case MapThemeMode.dark:
        return MapboxConfig.styleDark;
    }
  }

  @override
  Widget build(BuildContext context) {
    final navManager = context.watch<NavigationManager>();
    final bleService = context.watch<BleService>();
    final isDriving = navManager.isNavigating;
    final userPos = navManager.currentLocation ?? _userPosition;

    return Scaffold(
      backgroundColor: const Color(0xFFF2F2F7),
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          // -----------------------------------------------------------
          // 1. MapLibre Native Vector Map (60fps GPU-rendered)
          // -----------------------------------------------------------
          Listener(
            onPointerDown: (ev) {
              _mapPointerDownPos = ev.position;
            },
            onPointerMove: (ev) {
              final downPos = _mapPointerDownPos;
              if (downPos != null && (ev.position - downPos).distance > 12.0) {
                _userInteractedBeforeGpsSettle = true;
                if (isDriving && _isAutoCentering) {
                  _mapPointerDownPos = null;
                  setState(() {
                    _isAutoCentering = false;
                  });
                }
              }
            },
            onPointerUp: (_) => _mapPointerDownPos = null,
            onPointerCancel: (_) => _mapPointerDownPos = null,
            child: ml.MapLibreMap(
              styleString: _buildMaplibreStyleString(),
              initialCameraPosition: ml.CameraPosition(
                target: ml.LatLng(userPos.latitude, userPos.longitude),
                zoom: 16.5,
              ),
              onMapCreated: _onMapCreated,
              onStyleLoadedCallback: () {
                _styleLoaded = true;
                _tryCenterOnInitialUserLocation(animate: false);
                _updateRouteOnMap();
                _updateDestinationMarker();
              },
              onMapClick: (point, coord) => _onMapTapped(LatLng(coord.latitude, coord.longitude)),
              onMapLongClick: (point, coord) => _onMapTapped(LatLng(coord.latitude, coord.longitude)),
              trackCameraPosition: true,
              compassEnabled: false,
              myLocationEnabled: !isDriving,
              myLocationTrackingMode: ml.MyLocationTrackingMode.none,
              myLocationRenderMode: ml.MyLocationRenderMode.compass,
              rotateGesturesEnabled: true,
              scrollGesturesEnabled: true,
              zoomGesturesEnabled: true,
              tiltGesturesEnabled: true,
            ),
          ),

          // -----------------------------------------------------------
          // 1b. Road-Snapped 60 FPS Apple Maps 3D Navigation Chevron Puck
          // -----------------------------------------------------------
          if (isDriving)
            ValueListenableBuilder<({Offset pos, double rotationRad})?>(
              valueListenable: _vehiclePuckNotifier,
              builder: (context, puck, _) {
                final screenSize = MediaQuery.of(context).size;
                final dx = puck?.pos.dx ?? (screenSize.width / 2.0);
                final dy = puck?.pos.dy ?? (screenSize.height * 0.65);
                final rot = puck?.rotationRad ?? 0.0;
                if (dx < -40 || dx > screenSize.width + 40 || dy < -40 || dy > screenSize.height + 40) {
                  return const SizedBox.shrink();
                }
                return Positioned(
                  left: dx - 26,
                  top: dy - 26,
                  child: IgnorePointer(
                    child: Transform.rotate(
                      angle: rot,
                      child: SizedBox(
                        width: 52,
                        height: 52,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            // Outer soft radar halo
                            Container(
                              width: 52,
                              height: 52,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: const Color(0xFF007AFF).withAlpha(38),
                              ),
                            ),
                            // Crisp white Apple Maps navigation shield with drop shadow
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white,
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withAlpha(65),
                                    blurRadius: 8,
                                    offset: const Offset(0, 3),
                                  ),
                                ],
                              ),
                              child: const Center(
                                child: Icon(
                                  Icons.navigation_rounded,
                                  color: Color(0xFF007AFF),
                                  size: 24,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),

          // -----------------------------------------------------------
          // 2. Top-Left Controls: 3-line Menu Button + Weather Pill + Quick Utility Chips
          // -----------------------------------------------------------
          if (!isDriving)
            SafeArea(
              child: Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 16.0, right: 16.0, top: 8.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildMenuButton(context, bleService),
                          const SizedBox(width: 8),
                          _buildAppleWeatherPill(),
                        ],
                      ),
                      if (_viewMode == 0) ...[
                        const SizedBox(height: 10),
                        _buildQuickUtilityChipsBar(navManager),
                      ],
                    ],
                  ),
                ),
              ),
            ),

          // -----------------------------------------------------------
          // 3. BLE Status Indicator (Top-Center)
          // -----------------------------------------------------------
          if (!isDriving && bleService.isConnected)
            SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: _buildBleStatusBadge(bleService),
                ),
              ),
            ),

          // -----------------------------------------------------------
          // 4. Right-side Floating Action Controls (Browse / Route Preview)
          // -----------------------------------------------------------
          if (!isDriving)
            Positioned(
              right: 16,
              bottom: _viewMode == 0
                  ? 95
                  : (_viewMode == 2
                      ? (MediaQuery.of(context).size.height * 0.54).clamp(395.0, 520.0)
                      : 325),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildCircularGlassButton(
                    icon: Icons.layers_rounded,
                    tooltip: 'Đổi nền bản đồ',
                    onTap: _showMapThemePicker,
                  ),
                  const SizedBox(height: 10),
                  _buildQuickBleConnectButton(bleService),
                  const SizedBox(height: 10),
                  _buildAppleVerticalControlPill(navManager, isDriving),
                ],
              ),
            ),

          // -----------------------------------------------------------
          // 5. Active Driving Top Maneuver Banner + Quick Utility Chips
          // -----------------------------------------------------------
          if (isDriving)
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 8.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildAppleActiveDrivingTurnBanner(navManager),
                    const SizedBox(height: 8),
                    _buildQuickUtilityChipsBar(navManager, compact: true),
                  ],
                ),
              ),
            ),

          // -----------------------------------------------------------
          // 6. Active Driving Bottom HUD + Speed Limit / Camera Alert + Right 4-Button Stack
          // -----------------------------------------------------------
          if (isDriving)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_selectedUtilityPoi != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                        child: _buildSelectedUtilityPoiCard(_selectedUtilityPoi!, isDriving: true),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildDrivingTrafficHudCluster(navManager),
                              if (!_isAutoCentering || _isDrivingZoomOverview) ...[
                                const SizedBox(height: 10),
                                Material(
                                  color: Colors.white.withValues(alpha: 0.96),
                                  elevation: 4,
                                  shadowColor: Colors.black26,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(24),
                                    side: const BorderSide(color: Color(0xFFE5E5EA)),
                                  ),
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(24),
                                    onTap: _recenterToVehicle,
                                    child: const Padding(
                                      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.near_me_rounded, color: Color(0xFF007AFF), size: 18),
                                          SizedBox(width: 6),
                                          Text(
                                            'Về giữa',
                                            style: TextStyle(
                                              color: Color(0xFF1C1C1E),
                                              fontWeight: FontWeight.w700,
                                              fontSize: 14,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const Spacer(),
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _buildDrivingCompassButton(navManager),
                              const SizedBox(height: 10),
                              _buildDrivingCircleButton(
                                icon: Icons.search_rounded,
                                tooltip: 'Tìm kiếm quanh lộ trình',
                                onTap: () {
                                  HapticFeedback.selectionClick();
                                  _openDrivingAlongRouteSearchModal();
                                },
                              ),
                              const SizedBox(height: 10),
                              _buildDrivingCircleButton(
                                icon: navManager.isVoiceEnabled ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                                iconColor: navManager.isVoiceEnabled ? const Color(0xFF007AFF) : const Color(0xFF8E8E93),
                                tooltip: navManager.isVoiceEnabled ? 'Tắt giọng đọc chỉ dẫn' : 'Bật giọng đọc chỉ dẫn',
                                isActive: navManager.isVoiceEnabled,
                                onTap: () {
                                  HapticFeedback.selectionClick();
                                  final nextState = !navManager.isVoiceEnabled;
                                  navManager.setVoiceEnabled(nextState);
                                  if (nextState) {
                                    navManager.testVoiceGuidance();
                                  }
                                },
                              ),
                              const SizedBox(height: 10),
                              _buildDrivingCircleButton(
                                icon: _isDrivingZoomOverview ? Icons.navigation_rounded : Icons.alt_route_rounded,
                                iconColor: _isDrivingZoomOverview ? const Color(0xFF007AFF) : const Color(0xFF1C1C1E),
                                tooltip: _isDrivingZoomOverview ? 'Quay lại dẫn đường' : 'Xem tổng quan lộ trình',
                                isActive: _isDrivingZoomOverview,
                                onTap: () => _toggleDrivingOverview(navManager),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    _buildAppleActiveDrivingBottomHud(navManager, bleService),
                  ],
                ),
              ),
            ),

          // -----------------------------------------------------------
          // 7. Bottom Panels (Browse / Place Sheet / Route Preview)
          // -----------------------------------------------------------
          // Mode 0: Browse Map Bottom Search Capsule + Selected Utility POI Card
          if (!isDriving && _viewMode == 0)
            Positioned(
              bottom: 20,
              left: 16,
              right: 16,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_selectedUtilityPoi != null) ...[
                    _buildSelectedUtilityPoiCard(_selectedUtilityPoi!, isDriving: false),
                    const SizedBox(height: 10),
                  ],
                  _buildAppleBottomSearchCapsule(),
                ],
              ),
            ),

          // Mode 1: Place Details Inspector Sheet (Screenshot 3)
          if (!isDriving && _viewMode == 1 && _selectedPlace != null)
            Align(
              alignment: Alignment.bottomCenter,
              child: _buildApplePlaceInspectorSheet(_selectedPlace!),
            ),

          // Mode 2: Route Directions & Comparison Sheet (Screenshot 4)
          if (!isDriving && _viewMode == 2)
            Align(
              alignment: Alignment.bottomCenter,
              child: _buildAppleRouteDirectionsSheet(),
            ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------
  // Apple Maps Top-Left 3-line Menu Button
  // -------------------------------------------------------------
  Widget _buildMenuButton(BuildContext context, BleService bleService) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          if (widget.onOpenMenu != null) {
            widget.onOpenMenu!();
          } else {
            Scaffold.maybeOf(context)?.openDrawer();
          }
        },
        borderRadius: BorderRadius.circular(22),
        child: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(240),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(25),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
            ],
            border: Border.all(
              color: bleService.isConnected ? const Color(0xFF007AFF) : Colors.black12,
              width: 1.2,
            ),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              const Icon(
                Icons.menu_rounded,
                color: Color(0xFF1C1C1E),
                size: 22,
              ),
              if (bleService.isConnected)
                Positioned(
                  right: 8,
                  top: 8,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: bleService.isWifiConnected ? const Color(0xFF05FFA1) : const Color(0xFF007AFF),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 1.5),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------
  // Apple Maps Weather Pill (Screenshot 1)
  // -------------------------------------------------------------
  Widget _buildAppleWeatherPill() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.90),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.black.withOpacity(0.06)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloudy_snowing, color: Color(0xFF007AFF), size: 16),
          SizedBox(width: 6),
          Text(
            '27°',
            style: TextStyle(
              color: Colors.black87,
              fontSize: 14,
              fontWeight: FontWeight.bold,
              letterSpacing: -0.2,
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------
  // Apple Maps Right Floating Buttons (Screenshot 1 & 4)
  // -------------------------------------------------------------
  Widget _buildCircularGlassButton({
    required IconData icon,
    Color? iconColor,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withOpacity(0.92),
          border: Border.all(color: Colors.black.withOpacity(0.06)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.12),
              blurRadius: 12,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Icon(icon, color: iconColor ?? Colors.black87, size: 22),
      ),
    );
  }

  /// Nút Kết nối nhanh Bluetooth ysiducnaga (thay thế nút hình la bàn cũ)
  Widget _buildQuickBleConnectButton(BleService bleService) {
    final isConnected = bleService.isConnected;
    final isBusy = bleService.isConnecting || bleService.isScanning;

    return GestureDetector(
      onTap: () => _onQuickBleConnectTapped(bleService),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: 0.94),
          border: Border.all(
            color: isConnected
                ? const Color(0xFF34C759)
                : (isBusy ? const Color(0xFF007AFF) : Colors.black.withValues(alpha: 0.08)),
            width: isConnected || isBusy ? 1.8 : 1.0,
          ),
          boxShadow: [
            BoxShadow(
              color: isConnected
                  ? const Color(0xFF34C759).withValues(alpha: 0.25)
                  : Colors.black.withValues(alpha: 0.12),
              blurRadius: 12,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (isBusy)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  color: Color(0xFF007AFF),
                ),
              )
            else
              Icon(
                isConnected ? Icons.bluetooth_connected_rounded : Icons.bluetooth_rounded,
                color: isConnected ? const Color(0xFF34C759) : const Color(0xFF007AFF),
                size: 22,
              ),
            if (isConnected)
              Positioned(
                right: 7,
                top: 7,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: bleService.isWifiConnected
                        ? const Color(0xFF34C759)
                        : const Color(0xFF007AFF),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _onQuickBleConnectTapped(BleService bleService) async {
    if (bleService.isConnected) {
      _showQuickBleStatusSheet(bleService);
      return;
    }
    if (bleService.isConnecting || bleService.isScanning) return;

    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: const Color(0xFF007AFF),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        duration: const Duration(seconds: 2),
        content: const Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            ),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'Đang kết nối nhanh tới Hoa hướng dương...',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );

    final ok = await bleService.quickConnectToYsiducnaga();
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();

    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF34C759),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          duration: const Duration(seconds: 2),
          content: Row(
            children: [
              const Icon(Icons.bluetooth_connected_rounded, color: Colors.white, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Đã kết nối ${bleService.connectedDeviceName ?? "Hoa hướng dương"} thành công!',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ),
      );
    } else {
      _showQuickBleStatusSheet(bleService);
    }
  }

  void _showQuickBleStatusSheet(BleService bleService) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return AnimatedBuilder(
          animation: bleService,
          builder: (context, _) {
            final isConn = bleService.isConnected;
            final isWifi = bleService.isWifiConnected;
            return Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
              decoration: const BoxDecoration(
                color: Color(0xFFF2F2F7),
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 38,
                      height: 5,
                      margin: const EdgeInsets.only(bottom: 14),
                      decoration: BoxDecoration(
                        color: Colors.black26,
                        borderRadius: BorderRadius.circular(2.5),
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.05),
                          blurRadius: 10,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: (isConn ? const Color(0xFF34C759) : const Color(0xFF007AFF))
                                .withValues(alpha: 0.14),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            isConn ? Icons.bluetooth_connected_rounded : Icons.bluetooth_searching_rounded,
                            color: isConn ? const Color(0xFF34C759) : const Color(0xFF007AFF),
                            size: 26,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                isConn
                                    ? (bleService.connectedDeviceName ?? 'Hoa hướng dương')
                                    : 'Chưa kết nối Hoa hướng dương',
                                style: const TextStyle(
                                  color: Color(0xFF1C1C1E),
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                isConn
                                    ? (isWifi
                                        ? 'Đã kết nối BLE + Wi-Fi Stream (${bleService.wifiIp})'
                                        : 'Đã kết nối Bluetooth BLE • Sẵn sàng dẫn đường')
                                    : 'Bật nguồn màn hình Hoa hướng dương để kết nối nhanh',
                                style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 12.5),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: isConn ? const Color(0xFFFF3B30) : const Color(0xFF007AFF),
                            foregroundColor: Colors.white,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          ),
                          icon: Icon(
                            isConn ? Icons.link_off_rounded : Icons.flash_on_rounded,
                            size: 19,
                          ),
                          label: Text(
                            isConn ? 'Ngắt kết nối' : 'Quét & Kết nối lại',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14.5),
                          ),
                          onPressed: () async {
                            if (isConn) {
                              await bleService.disconnect();
                              if (ctx.mounted) Navigator.pop(ctx);
                            } else {
                              final ok = await bleService.quickConnectToYsiducnaga();
                              if (ok && ctx.mounted) Navigator.pop(ctx);
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildAppleVerticalControlPill(NavigationManager navManager, bool isDriving) {
    return Container(
      width: 44,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.94),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.black.withOpacity(0.06)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.12),
            blurRadius: 14,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            icon: Icon(
              _transportMode == 'driving' ? Icons.directions_car_rounded : Icons.two_wheeler_rounded,
              color: Colors.black87,
              size: 20,
            ),
            tooltip: 'Chế độ phương tiện',
            onPressed: () {
              setState(() {
                _transportMode = _transportMode == 'bike' ? 'driving' : 'bike';
              });
              if (_selectedPlace != null) {
                _calculateRoutesForPlace(_selectedPlace!);
              }
            },
          ),
          Container(
            width: 28,
            height: 0.8,
            color: Colors.black12,
          ),
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            icon: const Icon(Icons.navigation_rounded, color: Color(0xFF007AFF), size: 22),
            tooltip: 'Vị trí hiện tại',
            onPressed: () {
              if (isDriving) {
                _recenterToVehicle();
              } else {
                final current = navManager.currentLocation ?? _userPosition;
                _mapController?.animateCamera(
                  ml.CameraUpdate.newLatLngZoom(ml.LatLng(current.latitude, current.longitude), 16.5),
                );
              }
            },
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------
  // Apple Maps Bottom Search Capsule (Screenshot 1)
  // -------------------------------------------------------------
  Widget _buildAppleBottomSearchCapsule() {
    final isApple = MapSettingsService().isAppleMaps;

    return GestureDetector(
      onTap: _openAppleSearchModal,
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: Colors.black.withValues(alpha: 0.08)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.12),
              blurRadius: 20,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            const Icon(Icons.search_rounded, color: Colors.black54, size: 24),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Tìm kiếm địa điểm',
                style: const TextStyle(
                  color: Colors.black87,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  letterSpacing: -0.2,
                ),
              ),
            ),
            // Quick Provider Switch Pill
            GestureDetector(
              onTap: () => showMapProviderSettingsSheet(context),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                margin: const EdgeInsets.only(right: 6),
                decoration: BoxDecoration(
                  color: isApple
                      ? const Color(0xFF007AFF).withValues(alpha: 0.12)
                      : const Color(0xFFFF9F1C).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isApple
                        ? const Color(0xFF007AFF).withValues(alpha: 0.3)
                        : const Color(0xFFFF9F1C).withValues(alpha: 0.4),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isApple ? Icons.bolt_rounded : Icons.map_rounded,
                      size: 14,
                      color: isApple ? const Color(0xFF007AFF) : const Color(0xFFD97706),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      isApple ? 'Tối ưu' : 'Máy chủ VN',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: isApple ? const Color(0xFF007AFF) : const Color(0xFFD97706),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.mic_none_rounded, color: Colors.black54, size: 22),
              onPressed: _openAppleSearchModal,
            ),
            GestureDetector(
              onTap: _showGoongKeyDialog,
              child: Container(
                width: 32,
                height: 32,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFF5E5CE6),
                ),
                child: const Center(
                  child: Text(
                    'Y',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------
  // Apple Maps Search Modal Sheet (Screenshot 2)
  // -------------------------------------------------------------
  void _openAppleSearchModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (modalCtx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            _searchModalSetState = setModalState;
            final query = _searchController.text.trim();
            final isQueryMode = query.isNotEmpty;
            final results = isQueryMode ? _searchResults : _searchService.recentSearches;

            return DraggableScrollableSheet(
              initialChildSize: 0.85,
              maxChildSize: 0.95,
              minChildSize: 0.45,
              builder: (_, scrollController) {
                return Container(
                  decoration: const BoxDecoration(
                    color: Color(0xFFF2F2F7),
                    borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                  ),
                  child: Column(
                    children: [
                      // Top Drag Handle
                      Center(
                        child: Container(
                          width: 36,
                          height: 5,
                          margin: const EdgeInsets.only(top: 10, bottom: 12),
                          decoration: BoxDecoration(
                            color: Colors.black26,
                            borderRadius: BorderRadius.circular(2.5),
                          ),
                        ),
                      ),

                      // Search Input Header
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0),
                        child: Row(
                          children: [
                            Expanded(
                              child: Container(
                                height: 46,
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(23),
                                  border: Border.all(color: Colors.black.withOpacity(0.06)),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.04),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.search_rounded, color: Colors.black54, size: 20),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: TextField(
                                        controller: _searchController,
                                        autofocus: true,
                                        textInputAction: TextInputAction.search,
                                        style: const TextStyle(
                                          color: Colors.black87,
                                          fontSize: 16,
                                          fontWeight: FontWeight.w500,
                                        ),
                                        decoration: InputDecoration(
                                          hintText: MapSettingsService().isAppleMaps
                                              ? 'Tìm kiếm địa điểm...'
                                              : 'Tìm kiếm địa điểm...',
                                          hintStyle: const TextStyle(color: Colors.black38, fontSize: 16),
                                          border: InputBorder.none,
                                          isDense: true,
                                        ),
                                        onChanged: (val) {
                                          _onSearchChanged(val);
                                        },
                                        onSubmitted: (val) {
                                          _onSearchSubmitted(val, modalCtx: modalCtx);
                                        },
                                      ),
                                    ),
                                    if (_isSearching)
                                      const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF007AFF)),
                                      )
                                    else if (_searchController.text.isNotEmpty)
                                      GestureDetector(
                                        onTap: () {
                                          _searchController.clear();
                                          _onSearchChanged('');
                                        },
                                        child: const Icon(Icons.cancel, color: Colors.black38, size: 20),
                                      ),
                                    const SizedBox(width: 6),
                                    const Icon(Icons.mic_none_rounded, color: Colors.black54, size: 20),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            GestureDetector(
                              onTap: () => Navigator.pop(modalCtx),
                              child: Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.black.withOpacity(0.07),
                                ),
                                child: const Icon(Icons.close_rounded, color: Colors.black54, size: 20),
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Provider Quick Switch Banner
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                        child: Row(
                          children: [
                            Text(
                              'Nguồn tìm kiếm: ',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.black.withValues(alpha: 0.5),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            GestureDetector(
                              onTap: () {
                                showMapProviderSettingsSheet(context);
                                setModalState(() {});
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: MapSettingsService().isAppleMaps
                                      ? const Color(0xFF007AFF).withValues(alpha: 0.12)
                                      : const Color(0xFFFF9F1C).withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: MapSettingsService().isAppleMaps
                                        ? const Color(0xFF007AFF).withValues(alpha: 0.3)
                                        : const Color(0xFFFF9F1C).withValues(alpha: 0.4),
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      MapSettingsService().isAppleMaps ? Icons.apple_rounded : Icons.map_rounded,
                                      size: 13,
                                      color: MapSettingsService().isAppleMaps
                                          ? const Color(0xFF007AFF)
                                          : const Color(0xFFD97706),
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      MapSettingsService().isAppleMaps
                                          ? 'Tối ưu cho iPhone'
                                          : 'Máy chủ Việt Nam',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: MapSettingsService().isAppleMaps
                                            ? const Color(0xFF007AFF)
                                            : const Color(0xFFD97706),
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Icon(
                                      Icons.swap_horiz_rounded,
                                      size: 14,
                                      color: Colors.black.withValues(alpha: 0.5),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 6),

                      // Body: Query Results or Recent Searches & Nearby Categories
                      Expanded(
                        child: isQueryMode
                            ? (results.isEmpty
                                ? Center(
                                    child: Padding(
                                      padding: const EdgeInsets.all(24.0),
                                      child: Text(
                                        _isSearching
                                            ? 'Đang tìm kiếm địa điểm...'
                                            : (query.length < 2
                                                ? 'Nhập ít nhất 2 ký tự để tìm kiếm'
                                                : 'Không tìm thấy địa điểm phù hợp'),
                                        style: const TextStyle(color: Colors.black45, fontSize: 14, fontWeight: FontWeight.w500),
                                      ),
                                    ),
                                  )
                                : ListView.separated(
                                    controller: scrollController,
                                    padding: const EdgeInsets.symmetric(horizontal: 16),
                                    itemCount: results.length,
                                    separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.black12),
                                    itemBuilder: (context, idx) {
                                      final p = results[idx];
                                      final distText = p.formattedDistance;
                                      return ListTile(
                                        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                        leading: const CircleAvatar(
                                          radius: 18,
                                          backgroundColor: Colors.white,
                                          child: Icon(Icons.location_on_rounded, color: Color(0xFF007AFF), size: 20),
                                        ),
                                        title: Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                p.name,
                                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.black87),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            if (distText.isNotEmpty) ...[
                                              const SizedBox(width: 6),
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                decoration: BoxDecoration(
                                                  color: const Color(0xFFE5F0FF),
                                                  borderRadius: BorderRadius.circular(6),
                                                ),
                                                child: Text(
                                                  distText,
                                                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF007AFF)),
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                        subtitle: Text(
                                          p.displayName,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(color: Colors.black54, fontSize: 13),
                                        ),
                                        trailing: GestureDetector(
                                          onTap: () {
                                            Navigator.pop(modalCtx);
                                            _onPlaceClicked(p, autoCalculateRoutes: true);
                                          },
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF007AFF),
                                              borderRadius: BorderRadius.circular(14),
                                            ),
                                            child: const Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(Icons.directions_rounded, color: Colors.white, size: 15),
                                                SizedBox(width: 4),
                                                Text(
                                                  'Đi',
                                                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                        onTap: () {
                                          Navigator.pop(modalCtx);
                                          _onPlaceClicked(p);
                                        },
                                      );
                                    },
                                  ))
                            : ListView(
                                controller: scrollController,
                                padding: const EdgeInsets.symmetric(horizontal: 16),
                                children: [
                                  // Quick Action: Paste Google Maps Link Chip
                                  GestureDetector(
                                    onTap: () async {
                                      Navigator.pop(modalCtx);
                                      _pasteFromClipboard();
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.all(12),
                                      margin: const EdgeInsets.only(bottom: 16),
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(16),
                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.black.withOpacity(0.04),
                                            blurRadius: 8,
                                            offset: const Offset(0, 2),
                                          ),
                                        ],
                                      ),
                                      child: const Row(
                                        children: [
                                          Icon(Icons.content_paste_rounded, color: Color(0xFF007AFF), size: 20),
                                          SizedBox(width: 10),
                                          Expanded(
                                            child: Text(
                                              'Dán liên kết Google Maps hoặc Tọa độ',
                                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF007AFF)),
                                            ),
                                          ),
                                          Icon(Icons.chevron_right_rounded, color: Colors.black38),
                                        ],
                                      ),
                                    ),
                                  ),

                                  // Section 0: "Địa điểm đã lưu" (Saved Places)
                                  if (_savedPlacesService.savedPlaces.isNotEmpty) ...[
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        const Row(
                                          children: [
                                            Icon(Icons.bookmark_rounded, color: Color(0xFFFF9500), size: 20),
                                            SizedBox(width: 6),
                                            Text(
                                              'Địa điểm đã lưu',
                                              style: TextStyle(
                                                fontSize: 19,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.black87,
                                                letterSpacing: -0.3,
                                              ),
                                            ),
                                          ],
                                        ),
                                        GestureDetector(
                                          onTap: () {
                                            Navigator.pop(modalCtx);
                                            showSavedPlacesSheet(
                                              context,
                                              onSelectPlace: (p, {bool autoRoute = false}) {
                                                _onPlaceClicked(p, autoCalculateRoutes: autoRoute);
                                              },
                                            );
                                          },
                                          child: const Text(
                                            'Xem tất cả',
                                            style: TextStyle(color: Color(0xFF007AFF), fontSize: 14, fontWeight: FontWeight.w600),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    Container(
                                      margin: const EdgeInsets.only(bottom: 22),
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(16),
                                        boxShadow: [
                                          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2)),
                                        ],
                                      ),
                                      child: Column(
                                        children: _savedPlacesService.savedPlaces.take(4).map((p) {
                                          return Column(
                                            children: [
                                              ListTile(
                                                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                                                leading: const Icon(Icons.bookmark_rounded, color: Color(0xFFFF9500), size: 22),
                                                title: Text(
                                                  p.name,
                                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.black87),
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                                subtitle: Text(
                                                  p.displayName,
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: const TextStyle(color: Colors.black45, fontSize: 13),
                                                ),
                                                trailing: GestureDetector(
                                                  onTap: () {
                                                    Navigator.pop(modalCtx);
                                                    _onPlaceClicked(p, autoCalculateRoutes: true);
                                                  },
                                                  child: Container(
                                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                                    decoration: BoxDecoration(
                                                      color: const Color(0xFF007AFF),
                                                      borderRadius: BorderRadius.circular(14),
                                                    ),
                                                    child: const Row(
                                                      mainAxisSize: MainAxisSize.min,
                                                      children: [
                                                        Icon(Icons.directions_rounded, color: Colors.white, size: 15),
                                                        SizedBox(width: 4),
                                                        Text(
                                                          'Đi',
                                                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                                onTap: () {
                                                  Navigator.pop(modalCtx);
                                                  _onPlaceClicked(p);
                                                },
                                              ),
                                              const Divider(height: 1, indent: 48, color: Colors.black12),
                                            ],
                                          );
                                        }).toList(),
                                      ),
                                    ),
                                  ],

                                  // Section 1: "Gần đây >"
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      const Row(
                                        children: [
                                          Text(
                                            'Gần đây',
                                            style: TextStyle(
                                              fontSize: 19,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.black87,
                                              letterSpacing: -0.3,
                                            ),
                                          ),
                                          Icon(Icons.chevron_right_rounded, color: Colors.black54, size: 22),
                                        ],
                                      ),
                                      if (_searchService.recentSearches.isNotEmpty)
                                        GestureDetector(
                                          onTap: () {
                                            setState(() => _searchService.clearRecentSearches());
                                            setModalState(() {});
                                          },
                                          child: const Text('Xóa', style: TextStyle(color: Color(0xFF007AFF), fontSize: 14)),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Container(
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(16),
                                      boxShadow: [
                                        BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 8, offset: const Offset(0, 2)),
                                      ],
                                    ),
                                    child: Column(
                                      children: _searchService.recentSearches.isEmpty
                                          ? [
                                              const Padding(
                                                padding: EdgeInsets.all(16.0),
                                                child: Text('Chưa có lịch sử tìm kiếm', style: TextStyle(color: Colors.black38, fontSize: 14)),
                                              ),
                                            ]
                                          : _searchService.recentSearches.take(4).map((p) {
                                              return Column(
                                                children: [
                                                  ListTile(
                                                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                                                    leading: const Icon(Icons.search_rounded, color: Colors.black45, size: 20),
                                                    title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.black87)),
                                                    subtitle: Text(p.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.black45, fontSize: 13)),
                                                    trailing: const Icon(Icons.more_horiz_rounded, color: Colors.black38),
                                                    onTap: () {
                                                      Navigator.pop(modalCtx);
                                                      _onPlaceClicked(p);
                                                    },
                                                  ),
                                                  const Divider(height: 1, indent: 48, color: Colors.black12),
                                                ],
                                              );
                                            }).toList(),
                                    ),
                                  ),

                                  const SizedBox(height: 24),

                                  // Section 2: "Tìm lân cận" (Nearby Categories)
                                  const Text(
                                    'Tìm lân cận',
                                    style: TextStyle(
                                      fontSize: 19,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.black87,
                                      letterSpacing: -0.3,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Container(
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(16),
                                      boxShadow: [
                                        BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 8, offset: const Offset(0, 2)),
                                      ],
                                    ),
                                    child: Column(
                                      children: [
                                        _buildAppleCategoryRow('🏛️', 'Ngân Hàng và ATM', () {
                                          Navigator.pop(modalCtx);
                                          _onSelectCategory(const QuickSearchCategory(
                                            title: 'Ngân Hàng và ATM',
                                            query: 'ngân hàng, atm',
                                            icon: Icons.account_balance_rounded,
                                            color: Color(0xFF007AFF),
                                          ));
                                        }),
                                        const Divider(height: 1, indent: 48, color: Colors.black12),
                                        _buildAppleCategoryRow('🛏️', 'Khách sạn', () {
                                          Navigator.pop(modalCtx);
                                          _onSelectCategory(const QuickSearchCategory(
                                            title: 'Khách sạn',
                                            query: 'khách sạn, homestay, hotel',
                                            icon: Icons.hotel_rounded,
                                            color: Color(0xFF5856D6),
                                          ));
                                        }),
                                        const Divider(height: 1, indent: 48, color: Colors.black12),
                                        _buildAppleCategoryRow('🛍️', 'Trung tâm thương mại', () {
                                          Navigator.pop(modalCtx);
                                          _onSelectCategory(const QuickSearchCategory(
                                            title: 'Trung tâm thương mại',
                                            query: 'trung tâm thương mại, siêu thị, vincom',
                                            icon: Icons.shopping_bag_rounded,
                                            color: Color(0xFFFF9500),
                                          ));
                                        }),
                                        const Divider(height: 1, indent: 48, color: Colors.black12),
                                        _buildAppleCategoryRow('⛽', 'Cây xăng', () {
                                          Navigator.pop(modalCtx);
                                          _onSelectCategory(const QuickSearchCategory(
                                            title: 'Cây xăng',
                                            query: 'cây xăng, petrolimex',
                                            icon: Icons.local_gas_station_rounded,
                                            color: Color(0xFFFF9F1C),
                                          ));
                                        }),
                                        const Divider(height: 1, indent: 48, color: Colors.black12),
                                        _buildAppleCategoryRow('☕', 'Quán cafe & Ăn uống', () {
                                          Navigator.pop(modalCtx);
                                          _onSelectCategory(const QuickSearchCategory(
                                            title: 'Quán cafe & Ăn uống',
                                            query: 'quán cafe, cà phê, highlands, the coffee house',
                                            icon: Icons.local_cafe_rounded,
                                            color: Color(0xFF8D6E63),
                                          ));
                                        }),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 30),
                                ],
                              ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    ).whenComplete(() {
      _searchModalSetState = null;
    });
  }

  Widget _buildAppleCategoryRow(String emoji, String title, VoidCallback onTap) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: Text(emoji, style: const TextStyle(fontSize: 22)),
      title: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.black87)),
      trailing: const Icon(Icons.chevron_right_rounded, color: Colors.black26, size: 20),
      onTap: onTap,
    );
  }

  // -------------------------------------------------------------
  // Apple Maps Place Inspector Sheet (Screenshot 3)
  // -------------------------------------------------------------
  Widget _buildApplePlaceInspectorSheet(MapPlace place) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.96),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.16),
            blurRadius: 25,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Drag Handle
              Center(
                child: Container(
                  width: 36,
                  height: 5,
                  margin: const EdgeInsets.only(bottom: 10),
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    borderRadius: BorderRadius.circular(2.5),
                  ),
                ),
              ),

              // Header Row: Share, Title & Subtitle, Close X
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  IconButton(
                    icon: const Icon(Icons.ios_share_rounded, color: Color(0xFF007AFF), size: 24),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: '${place.name}\n${place.coordinate.latitude}, ${place.coordinate.longitude}'));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Đã sao chép thông tin địa điểm')),
                      );
                    },
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Text(
                          place.name,
                          style: const TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.bold,
                            color: Colors.black87,
                            letterSpacing: -0.3,
                          ),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          place.displayName.isNotEmpty ? place.displayName : 'Cửa hàng',
                          style: const TextStyle(fontSize: 13, color: Colors.black54),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        _viewMode = 0;
                        _selectedPlace = null;
                      });
                      _updateDestinationMarker();
                    },
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.black.withOpacity(0.08),
                      ),
                      child: const Icon(Icons.close_rounded, size: 18, color: Colors.black54),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 14),

              // Primary Action Buttons Row (Screenshot 3)
              Row(
                children: [
                  // Blue Directions Button (Car Icon + Travel Time e.g. "Chỉ đường")
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF007AFF),
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                      icon: _isLoadingRoutes
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.directions_car_rounded, size: 20),
                      label: Text(
                        _isLoadingRoutes
                            ? 'Đang tính đường...'
                            : (_routes.isNotEmpty
                                ? 'Chỉ đường • ${_routes.first.formattedDuration}'
                                : 'Chỉ đường'),
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      onPressed: () {
                        if (_routes.isNotEmpty && !_isLoadingRoutes) {
                          setState(() {
                            _viewMode = 2;
                          });
                          context.read<NavigationManager>().setPreviewRoute(_routes[_selectedRouteIndex]);
                          _updateRouteOnMap();
                          _fitRouteBounds(_routes[_selectedRouteIndex].polylinePoints);
                        } else {
                          _calculateRoutesForPlace(place);
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Secondary Button: Save / Bookmark Place ("Lưu địa điểm" / "Đã lưu")
                  Expanded(
                    child: Builder(
                      builder: (context) {
                        final isSaved = _savedPlacesService.isSaved(place);
                        return ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: isSaved
                                ? const Color(0xFFFF9500).withValues(alpha: 0.16)
                                : const Color(0xFFE5F0FF),
                            foregroundColor: isSaved
                                ? const Color(0xFFFF9500)
                                : const Color(0xFF007AFF),
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          ),
                          icon: Icon(
                            isSaved ? Icons.bookmark_added_rounded : Icons.bookmark_add_outlined,
                            size: 20,
                          ),
                          label: Text(
                            isSaved ? 'Đã lưu' : 'Lưu địa điểm',
                            style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.bold),
                          ),
                          onPressed: () async {
                            final resolved = await _resolvePlaceCoordinateIfNeeded(place);
                            final nowSaved = await _savedPlacesService.toggleSaved(resolved);
                            if (!mounted) return;
                            setState(() {});
                            ScaffoldMessenger.of(context).hideCurrentSnackBar();
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                backgroundColor: nowSaved ? const Color(0xFFFF9500) : const Color(0xFF1C1C1E),
                                behavior: SnackBarBehavior.floating,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                duration: const Duration(seconds: 2),
                                content: Text(
                                  nowSaved
                                      ? '⭐ Đã lưu "${resolved.name}" vào Địa điểm đã lưu'
                                      : 'Đã bỏ lưu "${resolved.name}"',
                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 14),

              // Details & Ratings Card
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF2F2F7),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Thông tin địa điểm', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.black87)),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Tọa độ GPS:', style: TextStyle(fontSize: 12, color: Colors.black54)),
                        Text(
                          '${place.coordinate.latitude.toStringAsFixed(5)}, ${place.coordinate.longitude.toStringAsFixed(5)}',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.black87),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    const Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Định tuyến:', style: TextStyle(fontSize: 12, color: Colors.black54)),
                        Text('Tìm kiếm • Dẫn đường thời gian thực', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF34C759))),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 12),

              // Bottom Action Bar: Gắn nhãn nhanh Nhà riêng / Công ty / Yêu thích / Danh sách đã lưu
              Container(
                height: 46,
                decoration: BoxDecoration(
                  color: const Color(0xFFF2F2F7),
                  borderRadius: BorderRadius.circular(23),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    IconButton(
                      tooltip: 'Lưu làm Nhà riêng',
                      icon: const Icon(Icons.home_rounded, color: Color(0xFF007AFF)),
                      onPressed: () async {
                        final resolved = await _resolvePlaceCoordinateIfNeeded(place);
                        await _savedPlacesService.savePlace(resolved, customName: 'Nhà riêng (${resolved.name})', tag: 'Nhà riêng');
                        if (!mounted) return;
                        setState(() {});
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('🏠 Đã lưu làm địa chỉ Nhà riêng')),
                        );
                      },
                    ),
                    Container(width: 1, height: 20, color: Colors.black12),
                    IconButton(
                      tooltip: 'Lưu làm Công ty',
                      icon: const Icon(Icons.business_center_rounded, color: Color(0xFF5856D6)),
                      onPressed: () async {
                        final resolved = await _resolvePlaceCoordinateIfNeeded(place);
                        await _savedPlacesService.savePlace(resolved, customName: 'Công ty (${resolved.name})', tag: 'Công ty');
                        if (!mounted) return;
                        setState(() {});
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('🏢 Đã lưu làm địa chỉ Công ty')),
                        );
                      },
                    ),
                    Container(width: 1, height: 20, color: Colors.black12),
                    IconButton(
                      tooltip: 'Lưu Yêu thích',
                      icon: Icon(
                        _savedPlacesService.isSaved(place) ? Icons.star_rounded : Icons.star_border_rounded,
                        color: const Color(0xFFFF9500),
                      ),
                      onPressed: () async {
                        final resolved = await _resolvePlaceCoordinateIfNeeded(place);
                        await _savedPlacesService.toggleSaved(resolved, tag: 'Yêu thích');
                        if (mounted) setState(() {});
                      },
                    ),
                    Container(width: 1, height: 20, color: Colors.black12),
                    IconButton(
                      tooltip: 'Mở danh sách đã lưu',
                      icon: const Icon(Icons.bookmarks_rounded, color: Colors.black87),
                      onPressed: () {
                        showSavedPlacesSheet(
                          context,
                          onSelectPlace: (p, {bool autoRoute = false}) {
                            _onPlaceClicked(p, autoCalculateRoutes: autoRoute);
                          },
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------
  // Apple Maps Route Directions Sheet (Screenshot 4)
  // -------------------------------------------------------------
  Widget _buildAppleRouteDirectionsSheet() {
    final selectedRoute = _routes.isNotEmpty ? _routes[_selectedRouteIndex] : null;
    final durationStr = selectedRoute?.formattedDuration ?? '--';
    final distanceStr = selectedRoute?.formattedDistance ?? '--';
    final etaMins = (selectedRoute?.totalDurationSeconds ?? 0) ~/ 60;
    final arrivalTime = DateTime.now().add(Duration(minutes: etaMins));
    final arrivalStr = '${arrivalTime.hour.toString().padLeft(2, '0')}:${arrivalTime.minute.toString().padLeft(2, '0')}';

    return Container(
      key: _directionsSheetKey,
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.96),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.18),
            blurRadius: 28,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Drag Handle
              Center(
                child: Container(
                  width: 36,
                  height: 5,
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    borderRadius: BorderRadius.circular(2.5),
                  ),
                ),
              ),

              // Header: Share on left, "Chỉ đường" in center with "Tùy chọn" pill, (X) on right
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    icon: const Icon(Icons.ios_share_rounded, color: Color(0xFF007AFF), size: 22),
                    onPressed: () {},
                  ),
                  Column(
                    children: [
                      const Text(
                        'Chỉ đường',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                          letterSpacing: -0.3,
                        ),
                      ),
                      const SizedBox(height: 2),
                      GestureDetector(
                        onTap: () => showMapProviderSettingsSheet(context),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: MapSettingsService().isAppleMaps
                                ? const Color(0xFFE5F0FF)
                                : const Color(0xFFFEF3C7),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                MapSettingsService().isAppleMaps ? '⚡ Tối ưu iPhone' : '🟢 Máy chủ VN',
                                style: TextStyle(
                                  color: MapSettingsService().isAppleMaps
                                      ? const Color(0xFF007AFF)
                                      : const Color(0xFFD97706),
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Icon(
                                Icons.swap_horiz_rounded,
                                color: MapSettingsService().isAppleMaps
                                    ? const Color(0xFF007AFF)
                                    : const Color(0xFFD97706),
                                size: 14,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        _viewMode = 0;
                        _routes = [];
                      });
                      _updateRouteOnMap();
                    },
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.black.withOpacity(0.08),
                      ),
                      child: const Icon(Icons.close_rounded, size: 18, color: Colors.black54),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              // Transport Mode Selector Card (🚗 🚶 🚆 🚲 🙋)
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: const Color(0xFFE5E5EA),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    _buildAppleTransportModeBtn(icon: Icons.directions_car_rounded, mode: 'driving'),
                    _buildAppleTransportModeBtn(icon: Icons.directions_walk_rounded, mode: 'foot'),
                    _buildAppleTransportModeBtn(icon: Icons.directions_transit_rounded, mode: 'transit'),
                    _buildAppleTransportModeBtn(icon: Icons.two_wheeler_rounded, mode: 'bike'),
                    _buildAppleTransportModeBtn(icon: Icons.front_hand_rounded, mode: 'hailing'),
                  ],
                ),
              ),

              const SizedBox(height: 12),

              // Waypoints List Card
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFFF2F2F7),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.near_me_rounded, color: Color(0xFF007AFF), size: 18),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            'Vị trí của tôi',
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.black87),
                          ),
                        ),
                        Icon(Icons.menu_rounded, color: Colors.black38, size: 18),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 8, top: 4, bottom: 4),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Container(width: 2, height: 16, color: Colors.black12),
                      ),
                    ),
                    Row(
                      children: [
                        const Icon(Icons.shopping_bag_rounded, color: Color(0xFFFF9500), size: 18),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _selectedPlace?.name ?? 'Điểm đến',
                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.black87),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Icon(Icons.menu_rounded, color: Colors.black38, size: 18),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 8, top: 4, bottom: 4),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Container(width: 2, height: 16, color: Colors.black12),
                      ),
                    ),
                    Row(
                      children: [
                        Container(
                          width: 18,
                          height: 18,
                          decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF007AFF)),
                          child: const Icon(Icons.add, color: Colors.white, size: 14),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            'Điểm dừng',
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF007AFF)),
                          ),
                        ),
                        const Icon(Icons.mic_none_rounded, color: Colors.black38, size: 18),
                        const SizedBox(width: 8),
                        const Icon(Icons.menu_rounded, color: Colors.black38, size: 18),
                      ],
                    ),
                  ],
                ),
              ),

              // Multi-route Choice Chips (Hiển thị các lộ trình khác nhau chuẩn Apple Maps)
              if (_routes.length > 1) ...[
                const SizedBox(height: 10),
                SizedBox(
                  height: 62,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _routes.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (context, idx) {
                      final r = _routes[idx];
                      final isSelected = idx == _selectedRouteIndex;
                      return GestureDetector(
                        onTap: () {
                          setState(() {
                            _selectedRouteIndex = idx;
                          });
                          context.read<NavigationManager>().setPreviewRoute(r);
                          _updateRouteOnMap();
                          _fitRouteBounds(r.polylinePoints);
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: isSelected ? const Color(0xFF007AFF) : Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: isSelected ? const Color(0xFF007AFF) : Colors.black12,
                              width: isSelected ? 2 : 1,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: isSelected
                                    ? const Color(0xFF007AFF).withOpacity(0.3)
                                    : Colors.black.withOpacity(0.04),
                                blurRadius: 6,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    r.formattedDuration,
                                    style: TextStyle(
                                      color: isSelected ? Colors.white : const Color(0xFF1C1C1E),
                                      fontWeight: FontWeight.bold,
                                      fontSize: 15,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    r.formattedDistance,
                                    style: TextStyle(
                                      color: isSelected ? Colors.white.withOpacity(0.85) : Colors.black54,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                idx == 0
                                    ? (MapSettingsService().isAppleMaps ? 'Nhanh nhất' : 'Nhanh nhất')
                                    : 'Tuyến ${idx + 1}',
                                style: TextStyle(
                                  color: isSelected ? Colors.white.withOpacity(0.9) : const Color(0xFF34C759),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],

              const SizedBox(height: 12),

              // Bottom Route Action Card: Large Time Info + Big Green "ĐI" Button
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF2F2F7),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            durationStr,
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: Colors.black87,
                              letterSpacing: -0.4,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Giờ đến: $arrivalStr · $distanceStr',
                            style: const TextStyle(fontSize: 13, color: Colors.black54),
                          ),
                          Text(
                            _selectedRouteIndex == 0
                                ? (MapSettingsService().isAppleMaps ? 'Nhanh nhất' : 'Nhanh nhất')
                                : 'Lộ trình thay thế ${_selectedRouteIndex + 1}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: _selectedRouteIndex == 0 ? const Color(0xFF34C759) : const Color(0xFF007AFF),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Simulation Button (Small)
                    GestureDetector(
                      onTap: () => _startDriving(isSimulation: true),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                        margin: const EdgeInsets.only(right: 8),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Colors.black12),
                        ),
                        child: const Icon(Icons.play_arrow_rounded, color: Color(0xFF007AFF), size: 22),
                      ),
                    ),
                    // Big Bright Green "ĐI" Button (Screenshot 4)
                    GestureDetector(
                      onTap: () => _startDriving(isSimulation: false),
                      child: Container(
                        width: 70,
                        height: 56,
                        decoration: BoxDecoration(
                          color: const Color(0xFF34C759),
                          borderRadius: BorderRadius.circular(18),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF34C759).withOpacity(0.4),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: const Center(
                          child: Text(
                            'ĐI',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 6),
              // Dots Page Indicator
              const Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircleAvatar(radius: 3, backgroundColor: Colors.black87),
                    SizedBox(width: 4),
                    CircleAvatar(radius: 3, backgroundColor: Colors.black26),
                    SizedBox(width: 4),
                    CircleAvatar(radius: 3, backgroundColor: Colors.black26),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAppleTransportModeBtn({required IconData icon, required String mode}) {
    final isSelected = (_transportMode == mode) ||
        (mode == 'bike' && _transportMode == 'bike') ||
        (mode == 'driving' && _transportMode == 'driving');
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() => _transportMode = (mode == 'hailing' || mode == 'transit') ? 'driving' : mode);
          if (_selectedPlace != null) {
            _calculateRoutesForPlace(_selectedPlace!);
          }
        },
        child: Container(
          height: 38,
          decoration: BoxDecoration(
            color: isSelected ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : [],
          ),
          child: Icon(
            icon,
            color: isSelected ? Colors.black87 : Colors.black45,
            size: 20,
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------
  // Google Maps Style Active Driving Turn Banner & Right Stack
  // -------------------------------------------------------------
  Widget _buildAppleActiveDrivingTurnBanner(NavigationManager navManager) {
    final isRerouting = navManager.isRerouting;
    final step = navManager.upcomingStep ?? navManager.currentStep;
    final dist = navManager.distanceToNextManeuver.round();
    final distStr = dist >= 1000 ? '${(dist / 1000).toStringAsFixed(1)} km' : '$dist m';
    final street = isRerouting
        ? 'Đang tính lại lộ trình...'
        : (step?.streetName.isNotEmpty == true ? step!.streetName : navManager.currentStreetName);
    final icon = isRerouting ? Icons.sync_rounded : (step?.icon ?? Icons.straight_rounded);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF0B6B5A),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.14),
            ),
            child: Icon(icon, color: Colors.white, size: 28),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  isRerouting ? 'Cập nhật đường đi mới' : 'Trong $distStr',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.86),
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  street,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 21,
                    fontWeight: FontWeight.bold,
                    letterSpacing: -0.3,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDrivingCircleButton({
    required IconData icon,
    Color? iconColor,
    required String tooltip,
    required VoidCallback onTap,
    bool isActive = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: isActive ? const Color(0xFFEAF3FF) : Colors.white.withValues(alpha: 0.96),
        elevation: 4,
        shadowColor: Colors.black26,
        shape: CircleBorder(
          side: BorderSide(
            color: isActive ? const Color(0xFF007AFF) : const Color(0xFFE5E5EA),
            width: isActive ? 1.8 : 1.0,
          ),
        ),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Icon(icon, color: iconColor ?? const Color(0xFF1C1C1E), size: 23),
          ),
        ),
      ),
    );
  }

  Widget _buildDrivingCompassButton(NavigationManager navManager) {
    final needleAngleRad = _isNorthUpLocked
        ? 0.0
        : (-navManager.effectiveHeading * math.pi / 180.0);
    return Tooltip(
      message: _isNorthUpLocked ? 'Xoay bản đồ theo hướng đi' : 'Ghim bản đồ hướng Bắc',
      child: Material(
        color: _isNorthUpLocked ? const Color(0xFFEAF3FF) : Colors.white.withValues(alpha: 0.96),
        elevation: 4,
        shadowColor: Colors.black26,
        shape: CircleBorder(
          side: BorderSide(
            color: _isNorthUpLocked ? const Color(0xFF007AFF) : const Color(0xFFE5E5EA),
            width: _isNorthUpLocked ? 1.8 : 1.0,
          ),
        ),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => _toggleDrivingNorthLock(navManager),
          child: SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: Transform.rotate(
                angle: needleAngleRad,
                child: CustomPaint(
                  size: const Size(24, 24),
                  painter: _CompassNeedlePainter(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _toggleDrivingNorthLock(NavigationManager navManager) {
    final ctrl = _mapController;
    if (ctrl == null) return;
    final pos = navManager.currentLocation ?? _userPosition;
    final heading = navManager.effectiveHeading;
    final nextLocked = !_isNorthUpLocked;

    HapticFeedback.selectionClick();
    _lockCameraDuringTransition(450);
    setState(() {
      _isNorthUpLocked = nextLocked;
      _isDrivingZoomOverview = false;
      _isAutoCentering = true;
    });

    final camTarget = nextLocked ? pos : _offsetCameraTarget(pos, heading, 26.0);
    ctrl.animateCamera(
      ml.CameraUpdate.newCameraPosition(
        ml.CameraPosition(
          target: ml.LatLng(camTarget.latitude, camTarget.longitude),
          zoom: nextLocked ? 16.6 : 17.4,
          tilt: nextLocked ? 0.0 : 46.0,
          bearing: nextLocked ? 0.0 : heading,
        ),
      ),
    );
  }

  void _toggleDrivingOverview(NavigationManager navManager) {
    HapticFeedback.selectionClick();
    if (_isDrivingZoomOverview) {
      _recenterToVehicle();
      return;
    }
    _lockCameraDuringTransition(520);
    setState(() {
      _isDrivingZoomOverview = true;
      _isAutoCentering = false;
    });
    final pts = navManager.remainingPolylinePoints.isNotEmpty
        ? navManager.remainingPolylinePoints
        : (navManager.activeRoute?.polylinePoints ?? <LatLng>[]);
    final ctrl = _mapController;
    if (ctrl != null && pts.isNotEmpty) {
      double minLat = pts.first.latitude, maxLat = pts.first.latitude;
      double minLng = pts.first.longitude, maxLng = pts.first.longitude;
      for (final p in pts) {
        if (p.latitude < minLat) minLat = p.latitude;
        if (p.latitude > maxLat) maxLat = p.latitude;
        if (p.longitude < minLng) minLng = p.longitude;
        if (p.longitude > maxLng) maxLng = p.longitude;
      }
      final span = math.max((maxLat - minLat).abs(), (maxLng - minLng).abs()).clamp(0.002, 20.0);
      final approxZoom = (math.log(360.0 / span) / math.ln2 - 1.5).clamp(5.0, 16.0);
      unawaited(() async {
        try {
          await ctrl.moveCamera(
            ml.CameraUpdate.newCameraPosition(
              ml.CameraPosition(
                target: ml.LatLng((minLat + maxLat) / 2, (minLng + maxLng) / 2),
                zoom: approxZoom,
                tilt: 0.0,
                bearing: 0.0,
              ),
            ),
          );
        } catch (_) {}
        if (mounted && _isDrivingZoomOverview) {
          _fitRouteBounds(pts, topPadding: 145.0, bottomPadding: 190.0);
        }
      }());
    }
  }

  double _minDistanceToPolyline(LatLng point, List<LatLng> polyline) {
    if (polyline.isEmpty) return 0.0;
    const distCalc = Distance();
    double minDist = double.infinity;
    final step = polyline.length > 150 ? (polyline.length ~/ 150).clamp(1, 10) : 1;
    for (int i = 0; i < polyline.length; i += step) {
      final d = distCalc.as(LengthUnit.Meter, point, polyline[i]);
      if (d < minDist) minDist = d;
    }
    final lastDist = distCalc.as(LengthUnit.Meter, point, polyline.last);
    return math.min(minDist, lastDist);
  }

  Future<void> _openDrivingAlongRouteSearchModal() async {
    final navManager = Provider.of<NavigationManager>(context, listen: false);
    final userPos = navManager.currentLocation ?? _userPosition;
    final remainingPts = navManager.remainingPolylinePoints.isNotEmpty
        ? navManager.remainingPolylinePoints
        : <LatLng>[userPos];

    final searchCtrl = TextEditingController();
    Timer? debounce;
    bool isSearching = false;
    String activeQuery = '';
    String? routingButtonKey;
    String? modalError;
    int searchToken = 0;
    List<({MapPlace place, double fromUserMeters, double offRouteMeters})> results = [];

    const quickChips = <({String label, String query, IconData icon})>[
      (label: 'Cây xăng', query: 'Cây xăng', icon: Icons.local_gas_station_rounded),
      (label: 'Cà phê', query: 'Cà phê', icon: Icons.local_cafe_rounded),
      (label: 'Sửa xe', query: 'Sửa xe máy', icon: Icons.build_rounded),
      (label: 'ATM', query: 'ATM', icon: Icons.atm_rounded),
      (label: 'Nhà thuốc', query: 'Nhà thuốc', icon: Icons.local_pharmacy_rounded),
      (label: 'Quán ăn', query: 'Quán ăn', icon: Icons.restaurant_rounded),
    ];

    bool hasValidCoord(MapPlace p) =>
        p.coordinate.latitude.abs() > 0.001 || p.coordinate.longitude.abs() > 0.001;

    List<LatLng> buildRouteAnchors() {
      final anchors = <LatLng>[userPos];
      if (remainingPts.length >= 6) {
        final p1 = remainingPts[(remainingPts.length * 0.35).floor()];
        final p2 = remainingPts[(remainingPts.length * 0.70).floor()];
        const distCalc = Distance();
        if (distCalc.as(LengthUnit.Meter, userPos, p1) > 400) {
          anchors.add(p1);
        }
        if (distCalc.as(LengthUnit.Meter, p1, p2) > 500) {
          anchors.add(p2);
        }
      }
      return anchors;
    }

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (modalCtx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            Future<void> runSearch(String query) async {
              final q = query.trim();
              final myToken = ++searchToken;
              if (q.isEmpty) {
                setModalState(() {
                  activeQuery = '';
                  results = [];
                  isSearching = false;
                  modalError = null;
                });
                return;
              }
              setModalState(() {
                activeQuery = q;
                isSearching = true;
                modalError = null;
              });
              final anchors = buildRouteAnchors();
              try {
                final candidates = <MapPlace>[];
                if (AppleMapsService.isSupported) {
                  final appleBatches = await Future.wait(
                    anchors.map((a) => AppleMapsService().searchPlaces(q, nearLocation: a, limit: 8)),
                  );
                  for (final b in appleBatches) {
                    candidates.addAll(b);
                  }
                }
                if (candidates.where(hasValidCoord).length < 4) {
                  final fallbackBatch = await _searchService.searchPlaces(q, nearLocation: anchors.first);
                  candidates.addAll(fallbackBatch);
                }

                // Phân giải tọa độ cho các kết quả Goong trả về (0, 0) trước khi tính khoảng cách
                final needsResolve = candidates.where((p) => !hasValidCoord(p)).take(6).toList();
                final resolvedExtras = needsResolve.isNotEmpty
                    ? await Future.wait(needsResolve.map(_resolvePlaceCoordinateIfNeeded))
                    : const <MapPlace>[];

                if (myToken != searchToken) return;

                final allPlaces = <MapPlace>[
                  ...candidates.where(hasValidCoord),
                  ...resolvedExtras.where(hasValidCoord),
                ];

                final seen = <String>{};
                final merged = <({MapPlace place, double fromUserMeters, double offRouteMeters})>[];
                const distCalc = Distance();

                for (final p in allPlaces) {
                  final key =
                      '${p.coordinate.latitude.toStringAsFixed(4)},${p.coordinate.longitude.toStringAsFixed(4)}_${p.name.trim().toLowerCase()}';
                  if (seen.add(key)) {
                    final dUser = distCalc.as(LengthUnit.Meter, userPos, p.coordinate);
                    final dRoute = _minDistanceToPolyline(p.coordinate, remainingPts);
                    merged.add((place: p, fromUserMeters: dUser, offRouteMeters: dRoute));
                  }
                }
                merged.sort((a, b) {
                  final scoreA = a.offRouteMeters * 1.5 + a.fromUserMeters * 0.25;
                  final scoreB = b.offRouteMeters * 1.5 + b.fromUserMeters * 0.25;
                  return scoreA.compareTo(scoreB);
                });
                if (ctx.mounted && myToken == searchToken) {
                  setModalState(() {
                    results = merged.take(15).toList();
                    isSearching = false;
                  });
                }
              } catch (_) {
                if (ctx.mounted && myToken == searchToken) {
                  setModalState(() {
                    isSearching = false;
                    modalError = 'Không thể tìm kiếm lúc này. Vui lòng thử lại.';
                  });
                }
              }
            }

            return Container(
              height: MediaQuery.of(ctx).size.height * 0.78,
              decoration: const BoxDecoration(
                color: Color(0xFFF2F2F7),
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(
                children: [
                  const SizedBox(height: 10),
                  Container(
                    width: 38,
                    height: 5,
                    decoration: BoxDecoration(
                      color: Colors.black26,
                      borderRadius: BorderRadius.circular(2.5),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Tìm kiếm trên lộ trình',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF1C1C1E),
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(modalCtx),
                          icon: const Icon(Icons.close_rounded, color: Color(0xFF8E8E93)),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: TextField(
                      controller: searchCtrl,
                      textInputAction: TextInputAction.search,
                      onChanged: (val) {
                        setModalState(() {});
                        debounce?.cancel();
                        debounce = Timer(const Duration(milliseconds: 350), () => runSearch(val));
                      },
                      onSubmitted: runSearch,
                      style: const TextStyle(color: Color(0xFF1C1C1E), fontSize: 15),
                      decoration: InputDecoration(
                        hintText: 'Tìm cây xăng, cà phê, ATM quanh đường đi...',
                        hintStyle: const TextStyle(color: Color(0xFF8E8E93), fontSize: 14),
                        prefixIcon: const Icon(Icons.search_rounded, color: Color(0xFF007AFF)),
                        suffixIcon: searchCtrl.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear_rounded, color: Color(0xFF8E8E93), size: 18),
                                onPressed: () {
                                  searchCtrl.clear();
                                  runSearch('');
                                },
                              )
                            : null,
                        filled: true,
                        fillColor: Colors.white,
                        contentPadding: const EdgeInsets.symmetric(vertical: 12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 38,
                    child: ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      scrollDirection: Axis.horizontal,
                      itemCount: quickChips.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (_, idx) {
                        final chip = quickChips[idx];
                        final selected = activeQuery.toLowerCase() == chip.query.toLowerCase();
                        return GestureDetector(
                          onTap: () {
                            searchCtrl.text = chip.query;
                            runSearch(chip.query);
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: selected ? const Color(0xFF007AFF) : Colors.white,
                              borderRadius: BorderRadius.circular(19),
                              border: Border.all(
                                color: selected ? const Color(0xFF007AFF) : const Color(0xFFE5E5EA),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  chip.icon,
                                  size: 16,
                                  color: selected ? Colors.white : const Color(0xFF007AFF),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  chip.label,
                                  style: TextStyle(
                                    color: selected ? Colors.white : const Color(0xFF1C1C1E),
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  if (modalError != null)
                    Container(
                      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF3B30).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.error_outline_rounded, color: Color(0xFFFF3B30), size: 16),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              modalError!,
                              style: const TextStyle(color: Color(0xFFC62828), fontSize: 12.5, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: isSearching
                        ? const Center(
                            child: CupertinoActivityIndicator(radius: 14),
                          )
                        : activeQuery.isEmpty
                            ? const Center(
                                child: Padding(
                                  padding: EdgeInsets.all(24.0),
                                  child: Text(
                                    'Chọn nhanh danh mục phía trên hoặc nhập địa điểm muốn tìm dọc theo lộ trình hiện tại.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(color: Color(0xFF8E8E93), fontSize: 14, height: 1.4),
                                  ),
                                ),
                              )
                            : results.isEmpty
                                ? const Center(
                                    child: Text(
                                      'Không tìm thấy địa điểm phù hợp quanh lộ trình',
                                      style: TextStyle(color: Color(0xFF8E8E93), fontSize: 14),
                                    ),
                                  )
                                : ListView.separated(
                                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
                                    itemCount: results.length,
                                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                                    itemBuilder: (_, idx) {
                                      final item = results[idx];
                                      final p = item.place;
                                      final itemBaseKey =
                                          '${p.coordinate.latitude.toStringAsFixed(5)}_${p.coordinate.longitude.toStringAsFixed(5)}_${p.name}';
                                      final stopKey = '${itemBaseKey}_stop';
                                      final directKey = '${itemBaseKey}_direct';
                                      final isStopBusy = routingButtonKey == stopKey;
                                      final isDirectBusy = routingButtonKey == directKey;
                                      final isAnyBusy = routingButtonKey != null;

                                      final userDistStr = item.fromUserMeters >= 1000
                                          ? '${(item.fromUserMeters / 1000).toStringAsFixed(1)} km'
                                          : '${item.fromUserMeters.round()} m';
                                      final routeTag = item.offRouteMeters <= 250
                                          ? 'Trên lộ trình'
                                          : 'Cách đường ${item.offRouteMeters >= 1000 ? "${(item.offRouteMeters / 1000).toStringAsFixed(1)} km" : "${item.offRouteMeters.round()} m"}';

                                      return Container(
                                        padding: const EdgeInsets.all(14),
                                        decoration: BoxDecoration(
                                          color: Colors.white,
                                          borderRadius: BorderRadius.circular(16),
                                          border: Border.all(color: const Color(0xFFE5E5EA)),
                                        ),
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Expanded(
                                                  child: Text(
                                                    p.name,
                                                    style: const TextStyle(
                                                      color: Color(0xFF1C1C1E),
                                                      fontWeight: FontWeight.w700,
                                                      fontSize: 15,
                                                    ),
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis,
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                                Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                                  decoration: BoxDecoration(
                                                    color: const Color(0xFF34C759).withValues(alpha: 0.12),
                                                    borderRadius: BorderRadius.circular(8),
                                                  ),
                                                  child: Text(
                                                    '$userDistStr · $routeTag',
                                                    style: const TextStyle(
                                                      color: Color(0xFF1E8E3E),
                                                      fontSize: 11,
                                                      fontWeight: FontWeight.w700,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              p.displayName,
                                              style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 12.5),
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            const SizedBox(height: 10),
                                            Row(
                                              children: [
                                                Expanded(
                                                  child: ElevatedButton.icon(
                                                    style: ElevatedButton.styleFrom(
                                                      backgroundColor: const Color(0xFF007AFF),
                                                      foregroundColor: Colors.white,
                                                      elevation: 0,
                                                      padding: const EdgeInsets.symmetric(vertical: 9),
                                                      shape: RoundedRectangleBorder(
                                                        borderRadius: BorderRadius.circular(10),
                                                      ),
                                                    ),
                                                    onPressed: isAnyBusy
                                                        ? null
                                                        : () async {
                                                            HapticFeedback.selectionClick();
                                                            setModalState(() {
                                                              routingButtonKey = stopKey;
                                                              modalError = null;
                                                            });
                                                            final ok = await _routeAlongWithStop(p);
                                                            if (ok) {
                                                              if (modalCtx.mounted) Navigator.pop(modalCtx);
                                                            } else if (ctx.mounted) {
                                                              setModalState(() {
                                                                routingButtonKey = null;
                                                                modalError = 'Không thể ghép đường ghé "${p.name}".';
                                                              });
                                                            }
                                                          },
                                                    icon: isStopBusy
                                                        ? const SizedBox(
                                                            width: 14,
                                                            height: 14,
                                                            child: CupertinoActivityIndicator(color: Colors.white, radius: 7),
                                                          )
                                                        : const Icon(Icons.add_road_rounded, size: 16),
                                                    label: const Text(
                                                      'Ghé qua điểm này',
                                                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                                OutlinedButton(
                                                  style: OutlinedButton.styleFrom(
                                                    foregroundColor: const Color(0xFF1C1C1E),
                                                    side: const BorderSide(color: Color(0xFFD1D1D6)),
                                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                                                    shape: RoundedRectangleBorder(
                                                      borderRadius: BorderRadius.circular(10),
                                                    ),
                                                  ),
                                                  onPressed: isAnyBusy
                                                      ? null
                                                      : () async {
                                                          HapticFeedback.selectionClick();
                                                          setModalState(() {
                                                            routingButtonKey = directKey;
                                                            modalError = null;
                                                          });
                                                          final ok = await _routeDirectlyToPlace(p);
                                                          if (ok) {
                                                            if (modalCtx.mounted) Navigator.pop(modalCtx);
                                                          } else if (ctx.mounted) {
                                                            setModalState(() {
                                                              routingButtonKey = null;
                                                              modalError = 'Không tìm thấy đường đi tới "${p.name}".';
                                                            });
                                                          }
                                                        },
                                                  child: isDirectBusy
                                                      ? const CupertinoActivityIndicator(radius: 7)
                                                      : const Text(
                                                          'Đi thẳng',
                                                          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                                                        ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
    debounce?.cancel();
    searchCtrl.dispose();
  }

  Future<bool> _routeAlongWithStop(MapPlace rawStop) async {
    final navManager = Provider.of<NavigationManager>(context, listen: false);
    final startPos = navManager.currentLocation ?? _userPosition;
    final currentPts = navManager.activeRoute?.polylinePoints ?? <LatLng>[];
    final stop = await _resolvePlaceCoordinateIfNeeded(rawStop);
    if (stop.coordinate.latitude.abs() < 0.001 && stop.coordinate.longitude.abs() < 0.001) {
      return false;
    }

    final finalDest = _queuedFinalDestination ??
        _selectedPlace ??
        (currentPts.isNotEmpty
            ? MapPlace(displayName: 'Điểm đến', name: 'Điểm đến', coordinate: currentPts.last)
            : stop);
    final wasSim = navManager.isSimulating;

    try {
      final legs = await Future.wait([
        _directionsService.calculateMultipleRoutes(startPos, stop.coordinate, mode: _transportMode),
        _directionsService.calculateMultipleRoutes(stop.coordinate, finalDest.coordinate, mode: _transportMode),
      ]);
      final leg1List = legs[0];
      final leg2List = legs[1];
      if (leg1List.isEmpty || leg2List.isEmpty || !mounted) return false;

      final leg1 = leg1List.first;
      final leg2 = leg2List.first;
      final stitchedPts = <LatLng>[
        ...leg1.polylinePoints,
        if (leg2.polylinePoints.isNotEmpty) ...leg2.polylinePoints.skip(1),
      ];
      final stitchedSteps = <NavStep>[];
      int idx = 0;
      for (final s in leg1.steps) {
        final isLegEnd = s.maneuverTypeStr == 'arrive';
        stitchedSteps.add(
          NavStep(
            stepIndex: idx++,
            instruction: isLegEnd ? 'Ghé điểm dừng ${stop.name}, sau đó tiếp tục đi' : s.instruction,
            streetName: isLegEnd ? stop.name : s.streetName,
            distanceMeters: s.distanceMeters,
            durationSeconds: s.durationSeconds,
            coordinate: s.coordinate,
            maneuverTypeStr: isLegEnd ? 'straight' : s.maneuverTypeStr,
            maneuverModifier: isLegEnd ? 'straight' : s.maneuverModifier,
          ),
        );
      }
      for (int i = 0; i < leg2.steps.length; i++) {
        final s = leg2.steps[i];
        if (i == 0 && s.maneuverType == ManeuverType.depart) continue;
        stitchedSteps.add(
          NavStep(
            stepIndex: idx++,
            instruction: s.instruction,
            streetName: s.streetName,
            distanceMeters: s.distanceMeters,
            durationSeconds: s.durationSeconds,
            coordinate: s.coordinate,
            maneuverTypeStr: s.maneuverTypeStr,
            maneuverModifier: s.maneuverModifier,
          ),
        );
      }

      final combinedRoute = NavRoute(
        totalDistanceMeters: leg1.totalDistanceMeters + leg2.totalDistanceMeters,
        totalDurationSeconds: leg1.totalDurationSeconds + leg2.totalDurationSeconds,
        polylinePoints: stitchedPts,
        steps: stitchedSteps,
        summary: 'Qua ${stop.name}',
        title: 'Qua ${stop.name}',
        subtitle: finalDest.name,
        isFastest: true,
        themeColor: const Color(0xFF007AFF),
      );

      setState(() {
        _routes = [combinedRoute];
        _selectedRouteIndex = 0;
        _selectedPlace = finalDest;
        _queuedFinalDestination = finalDest;
        _isAutoCentering = true;
        _isDrivingZoomOverview = false;
        _cameraLockUntil = DateTime.fromMillisecondsSinceEpoch(0);
        _lastLineTrimPos = null;
      });
      if (wasSim) {
        navManager.startSimulation(combinedRoute);
      } else {
        navManager.startNavigation(combinedRoute);
      }
      _updateRouteOnMap();
      _updateDestinationMarker();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF34C759),
            content: Text(
              'Đã thêm điểm ghé qua ${stop.name}',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
            ),
          ),
        );
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _routeDirectlyToPlace(MapPlace rawDest) async {
    final navManager = Provider.of<NavigationManager>(context, listen: false);
    final startPos = navManager.currentLocation ?? _userPosition;
    final dest = await _resolvePlaceCoordinateIfNeeded(rawDest);
    if (dest.coordinate.latitude.abs() < 0.001 && dest.coordinate.longitude.abs() < 0.001) {
      return false;
    }

    final wasSim = navManager.isSimulating;
    try {
      final newRoutes = await _directionsService.calculateMultipleRoutes(
        startPos,
        dest.coordinate,
        mode: _transportMode,
      );
      if (newRoutes.isEmpty || !mounted) return false;
      final chosen = newRoutes.first;
      setState(() {
        _routes = newRoutes;
        _selectedRouteIndex = 0;
        _selectedPlace = dest;
        _queuedFinalDestination = dest;
        _isAutoCentering = true;
        _isDrivingZoomOverview = false;
        _cameraLockUntil = DateTime.fromMillisecondsSinceEpoch(0);
        _lastLineTrimPos = null;
      });
      if (wasSim) {
        navManager.startSimulation(chosen);
      } else {
        navManager.startNavigation(chosen);
      }
      _updateRouteOnMap();
      _updateDestinationMarker();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _stopDrivingAndReset(NavigationManager navManager) async {
    navManager.stopNavigation();
    navManager.setPreviewRoute(null);
    await _mapController?.clearLines();
    await _mapController?.clearCircles();
    setState(() {
      _viewMode = 0;
      _routes = [];
      _selectedPlace = null;
      _queuedFinalDestination = null;
      _isDrivingZoomOverview = false;
      _isNorthUpLocked = false;
      _isCameraMoveInFlight = false;
      _lastLineTrimPos = null;
    });
    _updateDestinationMarker();
    final pos = navManager.currentLocation ?? _userPosition;
    _mapController?.animateCamera(
      ml.CameraUpdate.newCameraPosition(
        ml.CameraPosition(
          target: ml.LatLng(pos.latitude, pos.longitude),
          zoom: 16.5,
          tilt: 0.0,
          bearing: 0.0,
        ),
      ),
    );
  }

  Widget _buildAppleActiveDrivingBottomHud(NavigationManager navManager, BleService bleService) {
    final etaMins = navManager.remainingEtaMinutes;
    final now = DateTime.now().add(Duration(minutes: etaMins));
    final timeStr = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final hours = etaMins ~/ 60;
    final remMins = etaMins % 60;
    final durationLabel = hours > 0
        ? (remMins > 0 ? '$hours giờ $remMins phút' : '$hours giờ')
        : '$remMins phút';
    final totalMeters = navManager.remainingTotalDistance.round();
    final distFormatted = totalMeters >= 1000
        ? (totalMeters >= 10000
            ? '${(totalMeters / 1000).toStringAsFixed(0)} km'
            : '${(totalMeters / 1000).toStringAsFixed(1)} km')
        : '$totalMeters m';

    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 14),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFE5E5EA)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.14),
            blurRadius: 18,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Flexible(
                      child: Text(
                        durationLabel,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF1C1C1E),
                          letterSpacing: -0.5,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    const Icon(Icons.eco_rounded, color: Color(0xFF34C759), size: 19),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '$distFormatted · $timeStr',
                  style: const TextStyle(
                    fontSize: 15,
                    color: Color(0xFF8E8E93),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          GestureDetector(
            onTap: () => _stopDrivingAndReset(navManager),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 13),
              decoration: BoxDecoration(
                color: const Color(0xFFFF3B30),
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFFF3B30).withValues(alpha: 0.30),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: const Text(
                'Thoát',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------
  // Map Theme Picker Dialog (Unified iOS Light Theme)
  // -------------------------------------------------------------
  void _showMapThemePicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'CHỌN GIAO DIỆN BẢN ĐỒ',
                style: TextStyle(color: Color(0xFF007AFF), fontWeight: FontWeight.bold, fontSize: 13, letterSpacing: 1),
              ),
              const SizedBox(height: 14),
              _buildThemeOption(
                title: 'Bản đồ Đường phố (Streets)',
                subtitle: 'Giao diện vector sắc nét, tải nhanh chuẩn vector',
                mode: MapThemeMode.streets,
                icon: Icons.map_rounded,
              ),
              _buildThemeOption(
                title: 'Vệ tinh lai (Hybrid Satellite)',
                subtitle: 'Ảnh chụp vệ tinh độ nét cao kèm tên đường tiếng Việt',
                mode: MapThemeMode.satellite,
                icon: Icons.satellite_alt_rounded,
              ),
              _buildThemeOption(
                title: 'Chế độ Ban Đêm (Navigation Dark)',
                subtitle: 'Theme tối độ tương phản cao, dịu mắt khi lái xe đêm',
                mode: MapThemeMode.navigationNight,
                icon: Icons.dark_mode_rounded,
              ),
              _buildThemeOption(
                title: 'Giao diện Tối (Dark Minimal)',
                subtitle: 'Theme tối tối giản',
                mode: MapThemeMode.dark,
                icon: Icons.nightlight_round,
              ),
              const Divider(color: Color(0xFFE5E5EA), height: 24),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: (GoongConfig.isConfigured ? const Color(0xFF34C759) : const Color(0xFFFF9500))
                        .withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: (GoongConfig.isConfigured ? const Color(0xFF34C759) : const Color(0xFFFF9500))
                          .withValues(alpha: 0.45),
                    ),
                  ),
                  child: Icon(
                    Icons.vpn_key_rounded,
                    color: GoongConfig.isConfigured ? const Color(0xFF1E8E3E) : const Color(0xFFFF9500),
                    size: 20,
                  ),
                ),
                title: const Text(
                  'Cấu hình khóa bản đồ',
                  style: TextStyle(color: Color(0xFF1C1C1E), fontWeight: FontWeight.bold, fontSize: 14),
                ),
                subtitle: Text(
                  GoongConfig.isConfigured
                      ? 'Đang kích hoạt bản đồ & dẫn đường chuẩn VN'
                      : 'Chưa cấu hình (Bấm vào đây để nhập khóa bản đồ)',
                  style: TextStyle(
                    color: GoongConfig.isConfigured ? const Color(0xFF1E8E3E) : const Color(0xFF8E8E93),
                    fontSize: 11.5,
                  ),
                ),
                trailing: const Icon(Icons.chevron_right_rounded, color: Color(0xFF8E8E93)),
                onTap: () {
                  Navigator.pop(context);
                  _showGoongKeyDialog();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  /// Dialog nhập MapTiles Key và REST API Key của Goong Map (Unified iOS Light Theme)
  void _showGoongKeyDialog() {
    final mapTilesCtrl = TextEditingController(text: GoongConfig.maptilesKey);
    final restApiCtrl = TextEditingController(text: GoongConfig.restApiKey);

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Row(
            children: [
              Icon(Icons.map_rounded, color: Color(0xFF007AFF), size: 22),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Cấu hình khóa bản đồ',
                  style: TextStyle(color: Color(0xFF1C1C1E), fontSize: 17, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Hệ thống bản đồ chuẩn Việt Nam, tìm chính xác số nhà, ngõ ngách và dẫn đường phân làn xe máy chuẩn xác.',
                  style: TextStyle(color: Color(0xFF636366), fontSize: 12.5, height: 1.4),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: mapTilesCtrl,
                  style: const TextStyle(color: Color(0xFF1C1C1E), fontSize: 13),
                  decoration: InputDecoration(
                    labelText: '1. MapTiles Key (Hiển thị bản đồ)',
                    labelStyle: const TextStyle(color: Color(0xFF007AFF), fontSize: 12, fontWeight: FontWeight.w600),
                    hintText: 'Dán khóa hiển thị bản đồ (MapTiles key)',
                    hintStyle: const TextStyle(color: Color(0xFFC7C7CC), fontSize: 11),
                    filled: true,
                    fillColor: const Color(0xFFF2F2F7),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0xFFE5E5EA)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0xFFE5E5EA)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0xFF007AFF), width: 1.5),
                    ),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: restApiCtrl,
                  style: const TextStyle(color: Color(0xFF1C1C1E), fontSize: 13),
                  decoration: InputDecoration(
                    labelText: '2. REST API Key (Tìm kiếm & Dẫn đường)',
                    labelStyle: const TextStyle(color: Color(0xFF1E8E3E), fontSize: 12, fontWeight: FontWeight.w600),
                    hintText: 'Dán khóa dịch vụ (API key)',
                    hintStyle: const TextStyle(color: Color(0xFFC7C7CC), fontSize: 11),
                    filled: true,
                    fillColor: const Color(0xFFF2F2F7),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0xFFE5E5EA)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0xFFE5E5EA)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0xFF007AFF), width: 1.5),
                    ),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF2F2F7),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.info_outline_rounded, color: Color(0xFF007AFF), size: 15),
                      SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Khóa miễn phí do nhà cung cấp bản đồ cấp',
                          style: TextStyle(color: Color(0xFF3A3A3C), fontSize: 11.5),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Hủy', style: TextStyle(color: Color(0xFF8E8E93), fontWeight: FontWeight.w600)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF007AFF),
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () {
                setState(() {
                  GoongConfig.maptilesKey = mapTilesCtrl.text.trim();
                  GoongConfig.restApiKey = restApiCtrl.text.trim();
                });
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    backgroundColor: const Color(0xFF34C759),
                    content: Text(
                      GoongConfig.isConfigured
                          ? 'Đã kích hoạt toàn bộ dịch vụ bản đồ thành công!'
                          : 'Đã lưu cấu hình bản đồ',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ),
                );
              },
              child: const Text('Lưu Key', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  Widget _buildThemeOption({
    required String title,
    required String subtitle,
    required MapThemeMode mode,
    required IconData icon,
  }) {
    final isSelected = _currentTheme == mode;
    return Material(
      color: Colors.transparent,
      child: ListTile(
        leading: Icon(icon, color: isSelected ? const Color(0xFF007AFF) : const Color(0xFF8E8E93)),
        title: Text(
          title,
          style: TextStyle(
            color: isSelected ? const Color(0xFF007AFF) : const Color(0xFF1C1C1E),
            fontWeight: FontWeight.bold,
            fontSize: 14,
          ),
        ),
        subtitle: Text(subtitle, style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 12)),
        trailing: isSelected ? const Icon(Icons.check_circle_rounded, color: Color(0xFF007AFF)) : null,
        onTap: () {
          setState(() => _currentTheme = mode);
          try {
            final streamService = Provider.of<EspStreamService>(context, listen: false);
            if (!streamService.hasUserSelectedMapStyle || streamService.streamMapStyle.startsWith('osm-3d')) {
              if (mode == MapThemeMode.dark || mode == MapThemeMode.navigationNight) {
                streamService.streamMapStyle = 'osm-3d-dark';
              } else {
                streamService.streamMapStyle = 'osm-3d';
              }
            }
          } catch (_) {}
          Navigator.pop(context);
        },
      ),
    );
  }

  Widget _buildBleStatusBadge(BleService bleService) {
    final isConnected = bleService.isConnected;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isConnected ? const Color(0xFF34C759) : const Color(0xFFE5E5EA),
        ),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isConnected ? Icons.bluetooth_connected_rounded : Icons.bluetooth_disabled_rounded,
            size: 14,
            color: isConnected ? const Color(0xFF1E8E3E) : const Color(0xFF8E8E93),
          ),
          const SizedBox(width: 6),
          Text(
            isConnected ? '${bleService.customBleName} Live' : '${bleService.customBleName} Off',
            style: TextStyle(
              color: isConnected ? const Color(0xFF1E8E3E) : const Color(0xFF8E8E93),
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------
  // NHIỆM VỤ 3: Thanh tìm nhanh Tiện ích (⛽ Cây xăng, ⚡ Trạm sạc, 🅿️ Bãi đỗ xe)
  // -------------------------------------------------------------
  Widget _buildQuickUtilityChipsBar(NavigationManager navManager, {bool compact = false}) {
    const items = <({
      String key,
      String emoji,
      String label,
      String keyword,
      Color accent,
    })>[
      (key: 'fuel', emoji: '⛽', label: 'Cây xăng', keyword: 'cây xăng', accent: Color(0xFFEF4444)),
      (key: 'charging_station', emoji: '⚡', label: 'Trạm sạc', keyword: 'trạm sạc VinFast', accent: Color(0xFF10B981)),
      (key: 'parking', emoji: '🅿️', label: 'Bãi đỗ xe', keyword: 'bãi đỗ xe', accent: Color(0xFF2563EB)),
    ];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final item in items) ...[
            GestureDetector(
              onTap: () => _onQuickUtilityChipTapped(
                key: item.key,
                keyword: item.keyword,
                label: item.label,
                navManager: navManager,
              ),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 10 : 12,
                  vertical: compact ? 6 : 7,
                ),
                decoration: BoxDecoration(
                  color: _activeUtilityKey == item.key
                      ? item.accent
                      : Colors.white.withValues(alpha: 0.94),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: _activeUtilityKey == item.key
                        ? item.accent
                        : Colors.black.withValues(alpha: 0.08),
                    width: 1.0,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.10),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_isLoadingUtilities && _activeUtilityKey == item.key)
                      const SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    else
                      Text(item.emoji, style: TextStyle(fontSize: compact ? 12.5 : 13.5)),
                    const SizedBox(width: 5),
                    Text(
                      item.label,
                      style: TextStyle(
                        color: _activeUtilityKey == item.key
                            ? Colors.white
                            : const Color(0xFF1C1C1E),
                        fontSize: compact ? 12 : 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          if (_activeUtilityKey != null)
            GestureDetector(
              onTap: _clearQuickUtilities,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.close_rounded, color: Colors.white, size: 14),
                    SizedBox(width: 3),
                    Text(
                      'Ẩn',
                      style: TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _onQuickUtilityChipTapped({
    required String key,
    required String keyword,
    required String label,
    required NavigationManager navManager,
  }) async {
    HapticFeedback.selectionClick();
    if (_activeUtilityKey == key && !_isLoadingUtilities) {
      _clearQuickUtilities();
      return;
    }

    final center = navManager.currentLocation ?? _userPosition;
    setState(() {
      _activeUtilityKey = key;
      _isLoadingUtilities = true;
      _utilityResults = [];
      _selectedUtilityPoi = null;
    });

    final results = await GoongService().searchNearbyUtilities(
      center,
      keyword: keyword,
      amenityTag: key,
      categoryLabel: label,
      radiusMeters: 5000,
      limit: 12,
    );

    if (!mounted || _activeUtilityKey != key) return;
    setState(() {
      _isLoadingUtilities = false;
      _utilityResults = results;
      _selectedUtilityPoi = results.isNotEmpty ? results.first : null;
    });
    await _updateDestinationMarker();
    if (!mounted) return;

    if (results.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text('Không tìm thấy $label trong bán kính 5 km quanh bạn.'),
        ),
      );
      return;
    }

    if (!navManager.isNavigating) {
      final pts = <LatLng>[center, ...results.take(5).map((e) => e.coordinate)];
      _fitRouteBounds(pts, topPadding: 140, bottomPadding: 220);
    }
  }

  void _clearQuickUtilities() {
    setState(() {
      _activeUtilityKey = null;
      _isLoadingUtilities = false;
      _utilityResults = [];
      _selectedUtilityPoi = null;
    });
    _updateDestinationMarker();
  }

  Widget _buildSelectedUtilityPoiCard(MapPlace poi, {required bool isDriving}) {
    final String badgeEmoji = switch (_activeUtilityKey) {
      'fuel' => '⛽',
      'charging_station' => '⚡',
      'parking' => '🅿️',
      _ => '📍',
    };
    final double? distM = poi.distanceMeters;
    final String distLabel = distM == null
        ? ''
        : (distM >= 1000
            ? '${(distM / 1000.0).toStringAsFixed(1)} km'
            : '${distM.round()} m');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.97),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.black.withValues(alpha: 0.08)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.16),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: const Color(0xFFF2F2F7),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(child: Text(badgeEmoji, style: const TextStyle(fontSize: 20))),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  poi.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF1C1C1E),
                    fontSize: 14.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  distLabel.isNotEmpty
                      ? '$distLabel • ${poi.displayName}'
                      : poi.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF636366),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF34C759),
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            onPressed: () async {
              final target = poi;
              _clearQuickUtilities();
              if (isDriving) {
                final navManager = Provider.of<NavigationManager>(context, listen: false);
                final startPos = navManager.currentLocation ?? _userPosition;
                final routes = await _directionsService.calculateMultipleRoutes(
                  startPos,
                  target.coordinate,
                  mode: _transportMode,
                  bypassCache: true,
                );
                if (!mounted || routes.isEmpty) return;
                setState(() {
                  _selectedPlace = target;
                  _routes = routes;
                  _selectedRouteIndex = 0;
                });
                navManager.startNavigation(routes.first);
                _updateRouteOnMap();
                _updateDestinationMarker();
              } else {
                await _calculateRoutesForPlace(target);
              }
            },
            child: const Text(
              'Đi tới đây',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: () => setState(() => _selectedUtilityPoi = null),
            child: const Icon(Icons.close_rounded, color: Color(0xFF8E8E93), size: 20),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------
  // NHIỆM VỤ 4: Cụm Biển báo tốc độ viền đỏ + Bong bóng tốc độ + Camera phạt nguội khi dẫn đường
  // -------------------------------------------------------------
  Widget _buildDrivingTrafficHudCluster(NavigationManager navManager) {
    final alertEngine = navManager.alertEngine;
    final int speedKmh = navManager.currentSpeedKmh.round();
    final int speedLimit = alertEngine.currentSpeedLimitKmh;
    final bool isOverSpeed = alertEngine.isOverSpeed;
    final TrafficHazardNode? hazard = alertEngine.upcomingHazard;
    final double? hazardDistM = alertEngine.upcomingHazardDistanceM;
    final bool flashRedOn = isOverSpeed && ((DateTime.now().millisecondsSinceEpoch ~/ 400) % 2 == 0);

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // 1. Bong bóng tốc độ hiện tại (nhấp nháy Đỏ khi quá tốc độ >= 3 km/h)
        AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: isOverSpeed
                ? (flashRedOn ? const Color(0xFFDC2626) : const Color(0xFF991B1B))
                : const Color(0xFF18191E).withValues(alpha: 0.94),
            shape: BoxShape.circle,
            border: Border.all(
              color: isOverSpeed
                  ? (flashRedOn ? const Color(0xFFFCA5A5) : const Color(0xFFEF4444))
                  : const Color(0xFF38BDF8),
              width: isOverSpeed ? 2.6 : 1.8,
            ),
            boxShadow: [
              BoxShadow(
                color: (isOverSpeed ? const Color(0xFFEF4444) : Colors.black).withValues(alpha: 0.32),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '$speedKmh',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  height: 1.0,
                ),
              ),
              Text(
                'km/h',
                style: TextStyle(
                  color: isOverSpeed ? const Color(0xFFFEE2E2) : const Color(0xFF94A3B8),
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),

        // 2. Biển báo giới hạn tốc độ viền đỏ chuẩn VN (cập nhật động từ OSM/Camera)
        Container(
          width: 50,
          height: 50,
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0xFFEF4444), width: 5.0),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.24),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Center(
            child: Text(
              '$speedLimit',
              style: TextStyle(
                color: const Color(0xFF111827),
                fontSize: speedLimit >= 100 ? 14.5 : 17.5,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.5,
              ),
            ),
          ),
        ),

        // 3. Huy hiệu Camera phạt nguội / Biển báo nguy hiểm kèm khoảng cách đếm ngược (< 300m)
        if (hazard != null && hazardDistM != null && hazardDistM < 300.0) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: hazard.type == TrafficHazardType.speedCamera
                  ? const Color(0xFFB91C1C).withValues(alpha: 0.96)
                  : const Color(0xFFD97706).withValues(alpha: 0.96),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withValues(alpha: 0.85), width: 1.4),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.28),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  hazard.type == TrafficHazardType.speedCamera
                      ? Icons.videocam_rounded
                      : Icons.warning_amber_rounded,
                  color: Colors.white,
                  size: 19,
                ),
                const SizedBox(width: 6),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hazard.type == TrafficHazardType.speedCamera ? 'CAMERA' : 'CHÚ Ý',
                      style: const TextStyle(
                        color: Color(0xFFFDE047),
                        fontSize: 9.5,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.4,
                      ),
                    ),
                    Text(
                      '${hazardDistM.round()} m',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w900,
                        height: 1.05,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _CompassNeedlePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final halfW = size.width * 0.24;

    final northPath = ui.Path()
      ..moveTo(cx, 0)
      ..lineTo(cx + halfW, cy)
      ..lineTo(cx - halfW, cy)
      ..close();
    final northPaint = Paint()..color = const Color(0xFFFF3B30);
    canvas.drawPath(northPath, northPaint);

    final southPath = ui.Path()
      ..moveTo(cx, size.height)
      ..lineTo(cx + halfW, cy)
      ..lineTo(cx - halfW, cy)
      ..close();
    final southPaint = Paint()..color = const Color(0xFF8E8E93);
    canvas.drawPath(southPath, southPaint);

    final centerPaint = Paint()..color = Colors.white;
    canvas.drawCircle(Offset(cx, cy), 1.8, centerPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
