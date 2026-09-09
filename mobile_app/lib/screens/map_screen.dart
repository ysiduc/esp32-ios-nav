import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../models/route_model.dart';
import '../services/ble_service.dart';
import '../services/navigation_manager.dart';
import '../services/osrm_service.dart';
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
  final OsrmService _osrmService = OsrmService();
  final TextEditingController _searchController = TextEditingController();

  LatLng _center = const LatLng(10.7769, 106.7009); // Ho Chi Minh City
  LatLng? _destinationPoint;
  String? _destinationName;
  NavRoute? _calculatedRoute;
  List<MapPlace> _searchResults = [];
  Timer? _debounceTimer;

  // 6 Official Basemap Layers from iD / OpenFreeMap Ecosystem (100% Free, NO API Keys)
  int _selectedStyleIndex = 1; // Default: Street Map
  final List<Map<String, dynamic>> _idMapStyles = [
    {
      'id': 'light',
      'name': 'Light Canvas',
      'desc': 'Bản đồ xám sáng tối giản (Esri Light)',
      'url': 'https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Light_Gray_Base/MapServer/tile/{z}/{y}/{x}',
      'icon': Icons.light_mode_outlined,
    },
    {
      'id': 'street',
      'name': 'Street Map',
      'desc': 'Bản đồ đường phố chi tiết (Esri Street)',
      'url': 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Street_Map/MapServer/tile/{z}/{y}/{x}',
      'icon': Icons.alt_route_rounded,
    },
    {
      'id': 'osm_hot',
      'name': 'OSM Liberty',
      'desc': 'Bản đồ OpenStreetMap Humanitarian độ tương phản cao',
      'url': 'https://a.tile.openstreetmap.fr/hot/{z}/{x}/{y}.png',
      'icon': Icons.explore_rounded,
    },
    {
      'id': 'dark',
      'name': 'Dark Canvas',
      'desc': 'Giao diện đêm huyền ảo (Esri Dark Gray)',
      'url': 'https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Dark_Gray_Base/MapServer/tile/{z}/{y}/{x}',
      'icon': Icons.dark_mode_rounded,
    },
    {
      'id': 'satellite',
      'name': 'Vệ Tinh HD',
      'desc': 'Ảnh chụp vệ tinh siêu nét toàn cầu (Esri World Imagery)',
      'url': 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
      'icon': Icons.satellite_alt_rounded,
    },
    {
      'id': '3d_topo',
      'name': '3D Topo',
      'desc': 'Bản đồ địa hình đồi núi & độ cao (OpenTopoMap)',
      'url': 'https://tile.opentopomap.org/{z}/{x}/{y}.png',
      'icon': Icons.landscape_rounded,
    },
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final navManager = Provider.of<NavigationManager>(context, listen: false);
      if (navManager.currentLocation != null) {
        _center = navManager.currentLocation!;
        _mapController.move(_center, 15.0);
      }
    });
  }

  void _switchMapStyle(int index) {
    setState(() {
      _selectedStyleIndex = index;
    });
  }

  // Fast Typo-Tolerant Search powered by Photon (Komoot)
  void _onSearchChanged(String query) {
    _debounceTimer?.cancel();
    if (query.trim().isEmpty) {
      setState(() => _searchResults = []);
      return;
    }

    _debounceTimer = Timer(const Duration(milliseconds: 300), () async {
      final navManager = Provider.of<NavigationManager>(context, listen: false);
      // 1. Try Photon first (fastest autocomplete)
      var results = await _photonService.searchPlaces(query, nearLocation: navManager.currentLocation);
      // 2. Fallback to Nominatim if needed
      if (results.isEmpty) {
        results = await _osrmService.searchPlaces(query, nearLocation: navManager.currentLocation);
      }
      if (mounted) {
        setState(() => _searchResults = results);
      }
    });
  }

  Future<void> _selectPlace(MapPlace place) async {
    setState(() {
      _searchResults = [];
      _destinationPoint = place.coordinate;
      _destinationName = place.name;
      _searchController.text = place.name;
    });
    FocusScope.of(context).unfocus();

    _mapController.move(place.coordinate, 15.0);
    await _buildRouteToDestination();
  }

  Future<void> _onMapTap(TapPosition tapPosition, LatLng point) async {
    final navManager = Provider.of<NavigationManager>(context, listen: false);
    if (navManager.isNavigating) return;

    setState(() {
      _destinationPoint = point;
      _destinationName = 'Vị trí đã chọn';
      _searchResults = [];
    });

    final address = await _photonService.reverseGeocode(point);
    if (mounted && _destinationPoint == point) {
      setState(() {
        _destinationName = address;
        _searchController.text = _destinationName!;
      });
    }

    await _buildRouteToDestination();
  }

  // Turn-by-Turn Route Calculation powered by Valhalla with OSRM fallback
  Future<void> _buildRouteToDestination() async {
    if (_destinationPoint == null) return;
    final navManager = Provider.of<NavigationManager>(context, listen: false);
    final start = navManager.currentLocation ?? _center;

    // 1. Try Valhalla (supports dynamic costing, rich lane maneuvers)
    var route = await _valhallaService.calculateRoute(start, _destinationPoint!);
    // 2. Fallback to OSRM if Valhalla is unavailable
    route ??= await _osrmService.calculateRoute(start, _destinationPoint!);

    if (mounted) {
      setState(() {
        _calculatedRoute = route;
      });

      if (route != null) {
        _fitRouteBounds(route.polylinePoints);
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

    final bounds = LatLngBounds(
      LatLng(minLat, minLng),
      LatLng(maxLat, maxLng),
    );
    _mapController.fitCamera(
      CameraFit.bounds(
        bounds: bounds,
        padding: const EdgeInsets.only(top: 180, bottom: 240, left: 40, right: 40),
      ),
    );
  }

  void _recenterOnUser() {
    final navManager = Provider.of<NavigationManager>(context, listen: false);
    if (navManager.currentLocation != null) {
      _mapController.move(navManager.currentLocation!, 16.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final navManager = context.watch<NavigationManager>();
    final bleService = context.watch<BleService>();
    final isNavigating = navManager.isNavigating;
    final userPos = navManager.currentLocation ?? _center;
    final currentStyle = _idMapStyles[_selectedStyleIndex];

    return Scaffold(
      body: Stack(
        children: [
          // 1. Map Layer
          FlutterMap(
            key: ValueKey('map_${currentStyle['id']}'),
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _center,
              initialZoom: 15.0,
              onTap: _onMapTap,
            ),
            children: [
              TileLayer(
                urlTemplate: currentStyle['url'] as String,
                userAgentPackageName: 'com.esp32nav.app',
                maxZoom: 19,
              ),

              // Polyline Route Layer
              if (_calculatedRoute != null)
                PolylineLayer(
                  polylines: [
                    // Outer neon border
                    Polyline(
                      points: _calculatedRoute!.polylinePoints,
                      strokeWidth: 8.0,
                      color: const Color(0xFF0077B6).withAlpha(150),
                    ),
                    // Inner bright electric line
                    Polyline(
                      points: _calculatedRoute!.polylinePoints,
                      strokeWidth: 5.0,
                      color: const Color(0xFF00F0FF),
                    ),
                  ],
                ),

              // Marker Layer (GPS Puck + Destination Marker)
              MarkerLayer(
                markers: [
                  // User Location Puck
                  Marker(
                    point: userPos,
                    width: 44,
                    height: 44,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFF00F0FF).withAlpha(70),
                          ),
                        ),
                        Transform.rotate(
                          angle: (navManager.currentHeading * (3.1415926535 / 180.0)),
                          child: const Icon(Icons.navigation, color: Color(0xFF00F0FF), size: 26),
                        ),
                      ],
                    ),
                  ),

                  // Destination Pin
                  if (_destinationPoint != null)
                    Marker(
                      point: _destinationPoint!,
                      width: 42,
                      height: 42,
                      child: const Icon(Icons.location_on, color: Color(0xFFFF2A6D), size: 40),
                    ),
                ],
              ),
            ],
          ),

          // 2. Top Search Bar (Photon) & Style Selector
          if (!isNavigating)
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Search Bar
                    Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF161B22).withAlpha(240),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withAlpha(100),
                            blurRadius: 15,
                            offset: const Offset(0, 5),
                          ),
                        ],
                        border: Border.all(color: Colors.white12),
                      ),
                      child: TextField(
                        controller: _searchController,
                        style: const TextStyle(color: Colors.white, fontSize: 15),
                        onChanged: _onSearchChanged,
                        decoration: InputDecoration(
                          hintText: 'Tìm kiếm Photon (tự sửa lỗi chính tả)...',
                          hintStyle: const TextStyle(color: Colors.white54),
                          prefixIcon: const Icon(Icons.search, color: Color(0xFF00F0FF)),
                          suffixIcon: _searchController.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear, color: Colors.white54),
                                  onPressed: () {
                                    _searchController.clear();
                                    setState(() {
                                      _searchResults = [];
                                      _destinationPoint = null;
                                      _calculatedRoute = null;
                                    });
                                  },
                                )
                              : null,
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),

                    const SizedBox(height: 8),

                    // 6-Style Selector Horizontal Bar
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFF161B22).withAlpha(235),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: Colors.white12),
                        boxShadow: [
                          BoxShadow(color: Colors.black.withAlpha(80), blurRadius: 10, offset: const Offset(0, 3)),
                        ],
                      ),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: List.generate(_idMapStyles.length, (idx) {
                            final style = _idMapStyles[idx];
                            final isSelected = _selectedStyleIndex == idx;

                            return Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 3.0),
                              child: InkWell(
                                onTap: () => _switchMapStyle(idx),
                                borderRadius: BorderRadius.circular(18),
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 200),
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                                  decoration: BoxDecoration(
                                    color: isSelected ? const Color(0xFF00F0FF) : const Color(0xFF21262D),
                                    borderRadius: BorderRadius.circular(18),
                                    boxShadow: isSelected
                                        ? [
                                            BoxShadow(
                                              color: const Color(0xFF00F0FF).withAlpha(80),
                                              blurRadius: 8,
                                              offset: const Offset(0, 2),
                                            ),
                                          ]
                                        : null,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        style['icon'] as IconData,
                                        size: 14,
                                        color: isSelected ? Colors.black : Colors.white70,
                                      ),
                                      const SizedBox(width: 5),
                                      Text(
                                        style['name'] as String,
                                        style: TextStyle(
                                          color: isSelected ? Colors.black : Colors.white,
                                          fontSize: 12,
                                          fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          }),
                        ),
                      ),
                    ),

                    // Search Results Autocomplete Dropdown
                    if (_searchResults.isNotEmpty)
                      Container(
                        margin: const EdgeInsets.only(top: 8),
                        constraints: const BoxConstraints(maxHeight: 260),
                        decoration: BoxDecoration(
                          color: const Color(0xFF161B22).withAlpha(250),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.white12),
                        ),
                        child: ListView.separated(
                          shrinkWrap: true,
                          padding: EdgeInsets.zero,
                          itemCount: _searchResults.length,
                          separatorBuilder: (ctx, idx) => const Divider(color: Colors.white10, height: 1),
                          itemBuilder: (context, index) {
                            final place = _searchResults[index];
                            return ListTile(
                              leading: const Icon(Icons.location_on_outlined, color: Color(0xFF00F0FF)),
                              title: Text(
                                place.name,
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                place.displayName,
                                style: const TextStyle(color: Colors.white54, fontSize: 12),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: () => _selectPlace(place),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ),

          // 3. Floating Action Buttons (Right side)
          Positioned(
            right: 16,
            bottom: isNavigating ? 180 : 200,
            child: Column(
              children: [
                // BLE Connection Status Floating Badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF161B22).withAlpha(230),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: bleService.isConnected ? const Color(0xFF05FFA1) : Colors.white24,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: bleService.isConnected ? const Color(0xFF05FFA1) : Colors.redAccent,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        bleService.isConnected ? 'ESP32 Sẵn sàng' : 'Chưa nối ESP32',
                        style: TextStyle(
                          color: bleService.isConnected ? const Color(0xFF05FFA1) : Colors.white70,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),

                // Map Style Switcher Quick FAB
                FloatingActionButton.small(
                  heroTag: 'style_fab',
                  backgroundColor: const Color(0xFF161B22),
                  foregroundColor: const Color(0xFF00F0FF),
                  tooltip: 'Đổi kiểu bản đồ',
                  onPressed: () {
                    _switchMapStyle((_selectedStyleIndex + 1) % _idMapStyles.length);
                  },
                  child: const Icon(Icons.layers_rounded),
                ),
                const SizedBox(height: 10),

                // Recenter My Location FAB
                FloatingActionButton.small(
                  heroTag: 'location_fab',
                  backgroundColor: const Color(0xFF00F0FF),
                  foregroundColor: Colors.black,
                  tooltip: 'Về vị trí hiện tại',
                  onPressed: _recenterOnUser,
                  child: const Icon(Icons.my_location),
                ),
              ],
            ),
          ),

          // 4. Active Turn-by-Turn Navigation HUD (When Navigating)
          if (isNavigating)
            SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                  child: _buildNavigationHud(navManager),
                ),
              ),
            ),

          // 5. Bottom Route Preview Card (When route selected but not navigating)
          if (!isNavigating && _calculatedRoute != null)
            Align(
              alignment: Alignment.bottomCenter,
              child: _buildRoutePreviewSheet(navManager),
            ),
        ],
      ),
    );
  }

  /// Active Navigation Turn HUD Top Card
  Widget _buildNavigationHud(NavigationManager navManager) {
    final step = navManager.currentStep;
    final turnIcon = step?.icon ?? Icons.arrow_upward;
    final dist = navManager.distanceToNextManeuver.round();
    final street = step?.streetName ?? 'Tiếp tục đi thẳng';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF0D1117).withAlpha(240),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF00F0FF).withAlpha(100), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF00F0FF).withAlpha(40),
            blurRadius: 20,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              // Large Direction Icon
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: const Color(0xFF00F0FF).withAlpha(40),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(turnIcon, color: const Color(0xFF00F0FF), size: 38),
              ),
              const SizedBox(width: 16),

              // Distance & Next Street
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          dist >= 1000 ? '${(dist / 1000).toStringAsFixed(1)} km' : '$dist m',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 26,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                          ),
                        ),
                        const Spacer(),
                        if (navManager.isSimulating)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFB800).withAlpha(50),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Text(
                              'MÔ PHỎNG',
                              style: TextStyle(color: Color(0xFFFFB800), fontSize: 10, fontWeight: FontWeight.bold),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      street,
                      style: const TextStyle(color: Colors.white70, fontSize: 15, fontWeight: FontWeight.w500),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),
          const Divider(color: Colors.white12, height: 1),
          const SizedBox(height: 10),

          // Stats Bar: Speed | ETA | Total Remaining Dist | Exit
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildStatItem('Tốc độ', '${navManager.currentSpeedKmh.round()} km/h', const Color(0xFF05FFA1)),
              _buildStatItem('Còn lại', '${(navManager.remainingTotalDistance / 1000).toStringAsFixed(1)} km', Colors.white),
              _buildStatItem('Dự kiến', '${navManager.remainingEtaMinutes} phút', const Color(0xFF00F0FF)),

              IconButton(
                icon: const Icon(Icons.close, color: Colors.redAccent),
                tooltip: 'Dừng điều hướng',
                onPressed: () => navManager.stopNavigation(),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(String label, String value, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 11)),
        Text(
          value,
          style: TextStyle(color: color, fontSize: 14, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }

  /// Bottom Sheet Preview for Route
  Widget _buildRoutePreviewSheet(NavigationManager navManager) {
    final route = _calculatedRoute!;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border.all(color: Colors.white12),
        boxShadow: [
          BoxShadow(color: Colors.black.withAlpha(120), blurRadius: 25, offset: const Offset(0, -5)),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _destinationName ?? 'Điểm đến đã chọn',
                        style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${route.formattedDistance} • ${route.formattedDuration}',
                        style: const TextStyle(color: Color(0xFF00F0FF), fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white54),
                  onPressed: () {
                    setState(() {
                      _calculatedRoute = null;
                      _destinationPoint = null;
                    });
                  },
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Action Buttons: Start Navigation & Simulate
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00F0FF),
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    icon: const Icon(Icons.navigation_rounded, color: Colors.black),
                    label: const Text('Bắt đầu điều hướng', style: TextStyle(fontWeight: FontWeight.bold)),
                    onPressed: () {
                      navManager.startNavigation(route);
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 1,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFFFB800),
                      side: const BorderSide(color: Color(0xFFFFB800)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    icon: const Icon(Icons.play_circle_outline, size: 20),
                    label: const Text('Mô phỏng', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                    onPressed: () {
                      navManager.startSimulation(route);
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
