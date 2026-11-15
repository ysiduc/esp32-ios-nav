import 'dart:io';

import 'package:flutter/material.dart';

import '../../models/custom_theme_model.dart';

/// Renders an imported ZIP custom theme identically on the 320x240 simulator canvas.
class DynamicCustomTheme extends StatelessWidget {
  final String bgImagePath;
  final CustomThemeSpec spec;
  final String formattedTime;
  final DateTime now;
  final String songTitle;
  final int songElapsedSec;
  final int songDurationSec;
  final String notifTitle;
  final String notifMsg;

  const DynamicCustomTheme({
    super.key,
    required this.bgImagePath,
    required this.spec,
    required this.formattedTime,
    required this.now,
    required this.songTitle,
    required this.songElapsedSec,
    required this.songDurationSec,
    required this.notifTitle,
    required this.notifMsg,
  });

  String _formatDate() {
    const vnDays = [
      'THỨ HAI',
      'THỨ BA',
      'THỨ TƯ',
      'THỨ NĂM',
      'THỨ SÁU',
      'THỨ BẢY',
      'CHỦ NHẬT',
    ];
    const enDays = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];
    const enMonths = [
      'JAN',
      'FEB',
      'MAR',
      'APR',
      'MAY',
      'JUN',
      'JUL',
      'AUG',
      'SEP',
      'OCT',
      'NOV',
      'DEC',
    ];
    final wd = (now.weekday - 1).clamp(0, 6);
    final dd = now.day.toString().padLeft(2, '0');
    final mm = now.month.toString().padLeft(2, '0');
    switch (spec.date.format) {
      case 'dmy_dot':
        final tNum = now.weekday == 7 ? 0 : now.weekday + 1;
        return 'T$tNum, $dd.$mm.${now.year}';
      case 'dmy_slash':
        return '$dd/$mm/${now.year}';
      case 'en_upper':
        final mon = enMonths[(now.month - 1).clamp(0, 11)];
        return '${enDays[wd]} $mon $dd';
      case 'vn_short':
      default:
        return '${vnDays[wd]}, $dd/$mm';
    }
  }

  String _mmss(int sec) {
    final s = sec < 0 ? 0 : sec;
    final m = (s ~/ 60).toString().padLeft(2, '0');
    final rem = (s % 60).toString().padLeft(2, '0');
    return '$m:$rem';
  }

  @override
  Widget build(BuildContext context) {
    final bgColor = CustomThemeSpec.parseColor(
      spec.bgColor,
      const Color(0xFF0B111A),
    );
    final bgFile = bgImagePath.isNotEmpty ? File(bgImagePath) : null;
    final hasBgFile = bgFile != null && bgFile.existsSync();

    return FittedBox(
      fit: BoxFit.contain,
      child: SizedBox(
        width: 320,
        height: 240,
        child: Container(
          color: bgColor,
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              if (hasBgFile)
                Positioned.fill(
                  child: Image.file(
                    bgFile,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                  ),
                ),

              // Decorative boxes & borders
              for (final box in spec.boxes)
                Positioned(
                  left: box.x,
                  top: box.y,
                  width: box.w,
                  height: box.h,
                  child: Container(
                    decoration: BoxDecoration(
                      color: (box.fill != null && box.fill!.isNotEmpty)
                          ? CustomThemeSpec.parseColor(
                              box.fill,
                              Colors.transparent,
                            ).withValues(alpha: 0.78)
                          : null,
                      borderRadius: BorderRadius.circular(box.r),
                      border: (box.border != null && box.border!.isNotEmpty)
                          ? Border.all(
                              color: CustomThemeSpec.parseColor(
                                box.border,
                                Colors.white30,
                              ),
                              width: 1,
                            )
                          : null,
                    ),
                  ),
                ),

              // Static labels
              for (final lbl in spec.labels)
                if (lbl.visible && lbl.text.isNotEmpty)
                  Positioned(
                    left: lbl.center ? lbl.x - lbl.maxW / 2 : lbl.x,
                    top: lbl.y,
                    width: lbl.maxW,
                    child: Text(
                      lbl.text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: lbl.center ? TextAlign.center : TextAlign.left,
                      style: TextStyle(
                        color: CustomThemeSpec.parseColor(
                          lbl.color,
                          Colors.white,
                        ),
                        fontSize: lbl.fontSize,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),

              // Clock
              if (spec.clock.visible)
                Positioned(
                  left: spec.clock.center ? 0 : spec.clock.x,
                  right: spec.clock.center ? 0 : null,
                  top: spec.clock.y,
                  child: Text(
                    formattedTime,
                    textAlign:
                        spec.clock.center ? TextAlign.center : TextAlign.left,
                    style: TextStyle(
                      color: CustomThemeSpec.parseColor(
                        spec.clock.color,
                        const Color(0xFFFACC15),
                      ),
                      fontSize: spec.clock.fontSize,
                      fontWeight: FontWeight.w800,
                      fontFamily:
                          spec.clock.font.toLowerCase().contains('7seg') ||
                                  spec.clock.font.toLowerCase().contains('mono')
                              ? 'monospace'
                              : null,
                      height: 1.0,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),

              // Date
              if (spec.date.visible)
                Positioned(
                  left: spec.date.center ? 0 : spec.date.x,
                  right: spec.date.center ? 0 : null,
                  top: spec.date.y,
                  child: Text(
                    _formatDate(),
                    textAlign:
                        spec.date.center ? TextAlign.center : TextAlign.left,
                    style: TextStyle(
                      color: CustomThemeSpec.parseColor(
                        spec.date.color,
                        Colors.white,
                      ),
                      fontSize: spec.date.fontSize,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),

              // Music title (when not using bottom waybar)
              if (spec.song.visible &&
                  !spec.showWaybar &&
                  songTitle.isNotEmpty)
                Positioned(
                  left: spec.song.x,
                  top: spec.song.y,
                  width: spec.song.w,
                  child: Text(
                    songTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: CustomThemeSpec.parseColor(
                        spec.song.color,
                        const Color(0xFFFEF08A),
                      ),
                      fontSize: spec.song.fontSize,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),

              // Music duration
              if (spec.duration.visible &&
                  !spec.showWaybar &&
                  songDurationSec > 0)
                Positioned(
                  left: spec.duration.x,
                  top: spec.duration.y,
                  child: _buildDurationWidget(),
                ),

              // Notification title + body
              if (notifTitle.isNotEmpty && spec.notifTitle.visible)
                Positioned(
                  left: spec.notifTitle.x,
                  top: spec.notifTitle.y,
                  width: spec.notifTitle.maxW,
                  child: Text(
                    notifTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: CustomThemeSpec.parseColor(
                        spec.notifTitle.color,
                        const Color(0xFFFACC15),
                      ),
                      fontSize: spec.notifTitle.fontSize,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              if (notifMsg.isNotEmpty && spec.notifMsg.visible)
                Positioned(
                  left: spec.notifMsg.x,
                  top: spec.notifMsg.y,
                  width: spec.notifMsg.maxW,
                  child: Text(
                    notifMsg,
                    maxLines: spec.notifMsg.maxLines,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: CustomThemeSpec.parseColor(
                        spec.notifMsg.color,
                        Colors.white,
                      ),
                      fontSize: spec.notifMsg.fontSize,
                      height: (spec.notifMsg.lineHeight / spec.notifMsg.fontSize)
                          .clamp(1.1, 1.8),
                    ),
                  ),
                ),

              // Optional bottom Waybar
              if (spec.showWaybar)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: 24,
                  child: Container(
                    decoration: const BoxDecoration(
                      color: Color(0xFF0F172A),
                      border: Border(
                        top: BorderSide(color: Color(0xFF334155), width: 1),
                      ),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 50,
                          child: Text(
                            formattedTime,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        Container(
                          width: 1,
                          height: 14,
                          color: const Color(0xFF334155),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            songTitle.isNotEmpty ? songTitle : 'Nhac tat',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFFFEF08A),
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
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

  Widget _buildDurationWidget() {
    final el = _mmss(songElapsedSec);
    final dur = _mmss(songDurationSec);
    final primary = CustomThemeSpec.parseColor(
      spec.duration.color,
      const Color(0xFFFB923C),
    );
    final secondary = CustomThemeSpec.parseColor(
      spec.duration.secondaryColor,
      Colors.white,
    );

    if (spec.duration.mode == 'split') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            el,
            style: TextStyle(
              color: primary,
              fontSize: spec.duration.fontSize,
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(
            dur,
            style: TextStyle(
              color: secondary,
              fontSize: spec.duration.fontSize,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );
    }

    final text = spec.duration.mode == 'elapsed' ? el : '$el / $dur';
    return Text(
      text,
      style: TextStyle(
        color: primary,
        fontSize: spec.duration.fontSize,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}
