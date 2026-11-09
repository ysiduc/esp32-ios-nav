import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../config/simulator_presets.dart';

/// GIAO DIỆN 1: SUNFLOWER BENTO (Lớp nền Image.asset 320x240 + Lớp trên Stack Positioned Text)
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
    final sStr = currentTime.second.toString().padLeft(2, '0');
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

          // --- Ô Đồng hồ (Góc trên trái) ---
          // Positioned(left: 18, top: 18): Row gồm Giờ HH:mm + Giây ss
          Positioned(
            left: 18,
            top: 18,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  '$hStr:$mStr',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 38,
                    fontWeight: FontWeight.w800,
                    color: const Color(0xFFFACC15),
                    letterSpacing: -1,
                    height: 1.0,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  sStr,
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: const Color(0xFFF97316),
                    height: 1.0,
                  ),
                ),
              ],
            ),
          ),

          // Positioned(left: 20, top: 68): Thứ & Ngày THỨ HAI, 09/11
          Positioned(
            left: 20,
            top: 68,
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

          // --- Ô Tin nhắn (Khung dọc bên phải) ---
          // Positioned(left: 200, top: 23): Tiêu đề "TIN NHẮN MỚI"
          Positioned(
            left: 200,
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

          // Positioned(left: 184, top: 52, width: 115, height: 95): Tên người gửi + Nội dung tin nhắn
          Positioned(
            left: 184,
            top: 52,
            width: 115,
            height: 95,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  mockData.sender,
                  style: GoogleFonts.plusJakartaSans(
                    color: const Color(0xFFFACC15),
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    height: 1.2,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                Expanded(
                  child: Text(
                    mockData.message,
                    style: GoogleFonts.plusJakartaSans(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      height: 1.25,
                    ),
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),

          // --- Thanh Nhạc (Dưới đáy) ---
          // Positioned(left: 58, top: 204, width: 195): Tên bài hát - Ca sĩ
          Positioned(
            left: 58,
            top: 204,
            width: 195,
            child: Text(
              mockData.fullSongTitle,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: const Color(0xFFFEF08A),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),

          // Positioned(right: 16, top: 202): Cột phải hiển thị thời gian hiện tại 01:24 và tổng 03:52
          Positioned(
            right: 16,
            top: 202,
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
