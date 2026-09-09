import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/ble_service.dart';
import '../services/navigation_manager.dart';

class EspPreviewScreen extends StatefulWidget {
  const EspPreviewScreen({super.key});

  @override
  State<EspPreviewScreen> createState() => _EspPreviewScreenState();
}

class _EspPreviewScreenState extends State<EspPreviewScreen> {
  // Notification Simulation State
  bool _showCallPopup = false;
  bool _showSmsPopup = false;
  final String _callerName = 'Nguyễn Văn A';
  final String _smsSender = 'Mẹ';
  final String _smsContent = 'Con ve nha an com nhe!';
  Timer? _popupDismissTimer;

  void _triggerMockCall() {
    _popupDismissTimer?.cancel();
    setState(() {
      _showCallPopup = true;
      _showSmsPopup = false;
    });

    _popupDismissTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) setState(() => _showCallPopup = false);
    });
  }

  void _triggerMockSms() {
    _popupDismissTimer?.cancel();
    setState(() {
      _showSmsPopup = true;
      _showCallPopup = false;
    });

    _popupDismissTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _showSmsPopup = false);
    });
  }

  @override
  void dispose() {
    _popupDismissTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final navManager = context.watch<NavigationManager>();
    final bleService = context.watch<BleService>();

    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        elevation: 0,
        title: const Row(
          children: [
            Icon(Icons.tv_rounded, color: Color(0xFF00F0FF)),
            SizedBox(width: 10),
            Text('Mô phỏng Màn hình ESP32', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          ],
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Subtitle
            const Text(
              'Giao diện thực tế hiển thị trên phần cứng ESP32 (TFT / OLED)',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 16),

            // 1. ESP32 Physical Device Enclosure Mockup
            Center(
              child: Container(
                width: 320,
                height: 220,
                decoration: BoxDecoration(
                  color: const Color(0xFF1E242C),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: const Color(0xFF30363D), width: 6),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha(200),
                      blurRadius: 25,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    color: Colors.black, // Display Canvas
                    child: Stack(
                      children: [
                        // Display Content (Navigation HUD or Popups)
                        if (_showCallPopup)
                          _buildCallPopup()
                        else if (_showSmsPopup)
                          _buildSmsPopup()
                        else
                          _buildEspNavView(navManager),

                        // Top Hardware Status Line (BLE, Clock, Battery)
                        Positioned(
                          top: 6,
                          left: 10,
                          right: 10,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    bleService.isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                                    color: bleService.isConnected ? const Color(0xFF00F0FF) : Colors.redAccent,
                                    size: 14,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    bleService.isConnected ? 'ANCS OK' : 'NO BLE',
                                    style: TextStyle(
                                      color: bleService.isConnected ? const Color(0xFF00F0FF) : Colors.redAccent,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                ],
                              ),
                              const Text(
                                '12:45',
                                style: TextStyle(color: Colors.white70, fontSize: 10, fontFamily: 'monospace'),
                              ),
                              const Row(
                                children: [
                                  Icon(Icons.battery_full, color: Color(0xFF05FFA1), size: 14),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 24),

            // 2. Interactive Testing Controls
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF161B22),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'KIỂM THỬ THÔNG BÁO iOS (ANCS POPUP TEST)',
                    style: TextStyle(color: Color(0xFF00F0FF), fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Khi iPhone nhận cuộc gọi hoặc tin nhắn, iOS ANCS tự động bắn sự kiện qua Bluetooth sang ESP32. Bấm các nút dưới đây để kiểm tra hiệu ứng đè màn hình thông báo:',
                    style: TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                  const SizedBox(height: 14),

                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF05FFA1).withAlpha(50),
                            foregroundColor: const Color(0xFF05FFA1),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            side: const BorderSide(color: Color(0xFF05FFA1)),
                          ),
                          icon: const Icon(Icons.phone_in_talk_rounded, size: 20),
                          label: const Text('Cuộc gọi đến', style: TextStyle(fontWeight: FontWeight.bold)),
                          onPressed: _triggerMockCall,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFFFB800).withAlpha(50),
                            foregroundColor: const Color(0xFFFFB800),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            side: const BorderSide(color: Color(0xFFFFB800)),
                          ),
                          icon: const Icon(Icons.mark_chat_unread_rounded, size: 20),
                          label: const Text('Tin nhắn SMS', style: TextStyle(fontWeight: FontWeight.bold)),
                          onPressed: _triggerMockSms,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // 3. Technical Explanation Card
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF161B22),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white12),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'CƠ CHẾ KÉP TRÊN ESP32',
                    style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 8),
                  Text(
                    '1. Kênh ANCS (Client): Lắng nghe iOS Notification Center để hiện Popup Cuộc gọi/Tin nhắn đè lên giao diện chính.\n'
                    '2. Kênh Chỉ đường (Server): Nhận JSON lộ trình từ App Flutter để vẽ icon mũi tên rẽ, số mét và tên đường.\n'
                    '3. Tự động phục hồi: Sau khi kết thúc cuộc gọi hoặc tin nhắn, màn hình ESP32 tự động quay lại chế độ chỉ đường.',
                    style: TextStyle(color: Colors.white60, fontSize: 12, height: 1.5),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Screen View 1: Navigation HUD on ESP32
  Widget _buildEspNavView(NavigationManager navManager) {
    final step = navManager.currentStep;
    final dist = navManager.distanceToNextManeuver.round();
    final street = step?.streetName ?? 'San sang dan duong';
    final speed = navManager.currentSpeedKmh.round();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 26, 16, 12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              // Large Direction Icon (High contrast cyan/white for TFT/OLED)
              Container(
                width: 68,
                height: 68,
                decoration: BoxDecoration(
                  color: const Color(0xFF00F0FF).withAlpha(40),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF00F0FF), width: 2),
                ),
                child: Icon(
                  step?.icon ?? Icons.navigation_rounded,
                  color: const Color(0xFF00F0FF),
                  size: 46,
                ),
              ),
              const SizedBox(width: 14),

              // Distance Meter & Speed
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      dist >= 1000 ? '${(dist / 1000).toStringAsFixed(1)} km' : '$dist m',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'monospace',
                      ),
                    ),
                    Row(
                      children: [
                        const Icon(Icons.speed, color: Color(0xFF05FFA1), size: 16),
                        const SizedBox(width: 4),
                        Text(
                          '$speed km/h',
                          style: const TextStyle(color: Color(0xFF05FFA1), fontSize: 14, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF21262D),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              street.toUpperCase(),
              style: const TextStyle(
                color: Color(0xFFFFB800),
                fontSize: 13,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// Screen View 2: Incoming Call Popup on ESP32
  Widget _buildCallPopup() {
    return Container(
      color: const Color(0xFF002B1B), // Dark green alert background
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.phone_in_talk, color: Color(0xFF05FFA1), size: 28),
              SizedBox(width: 8),
              Text(
                'CUOC GOI DEN',
                style: TextStyle(color: Color(0xFF05FFA1), fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            _callerName.toUpperCase(),
            style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 12),
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              Text('☎️ Nhap nhay den bao...', style: TextStyle(color: Colors.white60, fontSize: 11)),
            ],
          ),
        ],
      ),
    );
  }

  /// Screen View 3: SMS Notification Popup on ESP32
  Widget _buildSmsPopup() {
    return Container(
      color: const Color(0xFF2B1F00), // Dark Amber alert background
      padding: const EdgeInsets.all(14),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.mail_outline_rounded, color: Color(0xFFFFB800), size: 20),
              const SizedBox(width: 6),
              Text(
                'SMS: ${_smsSender.toUpperCase()}',
                style: const TextStyle(color: Color(0xFFFFB800), fontSize: 14, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              _smsContent,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
