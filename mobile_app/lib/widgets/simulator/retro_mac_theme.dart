import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../config/simulator_presets.dart';
import 'marquee_text.dart';

/// GIAO DIỆN 3: RETRO MACINTOSH PIXEL OS (Căn giữa đồng hồ, thông báo nằm lọt trong ô Mail thả trôi)
class RetroMacTheme extends StatelessWidget {
  final DateTime currentTime;
  final SimulatorMockData mockData;

  const RetroMacTheme({
    super.key,
    required this.currentTime,
    this.mockData = SimulatorMockData.defaultPreset,
  });

  @override
  Widget build(BuildContext context) {
    final hStr = currentTime.hour.toString().padLeft(2, '0');
    final mStr = currentTime.minute.toString().padLeft(2, '0');
    const days = [
      'MONDAY',
      'TUESDAY',
      'WEDNESDAY',
      'THURSDAY',
      'FRIDAY',
      'SATURDAY',
      'SUNDAY'
    ];
    final dayEn = days[currentTime.weekday - 1];
    final d = currentTime.day.toString().padLeft(2, '0');
    final m = currentTime.month.toString().padLeft(2, '0');
    final y = currentTime.year.toString();
    final dateStr = '$d/$m/$y\n$dayEn';

    return SizedBox(
      width: 320,
      height: 240,
      child: Stack(
        children: [
          // Lớp dưới: Ảnh nền 320x240 phẳng 2D
          Positioned.fill(
            child: Image.asset(
              'assets/themes/theme_3_bg.png',
              width: 320,
              height: 240,
              fit: BoxFit.cover,
            ),
          ),

          // --- Cửa sổ 1 - Đồng hồ (Vùng bên trong: x: 9..144, y: 34..118, căn giữa chuẩn) ---
          Positioned(
            left: 9,
            top: 38,
            width: 135,
            child: Text(
              '$hStr:$mStr',
              textAlign: TextAlign.center,
              style: GoogleFonts.vt323(
                fontSize: 40,
                color: Colors.black,
                fontWeight: FontWeight.w900,
                height: 1.0,
              ),
            ),
          ),

          // Ngày tháng tiếng Anh (Căn giữa ngang trong cửa sổ đồng hồ)
          Positioned(
            left: 9,
            top: 82,
            width: 135,
            child: Text(
              dateStr,
              textAlign: TextAlign.center,
              style: GoogleFonts.vt323(
                fontSize: 12,
                height: 1.1,
                color: Colors.black,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),

          // --- Cửa sổ 2 - Tin nhắn (Vùng bên trong: x: 14..146, y: 142..218, thả trôi nếu dài) ---
          // "From: Người gửi" (thả trôi nếu dài hơn 124px)
          Positioned(
            left: 16,
            top: 146,
            child: MarqueeText(
              text: 'From: ${mockData.sender}',
              width: 124,
              style: GoogleFonts.vt323(
                fontSize: 12,
                color: Colors.black,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),

          // Nội dung tin nhắn (Nằm bên dưới phong bì, thả trôi nếu dài hơn 124px)
          Positioned(
            left: 16,
            top: 166,
            width: 124,
            height: 48,
            child: ClipRect(
              child: MarqueeText(
                text: mockData.message,
                width: 124,
                style: GoogleFonts.vt323(
                  fontSize: 11.5,
                  color: Colors.black,
                  height: 1.15,
                ),
              ),
            ),
          ),

          // --- Cửa sổ 3 - Nhạc (Bên phải: thanh đen w: 110) ---
          // Tên bài hát (thả trôi marquee nếu dài hơn 110px)
          Positioned(
            left: 178,
            top: 65,
            child: MarqueeText(
              text: mockData.fullSongTitle,
              width: 110,
              style: GoogleFonts.vt323(
                fontSize: 11,
                color: Colors.white,
              ),
            ),
          ),

          // Thời lượng (chỉ hiện khi có tiến trình bài hát)
          if (mockData.durationSec > 0)
            Positioned(
              left: 226,
              top: 151,
              width: 44,
              child: Text(
                mockData.timeRatioStr,
                textAlign: TextAlign.right,
                style: GoogleFonts.vt323(
                  fontSize: 9.5,
                  color: Colors.black,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
