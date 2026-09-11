import 'dart:async';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:provider/provider.dart';
import '../services/ble_service.dart';
import '../services/esp_stream_service.dart';
import '../services/navigation_manager.dart';
import '../services/phone_media_service.dart';

class EspPreviewScreen extends StatefulWidget {
  const EspPreviewScreen({super.key});

  @override
  State<EspPreviewScreen> createState() => _EspPreviewScreenState();
}

class _EspPreviewScreenState extends State<EspPreviewScreen> {
  final GlobalKey _streamBoundaryKey = GlobalKey();

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
      final nav = Provider.of<NavigationManager>(context, listen: false);
      nav.sendPreviewPayloadToEsp32();
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
    final mediaService = context.watch<PhoneMediaService>();

    final userLoc = navManager.currentLocation ??
        (navManager.activeRoute?.polylinePoints.isNotEmpty == true
            ? navManager.activeRoute!.polylinePoints.first
            : const LatLng(20.9832, 105.8425));



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
                        children: [
                          // 1/6: * ysiduc
                          Expanded(
                            flex: 1,
                            child: Row(
                              children: [
                                Icon(
                                  bleService.isConnected ? Icons.bluetooth_connected : Icons.bluetooth,
                                  color: const Color(0xFF00F0FF),
                                  size: 11,
                                ),
                                const SizedBox(width: 2),
                                const Text(
                                  '* ysiduc',
                                  style: TextStyle(
                                    color: Color(0xFF00F0FF),
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),

                          // 3/6: Marquee / Current Track Title & Artist
                          Expanded(
                            flex: 3,
                            child: Center(
                              child: Text(
                                mediaService.hasMedia
                                    ? '♫ ${mediaService.songTitle}${mediaService.songArtist.isNotEmpty ? " - ${mediaService.songArtist}" : ""}'
                                    : '-- Chưa phát nhạc --',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: mediaService.hasMedia ? const Color(0xFFFBBF24) : Colors.white38,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),

                          // 1/6: Current Clock
                          Expanded(
                            flex: 1,
                            child: Center(
                              child: Text(
                                _getCurrentClock(),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),

                          // 1/6: Battery & Icon
                          const Expanded(
                            flex: 1,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                Text(
                                  '89%',
                                  style: TextStyle(
                                    color: Color(0xFF05FFA1),
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                SizedBox(width: 2),
                                Icon(Icons.battery_5_bar_rounded, color: Color(0xFF05FFA1), size: 12),
                              ],
                            ),
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

            const SizedBox(height: 14),

            // MapTiler Minimap Style Switcher
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF131B26),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFF00F0FF).withAlpha(60)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.layers_rounded, color: Color(0xFF00F0FF), size: 18),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'MAPTILER MINIMAP',
                          style: TextStyle(color: Color(0xFF00F0FF), fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Style bản đồ thu nhỏ gửi sang ESP32',
                          style: TextStyle(color: Colors.white54, fontSize: 10),
                        ),
                      ],
                    ),
                  ),
                  DropdownButton<String>(
                    value: streamService.streamMapStyle,
                    dropdownColor: const Color(0xFF1E293B),
                    underline: const SizedBox(),
                    icon: const Icon(Icons.arrow_drop_down, color: Color(0xFF00F0FF)),
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                    items: const [
                      DropdownMenuItem(value: 'streets-v2', child: Text('Streets v2')),
                      DropdownMenuItem(value: 'streets-v2-dark', child: Text('Dark v2 (Đêm)')),
                      DropdownMenuItem(value: 'hybrid', child: Text('Hybrid (Vệ tinh)')),
                    ],
                    onChanged: (val) {
                      if (val != null) {
                        setState(() {
                          streamService.streamMapStyle = val;
                        });
                      }
                    },
                  ),
                ],
              ),
            ),

            const SizedBox(height: 14),

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
                  // Real-time iOS Now Playing Detection Status Banner
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0B111A),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: mediaService.hasMedia ? const Color(0xFF05FFA1).withAlpha(140) : Colors.white12,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          mediaService.hasMedia ? Icons.graphic_eq_rounded : Icons.music_off_rounded,
                          color: mediaService.hasMedia ? const Color(0xFF05FFA1) : Colors.white38,
                          size: 20,
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                mediaService.hasMedia ? 'PHÁT HIỆN TỪ IPHONE (REAL-TIME)' : 'CHƯA PHÁT NHẠC TRÊN IPHONE',
                                style: TextStyle(
                                  color: mediaService.hasMedia ? const Color(0xFF05FFA1) : Colors.white38,
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                mediaService.hasMedia
                                    ? '${mediaService.songTitle} - ${mediaService.songArtist}'
                                    : 'Mở Spotify, Apple Music, YouTube hoặc Zing MP3...',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: mediaService.hasMedia ? Colors.white : Colors.white54,
                                  fontSize: 12,
                                  fontWeight: mediaService.hasMedia ? FontWeight.bold : FontWeight.normal,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      ActionChip(
                        avatar: const Icon(Icons.refresh_rounded, size: 14, color: Color(0xFF00F0FF)),
                        backgroundColor: const Color(0xFF00F0FF).withAlpha(25),
                        side: const BorderSide(color: Color(0xFF00F0FF)),
                        label: const Text('Lấy lại nhạc iPhone', style: TextStyle(color: Color(0xFF00F0FF), fontSize: 11, fontWeight: FontWeight.bold)),
                        onPressed: () => mediaService.pollNowPlaying(),
                      ),
                      ActionChip(
                        backgroundColor: const Color(0xFF0E1520),
                        side: const BorderSide(color: Color(0xFF1E293B)),
                        label: const Text('Simulate: Waiting For You', style: TextStyle(color: Colors.white70, fontSize: 11)),
                        onPressed: () => mediaService.setMockSong('Waiting For You', 'MONO'),
                      ),
                      ActionChip(
                        backgroundColor: const Color(0xFF0E1520),
                        side: const BorderSide(color: Color(0xFF1E293B)),
                        label: const Text('Simulate: Nơi Này Có Anh', style: TextStyle(color: Colors.white70, fontSize: 11)),
                        onPressed: () => mediaService.setMockSong('Noi Nay Co Anh', 'Son Tung M-TP'),
                      ),
                      ActionChip(
                        avatar: const Icon(Icons.edit, size: 14, color: Color(0xFF00F0FF)),
                        backgroundColor: const Color(0xFF0E1520),
                        side: const BorderSide(color: Color(0xFF1E293B)),
                        label: const Text('Nhập tùy ý...', style: TextStyle(color: Colors.white70, fontSize: 11)),
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
                  : CustomPaint(
                      painter: StandbyVectorMapPainter(navManager: navManager),
                      size: const Size(144, 208),
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
          child: Builder(
            builder: (context) {
              final hasSong = navManager.currentSongTitle.isNotEmpty && navManager.currentSongTitle != 'CHUA PHAT NHAC';
              return Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        hasSong ? Icons.play_arrow_rounded : Icons.headphones_rounded,
                        color: hasSong ? const Color(0xFFFFB800) : Colors.white38,
                        size: 13,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        hasSong ? 'ĐANG PHÁT' : 'CHƯA PHÁT NHẠC',
                        style: TextStyle(
                          color: hasSong ? const Color(0xFFFFB800) : Colors.white38,
                          fontSize: 9,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    (hasSong ? navManager.currentSongTitle : 'MỞ NHẠC TRÊN IPHONE').toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: hasSong ? Colors.white : Colors.white54,
                      fontSize: 9.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    (hasSong ? navManager.currentSongArtist : 'SPOTIFY / APPLE MUSIC').toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFF94A3B8),
                      fontSize: 8.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 5),
                  // Audio Sound Equalizer visualizer bars
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: (hasSong
                            ? [4, 10, 16, 12, 6, 14, 18, 8, 12, 6]
                            : [2, 2, 2, 2, 2, 2, 2, 2, 2, 2])
                        .map((h) => Container(
                              width: 3.5,
                              height: h.toDouble(),
                              margin: const EdgeInsets.symmetric(horizontal: 1.5),
                              decoration: BoxDecoration(
                                color: hasSong ? const Color(0xFF00F0FF) : const Color(0xFF1E293B),
                                borderRadius: BorderRadius.circular(1.5),
                              ),
                            ))
                        .toList(),
                  ),
                ],
              );
            },
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

class StandbyVectorMapPainter extends CustomPainter {
  final NavigationManager navManager;
  StandbyVectorMapPainter({required this.navManager});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final cx = w / 2.0;
    final cy = h * 0.72;

