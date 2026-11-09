import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../config/simulator_presets.dart';

/// GIAO DIỆN 2: CYBERPUNK NEON HUD (Lớp nền Image.asset 320x240 + Lớp trên Stack Positioned Text)
class CyberRadarTheme extends StatelessWidget {
  final DateTime currentTime;
  final SimulatorMockData mockData;

  const CyberRadarTheme({
    super.key,
    required this.currentTime,
    this.mockData = SimulatorMockData.defaultPreset,
  });

  @override
  Widget build(BuildContext context) {
    final hStr = currentTime.hour.toString().padLeft(2, '0');
    final mStr = currentTime.minute.toString().padLeft(2, '0');
    final sStr = currentTime.second.toString().padLeft(2, '0');
    final dayOfWeek = currentTime.weekday == 7 ? 'CN' : 'T${currentTime.weekday + 1}';
    final d = currentTime.day.toString().padLeft(2, '0');
    final m = currentTime.month.toString().padLeft(2, '0');
    final y = currentTime.year.toString();
    final dateStr = '$dayOfWeek, $d.$m.$y';

    return SizedBox(
      width: 320,
      height: 240,
      child: Stack(
        children: [
          // Lớp dưới: Ảnh nền 320x240 phẳng 2D
          Positioned.fill(
            child: Image.asset(
              'assets/themes/theme_2_bg.png',
              width: 320,
              height: 240,
              fit: BoxFit.cover,
            ),
          ),

          // --- Khung Đồng hồ (Bên trái) ---
          // Positioned(left: 22, top: 44): Giờ HH:mm (GoogleFonts.orbitron) + Giây ss
          Positioned(
            left: 22,
            top: 44,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  '$hStr:$mStr',
                  style: GoogleFonts.orbitron(
                    fontSize: 42,
                    fontWeight: FontWeight.w900,
                    color: const Color(0xFF00F0FF),
                    letterSpacing: -1,
                    shadows: const [
                      Shadow(color: Color(0xFF00F0FF), blurRadius: 14),
                      Shadow(color: Color(0xFF00F0FF), blurRadius: 4),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  sStr,
                  style: GoogleFonts.orbitron(
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    color: const Color(0xFFFF007F),
                    shadows: const [
                      Shadow(color: Color(0xFFFF007F), blurRadius: 10),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Positioned(left: 24, top: 116): Ngày T2, 09.11.2026
          Positioned(
            left: 24,
            top: 116,
            child: Text(
              dateStr,
              style: GoogleFonts.chakraPetch(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: const Color(0xFF67E8F9),
                letterSpacing: 1.0,
              ),
            ),
          ),

          // --- Khung Tin nhắn (Bên phải) ---
          // Positioned(left: 222, top: 31): "MSG_INCOMING"
          Positioned(
            left: 222,
            top: 31,
            child: Text(
              'MSG_INCOMING',
              style: GoogleFonts.orbitron(
                fontSize: 8.5,
                fontWeight: FontWeight.w700,
                color: const Color(0xFFFF007F),
                letterSpacing: 0.8,
              ),
            ),
          ),

          // Positioned(left: 208, top: 54, width: 92, height: 100): Nội dung tin nhắn
          Positioned(
            left: 208,
            top: 54,
            width: 92,
            height: 100,
            child: Text(
              '${mockData.sender}: "${mockData.message}"',
              style: GoogleFonts.chakraPetch(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.white,
                height: 1.25,
              ),
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
            ),
          ),

          // --- Thanh Nhạc (Dưới đáy) ---
          // Positioned(left: 56, top: 196, width: 175): Tên bài hát - Ca sĩ
          Positioned(
            left: 56,
            top: 196,
            width: 175,
            child: Text(
              mockData.fullSongTitle,
              style: GoogleFonts.chakraPetch(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: const Color(0xFF67E8F9),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),

          // Positioned(right: 16, top: 196): Thời lượng 01:24 / 03:52
          Positioned(
            right: 16,
            top: 196,
            child: Text(
              mockData.timeRatioStr,
              style: GoogleFonts.orbitron(
                fontSize: 9.5,
                fontWeight: FontWeight.w700,
                color: const Color(0xFFFB923C),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
