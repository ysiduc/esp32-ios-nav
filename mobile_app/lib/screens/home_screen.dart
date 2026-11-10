import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/route_model.dart';
import '../services/ble_service.dart';
import '../services/navigation_manager.dart';
import '../services/saved_places_service.dart';
import '../widgets/map_provider_settings_sheet.dart';
import 'ble_screen.dart';
import 'esp_preview_screen.dart';
import 'esp_simulator_screen.dart';
import 'map_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey<MapScreenState> _mapKey = GlobalKey<MapScreenState>();
  final SavedPlacesService _savedPlacesService = SavedPlacesService();
  int _currentIndex = 0;

  void _switchToMap() {
    setState(() => _currentIndex = 0);
    try {
      final ble = context.read<BleService>();
      if (ble.isConnected) {
        ble.sendRawJson(jsonEncode({'type': 'RESTORE_IDLE_MAP'}));
      }
    } catch (_) {}
  }

  void _handleSelectSavedPlace(MapPlace place, {bool autoRoute = false}) {
    _switchToMap();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _mapKey.currentState?.selectSavedPlace(place, autoRoute: autoRoute);
    });
  }

  @override
  Widget build(BuildContext context) {
    final bleService = context.watch<BleService>();
    final navManager = context.watch<NavigationManager>();

    final screens = [
      MapScreen(
        key: _mapKey,
        onOpenMenu: () => _scaffoldKey.currentState?.openDrawer(),
      ),
      BleScreen(
        onBackToMap: _switchToMap,
      ),
      EspSimulatorScreen(
        onBackToMap: _switchToMap,
      ),
      EspPreviewScreen(
        onBackToMap: _switchToMap,
      ),
    ];

    return Scaffold(
      key: _scaffoldKey,
      drawerEnableOpenDragGesture: _currentIndex == 0 && !navManager.isNavigating,
      drawer: _buildIosAppDrawer(context, bleService, navManager),
      body: IndexedStack(
        index: _currentIndex,
        children: screens,
      ),
    );
  }

  Widget _buildIosAppDrawer(
    BuildContext context,
    BleService bleService,
    NavigationManager navManager,
  ) {
    final isBle = bleService.isConnected;
    final isWifi = bleService.isWifiConnected;
    final isBusy = bleService.isConnecting || bleService.isScanning;

    return Drawer(
      width: 318,
      backgroundColor: const Color(0xFFF2F2F7),
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(right: Radius.circular(28)),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ─── 1. App Brand & Quick Connection Header Card ───
            Container(
              margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(22),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 14,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF007AFF), Color(0xFF00C6FF)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(14),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF007AFF).withValues(alpha: 0.3),
                              blurRadius: 8,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: const Icon(Icons.navigation_rounded, color: Colors.white, size: 26),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'ysiducnaga',
                              style: TextStyle(
                                color: Color(0xFF1C1C1E),
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.4,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              'Smart HUD • Goong & Apple Maps',
                              style: TextStyle(
                                color: Color(0xFF8E8E93),
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // Quick BLE Connection Pill inside Header
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: isBle
                          ? const Color(0xFF34C759).withValues(alpha: 0.10)
                          : const Color(0xFFF2F2F7),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: isBle
                            ? const Color(0xFF34C759).withValues(alpha: 0.35)
                            : Colors.black.withValues(alpha: 0.05),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          isBle ? Icons.bluetooth_connected_rounded : Icons.bluetooth_rounded,
                          color: isBle ? const Color(0xFF34C759) : const Color(0xFF007AFF),
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                isBle
                                    ? (bleService.connectedDeviceName ?? 'ysiducnaga')
                                    : (isBusy ? 'Đang tìm ysiducnaga...' : 'Chưa kết nối ysiducnaga'),
                                style: TextStyle(
                                  color: isBle ? const Color(0xFF1C1C1E) : const Color(0xFF3A3A3C),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                isBle
                                    ? (isWifi ? 'BLE + Wi-Fi Stream (${bleService.wifiIp})' : 'Đã kết nối BLE trực tiếp')
                                    : 'Bấm Kết nối để đồng bộ màn hình HUD',
                                style: const TextStyle(
                                  color: Color(0xFF8E8E93),
                                  fontSize: 11,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        GestureDetector(
                          onTap: () async {
                            if (isBle) {
                              Navigator.pop(context);
                              setState(() => _currentIndex = 1);
                            } else if (!isBusy) {
                              await bleService.quickConnectToYsiducnaga();
                            }
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: isBle ? const Color(0xFF34C759) : const Color(0xFF007AFF),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              isBle ? 'Chi tiết' : (isBusy ? 'Đang quét' : 'Kết nối'),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11.5,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // ─── 2. Scrollable Menu Groups ───
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                children: [
                  _buildSectionHeader('ĐIỀU HƯỚNG & TIỆN ÍCH'),
                  Container(
                    decoration: _iosGroupCardDecoration(),
                    child: Column(
                      children: [
                        _buildIosMenuTile(
                          icon: Icons.map_rounded,
                          iconBg: const Color(0xFF007AFF),
                          title: 'Bản đồ dẫn đường',
                          subtitle: 'Goong Tìm kiếm • Apple Maps Realtime',
                          isSelected: _currentIndex == 0,
                          onTap: () {
                            Navigator.pop(context);
                            _switchToMap();
                          },
                        ),
                        const Divider(height: 1, indent: 58, color: Color(0xFFE5E5EA)),
                        AnimatedBuilder(
                          animation: _savedPlacesService,
                          builder: (context, _) {
                            final count = _savedPlacesService.savedPlaces.length;
                            return _buildIosMenuTile(
                              icon: Icons.bookmark_rounded,
                              iconBg: const Color(0xFFFF9500),
                              title: 'Địa điểm đã lưu',
                              subtitle: count > 0
                                  ? '$count địa điểm yêu thích (Nhà riêng, Công ty...)'
                                  : 'Lưu các điểm đến thường xuyên của bạn',
                              badgeText: count > 0 ? '$count' : null,
                              onTap: () {
                                Navigator.pop(context);
                                showSavedPlacesSheet(
                                  context,
                                  onSelectPlace: _handleSelectSavedPlace,
                                );
                              },
                            );
                          },
                        ),
                        const Divider(height: 1, indent: 58, color: Color(0xFFE5E5EA)),
                        // Voice Guidance Toggle Row + Test Button
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          child: Row(
                            children: [
                              Container(
                                width: 34,
                                height: 34,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF34C759),
                                  borderRadius: BorderRadius.circular(9),
                                ),
                                child: const Icon(Icons.record_voice_over_rounded, color: Colors.white, size: 19),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Đọc chỉ dẫn đường',
                                      style: TextStyle(
                                        color: Color(0xFF1C1C1E),
                                        fontWeight: FontWeight.w600,
                                        fontSize: 14.5,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    GestureDetector(
                                      onTap: () => navManager.testVoiceGuidance(),
                                      child: const Text(
                                        'Giọng đọc Tiếng Việt • Bấm để nghe thử 🔊',
                                        style: TextStyle(
                                          color: Color(0xFF007AFF),
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              CupertinoSwitch(
                                value: navManager.isVoiceEnabled,
                                activeTrackColor: const Color(0xFF34C759),
                                onChanged: (val) {
                                  navManager.setVoiceEnabled(val);
                                  if (val) {
                                    navManager.testVoiceGuidance();
                                  }
                                },
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 18),
                  _buildSectionHeader('THIẾT BỊ MÀN HÌNH (YSIDUCNAGA)'),
                  Container(
                    decoration: _iosGroupCardDecoration(),
                    child: Column(
                      children: [
                        _buildIosMenuTile(
                          icon: Icons.bluetooth_searching_rounded,
                          iconBg: const Color(0xFF007AFF),
                          title: 'Kết nối ysiducnaga',
                          subtitle: 'Quét Bluetooth BLE, ghép đôi thông báo & Wi-Fi',
                          isSelected: _currentIndex == 1,
                          statusDotColor: isBle ? const Color(0xFF34C759) : null,
                          onTap: () {
                            Navigator.pop(context);
                            setState(() => _currentIndex = 1);
                          },
                        ),
                        const Divider(height: 1, indent: 58, color: Color(0xFFE5E5EA)),
                        _buildIosMenuTile(
                          icon: Icons.watch_rounded,
                          iconBg: const Color(0xFF5856D6),
                          title: 'Giao diện Màn chờ (6 Themes)',
                          subtitle: 'Đổi mặt đồng hồ & tải ảnh nền cá nhân lên ESP32',
                          isSelected: _currentIndex == 2,
                          onTap: () {
                            Navigator.pop(context);
                            setState(() => _currentIndex = 2);
                          },
                        ),
                        const Divider(height: 1, indent: 58, color: Color(0xFFE5E5EA)),
                        _buildIosMenuTile(
                          icon: Icons.cast_connected_rounded,
                          iconBg: const Color(0xFFFF2D55),
                          title: 'Trạng thái Stream & Test HUD',
                          subtitle: 'Xem trước khung hình 30 FPS & test cuộc gọi/SMS',
                          isSelected: _currentIndex == 3,
                          onTap: () {
                            Navigator.pop(context);
                            setState(() => _currentIndex = 3);
                          },
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 18),
                  _buildSectionHeader('CÀI ĐẶT HỆ THỐNG'),
                  Container(
                    decoration: _iosGroupCardDecoration(),
                    child: Column(
                      children: [
                        _buildIosMenuTile(
                          icon: Icons.alt_route_rounded,
                          iconBg: const Color(0xFF00C7BE),
                          title: 'Dịch vụ Bản đồ & Lộ trình',
                          subtitle: 'Goong Tìm kiếm + Apple Maps Dẫn đường',
                          isSelected: false,
                          onTap: () {
                            Navigator.pop(context);
                            showMapProviderSettingsSheet(context);
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  BoxDecoration _iosGroupCardDecoration() {
    return BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.04),
          blurRadius: 10,
          offset: const Offset(0, 2),
        ),
      ],
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 12, bottom: 6),
      child: Text(
        title,
        style: const TextStyle(
          color: Color(0xFF8E8E93),
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }

  Widget _buildIosMenuTile({
    required IconData icon,
    required Color iconBg,
    required String title,
    required String subtitle,
    bool isSelected = false,
    String? badgeText,
    Color? statusDotColor,
    required VoidCallback onTap,
  }) {
    return Material(
      color: isSelected ? const Color(0xFF007AFF).withValues(alpha: 0.08) : Colors.transparent,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: iconBg,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, color: Colors.white, size: 19),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: isSelected ? const Color(0xFF007AFF) : const Color(0xFF1C1C1E),
                        fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
                        fontSize: 14.5,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Color(0xFF8E8E93),
                        fontSize: 11.5,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (badgeText != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  margin: const EdgeInsets.only(right: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF9500).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    badgeText,
                    style: const TextStyle(
                      color: Color(0xFFFF9500),
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
              if (statusDotColor != null)
                Container(
                  width: 9,
                  height: 9,
                  margin: const EdgeInsets.only(right: 6),
                  decoration: BoxDecoration(
                    color: statusDotColor,
                    shape: BoxShape.circle,
                  ),
                ),
              const Icon(Icons.chevron_right_rounded, color: Color(0xFFC7C7CC), size: 20),
            ],
          ),
        ),
      ),
    );
  }
}
