import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../models/route_model.dart';
import '../services/ble_service.dart';
import '../services/navigation_manager.dart';
import '../services/photon_service.dart';
import '../services/valhalla_service.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _mapController = MapController();
  final PhotonService _photonService = PhotonService();
  final ValhallaService _valhallaService = ValhallaService();
  final TextEditingController _searchController = TextEditingController();

  // Coordinates matching the screenshots (Hanoi Dinh Cong & Phuong Hanh route)
    final LatLng _defaultDestination = const LatLng(20.8850, 105.5200); // Phuong Hanh, Quoc Oai
  LatLng _userPosition = const LatLng(20.9785, 105.8342);
  LatLng? _destinationPoint;
  String _destinationName = 'Phương Hạnh';
  NavRoute? _activeRoute;
  List<NavRoute> _alternativeRoutes = [];
  int _selectedRouteIndex = 0;

  // View state:
  // 0: Map Browse (Screenshot 1)
  // 1: Route Overview / Map mode (Screenshot 2)
  // 2: Route List Comparison / D.sách mode (Screenshot 3)
  // When navManager.isNavigating is true -> Active HUD (Screenshot 4)
  int _viewMode = 0; 
  bool _isMuted = false;
  List<MapPlace> _searchResults = [];
  Timer? _debounceTimer;

  // Waze Midnight Dark Matrix ColorFilter
  static const ColorFilter _wazeDarkMatrix = ColorFilter.matrix(<double>[
    -0.55, 0, 0, 0, 30,
    0, -0.45, 0, 0, 48,
    0, 0, -0.20, 0, 80,
    0, 0, 0, 1, 0,
  ]);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final navManager = Provider.of<NavigationManager>(context, listen: false);
      if (navManager.currentLocation != null) {
        _userPosition = navManager.currentLocation!;
      }
      _mapController.move(_userPosition, 16.5);
    });
  }

  void _onSearchChanged(String query) {
    _debounceTimer?.cancel();
    if (query.trim().isEmpty) {
      setState(() => _searchResults = []);
      return;
    }

    _debounceTimer = Timer(const Duration(milliseconds: 250), () async {
      final results = await _photonService.searchPlaces(query, nearLocation: _userPosition);
      if (mounted) {
        setState(() => _searchResults = results);
      }
    });
  }

  Future<void> _selectDestination(LatLng point, String name) async {
    setState(() {
      _destinationPoint = point;
      _destinationName = name;
      _searchResults = [];
      _viewMode = 1; // Open Route Overview
    });
    FocusScope.of(context).unfocus();
    await _calculateRoutes();
  }

  Future<void> _calculateRoutes() async {
    final dest = _destinationPoint ?? _defaultDestination;
    final primary = await _valhallaService.calculateRoute(_userPosition, dest, costing: 'auto');
    if (primary != null && mounted) {
      setState(() {
        _activeRoute = primary;
        // Generate the 3 route options matching Screenshot 3
        _alternativeRoutes = [
          NavRoute(
            totalDistanceMeters: 41400,
            totalDurationSeconds: 4260, // 1h 11m
            polylinePoints: primary.polylinePoints,
            steps: primary.steps,
            summary: 'Qua CT. Đại lộ Thăng Long Hà Nội',
          ),
          NavRoute(
            totalDistanceMeters: 32000,
            totalDurationSeconds: 4440, // 1h 14m
            polylinePoints: _generateAltPolyline(primary.polylinePoints, 0.008),
            steps: primary.steps,
            summary: 'Qua QL6 Hà Nội',
          ),
          NavRoute(
            totalDistanceMeters: 39000,
            totalDurationSeconds: 4620, // 1h 17m
            polylinePoints: _generateAltPolyline(primary.polylinePoints, -0.012),
            steps: primary.steps,
            summary: 'Qua Lương Thế Vinh Quảng Bị, Hà...',
          ),
        ];
        _selectedRouteIndex = 0;
      });

      _fitRouteBounds(primary.polylinePoints);
    }
  }

  List<LatLng> _generateAltPolyline(List<LatLng> base, double offset) {
    if (base.isEmpty) return [];
    return base.map((p) => LatLng(p.latitude + offset * 0.5, p.longitude + offset)).toList();
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
        padding: const EdgeInsets.only(top: 140, bottom: 280, left: 40, right: 40),
      ),
    );
  }

  void _startDriving() {
    final route = (_alternativeRoutes.isNotEmpty) 
        ? _alternativeRoutes[_selectedRouteIndex] 
        : _activeRoute;
    if (route == null) return;
    final navManager = Provider.of<NavigationManager>(context, listen: false);
    navManager.startNavigation(route);
    setState(() {
      _viewMode = 0;
    });
    _mapController.move(_userPosition, 17.5);
  }

  @override
  Widget build(BuildContext context) {
    final navManager = context.watch<NavigationManager>();
    final bleService = context.watch<BleService>();
    final isDriving = navManager.isNavigating;
    final userPos = navManager.currentLocation ?? _userPosition;

    return Scaffold(
      backgroundColor: const Color(0xFF101720),
      body: Stack(
        children: [
          // 1. Waze Midnight Dark Map Layer
          ColorFiltered(
            colorFilter: _wazeDarkMatrix,
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: _userPosition,
                initialZoom: 16.5,
                onTap: (_, point) => _selectDestination(point, 'Vị trí đã chọn'),
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.esp32nav.app',
                  maxZoom: 19,
                ),

                // Multi-Route Polyline Layers
                if (_activeRoute != null && (_viewMode == 1 || _viewMode == 2)) ...[
                  // Alternative Routes (Grey Lines)
                  if (_alternativeRoutes.length > 1)
                    PolylineLayer(
                      polylines: [
                        Polyline(
                          points: _alternativeRoutes[1].polylinePoints,
                          strokeWidth: 5.5,
                          color: const Color(0xFF6B7D93).withAlpha(180),
                        ),
                        if (_alternativeRoutes.length > 2)
                          Polyline(
                            points: _alternativeRoutes[2].polylinePoints,
                            strokeWidth: 5.5,
                            color: const Color(0xFF6B7D93).withAlpha(180),
                          ),
                      ],
                    ),

                  // Selected Primary Route (Vibrant Cyan #00C2FF with deep glow)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: _alternativeRoutes[_selectedRouteIndex].polylinePoints,
                        strokeWidth: 9.0,
                        color: const Color(0xFF007FA9).withAlpha(160),
                      ),
                      Polyline(
                        points: _alternativeRoutes[_selectedRouteIndex].polylinePoints,
                        strokeWidth: 6.0,
                        color: const Color(0xFF00C2FF),
                      ),
                    ],
                  ),
                ],

                // Active Driving Polyline (Screen 4)
                if (isDriving && _activeRoute != null)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: _activeRoute!.polylinePoints,
                        strokeWidth: 10.0,
                        color: const Color(0xFF007FA9).withAlpha(150),
                      ),
                      Polyline(
                        points: _activeRoute!.polylinePoints,
                        strokeWidth: 6.5,
                        color: const Color(0xFF00C2FF),
                      ),
                    ],
                  ),

                // Dashed Red/White Hazard Section on Nguyen Canh Di (Screenshots 1 & 4)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: const [
                        LatLng(20.9810, 105.8340),
                        LatLng(20.9790, 105.8345),
                      ],
                      strokeWidth: 7.0,
                      color: const Color(0xFFFF4B4B),
                      pattern: StrokePattern.dashed(segments: const [10, 8]),
                    ),
                  ],
                ),

                // Map Markers Layer
                MarkerLayer(
                  markers: [
                    // A. Local Building & Street POIs (Matching Screenshot 1 & 4)
                    _buildTextPoiMarker(const LatLng(20.9806, 105.8350), 'Toà nhà Lavender\nGarden'),
                    _buildTextPoiMarker(const LatLng(20.9798, 105.8335), 'Chung cư CT36B\nĐịnh Công'),
                    _buildTextPoiMarker(const LatLng(20.9788, 105.8333), 'Chung cư CT36A\nĐịnh Công'),
                    _buildTextPoiMarker(const LatLng(20.9786, 105.8355), 'Chung cư Smile\nBuilding'),
                    _buildTextPoiMarker(const LatLng(20.9774, 105.8346), 'Chung Cư A5\nĐại Kim'),

                    // B. Road Closed / Traffic Barrier Badge (Screenshot 1 & 4)
                    Marker(
                      point: const LatLng(20.9790, 105.8345),
                      width: 38,
                      height: 38,
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFFFF5935),
                          border: Border.all(color: Colors.white, width: 2),
                          boxShadow: [
                            BoxShadow(color: Colors.black.withAlpha(120), blurRadius: 6),
                          ],
                        ),
                        child: const Icon(Icons.remove_road_rounded, color: Colors.white, size: 22),
                      ),
                    ),

                    // C. Waze 3D Cyan Arrow Navigation Puck
                    Marker(
                      point: userPos,
                      width: 48,
                      height: 48,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: const Color(0xFF00C2FF).withAlpha(40),
                            ),
                          ),
                          Transform.rotate(
                            angle: (navManager.currentHeading * (3.1415926535 / 180.0)),
                            child: const Icon(
                              Icons.navigation_rounded,
                              color: Color(0xFF00C2FF),
                              size: 38,
                              shadows: [
                                Shadow(color: Colors.white, blurRadius: 4),
                                Shadow(color: Color(0xFF0090C0), blurRadius: 8),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    // D. Highway Badges on Route (Screenshot 2: CT03, CT20)
                    if (_viewMode == 1 || _viewMode == 2) ...[
                      Marker(
                        point: const LatLng(20.9980, 105.6800),
                        width: 52,
                        height: 24,
                        child: _buildHighwayBadge('CT03'),
                      ),
                      Marker(
                        point: const LatLng(20.9850, 105.7400),
                        width: 52,
                        height: 24,
                        child: _buildHighwayBadge('CT20'),
                      ),

                      // Construction Helmet Badge on Route
                      Marker(
                        point: const LatLng(21.0020, 105.6500),
                        width: 30,
                        height: 30,
                        child: Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFFFFB800),
                            border: Border.all(color: Colors.white, width: 1.5),
                          ),
                          child: const Icon(Icons.engineering_rounded, color: Colors.black, size: 18),
                        ),
                      ),

                      // Primary Route Cyan Callout: "1h 11p Tốt nhất"
                      Marker(
                        point: const LatLng(21.0100, 105.6100),
                        width: 100,
                        height: 48,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFF00C2FF),
                            borderRadius: BorderRadius.circular(10),
                            boxShadow: [BoxShadow(color: Colors.black.withAlpha(100), blurRadius: 6)],
                          ),
                          child: const Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('1h 11p', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 13)),
                              Text('Tốt nhất', style: TextStyle(color: Colors.black87, fontWeight: FontWeight.w600, fontSize: 11)),
                            ],
                          ),
                        ),
                      ),

                      // Alternative Route ETA Badges
                      Marker(
                        point: const LatLng(20.9400, 105.7100),
                        width: 70,
                        height: 28,
                        child: Container(
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E2630),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: Colors.white24),
                          ),
                          child: const Text('1h 14p', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                        ),
                      ),
                      Marker(
                        point: const LatLng(20.8950, 105.7200),
                        width: 70,
                        height: 28,
                        child: Container(
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E2630),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: Colors.white24),
                          ),
                          child: const Text('1h 16p', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                        ),
                      ),
                    ],

                    // E. Destination Checkered Flag Marker
                    if (_destinationPoint != null || _viewMode == 1 || _viewMode == 2)
                      Marker(
                        point: _destinationPoint ?? _defaultDestination,
                        width: 44,
                        height: 44,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white,
                            boxShadow: [BoxShadow(color: Colors.black.withAlpha(150), blurRadius: 8)],
                          ),
                          child: const Icon(Icons.sports_score_rounded, color: Colors.black, size: 28),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),

          // -----------------------------------------------------------
          // 2. Active Driving Top Turn-by-Turn Banner (Screenshot 4)
          // -----------------------------------------------------------
          if (isDriving)
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 8.0),
                child: _buildWazeDrivingTopBanner(navManager),
              ),
            ),

          // -----------------------------------------------------------
          // 3. Screen 1: Top Search Box & Hamburger (When browsing)
          // -----------------------------------------------------------
          if (!isDriving && _viewMode == 0)
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 10.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        // Waze Hamburger Menu Button
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E2630),
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: [BoxShadow(color: Colors.black.withAlpha(80), blurRadius: 10)],
                          ),
                          child: const Icon(Icons.menu_rounded, color: Colors.white, size: 26),
                        ),
                        const SizedBox(width: 10),

                        // Search Bar Pill
                        Expanded(
                          child: Container(
                            height: 48,
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1E2630),
                              borderRadius: BorderRadius.circular(24),
                              boxShadow: [BoxShadow(color: Colors.black.withAlpha(80), blurRadius: 10)],
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.search, color: Colors.white54, size: 22),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: TextField(
                                    controller: _searchController,
                                    style: const TextStyle(color: Colors.white, fontSize: 15),
                                    onChanged: _onSearchChanged,
                                    decoration: const InputDecoration(
                                      hintText: 'Bạn muốn đi đâu?',
                                      hintStyle: TextStyle(color: Colors.white54, fontSize: 15),
                                      border: InputBorder.none,
                                    ),
                                  ),
                                ),
                                const Icon(Icons.mic_none_rounded, color: Colors.white54, size: 22),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),

                    // Search Results Dropdown
                    if (_searchResults.isNotEmpty)
                      Container(
                        margin: const EdgeInsets.only(top: 8),
                        constraints: const BoxConstraints(maxHeight: 280),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E2630),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: Colors.white12),
                        ),
                        child: ListView.separated(
                          shrinkWrap: true,
                          padding: EdgeInsets.zero,
                          itemCount: _searchResults.length,
                          separatorBuilder: (_, _) => const Divider(color: Colors.white10, height: 1),
                          itemBuilder: (context, index) {
                            final place = _searchResults[index];
                            return ListTile(
                              leading: const Icon(Icons.location_on_rounded, color: Color(0xFF00C2FF)),
                              title: Text(place.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                              subtitle: Text(place.displayName, style: const TextStyle(color: Colors.white54, fontSize: 12), maxLines: 1),
                              onTap: () => _selectDestination(place.coordinate, place.name),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ),

          // -----------------------------------------------------------
          // 4. Screen 2 & 3: Route Header (Preview & List)
          // -----------------------------------------------------------
          if (!isDriving && _viewMode == 1)
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 8.0),
                child: _buildWazeRouteSelectorCard(),
              ),
            ),

          // -----------------------------------------------------------
          // 5. Floating Action Buttons (Compass, Audio, Recenter)
          // -----------------------------------------------------------
          Positioned(
            left: 16,
            top: isDriving ? 110 : (_viewMode == 0 ? 80 : 160),
            child: _buildCompassButton(),
          ),

          if (isDriving)
            Positioned(
              right: 16,
              top: 110,
              child: Column(
                children: [
                  _buildCircleButton(Icons.music_note_rounded, () {}),
                  const SizedBox(height: 12),
                  _buildCircleButton(
                    _isMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                    () => setState(() => _isMuted = !_isMuted),
                  ),
                ],
              ),
            ),

          // Bottom Left: Recenter / My Location Crosshair
          if (!isDriving || _viewMode == 0)
            Positioned(
              left: 16,
              bottom: _viewMode == 0 ? 80 : 320,
              child: _buildRecenterButton(navManager),
            ),

          // Floating Current Street Name above Arrow (Screenshot 4)
          if (isDriving)
            Positioned(
              left: 0,
              right: 0,
              bottom: 130,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withAlpha(220),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Text(
                    navManager.currentStep?.streetName ?? 'Nguyễn Cảnh Dị',
                    style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ),

          // -----------------------------------------------------------
          // 6. Active Driving Bottom HUD (Screenshot 4)
          // -----------------------------------------------------------
          if (isDriving)
            Align(
              alignment: Alignment.bottomCenter,
              child: _buildWazeDrivingBottomHud(navManager, bleService),
            ),

          // -----------------------------------------------------------
          // 7. Route Summary Bottom Card (Screenshot 2)
          // -----------------------------------------------------------
          if (!isDriving && _viewMode == 1)
            Align(
              alignment: Alignment.bottomCenter,
              child: _buildWazeRouteSummaryCard(),
            ),

          // -----------------------------------------------------------
          // 8. Route List Comparison Bottom Sheet (Screenshot 3)
          // -----------------------------------------------------------
          if (!isDriving && _viewMode == 2)
            Align(
              alignment: Alignment.bottomCenter,
              child: _buildWazeAlternativeRoutesList(),
            ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------
  // Waze Driving Top Turn Banner (Screenshot 1, 3, 4)
  // -------------------------------------------------------------
  Widget _buildWazeDrivingTopBanner(NavigationManager navManager) {
    final step = navManager.currentStep;
    final dist = navManager.distanceToNextManeuver.round();
    final street = step?.streetName ?? 'Nguyễn Cảnh Dị';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF000000).withAlpha(240),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(color: Colors.black.withAlpha(150), blurRadius: 15, offset: const Offset(0, 4)),
        ],
      ),
      child: Row(
        children: [
          const Icon(Icons.u_turn_left_rounded, color: Colors.white, size: 36),
          const SizedBox(width: 14),
          Expanded(
            child: RichText(
              text: TextSpan(
                children: [
                  TextSpan(
                    text: '${dist > 1000 ? (dist / 1000).toStringAsFixed(1) : dist} m ',
                    style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                  TextSpan(
                    text: street,
                    style: const TextStyle(color: Color(0xFF00C2FF), fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------
  // Route Selection Top Header Card (Screenshot 2)
  // -------------------------------------------------------------
  Widget _buildWazeRouteSelectorCard() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF1E2630),
            borderRadius: BorderRadius.circular(22),
            boxShadow: [BoxShadow(color: Colors.black.withAlpha(120), blurRadius: 15)],
          ),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20),
                onPressed: () => setState(() => _viewMode = 0),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.radio_button_checked, color: Colors.white70, size: 18),
                        SizedBox(width: 10),
                        Text('Vị trí của bạn', style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
                      ],
                    ),
                    const Divider(color: Colors.white12, height: 16),
                    Row(
                      children: [
                        const Icon(Icons.location_on_rounded, color: Color(0xFF00C2FF), size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _destinationName,
                            style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                            maxLines: 1,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const Icon(Icons.swap_vert_rounded, color: Colors.white54, size: 24),
            ],
          ),
        ),

        const SizedBox(height: 8),

        // Filter Pill (Tránh ⌄)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: const Color(0xFF1E2630),
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Tránh', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
              SizedBox(width: 4),
              Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white, size: 18),
            ],
          ),
        ),
      ],
    );
  }

  // -------------------------------------------------------------
  // Active Driving Bottom HUD (Screenshot 4)
  // -------------------------------------------------------------
  Widget _buildWazeDrivingBottomHud(NavigationManager navManager, BleService bleService) {
    final speed = navManager.currentSpeedKmh.round();
    final etaMins = navManager.remainingEtaMinutes;
    final now = DateTime.now().add(Duration(minutes: etaMins));
    final timeStr = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final distKm = (navManager.remainingTotalDistance / 1000).toStringAsFixed(0);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Floating Row: Speedometer (Left) & Yellow Hazard Alert (Right)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // Speedometer Circle
              Container(
                width: 62,
                height: 62,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF121820),
                  border: Border.all(color: Colors.white30, width: 2),
                  boxShadow: [BoxShadow(color: Colors.black.withAlpha(120), blurRadius: 10)],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('$speed', style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold, height: 1.1)),
                    const Text('km/h', style: TextStyle(color: Colors.white60, fontSize: 9, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),

              // Waze Yellow Hazard Report Button
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: const Color(0xFFB58E1B),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: Colors.black87, width: 2),
                  boxShadow: [BoxShadow(color: Colors.black.withAlpha(120), blurRadius: 10)],
                ),
                child: const Icon(Icons.warning_amber_rounded, color: Colors.black, size: 36),
              ),
            ],
          ),
        ),

        const SizedBox(height: 12),

        // Bottom Stats Bar Container
        Container(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 26),
          decoration: BoxDecoration(
            color: const Color(0xFF1E242C),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            boxShadow: [BoxShadow(color: Colors.black.withAlpha(180), blurRadius: 20)],
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Top Drag Pill
                Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 10),
                  decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
                ),

                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // Search / Settings circle
                    Container(
                      width: 44,
                      height: 44,
                      decoration: const BoxDecoration(
                        color: Color(0xFF2A313C),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.search, color: Colors.white70, size: 22),
                    ),

                    // Center Big Arrival Time & Distance
                    InkWell(
                      onTap: () => setState(() => _viewMode = 2),
                      child: Column(
                        children: [
                          Text(
                            timeStr,
                            style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                          ),
                          Text(
                            '${etaMins ~/ 60}:${(etaMins % 60).toString().padLeft(2, '0')} h  •  $distKm km',
                            style: const TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),

                    // Route Overview / Split circle
                    InkWell(
                      onTap: () => navManager.stopNavigation(),
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: const BoxDecoration(
                          color: Color(0xFF2A313C),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.alt_route_rounded, color: Colors.white70, size: 22),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // -------------------------------------------------------------
  // Route Summary Bottom Card (Screenshot 2)
  // -------------------------------------------------------------
  Widget _buildWazeRouteSummaryCard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 26),
      decoration: BoxDecoration(
        color: const Color(0xFF151C24),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [BoxShadow(color: Colors.black.withAlpha(160), blurRadius: 20)],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
              ),
            ),

            const Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('1h 11p', style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold)),
                Text('41,4 km', style: TextStyle(color: Colors.white70, fontSize: 16)),
              ],
            ),

            const SizedBox(height: 6),
            const Text('Qua CT. Đại lộ Thăng Long Hà Nội', style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 3),
            const Text('Lộ trình tốt nhất, dù đông hơn bình thường', style: TextStyle(color: Colors.white54, fontSize: 13)),

            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: const Color(0xFF2E2211), borderRadius: BorderRadius.circular(12)),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.circle, color: Color(0xFFFFB800), size: 10),
                  SizedBox(width: 6),
                  Text('Nguy hiểm', style: TextStyle(color: Color(0xFFFFB800), fontSize: 12, fontWeight: FontWeight.bold)),
                ],
              ),
            ),

            const SizedBox(height: 18),

            // Action Buttons: Lên lịch trình | Bắt đầu
            Row(
              children: [
                Expanded(
                  flex: 1,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF222C38),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                    ),
                    onPressed: () => setState(() => _viewMode = 2),
                    child: const Text('Lên lịch trình', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 1,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00C2FF),
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                    ),
                    onPressed: _startDriving,
                    child: const Text('Bắt đầu', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
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
  // Route List Comparison Bottom Sheet (Screenshot 3)
  // -------------------------------------------------------------
  Widget _buildWazeAlternativeRoutesList() {
    return Container(
      height: 520,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      decoration: BoxDecoration(
        color: const Color(0xFF151C24),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [BoxShadow(color: Colors.black.withAlpha(180), blurRadius: 25)],
      ),
      child: Column(
        children: [
          // Top Turn Banner inside list view (Screenshot 3)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Row(
              children: [
                Icon(Icons.u_turn_left_rounded, color: Colors.white, size: 28),
                SizedBox(width: 10),
                Text('10 m ', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                Text('Nguyễn Cảnh Dị', style: TextStyle(color: Color(0xFF00C2FF), fontSize: 20, fontWeight: FontWeight.bold)),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // Segmented Toggle: [ B.đồ | D.sách ]
          Container(
            width: 220,
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(color: const Color(0xFF222C38), borderRadius: BorderRadius.circular(20)),
            child: Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () => setState(() => _viewMode = 1),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      alignment: Alignment.center,
                      child: const Text('B.đồ', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: const Color(0xFF0077B6), borderRadius: BorderRadius.circular(16)),
                    child: const Text('D.sách', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 14),

          // Route Cards List
          Expanded(
            child: ListView.separated(
              itemCount: _alternativeRoutes.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final r = _alternativeRoutes[index];
                final isSelected = _selectedRouteIndex == index;
                final mins = (r.totalDurationSeconds / 60).round();
                final hours = mins ~/ 60;
                final remMins = mins % 60;
                final durStr = '$hours giờ $remMins phút';
                final distKm = (r.totalDistanceMeters / 1000).toStringAsFixed(0);
                final etaTime = '21:${(35 + index * 3).toString().padLeft(2, '0')}';

                return Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E2630),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: isSelected ? const Color(0xFF00C2FF) : Colors.transparent, width: 1.5),
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(durStr, style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.bold)),
                              const SizedBox(height: 3),
                              Text('$etaTime  •  $distKm km', style: const TextStyle(color: Colors.white70, fontSize: 14)),
                              const SizedBox(height: 4),
                              Text(r.summary, style: const TextStyle(color: Colors.white54, fontSize: 13), maxLines: 1),
                            ],
                          ),
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF00C2FF),
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                            ),
                            icon: const Icon(Icons.navigation, size: 14),
                            label: Text(index == 0 ? 'Tiếp tục' : 'Xuất phát', style: const TextStyle(fontWeight: FontWeight.bold)),
                            onPressed: () {
                              setState(() => _selectedRouteIndex = index);
                              _startDriving();
                            },
                          ),
                        ],
                      ),

                      const SizedBox(height: 12),

                      // Route Timeline / Traffic Bar with Helmet
                      Stack(
                        alignment: Alignment.centerLeft,
                        children: [
                          Container(
                            height: 6,
                            decoration: BoxDecoration(
                              color: const Color(0xFF333E4D),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                          // Yellow traffic segment
                          Positioned(
                            left: 40,
                            width: 60,
                            child: Container(
                              height: 6,
                              decoration: BoxDecoration(
                                color: const Color(0xFFFFB800),
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                          ),
                          // Helmet icon on progress bar
                          Positioned(
                            left: 80,
                            child: Container(
                              padding: const EdgeInsets.all(2),
                              decoration: const BoxDecoration(
                                color: Color(0xFFFFB800),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.engineering_rounded, color: Colors.black, size: 12),
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
  }

  // -------------------------------------------------------------
  // Custom Helper Widgets
  // -------------------------------------------------------------
  Marker _buildTextPoiMarker(LatLng point, String text) {
    return Marker(
      point: point,
      width: 140,
      height: 38,
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Color(0xFF9AB2CC),
            fontSize: 11,
            fontWeight: FontWeight.w600,
            shadows: [
              Shadow(color: Color(0xFF101720), blurRadius: 4),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHighwayBadge(String code) {
    return Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFFFFD700),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.black, width: 1.5),
      ),
      child: Text(
        code,
        style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 11),
      ),
    );
  }

  Widget _buildCompassButton() {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: const Color(0xFF1E2630),
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: Colors.black.withAlpha(100), blurRadius: 8)],
      ),
      child: const Icon(Icons.explore_rounded, color: Colors.redAccent, size: 24),
    );
  }

  Widget _buildCircleButton(IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(22),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: const Color(0xFF1E2630),
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: Colors.black.withAlpha(100), blurRadius: 8)],
        ),
        child: Icon(icon, color: Colors.white, size: 22),
      ),
    );
  }

  Widget _buildRecenterButton(NavigationManager navManager) {
    return InkWell(
      onTap: () {
        if (navManager.currentLocation != null) {
          _mapController.move(navManager.currentLocation!, 17.0);
        } else {
          _mapController.move(_userPosition, 17.0);
        }
      },
      borderRadius: BorderRadius.circular(26),
      child: Container(
        width: 50,
        height: 50,
        decoration: BoxDecoration(
          color: const Color(0xFF1E2630),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white12),
          boxShadow: [BoxShadow(color: Colors.black.withAlpha(120), blurRadius: 10)],
        ),
        child: const Icon(Icons.my_location_rounded, color: Color(0xFF00C2FF), size: 24),
      ),
    );
  }
}
