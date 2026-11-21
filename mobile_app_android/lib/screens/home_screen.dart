import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/route_model.dart';
import '../services/ble_service.dart';
import '../services/navigation_manager.dart';
import '../services/saved_places_service.dart';
import '../widgets/firmware_update_sheet.dart';
import '../widgets/map_provider_settings_sheet.dart';
import 'ble_screen.dart';
import 'esp_interface_screen.dart';
import 'map_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey<MapScreenState> _mapKey = GlobalKey<MapScreenState>();
  final SavedPlacesService _savedPlacesService = SavedPlacesService();
  int _currentIndex = 0;
  ({
    bool usingVietnamese,
    bool hasOfflineVietnamese,
    bool hasNetworkVietnamese,
    String engine,
    String voiceLocale,
    String diagnostic,
  })? _ttsStatus;
  bool _loggedTtsDiag = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshTtsStatus());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Refresh status shortly after resuming (e.g., returning from TTS voice download)
      Future.delayed(const Duration(milliseconds: 600), () {
        if (mounted) _refreshTtsStatus();
      });
    }
  }

  Future<void> _refreshTtsStatus({bool promptDialogIfMissing = false}) async {
    if (!mounted) return;
    final navManager = context.read<NavigationManager>();
    final bleService = context.read<BleService>();
    final st = await navManager.getTtsVoiceStatus();
    if (!mounted || st == null) return;
    setState(() => _ttsStatus = st);
    if (!_loggedTtsDiag && st.diagnostic.isNotEmpty) {
      _loggedTtsDiag = true;
      bleService.logInfo('TTS: ${st.diagnostic}');
    }
    if (promptDialogIfMissing && !st.usingVietnamese) {
      _showMissingVietnameseTtsDialog(navManager, st);
    }
  }

  void _showMissingVietnameseTtsDialog(
    NavigationManager navManager,
    ({
      bool usingVietnamese,
      bool hasOfflineVietnamese,
      bool hasNetworkVietnamese,
      String engine,
      String voiceLocale,
      String diagnostic,
    }) st,
  ) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        title: const Text(
          'Thiếu gói giọng Tiếng Việt (TTS)',
          style: TextStyle(color: Color(0xFF1C1C1E), fontWeight: FontWeight.w700, fontSize: 16.5),
        ),
        content: Text(
          'Máy đang dùng bộ đọc "${st.engine.isEmpty ? "mặc định" : st.engine}" '
          '(ngôn ngữ hiện tại: ${st.voiceLocale.isEmpty ? "chưa có vi-VN" : st.voiceLocale}), '
          'nên chữ Tiếng Việt bị đọc bằng giọng tiếng Anh.\n\n'
          'Hãy bấm "Tải giọng Tiếng Việt" để cài gói Tiếng Việt từ Google TTS (hoặc mở Cài đặt TTS để chuyển bộ đọc sang Dịch vụ giọng nói của Google).',
          style: const TextStyle(color: Color(0xFF3A3A3C), fontSize: 13.5, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              navManager.openSystemTtsSettings();
            },
            child: const Text('Cài đặt TTS'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF007AFF),
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              Navigator.pop(ctx);
              navManager.openVietnameseTtsInstaller();
            },
            child: const Text('Tải giọng Tiếng Việt'),
          ),
        ],
      ),
    );
  }

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
        onOpenMenu: () {
          _refreshTtsStatus();
          _scaffoldKey.currentState?.openDrawer();
        },
      ),
      BleScreen(
        onBackToMap: _switchToMap,
      ),
      EspInterfaceScreen(
        isActive: _currentIndex == 2,
        onBackToMap: _switchToMap,
      ),
    ];

    return Scaffold(
      key: _scaffoldKey,
      drawerEnableOpenDragGesture: _currentIndex == 0 && !navManager.isNavigating,
      onDrawerChanged: (isOpened) {
        if (isOpened) _refreshTtsStatus();
      },
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
                        width: 50,
                        height: 50,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.18),
                              blurRadius: 8,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: Image.asset(
                            'assets/themes/app_icon.png',
                            width: 50,
                            height: 50,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              color: const Color(0xFF007AFF),
                              child: const Icon(Icons.navigation_rounded, color: Colors.white, size: 26),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Hoa hướng dương',
                              style: TextStyle(
                                color: Color(0xFF1C1C1E),
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.4,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              'Smart HUD • Dẫn đường xe máy',
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
                                    ? (bleService.connectedDeviceName ?? 'Hoa hướng dương')
                                    : (isBusy ? 'Đang tìm Hoa hướng dương...' : 'Chưa kết nối Hoa hướng dương'),
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
                          subtitle: 'Tìm địa chỉ • Dẫn đường thời gian thực',
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
                                      onTap: () {
                                        navManager.testVoiceGuidance();
                                        _refreshTtsStatus(promptDialogIfMissing: true);
                                      },
                                      child: Text(
                                        _ttsStatus == null
                                            ? 'Giọng đọc Tiếng Việt • Bấm để nghe thử 🔊'
                                            : (_ttsStatus!.hasOfflineVietnamese
                                                ? 'Tiếng Việt offline (${_ttsStatus!.voiceLocale.isEmpty ? "vi-VN" : _ttsStatus!.voiceLocale}) • Nghe thử 🔊'
                                                : (_ttsStatus!.usingVietnamese
                                                    ? 'Tiếng Việt online (${_ttsStatus!.engine}) • Nghe thử 🔊'
                                                    : 'Thiếu gói giọng Tiếng Việt (${_ttsStatus!.engine.isEmpty ? "chưa cài" : _ttsStatus!.engine}) • Nghe thử 🔊')),
                                        style: TextStyle(
                                          color: (_ttsStatus != null && !_ttsStatus!.usingVietnamese)
                                              ? const Color(0xFFFF3B30)
                                              : (_ttsStatus != null && !_ttsStatus!.hasOfflineVietnamese
                                                  ? const Color(0xFFFF9500)
                                                  : const Color(0xFF007AFF)),
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                    if (_ttsStatus != null && !_ttsStatus!.hasOfflineVietnamese) ...[
                                      const SizedBox(height: 6),
                                      GestureDetector(
                                        onTap: () {
                                          navManager.openVietnameseTtsInstaller();
                                        },
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFFF9500).withValues(alpha: 0.14),
                                            borderRadius: BorderRadius.circular(8),
                                            border: Border.all(
                                              color: const Color(0xFFFF9500).withValues(alpha: 0.45),
                                            ),
                                          ),
                                          child: Text(
                                            _ttsStatus!.usingVietnamese
                                                ? 'Tải gói giọng Việt offline ⬇'
                                                : 'Cài đặt giọng Tiếng Việt ngay ⬇',
                                            style: const TextStyle(
                                              color: Color(0xFFB25000),
                                              fontSize: 11.5,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
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
                                  _refreshTtsStatus(promptDialogIfMissing: val);
                                },
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 18),
                  _buildSectionHeader('THIẾT BỊ MÀN HÌNH (HOA HƯỚNG DƯƠNG)'),
                  Container(
                    decoration: _iosGroupCardDecoration(),
                    child: Column(
                      children: [
                        _buildIosMenuTile(
                          icon: Icons.bluetooth_searching_rounded,
                          iconBg: const Color(0xFF007AFF),
                          title: 'Kết nối Hoa hướng dương',
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
                          icon: Icons.display_settings_rounded,
                          iconBg: const Color(0xFF5856D6),
                          title: 'Giao diện ESP32',
                          subtitle: 'Độ sáng, mô phỏng Màn 1/2, theme ZIP & minimap',
                          isSelected: _currentIndex == 2,
                          onTap: () {
                            Navigator.pop(context);
                            setState(() => _currentIndex = 2);
                          },
                        ),
                        const Divider(height: 1, indent: 58, color: Color(0xFFE5E5EA)),
                        _buildIosMenuTile(
                          icon: Icons.system_update_rounded,
                          iconBg: const Color(0xFF34C759),
                          title: 'Cập nhật Firmware (.zip)',
                          subtitle: bleService.espFirmwareVersion != null
                              ? 'Trên mạch: v${bleService.espFirmwareVersion} • Nạp không dây OTA'
                              : 'Nạp firmware ESP32-S3 qua Wi-Fi từ file .zip',
                          isSelected: false,
                          onTap: () {
                            Navigator.pop(context);
                            showFirmwareUpdateSheet(context);
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
                          subtitle: 'Tuỳ chỉnh nguồn tìm kiếm và tính lộ trình',
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
