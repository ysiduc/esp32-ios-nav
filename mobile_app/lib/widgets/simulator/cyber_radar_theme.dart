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
      width: 240,
      height: 240,
      child: Stack(
        children: [
          // Lớp dưới: Ảnh nền 240x240 phóng to khớp 4 góc
          Positioned.fill(
            child: Image.asset(
              'assets/themes/theme_2_bg.png',
              width: 240,
              height: 240,
              fit: BoxFit.cover,
            ),
          ),

          // --- Khung Đồng hồ (Bên trái: x: 4..150, y: 4..176) ---
          Positioned(
            left: 10,
            top: 44,
            width: 134,
            child: Text(
              '$hStr:$mStr',
              textAlign: TextAlign.center,
              style: GoogleFonts.orbitron(
                fontSize: 32,
                fontWeight: FontWeight.w900,
                color: const Color(0xFF00F0FF),
                letterSpacing: -1,
                shadows: const [
                  Shadow(color: Color(0xFF00F0FF), blurRadius: 12),
                  Shadow(color: Color(0xFF00F0FF), blurRadius: 3),
                ],
              ),
            ),
          ),

          // Ngày tháng (bên dưới đồng hồ)
          Positioned(
            left: 10,
            top: 102,
            width: 134,
            child: Text(
              dateStr,
              textAlign: TextAlign.center,
              style: GoogleFonts.chakraPetch(
                fontSize: 9.5,
                fontWeight: FontWeight.w700,
                color: const Color(0xFF67E8F9),
                letterSpacing: 0.7,
              ),
            ),
          ),

          // --- Khung Tin nhắn (Bên phải: x: 158..231, y: 12..170) ---
          Positioned(
            left: 181,
            top: 20,
            child: Text(
              'MSG_INCOMING',
              style: GoogleFonts.orbitron(
                fontSize: 5.5,
                fontWeight: FontWeight.w700,
                color: const Color(0xFFFF007F),
                letterSpacing: 0.4,
              ),
            ),
          ),

          // Tên người gửi
          Positioned(
            left: 162,
            top: 43,
            width: 66,
            child: Text(
              mockData.sender,
              style: GoogleFonts.chakraPetch(
                fontSize: 9.5,
                fontWeight: FontWeight.w700,
                color: const Color(0xFFFF007F),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),

          // Nội dung tin nhắn
          Positioned(
            left: 162,
            top: 58,
            width: 66,
            height: 82,
            child: Text(
              mockData.message,
              style: GoogleFonts.chakraPetch(
                fontSize: 8.5,
                fontWeight: FontWeight.w600,
                color: Colors.white,
                height: 1.2,
              ),
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
            ),
          ),

          // --- Thanh Nhạc (Dưới đáy: x: 4..236, y: 182..234) ---
          Positioned(
            left: 48,
            top: 192,
            child: MarqueeText(
              text: mockData.fullSongTitle,
              width: 112,
              style: GoogleFonts.chakraPetch(
                fontSize: 9.0,
                fontWeight: FontWeight.w700,
                color: const Color(0xFF67E8F9),
              ),
            ),
          ),

          // Thời lượng (chỉ hiện khi có tiến trình thực tế)
          if (mockData.durationSec > 0)
            Positioned(
              right: 10,
              top: 193,
              child: Text(
                mockData.timeRatioStr,
                style: GoogleFonts.orbitron(
                  fontSize: 7.5,
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
