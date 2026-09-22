import '../widgets/liquid_glass.dart';
import 'package:flutter/rendering.dart';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;
import 'package:latlong2/latlong.dart' hide Path;
import 'package:provider/provider.dart';
import '../config/mapbox_config.dart';
import '../models/route_model.dart';
import '../services/ble_service.dart';
import '../services/esp_stream_service.dart';
import '../services/google_maps_parser.dart';
import '../services/google_link_controller.dart';
import '../services/mapbox_directions_service.dart';
import '../services/navigation_manager.dart';
import '../services/off_route_detector.dart';
import '../services/route_render_controller.dart';
import '../services/search_service.dart';
import '../services/voice_guidance_service.dart';


// RoutePresentationMode is imported from route_render_controller.dart

enum MapThemeMode {
  streets,         // Apple Streets (clean light aesthetic)
  satellite,       // Hybrid Satellite Streets
  navigationNight, // Navigation Night (dark, driver-optimized)
  dark,            // Dark minimal
}

class MapScreen extends StatefulWidget {
  final VoidCallback? onOpenMenu;
  const MapScreen({super.key, this.onOpenMenu});

  @override
  State<MapScreen> createState() => _MapScreenState();
}


class _MapLibreLineDrawer implements MapLineDrawer {
  final ml.MapLibreMapController? Function() getController;
  _MapLibreLineDrawer(this.getController);

  @override
  Future<void> clearLines() async {
    final ctrl = getController();
    if (ctrl != null) {
      await ctrl.clearLines();
    }
  }

  @override
  Future<void> drawActiveRoute({
    required List<LatLng> remainingPolyline,
    List<LatLng>? secondaryPolyline,
  }) async {
    final ctrl = getController();
    if (ctrl == null) return;

    // 1. Draw Secondary reference route (pale blue ~50% opacity) if present (P5.6 BUG F)
    if (secondaryPolyline != null && secondaryPolyline.length >= 2) {
      final secGeometry = secondaryPolyline.map((p) => ml.LatLng(p.latitude, p.longitude)).toList();
      await ctrl.addLine(
        ml.LineOptions(
          geometry: secGeometry,
          lineColor: '#007AFF',
          lineWidth: 5.0,
          lineOpacity: 0.45,
          lineJoin: 'round',
        ),
      );
    }

    if (remainingPolyline.length < 2) return;
    final mlGeometry = remainingPolyline.map((p) => ml.LatLng(p.latitude, p.longitude)).toList();

    // 2. Casing / Glow outline (Apple Maps Deep Blue Casing #0051B3)
    await ctrl.addLine(
      ml.LineOptions(
        geometry: mlGeometry,
        lineColor: '#0051B3',
        lineWidth: 8.5,
        lineOpacity: 0.9,
        lineJoin: 'round',
      ),
    );

    // 3. Core Apple Maps Vibrant Route Line (#007AFF)
    await ctrl.addLine(
      ml.LineOptions(
        geometry: mlGeometry,
        lineColor: '#007AFF',
        lineWidth: 6.0,
        lineOpacity: 1.0,
        lineJoin: 'round',
      ),
    );
  }

  @override
  Future<void> drawPreviewRoutes({
    required List<LatLng> mainRoute,
    required List<List<LatLng>> alternativeRoutes,
  }) async {
    final ctrl = getController();
    if (ctrl == null) return;

    // Draw alternative routes first in muted Apple slate
    for (final altPoints in alternativeRoutes) {
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

    if (mainRoute.length >= 2) {
      final mlGeometry = mainRoute.map((p) => ml.LatLng(p.latitude, p.longitude)).toList();
      await ctrl.addLine(
        ml.LineOptions(
          geometry: mlGeometry,
          lineColor: '#0051B3',
          lineWidth: 8.5,
          lineOpacity: 0.9,
          lineJoin: 'round',
        ),
      );
      await ctrl.addLine(
        ml.LineOptions(
          geometry: mlGeometry,
          lineColor: '#007AFF',
          lineWidth: 6.0,
          lineOpacity: 1.0,
          lineJoin: 'round',
        ),
      );
    }
  }
}

class _MapScreenState extends State<MapScreen> {
  RoutePresentationMode _lastRenderedMode = RoutePresentationMode.none;
  int _lastRenderedPointsCount = 0;
  LatLng? _lastRenderedStartCoord;
  bool _showDebugOverlay = false;

  ml.MapLibreMapController? _mapController;
  final SearchService _searchService = SearchService();
  final MapboxDirectionsService _directionsService = MapboxDirectionsService();
  final GoogleMapsParser _googleMapsParser = GoogleMapsParser();
  late final GoogleLinkResolutionController _googleLinkController;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  bool _mapReady = false;

  // Coordinates default (Hanoi)
  LatLng _userPosition = const LatLng(21.0285, 105.8542);
  MapPlace? _selectedPlace;
  List<NavRoute> _routes = [];
  int _selectedRouteIndex = 0;
  String _transportMode = 'bike'; // Default to Motorcycle in Vietnam
  bool _isLoadingRoutes = false;
  bool _isSearching = false;
  int _googleLinkGeneration = 0;
  bool _isAutocompleteRefreshing = false;
  bool _isResolvingGoogleLink = false;
  String? _googleLinkStatusText;
  int _searchGeneration = 0;
  StateSetter? _activeModalSetState;

  void _updateSearchUIState(VoidCallback fn) {
    if (mounted) {
      setState(fn);
      _activeModalSetState?.call(() {});
    }
  }

  void _cancelGoogleLinkResolution() {
    _googleLinkController.cancel();
  }

