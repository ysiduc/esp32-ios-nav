import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/ble_service.dart';
import '../services/navigation_manager.dart';
import 'ble_screen.dart';
import 'esp_preview_screen.dart';
import 'map_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    final bleService = context.watch<BleService>();
    final navManager = context.watch<NavigationManager>();

    final screens = [
      MapScreen(
        onOpenMenu: () => _scaffoldKey.currentState?.openDrawer(),
      ),
      BleScreen(
        onBackToMap: () => setState(() => _currentIndex = 0),
      ),
      EspPreviewScreen(
        onBackToMap: () => setState(() => _currentIndex = 0),
      ),
    ];

    return Scaffold(
      key: _scaffoldKey,
      drawerEnableOpenDragGesture: _currentIndex == 0 && !navManager.isNavigating,
      drawer: _buildAppDrawer(context, bleService),
      body: IndexedStack(
        index: _currentIndex,
        children: screens,
      ),
      // No bottomNavigationBar: Map is the pure full-screen main interface!
    );
  }

  Widget _buildAppDrawer(BuildContext context, BleService bleService) {
    final isBle = bleService.isConnected;
    final isWifi = bleService.isWifiConnected;

    return Drawer(
      backgroundColor: const Color(0xFF131B26),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Colors.white10)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFF00F0FF).withAlpha(35),
                          border: Border.all(color: const Color(0xFF00F0FF).withAlpha(120)),
                        ),
                        child: const Icon(Icons.navigation_rounded, color: Color(0xFF00F0FF), size: 24),
                      ),
                      const SizedBox(width: 14),
                      const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'ESP32 NAVI',
                            style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold, letterSpacing: 0.8),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'Bản đồ dẫn đường thông minh',
                            style: TextStyle(color: Colors.white54, fontSize: 12),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Connection Status Pill
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0B111A),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isBle ? const Color(0xFF05FFA1).withAlpha(80) : Colors.white12,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          isBle ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                          color: isBle ? const Color(0xFF05FFA1) : Colors.white38,
                          size: 16,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            isBle
                                ? (isWifi ? 'BLE + WiFi Hotspot (${bleService.wifiIp})' : 'Đã kết nối BLE (ESP32 Live)')
                                : 'Chưa kết nối ESP32',
                            style: TextStyle(
                              color: isBle ? const Color(0xFF05FFA1) : Colors.white54,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Navigation Items
            const SizedBox(height: 12),
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
              subtitle: 'Quét BLE & Cài đặt WiFi Hotspot iPhone',
              isSelected: _currentIndex == 1,
              badgeColor: isBle ? const Color(0xFF05FFA1) : null,
              onTap: () {
                Navigator.pop(context);
                setState(() => _currentIndex = 1);
              },
            ),
            _buildDrawerTile(
              icon: Icons.screenshot_monitor_rounded,
              title: 'Mô phỏng Màn hình ESP32',
              subtitle: 'Xem trước HUD, Mini Map & FPS stream',
              isSelected: _currentIndex == 2,
              onTap: () {
                Navigator.pop(context);
                setState(() => _currentIndex = 2);
              },
            ),

            const Spacer(),

            // Footer Info
            Container(
              padding: const EdgeInsets.all(16),
              margin: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF0B111A),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white10),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline_rounded, color: Color(0xFF00F0FF), size: 18),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Bấm 3 gạch góc trên trái để mở menu này bất cứ lúc nào.',
                      style: TextStyle(color: Colors.white60, fontSize: 11),
                    ),
                  ),
                ],
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
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: isSelected ? const Color(0xFF00F0FF).withAlpha(30) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isSelected ? const Color(0xFF00F0FF).withAlpha(100) : Colors.transparent,
        ),
      ),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        leading: Icon(
          icon,
          color: isSelected ? const Color(0xFF00F0FF) : Colors.white70,
          size: 24,
        ),
        title: Text(
          title,
          style: TextStyle(
            color: isSelected ? const Color(0xFF00F0FF) : Colors.white,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
            fontSize: 14,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: const TextStyle(color: Colors.white38, fontSize: 11),
        ),
        trailing: badgeColor != null
            ? Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: badgeColor, shape: BoxShape.circle),
              )
            : null,
        onTap: onTap,
      ),
    );
  }
}
