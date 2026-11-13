import 'dart:io';

import 'package:flutter/material.dart';

import '../../models/custom_theme_model.dart';
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
  final int man2BuiltInStyle;
  final ImportedCustomTheme? man2CustomTheme;

  const EspMan2Preview({
    super.key,
    required this.bleService,
    required this.streamService,
    required this.navManager,
    required this.mediaService,
    required this.callService,
    required this.currentTime,
    this.man2BuiltInStyle = 0,
    this.man2CustomTheme,
  });

  static const List<String> _vnDays = [
    'Thứ Hai',
    'Thứ Ba',
    'Thứ Tư',
    'Thứ Năm',
    'Thứ Sáu',
    'Thứ Bảy',
    'Chủ Nhật',
  ];

  String _formatDate(String format) {
    final dd = currentTime.day.toString().padLeft(2, '0');
    final mm = currentTime.month.toString().padLeft(2, '0');
    final yyyy = currentTime.year.toString();
    if (format == 'dmy_slash') return '$dd/$mm/$yyyy';
    if (format == 'dmy_dot') {
      final t = currentTime.weekday == 7 ? 0 : currentTime.weekday + 1;
      return 'T$t, $dd.$mm.$yyyy';
    }
    if (format == 'en_upper') {
      const enDays = ['SUN', 'MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT'];
      const enMonths = [
        'JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN',
        'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC',
      ];
      final d = enDays[currentTime.weekday % 7];
      final m = enMonths[(currentTime.month - 1).clamp(0, 11)];
      return '$d $m $dd';
    }
    return '${_vnDays[currentTime.weekday - 1]}, $dd/$mm';
  }

  _Man2RenderSpec _resolveSpec() {
    if (man2CustomTheme != null) {
      final s = man2CustomTheme!.spec;
      final panel = s.panel ??
          const CustomThemeBox(
            x: 158,
            y: 6,
            w: 158,
            h: 228,
            r: 12,
            fill: '#131B26',
            border: '#202D3D',
          );
      final songX = s.song.boxX ?? (panel.x + 6);
      final songY = s.song.boxY ?? 80;
      final songW = s.song.boxW ?? (panel.w - 12);
      final songH = s.song.boxH ?? 40;
      return _Man2RenderSpec(
        screenBg: CustomThemeSpec.parseColor(s.bgColor, const Color(0xFF0B111A)),
        bgImagePath: man2CustomTheme!.bgImagePath,
        mapRect: Rect.fromLTWH(s.minimap.x, s.minimap.y, s.minimap.w, s.minimap.h),
        mapRadius: s.minimap.r,
        mapBorder: CustomThemeSpec.parseColor(s.minimap.border, const Color(0xFF38BDF8)),
        showPanel: s.showPanel,
        panelRect: Rect.fromLTWH(panel.x, panel.y, panel.w, panel.h),
        panelRadius: panel.r,
        panelBg: CustomThemeSpec.parseColor(panel.fill, const Color(0xFF131B26)),
        panelBorder: CustomThemeSpec.parseColor(panel.border, const Color(0xFF202D3D)),
        clockVisible: s.clock.visible,
        clockCenterX: s.clock.center ? s.clock.x : (panel.x + panel.w / 2),
        clockY: s.clock.y,
        clockColor: CustomThemeSpec.parseColor(s.clock.color, Colors.white),
        clockMono: s.clock.font == '7seg',
        dateVisible: s.date.visible,
        dateCenterX: s.date.center ? s.date.x : (panel.x + panel.w / 2),
        dateY: s.date.y,
        dateColor: CustomThemeSpec.parseColor(s.date.color, const Color(0xFF94A3B8)),
        dateFormat: s.date.format,
        songVisible: s.song.visible,
        songRect: Rect.fromLTWH(songX, songY, songW, songH),
        songBg: CustomThemeSpec.parseColor(s.song.bgColor, const Color(0xFF0B111A)),
        songBorder: CustomThemeSpec.parseColor(s.song.border, const Color(0xFF1E293B)),
        songColor: CustomThemeSpec.parseColor(s.song.color, const Color(0xFFFACC15)),
        durColor: CustomThemeSpec.parseColor(s.song.durColor, const Color(0xFF38BDF8)),
        notifVisible: s.notif.visible,
        notifRect: Rect.fromLTWH(s.notif.x, s.notif.y, s.notif.w, s.notif.h),
        notifRadius: s.notif.r,
        notifBg: CustomThemeSpec.parseColor(s.notif.fill, const Color(0xFF0B111A)),
        notifBorder: CustomThemeSpec.parseColor(s.notif.border, const Color(0xFF1E293B)),
        notifTitleColor: CustomThemeSpec.parseColor(s.notif.titleColor, const Color(0xFFFACC15)),
        notifMsgColor: CustomThemeSpec.parseColor(s.notif.msgColor, Colors.white),
      );
    }

    switch (man2BuiltInStyle) {
      case 1: // Neon Cyber Map
        return const _Man2RenderSpec(
          screenBg: Color.fromARGB(255, 5, 7, 20),
          mapRect: Rect.fromLTWH(6, 8, 144, 224),
          mapRadius: 10,
          mapBorder: Color(0xFFEC4899),
          showPanel: true,
          panelRect: Rect.fromLTWH(158, 6, 158, 228),
          panelRadius: 12,
          panelBg: Color.fromARGB(255, 12, 16, 38),
          panelBorder: Color(0xFF00F0FF),
          clockVisible: true,
          clockCenterX: 237,
          clockY: 14,
          clockColor: Color(0xFF00F0FF),
          clockMono: true,
          dateVisible: true,
          dateCenterX: 237,
          dateY: 46,
          dateColor: Color(0xFFC084FC),
          dateFormat: 'vn_short',
          songVisible: true,
          songRect: Rect.fromLTWH(164, 80, 146, 40),
          songBg: Color.fromARGB(255, 9, 12, 28),
          songBorder: Color(0xFFEC4899),
          songColor: Color(0xFF67E8F9),
          durColor: Color(0xFFF472B6),
          notifVisible: true,
          notifRect: Rect.fromLTWH(164, 124, 146, 106),
          notifRadius: 8,
          notifBg: Color.fromARGB(255, 9, 12, 28),
          notifBorder: Color(0xFF00F0FF),
          notifTitleColor: Color(0xFFFACC15),
          notifMsgColor: Colors.white,
        );
      case 2: // Sunflower Warm HUD
        return const _Man2RenderSpec(
          screenBg: Color.fromARGB(255, 18, 14, 10),
          mapRect: Rect.fromLTWH(6, 8, 144, 224),
          mapRadius: 10,
          mapBorder: Color(0xFFFACC15),
          showPanel: true,
          panelRect: Rect.fromLTWH(158, 6, 158, 228),
          panelRadius: 12,
          panelBg: Color.fromARGB(255, 34, 26, 18),
          panelBorder: Color(0xFFD97706),
          clockVisible: true,
          clockCenterX: 237,
          clockY: 14,
          clockColor: Color(0xFFFACC15),
          clockMono: false,
          dateVisible: true,
          dateCenterX: 237,
          dateY: 46,
          dateColor: Color(0xFFFDE68A),
          dateFormat: 'vn_short',
          songVisible: true,
          songRect: Rect.fromLTWH(164, 80, 146, 40),
          songBg: Color.fromARGB(255, 22, 17, 12),
          songBorder: Color(0xFFB45309),
          songColor: Color(0xFFFEF08A),
          durColor: Color(0xFFFB923C),
          notifVisible: true,
          notifRect: Rect.fromLTWH(164, 124, 146, 106),
          notifRadius: 8,
          notifBg: Color.fromARGB(255, 22, 17, 12),
          notifBorder: Color(0xFFD97706),
          notifTitleColor: Color(0xFFFACC15),
          notifMsgColor: Colors.white,
        );
      case 3: // Right-Hand Minimap
        return const _Man2RenderSpec(
          screenBg: Color.fromARGB(255, 7, 12, 16),
          mapRect: Rect.fromLTWH(170, 8, 144, 224),
          mapRadius: 10,
          mapBorder: Color(0xFF10B981),
          showPanel: true,
          panelRect: Rect.fromLTWH(4, 6, 158, 228),
          panelRadius: 12,
          panelBg: Color.fromARGB(255, 14, 22, 30),
          panelBorder: Color.fromARGB(255, 30, 58, 72),
          clockVisible: true,
          clockCenterX: 83,
          clockY: 14,
          clockColor: Colors.white,
          clockMono: false,
          dateVisible: true,
          dateCenterX: 83,
          dateY: 46,
          dateColor: Color(0xFF6EE7B7),
          dateFormat: 'vn_short',
          songVisible: true,
          songRect: Rect.fromLTWH(10, 80, 146, 40),
          songBg: Color.fromARGB(255, 9, 15, 22),
          songBorder: Color(0xFF10B981),
          songColor: Color(0xFFFACC15),
          durColor: Color(0xFF34D399),
          notifVisible: true,
          notifRect: Rect.fromLTWH(10, 124, 146, 106),
          notifRadius: 8,
          notifBg: Color.fromARGB(255, 9, 15, 22),
          notifBorder: Color.fromARGB(255, 30, 58, 72),
          notifTitleColor: Color(0xFFFACC15),
          notifMsgColor: Colors.white,
        );
      case 0:
      default:
        return const _Man2RenderSpec(
          screenBg: Colors.black,
          mapRect: Rect.fromLTWH(6, 8, 144, 224),
          mapRadius: 10,
          mapBorder: Color(0xFF00F0FF),
          showPanel: true,
          panelRect: Rect.fromLTWH(158, 6, 158, 228),
          panelRadius: 12,
          panelBg: Color(0xFF131B26),
          panelBorder: Color(0xFF202D3D),
          clockVisible: true,
          clockCenterX: 237,
          clockY: 14,
          clockColor: Colors.white,
          clockMono: false,
          dateVisible: true,
          dateCenterX: 237,
          dateY: 46,
          dateColor: Color(0xFF94A3B8),
          dateFormat: 'vn_short',
          songVisible: true,
          songRect: Rect.fromLTWH(164, 80, 146, 40),
          songBg: Color(0xFF0B111A),
          songBorder: Color(0xFF1E293B),
          songColor: Color(0xFFFEF08A),
          durColor: Color(0xFF38BDF8),
          notifVisible: true,
          notifRect: Rect.fromLTWH(164, 124, 146, 106),
          notifRadius: 8,
          notifBg: Color(0xFF0B111A),
          notifBorder: Color(0xFF1E293B),
          notifTitleColor: Color(0xFFFACC15),
          notifMsgColor: Colors.white,
        );
    }
  }

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

    final spec = _resolveSpec();
    final hasCustomBg = spec.bgImagePath != null &&
        spec.bgImagePath!.isNotEmpty &&
        File(spec.bgImagePath!).existsSync();

    return FittedBox(
      fit: BoxFit.contain,
      child: SizedBox(
        width: 320,
        height: 240,
        child: Container(
          color: spec.screenBg,
          child: Stack(
            children: [
              if (hasCustomBg)
                Positioned.fill(
                  child: Image.file(
                    File(spec.bgImagePath!),
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                  ),
                ),

              // Minimap panel
              Positioned(
                left: spec.mapRect.left,
                top: spec.mapRect.top,
                width: spec.mapRect.width,
                height: spec.mapRect.height,
                child: Container(
                  decoration: BoxDecoration(
                    color: spec.songBg,
                    borderRadius: BorderRadius.circular(spec.mapRadius),
                    border: Border.all(color: spec.mapBorder, width: 1.4),
                  ),
                  child: ClipRRect(
                    borderRadius:
                        BorderRadius.circular((spec.mapRadius - 1).clamp(0, 24)),
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
                              accentColor: spec.mapBorder,
                            ),
                          ),
                  ),
                ),
              ),

              // Right/Left HUD background card
              if (spec.showPanel)
                Positioned(
                  left: spec.panelRect.left,
                  top: spec.panelRect.top,
                  width: spec.panelRect.width,
                  height: spec.panelRect.height,
                  child: Container(
                    decoration: BoxDecoration(
                      color: spec.panelBg,
                      borderRadius: BorderRadius.circular(spec.panelRadius),
                      border: Border.all(color: spec.panelBorder, width: 1.2),
                    ),
                  ),
                ),

              // Clock
              if (spec.clockVisible)
                Positioned(
                  left: spec.clockCenterX - 75,
                  top: spec.clockY,
                  width: 150,
                  child: Text(
                    clockStr,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: spec.clockColor,
                      fontSize: 27,
                      fontWeight: FontWeight.w800,
                      fontFamily: spec.clockMono ? 'monospace' : null,
                      height: 1.0,
                      letterSpacing: 1.0,
                    ),
                  ),
                ),

              // Date + divider
              if (spec.dateVisible)
                Positioned(
                  left: spec.dateCenterX - 75,
                  top: spec.dateY,
                  width: 150,
                  child: Text(
                    _formatDate(spec.dateFormat),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: spec.dateColor,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              if (spec.showPanel)
                Positioned(
                  left: spec.panelRect.left + 14,
                  top: spec.dateY + 22,
                  width: (spec.panelRect.width - 28).clamp(20, 140),
                  height: 1,
                  child: Container(color: spec.panelBorder),
                ),

              // Music Box
              if (spec.songVisible)
                Positioned(
                  left: spec.songRect.left,
                  top: spec.songRect.top,
                  width: spec.songRect.width,
                  height: spec.songRect.height,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7),
                    decoration: BoxDecoration(
                      color: spec.songBg,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: spec.songBorder),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          mediaService.isPlaying
                              ? Icons.graphic_eq_rounded
                              : Icons.music_note_rounded,
                          size: 13,
                          color: mediaService.hasMedia
                              ? spec.durColor
                              : const Color(0xFF64748B),
                        ),
                        const SizedBox(width: 5),
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
                                  ? spec.songColor
                                  : const Color(0xFF64748B),
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              // Notification Box
              if (spec.notifVisible)
                Positioned(
                  left: spec.notifRect.left,
                  top: spec.notifRect.top,
                  width: spec.notifRect.width,
                  height: spec.notifRect.height,
                  child: _buildNotifCard(spec),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNotifCard(_Man2RenderSpec spec) {
    final isCall = callService.isRinging;
    final hasSms = callService.showSmsNotification;
    final hasNotif = isCall || hasSms;

    final borderColor = isCall
        ? const Color(0xFF22C55E)
        : (hasSms ? spec.notifTitleColor : spec.notifBorder);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(7),
      decoration: BoxDecoration(
        color: spec.notifBg,
        borderRadius: BorderRadius.circular(spec.notifRadius),
        border: Border.all(color: borderColor, width: isCall ? 1.5 : 1),
      ),
      child: !hasNotif
          ? const Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.notifications_none_rounded,
                  color: Color(0xFF475569),
                  size: 20,
                ),
                SizedBox(height: 5),
                Text(
                  'Chưa có thông báo',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFF64748B),
                    fontSize: 9.5,
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
                      width: 17,
                      height: 17,
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
                        size: 10,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 5),
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
                              : spec.notifTitleColor,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const Divider(
                  height: 8,
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
                    style: TextStyle(
                      color: spec.notifMsgColor,
                      fontSize: 9.5,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _Man2RenderSpec {
  final Color screenBg;
  final String? bgImagePath;
  final Rect mapRect;
  final double mapRadius;
  final Color mapBorder;
  final bool showPanel;
  final Rect panelRect;
  final double panelRadius;
  final Color panelBg;
  final Color panelBorder;
  final bool clockVisible;
  final double clockCenterX;
  final double clockY;
  final Color clockColor;
  final bool clockMono;
  final bool dateVisible;
  final double dateCenterX;
  final double dateY;
  final Color dateColor;
  final String dateFormat;
  final bool songVisible;
  final Rect songRect;
  final Color songBg;
  final Color songBorder;
  final Color songColor;
  final Color durColor;
  final bool notifVisible;
  final Rect notifRect;
  final double notifRadius;
  final Color notifBg;
  final Color notifBorder;
  final Color notifTitleColor;
  final Color notifMsgColor;

  const _Man2RenderSpec({
    required this.screenBg,
    this.bgImagePath,
    required this.mapRect,
    required this.mapRadius,
    required this.mapBorder,
    required this.showPanel,
    required this.panelRect,
    required this.panelRadius,
    required this.panelBg,
    required this.panelBorder,
    required this.clockVisible,
    required this.clockCenterX,
    required this.clockY,
    required this.clockColor,
    required this.clockMono,
    required this.dateVisible,
    required this.dateCenterX,
    required this.dateY,
    required this.dateColor,
    required this.dateFormat,
    required this.songVisible,
    required this.songRect,
    required this.songBg,
    required this.songBorder,
    required this.songColor,
    required this.durColor,
    required this.notifVisible,
    required this.notifRect,
    required this.notifRadius,
    required this.notifBg,
    required this.notifBorder,
    required this.notifTitleColor,
    required this.notifMsgColor,
  });
}

class _StandbyGridPainter extends CustomPainter {
  final int zoom;
  final String mapStyle;
  final Color accentColor;

  const _StandbyGridPainter({
    required this.zoom,
    required this.mapStyle,
    required this.accentColor,
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
      ..color = accentColor
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
      oldDelegate.zoom != zoom ||
      oldDelegate.mapStyle != mapStyle ||
      oldDelegate.accentColor != accentColor;
}

