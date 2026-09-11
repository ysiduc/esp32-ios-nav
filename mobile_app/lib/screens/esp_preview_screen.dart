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

            // Music & Standby Control
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF131B26),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF00F0FF).withAlpha(60)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.music_note_rounded, color: Color(0xFF00F0FF), size: 16),
                          SizedBox(width: 6),
                          Text(
                            'ĐIỀU KHIỂN NHẠC & CHẾ ĐỘ MÀN HÌNH',
                            style: TextStyle(color: Color(0xFF00F0FF), fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: navManager.isNavigating ? const Color(0xFF00F0FF).withAlpha(30) : const Color(0xFF05FFA1).withAlpha(30),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: navManager.isNavigating ? const Color(0xFF00F0FF) : const Color(0xFF05FFA1)),
                        ),
                        child: Text(
                          navManager.isNavigating ? 'DẪN ĐƯỜNG' : 'CHẾ ĐỘ CHỜ',
                          style: TextStyle(
                            color: navManager.isNavigating ? const Color(0xFF00F0FF) : const Color(0xFF05FFA1),
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Đang phát: ${navManager.currentSongTitle} - ${navManager.currentSongArtist}',
                    style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      ActionChip(
                        backgroundColor: const Color(0xFF0E1520),
                        side: const BorderSide(color: Color(0xFF1E293B)),
                        label: const Text('Waiting For You - MONO', style: TextStyle(color: Colors.white70, fontSize: 11)),
                        onPressed: () => navManager.setSong('Waiting For You', 'MONO'),
                      ),
                      ActionChip(
                        backgroundColor: const Color(0xFF0E1520),
                        side: const BorderSide(color: Color(0xFF1E293B)),
                        label: const Text('Nơi Này Có Anh - M-TP', style: TextStyle(color: Colors.white70, fontSize: 11)),
                        onPressed: () => navManager.setSong('Noi Nay Co Anh', 'Son Tung M-TP'),
                      ),
                      ActionChip(
                        backgroundColor: const Color(0xFF0E1520),
                        side: const BorderSide(color: Color(0xFF1E293B)),
                        label: const Text('Cắt Đôi Nỗi Sầu - TDT', style: TextStyle(color: Colors.white70, fontSize: 11)),
                        onPressed: () => navManager.setSong('Cat Doi Noi Sau', 'Tang Duy Tan'),
                      ),
                      ActionChip(
                        avatar: const Icon(Icons.edit, size: 14, color: Color(0xFF00F0FF)),
                        backgroundColor: const Color(0xFF00F0FF).withAlpha(30),
                        side: const BorderSide(color: Color(0xFF00F0FF)),
                        label: const Text('Đổi bài hát...', style: TextStyle(color: Color(0xFF00F0FF), fontSize: 11, fontWeight: FontWeight.bold)),
                        onPressed: () => _showEditSongDialog(context, navManager),
                      ),
                    ],
                  ),
                  if (navManager.isNavigating) ...[
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.redAccent,
                          side: const BorderSide(color: Colors.redAccent),
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        icon: const Icon(Icons.stop_rounded, size: 16),
                        label: const Text('Dừng dẫn đường (Về chế độ chờ)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                        onPressed: () => navManager.stopNavigation(),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 14),

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

  void _showEditSongDialog(BuildContext context, NavigationManager navManager) {
    final titleCtrl = TextEditingController(text: navManager.currentSongTitle);
    final artistCtrl = TextEditingController(text: navManager.currentSongArtist);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF131B26),
        title: const Text('Đổi bài hát đang phát', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleCtrl,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Tên bài hát',
                labelStyle: TextStyle(color: Color(0xFF00F0FF)),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF00F0FF))),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: artistCtrl,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Tên ca sĩ / nghệ sĩ',
                labelStyle: TextStyle(color: Color(0xFF00F0FF)),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF00F0FF))),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Hủy', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00F0FF),
              foregroundColor: Colors.black,
            ),
            onPressed: () {
              if (titleCtrl.text.trim().isNotEmpty) {
                navManager.setSong(titleCtrl.text.trim(), artistCtrl.text.trim());
              }
              Navigator.pop(ctx);
            },
            child: const Text('Cập nhật', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  String _getCurrentClock() {
    final now = DateTime.now();
    final h = now.hour.toString().padLeft(2, '0');
    final m = now.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  /// Split View: Left 50% Live Streamed Map (100% Mirror of ESP32) | Right 50% Standby Dashboard or Nav HUD
  Widget _buildSplitView(NavigationManager navManager, EspStreamService streamService, LatLng userLoc) {
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
        // RIGHT 50%: HUD NAVIGATION CARDS OR STANDBY MUSIC / CLOCK DASHBOARD
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
            child: !navManager.isNavigating
                ? _buildStandbyDashboard(navManager)
                : _buildNavigationHud(navManager),
          ),
        ),
      ],
    );
  }

  /// Standby Dashboard (Idle Mode): Clock, ysiduc, Current Song & Artist, Equalizer
  Widget _buildStandbyDashboard(NavigationManager navManager) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // 1. Large Elegant Digital Clock
        Text(
          _getCurrentClock(),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 26,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.0,
            height: 1.0,
          ),
        ),

        // 2. Driver / Branding Tag: * ysiduc
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: const Color(0xFF0E1520),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: const Color(0xFF0084FF), width: 1.2),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.bluetooth, color: Color(0xFF00F0FF), size: 12),
              SizedBox(width: 4),
              Text(
                'ysiduc',
                style: TextStyle(
                  color: Color(0xFF00F0FF),
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),

        // 3. Media / Music Player Card
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFF0B111A),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF1E293B)),
          ),
          child: Column(
            children: [
              const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.play_arrow_rounded, color: Color(0xFFFFB800), size: 13),
                  SizedBox(width: 3),
                  Text(
                    'ĐANG PHÁT',
                    style: TextStyle(
                      color: Color(0xFFFFB800),
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                navManager.currentSongTitle.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                navManager.currentSongArtist.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFF94A3B8),
                  fontSize: 9,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 5),
              // Audio Sound Equalizer visualizer bars
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [4, 10, 16, 12, 6, 14, 18, 8, 12, 6]
                    .map((h) => Container(
                          width: 3.5,
                          height: h.toDouble(),
                          margin: const EdgeInsets.symmetric(horizontal: 1.5),
                          decoration: BoxDecoration(
                            color: const Color(0xFF00F0FF),
                            borderRadius: BorderRadius.circular(1.5),
                          ),
                        ))
                    .toList(),
              ),
            ],
          ),
        ),

        // 4. Bottom Standby Status
        const Text(
          'SẴN SÀNG DI CHUYỂN',
          style: TextStyle(
            color: Color(0xFF05FFA1),
            fontSize: 10,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }

  /// Active Navigation Turn Maneuver HUD
  Widget _buildNavigationHud(NavigationManager navManager) {
    final step = navManager.currentStep;
    final dist = navManager.distanceToNextManeuver.round() > 0 ? navManager.distanceToNextManeuver.round() : 208;
    final distStr = dist >= 1000 ? '${(dist / 1000).toStringAsFixed(1)}km' : '${dist}m';
    final street = step?.streetName.isNotEmpty == true ? step!.streetName : 'CẦU SÔNG LỪ';
    final speed = navManager.currentSpeedKmh.round();
    final etaMins = navManager.remainingEtaMinutes > 0 ? navManager.remainingEtaMinutes : 11;
    final totalDistKm = navManager.remainingTotalDistance > 0 ? (navManager.remainingTotalDistance / 1000).toStringAsFixed(1) : '5.9';

    final arrivalTime = DateTime.now().add(Duration(minutes: etaMins));
    final arrivalClock = '${arrivalTime.hour.toString().padLeft(2, '0')}:${arrivalTime.minute.toString().padLeft(2, '0')}';

    return Column(
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
