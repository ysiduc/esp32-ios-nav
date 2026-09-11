import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:provider/provider.dart';
import '../models/route_model.dart';
import '../services/ble_service.dart';
import '../services/esp_stream_service.dart';
import '../services/google_maps_parser.dart';
import '../services/navigation_manager.dart';
import '../services/osrm_service.dart';
import '../services/search_service.dart';

enum MapThemeMode {
  googleRoad,      // Google Maps Standard HD Retina (Crisp, familiar, zero watermark)
  googleSatellite, // Google Maps Hybrid Satellite HD Retina
  darkCyber,       // Midnight Dark Mode HD Retina
  osmStandard,     // OpenStreetMap Standard
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final GlobalKey _mapStreamBoundaryKey = GlobalKey();
  final MapController _mapController = MapController();
  final MapController _streamMapController = MapController();
  final SearchService _searchService = SearchService();
  final OsrmService _osrmService = OsrmService();
  final GoogleMapsParser _googleMapsParser = GoogleMapsParser();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

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
  bool _isMuted = false;
  MapThemeMode _currentTheme = MapThemeMode.googleRoad; // Google Maps Retina HD (Zero blurriness!)

  List<MapPlace> _searchResults = [];
  Timer? _debounceTimer;
  String? _clipboardGoogleMapsText;
  String? _lastDismissedClipboardText;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final navManager = Provider.of<NavigationManager>(context, listen: false);
      if (navManager.currentLocation != null) {
        _userPosition = navManager.currentLocation!;
        _mapController.move(_userPosition, 16.0);
        try {
          _streamMapController.moveAndRotate(_userPosition, 17.8, -navManager.currentHeading);
        } catch (_) {}
      }

      // Hook navigation position update callback to continuously center vehicle
      navManager.onLocationChanged = (loc, heading) {
        if (mounted && navManager.isNavigating && _isAutoCentering) {
          _mapController.move(loc, 17.5);
        }
        try {
          _streamMapController.moveAndRotate(loc, 17.8, -heading);
        } catch (_) {}
      };