    // 1. Dark Cyber Navy Background
    final bgPaint = Paint()..color = const Color(0xFF0B111A);
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), bgPaint);

    // 2. Concentric Radar Distance Rings (50m, 100m)
    final radarPaint = Paint()
      ..color = const Color(0xFF142030)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(Offset(cx, cy), 45, radarPaint);
    canvas.drawCircle(Offset(cx, cy), 90, radarPaint);
    canvas.drawLine(Offset(cx - 65, cy), Offset(cx + 65, cy), radarPaint);
    canvas.drawLine(Offset(cx, cy - 110), Offset(cx, cy + 60), radarPaint);

    // 3. Dynamic Vector Route Corridor
    final points = navManager.computeUpcomingRoutePoints();
    final isNav = navManager.isNavigating;
    final turnCode = navManager.currentStep?.turnCode ?? 0;

    if (points.length >= 2) {
      final path = Path();
      for (int i = 0; i < points.length; i++) {
        final px = (cx + points[i][0]).clamp(8.0, w - 8.0);
        final py = (cy - points[i][1]).clamp(28.0, h - 10.0);
        if (i == 0) {
          path.moveTo(px, py);
        } else {
          path.lineTo(px, py);
        }
      }

      // Asphalt casing
      final asphaltPaint = Paint()
        ..color = const Color(0xFF1E293B)
        ..strokeWidth = 10.0
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      canvas.drawPath(path, asphaltPaint);

      // Cyan glow
      final glowPaint = Paint()
        ..color = const Color(0xFF0077B6).withAlpha(180)
        ..strokeWidth = 6.0
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      canvas.drawPath(path, glowPaint);

      // Vibrant core cyan
      final corePaint = Paint()
        ..color = const Color(0xFF00F0FF)
        ..strokeWidth = 3.0
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      canvas.drawPath(path, corePaint);

      // Destination target flag/dot at last point
      final last = points.last;
      final endX = (cx + last[0]).clamp(8.0, w - 8.0);
      final endY = (cy - last[1]).clamp(28.0, h - 10.0);
      canvas.drawCircle(Offset(endX, endY), 5, Paint()..color = const Color(0xFFFACC15));
      canvas.drawCircle(Offset(endX, endY), 2.5, Paint()..color = Colors.white);
    } else {
      // Fallback smooth road corridor
      double endX = cx;
      double endY = 48.0;
      if (turnCode == 5 || turnCode == 6 || turnCode == 7) {
        endX = 22.0;
        endY = 95.0;
      } else if (turnCode == 1 || turnCode == 2 || turnCode == 3) {
        endX = w - 22.0;
        endY = 95.0;
      }

      final curvePath = Path()
        ..moveTo(cx, h)
        ..lineTo(cx, 130)
        ..lineTo(endX, endY);

      canvas.drawPath(
        curvePath,
        Paint()
          ..color = const Color(0xFF1E293B)
          ..strokeWidth = 10.0
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..style = PaintingStyle.stroke,
      );
      canvas.drawPath(
        curvePath,
        Paint()
          ..color = const Color(0xFF00F0FF)
          ..strokeWidth = 3.0
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..style = PaintingStyle.stroke,
      );
      canvas.drawCircle(Offset(endX, endY), 4, Paint()..color = const Color(0xFFFACC15));
    }

    // 4. Vehicle Chevron at cx, cy pointing straight UP
    final chevronPath = Path()
      ..moveTo(cx, cy - 9)
      ..lineTo(cx + 6, cy + 6)
      ..lineTo(cx, cy + 3)
      ..lineTo(cx - 6, cy + 6)
      ..close();
    canvas.drawCircle(Offset(cx, cy), 14, Paint()..color = const Color(0xFF00F0FF).withAlpha(40));
    canvas.drawPath(chevronPath, Paint()..color = const Color(0xFF00F0FF));
    canvas.drawCircle(Offset(cx, cy + 2), 2, Paint()..color = Colors.white);

    // 5. Top HUD Glass Pill Overlay
    final pillRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(8, 6, w - 16, 26),
      const Radius.circular(6),
    );
    canvas.drawRRect(pillRect, Paint()..color = const Color(0xFF0F1724));
    canvas.drawRRect(
      pillRect,
      Paint()
        ..color = const Color(0xFF1E3048)
        ..strokeWidth = 1.0
        ..style = PaintingStyle.stroke,
    );

    // Pill Content
    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    if (isNav) {
      final distM = navManager.distanceToNextManeuver.round();
      final distStr = distM >= 1000 ? '${(distM / 1000.0).toStringAsFixed(1)}km' : '${distM}m';
      textPainter.text = TextSpan(
        text: '➤  $distStr',
        style: const TextStyle(color: Color(0xFFFACC15), fontSize: 11, fontWeight: FontWeight.bold),
      );
    } else {
      textPainter.text = const TextSpan(
        text: 'CHẾ ĐỘ CHỜ - GPS',
        style: TextStyle(color: Color(0xFF94A3B8), fontSize: 10, fontWeight: FontWeight.bold),
      );
    }
    textPainter.layout();
    textPainter.paint(canvas, const Offset(16, 12));

    // GPS Status Dot
    canvas.drawCircle(Offset(w - 18, 19), 3, Paint()..color = isNav ? const Color(0xFF22C55E) : const Color(0xFF00F0FF));
  }

  @override
  bool shouldRepaint(covariant StandbyVectorMapPainter oldDelegate) => true;
}
