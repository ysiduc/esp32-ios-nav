import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../config/simulator_presets.dart';

/// GIAO DIỆN 3: RETRO MACINTOSH PIXEL OS (Căn chỉnh tọa độ pixel-perfect theo ảnh nền theme_3_bg.png)
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
          // Lớp dưới: Ảnh nền 320x240 phẳng 2D (Đã có sẵn menu bar, CLOCK.EXE, MAIL.APP, PLAYER.EXE)
          Positioned.fill(
            child: Image.asset(
              'assets/themes/theme_3_bg.png',
              width: 320,
              height: 240,
              fit: BoxFit.cover,
            ),
          ),

          // --- Cửa sổ 1 - Đồng hồ (Vùng trắng bên trong: x: 9..144, y: 34..118) ---
          // Giờ HH:mm + Giây ss (Căn giữa ngang hoàn hảo trong cửa sổ đồng hồ)
          Positioned(
            left: 10,
            top: 42,
            width: 134,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
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

          // Ngày tháng tiếng Anh (Căn giữa ngang trong cửa sổ đồng hồ)
          Positioned(
            left: 10,
            top: 82,
            width: 134,
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

          // --- Cửa sổ 2 - Tin nhắn (Vùng trắng bên trong: x: 8..152, y: 141..217) ---
          // "From: Người gửi" (Nằm ngang hàng bên phải icon phong bì x: 14..36, y: 144..162)
          Positioned(
            left: 42,
            top: 148,
            child: Text(
              'From: ${mockData.sender}',
              style: GoogleFonts.vt323(
                fontSize: 12,
                color: Colors.black,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),

          // Nội dung tin nhắn (Nằm bên dưới phong bì và tiêu đề người gửi)
          Positioned(
            left: 16,
            top: 168,
            width: 132,
            height: 44,
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
          // Tên bài hát (Nằm lọt lòng bên trong thanh ngang đen: x: 177..264, y: 65..78)
          Positioned(
            left: 178,
            top: 65,
            width: 86,
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

          // Thời lượng 01:24 / 03:52 (Nằm bên trên thanh tiến trình tại x: 226..268, y: 151..163)
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
