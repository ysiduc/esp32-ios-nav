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
      width: 320,
      height: 240,
      child: Stack(
        children: [
          // Lớp dưới: Ảnh nền 320x240 phẳng 2D
          Positioned.fill(
            child: Image.asset(
              'assets/themes/theme_5_bg.png',
              width: 320,
              height: 240,
              fit: BoxFit.cover,
            ),
          ),

          // --- Khung 1 - Đồng hồ Comic (Góc trên trái: panel x: 8..170, y: 8..115, chỉ hiện HH:mm) ---
          Positioned(
            left: 16,
            top: 20,
            width: 148,
            child: Center(
              child: Stack(
                children: [
                  Text(
                    '$hStr:$mStr',
                    style: GoogleFonts.bangers(
                      fontSize: 40,
                      letterSpacing: 1.0,
                      foreground: Paint()
                        ..style = PaintingStyle.stroke
                        ..strokeWidth = 6.0
                        ..strokeCap = StrokeCap.round
                        ..strokeJoin = StrokeJoin.round
                        ..color = Colors.black,
                    ),
                  ),
                  Text(
                    '$hStr:$mStr',
                    style: GoogleFonts.bangers(
                      fontSize: 40,
                      letterSpacing: 1.0,
                      foreground: Paint()
                        ..style = PaintingStyle.stroke
                        ..strokeWidth = 3.0
                        ..strokeCap = StrokeCap.round
                        ..strokeJoin = StrokeJoin.round
                        ..color = Colors.white,
                    ),
                  ),
                  Text(
                    '$hStr:$mStr',
                    style: GoogleFonts.bangers(
                      fontSize: 40,
                      letterSpacing: 1.0,
                      color: Colors.black,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Chữ nằm chính giữa dải ruy-băng cam (Ruy băng x: 15..162, y: 72..113)
          Positioned(
            left: 30,
            top: 83,
            width: 118,
            height: 20,
            child: Center(
              child: Text(
                dateRibbon,
                textAlign: TextAlign.center,
                style: GoogleFonts.fredoka(
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                  color: Colors.black,
                ),
                maxLines: 1,
              ),
            ),
          ),

          // --- Khung 2 - Bóng thoại Tin nhắn (Bóng thoại trắng x: 21..166, y: 136..222) ---
          Positioned(
            left: 28,
            top: 140,
            width: 130,
            height: 72,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Tên người gửi nổi bật (cố định, cắt ... nếu quá dài)
                SizedBox(
                  width: 120,
                  child: Text(
                    '💬 ${mockData.sender.toUpperCase()}:',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.fredoka(
                      fontSize: 11.0,
                      fontWeight: FontWeight.w900,
                      color: const Color(0xFFEA580C),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 2),
                // Nội dung tin nhắn xuống dòng đến hết ô, không cần trôi
                Expanded(
                  child: Text(
                    mockData.message,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.fredoka(
                      fontSize: 10.0,
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

          // --- Khung 3 - Nhạc (Cột xanh bên phải: Badge vàng viền đen nổi bật chất Comic) ---
          Positioned(
            left: 184,
            top: 16,
            width: 124,
            height: 26,
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFFFACC15),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.black, width: 2),
                boxShadow: const [
                  BoxShadow(color: Colors.black, offset: Offset(2, 2)),
                ],
              ),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              alignment: Alignment.center,
              child: MarqueeText(
                text: '${mockData.songTitle} - ${mockData.songArtist}'.toUpperCase(),
                width: 112,
                textAlign: TextAlign.center,
                style: GoogleFonts.bangers(
                  fontSize: 12,
                  letterSpacing: 0.8,
                  color: Colors.black,
                ),
              ),
            ),
          ),

          // Thời lượng 01:24 và 03:52 (bên dưới thanh tiến trình đáy)
          if (mockData.durationSec > 0)
            Positioned(
              left: 184,
              top: 212,
              width: 122,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    mockData.elapsedStr,
                    style: GoogleFonts.fredoka(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w900,
                      color: Colors.black,
                    ),
                  ),
                  Text(
                    mockData.durationStr,
                    style: GoogleFonts.fredoka(
                      fontSize: 9.5,
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
