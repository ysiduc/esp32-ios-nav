import '../services/esp_stream_service.dart';
import 'dart:ui';
import '../widgets/liquid_glass.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/ble_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_radius.dart';
import '../theme/app_typography.dart';
import '../widgets/common/status_badge.dart';
import 'map_screen.dart';
import 'ble_screen.dart';
import 'esp_preview_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    final bleService = context.watch<BleService>();

    final screens = [
      const MapScreen(),
      BleScreen(onBackToMap: () => setState(() => _currentIndex = 0)),
      EspPreviewScreen(onBackToMap: () => setState(() => _currentIndex = 0)),
    ];

    return Scaffold(
      drawerScrimColor: Colors.transparent,
      onDrawerChanged: (isOpen) => MapNativeGlassController.instance.setOverlayMode(
        isOpen ? MapOverlayMode.drawer : MapOverlayMode.none,
      ),
      drawer: _buildAppDrawer(context, bleService),
      body: IndexedStack(
        index: _currentIndex,
        children: screens,
      ),
    );
  }

  bool _isDarkMode(BuildContext context) {
    try {
      final streamService = Provider.of<EspStreamService>(context, listen: false);
      if (streamService.streamMapStyle == 'streets-v2-dark' ||
          streamService.streamMapStyle == 'hybrid') {
        return true;
      }
    } catch (_) {}
    return Theme.of(context).brightness == Brightness.dark;
  }

  Widget _buildAppDrawer(BuildContext context, BleService bleService) {
    final isBle = bleService.isConnected;
    final isWifi = bleService.isWifiConnected;
    final isDark = _isDarkMode(context);

    return Drawer(
      backgroundColor: Colors.transparent,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: const BorderRadius.horizontal(right: Radius.circular(28)),
          gradient: MapOverlayGlassStyle.drawerRimGradient(isDark: isDark),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(isDark ? 0.25 : 0.06),
              blurRadius: 24,
              offset: const Offset(4, 0),
            ),
          ],
        ),
        padding: const EdgeInsets.only(top: 0.8, right: 0.8, bottom: 0.8),
        child: ClipRRect(
          borderRadius: const BorderRadius.horizontal(right: Radius.circular(27.2)),
          child: BackdropFilter(
            filter: ImageFilter.blur(
              sigmaX: MapOverlayGlassStyle.largeSurfaceBlur,
              sigmaY: MapOverlayGlassStyle.largeSurfaceBlur,
            ),
            child: Container(
              decoration: BoxDecoration(
                gradient: MapOverlayGlassStyle.wateryLargeSurfaceGradient(isDark: isDark),
                borderRadius: const BorderRadius.horizontal(right: Radius.circular(27.2)),
              ),
              child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color: const Color(0xFF007AFF).withOpacity(isDark ? 0.25 : 0.12),
                                borderRadius: AppRadius.roundedLg,
                                border: Border.all(
                                  color: const Color(0xFF007AFF).withOpacity(0.35),
                                  width: 1.0,
                                ),
                              ),
                              child: const Icon(Icons.navigation_rounded, color: Color(0xFF007AFF), size: 26),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'ESP32 NAVI',
                                    style: AppTypography.title2.copyWith(
                                      color: isDark ? Colors.white : AppColors.textPrimary,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Bản đồ dẫn đường thông minh',
                                    style: AppTypography.caption.copyWith(
                                      color: isDark ? Colors.white70 : AppColors.textSecondary,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),

                        // Connection Status Card
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: MapOverlayGlassStyle.drawerCardFill(isDark: isDark),
                            borderRadius: BorderRadius.circular(16),
                            border: MapOverlayGlassStyle.drawerCardBorder(isDark: isDark),
                          ),
                          child: Row(
                            children: [
                              StatusBadge(
                                text: isBle ? 'KẾT NỐI' : 'CHƯA KẾT NỐI',
                                color: isBle ? AppColors.success : (isDark ? Colors.white60 : AppColors.textSecondary),
                                icon: isBle ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  isBle
                                      ? (isWifi ? 'BLE + Hotspot (${bleService.wifiIp})' : 'Đã kết nối BLE ESP32')
                                      : 'Chưa kết nối thiết bị ESP32',
                                  style: AppTypography.footnote.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: isBle
                                        ? (isDark ? Colors.white : AppColors.textPrimary)
                                        : (isDark ? Colors.white70 : AppColors.textSecondary),
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                            child: Text(
                              'ỨNG DỤNG & ĐIỀU HƯỚNG',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: isDark ? Colors.white60 : const Color(0xFF6E6E73),
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),

                          // Navigation Items
                          _buildDrawerTile(
                            icon: Icons.map_rounded,
                            title: 'Bản đồ dẫn đường',
                            subtitle: 'Giao diện chính bản đồ',
                            isSelected: _currentIndex == 0,
                            isDark: isDark,
                            onTap: () {
                              Navigator.pop(context);
                              setState(() => _currentIndex = 0);
                            },
                          ),
                          _buildDrawerTile(
                            icon: Icons.bluetooth_searching_rounded,
                            title: 'Kết nối ESP32',
                            subtitle: 'Quét BLE & Cài đặt WiFi Hotspot',
                            isSelected: _currentIndex == 1,
                            isDark: isDark,
                            badgeColor: isBle ? AppColors.success : null,
                            onTap: () {
                              Navigator.pop(context);
                              setState(() => _currentIndex = 1);
                            },
                          ),
                          _buildDrawerTile(
                            icon: Icons.screenshot_monitor_rounded,
                            title: 'Mô phỏng Màn hình ESP32',
                            subtitle: 'Xem trước HUD, Mini Map & Stream',
                            isSelected: _currentIndex == 2,
                            isDark: isDark,
                            onTap: () {
                              Navigator.pop(context);
                              setState(() => _currentIndex = 2);
                            },
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Footer Info
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: MapOverlayGlassStyle.drawerCardFill(isDark: isDark),
                        borderRadius: BorderRadius.circular(16),
                        border: MapOverlayGlassStyle.drawerCardBorder(isDark: isDark),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline_rounded, color: Color(0xFF007AFF), size: 20),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Kéo từ mép trái bản đồ để mở menu nhanh bất cứ lúc nào.',
                              style: AppTypography.caption.copyWith(
                                color: isDark ? Colors.white70 : AppColors.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      ),
    );
  }

  Widget _buildDrawerTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool isSelected,
    required bool isDark,
    required VoidCallback onTap,
    Color? badgeColor,
  }) {
    final bg = MapOverlayGlassStyle.drawerCardFill(isDark: isDark, isSelected: isSelected);
    final border = MapOverlayGlassStyle.drawerCardBorder(isDark: isDark, isSelected: isSelected);
    final fg = isSelected
        ? const Color(0xFF007AFF)
        : (isDark ? Colors.white : AppColors.textPrimary);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: AppRadius.roundedLg,
        border: border,
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: AppRadius.roundedLg,
        child: ListTile(
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.roundedLg),
        leading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: isSelected
                ? const Color(0xFF007AFF)
                : (isDark ? Colors.white.withOpacity(0.10) : const Color(0xFFE5E5EA)),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            icon,
            color: isSelected ? Colors.white : (isDark ? Colors.white70 : AppColors.textSecondary),
            size: 20,
          ),
        ),
        title: Text(
          title,
          style: AppTypography.headline.copyWith(
            color: fg,
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: AppTypography.caption.copyWith(
            color: isDark ? Colors.white60 : AppColors.textSecondary,
          ),
        ),
        trailing: badgeColor != null
            ? Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: badgeColor, shape: BoxShape.circle),
              )
            : Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: isDark ? Colors.white38 : AppColors.textTertiary,
              ),
        onTap: onTap,
        ),
      ),
    );
  }
}
