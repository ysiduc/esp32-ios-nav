import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../config/simulator_presets.dart';
import 'marquee_text.dart';

/// GIAO DIỆN 2: CYBERPUNK NEON HUD (Căn chỉnh tọa độ pixel-perfect theo ảnh nền theme_2_bg.png)
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

          // --- Khung Đồng hồ (Bên trái: x: 22..195, y: 24..160, chỉ hiện HH:mm) ---
          Positioned(
            left: 24,
            top: 44,
            child: Text(
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
          ),

          // Ngày tháng (bên dưới đồng hồ)
          Positioned(
            left: 26,
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

          // --- Khung Tin nhắn (Bên phải: viền hồng nét đứt x: 214..303, y: 22..160) ---
          // Tiêu đề MSG_INCOMING (nằm sau icon 💬 ở x: 218)
          Positioned(
            left: 232,
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

          // Nội dung tin nhắn (bắt đầu từ x: 220 để nằm hoàn toàn bên trong khung viền x: 214..303)
          Positioned(
            left: 220,
            top: 52,
            width: 80,
            height: 98,
            child: Text(
              '${mockData.sender}:\n"${mockData.message}"',
              style: GoogleFonts.chakraPetch(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: Colors.white,
                height: 1.25,
              ),
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
            ),
          ),

          // --- Thanh Nhạc (Dưới đáy: khung y: 173..210) ---
          // Tên bài hát - Ca sĩ (thả trôi marquee nếu dài hơn 160px)
          Positioned(
            left: 60,
            top: 178,
            child: MarqueeText(
              text: mockData.fullSongTitle,
              width: 160,
              style: GoogleFonts.chakraPetch(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: const Color(0xFF67E8F9),
              ),
            ),
          ),

          // Thời lượng 01:24 / 03:52 (chỉ hiện khi có tiến trình thực tế)
          if (mockData.durationSec > 0)
            Positioned(
              right: 20,
              top: 178,
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
