import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../config/simulator_presets.dart';

/// GIAO DIỆN 5: POP-ART COMIC STRIP (Căn chỉnh tọa độ pixel-perfect theo ảnh nền theme_5_bg.png)
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
    final sStr = currentTime.second.toString().padLeft(2, '0');
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

          // --- Khung 1 - Đồng hồ Comic (Góc trên trái: panel x: 8..170, y: 8..115) ---
          // Giờ HH:mm (ruột đen, viền trắng, viền ngoài đen) + Giây ss (ruột cam, viền đen)
          Positioned(
            left: 16,
            top: 20,
            width: 148,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                // Giờ: Stack 3 lớp tạo viền kép đậm chất Comic
                Stack(
                  children: [
                    Text(
                      '$hStr:$mStr',
                      style: GoogleFonts.bangers(
                        fontSize: 38,
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
                        fontSize: 38,
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
                        fontSize: 38,
                        letterSpacing: 1.0,
                        color: Colors.black,
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 4),
                // Giây ss
                Stack(
                  children: [
                    Text(
                      sStr,
                      style: GoogleFonts.bangers(
                        fontSize: 20,
                        foreground: Paint()
                          ..style = PaintingStyle.stroke
                          ..strokeWidth = 3.5
                          ..strokeCap = StrokeCap.round
                          ..strokeJoin = StrokeJoin.round
                          ..color = Colors.black,
                      ),
                    ),
                    Text(
                      sStr,
                      style: GoogleFonts.bangers(
                        fontSize: 20,
                        color: const Color(0xFFF97316),
                      ),
                    ),
                  ],
                ),
              ],
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
            top: 142,
            width: 130,
            height: 68,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '💬 TIN MỚI!',
                  style: GoogleFonts.fredoka(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w900,
                    color: Colors.black,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 2),
                Text(
                  '${mockData.sender}: "${mockData.message}"',
                  style: GoogleFonts.fredoka(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: Colors.black,
                    height: 1.15,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),

          // --- Khung 3 - Nhạc (Cột xanh bên phải: bầu trời x: 180..311, y: 12..74) ---
          // Tên bài hát & Ca sĩ in hoa, chữ vàng viền đen đậm
          Positioned(
            left: 184,
            top: 18,
            width: 124,
            child: ComicStrokeText(
              text: '${mockData.songTitle}\n${mockData.songArtist}'.toUpperCase(),
              fontSize: 12,
              fillColor: const Color(0xFFFACC15),
              strokeColor: Colors.black,
              strokeWidth: 3.2,
              textAlign: TextAlign.center,
              fontStyle: GoogleFonts.bangers(height: 1.1),
            ),
          ),

          // Thời lượng 01:24 và 03:52 (bên dưới thanh tiến trình đáy)
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

class ComicStrokeText extends StatelessWidget {
  final String text;
  final double fontSize;
  final Color fillColor;
  final Color strokeColor;
  final double strokeWidth;
  final TextAlign textAlign;
  final TextStyle? fontStyle;

  const ComicStrokeText({
    super.key,
    required this.text,
    required this.fontSize,
    this.fillColor = Colors.white,
    this.strokeColor = Colors.black,
    this.strokeWidth = 3.0,
    this.textAlign = TextAlign.left,
    this.fontStyle,
  });

  @override
  Widget build(BuildContext context) {
    final baseStyle = (fontStyle ?? GoogleFonts.bangers()).copyWith(
      fontSize: fontSize,
    );

    return Stack(
      children: [
        Text(
          text,
          textAlign: textAlign,
          style: baseStyle.copyWith(
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = strokeWidth
              ..strokeCap = StrokeCap.round
              ..strokeJoin = StrokeJoin.round
              ..color = strokeColor,
          ),
        ),
        Text(
          text,
          textAlign: textAlign,
          style: baseStyle.copyWith(
            color: fillColor,
          ),
        ),
      ],
    );
  }
}
