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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final navManager = Provider.of<NavigationManager>(context, listen: false);
      if (navManager.currentLocation != null) {
        _miniMapController.move(navManager.currentLocation!, 17.0);
      }

      // Auto-start 20 FPS JPEG streaming immediately on screen open
      Future.delayed(const Duration(milliseconds: 500), () {
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
    _popupDismissTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final navManager = context.watch<NavigationManager>();
    final bleService = context.watch<BleService>();
    final streamService = context.watch<EspStreamService>();

    final userLoc = navManager.currentLocation ?? const LatLng(21.0285, 105.8542);

    // Keep Mini Map ALWAYS centered on vehicle location
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        _miniMapController.move(userLoc, 17.0);
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
                            streamService.isStreaming
                                ? 'STREAMING ${streamService.targetFps} FPS (${streamService.actualFps.toStringAsFixed(1)} FPS)'
                                : 'STREAM TẮT',
                            style: TextStyle(
                              color: streamService.isStreaming ? const Color(0xFF05FFA1) : Colors.white60,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          Text(
                            '${streamService.frameSizeKb} KB/frame',
                            style: const TextStyle(color: Colors.white70, fontSize: 11, fontFamily: 'monospace'),
                          ),
                          const SizedBox(width: 8),
                          GestureDetector(
                            onTap: () {
                              if (streamService.isStreaming) {
                                streamService.stopStreaming();
                              } else {
                                streamService.startStreaming(boundaryKey: _streamBoundaryKey);
                              }
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                              decoration: BoxDecoration(
                                color: streamService.isStreaming ? Colors.redAccent.withAlpha(35) : const Color(0xFF00F0FF).withAlpha(35),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: streamService.isStreaming ? Colors.redAccent : const Color(0xFF00F0FF)),
                              ),
                              child: Text(
                                streamService.isStreaming ? 'Dừng' : 'Bật Stream',
                                style: TextStyle(
                                  color: streamService.isStreaming ? Colors.redAccent : const Color(0xFF00F0FF),
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
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

            // 1. ESP32 Physical Device Enclosure Mockup (350x220 TFT LCD / OLED)
            Center(
              child: RepaintBoundary(
                key: _streamBoundaryKey,
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
                      color: Colors.black, // Display Canvas
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
            ),

            const SizedBox(height: 20),

            // 2. Stream Connection Details Card
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
                  const Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'KẾT NỐI STREAM JPEG SANG ESP32 (20 FPS)',
                        style: TextStyle(color: Color(0xFF00F0FF), fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                      ),
                      Icon(Icons.wifi_tethering_rounded, color: Color(0xFF00F0FF), size: 18),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '1. Kênh Wi-Fi / Hotspot (Mượt 20 FPS): ESP32 kết nối Wi-Fi và đọc luồng MJPEG tại:\n'
                    '   URL: http://<IP_DIEN_THOAI>:8080/stream.mjpg\n'
                    '2. Kênh BLE: Tự động gửi frame JPEG qua BLE RX Characteristic.\n'
                    '3. Vị trí xe luôn được căn chính xác 100% ở tâm giữa của nửa màn hình bên trái.',
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
    final street = step?.streetName ?? 'San sang dan duong';
    final speed = navManager.currentSpeedKmh.round();
    final etaMins = navManager.remainingEtaMinutes;
    final totalDistKm = (navManager.remainingTotalDistance / 1000).toStringAsFixed(1);

    final arrivalTime = DateTime.now().add(Duration(minutes: etaMins));
    final arrivalClock = '${arrivalTime.hour.toString().padLeft(2, '0')}:${arrivalTime.minute.toString().padLeft(2, '0')}';

    final activeRoute = navManager.activeRoute;

    return Padding(
      padding: const EdgeInsets.only(top: 24.0),
      child: Row(
        children: [
          // -----------------------------------------------------------
          // LEFT 50%: Live Mini Map Canvas (Strictly Centered on Vehicle)
          // -----------------------------------------------------------
          Expanded(
            flex: 1,
            child: Container(
              margin: const EdgeInsets.fromLTRB(6, 4, 3, 6),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF00F0FF).withAlpha(80), width: 1.2),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(9),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Mini Map Layer
                    FlutterMap(
                      mapController: _miniMapController,
                      options: MapOptions(
                        initialCenter: userLoc,
                        initialZoom: 17.0,
                        interactionOptions: const InteractionOptions(flags: InteractiveFlag.none),
                      ),
                      children: [
                        TileLayer(
                          urlTemplate: 'https://mt1.google.com/vt/lyrs=m&scale=2&hl=vi&x={x}&y={y}&z={z}',
                          userAgentPackageName: 'com.esp32nav.app',
                          maxZoom: 20,
                        ),
                        if (activeRoute != null)
                          PolylineLayer(
                            polylines: [
                              Polyline(
                                points: activeRoute.polylinePoints,
                                strokeWidth: 6.0,
                                color: const Color(0xFF00F0FF),
                              ),
                            ],
                          ),
                        MarkerLayer(
                          markers: [
                            Marker(
                              point: userLoc,
                              width: 32,
                              height: 32,
                              alignment: Alignment.center,
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  Container(
                                    width: 30,
                                    height: 30,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: const Color(0xFF0084FF).withAlpha(40),
                                      border: Border.all(color: const Color(0xFF0084FF).withAlpha(120), width: 1.5),
                                    ),
                                  ),
                                  Transform.rotate(
                                    angle: (navManager.currentHeading * (3.1415926535 / 180.0)),
                                    child: Container(
                                      width: 22,
                                      height: 22,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: const Color(0xFF0084FF),
                                        border: Border.all(color: Colors.white, width: 2),
                                        boxShadow: [
                                          BoxShadow(color: const Color(0xFF0084FF).withAlpha(200), blurRadius: 8),
                                        ],
                                      ),
                                      child: const Icon(Icons.navigation_rounded, color: Colors.white, size: 14),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),

                    // Mini Map Overlay Badge
                    Positioned(
                      bottom: 4,
                      left: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.black.withAlpha(200),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'MAP LIVE',
                          style: TextStyle(color: Color(0xFF00F0FF), fontSize: 8, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // -----------------------------------------------------------
          // RIGHT 50%: Turn Directions, Speed, Street Name & ETA Metrics
          // -----------------------------------------------------------
          Expanded(
            flex: 1,
            child: Container(
              margin: const EdgeInsets.fromLTRB(3, 4, 6, 6),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF161E28),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white12),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Row 1: Big Turn Arrow + Distance to Turn
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: const Color(0xFF00F0FF).withAlpha(35),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFF00F0FF), width: 1.2),
                        ),
                        child: Icon(
                          step?.icon ?? Icons.straight_rounded,
                          color: const Color(0xFF00F0FF),
                          size: 26,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              distStr,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                fontFamily: 'monospace',
                                height: 1.1,
                              ),
                            ),
                            Text(
                              '$speed km/h',
                              style: const TextStyle(
                                color: Color(0xFF05FFA1),
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),

                  // Row 2: Next Street Name Badge (Marquee/Uppercase)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Text(
                      street.toUpperCase(),
                      style: const TextStyle(
                        color: Color(0xFFFFB800),
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'monospace',
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),

                  // Row 3: Arrival Time Clock & Remaining Duration/KM
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0A0E14),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('DỰ KIẾN', style: TextStyle(color: Colors.white38, fontSize: 7, fontWeight: FontWeight.bold)),
                            Text(
                              arrivalClock,
                              style: const TextStyle(color: Color(0xFF00F0FF), fontSize: 12, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
                            ),
                          ],
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text('$totalDistKm km', style: const TextStyle(color: Colors.white70, fontSize: 8, fontFamily: 'monospace')),
                            Text(
                              '$etaMins ph',
                              style: const TextStyle(color: Color(0xFF05FFA1), fontSize: 11, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Screen View 2: Incoming Call Popup on ESP32
  Widget _buildCallPopup() {
    return Container(
      color: const Color(0xFF002B1B),
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
      color: const Color(0xFF2B1F00),
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
