import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../config/simulator_presets.dart';
import 'marquee_text.dart';

/// GIAO DIỆN 1: SUNFLOWER BENTO (Căn chỉnh pixel-perfect: tên bài hát nhỏ 2px dời xuống 3px, thông báo thả trôi)
class CarbonSportTheme extends StatelessWidget {
  final DateTime currentTime;
  final SimulatorMockData mockData;

  const CarbonSportTheme({
    super.key,
    required this.currentTime,
    this.mockData = SimulatorMockData.defaultPreset,
  });

  String _formatDateVietnamese(DateTime dt) {
    const days = [
      'THỨ HAI',
      'THỨ BA',
      'THỨ TƯ',
      'THỨ NĂM',
      'THỨ SÁU',
      'THỨ BẢY',
      'CHỦ NHẬT'
    ];
    final dayName = days[dt.weekday - 1];
    final d = dt.day.toString().padLeft(2, '0');
    final m = dt.month.toString().padLeft(2, '0');
    return '$dayName, $d/$m';
  }

  @override
  Widget build(BuildContext context) {
    final hStr = currentTime.hour.toString().padLeft(2, '0');
    final mStr = currentTime.minute.toString().padLeft(2, '0');
    final dateStr = _formatDateVietnamese(currentTime);

    return SizedBox(
      width: 240,
      height: 240,
      child: Stack(
        children: [
          // Lớp dưới: Ảnh nền 240x240 phẳng 2D
          Positioned.fill(
            child: Image.asset(
              'assets/themes/theme_1_bg.png',
              width: 240,
              height: 240,
              fit: BoxFit.cover,
            ),
          ),

          // --- Ô Đồng hồ (Góc trên trái: x: 6..128, y: 6..92) ---
          Positioned(
            left: 12,
            top: 16,
            width: 110,
            child: Text(
              '$hStr:$mStr',
              style: GoogleFonts.plusJakartaSans(
                fontSize: 32,
                fontWeight: FontWeight.w800,
                color: const Color(0xFFFACC15),
                letterSpacing: -1,
                height: 1.0,
              ),
            ),
          ),

          // Thứ & Ngày (bên dưới giờ)
          Positioned(
            left: 13,
            top: 56,
            width: 108,
            child: Text(
              dateStr,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 9.5,
                fontWeight: FontWeight.w700,
                color: Colors.white,
                letterSpacing: 0.3,
              ),
            ),
          ),

          // --- Ô Tin nhắn (Khung dọc bên phải: x: 134..234, y: 6..200) ---
          Positioned(
            left: 162,
            top: 16,
            child: Text(
              'TIN NHẮN MỚI',
              style: GoogleFonts.plusJakartaSans(
                fontSize: 8.0,
                fontWeight: FontWeight.w800,
                color: const Color(0xFFFB923C),
                letterSpacing: 0.4,
              ),
            ),
          ),

          // Tên người gửi (cố định)
          Positioned(
            left: 141,
            top: 38,
            width: 86,
            child: Text(
              mockData.sender,
              style: GoogleFonts.plusJakartaSans(
                color: const Color(0xFFFACC15),
                fontWeight: FontWeight.w700,
                fontSize: 10.0,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),

          // Nội dung tin nhắn
          Positioned(
            left: 141,
            top: 54,
            width: 86,
            height: 68,
            child: Text(
              mockData.message,
              style: GoogleFonts.plusJakartaSans(
                color: Colors.white,
                fontSize: 9.0,
                fontWeight: FontWeight.w500,
                height: 1.25,
              ),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
          ),

          // --- Thanh Nhạc (Dưới đáy: x: 6..234, y: 206..234) ---
          Positioned(
            left: 48,
            top: 210,
            child: MarqueeText(
              text: mockData.fullSongTitle,
              width: 144,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 8.5,
                fontWeight: FontWeight.w700,
                color: const Color(0xFFFEF08A),
              ),
            ),
          ),

          // Cột thời gian hiện tại / tổng thời gian (chỉ hiện khi có tiến trình bài hát)
          if (mockData.durationSec > 0)
            Positioned(
              right: 12,
              top: 209,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    mockData.elapsedStr,
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 7.5,
                      fontWeight: FontWeight.w700,
                      color: const Color(0xFFFB923C),
                      height: 1.1,
                    ),
                  ),
                  Text(
                    mockData.durationStr,
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 7.5,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                      height: 1.1,
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
