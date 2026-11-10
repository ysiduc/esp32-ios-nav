import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../config/simulator_presets.dart';
import 'marquee_text.dart';

/// GIAO DIỆN 1: SUNFLOWER BENTO (Căn chỉnh tọa độ pixel-perfect theo ảnh nền theme_1_bg.png)
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
      width: 320,
      height: 240,
      child: Stack(
        children: [
          // Lớp dưới: Ảnh nền 320x240 phẳng 2D
          Positioned.fill(
            child: Image.asset(
              'assets/themes/theme_1_bg.png',
              width: 320,
              height: 240,
              fit: BoxFit.cover,
            ),
          ),

          // --- Ô Đồng hồ (Góc trên trái: ô x: 12..160, y: 12..104, chỉ hiện HH:mm) ---
          Positioned(
            left: 20,
            top: 22,
            child: Text(
              '$hStr:$mStr',
              style: GoogleFonts.plusJakartaSans(
                fontSize: 38,
                fontWeight: FontWeight.w800,
                color: const Color(0xFFFACC15),
                letterSpacing: -1,
                height: 1.0,
              ),
            ),
          ),

          // Thứ & Ngày (bên dưới giờ)
          Positioned(
            left: 22,
            top: 70,
            child: Text(
              dateStr,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Colors.white,
                letterSpacing: 0.5,
              ),
            ),
          ),

          // --- Ô Tin nhắn (Khung dọc bên phải: x: 176..304, y: 15..184) ---
          // Tiêu đề "TIN NHẮN MỚI" (ngay sau icon bong bóng chat ở x: 185, y: 23)
          Positioned(
            left: 204,
            top: 23,
            child: Text(
              'TIN NHẮN MỚI',
              style: GoogleFonts.plusJakartaSans(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: const Color(0xFFFB923C),
                letterSpacing: 0.6,
              ),
            ),
          ),

          // Tên người gửi + Nội dung tin nhắn (nằm gọn phần trên, không đè bông hoa ở đáy)
          Positioned(
            left: 184,
            top: 50,
            width: 110,
            height: 75,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  mockData.sender,
                  style: GoogleFonts.plusJakartaSans(
                    color: const Color(0xFFFACC15),
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                    height: 1.2,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Expanded(
                  child: Text(
                    mockData.message,
                    style: GoogleFonts.plusJakartaSans(
                      color: Colors.white,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      height: 1.25,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),

          // --- Thanh Nhạc (Dưới đáy: pill y: 190..231) ---
          // Tên bài hát - Ca sĩ (thả trôi marquee nếu dài hơn 175px)
          Positioned(
            left: 60,
            top: 198,
            child: MarqueeText(
              text: mockData.fullSongTitle,
              width: 175,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: const Color(0xFFFEF08A),
              ),
            ),
          ),

          // Cột thời gian hiện tại / tổng thời gian (chỉ hiện khi có tiến trình bài hát)
          if (mockData.durationSec > 0)
            Positioned(
              right: 20,
              top: 198,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    mockData.elapsedStr,
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      color: const Color(0xFFFB923C),
                      height: 1.1,
                    ),
                  ),
                  Text(
                    mockData.durationStr,
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 9,
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
