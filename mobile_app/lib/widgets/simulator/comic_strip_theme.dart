import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../config/simulator_presets.dart';

/// GIAO DIỆN 5: POP-ART COMIC STRIP (Lớp nền Image.asset 320x240 + Lớp trên Stack Positioned Text)
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

          // --- Khung 1 - Đồng hồ Comic (Trên trái) ---
          // Positioned(left: 22, top: 18): Giờ HH:mm (ruột đen, viền trắng + ngoài đen đậm) + Giây ss (ruột cam, viền đen)
          Positioned(
            left: 22,
            top: 18,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                // Giờ: Stack 3 lớp (Đen ngoài -> Trắng giữa -> Ruột đen)
                Stack(
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
                          ..strokeWidth = 3.2
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
                const SizedBox(width: 4),
                // Giây ss (ruột cam Color(0xFFF97316), viền đen)
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

          // Positioned(left: 42, top: 78, width: 112): Chữ chính giữa dải ruy-băng cam
          Positioned(
            left: 42,
            top: 78,
            width: 112,
            child: Text(
              dateRibbon,
              textAlign: TextAlign.center,
              style: GoogleFonts.fredoka(
                fontSize: 10.5,
                fontWeight: FontWeight.w900,
                color: Colors.black,
              ),
              maxLines: 1,
            ),
          ),

          // --- Khung 2 - Bóng thoại Tin nhắn (Dưới trái) ---
          // Positioned(left: 32, top: 140, width: 128, height: 70)
          Positioned(
            left: 32,
            top: 140,
            width: 128,
            height: 70,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '💬 TIN MỚI!',
                  style: GoogleFonts.fredoka(
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                    color: Colors.black,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 2),
                Text(
                  '${mockData.sender}: "${mockData.message}"',
                  style: GoogleFonts.fredoka(
                    fontSize: 11,
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

          // --- Khung 3 - Nhạc (Cột xanh bên phải) ---
          // Positioned(left: 190, top: 20, width: 114): Tên bài hát & Ca sĩ in hoa, chữ vàng #FACC15 viền đen đậm
          Positioned(
            left: 190,
            top: 20,
            width: 114,
            child: ComicStrokeText(
              text: '${mockData.songTitle}\n${mockData.songArtist}'.toUpperCase(),
              fontSize: 13,
              fillColor: const Color(0xFFFACC15),
              strokeColor: Colors.black,
              strokeWidth: 3.5,
              textAlign: TextAlign.center,
              fontStyle: GoogleFonts.bangers(height: 1.1),
            ),
          ),

          // Positioned(left: 192, top: 212, width: 110): Row spaceBetween 01:24 và 03:52
          Positioned(
            left: 192,
            top: 212,
            width: 110,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  mockData.elapsedStr,
                  style: GoogleFonts.fredoka(
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                    color: Colors.black,
                  ),
                ),
                Text(
                  mockData.durationStr,
                  style: GoogleFonts.fredoka(
                    fontSize: 10,
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
