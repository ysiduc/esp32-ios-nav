import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../config/simulator_presets.dart';
import 'marquee_text.dart';

/// GIAO DIỆN 4: 80s SYNTHWAVE CASSETTE (Căn chỉnh tọa độ pixel-perfect theo ảnh nền theme_4_bg.png)
class CassetteWaveTheme extends StatelessWidget {
  final DateTime currentTime;
  final SimulatorMockData mockData;

  const CassetteWaveTheme({
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
    final datePart = '$dayOfWeek, $d TH$m ';
    final yearStr = currentTime.year.toString();

    return SizedBox(
      width: 320,
      height: 240,
      child: Stack(
        children: [
          // Lớp dưới: Ảnh nền 320x240 phẳng 2D
          Positioned.fill(
            child: Image.asset(
              'assets/themes/theme_4_bg.png',
              width: 320,
              height: 240,
              fit: BoxFit.cover,
            ),
          ),

          // --- Khu vực Mặt Trời Synthwave (Mặt trời tâm x: 80, y: 51.5, bounds x: 45..115, y: 26..77) ---
          // Giờ HH:mm (Căn giữa ngang trên mặt trời, chỉ hiện HH:mm)
          Positioned(
            left: 20,
            top: 34,
            width: 120,
            child: Text(
              '$hStr:$mStr',
              textAlign: TextAlign.center,
              style: GoogleFonts.righteous(
                fontSize: 36,
                color: Colors.white,
                letterSpacing: -0.5,
                height: 1.0,
                shadows: const [
                  Shadow(color: Color(0xFFEC4899), blurRadius: 10),
                  Shadow(color: Color(0xFFEC4899), blurRadius: 3),
                ],
              ),
            ),
          ),

          // Thứ & Ngày + Năm (Nằm ngay bên dưới mặt trời tại y: 84)
          Positioned(
            left: 16,
            top: 84,
            width: 128,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  datePart,
                  style: GoogleFonts.righteous(
                    color: const Color(0xFF22D3EE),
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                  ),
                ),
                Text(
                  yearStr,
                  style: GoogleFonts.righteous(
                    color: const Color(0xFFFACC15),
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),

          // --- Khung Tin nhắn (Dưới trái: x: 14..149, y: 124..192) ---
          // Tiêu đề MESSAGES (ngay sau icon chat ở x: 20, y: 128)
          Positioned(
            left: 36,
            top: 128,
            child: Text(
              'MESSAGES',
              style: GoogleFonts.righteous(
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
                color: const Color(0xFFF472B6),
                letterSpacing: 0.8,
              ),
            ),
          ),

          // Nội dung tin nhắn (nằm lọt trong khung hồng)
          Positioned(
            left: 22,
            top: 146,
            width: 120,
            height: 42,
            child: Text(
              '${mockData.sender}: "${mockData.message}"',
              style: GoogleFonts.chakraPetch(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: const Color(0xFFA5F3FC),
                height: 1.15,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),

          // --- Cuộn Băng Cassette (Bên phải: x: 168..307, y: 48..174) ---
          // Tên bài hát in hoa trên dải nhãn trên (thả trôi marquee nếu dài)
          Positioned(
            left: 178,
            top: 58,
            child: MarqueeText(
              text: mockData.songTitle.toUpperCase(),
              width: 120,
              textAlign: TextAlign.center,
              style: GoogleFonts.righteous(
                fontSize: 9.5,
                fontWeight: FontWeight.w800,
                color: Colors.white,
                letterSpacing: 0.4,
              ),
            ),
          ),

          // Tên ca sĩ in hoa trên dải nhãn dưới (thả trôi marquee nếu dài)
          Positioned(
            left: 178,
            top: 124,
            child: MarqueeText(
              text: mockData.songArtist.toUpperCase(),
              width: 120,
              textAlign: TextAlign.center,
              style: GoogleFonts.righteous(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                color: Colors.white,
                letterSpacing: 0.4,
              ),
            ),
          ),

          // Thời lượng 01:24 và 03:52 bên dưới thanh tiến trình cyan (chỉ hiện khi có tiến trình bài hát)
          if (mockData.durationSec > 0)
            Positioned(
              left: 172,
              top: 196,
              width: 136,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    mockData.elapsedStr,
                    style: GoogleFonts.righteous(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                      color: const Color(0xFF22D3EE),
                    ),
                  ),
                  Text(
                    mockData.durationStr,
                    style: GoogleFonts.righteous(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                      color: const Color(0xFF22D3EE),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
