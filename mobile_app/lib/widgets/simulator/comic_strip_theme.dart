import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../config/simulator_presets.dart';

/// GIAO DIỆN 5: POP-ART COMIC STRIP / MANGA (100% Pure Flutter Canvas & Widgets 320x240)
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
    final dStr = 'T${currentTime.weekday == 7 ? 'CN' : currentTime.weekday + 1}, ${currentTime.day.toString().padLeft(2, '0')} THÁNG ${currentTime.month.toString().padLeft(2, '0')}';

    return Container(
      width: 320,
      height: 240,
      decoration: BoxDecoration(
        color: const Color(0xFFFAFAFA),
        border: Border.all(color: Colors.black, width: 2.5),
      ),
      child: Stack(
        children: [
          // Panel 1 - Đồng hồ Comic (Góc trên trái: x: 8, y: 8, w: 168, h: 108)
          Positioned(
            left: 8,
            top: 8,
            width: 168,
            height: 108,
            child: _buildClockPanel(hStr, mStr, sStr, dStr),
          ),

          // Panel 2 - Bóng Thoại Tin Nhắn (Góc dưới trái: x: 8, y: 122, w: 168, h: 110)
          Positioned(
            left: 8,
            top: 122,
            width: 168,
            height: 110,
            child: _buildSpeechBubblePanel(),
          ),

          // Panel 3 - Máy Nghe Nhạc & Đĩa Than (Cột phải: x: 182, y: 8, w: 130, h: 224)
          Positioned(
            left: 182,
            top: 8,
            width: 130,
            height: 224,
            child: _buildMusicMangaPanel(),
          ),
        ],
      ),
    );
  }

  // --- Panel 1: Đồng hồ Comic ---
  Widget _buildClockPanel(String h, String m, String s, String dateStr) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFFEF08A),
        border: Border.all(color: Colors.black, width: 2.5),
      ),
      child: Stack(
        children: [
          // Speed lines and Halftone dots
          Positioned.fill(
            child: CustomPaint(
              painter: _SpeedLinesAndHalftonePainter(),
            ),
          ),

          // Center comic clock
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    // Giờ HH:mm béo viền kép đen trắng
                    _buildOutlinedText('$h:$m', 38, Colors.black, Colors.white, 3.5),
                    const SizedBox(width: 4),
                    // Giây ss cam viền đen
                    _buildOutlinedText(s, 18, const Color(0xFFF97316), Colors.black, 2.0),
                  ],
                ),
                const SizedBox(height: 6),

                // Ribbon banner cam ghi Thứ & Ngày
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFB923C),
                    border: Border.all(color: Colors.black, width: 1.5),
                    boxShadow: const [
                      BoxShadow(color: Colors.black, offset: Offset(2, 2)),
                    ],
                  ),
                  child: Text(
                    dateStr,
                    style: const TextStyle(
                      color: Colors.black,
                      fontSize: 9.5,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- Panel 2: Bóng Thoại Tin Nhắn ---
  Widget _buildSpeechBubblePanel() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF97316),
        border: Border.all(color: Colors.black, width: 2.5),
      ),
      padding: const EdgeInsets.all(6),
      child: Stack(
        children: [
          // Corner Hatching lines
          Positioned.fill(
            child: CustomPaint(
              painter: _HatchingLinesPainter(),
            ),
          ),

          // Speech Bubble with pointed tail
          Positioned(
            left: 4,
            top: 4,
            right: 4,
            bottom: 4,
            child: CustomPaint(
              painter: _SpeechBubblePainter(),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: const [
                        Text(
                          '💬 TIN MỚI!',
                          style: TextStyle(
                            color: Colors.black,
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${mockData.sender}:',
                      style: const TextStyle(
                        color: Colors.black,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        mockData.message,
                        style: const TextStyle(
                          color: Colors.black,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          height: 1.2,
                        ),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- Panel 3: Máy Nghe Nhạc & Đĩa Than ---
  Widget _buildMusicMangaPanel() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF7DD3FC),
        border: Border.all(color: Colors.black, width: 2.5),
      ),
      padding: const EdgeInsets.all(6),
      child: Column(
        children: [
          // Top: Dynamic Song Title & Artist in cartoon style
          _buildOutlinedText(mockData.songTitle.toUpperCase(), 11.5, const Color(0xFFFACC15), Colors.black, 2.0),
          const SizedBox(height: 2),
          Text(
            mockData.songArtist.toUpperCase(),
            style: const TextStyle(
              color: Colors.black,
              fontSize: 8.5,
              fontWeight: FontWeight.w900,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),

          // Center: Tilted Mini Cassette + Spinning Vinyl Record
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _VinylAndMiniCassettePainter(progress: mockData.songProgress),
                  ),
                ),
                // Comic action text "BAY BỔNG!"
                Positioned(
                  right: 2,
                  top: 8,
                  child: Transform.rotate(
                    angle: -0.2,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      color: const Color(0xFFFACC15),
                      child: const Text(
                        'BAY BỔNG!',
                        style: TextStyle(
                          color: Colors.black,
                          fontSize: 7.5,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),

          // Bottom: Progress bar with zebra stripes + 01:24 / 03:52
          Container(
            height: 10,
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: Colors.black, width: 1.5),
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                width: 114 * mockData.songProgress,
                color: const Color(0xFFF97316),
              ),
            ),
          ),
          const SizedBox(height: 2),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                mockData.elapsedStr,
                style: const TextStyle(color: Colors.black, fontSize: 8.5, fontWeight: FontWeight.bold),
              ),
              Text(
                mockData.durationStr,
                style: const TextStyle(color: Colors.black, fontSize: 8.5, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildOutlinedText(String text, double size, Color fillColor, Color strokeColor, double strokeWidth) {
    return Stack(
      children: [
        // Outline Stroke
        Text(
          text,
          style: TextStyle(
            fontSize: size,
            fontWeight: FontWeight.w900,
            fontFamily: 'monospace',
            letterSpacing: -1.0,
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = strokeWidth
              ..color = strokeColor,
          ),
        ),
        // Fill Text
        Text(
          text,
          style: TextStyle(
            fontSize: size,
            fontWeight: FontWeight.w900,
            fontFamily: 'monospace',
            letterSpacing: -1.0,
            color: fillColor,
          ),
        ),
      ],
    );
  }
}

/// Speed Lines & Halftone dots
class _SpeedLinesAndHalftonePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final lineP = Paint()
      ..color = const Color(0xFFFDE047).withValues(alpha: 0.7)
      ..strokeWidth = 1.2;

    const center = Offset(84, 54);
    // Draw radiating speed rays
    for (int i = 0; i < 16; i++) {
      final a = (i * 22.5) * math.pi / 180;
      final start = Offset(center.dx + 40 * math.cos(a), center.dy + 30 * math.sin(a));
      final end = Offset(center.dx + 110 * math.cos(a), center.dy + 80 * math.sin(a));
      canvas.drawLine(start, end, lineP);
    }

    // Halftone dots in 4 corners
    final dotP = Paint()..color = const Color(0xFFCA8A04).withValues(alpha: 0.35);
    for (double x = 4; x <= 24; x += 6) {
      for (double y = 4; y <= 24; y += 6) {
        canvas.drawCircle(Offset(x, y), 1.5, dotP);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Corner Hatching lines
class _HatchingLinesPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.black.withValues(alpha: 0.25)
      ..strokeWidth = 1.0;

    for (int i = 0; i < 5; i++) {
      canvas.drawLine(Offset(size.width - 24 + (i * 5.0), size.height), Offset(size.width, size.height - 24 + (i * 5.0)), p);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Speech Bubble with sharp tail pointing down-left
class _SpeechBubblePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    final path = Path();
    path.moveTo(8, 0);
    path.lineTo(w - 8, 0);
    path.quadraticBezierTo(w, 0, w, 8);
    path.lineTo(w, h - 18);
    path.quadraticBezierTo(w, h - 10, w - 8, h - 10);
    path.lineTo(30, h - 10);
    // Sharp tail pointing down-left
    path.lineTo(12, h);
    path.lineTo(18, h - 10);
    path.lineTo(8, h - 10);
    path.quadraticBezierTo(0, h - 10, 0, h - 18);
    path.lineTo(0, 8);
    path.quadraticBezierTo(0, 0, 8, 0);
    path.close();

    // Fill white
    canvas.drawPath(path, Paint()..color = Colors.white);
    // 2.5px solid black border
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Đĩa than (Vinyl record) xoay + Mini Cassette nghiêng
class _VinylAndMiniCassettePainter extends CustomPainter {
  final double progress;
  _VinylAndMiniCassettePainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width * 0.45, size.height * 0.55);
    const r = 36.0;

    // 1. Vinyl Record (Black disc with grooved rings)
    canvas.drawCircle(center, r, Paint()..color = Colors.black);
    final grooveP = Paint()
      ..color = const Color(0xFF27272A)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawCircle(center, r * 0.85, grooveP);
    canvas.drawCircle(center, r * 0.70, grooveP);
    canvas.drawCircle(center, r * 0.55, grooveP);

    // Center Orange Label & Hole
    canvas.drawCircle(center, 12, Paint()..color = const Color(0xFFF97316));
    canvas.drawCircle(center, 3, Paint()..color = Colors.white);

    // 2. Tilted Mini Cassette overlapping top-right
    canvas.save();
    canvas.translate(size.width * 0.55, size.height * 0.35);
    canvas.rotate(0.25);

    final casRRect = RRect.fromRectAndRadius(const Rect.fromLTWH(-28, -18, 56, 36), const Radius.circular(4));
    canvas.drawRRect(casRRect, Paint()..color = const Color(0xFFA7F3D0));
    canvas.drawRRect(
      casRRect,
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    // Cassette mini reels
    canvas.drawCircle(const Offset(-12, 0), 5, Paint()..color = Colors.white);
    canvas.drawCircle(const Offset(-12, 0), 2, Paint()..color = Colors.black);
    canvas.drawCircle(const Offset(12, 0), 5, Paint()..color = Colors.white);
    canvas.drawCircle(const Offset(12, 0), 2, Paint()..color = Colors.black);

    canvas.restore();

    // 3. Floating cartoon music notes in black
    _drawMusicNote(canvas, Offset(size.width * 0.15, size.height * 0.25));
    _drawMusicNote(canvas, Offset(size.width * 0.82, size.height * 0.75));
  }

  void _drawMusicNote(Canvas canvas, Offset pos) {
    final p = Paint()..color = Colors.black;
    canvas.drawCircle(pos, 3, p);
    canvas.drawLine(pos, Offset(pos.dx, pos.dy - 10), Paint()..color = Colors.black..strokeWidth = 1.5);
    canvas.drawLine(Offset(pos.dx, pos.dy - 10), Offset(pos.dx + 4, pos.dy - 12), Paint()..color = Colors.black..strokeWidth = 1.5);
  }

  @override
  bool shouldRepaint(covariant _VinylAndMiniCassettePainter oldDelegate) => oldDelegate.progress != progress;
}