      // Auto-start headless 20-30 FPS live map stream
      final streamService = Provider.of<EspStreamService>(context, listen: false);
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

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _recenterTimer?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------
  // Search Logic
  // -------------------------------------------------------------
  void _onSearchChanged(String query) {
    _debounceTimer?.cancel();
    if (query.trim().isEmpty) {
      setState(() {
        _searchResults = [];
        _isSearching = false;
      });
      return;
    }

    if (GoogleMapsParser.isGoogleMapsOrCoordInput(query)) {
      _debounceTimer = Timer(const Duration(milliseconds: 300), () {
        _handleGoogleMapsOrSharedInput(query);
      });
      return;
    }

    setState(() => _isSearching = true);
    _debounceTimer = Timer(const Duration(milliseconds: 250), () async {
      final navManager = Provider.of<NavigationManager>(context, listen: false);
      final currentPos = navManager.currentLocation ?? _userPosition;
      final results = await _searchService.searchPlaces(query, nearLocation: currentPos);
      if (mounted) {
        setState(() {
          _searchResults = results;
          _isSearching = false;
        });
      }
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
    setState(() => _isSearching = true);

    final navManager = Provider.of<NavigationManager>(context, listen: false);
    final currentPos = navManager.currentLocation ?? _userPosition;
    final results = await _searchService.searchPlaces(clean, nearLocation: currentPos);

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

  void _onPlaceClicked(MapPlace place) {
    _searchFocusNode.unfocus();
    _searchService.addRecentSearch(place);
    setState(() {
      _selectedPlace = place;
      _searchResults = [];
      _viewMode = 1; // Open Place Details Inspector
    });
    _mapController.move(place.coordinate, 16.5);
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
      _mapController.move(point, 16.5);
    }
  }

  // -------------------------------------------------------------
  // Route Calculation & Comparison Logic
  // -------------------------------------------------------------
  Future<void> _calculateRoutesForPlace(MapPlace place) async {
    final navManager = Provider.of<NavigationManager>(context, listen: false);
    final startPos = navManager.currentLocation ?? _userPosition;

    setState(() {
      _isLoadingRoutes = true;
      _selectedPlace = place;
      _viewMode = 2; // Open Route Comparison
      _selectedRouteIndex = 0;
      _routes = [];
    });

    final routes = await _osrmService.calculateMultipleRoutes(
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
        _fitRouteBounds(routes.first.polylinePoints);
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

    _mapController.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds(LatLng(minLat, minLng), LatLng(maxLat, maxLng)),
        padding: const EdgeInsets.only(top: 140, bottom: 320, left: 40, right: 40),
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

    // Always center vehicle at the exact center of map at start
    final startPos = navManager.currentLocation ?? _userPosition;
    _mapController.move(startPos, 17.5);
  }

  void _recenterToVehicle() {
    final navManager = Provider.of<NavigationManager>(context, listen: false);
    final current = navManager.currentLocation ?? _userPosition;
    setState(() {
      _isAutoCentering = true;
    });
    _mapController.move(current, 17.5);
  }

  // -------------------------------------------------------------
  // Map Tiles Layer (Ultra-Sharp HD Google Maps & CartoDB Retina Tiles)
  // -------------------------------------------------------------
  Widget _buildMapTiles() {
    switch (_currentTheme) {
      case MapThemeMode.googleRoad:
        return TileLayer(
          urlTemplate: 'https://mt1.google.com/vt/lyrs=m&hl=vi&x={x}&y={y}&z={z}',
          userAgentPackageName: 'com.esp32nav.app',
          maxZoom: 20,
        );
      case MapThemeMode.googleSatellite:
        return TileLayer(
          urlTemplate: 'https://mt1.google.com/vt/lyrs=y&hl=vi&x={x}&y={y}&z={z}',
          userAgentPackageName: 'com.esp32nav.app',
          maxZoom: 20,
        );
      case MapThemeMode.darkCyber:
        return TileLayer(
          urlTemplate: 'https://a.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}@2x.png',
          userAgentPackageName: 'com.esp32nav.app',
          maxZoom: 20,
        );
      case MapThemeMode.osmStandard:
        return TileLayer(
          urlTemplate: 'https://a.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}@2x.png',
          userAgentPackageName: 'com.esp32nav.app',
          maxZoom: 20,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final navManager = context.watch<NavigationManager>();
    final bleService = context.watch<BleService>();
    final isDriving = navManager.isNavigating;
    final userPos = navManager.currentLocation ?? _userPosition;

    final showDropdown = _searchFocusNode.hasFocus ||
        _searchController.text.isNotEmpty ||
        _searchResults.isNotEmpty ||
        _isSearching;

    // Keep Stream Mini Map synced with vehicle
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        _streamMapController.moveAndRotate(userPos, 17.8, -navManager.currentHeading);
      } catch (_) {}
    });

    return Scaffold(
      backgroundColor: const Color(0xFF0F141C),
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          // -----------------------------------------------------------
          // 0. Dedicated HD Zoomed-In Map Stream Viewport for ESP32 (165x185 Retina)
          // -----------------------------------------------------------
          SizedBox(
            width: 144,
            height: 208,
            child: RepaintBoundary(
              key: _mapStreamBoundaryKey,
              child: _buildDedicatedStreamMap(userPos, navManager),
            ),
          ),

          // -----------------------------------------------------------
          // 1. Crystal-Clear Main FlutterMap Layer (Retina HD!)
          // -----------------------------------------------------------
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: userPos,
              initialZoom: 16.5,
              onTap: (_, point) => _onMapTapped(point),
              onPositionChanged: (pos, hasGesture) {
                // If user dragged map during active driving, pause auto-centering
                if (hasGesture && isDriving && _isAutoCentering) {
                  setState(() => _isAutoCentering = false);
                  _recenterTimer?.cancel();
                  _recenterTimer = Timer(const Duration(seconds: 5), () {
                    if (mounted && isDriving) {
                      _recenterToVehicle();
                    }
                  });
                }
              },
            ),
            children: [
              _buildMapTiles(),

              // Multi-Route Polyline Layers (Comparison Mode)
              if (!isDriving && _routes.isNotEmpty && _viewMode == 2) ...[
                // Render Inactive Routes first (Slate Grey with slight glow)
                for (int i = 0; i < _routes.length; i++)
                  if (i != _selectedRouteIndex)
                    PolylineLayer(
                      polylines: [
                        Polyline(
                          points: _routes[i].polylinePoints,
                          strokeWidth: 6.5,
                          color: const Color(0xFF475569).withAlpha(190),
                        ),
                      ],
                    ),

                // Render Selected Active Route on Top (Vibrant Cyan/Green Glow)
                if (_selectedRouteIndex < _routes.length)
                  PolylineLayer(
                    polylines: [
                      // Outer glow layer
                      Polyline(
                        points: _routes[_selectedRouteIndex].polylinePoints,
                        strokeWidth: 12.0,
                        color: _routes[_selectedRouteIndex].themeColor.withAlpha(90),
                      ),
                      // Core bright polyline
                      Polyline(
                        points: _routes[_selectedRouteIndex].polylinePoints,
                        strokeWidth: 7.5,
                        color: _routes[_selectedRouteIndex].themeColor,
                      ),
                    ],
                  ),
              ],

              // Active Navigation Driving Polyline
              if (isDriving && navManager.activeRoute != null)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: navManager.activeRoute!.polylinePoints,
                      strokeWidth: 13.0,
                      color: const Color(0xFF0077B6).withAlpha(120),
                    ),
                    Polyline(
                      points: navManager.activeRoute!.polylinePoints,
                      strokeWidth: 8.0,
                      color: const Color(0xFF00F0FF),
                    ),
                  ],
                ),

              // Markers Layer
              MarkerLayer(
                markers: [
                  // A. User GPS Navigation Puck with heading arrow & pulsing aura
                  Marker(
                    point: userPos,
                    width: 56,
                    height: 56,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFF0084FF).withAlpha(35),
                            border: Border.all(color: const Color(0xFF0084FF).withAlpha(100), width: 1.5),
                          ),
                        ),
                        Transform.rotate(
                          angle: (navManager.currentHeading * (3.1415926535 / 180.0)),
                          child: Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: const Color(0xFF0084FF),
                              boxShadow: [
                                BoxShadow(color: const Color(0xFF0084FF).withAlpha(180), blurRadius: 10),
                                BoxShadow(color: Colors.black.withAlpha(120), blurRadius: 4),
                              ],
                            ),
                            child: const Icon(
                              Icons.navigation_rounded,
                              color: Colors.white,
                              size: 22,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // B. Selected Destination Pin Marker
                  if (_selectedPlace != null && !isDriving)
                    Marker(
                      point: _selectedPlace!.coordinate,
                      width: 52,
                      height: 60,
                      alignment: Alignment.topCenter,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: const LinearGradient(
                                colors: [Color(0xFFFF2E63), Color(0xFFFF5722)],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              boxShadow: [
                                BoxShadow(color: const Color(0xFFFF2E63).withAlpha(140), blurRadius: 12),
                                BoxShadow(color: Colors.black.withAlpha(120), blurRadius: 6),
                              ],
                            ),
                            child: const Icon(Icons.location_on_rounded, color: Colors.white, size: 22),
                          ),
                          CustomPaint(
                            size: const Size(12, 6),
                            painter: _TrianglePainter(color: const Color(0xFFFF5722)),
                          ),
                        ],
                      ),
                    ),

                  // C. Interactive Route ETA Pills on Map (Tap polyline label to switch routes)
                  if (!isDriving && _viewMode == 2 && _routes.length > 1) ...[
                    for (int i = 0; i < _routes.length; i++)
                      if (_routes[i].polylinePoints.isNotEmpty)
                        Marker(
                          point: _routes[i].polylinePoints[_routes[i].polylinePoints.length ~/ 2],
                          width: 90,
                          height: 36,
                          child: GestureDetector(
                            onTap: () => setState(() => _selectedRouteIndex = i),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: _selectedRouteIndex == i
                                    ? const Color(0xFF0077B6)
                                    : const Color(0xFF1E293B).withAlpha(240),
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(
                                  color: _selectedRouteIndex == i ? const Color(0xFF00F0FF) : Colors.white24,
                                  width: 1.5,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withAlpha(140),
                                    blurRadius: 6,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: Center(
                                child: Text(
                                  _routes[i].formattedDuration,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                  ],
                ],
              ),
            ],
          ),

          // -----------------------------------------------------------
          // 2. Top Bar: Search Bar, Clipboard Banner & Quick Categories (Browse Mode)
          // -----------------------------------------------------------
          if (!isDriving && _viewMode == 0)
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 8.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildModernSearchBar(),
                    if (_clipboardGoogleMapsText != null && !showDropdown)
                      _buildClipboardGoogleMapsBanner(),
                    if (showDropdown)
                      _buildSearchResultsDropdown(),
                    if (!showDropdown)
                      _buildQuickCategoriesRow(),
                  ],
                ),
              ),
            ),

          // -----------------------------------------------------------
          // 3. Top Route Config Header (Route Comparison Mode)
          // -----------------------------------------------------------
          if (!isDriving && _viewMode == 2)
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 8.0),
                child: _buildRouteComparisonTopHeader(),
              ),
            ),

          // -----------------------------------------------------------
          // 4. Floating Action Controls (Right side: Theme, Compass, GPS / Recenter)
          // -----------------------------------------------------------
          Positioned(
            right: 14,
            top: isDriving ? 110 : (_viewMode == 0 ? 118 : 170),
            child: Column(
              children: [
                _buildFloatingButton(
                  icon: Icons.layers_rounded,
                  tooltip: 'Đổi nền bản đồ',
                  onTap: _showMapThemePicker,
                ),
                const SizedBox(height: 10),
                _buildFloatingButton(
                  icon: Icons.explore_rounded,
                  iconColor: const Color(0xFFFF5252),
                  tooltip: 'Xoay về hướng Bắc',
                  onTap: () => _mapController.rotate(0),
                ),
                const SizedBox(height: 10),
                // Recenter / GPS Button
                _buildFloatingButton(
                  icon: isDriving && !_isAutoCentering
                      ? Icons.center_focus_strong_rounded
                      : Icons.my_location_rounded,
                  iconColor: isDriving && !_isAutoCentering ? const Color(0xFF00F0FF) : const Color(0xFF0084FF),
                  tooltip: isDriving ? 'Khóa tâm về xe' : 'Vị trí của tôi',
                  onTap: () {
                    if (isDriving) {
                      _recenterToVehicle();
                    } else {
                      final current = navManager.currentLocation ?? _userPosition;
                      _mapController.move(current, 16.5);
                    }
                  },
                ),
                if (isDriving) ...[
                  const SizedBox(height: 10),
                  _buildFloatingButton(
                    icon: _isMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                    tooltip: 'Âm thanh',
                    onTap: () => setState(() => _isMuted = !_isMuted),
                  ),
                ],
              ],
            ),
          ),

          // BLE Connection Mini Status Pill
          Positioned(
            left: 16,
            top: isDriving ? 110 : (_viewMode == 0 ? 120 : 170),
            child: _buildBleStatusBadge(bleService),
          ),

          // -----------------------------------------------------------
          // 5. Active Driving Top Turn Banner
          // -----------------------------------------------------------
          if (isDriving)
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 8.0),
                child: _buildActiveDrivingTurnBanner(navManager),
              ),
            ),

          // Floating "Khóa về vị trí" Banner when user manually pans map while driving
          if (isDriving && !_isAutoCentering)
            Positioned(
              bottom: 120,
              left: 0,
              right: 0,
              child: Center(
                child: GestureDetector(
                  onTap: _recenterToVehicle,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0084FF),
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(color: const Color(0xFF0084FF).withAlpha(140), blurRadius: 12, offset: const Offset(0, 3)),
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
          // 6. Bottom Panels
          // -----------------------------------------------------------
          // A. Place Inspector Bottom Sheet (Mode 1)
          if (!isDriving && _viewMode == 1 && _selectedPlace != null)
            Align(
              alignment: Alignment.bottomCenter,
              child: _buildPlaceInspectorBottomSheet(),
            ),

          // B. Route Comparison & Alternatives Bottom Sheet (Mode 2)
          if (!isDriving && _viewMode == 2)
            Align(
              alignment: Alignment.bottomCenter,
              child: _buildRouteComparisonBottomSheet(),
            ),

          // C. Active Driving HUD (Driving Mode)
          if (isDriving)
            Align(
              alignment: Alignment.bottomCenter,
              child: _buildActiveDrivingBottomHud(navManager, bleService),
            ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------
  // UI Component: Floating Google Maps Clipboard Banner
  // -------------------------------------------------------------
  Widget _buildClipboardGoogleMapsBanner() {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B).withAlpha(252),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF0084FF), width: 1.5),
        boxShadow: [
          BoxShadow(color: Colors.black.withAlpha(160), blurRadius: 12, offset: const Offset(0, 3)),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: const Color(0xFF0084FF).withAlpha(35),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.share_location_rounded, color: Color(0xFF0084FF), size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Link Google Maps trong bộ nhớ tạm',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                ),
                Text(
                  _clipboardGoogleMapsText ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white60, fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => _handleGoogleMapsOrSharedInput(_clipboardGoogleMapsText!),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF0084FF), Color(0xFF00B4D8)],
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text(
                'Mở ngay',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11),
              ),
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: () => setState(() => _clipboardGoogleMapsText = null),
            child: const Icon(Icons.close_rounded, color: Colors.white38, size: 18),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------
  // UI Component: Modern Search Bar
  // -------------------------------------------------------------
  Widget _buildModernSearchBar() {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B).withAlpha(245),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: Colors.white12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(160),
            blurRadius: 18,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          const Icon(Icons.search_rounded, color: Color(0xFF0084FF), size: 24),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _searchController,
              focusNode: _searchFocusNode,
              onChanged: _onSearchChanged,
              onSubmitted: _onSearchSubmitted,
              style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
              decoration: const InputDecoration(
                hintText: 'Nhập địa danh, số nhà, link Google Maps...',
                hintStyle: TextStyle(color: Colors.white38, fontSize: 13),
                border: InputBorder.none,
                isDense: true,
              ),
            ),
          ),
          if (_isSearching)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF0084FF)),
            )
          else if (_searchController.text.isNotEmpty)
            GestureDetector(
              onTap: () {
                _searchController.clear();
                _onSearchChanged('');
                setState(() => _searchResults = []);
              },
              child: const Icon(Icons.close_rounded, color: Colors.white54, size: 20),
            )
          else ...[
            GestureDetector(
              onTap: _pasteFromClipboard,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF0084FF).withAlpha(30),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF0084FF).withAlpha(80)),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.content_paste_rounded, color: Color(0xFF0084FF), size: 14),
                    SizedBox(width: 4),
                    Text(
                      'Dán',
                      style: TextStyle(color: Color(0xFF0084FF), fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // -------------------------------------------------------------
  // UI Component: Quick Category Chips (Horizontal Scroll)
  // -------------------------------------------------------------
  Widget _buildQuickCategoriesRow() {
    final categories = QuickSearchCategory.defaultCategories;
    return Container(
      height: 40,
      margin: const EdgeInsets.only(top: 8),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: categories.length + 1,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          if (index == 0) {
            // First item: 1-Tap Google Maps Paste Chip
            return GestureDetector(
              onTap: _pasteFromClipboard,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF0052D4), Color(0xFF4364F7)],
                  ),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white24),
                  boxShadow: [
                    BoxShadow(color: const Color(0xFF0052D4).withAlpha(120), blurRadius: 6),
                  ],
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.share_location_rounded, size: 16, color: Colors.white),
                    SizedBox(width: 6),
                    Text(
                      'Dán Google Maps',
                      style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            );
          }

          final cat = categories[index - 1];
          return GestureDetector(
            onTap: () => _onSelectCategory(cat),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B).withAlpha(230),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white12),
                boxShadow: [
                  BoxShadow(color: Colors.black.withAlpha(100), blurRadius: 6),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(cat.icon, size: 16, color: cat.color),
                  const SizedBox(width: 6),
                  Text(
                    cat.title,
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // -------------------------------------------------------------
  // UI Component: Search Results & Recent History Dropdown
  // -------------------------------------------------------------
  Widget _buildSearchResultsDropdown() {
    final query = _searchController.text.trim();
    final isQueryMode = query.isNotEmpty;
    final listToShow = isQueryMode ? _searchResults : _searchService.recentSearches;

    return Container(
      margin: const EdgeInsets.only(top: 8),
      constraints: const BoxConstraints(maxHeight: 340),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B).withAlpha(252),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white12),
        boxShadow: [
          BoxShadow(color: Colors.black.withAlpha(180), blurRadius: 20),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  !isQueryMode
                      ? 'ĐÃ TÌM GẦN ĐÂY'
                      : (_isSearching ? 'ĐANG TÌM KIẾM...' : 'KẾT QUẢ TÌM KIẾM (${listToShow.length})'),
                  style: const TextStyle(color: Color(0xFF0084FF), fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1),
                ),
                if (!isQueryMode && listToShow.isNotEmpty)
                  GestureDetector(
                    onTap: () => setState(() => _searchService.clearRecentSearches()),
                    child: const Text('Xóa lịch sử', style: TextStyle(color: Colors.white38, fontSize: 11)),
                  ),
              ],
            ),
          ),
          const Divider(color: Colors.white10, height: 1),
          // 1-Tap Google Maps Paste Action Tile in Dropdown
          Material(
            color: const Color(0xFF0084FF).withAlpha(15),
            child: InkWell(
              onTap: _pasteFromClipboard,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0084FF).withAlpha(30),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.share_location_rounded, color: Color(0xFF0084FF), size: 16),
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Dán liên kết từ Google Maps hoặc tọa độ',
                            style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                          ),
                          Text(
                            'Hỗ trợ maps.app.goo.gl, goo.gl/maps, tọa độ...',
                            style: TextStyle(color: Colors.white38, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.arrow_forward_ios_rounded, color: Color(0xFF0084FF), size: 12),
                  ],
                ),
              ),
            ),
          ),
          const Divider(color: Colors.white10, height: 1),
          Flexible(
            child: _isSearching
                ? Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF0084FF)),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            'Đang tìm "$query"...',
                            style: const TextStyle(color: Colors.white70, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  )
                : (listToShow.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(24.0),
                        child: Center(
                          child: Text(
                            isQueryMode
                                ? 'Không tìm thấy địa điểm "$query".\nHãy kiểm tra lại chính tả hoặc gõ tên đường, quận huyện.'
                                : 'Chưa có lịch sử tìm kiếm.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white54, fontSize: 13),
                          ),
                        ),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        itemCount: listToShow.length,
                        separatorBuilder: (_, __) => const Divider(color: Colors.white10, height: 1),
                        itemBuilder: (context, index) {
                          final place = listToShow[index];
                          return Material(
                            color: Colors.transparent,
                            child: ListTile(
                              dense: true,
                              leading: Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF0F172A),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Icon(place.categoryIcon, color: const Color(0xFF0084FF), size: 18),
                              ),
                              title: Text(
                                place.name,
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                place.shortSubtitle,
                                style: const TextStyle(color: Colors.white54, fontSize: 12),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: place.formattedDistance.isNotEmpty
                                  ? Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF0084FF).withAlpha(20),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text(
                                        place.formattedDistance,
                                        style: const TextStyle(color: Color(0xFF0084FF), fontSize: 11, fontWeight: FontWeight.bold),
                                      ),
                                    )
                                  : null,
                              onTap: () => _onPlaceClicked(place),
                            ),
                          );
                        },
                      )),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------
  // UI Component: Place Details Inspector (Mode 1)
  // -------------------------------------------------------------
  Widget _buildPlaceInspectorBottomSheet() {
    final place = _selectedPlace!;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 26),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: const Border(top: BorderSide(color: Colors.white12)),
        boxShadow: [
          BoxShadow(color: Colors.black.withAlpha(200), blurRadius: 25),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF2E63).withAlpha(25),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFFF2E63).withAlpha(80)),
                  ),
                  child: const Icon(Icons.location_on_rounded, color: Color(0xFFFF2E63), size: 28),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        place.name,
                        style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                        maxLines: 2,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        place.displayName,
                        style: const TextStyle(color: Colors.white60, fontSize: 13),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.white54),
                  onPressed: () => setState(() => _viewMode = 0),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white24),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    icon: const Icon(Icons.close_rounded, size: 18),
                    label: const Text('Đóng', style: TextStyle(fontWeight: FontWeight.bold)),
                    onPressed: () => setState(() => _viewMode = 0),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0084FF),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      elevation: 4,
                    ),
                    icon: const Icon(Icons.directions_rounded, size: 22),
                    label: const Text(
                      'TÌM ĐƯỜNG ĐI',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                    ),
                    onPressed: () => _calculateRoutesForPlace(place),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------
  // UI Component: Route Comparison Top Header (Mode 2)
  // -------------------------------------------------------------
  Widget _buildRouteComparisonTopHeader() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B).withAlpha(245),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white12),
        boxShadow: [BoxShadow(color: Colors.black.withAlpha(160), blurRadius: 18)],
      ),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 18),
                onPressed: () => setState(() => _viewMode = 0),
              ),
              Expanded(
                child: Column(
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.radio_button_checked, color: Color(0xFF0084FF), size: 16),
                        SizedBox(width: 8),
                        Text(
                          'Vị trí của bạn',
                          style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                    const Divider(color: Colors.white12, height: 12),
                    Row(
                      children: [
                        const Icon(Icons.location_on, color: Color(0xFFFF2E63), size: 18),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _selectedPlace?.name ?? 'Điểm đến',
                            style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Transport Mode Selector: 🏍️ Xe máy (Default) | 🚗 Ô tô | 🚶 Đi bộ
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                _buildTransportTab(icon: Icons.two_wheeler_rounded, label: 'Xe máy', mode: 'bike'),
                _buildTransportTab(icon: Icons.directions_car_rounded, label: 'Ô tô', mode: 'driving'),
                _buildTransportTab(icon: Icons.directions_walk_rounded, label: 'Đi bộ', mode: 'foot'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTransportTab({required IconData icon, required String label, required String mode}) {
    final isSelected = _transportMode == mode;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          if (_transportMode != mode) {
            setState(() => _transportMode = mode);
            if (_selectedPlace != null) {
              _calculateRoutesForPlace(_selectedPlace!);
            }
          }
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: isSelected ? const Color(0xFF0084FF) : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: isSelected ? Colors.white : Colors.white60),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: isSelected ? Colors.white : Colors.white60,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------
  // UI Component: Route Comparison & Alternatives Bottom Sheet (Mode 2)
  // -------------------------------------------------------------
  Widget _buildRouteComparisonBottomSheet() {
    if (_isLoadingRoutes) {
      return Container(
        height: 220,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          boxShadow: [BoxShadow(color: Colors.black.withAlpha(200), blurRadius: 25)],
        ),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Color(0xFF0084FF)),
            SizedBox(height: 16),
            Text(
              'Đang tính toán các lựa chọn đường đi tối ưu...',
              style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 4),
            Text('Tìm đường ngắn nhất, nhanh nhất & tránh tắc', style: TextStyle(color: Colors.white54, fontSize: 12)),
          ],
        ),
      );
    }

    if (_routes.isEmpty) {
      return Container(
        height: 200,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline_rounded, color: Colors.amber, size: 36),
            const SizedBox(height: 10),
            const Text('Không tìm thấy đường đi tới vị trí này', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () => setState(() => _viewMode = 0),
              child: const Text('Quay lại bản đồ'),
            ),
          ],
        ),
      );
    }

    final selectedRoute = _routes[_selectedRouteIndex];

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: const Border(top: BorderSide(color: Colors.white12)),
        boxShadow: [BoxShadow(color: Colors.black.withAlpha(200), blurRadius: 25)],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
              ),
            ),

            // Horizontal Route Selection Cards Carousel
            SizedBox(
              height: 105,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _routes.length,
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (context, index) {
                  final r = _routes[index];
                  final isSelected = _selectedRouteIndex == index;

                  return GestureDetector(
                    onTap: () {
                      setState(() => _selectedRouteIndex = index);
                      _fitRouteBounds(r.polylinePoints);
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: 225,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: isSelected ? const Color(0xFF0F172A) : const Color(0xFF161E28),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: isSelected ? const Color(0xFF0084FF) : Colors.white12,
                          width: isSelected ? 2 : 1,
                        ),
                        boxShadow: isSelected
                            ? [BoxShadow(color: const Color(0xFF0084FF).withAlpha(60), blurRadius: 10)]
                            : [],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                r.title,
                                style: TextStyle(
                                  color: isSelected ? const Color(0xFF0084FF) : Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                              ),
                              if (r.formattedDiffTag.isNotEmpty)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: (r.isFastest ? const Color(0xFF0084FF) : const Color(0xFF10B981)).withAlpha(30),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    r.formattedDiffTag,
                                    style: TextStyle(
                                      color: r.isFastest ? const Color(0xFF0084FF) : const Color(0xFF10B981),
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              Text(
                                r.formattedDuration,
                                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                r.formattedDistance,
                                style: const TextStyle(color: Colors.white60, fontSize: 13),
                              ),
                            ],
                          ),
                          Text(
                            r.subtitle,
                            style: const TextStyle(color: Colors.white38, fontSize: 11),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),

            const SizedBox(height: 14),

            // Selected Route Summary & Action Buttons
            Row(
              children: [
                // Step preview button
                IconButton(
                  style: IconButton.styleFrom(
                    backgroundColor: const Color(0xFF0F172A),
                    padding: const EdgeInsets.all(12),
                  ),
                  icon: const Icon(Icons.format_list_bulleted_rounded, color: Colors.white, size: 22),
                  tooltip: 'Xem danh sách bước rẽ',
                  onPressed: () => _showTurnStepsModal(selectedRoute),
                ),
                const SizedBox(width: 8),
                // Simulation Test Button
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF0084FF),
                    side: const BorderSide(color: Color(0xFF0084FF), width: 1.2),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  icon: const Icon(Icons.play_arrow_rounded, size: 20),
                  label: const Text('Mô phỏng', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  onPressed: () => _startDriving(isSimulation: true),
                ),
                const SizedBox(width: 8),
                // Real Start Driving Button
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0084FF),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      elevation: 4,
                    ),
                    icon: const Icon(Icons.navigation_rounded, size: 20),
                    label: const Text(
                      'BẮT ĐẦU',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                    ),
                    onPressed: () => _startDriving(isSimulation: false),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------
  // UI Component: Turn-by-Turn Preview List Modal
  // -------------------------------------------------------------
  void _showTurnStepsModal(NavRoute route) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E293B),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          maxChildSize: 0.85,
          minChildSize: 0.4,
          expand: false,
          builder: (_, scrollController) {
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(route.title, style: const TextStyle(color: Color(0xFF0084FF), fontWeight: FontWeight.bold, fontSize: 16)),
                          Text('${route.formattedDuration} • ${route.formattedDistance}', style: const TextStyle(color: Colors.white70, fontSize: 13)),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded, color: Colors.white),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                ),
                const Divider(color: Colors.white12, height: 1),
                Expanded(
                  child: ListView.separated(
                    controller: scrollController,
                    itemCount: route.steps.length,
                    separatorBuilder: (_, __) => const Divider(color: Colors.white10, height: 1),
                    itemBuilder: (context, idx) {
                      final step = route.steps[idx];
                      final distStr = step.distanceMeters >= 1000
                          ? '${(step.distanceMeters / 1000).toStringAsFixed(1)} km'
                          : '${step.distanceMeters.round()} m';

                      return Material(
                        color: Colors.transparent,
                        child: ListTile(
                          leading: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: const Color(0xFF0F172A),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(step.icon, color: const Color(0xFF0084FF), size: 22),
                          ),
                          title: Text(step.instruction, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
                          subtitle: Text(step.streetName, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                          trailing: Text(distStr, style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.bold, fontSize: 13)),
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // -------------------------------------------------------------
  // UI Component: Active Driving Turn Banner
  // -------------------------------------------------------------
  Widget _buildActiveDrivingTurnBanner(NavigationManager navManager) {
    final step = navManager.currentStep;
    final dist = navManager.distanceToNextManeuver.round();
    final distStr = dist >= 1000 ? '${(dist / 1000).toStringAsFixed(1)} km' : '$dist m';
    final street = step?.streetName ?? 'Tiếp tục đi thẳng';
    final icon = step?.icon ?? Icons.straight_rounded;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A).withAlpha(245),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFF0084FF).withAlpha(120), width: 1.5),
        boxShadow: [
          BoxShadow(color: Colors.black.withAlpha(180), blurRadius: 20, offset: const Offset(0, 4)),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF0084FF).withAlpha(30),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: const Color(0xFF0084FF), size: 36),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Trong $distStr',
                  style: const TextStyle(color: Color(0xFF0084FF), fontSize: 18, fontWeight: FontWeight.bold),
                ),
                Text(
                  street,
                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
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

  // -------------------------------------------------------------
  // UI Component: Active Driving Bottom HUD
  // -------------------------------------------------------------
  Widget _buildActiveDrivingBottomHud(NavigationManager navManager, BleService bleService) {
    final speed = navManager.currentSpeedKmh.round();
    final etaMins = navManager.remainingEtaMinutes;
    final now = DateTime.now().add(Duration(minutes: etaMins));
    final timeStr = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final distKm = (navManager.remainingTotalDistance / 1000).toStringAsFixed(1);

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 26),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: const Border(top: BorderSide(color: Colors.white12)),
        boxShadow: [BoxShadow(color: Colors.black.withAlpha(200), blurRadius: 25)],
      ),
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // Speedometer Circle
            Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF0F172A),
                border: Border.all(color: const Color(0xFF0084FF).withAlpha(120), width: 2),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('$speed', style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold, height: 1)),
                  const Text('km/h', style: TextStyle(color: Colors.white60, fontSize: 9, fontWeight: FontWeight.bold)),
                ],
              ),
            ),

            // Arrival ETA & Remaining Dist
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  timeStr,
                  style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold),
                ),
                Text(
                  '$etaMins phút  •  $distKm km',
                  style: const TextStyle(color: Color(0xFF0084FF), fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ],
            ),

            // Stop Navigation Button
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFEF4444),
                foregroundColor: Colors.white,
                shape: const CircleBorder(),
                padding: const EdgeInsets.all(14),
                elevation: 4,
              ),
              onPressed: () => navManager.stopNavigation(),
              child: const Icon(Icons.close_rounded, size: 24),
            ),
          ],
        ),
      ),
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
                title: 'Google Maps Chuẩn (HD Retina)',
                subtitle: 'Giao diện quen thuộc, độ phân giải cao sắc nét, không mờ',
                mode: MapThemeMode.googleRoad,
                icon: Icons.map_rounded,
              ),
              _buildThemeOption(
                title: 'Vệ tinh Google (Satellite Hybrid HD)',
                subtitle: 'Ảnh chụp vệ tinh thực tế độ nét cao kèm tên đường tiếng Việt',
                mode: MapThemeMode.googleSatellite,
                icon: Icons.satellite_alt_rounded,
              ),
              _buildThemeOption(
                title: 'Chế độ Ban Đêm (Dark Cyber)',
                subtitle: 'Theme tối độ tương phản cao, dịu mắt khi lái xe đêm',
                mode: MapThemeMode.darkCyber,
                icon: Icons.dark_mode_rounded,
              ),
              _buildThemeOption(
                title: 'OpenStreetMap',
                subtitle: 'Bản đồ mở thế giới',
                mode: MapThemeMode.osmStandard,
                icon: Icons.public_rounded,
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
          Navigator.pop(context);
        },
      ),
    );
  }

  // -------------------------------------------------------------
  // Helper Floating Action Button
  // -------------------------------------------------------------
  Widget _buildFloatingButton({
    required IconData icon,
    required VoidCallback onTap,
    String? tooltip,
    Color iconColor = Colors.white,
  }) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B).withAlpha(240),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white12),
        boxShadow: [BoxShadow(color: Colors.black.withAlpha(120), blurRadius: 10)],
      ),
      child: IconButton(
        icon: Icon(icon, color: iconColor, size: 22),
        tooltip: tooltip,
        onPressed: onTap,
        padding: EdgeInsets.zero,
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

  Widget _buildDedicatedStreamMap(LatLng userPos, NavigationManager navManager) {
    final activeRoute = navManager.activeRoute;
    return Container(
      width: 144,
      height: 208,
      color: const Color(0xFF0F172A),
      child: Stack(
        alignment: Alignment.center,
        children: [
          FlutterMap(
            mapController: _streamMapController,
            options: MapOptions(
              initialCenter: userPos,
              initialZoom: 16.0,
              initialRotation: -navManager.currentHeading,
              interactionOptions: const InteractionOptions(flags: InteractiveFlag.none),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://mt1.google.com/vt/lyrs=m&hl=vi&x={x}&y={y}&z={z}',
                userAgentPackageName: 'com.esp32nav.app',
                maxZoom: 20,
              ),
              if (activeRoute != null) ...[
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: activeRoute.polylinePoints,
                      strokeWidth: 10.0,
                      color: const Color(0xFF0077B6).withAlpha(140),
                    ),
                    Polyline(
                      points: activeRoute.polylinePoints,
                      strokeWidth: 6.5,
                      color: const Color(0xFF00F0FF),
                    ),
                  ],
                ),
              ],
              MarkerLayer(
                markers: [
                  Marker(
                    point: userPos,
                    width: 36,
                    height: 36,
                    alignment: Alignment.center,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFF0084FF).withAlpha(45),
                            border: Border.all(color: const Color(0xFF0084FF).withAlpha(180), width: 1.5),
                          ),
                        ),
                        Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFF0084FF),
                            border: Border.all(color: Colors.white, width: 2),
                            boxShadow: [
                              BoxShadow(color: const Color(0xFF0084FF).withAlpha(200), blurRadius: 8),
                            ],
                          ),
                          child: const Icon(Icons.navigation_rounded, color: Colors.white, size: 14),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
          Positioned(
            bottom: 4,
            left: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.black.withAlpha(200),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                'MAP LIVE',
                style: TextStyle(color: Color(0xFF00F0FF), fontSize: 8, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TrianglePainter extends CustomPainter {
  final Color color;
  _TrianglePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final path = Path();
    path.moveTo(0, 0);
    path.lineTo(size.width, 0);
    path.lineTo(size.width / 2, size.height);
    path.close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
