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

          // --- Khu vực Mặt Trời Synthwave (Mặt trời có viền mờ tương phản cao) ---
          // Giờ HH:mm (Căn giữa ngang trên mặt trời)
          Positioned(
            left: 20,
            top: 28,
            width: 120,
            child: Text(
              '$hStr:$mStr',
              textAlign: TextAlign.center,
              style: GoogleFonts.righteous(
                fontSize: 38,
                color: Colors.white,
                letterSpacing: -0.5,
                height: 1.0,
                shadows: const [
                  Shadow(color: Color(0xFFEC4899), blurRadius: 12),
                  Shadow(color: Color(0xFFEC4899), blurRadius: 4),
                  Shadow(color: Colors.black, blurRadius: 6),
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
          // Tiêu đề MESSAGES
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

          // Người gửi & Nội dung tin nhắn (thả trôi marquee nếu dài)
          Positioned(
            left: 22,
            top: 144,
            width: 120,
            height: 48,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MarqueeText(
                  text: mockData.sender,
                  width: 120,
                  style: GoogleFonts.chakraPetch(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: const Color(0xFFF472B6),
                  ),
                ),
                const SizedBox(height: 2),
                Expanded(
                  child: ClipRect(
                    child: MarqueeText(
                      text: mockData.message,
                      width: 120,
                      style: GoogleFonts.chakraPetch(
                        fontSize: 10.0,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFFA5F3FC),
                        height: 1.15,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // --- Cuộn Băng Cassette (Bên phải: x: 168..307, y: 48..174) ---
          // Tên bài hát in hoa trên dải nhãn trên (thả trôi marquee nếu dài)
          Positioned(
            left: 176,
            top: 58,
            child: MarqueeText(
              text: mockData.songTitle.toUpperCase(),
              width: 124,
              textAlign: TextAlign.center,
              style: GoogleFonts.righteous(
                fontSize: 10,
                fontWeight: FontWeight.w800,
                color: Colors.white,
                letterSpacing: 0.4,
              ),
            ),
          ),

          // Tên ca sĩ in hoa trên dải nhãn dưới mới (thả trôi marquee nếu dài)
          Positioned(
            left: 176,
            top: 120,
            child: MarqueeText(
              text: mockData.songArtist.toUpperCase(),
              width: 124,
              textAlign: TextAlign.center,
              style: GoogleFonts.righteous(
                fontSize: 9.5,
                fontWeight: FontWeight.w700,
                color: const Color(0xFF22D3EE),
                letterSpacing: 0.4,
              ),
            ),
          ),

          // Thời lượng bên dưới thanh tiến trình cyan
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