  void _showGoogleMapsResolutionFailure(String rawUrl) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: const Color(0xFF1C1C1E),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 6),
        content: const Text(
          'Không đọc được vị trí từ liên kết Google Maps',
          style: TextStyle(fontWeight: FontWeight.w600, color: Colors.white, fontSize: 13),
        ),
        action: SnackBarAction(
          label: 'Thử lại',
          textColor: const Color(0xFF0A84FF),
          onPressed: () {
            _handleGoogleMapsOrSharedInput(rawUrl);
          },
        ),
      ),
    );
  }

  // Auto-follow Camera Centering State
  bool _isAutoCentering = true;
  Timer? _recenterTimer;

  // P5.5.1 & P5.6: Deterministic RouteRenderController
  late final RouteRenderController _routeRenderController;
  int _lastObservedRenderRevision = -1;
  bool _lastObservedNavigating = false;
  int get routeGeometryUpdatesCount => _routeRenderController.renderCount;

  DateTime _lastRouteRenderTime = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _routeRenderCadenceTimer;

  void _throttledUpdateRouteOnMap({bool forceRedraw = false}) {
    if (forceRedraw) {
      _routeRenderCadenceTimer?.cancel();
      _lastRouteRenderTime = DateTime.now();
      _updateRouteOnMap(forceRedraw: true);
      return;
    }

    final now = DateTime.now();
    final elapsedMs = now.difference(_lastRouteRenderTime).inMilliseconds;

    // P5.6 Section 5: Decoupled responsive ~250ms route redraw cadence
    if (elapsedMs < 250) {
      if (_routeRenderCadenceTimer == null || !_routeRenderCadenceTimer!.isActive) {
        final delayMs = (250 - elapsedMs > 0) ? (250 - elapsedMs) : 0;
        _routeRenderCadenceTimer = Timer(Duration(milliseconds: delayMs), () {
          if (mounted) {
            _lastRouteRenderTime = DateTime.now();
            _updateRouteOnMap();
          }
        });
      }
      return;
    }

    _lastRouteRenderTime = now;
    _updateRouteOnMap();
  }

  DateTime _lastCameraAnimateTime = DateTime.fromMillisecondsSinceEpoch(0);
  bool _isCameraAnimating = false;
  LatLng? _coalescedCameraPos;
  double? _coalescedCameraHeading;
  Timer? _cameraCadenceTimer;
  int _cameraUpdatesCount = 0;
  int get cameraUpdatesCount => _cameraUpdatesCount;

  void _throttledAnimateCamera(LatLng pos, double heading) {
    final now = DateTime.now();
    final elapsedMs = now.difference(_lastCameraAnimateTime).inMilliseconds;

    // 8-10 Hz cadence = min 110ms between animation starts (Section 32)
    if (_isCameraAnimating || elapsedMs < 110) {
      _coalescedCameraPos = pos;
      _coalescedCameraHeading = heading;
      if (_cameraCadenceTimer == null || !_cameraCadenceTimer!.isActive) {
        final delayMs = 110 - elapsedMs > 0 ? 110 - elapsedMs : 0;
        _cameraCadenceTimer = Timer(Duration(milliseconds: delayMs), () {
          if (mounted && _coalescedCameraPos != null) {
            final p = _coalescedCameraPos!;
            final h = _coalescedCameraHeading ?? heading;
            _coalescedCameraPos = null;
            _coalescedCameraHeading = null;
            _executeCameraAnimation(p, h);
          }
        });
      }
      return;
    }

    _executeCameraAnimation(pos, heading);
  }

  void _executeCameraAnimation(LatLng pos, double heading) {
    final ctrl = _mapController;
    if (ctrl == null || !mounted) return;

    _lastCameraAnimateTime = DateTime.now();
    _isCameraAnimating = true;
    _cameraUpdatesCount++;

    ctrl.animateCamera(
      ml.CameraUpdate.newCameraPosition(
        ml.CameraPosition(
          target: ml.LatLng(pos.latitude, pos.longitude),
          zoom: _isDrivingZoomOverview ? 14.5 : 17.5,
          tilt: _isDrivingZoomOverview ? 0.0 : 50.0,
          bearing: _isDrivingZoomOverview ? 0.0 : heading,
        ),
      ),
    ).then((_) {
      _isCameraAnimating = false;
      if (_coalescedCameraPos != null && mounted) {
        final p = _coalescedCameraPos!;
        final h = _coalescedCameraHeading ?? 0.0;
        _coalescedCameraPos = null;
        _coalescedCameraHeading = null;
        _throttledAnimateCamera(p, h);
      }
    }).catchError((_) {
      _isCameraAnimating = false;
    });
  }

  // View state:
  // 0: Browse Map / Search
  // 1: Place Selected Inspector Sheet
  // 2: Route Comparison & Alternatives
  int _viewMode = 0;
  bool _isMuted = false;
  bool _isDrivingZoomOverview = false;
  MapThemeMode _currentTheme = MapThemeMode.streets; // Apple Streets (clean light)

  List<MapPlace> _searchResults = [];
  Timer? _debounceTimer;
  String? _clipboardGoogleMapsText;
  String? _lastDismissedClipboardText;

  @override
  void initState() {
    super.initState();
    _routeRenderController = RouteRenderController(_MapLibreLineDrawer(() => _mapController));

    _googleLinkController = GoogleLinkResolutionController(
      parser: _googleMapsParser,
      onStateChanged: (state) {
        if (mounted) {
          _updateSearchUIState(() {
            _isResolvingGoogleLink = state.isLoading;
            _googleLinkStatusText = state.statusText;
          });
        }
      },
    );
    _isMuted = VoiceGuidanceService().isMuted;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final navManager = Provider.of<NavigationManager>(context, listen: false);
      navManager.addListener(_onNavigationManagerChanged);
      _lastObservedRenderRevision = navManager.renderRevision;
      _lastObservedNavigating = navManager.isNavigating;
      if (navManager.currentLocation != null) {
        _userPosition = navManager.currentLocation!;
      }

      // Hook navigation position update callback to continuously center vehicle with 3D perspective
      navManager.onLocationChanged = (loc, heading) {
        if (mounted && navManager.isNavigating) {
          if (_isAutoCentering) {
            _throttledAnimateCamera(loc, heading);
          }
          _throttledUpdateRouteOnMap();
        }
      };

      // Auto-start headless live map stream and sync current theme
      final streamService = Provider.of<EspStreamService>(context, listen: false);
      if (_currentTheme == MapThemeMode.dark || _currentTheme == MapThemeMode.navigationNight) {
        streamService.streamMapStyle = 'streets-v2-dark';
      } else if (_currentTheme == MapThemeMode.satellite) {
        streamService.streamMapStyle = 'hybrid';
      } else {
        streamService.streamMapStyle = 'streets-v2';
      }
      // P5.4.1.2 Section 19 & 20: Do not auto-start high-FPS streaming without consumer.
      // EspStreamService handles demand-based streaming on ESP display connection.

      _checkClipboardForGoogleMaps();
    });

    _searchFocusNode.addListener(() {
      if (_searchFocusNode.hasFocus) {
        _checkClipboardForGoogleMaps();
      }
      setState(() {});
    });
  }

  /// Called when MaplibreMap is created and controller is ready
  void _onMapCreated(ml.MapLibreMapController controller) {
    _mapController = controller;
    _mapReady = true;

    // Move camera to user position
    final navManager = Provider.of<NavigationManager>(context, listen: false);
    final pos = navManager.currentLocation ?? _userPosition;
    controller.animateCamera(
      ml.CameraUpdate.newCameraPosition(
        ml.CameraPosition(target: ml.LatLng(pos.latitude, pos.longitude), zoom: 16.5),
      ),
    );
  }

  RoutePresentationMode get _presentationMode {
    final navManager = Provider.of<NavigationManager>(context, listen: false);
    if (navManager.isNavigating && navManager.activeRoute != null) {
      if (navManager.remainingTotalDistance <= 10.0 &&
          navManager.currentStepIndex >= (navManager.activeRoute!.steps.length - 1)) {
        return RoutePresentationMode.arrived;
      }
      return RoutePresentationMode.navigating;
    } else if (_routes.isNotEmpty && _selectedRouteIndex < _routes.length) {
      return RoutePresentationMode.preview;
    }
    return RoutePresentationMode.none;
  }

  /// Update route polyline on MapLibre via deterministic RouteRenderController (P5.5.1 Section 3, 7)
  Future<void> _updateRouteOnMap({bool forceRedraw = false}) async {
    final ctrl = _mapController;
    if (ctrl == null || !_mapReady) return;

    final navManager = Provider.of<NavigationManager>(context, listen: false);
    final mode = _presentationMode;
    List<LatLng> mainPoints = [];
    List<List<LatLng>> altPoints = [];

    switch (mode) {
      case RoutePresentationMode.navigating:
        mainPoints = navManager.remainingPolyline;
        if (navManager.secondaryPolyline.length >= 2) {
          altPoints.add(navManager.secondaryPolyline);
        }
        break;
      case RoutePresentationMode.preview:
        if (_routes.isNotEmpty && _selectedRouteIndex < _routes.length) {
          mainPoints = _routes[_selectedRouteIndex].polylinePoints;
          for (int i = 0; i < _routes.length; i++) {
            if (i != _selectedRouteIndex) {
              altPoints.add(_routes[i].polylinePoints);
            }
          }
        }
        break;
      case RoutePresentationMode.arrived:
      case RoutePresentationMode.none:
        mainPoints = [];
        break;
    }

    await _routeRenderController.submitRequest(
      routeRevision: navManager.renderRevision,
      mode: mode,
      mainPoints: mainPoints,
      altPoints: altPoints,
      forceRedraw: forceRedraw,
    );
  }

  /// Update native vector circle marker for destination pin in Apple Maps Orange
  Future<void> _updateDestinationMarker() async {
    final ctrl = _mapController;
    if (ctrl == null || !_mapReady) return;
    try {
      await ctrl.clearCircles();
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
      _clipboardGoogleMapsText = null;
      _lastDismissedClipboardText = clean;
    });

    final navManager = Provider.of<NavigationManager>(context, listen: false);
    final currentPos = navManager.currentLocation ?? _userPosition;

    final place = await _googleLinkController.resolve(clean, userLocation: currentPos);
    if (!mounted) return;

    final resolvedLink = _googleLinkController.state.resolvedLink;
    final isExact = resolvedLink?.isExact ?? (place != null && place.source == 'google_link_exact');
    final requiresConfirmation = resolvedLink?.requiresConfirmation ?? (!isExact);

    if (place != null) {
      if (isExact && !requiresConfirmation) {
        // EXACT PIN (P5.4.1.1 Authority 1-5): Auto-select immediately
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
        // UNVERIFIED / APPROXIMATE RESULT (P5.4.1.1 Sections 13 & 30):
        // DO NOT automatically start routing! Show confirmation dialog.
        _showUnverifiedGoogleConfirmationDialog(place, resolvedLink);
      }
    } else if (_googleLinkController.state.status != GoogleLinkResolutionStatus.cancelled) {
      _showGoogleMapsResolutionFailure(clean);
    }
  }

  void _showUnverifiedGoogleConfirmationDialog(MapPlace candidatePlace, GoogleMapsResolvedLink? link) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (dialogCtx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Row(
            children: [
              Icon(Icons.help_outline_rounded, color: Color(0xFFFF9500), size: 26),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Có thể là địa điểm này',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Không thể xác nhận chính xác ghim từ liên kết Google Maps. Hãy kiểm tra vị trí trước khi chỉ đường.',
                style: TextStyle(fontSize: 14, color: Colors.black87),
              ),
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF2F2F7),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      candidatePlace.name,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.black87),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      candidatePlace.displayName,
                      style: const TextStyle(fontSize: 13, color: Colors.black54),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Tọa độ: ${candidatePlace.coordinate.latitude.toStringAsFixed(5)}, ${candidatePlace.coordinate.longitude.toStringAsFixed(5)}',
                      style: const TextStyle(fontSize: 12, color: Color(0xFF8E8E93)),
                    ),
                  ],
                ),
              ),
              if (kDebugMode && link?.debugDiagnostics != null) ...[
                const SizedBox(height: 10),
                GestureDetector(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: link!.debugDiagnostics!));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Đã sao chép chẩn đoán GoogleLink'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.06),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.copy_rounded, size: 14, color: Color(0xFF007AFF)),
                        SizedBox(width: 6),
                        Text(
                          'Sao chép chẩn đoán (Debug)',
                          style: TextStyle(fontSize: 12, color: Color(0xFF007AFF), fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: const Text('Hủy', style: TextStyle(color: Colors.black54)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF007AFF),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () {
                Navigator.pop(dialogCtx);
                _searchController.text = candidatePlace.name;
                _onPlaceClicked(candidatePlace);
              },
              child: const Text('Dùng vị trí này', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  void _onNavigationManagerChanged() {
    if (!mounted) return;
    final navManager = Provider.of<NavigationManager>(context, listen: false);
    final rev = navManager.renderRevision;
    final isNav = navManager.isNavigating;

    if (rev != _lastObservedRenderRevision || isNav != _lastObservedNavigating) {
      _lastObservedRenderRevision = rev;
      _lastObservedNavigating = isNav;
      if (!isNav) {
        _routes = [];
        _routeRenderController.clearAndInvalidate();
      } else {
        _throttledUpdateRouteOnMap(forceRedraw: true);
      }
    }
  }

  @override
  void dispose() {
    _routeRenderCadenceTimer?.cancel();
    _cameraCadenceTimer?.cancel();
    _debounceTimer?.cancel();
    _recenterTimer?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    try {
      final navManager = Provider.of<NavigationManager>(context, listen: false);
      navManager.removeListener(_onNavigationManagerChanged);
    } catch (_) {}
    super.dispose();
  }

  // -------------------------------------------------------------
  // Search Logic
  // -------------------------------------------------------------
  void _onSearchChanged(String query) {
    _debounceTimer?.cancel();
    final clean = query.trim();
    if (clean.isEmpty) {
      _updateSearchUIState(() {
        _searchResults = [];
        _isAutocompleteRefreshing = false;
        _isSearching = false;
      });
      return;
    }

    if (GoogleMapsParser.isGoogleMapsOrCoordInput(clean)) {
      _debounceTimer = Timer(const Duration(milliseconds: 220), () {
        _handleGoogleMapsOrSharedInput(clean);
      });
      return;
    }

    if (clean.length < 2) return;

    try {
      Provider.of<EspStreamService>(context, listen: false).pauseForDuration(const Duration(milliseconds: 600));
    } catch (_) {}

    final navManager = Provider.of<NavigationManager>(context, listen: false);
    final currentPos = navManager.currentLocation ?? _userPosition;

    // 1. Fast local cache / prefix reuse suggestions (0–30ms) without blanking UI
    final cachedMatches = _searchService.findPrefixMatches(clean, nearLocation: currentPos);
    if (cachedMatches.isNotEmpty) {
      _updateSearchUIState(() {
        _searchResults = cachedMatches;
      });
    } else {
      final instantMatches = _searchService.searchInstantLocal(clean, nearLocation: currentPos);
      if (instantMatches.isNotEmpty) {
        _updateSearchUIState(() {
          _searchResults = instantMatches;
        });
      }
    }

    // 2. Debounce 220ms for network autocomplete
    final generation = ++_searchGeneration;
    _updateSearchUIState(() {
      _isAutocompleteRefreshing = true;
      _isSearching = true;
    });

    _debounceTimer = Timer(const Duration(milliseconds: 220), () async {
      await _searchService.searchPlacesProgressive(
        clean,
        nearLocation: currentPos,
        mode: SearchExecutionMode.autocomplete,
        onUpdate: (results, isFinal) {
          if (!mounted || generation != _searchGeneration) return;
          _updateSearchUIState(() {
            if (results.isNotEmpty) {
              _searchResults = results;
            }
            if (isFinal) {
              _isAutocompleteRefreshing = false;
              _isSearching = false;
            }
          });
        },
      );
    });
  }

  void _onSearchSubmitted(String query) async {
    final clean = query.trim();
    if (clean.isEmpty) return;

    if (GoogleMapsParser.isGoogleMapsOrCoordInput(clean)) {
      _handleGoogleMapsOrSharedInput(clean);
      return;
    }

    _debounceTimer?.cancel();
    final generation = ++_searchGeneration;
    _updateSearchUIState(() {
      _isAutocompleteRefreshing = true;
      _isSearching = true;
    });

    final navManager = Provider.of<NavigationManager>(context, listen: false);
    final currentPos = navManager.currentLocation ?? _userPosition;

    await _searchService.searchPlacesProgressive(
      clean,
      nearLocation: currentPos,
      mode: SearchExecutionMode.submitted,
      onUpdate: (results, isFinal) {
        if (!mounted || generation != _searchGeneration) return;
        _updateSearchUIState(() {
          if (results.isNotEmpty) {
            _searchResults = results;
          }
          if (isFinal) {
            _isAutocompleteRefreshing = false;
            _isSearching = false;
          }
        });
        if (isFinal &&
            results.length == 1 &&
            (results.first.precision == PlacePrecision.coordinate ||
             results.first.source == 'google_link_exact')) {
          _onPlaceClicked(results.first);
        }
      },
    );
  }

  void _onSelectCategory(QuickSearchCategory category) async {
    final navManager = Provider.of<NavigationManager>(context, listen: false);
    final currentPos = navManager.currentLocation ?? _userPosition;
    _searchController.text = category.title;
    final generation = ++_searchGeneration;
    _updateSearchUIState(() {
      _isAutocompleteRefreshing = true;
      _isSearching = true;
    });

    try {
      final results = await _searchService.searchCategory(category, nearLocation: currentPos);
      if (mounted && generation == _searchGeneration) {
        _updateSearchUIState(() {
          _searchResults = results;
          _isAutocompleteRefreshing = false;
          _isSearching = false;
        });
        if (results.length == 1 &&
            (results.first.precision == PlacePrecision.coordinate ||
             results.first.source == 'google_link_exact')) {
          _onPlaceClicked(results.first);
        }
      }
    } finally {
      if (mounted && generation == _searchGeneration) {
        _updateSearchUIState(() {
          _isAutocompleteRefreshing = false;
          _isSearching = false;
        });
      }
    }
  }

  Widget _buildPrecisionBadge(PlacePrecision precision) {
    String label;
    Color bg;
    Color fg;
    switch (precision) {
      case PlacePrecision.exactAddress:
        label = 'Địa chỉ';
        bg = const Color(0xFFE3F2FD);
        fg = const Color(0xFF1976D2);
        break;
      case PlacePrecision.poi:
      case PlacePrecision.building:
        label = 'Địa điểm';
        bg = const Color(0xFFE8F5E9);
        fg = const Color(0xFF388E3C);
        break;
      case PlacePrecision.street:
        label = 'Đường';
        bg = const Color(0xFFFFF3E0);
        fg = const Color(0xFFF57C00);
        break;
      case PlacePrecision.neighborhood:
      case PlacePrecision.district:
      case PlacePrecision.city:
        label = 'Khu vực';
        bg = const Color(0xFFF3E5F5);
        fg = const Color(0xFF7B1FA2);
        break;
      case PlacePrecision.approximate:
        label = 'Ước lượng';
        bg = const Color(0xFFFFF8E1);
        fg = const Color(0xFFFFA000);
        break;
      case PlacePrecision.coordinate:
        label = 'Tọa độ';
        bg = const Color(0xFFECEFF1);
        fg = const Color(0xFF455A64);
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: fg),
      ),
    );
  }

  void _onPlaceClicked(MapPlace place) async {
    MapPlace resolvedPlace = place;



    _searchFocusNode.unfocus();
    _searchService.addRecentSearch(resolvedPlace);
    if (mounted) {
      setState(() {
        _selectedPlace = resolvedPlace;
        _searchResults = [];
        _viewMode = 1; // Open Place Details Inspector
      });
      _mapController?.animateCamera(
        ml.CameraUpdate.newLatLngZoom(
          ml.LatLng(resolvedPlace.coordinate.latitude, resolvedPlace.coordinate.longitude),
          16.5,
        ),
      );
      _updateDestinationMarker();
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
    final navManager = Provider.of<NavigationManager>(context, listen: false);
    final startPos = navManager.currentLocation ?? _userPosition;

    try {
      Provider.of<EspStreamService>(context, listen: false).pauseForDuration(const Duration(milliseconds: 1500));
    } catch (_) {}

    setState(() {
      _isLoadingRoutes = true;
      _selectedPlace = place;
      _viewMode = 2; // Open Route Comparison
      _selectedRouteIndex = 0;
      _routes = [];
    });
    _updateDestinationMarker();

    final routes = await _directionsService.calculateMultipleRoutes(
      startPos,
      place.coordinate,
      mode: _transportMode,
    );

    if (mounted) {
      setState(() {
        _routes = routes;
        _isLoadingRoutes = false;
        _selectedRouteIndex = 0;
      });

      if (routes.isNotEmpty) {
        context.read<NavigationManager>().setPreviewRoute(routes.first);
        _fitRouteBounds(routes.first.polylinePoints);
        _updateRouteOnMap();
        _updateDestinationMarker();
      }
    }
  }

  void _fitRouteBounds(List<LatLng> points) {
    if (points.isEmpty) return;

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

    // MapLibre camera bounds fitting
    _mapController?.animateCamera(
      ml.CameraUpdate.newLatLngBounds(
        ml.LatLngBounds(
          southwest: ml.LatLng(minLat, minLng),
          northeast: ml.LatLng(maxLat, maxLng),
        ),
        top: 140, bottom: 320, left: 40, right: 40,
      ),
    );
  }

  void _startDriving({bool isSimulation = false}) {
    if (_routes.isEmpty) return;
    final chosenRoute = _routes[_selectedRouteIndex];
    final navManager = Provider.of<NavigationManager>(context, listen: false);

    _isAutoCentering = true;

    if (isSimulation) {
      navManager.startSimulation(chosenRoute);
    } else {
      navManager.startNavigation(chosenRoute);
    }

    setState(() {
      _viewMode = 0;
    });

    // Center vehicle with 3D perspective camera (50° tilt, aligned with heading)
    final startPos = navManager.currentLocation ?? _userPosition;
    _mapController?.animateCamera(
      ml.CameraUpdate.newCameraPosition(
        ml.CameraPosition(
          target: ml.LatLng(startPos.latitude, startPos.longitude),
          zoom: 17.5,
          tilt: 50.0,
          bearing: navManager.currentHeading,
        ),
      ),
    );
    _updateRouteOnMap();
  }

  void _recenterToVehicle() {
    final navManager = Provider.of<NavigationManager>(context, listen: false);
    final current = navManager.currentLocation ?? _userPosition;
    setState(() {
      _isAutoCentering = true;
    });
    _mapController?.animateCamera(
      ml.CameraUpdate.newCameraPosition(
        ml.CameraPosition(
          target: ml.LatLng(current.latitude, current.longitude),
          zoom: 17.5,
          tilt: 50.0,
          bearing: navManager.currentHeading,
        ),
      ),
    );
  }

  void _fitCameraToCurrentRoute() {
    final navManager = Provider.of<NavigationManager>(context, listen: false);
    if (navManager.activeRoute != null) {
      _fitRouteBounds(navManager.activeRoute!.polylinePoints);
    } else if (_routes.isNotEmpty) {
      _fitRouteBounds(_routes[_selectedRouteIndex].polylinePoints);
    }
  }

  void _showReportIncidentDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.96),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 5,
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(2.5),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Báo cáo sự cố',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF1C1C1E)),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.warning_amber_rounded, color: Color(0xFFFF9500), size: 28),
              title: const Text('Nguy hiểm trên đường', style: TextStyle(fontWeight: FontWeight.w600)),
              onTap: () {
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Đã ghi nhận báo cáo nguy hiểm')));
              },
            ),
            ListTile(
              leading: const Icon(Icons.car_crash_rounded, color: Color(0xFFFF3B30), size: 28),
              title: const Text('Tai nạn giao thông', style: TextStyle(fontWeight: FontWeight.w600)),
              onTap: () {
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Đã ghi nhận báo cáo tai nạn')));
              },
            ),
            ListTile(
              leading: const Icon(Icons.speed_rounded, color: Color(0xFF007AFF), size: 28),
              title: const Text('Điểm bắn tốc độ', style: TextStyle(fontWeight: FontWeight.w600)),
              onTap: () {
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Đã ghi nhận điểm tốc độ')));
              },
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------
  // MapLibre Style URL for current theme
  // -------------------------------------------------------------
  String _buildMaplibreStyleString() {
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
    final streamService = context.watch<EspStreamService>();
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
          ml.MapLibreMap(
            styleString: _buildMaplibreStyleString(),
            initialCameraPosition: ml.CameraPosition(
              target: ml.LatLng(userPos.latitude, userPos.longitude),
              zoom: 16.5,
            ),
            onMapCreated: _onMapCreated,
            onStyleLoadedCallback: () {
              _updateRouteOnMap();
              _updateDestinationMarker();
            },
            onMapClick: (point, coord) => _onMapTapped(LatLng(coord.latitude, coord.longitude)),
            onMapLongClick: (point, coord) => _onMapTapped(LatLng(coord.latitude, coord.longitude)),
            trackCameraPosition: true,
            compassEnabled: false,
            myLocationEnabled: true,
            myLocationTrackingMode: _isAutoCentering && isDriving
                ? ml.MyLocationTrackingMode.tracking
                : ml.MyLocationTrackingMode.none,
            myLocationRenderMode: ml.MyLocationRenderMode.compass,
            rotateGesturesEnabled: true,
            scrollGesturesEnabled: true,
            zoomGesturesEnabled: true,
            tiltGesturesEnabled: true,
          ),

          // -----------------------------------------------------------
          // 2. Top-Left Controls: 3-line Menu Button + Weather Pill
          // -----------------------------------------------------------
          if (!isDriving)
            SafeArea(
              child: Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 16.0, top: 8.0),
                  child: _buildTopLeftGlassGroup(context, bleService, streamService),
                ),
              ),
            ),

          if (_showDebugOverlay)
            Positioned(
              left: 16,
              top: 72,
              child: _buildDebugOverlay(streamService, navManager),
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
          // 4. Right-side Floating Action Controls (Apple Maps Style)
          // -----------------------------------------------------------
          if (!isDriving)
            Positioned(
              right: 16,
              bottom: _viewMode == 0 ? 95 : 325,
              child: _buildRightSideGlassStack(navManager, isDriving),
            ),

          // -----------------------------------------------------------
          // 5. Active Driving Top Maneuver Banner (Screenshot 5)
          // -----------------------------------------------------------
          if (isDriving)
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 8.0),
                child: _buildAppleActiveDrivingTurnBanner(navManager),
              ),
            ),

          // -----------------------------------------------------------
          // 6. Active Driving Right-side Circular Action Stack (Screenshot 5)
          // -----------------------------------------------------------
          if (isDriving)
            Positioned(
              right: 16,
              top: 130,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildCircularGlassButton(
                    icon: Icons.alt_route_rounded,
                    tooltip: 'Toàn cảnh lộ trình',
                    onTap: _fitCameraToCurrentRoute,
                  ),
                  const SizedBox(height: 12),
                  _buildCircularGlassButton(
                    icon: _isMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                    tooltip: _isMuted ? 'Bật âm thanh' : 'Tắt âm thanh',
                    onTap: () {
                      final voice = VoiceGuidanceService();
                      voice.toggleMute();
                      setState(() => _isMuted = voice.isMuted);
                    },
                  ),
                  const SizedBox(height: 12),
                  _buildCircularGlassButton(
                    icon: Icons.chat_bubble_outline_rounded,
                    tooltip: 'Báo cáo sự cố',
                    onTap: _showReportIncidentDialog,
                  ),
                ],
              ),
            ),

          // -----------------------------------------------------------
          // Floating Google Maps Link Resolving Banner
          if (_isResolvingGoogleLink)
            Positioned(
              top: MediaQuery.of(context).padding.top + 56,
              left: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.12),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF007AFF)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _googleLinkStatusText ?? 'Đang mở liên kết Google Maps…',
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: Colors.black87),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    GestureDetector(
                      onTap: _cancelGoogleLinkResolution,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        child: const Text('Hủy', style: TextStyle(color: Color(0xFFFF3B30), fontWeight: FontWeight.bold, fontSize: 13)),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // 7. Active Driving Floating Street Bubble on Route (Screenshot 5)
          // -----------------------------------------------------------
          if (isDriving)
            Positioned(
              bottom: 125,
              left: 0,
              right: 0,
              child: Center(
                child: _buildAppleFloatingStreetPill(navManager),
              ),
            ),

          // Floating "Khóa về vị trí" Banner when user manually pans map while driving
          if (isDriving && !_isAutoCentering)
            Positioned(
              bottom: 175,
              left: 0,
              right: 0,
              child: Center(
                child: GestureDetector(
                  onTap: _recenterToVehicle,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF007AFF),
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(color: const Color(0xFF007AFF).withOpacity(0.4), blurRadius: 12, offset: const Offset(0, 3)),
                      ],
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.center_focus_strong_rounded, color: Colors.white, size: 18),
                        SizedBox(width: 8),
                        Text(
                          'Khóa tâm về vị trí xe',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // -----------------------------------------------------------
          // 8. Bottom Panels
          // -----------------------------------------------------------
          // Mode 0: Browse Map Bottom Search Capsule (Screenshot 1)
          if (!isDriving && _viewMode == 0)
            Positioned(
              bottom: 20,
              left: 16,
              right: 16,
              child: _buildAppleBottomSearchCapsule(),
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

          // Driving Mode: Bottom HUD Capsule (Screenshot 5)
          if (isDriving)
            Align(
              alignment: Alignment.bottomCenter,
              child: _buildAppleActiveDrivingBottomHud(navManager, bleService),
            ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------

  // ─────────────────────────────────────────────────────────────
  // Liquid Glass Floating Controls (P5.4.1.3 Sections 36-45, 64)
  // ─────────────────────────────────────────────────────────────
  Widget _buildTopLeftGlassGroup(BuildContext context, BleService bleService, EspStreamService streamService) {
    return LiquidGlassContainer(
      radius: 24,
      blur: 20,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
            icon: Stack(
              alignment: Alignment.center,
              children: [
                const Icon(Icons.menu_rounded, color: Color(0xFF1C1C1E), size: 22),
                if (bleService.isConnected)
                  Positioned(
                    right: 6,
                    top: 6,
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
            tooltip: 'Menu',
            onPressed: () {
              if (widget.onOpenMenu != null) {
                widget.onOpenMenu!();
              } else {
                Scaffold.maybeOf(context)?.openDrawer();
              }
            },
          ),
          Container(
            width: 1.0,
            height: 22,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            color: Colors.black.withOpacity(0.12),
          ),
          GestureDetector(
            onTap: () {
              setState(() => _showDebugOverlay = !_showDebugOverlay);
            },
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.cloudy_snowing, color: Color(0xFF007AFF), size: 16),
                  SizedBox(width: 5),
                  Text(
                    '27°',
                    style: TextStyle(
                      color: Color(0xFF1C1C1E),
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      letterSpacing: -0.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRightSideGlassStack(NavigationManager navManager, bool isDriving) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        LiquidGlassContainer(
          radius: 22,
          blur: 20,
          width: 46,
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                icon: const Icon(Icons.layers_rounded, color: Color(0xFF1C1C1E), size: 20),
                tooltip: 'Đổi nền bản đồ',
                onPressed: _showMapThemePicker,
              ),
              Container(width: 26, height: 0.8, color: Colors.black.withOpacity(0.10)),
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                icon: const Icon(Icons.explore_rounded, color: Color(0xFFFF3B30), size: 20),
                tooltip: 'Hướng Bắc',
                onPressed: () => _mapController?.animateCamera(ml.CameraUpdate.bearingTo(0.0)),
              ),
              Container(width: 26, height: 0.8, color: Colors.black.withOpacity(0.10)),
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                icon: Icon(
                  _transportMode == 'driving' ? Icons.directions_car_rounded : Icons.two_wheeler_rounded,
                  color: _transportMode == 'bike' ? const Color(0xFF007AFF) : const Color(0xFF1C1C1E),
                  size: 20,
                ),
                tooltip: 'Chế độ phương tiện (Xe máy/Ô tô)',
                onPressed: () {
                  setState(() {
                    _transportMode = _transportMode == 'bike' ? 'driving' : 'bike';
                  });
                  if (_selectedPlace != null) {
                    _calculateRoutesForPlace(_selectedPlace!);
                  }
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        LiquidGlassButton(
          size: 46,
          radius: 23,
          isSelected: _isAutoCentering,
          activeGlowColor: const Color(0xFF007AFF),
          icon: Icon(
            _isAutoCentering ? Icons.navigation_rounded : Icons.navigation_outlined,
            color: const Color(0xFF007AFF),
            size: 22,
          ),
          tooltip: 'Vị trí hiện tại',
          onTap: () {
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
    );
  }

  Widget _buildDebugOverlay(EspStreamService streamService, NavigationManager navManager) {
    final physicalLoc = navManager.acceptedPhysicalLocation ?? navManager.rawLocation;
    final matchedLoc = navManager.matchedLocation;
    final physicalRouteDist = (navManager.activeRouteGeometry?.nearestProjection(physicalLoc ?? const LatLng(0, 0))?.lateralDistanceMeters ?? 0.0);
    final matchedLateralDist = (navManager.matchedProjection?.lateralDistanceMeters ?? 0.0);
    final lastLatencyMs = (navManager.routeCommittedAt != null && navManager.requestStartedAt != null)
        ? navManager.routeCommittedAt!.difference(navManager.requestStartedAt!).inMilliseconds
        : null;

    return LiquidGlassContainer(
      radius: 16,
      blur: 24,
      padding: const EdgeInsets.all(12),
      width: 240,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'TELEMETRY & FIELD DIAG',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Color(0xFF007AFF)),
              ),
              GestureDetector(
                onTap: () => setState(() => _showDebugOverlay = false),
                child: const Icon(Icons.close_rounded, size: 14, color: Colors.black54),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text('Transport: ${streamService.activeJpegTransport.name}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
          Text('Output FPS: ${streamService.actualFps.toStringAsFixed(1)}', style: const TextStyle(fontSize: 11)),
          Text('Render FPS: ${streamService.renderFps.toStringAsFixed(1)}', style: const TextStyle(fontSize: 11)),
          Text('Thermal: ${streamService.thermalState}', style: const TextStyle(fontSize: 11, color: Color(0xFF34C759))),
          if (navManager.isNavigating) ...[
            const Divider(height: 12, thickness: 0.5),
            const Text(
              'NAV ENGINE (P5.6)',
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Color(0xFFFF9500)),
            ),
            const SizedBox(height: 4),
            Text('GPS acc: ${navManager.horizontalAccuracy.toStringAsFixed(1)}m', style: const TextStyle(fontSize: 11)),
            if (physicalLoc != null)
              Text('Phys: ${physicalLoc.latitude.toStringAsFixed(5)}, ${physicalLoc.longitude.toStringAsFixed(5)}', style: const TextStyle(fontSize: 10, color: Colors.black87)),
            if (matchedLoc != null)
              Text('Match: ${matchedLoc.latitude.toStringAsFixed(5)}, ${matchedLoc.longitude.toStringAsFixed(5)}', style: const TextStyle(fontSize: 10, color: Colors.black87)),
            Text('Step: #${navManager.authoritativeCurrentManeuver?.stepIndex ?? 0} (${navManager.authoritativeCurrentManeuver?.maneuverType.name ?? "none"})', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
            Text('Modifier: ${navManager.authoritativeCurrentManeuver?.maneuverModifier ?? "none"}', style: const TextStyle(fontSize: 11)),
            Text('Maneuver raw: type=${navManager.authoritativeValhallaType ?? "none"}, str=${navManager.authoritativeManeuverTypeStr ?? "none"}, mod=${navManager.authoritativeManeuverModifier ?? "none"}', style: const TextStyle(fontSize: 10)),
            Text('Authoritative: idx=${navManager.authoritativeStepIndex ?? "none"}, shapeIdx=${navManager.authoritativeBeginShapeIndex ?? "none"}, dist=${navManager.distanceToNextManeuver.toStringAsFixed(0)}m', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600)),
            Text('Heading Δ: ${navManager.headingDeltaVsRouteDegrees?.toStringAsFixed(0) ?? "--"}° (WrongWay: ${navManager.isWrongWayDivergence ? "YES" : "NO"})', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: navManager.isWrongWayDivergence ? Colors.red : Colors.black87)),
            Text('Primary: gen ${navManager.rerouteGeneration} (${navManager.rerouteStatus})', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
            Text('Secondary: gen ${navManager.secondaryRerouteGeneration} (${navManager.secondaryRerouteStatus}, active: ${navManager.secondaryPolyline.isNotEmpty ? "YES" : "NO"})', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
            Text('Render: ${_routeRenderController.latestSubmittedGeneration}s/${_routeRenderController.latestCommittedGeneration}c (pending: ${_routeRenderController.hasPendingRequest ? "YES" : "NO"}, renders: ${_routeRenderController.renderCount})', style: const TextStyle(fontSize: 11)),
            Text('Physical route dist: ${physicalRouteDist.toStringAsFixed(1)}m', style: const TextStyle(fontSize: 11)),
            Text('Matched lateral: ${matchedLateralDist.toStringAsFixed(1)}m', style: const TextStyle(fontSize: 11)),
            Text('Progress: ${navManager.displayProgressMeters.toStringAsFixed(0)}m', style: const TextStyle(fontSize: 11)),
            Text('Route remain: ${navManager.remainingTotalDistance >= 1000 ? "${(navManager.remainingTotalDistance / 1000).toStringAsFixed(1)}km" : "${navManager.remainingTotalDistance.toStringAsFixed(0)}m"}', style: const TextStyle(fontSize: 11)),
            Text('OffRoute: ${navManager.lastOffRouteDecision?.state.name ?? "onRoute"}', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: navManager.lastOffRouteDecision?.state == OffRouteState.confirmed ? Colors.red : (navManager.lastOffRouteDecision?.state == OffRouteState.suspected ? Colors.orange : Colors.green))),
            Text('Reason: ${navManager.lastOffRouteDecision?.reason.name ?? "none"}', style: const TextStyle(fontSize: 11)),
            if (navManager.rerouteStatus == 'cooldown')
              Text('Reroute: cooldown (${navManager.rerouteCooldownRemainingSeconds.toStringAsFixed(1)}s, retry ${navManager.rerouteRetryCount})', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.orange))
            else
              Text('Reroute: ${navManager.rerouteStatus} (gen ${navManager.rerouteGeneration}, rev ${navManager.routeRevision})', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
            if (navManager.rerouteRetryCount > 0 && navManager.rerouteStatus != 'cooldown')
              Text('Retries: ${navManager.rerouteRetryCount}', style: const TextStyle(fontSize: 11)),
            Text('Latency: ${lastLatencyMs != null ? "${lastLatencyMs}ms" : "--"}', style: const TextStyle(fontSize: 11)),
          ],
        ],
      ),
    );
  }

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
    return GestureDetector(
      onTap: _openAppleSearchModal,
      child: LiquidGlassContainer(
        height: 56,
        radius: 28,
        blur: 24,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            const Icon(Icons.search_rounded, color: Colors.black87, size: 24),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Tìm kiếm điểm đến...',
                style: TextStyle(
                  color: Colors.black87,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  letterSpacing: -0.2,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.mic_none_rounded, color: Colors.black87, size: 22),
              onPressed: _openAppleSearchModal,
            ),
            GestureDetector(
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
            _activeModalSetState = setModalState;
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
                                        style: const TextStyle(
                                          color: Colors.black87,
                                          fontSize: 16,
                                          fontWeight: FontWeight.w500,
                                        ),
                                        decoration: const InputDecoration(
                                          hintText: 'Bản Đồ Apple',
                                          hintStyle: TextStyle(color: Colors.black38, fontSize: 16),
                                          border: InputBorder.none,
                                          isDense: true,
                                        ),
                                        onChanged: (val) {
                                          _onSearchChanged(val);
                                          setModalState(() {});
                                        },
                                        onSubmitted: (val) {
                                          _onSearchSubmitted(val);
                                          setModalState(() {});
                                        },
                                      ),
                                    ),
                                    if (_isAutocompleteRefreshing || _isResolvingGoogleLink)
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
                                          setModalState(() {});
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

                      if (_isResolvingGoogleLink)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: const Color(0xFF007AFF).withOpacity(0.08),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: const Color(0xFF007AFF).withOpacity(0.2)),
                            ),
                            child: Row(
                              children: [
                                const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF007AFF)),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    _googleLinkStatusText ?? 'Đang mở liên kết Google Maps…',
                                    style: const TextStyle(fontSize: 12, color: Color(0xFF007AFF), fontWeight: FontWeight.w600),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                GestureDetector(
                                  onTap: _cancelGoogleLinkResolution,
                                  child: const Padding(
                                    padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                    child: Text('Hủy', style: TextStyle(color: Color(0xFFFF3B30), fontWeight: FontWeight.bold, fontSize: 13)),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),

                      const SizedBox(height: 16),

                      // Body: Query Results or Recent Searches & Nearby Categories
                      Expanded(
                        child: isQueryMode
                            ? ListView.separated(
                                controller: scrollController,
                                padding: const EdgeInsets.symmetric(horizontal: 16),
                                itemCount: results.length,
                                separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.black12),
                                itemBuilder: (context, idx) {
                                  final p = results[idx];
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
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        _buildPrecisionBadge(p.precision),
                                      ],
                                    ),
                                    subtitle: Text(p.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.black54, fontSize: 13)),
                                    trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: Colors.black38),
                                    onTap: () {
                                      Navigator.pop(modalCtx);
                                      _onPlaceClicked(p);
                                    },
                                  );
                                },
                              )
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

                                  // Section 1: "Địa điểm đã lưu" (Saved Places)
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Row(
                                        children: [
                                          const Text(
                                            'Địa điểm đã lưu',
                                            style: TextStyle(
                                              fontSize: 19,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.black87,
                                              letterSpacing: -0.3,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          if (_searchService.savedPlaces.isNotEmpty)
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFF007AFF).withOpacity(0.12),
                                                borderRadius: BorderRadius.circular(10),
                                              ),
                                              child: Text(
                                                '${_searchService.savedPlaces.length}',
                                                style: const TextStyle(
                                                  color: Color(0xFF007AFF),
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ),
                                        ],
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
                                      children: _searchService.savedPlaces.isEmpty
                                          ? [
                                              Padding(
                                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                                                child: Row(
                                                  children: [
                                                    Icon(Icons.bookmark_outline_rounded, color: Colors.black26, size: 22),
                                                    const SizedBox(width: 10),
                                                    const Expanded(
                                                      child: Text(
                                                        'Chưa có địa điểm lưu. Chạm "Lưu" trên địa điểm để lưu vào đây.',
                                                        style: TextStyle(color: Colors.black45, fontSize: 13),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ]
                                          : _searchService.savedPlaces.map((p) {
                                              return Column(
                                                children: [
                                                  ListTile(
                                                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                                                    leading: Container(
                                                      width: 36,
                                                      height: 36,
                                                      decoration: BoxDecoration(
                                                        color: const Color(0xFFFF9500).withOpacity(0.15),
                                                        shape: BoxShape.circle,
                                                      ),
                                                      child: const Icon(Icons.star_rounded, color: Color(0xFFFF9500), size: 20),
                                                    ),
                                                    title: Text(
                                                      p.name,
                                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.black87),
                                                    ),
                                                    subtitle: Text(
                                                      p.displayName,
                                                      maxLines: 1,
                                                      overflow: TextOverflow.ellipsis,
                                                      style: const TextStyle(color: Colors.black45, fontSize: 13),
                                                    ),
                                                    trailing: Row(
                                                      mainAxisSize: MainAxisSize.min,
                                                      children: [
                                                        IconButton(
                                                          icon: const Icon(Icons.directions_rounded, color: Color(0xFF007AFF), size: 22),
                                                          tooltip: 'Chỉ đường',
                                                          onPressed: () {
                                                            Navigator.pop(modalCtx);
                                                            _calculateRoutesForPlace(p);
                                                          },
                                                        ),
                                                        IconButton(
                                                          icon: const Icon(Icons.close_rounded, color: Colors.black38, size: 18),
                                                          tooltip: 'Bỏ lưu',
                                                          onPressed: () async {
                                                            await _searchService.removeSavedPlace(p);
                                                            setModalState(() {});
                                                            setState(() {});
                                                          },
                                                        ),
                                                      ],
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

                                  const SizedBox(height: 20),

                                  // Section 2: "Lịch sử tìm kiếm" (Recent Searches)
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      const Row(
                                        children: [
                                          Text(
                                            'Lịch sử tìm kiếm',
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
                                          onTap: () async {
                                            await _searchService.clearRecentSearches();
                                            setModalState(() {});
                                            setState(() {});
                                          },
                                          child: const Text(
                                            'Xóa tất cả',
                                            style: TextStyle(
                                              color: Color(0xFF007AFF),
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
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
                                          : _searchService.recentSearches.take(8).map((p) {
                                              return Column(
                                                children: [
                                                  ListTile(
                                                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                                                    leading: const Icon(Icons.history_rounded, color: Colors.black45, size: 20),
                                                    title: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            p.name,
                                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.black87),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        _buildPrecisionBadge(p.precision),
                                      ],
                                    ),
                                                    subtitle: Text(p.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.black45, fontSize: 13)),
                                                    trailing: IconButton(
                                                      icon: const Icon(Icons.close_rounded, color: Colors.black38, size: 18),
                                                      tooltip: 'Xóa',
                                                      onPressed: () async {
                                                        await _searchService.deleteRecentSearch(p);
                                                        setModalState(() {});
                                                        setState(() {});
                                                      },
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
      _activeModalSetState = null;
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
              Builder(
                builder: (context) {
                  final isSaved = _searchService.isPlaceSaved(place);
                  return Row(
                    children: [
                      // Blue Directions Button (Car Icon + Travel Time e.g. "Chỉ đường")
                      Expanded(
                        flex: 5,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF007AFF),
                            foregroundColor: Colors.white,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          ),
                          icon: const Icon(Icons.directions_car_rounded, size: 20),
                          label: const Text(
                            'Chỉ đường',
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                          ),
                          onPressed: () => _calculateRoutesForPlace(place),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Bookmark / Save Place Button
                      Expanded(
                        flex: 4,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: isSaved ? const Color(0xFFFF9500).withOpacity(0.16) : const Color(0xFFE5F0FF),
                            foregroundColor: isSaved ? const Color(0xFFFF9500) : const Color(0xFF007AFF),
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          ),
                          icon: Icon(isSaved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded, size: 20),
                          label: Text(
                            isSaved ? 'Đã lưu' : 'Lưu',
                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                          ),
                          onPressed: () async {
                            await _searchService.toggleSavePlace(place);
                            setState(() {});
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  duration: const Duration(seconds: 1),
                                  content: Text(
                                    isSaved ? 'Đã xóa khỏi địa điểm đã lưu' : 'Đã lưu địa điểm thành công',
                                  ),
                                ),
                              );
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Copy GPS Coordinates Button
                      Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFFE5F0FF),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: IconButton(
                          icon: const Icon(Icons.copy_rounded, color: Color(0xFF007AFF), size: 20),
                          tooltip: 'Sao chép tọa độ GPS',
                          padding: const EdgeInsets.all(14),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(
                              text: '${place.coordinate.latitude.toStringAsFixed(6)}, ${place.coordinate.longitude.toStringAsFixed(6)}',
                            ));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Đã sao chép tọa độ GPS vào bộ nhớ tạm')),
                            );
                          },
                        ),
                      ),
                    ],
                  );
                },
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
                    const Text('Xếp hạng & Chi tiết', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.black87)),
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
                        Text('Dịch vụ:', style: TextStyle(fontSize: 12, color: Colors.black54)),
                        Text('Hoạt động bình thường', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF34C759))),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 12),

              // Bottom Action Bar: + (Lưu), ⭐ (Yêu thích), 👍 (Thích), ••• (Khác)
              Container(
                height: 46,
                decoration: BoxDecoration(
                  color: const Color(0xFFF2F2F7),
                  borderRadius: BorderRadius.circular(23),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    IconButton(icon: const Icon(Icons.add_rounded, color: Colors.black87), onPressed: () {}),
                    Container(width: 1, height: 20, color: Colors.black12),
                    IconButton(icon: const Icon(Icons.star_border_rounded, color: Colors.black87), onPressed: () {}),
                    Container(width: 1, height: 20, color: Colors.black12),
                    IconButton(icon: const Icon(Icons.thumb_up_alt_outlined, color: Colors.black87), onPressed: () {}),
                    Container(width: 1, height: 20, color: Colors.black12),
                    IconButton(icon: const Icon(Icons.more_horiz_rounded, color: Colors.black87), onPressed: () {}),
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
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE5F0FF),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text(
                          'Tùy chọn',
                          style: TextStyle(color: Color(0xFF007AFF), fontSize: 11, fontWeight: FontWeight.bold),
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
                                idx == 0 ? 'Đề xuất' : 'Tuyến ${idx + 1}',
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
                                ? 'Đề xuất'
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
  // Apple Maps Active Driving Turn Banner (Screenshot 5)
  // -------------------------------------------------------------
  Widget _buildAppleActiveDrivingTurnBanner(NavigationManager navManager) {
    final dist = navManager.distanceToNextManeuver.round();
    final distStr = dist >= 1000 ? '${(dist / 1000).toStringAsFixed(1)} km' : '$dist m';
    final instruction = navManager.bannerInstruction;
    final icon = navManager.bannerTurnIcon;

    return GestureDetector(
      onTap: () {
        if (kDebugMode) {
          setState(() => _showDebugOverlay = !_showDebugOverlay);
        }
      },
      child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E).withOpacity(0.96),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(0.1)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.35),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: [
          // Large Maneuver Icon (Circle with arrow)
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withOpacity(0.12),
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
                  'Trong $distStr',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  instruction,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
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
      ),
    );
  }

  Widget _buildAppleFloatingStreetPill(NavigationManager navManager) {
    final street = navManager.currentStep?.streetName ?? 'Lộ trình hiện tại';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF007AFF),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF007AFF).withOpacity(0.4),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            street,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  void _toggleDrivingZoom(NavigationManager navManager) {
    final ctrl = _mapController;
    if (ctrl == null) return;
    final pos = navManager.currentLocation ?? _userPosition;

    setState(() {
      _isDrivingZoomOverview = !_isDrivingZoomOverview;
    });

    if (_isDrivingZoomOverview) {
      // Zoom OUT to route overview (2D top-down)
      ctrl.animateCamera(
        ml.CameraUpdate.newCameraPosition(
          ml.CameraPosition(
            target: ml.LatLng(pos.latitude, pos.longitude),
            zoom: 14.5,
            tilt: 0.0,
            bearing: 0.0,
          ),
        ),
      );
    } else {
      // Zoom IN to driver perspective (3D follow)
      ctrl.animateCamera(
        ml.CameraUpdate.newCameraPosition(
          ml.CameraPosition(
            target: ml.LatLng(pos.latitude, pos.longitude),
            zoom: 17.5,
            tilt: 50.0,
            bearing: navManager.effectiveHeading,
          ),
        ),
      );
    }
  }

  Widget _buildAppleActiveDrivingBottomHud(NavigationManager navManager, BleService bleService) {
    final etaMins = navManager.remainingEtaMinutes;
    final now = DateTime.now().add(Duration(minutes: etaMins));
    final timeStr = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final hours = etaMins ~/ 60;
    final remMins = etaMins % 60;
    final durationStr = hours > 0 ? '$hours:${remMins.toString().padLeft(2, '0')}' : '$remMins';
    final durationUnit = hours > 0 ? 'giờ' : 'phút';
    final totalMeters = navManager.remainingTotalDistance.round();
    final distanceStr = totalMeters >= 1000
        ? (totalMeters >= 10000 ? (totalMeters / 1000).toStringAsFixed(0) : (totalMeters / 1000).toStringAsFixed(1))
        : '$totalMeters';
    final distanceUnit = totalMeters >= 1000 ? 'km' : 'm';

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        // Arrow Zoom In / Zoom Out button placed strictly ABOVE the red 'X' button!
        Padding(
          padding: const EdgeInsets.only(right: 20, bottom: 10),
          child: GestureDetector(
            onTap: () => _toggleDrivingZoom(navManager),
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.92),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.12),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(22),
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                  child: Center(
                    child: Icon(
                      _isDrivingZoomOverview ? Icons.near_me_rounded : Icons.navigation_rounded,
                      color: const Color(0xFF007AFF),
                      size: 24,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),

        // Bottom Capsule Navigation HUD
        Container(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.92),
            borderRadius: BorderRadius.circular(36),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.12),
                blurRadius: 20,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(36),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                child: Row(
                  children: [
                    // Column 1: ETA Clock
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Text(
                            timeStr,
                            style: const TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF1C1C1E),
                              letterSpacing: -0.5,
                            ),
                          ),
                          const SizedBox(height: 2),
                          const Text(
                            'đến',
                            style: TextStyle(
                              fontSize: 12,
                              color: Color(0xFF8E8E93),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Column 2: Duration
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Text(
                            durationStr,
                            style: const TextStyle(
                              fontSize: 21,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF007AFF),
                              letterSpacing: -0.5,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            durationUnit,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF8E8E93),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Column 3: Distance
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Text(
                            distanceStr,
                            style: const TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF1C1C1E),
                              letterSpacing: -0.5,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            distanceUnit,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF8E8E93),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Red circular End Route button - Clears route and restores clean map
                    GestureDetector(
                      onTap: () async {
                        _routeRenderCadenceTimer?.cancel();
                        _cameraCadenceTimer?.cancel();
                        _routes = [];
                        _selectedRouteIndex = 0;
                        navManager.stopNavigation();
                        navManager.setPreviewRoute(null);
                        await _routeRenderController.clearAndInvalidate();
                        await _mapController?.clearCircles();
                        if (mounted) {
                          setState(() {
                            _viewMode = 0;
                            _routes = [];
                            _selectedPlace = null;
                            _isDrivingZoomOverview = false;
                          });
                        }
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
                      },
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: const Color(0xFFFF3B30).withOpacity(0.12),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.close_rounded,
                          color: Color(0xFFFF3B30),
                          size: 24,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // -------------------------------------------------------------
  // Map Theme Picker Dialog
  // -------------------------------------------------------------
  void _showMapThemePicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('CHỌN GIAO DIỆN BẢN ĐỒ', style: TextStyle(color: Color(0xFF0084FF), fontWeight: FontWeight.bold, fontSize: 13, letterSpacing: 1)),
              const SizedBox(height: 14),
              _buildThemeOption(
                title: 'Bản đồ Đường phố (Streets)',
                subtitle: 'Giao diện vector sắc nét, tải nhanh chuẩn MapTiler',
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
            ],
          ),
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
        leading: Icon(icon, color: isSelected ? const Color(0xFF0084FF) : Colors.white60),
        title: Text(title, style: TextStyle(color: isSelected ? const Color(0xFF0084FF) : Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
        subtitle: Text(subtitle, style: const TextStyle(color: Colors.white54, fontSize: 12)),
        trailing: isSelected ? const Icon(Icons.check_circle_rounded, color: Color(0xFF0084FF)) : null,
        onTap: () {
          setState(() => _currentTheme = mode);
          try {
            final streamService = Provider.of<EspStreamService>(context, listen: false);
            if (mode == MapThemeMode.dark || mode == MapThemeMode.navigationNight) {
              streamService.streamMapStyle = 'streets-v2-dark';
            } else if (mode == MapThemeMode.satellite) {
              streamService.streamMapStyle = 'hybrid';
            } else {
              streamService.streamMapStyle = 'streets-v2';
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B).withAlpha(230),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: isConnected ? const Color(0xFF05FFA1) : Colors.white12),
        boxShadow: [BoxShadow(color: Colors.black.withAlpha(100), blurRadius: 8)],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isConnected ? Icons.bluetooth_connected_rounded : Icons.bluetooth_disabled_rounded,
            size: 14,
            color: isConnected ? const Color(0xFF05FFA1) : Colors.white38,
          ),
          const SizedBox(width: 6),
          Text(
            isConnected ? 'ESP32 Live' : 'ESP32 Off',
            style: TextStyle(
              color: isConnected ? const Color(0xFF05FFA1) : Colors.white54,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}
