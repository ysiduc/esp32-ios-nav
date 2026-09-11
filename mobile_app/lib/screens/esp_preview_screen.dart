import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:provider/provider.dart';
import '../services/ble_service.dart';
import '../services/esp_stream_service.dart';
import '../services/navigation_manager.dart';

class EspPreviewScreen extends StatefulWidget {
  const EspPreviewScreen({super.key});

  @override
  State<EspPreviewScreen> createState() => _EspPreviewScreenState();
}

class _EspPreviewScreenState extends State<EspPreviewScreen> {
  final GlobalKey _streamBoundaryKey = GlobalKey();
  final MapController _miniMapController = MapController();

  // Notification Simulation State
  bool _showCallPopup = false;
  bool _showSmsPopup = false;
  final String _callerName = 'Nguyễn Văn A';
  final String _smsSender = 'Mẹ';
  final String _smsContent = 'Con ve nha an com nhe!';
  Timer? _popupDismissTimer;
  Timer? _autoStartTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final navManager = Provider.of<NavigationManager>(context, listen: false);
      final loc = navManager.currentLocation ?? (navManager.activeRoute?.polylinePoints.isNotEmpty == true ? navManager.activeRoute!.polylinePoints.first : const LatLng(21.0285, 105.8542));
      try {
        _miniMapController.moveAndRotate(loc, 17.0, -navManager.currentHeading);
      } catch (_) {}

