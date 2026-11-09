import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../config/simulator_presets.dart';

/// GIAO DIỆN 4: 80s SYNTHWAVE CASSETTE (Lớp nền Image.asset 320x240 + Lớp trên Stack Positioned Text)
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
    final sStr = currentTime.second.toString().padLeft(2, '0');
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

          // --- Khu vực Đồng hồ (Trên trái, đè lên mặt trời Synthwave) ---
          // Positioned(left: 12, top: 20): Giờ HH:mm chữ trắng viền hồng neon phát sáng
          Positioned(
            left: 12,
            top: 20,
            child: Text(
              '$hStr:$mStr',
              style: GoogleFonts.righteous(
                fontSize: 42,
                color: Colors.white,
                letterSpacing: -1,
                height: 1.0,
                shadows: const [
                  Shadow(color: Color(0xFFEC4899), blurRadius: 12),
                  Shadow(color: Color(0xFFEC4899), blurRadius: 4),
                ],
              ),
            ),
          ),

          // Giây ss (left: 122, top: 44, fontSize: 20)
          Positioned(
            left: 122,
            top: 44,
            child: Text(
              sStr,
              style: GoogleFonts.righteous(
                fontSize: 20,
                color: const Color(0xFFFACC15),
                height: 1.0,
                shadows: const [
                  Shadow(color: Color(0xFFF59E0B), blurRadius: 8),
                ],
              ),
            ),
          ),

          // Positioned(left: 14, top: 82): Thứ & Ngày T2, 09 TH11 + Năm 2026
          Positioned(
            left: 14,
            top: 82,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  datePart,
                  style: GoogleFonts.righteous(
                    color: const Color(0xFF22D3EE),
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                  ),
                ),
                Text(
                  yearStr,
                  style: GoogleFonts.righteous(
                    color: const Color(0xFFFACC15),
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),

          // --- Khung Tin nhắn (Dưới trái) ---
          // Positioned(left: 38, top: 132): "MESSAGES"
          Positioned(
            left: 38,
            top: 132,
            child: Text(
              'MESSAGES',
              style: GoogleFonts.righteous(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: const Color(0xFFF472B6),
                letterSpacing: 0.8,
              ),
            ),
          ),

          // Positioned(left: 20, top: 154, width: 124, height: 55): Nội dung tin nhắn
          Positioned(
            left: 20,
            top: 154,
            width: 124,
            height: 55,
            child: Text(
              '${mockData.sender}: "${mockData.message}"',
              style: GoogleFonts.chakraPetch(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: const Color(0xFFA5F3FC),
                height: 1.2,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),

          // --- Cuộn Băng Cassette (Bên phải) ---
          // Positioned(left: 198, top: 40, width: 96): Tên bài hát in hoa trên nhãn trên
          Positioned(
            left: 198,
            top: 40,
            width: 96,
            child: Text(
              mockData.songTitle.toUpperCase(),
              style: GoogleFonts.righteous(
                fontSize: 9.5,
                fontWeight: FontWeight.w800,
                color: Colors.white,
                letterSpacing: 0.4,
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),

          // Positioned(left: 192, top: 103, width: 104): Tên ca sĩ in hoa trên nhãn dưới
          Positioned(
            left: 192,
            top: 103,
            width: 104,
            child: Text(
              mockData.songArtist.toUpperCase(),
              style: GoogleFonts.righteous(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                color: Colors.white,
                letterSpacing: 0.4,
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),

          // Positioned(left: 172, top: 176, width: 136): Row spaceBetween 01:24 và 03:52
          Positioned(
            left: 172,
            top: 176,
            width: 136,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  mockData.elapsedStr,
                  style: GoogleFonts.righteous(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: const Color(0xFF22D3EE),
                  ),
                ),
                Text(
                  mockData.durationStr,
                  style: GoogleFonts.righteous(
                    fontSize: 11,
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
