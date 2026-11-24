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
      width: 240,
      height: 240,
      child: Stack(
        children: [
          // Lớp dưới: Ảnh nền 240x240 phẳng 2D
          Positioned.fill(
            child: Image.asset(
              'assets/themes/theme_3_bg.png',
              width: 240,
              height: 240,
              fit: BoxFit.cover,
            ),
          ),

          // --- Cửa sổ 1 - Đồng hồ (x: 9..111, y: 34..117) ---
          Positioned(
            left: 9,
            top: 38,
            width: 102,
            child: Text(
              '$hStr:$mStr',
              textAlign: TextAlign.center,
              style: GoogleFonts.vt323(
                fontSize: 32,
                color: Colors.black,
                fontWeight: FontWeight.w900,
                height: 1.0,
              ),
            ),
          ),

          // Ngày tháng tiếng Anh
          Positioned(
            left: 9,
            top: 76,
            width: 102,
            child: Text(
              dateStr,
              textAlign: TextAlign.center,
              style: GoogleFonts.vt323(
                fontSize: 10.5,
                height: 1.1,
                color: Colors.black,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),

          // --- Cửa sổ 2 - Tin nhắn (x: 9..113, y: 144..228) ---
          Positioned(
            left: 34,
            top: 149,
            width: 76,
            child: Text(
              'From: ${mockData.sender}',
              style: GoogleFonts.vt323(
                fontSize: 10.5,
                color: Colors.black,
                fontWeight: FontWeight.bold,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),

          // Nội dung tin nhắn
          Positioned(
            left: 12,
            top: 168,
            width: 98,
            height: 54,
            child: Text(
              mockData.message,
              style: GoogleFonts.vt323(
                fontSize: 10.0,
                color: Colors.black,
                height: 1.15,
              ),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
          ),

          // --- Cửa sổ 3 - Nhạc (Bên phải: thanh đen x: 133..228, y: 61..76) ---
          Positioned(
            left: 135,
            top: 63,
            child: MarqueeText(
              text: mockData.fullSongTitle,
              width: 91,
              style: GoogleFonts.vt323(
                fontSize: 10,
                color: Colors.white,
              ),
            ),
          ),

          // Thời lượng (chỉ hiện khi có tiến trình bài hát)
          if (mockData.durationSec > 0)
            Positioned(
              left: 182,
              top: 148,
              width: 42,
              child: Text(
                mockData.timeRatioStr,
                textAlign: TextAlign.right,
                style: GoogleFonts.vt323(
                  fontSize: 8.5,
                  color: Colors.black,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
