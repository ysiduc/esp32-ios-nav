import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/ble_service.dart';
import 'ble_screen.dart';
import 'esp_preview_screen.dart';
import 'map_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;

  final List<Widget> _screens = const [
    MapScreen(),
    BleScreen(),
    EspPreviewScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final bleService = context.watch<BleService>();

    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _screens,
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF161B22),
          border: const Border(top: BorderSide(color: Colors.white12, width: 0.8)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(120),
              blurRadius: 15,
              offset: const Offset(0, -3),
            ),
          ],
        ),
        child: NavigationBar(
          selectedIndex: _currentIndex,
          onDestinationSelected: (index) {
            setState(() => _currentIndex = index);
          },
          backgroundColor: Colors.transparent,
          indicatorColor: const Color(0xFF00F0FF).withAlpha(50),
          destinations: [
            const NavigationDestination(
              icon: Icon(Icons.map_outlined, color: Colors.white70),
              selectedIcon: Icon(Icons.map, color: Color(0xFF00F0FF)),
              label: 'Bản đồ',
            ),
            NavigationDestination(
              icon: Badge(
                isLabelVisible: bleService.isConnected,
                backgroundColor: const Color(0xFF05FFA1),
                smallSize: 8,
                child: const Icon(Icons.bluetooth, color: Colors.white70),
              ),
              selectedIcon: Badge(
                isLabelVisible: bleService.isConnected,
                backgroundColor: const Color(0xFF05FFA1),
                smallSize: 8,
                child: const Icon(Icons.bluetooth_connected, color: Color(0xFF00F0FF)),
              ),
              label: 'Kết nối ESP32',
            ),
            const NavigationDestination(
              icon: Icon(Icons.screenshot_monitor_outlined, color: Colors.white70),
              selectedIcon: Icon(Icons.screenshot_monitor, color: Color(0xFF00F0FF)),
              label: 'Màn hình ESP32',
            ),
          ],
        ),
      ),
    );
  }
}
