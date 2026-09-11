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

  bool _showCallPopup = false;
  bool _showSmsPopup = false;
  final String _callerName = 'Nguyễn Văn A';
  final String _smsSender = 'Mẹ';
  final String _smsContent = 'Con ve nha an com nhe!';
  Timer? _popupDismissTimer;
  Timer? _autoStartTimer;
  Timer? _previewSyncTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final navManager = Provider.of<NavigationManager>(context, listen: false);
      final loc = navManager.currentLocation ??
          (navManager.activeRoute?.polylinePoints.isNotEmpty == true
              ? navManager.activeRoute!.polylinePoints.first
              : const LatLng(20.9832, 105.8425)); // Default to Pho Nguyen Cong Thai / Cau Song Lu
      try {
        _miniMapController.moveAndRotate(loc, 16.0, -navManager.currentHeading);
      } catch (_) {}

      // Auto-start headless 20-30 FPS JPEG streaming immediately
      _autoStartTimer = Timer(const Duration(milliseconds: 200), () {
        if (mounted) {
          final streamService = Provider.of<EspStreamService>(context, listen: false);
          if (!streamService.isStreaming) {
            streamService.startStreaming();
          }
        }
      });

      // Synchronize HUD navigation telemetry with physical ESP32 screen
      _previewSyncTimer = Timer.periodic(const Duration(milliseconds: 1200), (_) {
        if (mounted) {
          final nav = Provider.of<NavigationManager>(context, listen: false);
          nav.sendPreviewPayloadToEsp32();
        }
      });
      navManager.sendPreviewPayloadToEsp32();
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
    _previewSyncTimer?.cancel();
    _popupDismissTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final navManager = context.watch<NavigationManager>();
    final bleService = context.watch<BleService>();
    final streamService = context.watch<EspStreamService>();

    final userLoc = navManager.currentLocation ??
        (navManager.activeRoute?.polylinePoints.isNotEmpty == true
            ? navManager.activeRoute!.polylinePoints.first
            : const LatLng(20.9832, 105.8425));

    // Keep Mini Map centered on vehicle with zoom 16.0
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        _miniMapController.moveAndRotate(userLoc, 16.0, -navManager.currentHeading);
      } catch (_) {}
    });

    return Scaffold(
      backgroundColor: const Color(0xFF0B0F17),
      appBar: AppBar(
        backgroundColor: const Color(0xFF131B26),
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
            // Stream Control & FPS Bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF131B26),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: streamService.isStreaming ? const Color(0xFF00F0FF) : Colors.white12),
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
                            streamService.isStreaming ? 'Đang Stream JPEG Zoom x16 sang ESP32' : 'Dừng Stream',
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
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      Column(
                        children: [
                          const Text('FPS THỰC TẾ', style: TextStyle(color: Colors.white54, fontSize: 10, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 2),
                          Text(
                            '${streamService.actualFps.toStringAsFixed(1)} FPS',
                            style: const TextStyle(color: Color(0xFF05FFA1), fontSize: 14, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
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
                            style: const TextStyle(color: Color(0xFF00F0FF), fontSize: 14, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
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
                            style: const TextStyle(color: Color(0xFFFFB800), fontSize: 14, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // =========================================================
            // 1. EXACT 100% REPLICA OF TARGET DESIGN (320x240 Aspect)
            // =========================================================
            Center(
              child: Container(
                width: 350,
                height: 235,
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFF202A36), width: 5),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha(240),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Column(
                  children: [
                    // Top Status Bar: ESP32 BLE (Cyan) | Time (White) | 100% (Green)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Icon(
                                bleService.isConnected ? Icons.bluetooth_connected : Icons.bluetooth,
                                color: const Color(0xFF00F0FF),
                                size: 13,
                              ),
                              const SizedBox(width: 4),
                              const Text(
                                'ysiduc',
                                style: TextStyle(
                                  color: Color(0xFF00F0FF),
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ],
                          ),
                          Text(
                            _getCurrentClock(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const Row(
                            children: [
                              Text(
                                '89%',
                                style: TextStyle(
                                  color: Color(0xFF05FFA1),
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              SizedBox(width: 3),
                              Icon(Icons.battery_5_bar_rounded, color: Color(0xFF05FFA1), size: 14),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),

                    // Main Split Screen Body (50% Map Zoom x16 | 50% HUD Cards)
                    Expanded(
                      child: _showCallPopup
                          ? _buildCallPopup()
                          : _showSmsPopup
                              ? _buildSmsPopup()
                              : _buildSplitView(navManager, streamService, userLoc),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 20),

            // Notification Popups Testing
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF131B26),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'KIỂM THỬ THÔNG BÁO (ANCS POPUP)',
                    style: TextStyle(color: Color(0xFF00F0FF), fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF05FFA1).withAlpha(40),
                            foregroundColor: const Color(0xFF05FFA1),
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            side: const BorderSide(color: Color(0xFF05FFA1)),
                          ),
                          icon: const Icon(Icons.phone_in_talk_rounded, size: 18),
                          label: const Text('Cuộc gọi đến', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                          onPressed: _triggerMockCall,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFFFB800).withAlpha(40),
                            foregroundColor: const Color(0xFFFFB800),
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            side: const BorderSide(color: Color(0xFFFFB800)),
                          ),
                          icon: const Icon(Icons.mark_chat_unread_rounded, size: 18),
                          label: const Text('Tin nhắn SMS', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
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

  /// Split View: Left 50% Live Streamed Map (100% Mirror of ESP32) | Right 50% HUD Cards
  Widget _buildSplitView(NavigationManager navManager, EspStreamService streamService, LatLng userLoc) {
    final step = navManager.currentStep;
    final dist = navManager.distanceToNextManeuver.round() > 0 ? navManager.distanceToNextManeuver.round() : 208;
    final distStr = dist >= 1000 ? '${(dist / 1000).toStringAsFixed(1)}km' : '${dist}m';
    final street = step?.streetName.isNotEmpty == true ? step!.streetName : 'CẦU SÔNG LỪ';
    final speed = navManager.currentSpeedKmh.round();
    final etaMins = navManager.remainingEtaMinutes > 0 ? navManager.remainingEtaMinutes : 11;
    final totalDistKm = navManager.remainingTotalDistance > 0 ? (navManager.remainingTotalDistance / 1000).toStringAsFixed(1) : '5.9';

    final arrivalTime = DateTime.now().add(Duration(minutes: etaMins));
    final arrivalClock = '${arrivalTime.hour.toString().padLeft(2, '0')}:${arrivalTime.minute.toString().padLeft(2, '0')}';

    return Row(
      children: [
        // -----------------------------------------------------------------
        // LEFT 50%: EXACT 1:1 REAL-TIME ESP32 LIVE STREAM (144x208)
        // -----------------------------------------------------------------
        Expanded(
          flex: 1,
          child: Container(
            margin: const EdgeInsets.only(right: 5),
            decoration: BoxDecoration(
              color: const Color(0xFF0B111A),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF00F0FF), width: 1.5),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: streamService.latestJpegBytes != null
                  ? Image.memory(
                      streamService.latestJpegBytes!,
                      fit: BoxFit.fill,
                      gaplessPlayback: true,
                    )
                  : const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          CircularProgressIndicator(color: Color(0xFF00F0FF), strokeWidth: 2),
                          SizedBox(height: 8),
                          Text('Đang stream...', style: TextStyle(color: Colors.white54, fontSize: 11)),
                        ],
                      ),
                    ),
            ),
          ),
        ),

        // -----------------------------------------------------------------
        // RIGHT 50%: HUD NAVIGATION CARDS (Image Target Replica)
        // -----------------------------------------------------------------
        Expanded(
          flex: 1,
          child: Container(
            margin: const EdgeInsets.only(left: 5),
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: const Color(0xFF131B26),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF202D3D), width: 1.2),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Top Row: Maneuver Icon + Distance + Speed
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: const Color(0xFF0E1520),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFF00F0FF), width: 1.8),
                      ),
                      child: Icon(
                        _getTurnIcon(step?.turnCode ?? 6),
                        color: const Color(0xFF00F0FF),
                        size: 28,
                      ),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            distStr,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.w900,
                              height: 1.1,
                            ),
                          ),
                          Text(
                            '$speed km/h',
                            style: const TextStyle(
                              color: Color(0xFF00F0FF),
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                // Middle Row: Upcoming Street Name Pill
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0B111A),
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(color: const Color(0xFF1E293B)),
                  ),
                  child: Text(
                    street.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.left,
                    style: const TextStyle(
                      color: Color(0xFFFFB800),
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),

                // Bottom Row: ETA & Distance
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'DỰ KIẾN',
                          style: TextStyle(color: Color(0xFF64748B), fontSize: 8, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          arrivalClock,
                          style: const TextStyle(
                            color: Color(0xFF00F0FF),
                            fontSize: 15,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '$totalDistKm km',
                          style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 10, fontWeight: FontWeight.w600),
                        ),
                        Text(
                          '$etaMins ph',
                          style: const TextStyle(
                            color: Color(0xFF05FFA1),
                            fontSize: 15,
                            fontWeight: FontWeight.w900,
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
    );
  }

  Widget _buildCallPopup() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF022C22),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.phone_in_talk_rounded, color: Color(0xFF05FFA1), size: 30),
          const SizedBox(height: 4),
          const Text('CUỘC GỌI ĐẾN', style: TextStyle(color: Color(0xFF05FFA1), fontSize: 11, fontWeight: FontWeight.bold)),
          Text(_callerName, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildSmsPopup() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0B192C),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.mark_chat_unread_rounded, color: Color(0xFF00F0FF), size: 30),
          const SizedBox(height: 4),
          Text(_smsSender, style: const TextStyle(color: Color(0xFFFFB800), fontSize: 15, fontWeight: FontWeight.bold)),
          Text(_smsContent, style: const TextStyle(color: Colors.white, fontSize: 11), textAlign: TextAlign.center),
        ],
      ),
    );
  }

  IconData _getTurnIcon(int turnCode) {
    switch (turnCode) {
      case 1:
      case 2:
      case 3:
        return Icons.turn_right_rounded;
      case 4:
        return Icons.u_turn_left_rounded;
      case 5:
      case 6:
      case 7:
        return Icons.turn_left_rounded;
      case 8:
        return Icons.roundabout_right_rounded;
      case 9:
        return Icons.flag_rounded;
      default:
        return Icons.straight_rounded;
    }
  }
}
