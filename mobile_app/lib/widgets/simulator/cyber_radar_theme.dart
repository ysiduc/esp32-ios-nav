import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../config/simulator_presets.dart';
import 'marquee_text.dart';

/// GIAO DIỆN 2: CYBERPUNK NEON HUD (Ảnh nền zoom to khớp 4 góc màn hình, thông báo & nhạc thả trôi)
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
          // Lớp dưới: Ảnh nền 320x240 phóng to khớp 4 góc
          Positioned.fill(
            child: Image.asset(
              'assets/themes/theme_2_bg.png',
              width: 320,
              height: 240,
              fit: BoxFit.cover,
            ),
          ),

          // --- Khung Đồng hồ (Bên trái: x: 12..205, y: 15..165, chỉ hiện HH:mm) ---
          Positioned(
            left: 14,
            top: 38,
            child: Text(
              '$hStr:$mStr',
              style: GoogleFonts.orbitron(
                fontSize: 44,
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
            left: 16,
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

          // --- Khung Tin nhắn (Bên phải: viền hồng nét đứt x: 212..308, y: 27..170) ---
          // Tiêu đề MSG_INCOMING
          Positioned(
            left: 230,
            top: 32,
            child: Text(
              'MSG_INCOMING',
              style: GoogleFonts.orbitron(
                fontSize: 8.0,
                fontWeight: FontWeight.w700,
                color: const Color(0xFFFF007F),
                letterSpacing: 0.8,
              ),
            ),
          ),

          // Tên người gửi & Nội dung tin nhắn (nằm lọt trong khung hồng w: 86, thả trôi)
          Positioned(
            left: 218,
            top: 50,
            width: 86,
            height: 105,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MarqueeText(
                  text: mockData.sender,
                  width: 86,
                  style: GoogleFonts.chakraPetch(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: const Color(0xFFFF007F),
                  ),
                ),
                const SizedBox(height: 3),
                Expanded(
                  child: ClipRect(
                    child: MarqueeText(
                      text: mockData.message,
                      width: 86,
                      style: GoogleFonts.chakraPetch(
                        fontSize: 10.0,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                        height: 1.2,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // --- Thanh Nhạc (Dưới đáy: khung y: 172..232) ---
          // Tên bài hát - Ca sĩ (thả trôi marquee nếu dài hơn 180px)
          Positioned(
            left: 52,
            top: 188,
            child: MarqueeText(
              text: mockData.fullSongTitle,
              width: 180,
              style: GoogleFonts.chakraPetch(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: const Color(0xFF67E8F9),
              ),
            ),
          ),

          // Thời lượng (chỉ hiện khi có tiến trình thực tế)
          if (mockData.durationSec > 0)
            Positioned(
              right: 14,
              top: 188,
              child: Text(
                mockData.timeRatioStr,
                style: GoogleFonts.orbitron(
                  fontSize: 9.0,
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
