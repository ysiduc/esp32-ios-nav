import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../config/simulator_presets.dart';

/// GIAO DIỆN 3: RETRO MACINTOSH PIXEL OS (Lớp nền Image.asset 320x240 + Lớp trên Stack Positioned Text)
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
    final sStr = currentTime.second.toString().padLeft(2, '0');
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

          // --- Thanh Menu Trên Cùng ---
          // Positioned(left: 26, top: 2): "Retro Macintosh/OS"
          Positioned(
            left: 26,
            top: 2,
            child: Text(
              'Retro Macintosh/OS',
              style: GoogleFonts.vt323(
                fontSize: 12,
                color: Colors.black,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),

          // --- Cửa sổ 1 - Đồng hồ (Trên trái) ---
          // Positioned(left: 28, top: 22): Tiêu đề cửa sổ "CLOCK.EXE"
          Positioned(
            left: 28,
            top: 22,
            child: Text(
              'CLOCK.EXE',
              style: GoogleFonts.vt323(
                fontSize: 10,
                color: Colors.black,
              ),
            ),
          ),

          // Positioned(left: 22, top: 40): Giờ HH:mm + Giây ss
          Positioned(
            left: 22,
            top: 40,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  '$hStr:$mStr',
                  style: GoogleFonts.vt323(
                    fontSize: 38,
                    color: Colors.black,
                    fontWeight: FontWeight.w900,
                    height: 1.0,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  sStr,
                  style: GoogleFonts.vt323(
                    fontSize: 20,
                    color: const Color(0xFF4B5563),
                    fontWeight: FontWeight.w700,
                    height: 1.0,
                  ),
                ),
              ],
            ),
          ),

          // Positioned(left: 34, top: 82): Ngày 09/11/2026\nMONDAY
          Positioned(
            left: 34,
            top: 82,
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

          // --- Cửa sổ 2 - Tin nhắn (Dưới trái) ---
          // Positioned(left: 28, top: 132): Tiêu đề "MAIL.APP"
          Positioned(
            left: 28,
            top: 132,
            child: Text(
              'MAIL.APP',
              style: GoogleFonts.vt323(
                fontSize: 10,
                color: Colors.black,
              ),
            ),
          ),

          // Positioned(left: 44, top: 152): "From: Vợ"
          Positioned(
            left: 44,
            top: 152,
            child: Text(
              'From: ${mockData.sender}',
              style: GoogleFonts.vt323(
                fontSize: 12,
                color: Colors.black,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),

          // Positioned(left: 18, top: 174, width: 118, height: 48): Nội dung tin nhắn
          Positioned(
            left: 18,
            top: 174,
            width: 118,
            height: 48,
            child: Text(
              mockData.message,
              style: GoogleFonts.vt323(
                fontSize: 11.5,
                color: Colors.black,
                height: 1.15,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),

          // --- Cửa sổ 3 - Nhạc (Bên phải) ---
          // Positioned(left: 182, top: 53): Tiêu đề "PLAYER.EXE"
          Positioned(
            left: 182,
            top: 53,
            child: Text(
              'PLAYER.EXE',
              style: GoogleFonts.vt323(
                fontSize: 10,
                color: Colors.black,
              ),
            ),
          ),

          // Positioned(left: 170, top: 70, width: 136): Tên bài hát chạy chữ
          Positioned(
            left: 170,
            top: 70,
            width: 136,
            child: Text(
              mockData.fullSongTitle,
              style: GoogleFonts.vt323(
                fontSize: 11,
                color: Colors.white,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),

          // Positioned(left: 242, top: 156): Thời lượng 01:24 / 03:52
          Positioned(
            left: 242,
            top: 156,
            child: Text(
              mockData.timeRatioStr,
              style: GoogleFonts.vt323(
                fontSize: 10,
                color: Colors.black,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
