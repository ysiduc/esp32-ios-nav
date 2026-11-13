import 'package:flutter/material.dart';

import '../../services/ble_service.dart';
import '../../services/esp_stream_service.dart';
import '../../services/navigation_manager.dart';
import '../../services/phone_call_service.dart';
import '../../services/phone_media_service.dart';

/// Live 320x240 Màn 2 (App Idle Map / Active Nav Stream) replica matching display_ui.h.
class EspMan2Preview extends StatelessWidget {
  final BleService bleService;
  final EspStreamService streamService;
  final NavigationManager navManager;
  final PhoneMediaService mediaService;
  final PhoneCallService callService;
  final DateTime currentTime;

  const EspMan2Preview({
    super.key,
    required this.bleService,
    required this.streamService,
    required this.navManager,
    required this.mediaService,
    required this.callService,
    required this.currentTime,
  });

  @override
  Widget build(BuildContext context) {
    final clockStr =
        '${currentTime.hour.toString().padLeft(2, '0')}:${currentTime.minute.toString().padLeft(2, '0')}';

    // When actively navigating and ESP stream has full-frame JPEG, show full-screen live map
    if (navManager.isNavigating && streamService.latestJpegBytes != null) {
      return FittedBox(
        fit: BoxFit.contain,
        child: SizedBox(
          width: 320,
          height: 240,
          child: Image.memory(
            streamService.latestJpegBytes!,
            fit: BoxFit.fill,
            gaplessPlayback: true,
          ),
        ),
      );
    }

    return FittedBox(
      fit: BoxFit.contain,
      child: SizedBox(
        width: 320,
        height: 240,
        child: Container(
          color: Colors.black,
          padding: const EdgeInsets.all(6),
          child: Row(
            children: [
              // Left panel: 144x224 Minimap (matches display_ui.h Màn 2 left column)
              SizedBox(
                width: 146,
                height: 228,
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF0B111A),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: const Color(0xFF00F0FF),
                      width: 1.4,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(9),
                    child: streamService.latestJpegBytes != null
                        ? Image.memory(
                            streamService.latestJpegBytes!,
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                          )
                        : CustomPaint(
                            painter: _StandbyGridPainter(
                              zoom: streamService.minimapZoom,
                              mapStyle: streamService.streamMapStyle,
                            ),
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 6),

              // Right panel: HUD Card (Clock, BLE badge, Media pill, ANCS Notification box)
              Expanded(
                child: Container(
                  height: 228,
                  padding: const EdgeInsets.fromLTRB(7, 8, 7, 7),
                  decoration: BoxDecoration(
                    color: const Color(0xFF131B26),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: const Color(0xFF202D3D),
                      width: 1.2,
                    ),
                  ),
                  child: Column(
                    children: [
                      // Clock
                      Text(
                        clockStr,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          height: 1.0,
                          letterSpacing: 1.0,
                        ),
                      ),
                      const SizedBox(height: 5),

                      // Device BLE status tag
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0B111A),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: bleService.isConnected
                                ? const Color(0xFF00F0FF)
                                : const Color(0xFF334155),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              bleService.isConnected
                                  ? Icons.bluetooth_connected_rounded
                                  : Icons.bluetooth_disabled_rounded,
                              size: 11,
                              color: bleService.isConnected
                                  ? const Color(0xFF00F0FF)
                                  : const Color(0xFF64748B),
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                bleService.customBleName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: bleService.isConnected
                                      ? const Color(0xFF00F0FF)
                                      : const Color(0xFF94A3B8),
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),

                      // Music Pill (x164 y80 w146 h40)
                      Container(
                        height: 38,
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0B111A),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFF1E293B)),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              mediaService.isPlaying
                                  ? Icons.graphic_eq_rounded
                                  : Icons.music_note_rounded,
                              size: 14,
                              color: mediaService.hasMedia
                                  ? const Color(0xFF38BDF8)
                                  : const Color(0xFF64748B),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                mediaService.hasMedia
                                    ? (mediaService.songArtist.isNotEmpty
                                        ? '${mediaService.songTitle} - ${mediaService.songArtist}'
                                        : mediaService.songTitle)
                                    : 'Chưa phát nhạc',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: mediaService.hasMedia
                                      ? const Color(0xFFFEF08A)
                                      : const Color(0xFF64748B),
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),

                      // Notification Box (x164 y124 w146 h106)
                      Expanded(
                        child: _buildNotifCard(),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNotifCard() {
    final isCall = callService.isRinging;
    final hasSms = callService.showSmsNotification;
    final hasNotif = isCall || hasSms;

    final borderColor = isCall
        ? const Color(0xFF22C55E)
        : (hasSms ? const Color(0xFFFACC15) : const Color(0xFF1E293B));

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFF0B111A),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor, width: isCall ? 1.5 : 1),
      ),
      child: !hasNotif
          ? const Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.notifications_none_rounded,
                  color: Color(0xFF475569),
                  size: 22,
                ),
                SizedBox(height: 6),
                Text(
                  'Chưa có thông báo',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFF64748B),
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color: isCall
                            ? const Color(0xFF22C55E)
                            : const Color(0xFF0EA5E9),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        isCall
                            ? Icons.call_rounded
                            : Icons.chat_bubble_rounded,
                        size: 11,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        isCall
                            ? callService.callerName
                            : callService.lastSmsSender,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isCall
                              ? const Color(0xFF4ADE80)
                              : const Color(0xFFFACC15),
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const Divider(
                  height: 10,
                  color: Color(0xFF1C2634),
                  thickness: 1,
                ),
                Expanded(
                  child: Text(
                    isCall
                        ? (callService.phoneNumber.isNotEmpty
                            ? 'Cuộc gọi đến\n${callService.phoneNumber}'
                            : 'Cuộc gọi đến\nĐang đổ chuông...')
                        : callService.lastSmsMessage,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _StandbyGridPainter extends CustomPainter {
  final int zoom;
  final String mapStyle;

  const _StandbyGridPainter({
    required this.zoom,
    required this.mapStyle,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final isDark = mapStyle.contains('dark') || mapStyle == 'hybrid';
    final bgPaint = Paint()
      ..color = isDark ? const Color(0xFF0D1624) : const Color(0xFF162436);
    canvas.drawRect(Offset.zero & size, bgPaint);

    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.08)
      ..strokeWidth = 1;

    const step = 22.0;
    for (double x = 0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (double y = 0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    // Center navigation chevron preview
    final cx = size.width / 2;
    final cy = size.height / 2;
    final arrowPaint = Paint()
      ..color = const Color(0xFF38BDF8)
      ..style = PaintingStyle.fill;
    final path = Path()
      ..moveTo(cx, cy - 12)
      ..lineTo(cx + 9, cy + 9)
      ..lineTo(cx, cy + 4)
      ..lineTo(cx - 9, cy + 9)
      ..close();
    canvas.drawPath(path, arrowPaint);

    final tp = TextPainter(
      text: TextSpan(
        text: 'Zoom x$zoom\nĐang tải minimap...',
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.65),
          fontSize: 9.5,
          fontWeight: FontWeight.w600,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width - 12);
    tp.paint(canvas, Offset((size.width - tp.width) / 2, cy + 20));
  }

  @override
  bool shouldRepaint(covariant _StandbyGridPainter oldDelegate) =>
      oldDelegate.zoom != zoom || oldDelegate.mapStyle != mapStyle;
}
