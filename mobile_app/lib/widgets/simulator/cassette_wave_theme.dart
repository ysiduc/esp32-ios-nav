import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../config/simulator_presets.dart';
import 'marquee_text.dart';

/// GIAO DIỆN 4: 80s SYNTHWAVE CASSETTE (Khung đồng hồ tương phản cao, băng cassette sạch đẹp, thả trôi)
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
      width: 240,
      height: 240,
      child: Stack(
        children: [
          // Lớp dưới: Ảnh nền 240x240 phẳng 2D
          Positioned.fill(
            child: Image.asset(
              'assets/themes/theme_4_bg.png',
              width: 240,
              height: 240,
              fit: BoxFit.cover,
            ),
          ),

          // --- Khu vực Mặt Trời Synthwave (4..116, 12..106) ---
          Positioned(
            left: 4,
            top: 32,
            width: 112,
            child: Text(
              '$hStr:$mStr',
              textAlign: TextAlign.center,
              style: GoogleFonts.righteous(
                fontSize: 30,
                color: Colors.white,
                letterSpacing: -0.5,
                height: 1.0,
                shadows: const [
                  Shadow(color: Color(0xFFEC4899), blurRadius: 10),
                  Shadow(color: Color(0xFFEC4899), blurRadius: 3),
                  Shadow(color: Colors.black, blurRadius: 5),
                ],
              ),
            ),
          ),

          // Thứ & Ngày + Năm
          Positioned(
            left: 4,
            top: 82,
            width: 112,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  datePart,
                  style: GoogleFonts.righteous(
                    color: const Color(0xFF22D3EE),
                    fontSize: 9.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.3,
                  ),
                ),
                Text(
                  yearStr,
                  style: GoogleFonts.righteous(
                    color: const Color(0xFFFACC15),
                    fontSize: 9.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),

          // --- Khung Tin nhắn (Dưới trái: x: 12..106, y: 139..191) ---
          Positioned(
            left: 24,
            top: 125,
            child: Text(
              'MESSAGES',
              style: GoogleFonts.righteous(
                fontSize: 8.5,
                fontWeight: FontWeight.w800,
                color: const Color(0xFFF472B6),
                letterSpacing: 0.5,
              ),
            ),
          ),

          // Người gửi
          Positioned(
            left: 14,
            top: 141,
            width: 90,
            child: Text(
              mockData.sender,
              style: GoogleFonts.chakraPetch(
                fontSize: 9.0,
                fontWeight: FontWeight.w700,
                color: const Color(0xFFF472B6),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),

          // Nội dung tin nhắn
          Positioned(
            left: 14,
            top: 155,
            width: 90,
            height: 34,
            child: Text(
              mockData.message,
              style: GoogleFonts.chakraPetch(
                fontSize: 8.5,
                fontWeight: FontWeight.w600,
                color: const Color(0xFFA5F3FC),
                height: 1.15,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),

          // --- Cuộn Băng Cassette (Bên phải: x: 124..236, y: 52..130) ---
          Positioned(
            left: 131,
            top: 60,
            child: MarqueeText(
              text: mockData.songTitle.toUpperCase(),
              width: 96,
              textAlign: TextAlign.center,
              style: GoogleFonts.righteous(
                fontSize: 8.5,
                fontWeight: FontWeight.w800,
                color: Colors.white,
                letterSpacing: 0.3,
              ),
            ),
          ),

          // Tên ca sĩ
          Positioned(
            left: 131,
            top: 114,
            child: MarqueeText(
              text: mockData.songArtist.toUpperCase(),
              width: 96,
              textAlign: TextAlign.center,
              style: GoogleFonts.righteous(
                fontSize: 8.0,
                fontWeight: FontWeight.w700,
                color: const Color(0xFF22D3EE),
                letterSpacing: 0.3,
              ),
            ),
          ),

          // Thời lượng bên dưới thanh tiến trình cyan
          if (mockData.durationSec > 0)
            Positioned(
              left: 128,
              top: 192,
              width: 104,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    mockData.elapsedStr,
                    style: GoogleFonts.righteous(
                      fontSize: 9.0,
                      fontWeight: FontWeight.w800,
                      color: const Color(0xFF22D3EE),
                    ),
                  ),
                  Text(
                    mockData.durationStr,
                    style: GoogleFonts.righteous(
                      fontSize: 9.0,
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
