import '../widgets/liquid_glass.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/ble_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_radius.dart';
import '../theme/app_shadows.dart';
import '../theme/app_typography.dart';
import '../widgets/common/map_card.dart';
import '../widgets/common/section_header.dart';
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

  Widget _buildAppDrawer(BuildContext context, BleService bleService) {
    final isBle = bleService.isConnected;
    final isWifi = bleService.isWifiConnected;

    return Drawer(
      backgroundColor: AppColors.surfaceSecondary,
      surfaceTintColor: Colors.transparent,
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
                          color: AppColors.primaryLight,
                          borderRadius: AppRadius.roundedLg,
                          border: Border.all(color: AppColors.primary.withAlpha(50), width: 1.0),
                          boxShadow: AppShadows.card,
                        ),
                        child: const Icon(Icons.navigation_rounded, color: AppColors.primary, size: 26),
                      ),
                      const SizedBox(width: 14),
                      const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'ESP32 NAVI',
                            style: AppTypography.title2,
                          ),
                          SizedBox(height: 2),
                          Text(
                            'Bản đồ dẫn đường thông minh',
                            style: AppTypography.caption,
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Connection Status Card
                  MapCard(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    child: Row(
                      children: [
                        StatusBadge(
                          text: isBle ? 'KẾT NỐI' : 'CHƯA KẾT NỐI',
                          color: isBle ? AppColors.success : AppColors.textSecondary,
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
                              color: isBle ? AppColors.textPrimary : AppColors.textSecondary,
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

            const SectionHeader(title: 'Ứng dụng & Điều hướng'),
            const SizedBox(height: 4),

            // Navigation Items
            _buildDrawerTile(
              icon: Icons.map_rounded,
              title: 'Bản đồ dẫn đường',
              subtitle: 'Giao diện chính bản đồ',
              isSelected: _currentIndex == 0,
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
              onTap: () {
                Navigator.pop(context);
                setState(() => _currentIndex = 2);
              },
            ),

            const Spacer(),

            // Footer Info
            Padding(
              padding: const EdgeInsets.all(16),
              child: MapCard(
                padding: const EdgeInsets.all(14),
                color: AppColors.surface,
                child: const Row(
                  children: [
                    Icon(Icons.info_outline_rounded, color: AppColors.primary, size: 20),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Chạm nút 3 gạch góc trên bản đồ để mở menu nhanh bất cứ lúc nào.',
                        style: AppTypography.caption,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDrawerTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool isSelected,
    required VoidCallback onTap,
    Color? badgeColor,
  }) {
    final bg = isSelected ? AppColors.primaryLight : AppColors.surface;
    final border = isSelected ? AppColors.primary.withAlpha(90) : AppColors.border;
    final fg = isSelected ? AppColors.primary : AppColors.textPrimary;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: AppRadius.roundedLg,
        border: Border.all(color: border, width: isSelected ? 1.4 : 0.8),
        boxShadow: isSelected ? AppShadows.button : AppShadows.card,
      ),
      child: ListTile(
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.roundedLg),
        leading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: isSelected ? AppColors.primary : AppColors.canvas,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            icon,
            color: isSelected ? Colors.white : AppColors.textSecondary,
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
          style: AppTypography.caption,
        ),
        trailing: badgeColor != null
            ? Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: badgeColor, shape: BoxShape.circle),
              )
            : const Icon(Icons.chevron_right_rounded, size: 20, color: AppColors.textTertiary),
        onTap: onTap,
      ),
    );
  }
}