      // Auto-start 20 FPS JPEG streaming immediately on screen open
      _autoStartTimer = Timer(const Duration(milliseconds: 500), () {
        if (mounted) {
          final streamService = Provider.of<EspStreamService>(context, listen: false);
          if (!streamService.isStreaming) {
            streamService.startStreaming(boundaryKey: _streamBoundaryKey);
          }
        }
      });
    });
  }

  void _triggerMockCall() {
    _popupDismissTimer?.cancel();
    setState(() {
      _showCallPopup = true;
      _showSmsPopup = false;
    });

    final bleService = Provider.of<BleService>(context, listen: false);
    if (bleService.isConnected) {
      bleService.sendRawString('{"type":"CALL","title":"Nguyen Van A","msg":"Cuoc goi den tu iPhone"}');
    }

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

    final bleService = Provider.of<BleService>(context, listen: false);
    if (bleService.isConnected) {
      bleService.sendRawString('{"type":"SMS","title":"Me","msg":"Con ve nha an com nhe!"}');
    }

    _popupDismissTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _showSmsPopup = false);
    });
  }

  @override
  void dispose() {
    _autoStartTimer?.cancel();
    _popupDismissTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final navManager = context.watch<NavigationManager>();
    final bleService = context.watch<BleService>();
    final streamService = context.watch<EspStreamService>();

    final userLoc = navManager.currentLocation ?? (navManager.activeRoute?.polylinePoints.isNotEmpty == true ? navManager.activeRoute!.polylinePoints.first : const LatLng(21.0285, 105.8542));

    // Keep Mini Map centered on vehicle
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        _miniMapController.moveAndRotate(userLoc, 17.0, -navManager.currentHeading);
      } catch (_) {}
    });

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
            // Stream Live Status Bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF161B22),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: streamService.isStreaming ? const Color(0xFF00F0FF) : Colors.white12),
                boxShadow: [
                  BoxShadow(color: Colors.black.withAlpha(120), blurRadius: 10),
                ],
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: streamService.isStreaming ? const Color(0xFF05FFA1) : Colors.grey,
                              boxShadow: streamService.isStreaming
                                  ? [BoxShadow(color: const Color(0xFF05FFA1).withAlpha(180), blurRadius: 6)]
                                  : [],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            streamService.isStreaming ? 'Đang Stream JPEG sang ESP32' : 'Dừng Stream',
                            style: TextStyle(
                              color: streamService.isStreaming ? const Color(0xFF05FFA1) : Colors.white54,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                      Switch.adaptive(
                        value: streamService.isStreaming,
                        activeTrackColor: const Color(0xFF00F0FF),
                        onChanged: (val) {
                          if (val) {
                            streamService.startStreaming(boundaryKey: _streamBoundaryKey);
                          } else {
                            streamService.stopStreaming();
                          }
                        },
                      ),
                    ],
                  ),
                  const Divider(color: Colors.white12, height: 16),
                  // Realtime Telemetry Stats (FPS, Size, Target)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      Column(
                        children: [
                          const Text('FPS THỰC TẾ', style: TextStyle(color: Colors.white54, fontSize: 10, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 2),
                          Text(
                            '${streamService.actualFps.toStringAsFixed(1)} FPS',
                            style: const TextStyle(color: Color(0xFF05FFA1), fontSize: 13, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
                          ),
                        ],
                      ),
                      Container(width: 1, height: 24, color: Colors.white12),
                      Column(
                        children: [
                          const Text('KÍCH THƯỚC FRAME', style: TextStyle(color: Colors.white54, fontSize: 10, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 2),
                          Text(
                            '${streamService.frameSizeKb} KB',
                            style: const TextStyle(color: Color(0xFF00F0FF), fontSize: 13, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
                          ),
                        ],
                      ),
                      Container(width: 1, height: 24, color: Colors.white12),
                      Column(
                        children: [
                          const Text('MỤC TIÊU', style: TextStyle(color: Colors.white54, fontSize: 10, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 2),
                          Text(
                            '${streamService.targetFps} FPS',
                            style: const TextStyle(color: Color(0xFFFFB800), fontSize: 13, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const Divider(color: Colors.white12, height: 16),
                  // FPS Selector Presets: 12, 15, 20 (Default), 25, 30
                  Row(
                    children: [
                      const Text('Tần số quét:', style: TextStyle(color: Colors.white60, fontSize: 11)),
                      const SizedBox(width: 8),
                      for (final fps in [12, 15, 20, 25, 30])
                        Padding(
                          padding: const EdgeInsets.only(right: 6.0),
                          child: GestureDetector(
                            onTap: () => streamService.setTargetFps(fps),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: streamService.targetFps == fps ? const Color(0xFF0084FF) : const Color(0xFF0F172A),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: streamService.targetFps == fps ? const Color(0xFF00F0FF) : Colors.white12,
                                ),
                              ),
                              child: Text(
                                '$fps FPS',
                                style: TextStyle(
                                  color: streamService.targetFps == fps ? Colors.white : Colors.white60,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // 1. ESP32 Physical Device Enclosure Mockup (350x220 TFT ST7789)
            Center(
              child: Container(
                width: 350,
                height: 220,
                decoration: BoxDecoration(
                  color: const Color(0xFF1E242C),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: const Color(0xFF30363D), width: 6),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha(220),
                      blurRadius: 25,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    color: Colors.black,
                    child: Stack(
                      children: [
                        // Display Content (Navigation HUD or Popups)
                        if (_showCallPopup)
                          _buildCallPopup()
                        else if (_showSmsPopup)
                          _buildSmsPopup()
                        else
                          _buildEspSplitNavView(navManager, userLoc),

                        // Top Hardware Status Line (BLE, Clock, Battery)
                        Positioned(
                          top: 4,
                          left: 8,
                          right: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.black.withAlpha(180),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      bleService.isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                                      color: bleService.isConnected ? const Color(0xFF00F0FF) : Colors.redAccent,
                                      size: 12,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      bleService.isConnected ? 'ESP32 BLE' : 'NO BLE',
                                      style: TextStyle(
                                        color: bleService.isConnected ? const Color(0xFF00F0FF) : Colors.redAccent,
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold,
                                        fontFamily: 'monospace',
                                      ),
                                    ),
                                  ],
                                ),
                                Text(
                                  _getCurrentClock(),
                                  style: const TextStyle(color: Colors.white70, fontSize: 9, fontFamily: 'monospace', fontWeight: FontWeight.bold),
                                ),
                                const Row(
                                  children: [
                                    Text('100%', style: TextStyle(color: Color(0xFF05FFA1), fontSize: 9, fontFamily: 'monospace')),
                                    SizedBox(width: 2),
                                    Icon(Icons.battery_full, color: Color(0xFF05FFA1), size: 12),
                                  ],
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

            const SizedBox(height: 20),

            // 2. Stream Connection Details Card (100% Pure BLE)
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
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'KẾT NỐI STREAM BẢN ĐỒ SANG ESP32 (BLE)',
                        style: TextStyle(color: Color(0xFF00F0FF), fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                      ),
                      Icon(Icons.bluetooth_audio_rounded, color: Color(0xFF00F0FF), size: 18),
                    ],
                  ),
                  SizedBox(height: 8),
                  Text(
                    '1. Kênh BLE: Tự động gửi frame JPEG bản đồ (nửa trái) qua Bluetooth BLE tốc độ cao (MTU 517).\n'
                    '2. Tiết kiệm pin: Chạy 100% qua Bluetooth BLE siêu tiết kiệm pin, không cần bật WiFi Hotspot.\n'
                    '3. Vị trí xe luôn được căn chính xác 100% ở tâm giữa bản đồ.',
                    style: TextStyle(color: Colors.white60, fontSize: 12, height: 1.5),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // 3. Interactive Notification Testing Controls
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
                    'Bấm các nút dưới để kiểm tra hiệu ứng đè màn hình cuộc gọi / tin nhắn:',
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
          ],
        ),
      ),
    );
  }

  String _getCurrentClock() {
    final now = DateTime.now();
    final h = now.hour.toString().padLeft(2, '0');
    final m = now.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  /// Split Screen 50/50 Navigation View on ESP32 Display
  Widget _buildEspSplitNavView(NavigationManager navManager, LatLng userLoc) {
    final step = navManager.currentStep;
    final dist = navManager.distanceToNextManeuver.round();
    final distStr = dist >= 1000 ? '${(dist / 1000).toStringAsFixed(1)}km' : '${dist}m';
    final street = step?.streetName.isNotEmpty == true ? step!.streetName : 'KĐT ĐẠI KIM - ĐỊNH CÔNG';
    final speed = navManager.currentSpeedKmh.round();
    final etaMins = navManager.remainingEtaMinutes > 0 ? navManager.remainingEtaMinutes : 1;
    final totalDistKm = navManager.remainingTotalDistance > 0 ? (navManager.remainingTotalDistance / 1000).toStringAsFixed(1) : '0.1';

    final arrivalTime = DateTime.now().add(Duration(minutes: etaMins));
    final arrivalClock = '${arrivalTime.hour.toString().padLeft(2, '0')}:${arrivalTime.minute.toString().padLeft(2, '0')}';

    final activeRoute = navManager.activeRoute;
    final polylinePoints = activeRoute != null && activeRoute.polylinePoints.isNotEmpty
        ? activeRoute.polylinePoints
        : [
            LatLng(userLoc.latitude - 0.0015, userLoc.longitude - 0.0010),
            LatLng(userLoc.latitude, userLoc.longitude - 0.0010),
            userLoc,
            LatLng(userLoc.latitude + 0.0015, userLoc.longitude),
          ];

    return Padding(
      padding: const EdgeInsets.only(top: 24.0),
      child: Row(
        children: [
          // -----------------------------------------------------------
          // LEFT 50%: Live Mini Map Canvas
          // -----------------------------------------------------------
          Expanded(
            flex: 1,
            child: RepaintBoundary(
              key: _streamBoundaryKey,
              child: Container(
                margin: const EdgeInsets.fromLTRB(6, 4, 3, 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF00F0FF).withAlpha(120), width: 1.2),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // Mini Map Layer (OpenStreetMap / CartoDB Voyager with Dark Filter)
                      FlutterMap(
                        mapController: _miniMapController,
                        options: MapOptions(
                          initialCenter: userLoc,
                          initialZoom: 17.0,
                          initialRotation: -navManager.currentHeading,
                          interactionOptions: const InteractionOptions(flags: InteractiveFlag.none),
                        ),
                        children: [
                          TileLayer(
                            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                            userAgentPackageName: 'com.esp32nav.app',
                            maxZoom: 19,
                          ),
                          PolylineLayer(
                            polylines: [
                              Polyline(
                                points: polylinePoints,
                                strokeWidth: 5.0,
                                color: const Color(0xFF00F0FF),
                              ),
                            ],
                          ),
                          MarkerLayer(
                            markers: [
                              Marker(
                                point: userLoc,
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
                                        color: const Color(0xFF0084FF).withAlpha(50),
                                        border: Border.all(color: const Color(0xFF00F0FF).withAlpha(180), width: 1.5),
                                      ),
                                    ),
                                    Container(
                                      width: 20,
                                      height: 20,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: const Color(0xFF0084FF),
                                        border: Border.all(color: Colors.white, width: 2),
                                        boxShadow: [
                                          BoxShadow(color: const Color(0xFF0084FF).withAlpha(200), blurRadius: 8),
                                        ],
                                      ),
                                      child: const Icon(Icons.navigation_rounded, color: Colors.white, size: 12),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),

                      // MAP LIVE Pill Badge
                      Positioned(
                        bottom: 6,
                        left: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.black.withAlpha(200),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: Colors.white24, width: 0.5),
                          ),
                          child: const Text(
                            'MAP LIVE',
                            style: TextStyle(
                              color: Color(0xFF05FFA1),
                              fontSize: 8,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // -----------------------------------------------------------
          // RIGHT 50%: HUD Navigation Cards (Image 2 Replica)
          // -----------------------------------------------------------
          Expanded(
            flex: 1,
            child: Container(
              margin: const EdgeInsets.fromLTRB(3, 4, 6, 6),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF151D2A),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF222F42), width: 1.2),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Row 1: Maneuver Icon + Distance + Speed
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F172A),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFF00F0FF), width: 1.5),
                        ),
                        child: const Icon(
                          Icons.turn_right_rounded,
                          color: Color(0xFF00F0FF),
                          size: 26,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              distStr,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            Text(
                              '$speed km/h',
                              style: const TextStyle(
                                color: Color(0xFF05FFA1),
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),

                  // Row 2: Street Name Pill Card
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0B111A),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFF1E293B)),
                    ),
                    child: Text(
                      street.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFFFFB800),
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),

                  // Row 3: ETA & Remaining Distance
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'DỰ KIẾN',
                            style: TextStyle(color: Colors.white54, fontSize: 8, fontWeight: FontWeight.bold),
                          ),
                          Text(
                            arrivalClock,
                            style: const TextStyle(
                              color: Color(0xFF00F0FF),
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            '$totalDistKm km',
                            style: const TextStyle(color: Colors.white60, fontSize: 9),
                          ),
                          Text(
                            '$etaMins ph',
                            style: const TextStyle(
                              color: Color(0xFF05FFA1),
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCallPopup() {
    return Container(
      color: const Color(0xFF022C22),
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.phone_in_talk_rounded, color: Color(0xFF05FFA1), size: 36),
          const SizedBox(height: 8),
          const Text('CUỘC GỌI ĐẾN', style: TextStyle(color: Color(0xFF05FFA1), fontSize: 13, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(_callerName, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          const Text('Apple ANCS Notification', style: TextStyle(color: Color(0xFF00F0FF), fontSize: 10)),
        ],
      ),
    );
  }

  Widget _buildSmsPopup() {
    return Container(
      color: const Color(0xFF0B192C),
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.mark_chat_unread_rounded, color: Color(0xFF00F0FF), size: 36),
          const SizedBox(height: 8),
          const Text('TIN NHẮN SMS', style: TextStyle(color: Color(0xFF00F0FF), fontSize: 13, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(_smsSender, style: const TextStyle(color: Color(0xFFFFB800), fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(_smsContent, style: const TextStyle(color: Colors.white, fontSize: 12), textAlign: TextAlign.center),
        ],
      ),
    );
  }
}
