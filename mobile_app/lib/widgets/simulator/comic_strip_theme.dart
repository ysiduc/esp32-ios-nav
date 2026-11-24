import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../config/simulator_presets.dart';
import 'marquee_text.dart';

/// GIAO DIỆN 5: POP-ART COMIC STRIP (Bóng thoại có tên người gửi, bài hát trong badge vàng nổi bật)
class ComicStripTheme extends StatelessWidget {
  final DateTime currentTime;
  final SimulatorMockData mockData;

  const ComicStripTheme({
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
    final dateRibbon = '$dayOfWeek, $d THÁNG $m';

    return SizedBox(
      width: 240,
      height: 240,
      child: Stack(
        children: [
          // Lớp dưới: Ảnh nền 240x240 phẳng 2D
          Positioned.fill(
            child: Image.asset(
              'assets/themes/theme_5_bg.png',
              width: 240,
              height: 240,
              fit: BoxFit.cover,
            ),
          ),

          // --- Khung 1 - Đồng hồ Comic (Góc trên trái: x: 6..124, y: 6..116) ---
          Positioned(
            left: 12,
            top: 18,
            width: 106,
            child: Center(
              child: Stack(
                children: [
                  Text(
                    '$hStr:$mStr',
                    style: GoogleFonts.bangers(
                      fontSize: 32,
                      letterSpacing: 0.8,
                      foreground: Paint()
                        ..style = PaintingStyle.stroke
                        ..strokeWidth = 5.0
                        ..strokeCap = StrokeCap.round
                        ..strokeJoin = StrokeJoin.round
                        ..color = Colors.black,
                    ),
                  ),
                  Text(
                    '$hStr:$mStr',
                    style: GoogleFonts.bangers(
                      fontSize: 32,
                      letterSpacing: 0.8,
                      foreground: Paint()
                        ..style = PaintingStyle.stroke
                        ..strokeWidth = 2.5
                        ..strokeCap = StrokeCap.round
                        ..strokeJoin = StrokeJoin.round
                        ..color = Colors.white,
                    ),
                  ),
                  Text(
                    '$hStr:$mStr',
                    style: GoogleFonts.bangers(
                      fontSize: 32,
                      letterSpacing: 0.8,
                      color: Colors.black,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Chữ nằm chính giữa dải ruy-băng cam
          Positioned(
            left: 20,
            top: 82,
            width: 84,
            height: 18,
            child: Center(
              child: Text(
                dateRibbon,
                textAlign: TextAlign.center,
                style: GoogleFonts.fredoka(
                  fontSize: 8.5,
                  fontWeight: FontWeight.w900,
                  color: Colors.black,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),

          // --- Khung 2 - Bóng thoại Tin nhắn (x: 6..124, y: 122..234) ---
          Positioned(
            left: 18,
            top: 138,
            width: 92,
            height: 74,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: 88,
                  child: Text(
                    '💬 ${mockData.sender.toUpperCase()}:',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.fredoka(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w900,
                      color: const Color(0xFFEA580C),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 2),
                Expanded(
                  child: Text(
                    mockData.message,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.fredoka(
                      fontSize: 8.5,
                      fontWeight: FontWeight.w700,
                      color: Colors.black,
                      height: 1.15,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),

          // --- Khung 3 - Nhạc (Cột xanh bên phải: x: 130..234, y: 6..234) ---
          Positioned(
            left: 135,
            top: 14,
            width: 94,
            height: 22,
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFFFACC15),
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: Colors.black, width: 1.8),
                boxShadow: const [
                  BoxShadow(color: Colors.black, offset: Offset(2, 2)),
                ],
              ),
              padding: const EdgeInsets.symmetric(horizontal: 3),
              alignment: Alignment.center,
              child: MarqueeText(
                text: '${mockData.songTitle} - ${mockData.songArtist}'.toUpperCase(),
                width: 84,
                textAlign: TextAlign.center,
                style: GoogleFonts.bangers(
                  fontSize: 10.5,
                  letterSpacing: 0.6,
                  color: Colors.black,
                ),
              ),
            ),
          ),

          // Thời lượng bên dưới thanh tiến trình đáy
          if (mockData.durationSec > 0)
            Positioned(
              left: 135,
              top: 210,
              width: 94,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    mockData.elapsedStr,
                    style: GoogleFonts.fredoka(
                      fontSize: 8.5,
                      fontWeight: FontWeight.w900,
                      color: Colors.black,
                    ),
                  ),
                  Text(
                    mockData.durationStr,
                    style: GoogleFonts.fredoka(
                      fontSize: 8.5,
                      fontWeight: FontWeight.w900,
                      color: Colors.black,
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
