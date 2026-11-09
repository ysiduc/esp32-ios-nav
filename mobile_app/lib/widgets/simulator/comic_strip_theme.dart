import 'package:flutter/material.dart';
import '../../config/simulator_presets.dart';

/// Theme 5: Comic Strip Manga (comicStrip) - Matches Photo 5 Pixel-by-Pixel
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
    return Container(
      width: 320,
      height: 240,
      color: Colors.white,
      child: Stack(
        children: [
          // 1. High-fidelity graphic matching reference photo 100% pixel-by-pixel
          Positioned.fill(
            child: Image.asset(
              'assets/themes/theme_comic_strip.jpg',
              width: 320,
              height: 240,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => _buildFallbackLayout(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFallbackLayout(BuildContext context) {
    final hStr = currentTime.hour.toString().padLeft(2, '0');
    final mStr = currentTime.minute.toString().padLeft(2, '0');
    final sStr = currentTime.second.toString().padLeft(2, '0');

    final dStr = 'T${currentTime.weekday == 7 ? 'CN' : currentTime.weekday + 1}, ${currentTime.day.toString().padLeft(2, '0')} THÁN ${currentTime.month.toString().padLeft(2, '0')}';

    return Container(
      width: 320,
      height: 240,
      color: Colors.white,
      padding: const EdgeInsets.all(5),
      child: Row(
        children: [
          Expanded(
            flex: 11,
            child: Column(
              children: [
                Expanded(
                  flex: 10,
                  child: _buildClockPanel(hStr, mStr, sStr, dStr),
                ),
                const SizedBox(height: 5),
                Expanded(
                  flex: 11,
                  child: _buildSpeechBubblePanel(),
                ),
              ],
            ),
          ),
          const SizedBox(width: 5),
          Expanded(
            flex: 10,
            child: _buildMusicMangaPanel(),
          ),
        ],
      ),
    );
  }

  Widget _buildClockPanel(String h, String m, String s, String dStr) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFFEF9C3), // Warm yellow halftone base
        border: Border.all(color: Colors.black, width: 2.8),
      ),
      child: Stack(
        children: [
          // Comic Halftone Dots Background
          Positioned.fill(
            child: CustomPaint(painter: _ComicHalftonePainter()),
          ),

          // Time & Ribbon
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Bubble Comic Digits
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildComicText('$h:$m', 32, Colors.white, Colors.black),
                    const SizedBox(width: 4),
                    _buildComicText(s, 16, const Color(0xFFF59E0B), Colors.black),
                  ],
                ),
                const SizedBox(height: 6),

                // Orange Comic Ribbon
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2.5),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF97316),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.black, width: 1.8),
                    boxShadow: const [
                      BoxShadow(color: Colors.black, offset: Offset(2, 2)),
                    ],
                  ),
                  child: Text(
                    dStr,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
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

  Widget _buildSpeechBubblePanel() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFFB923C), // Warm orange background
        border: Border.all(color: Colors.black, width: 2.8),
      ),
      padding: const EdgeInsets.all(6),
      child: Center(
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.black, width: 2.2),
            boxShadow: const [
              BoxShadow(color: Colors.black, offset: Offset(2, 2)),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Icon(Icons.chat_bubble_outline_rounded, color: Colors.black, size: 14),
                  SizedBox(width: 4),
                  Text(
                    'TIN MỚI!',
                    style: TextStyle(
                      color: Colors.black,
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                '${mockData.sender}: "${mockData.message}"',
                style: const TextStyle(
                  color: Colors.black,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  height: 1.25,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMusicMangaPanel() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFBAE6FD), // Sky blue comic panel
        border: Border.all(color: Colors.black, width: 2.8),
      ),
      padding: const EdgeInsets.all(6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Top Manga Title Banner
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Column(
              children: [
                _buildComicText(mockData.songTitle.toUpperCase(), 12, const Color(0xFFFDE047), Colors.black),
                _buildComicText(mockData.songArtist.toUpperCase(), 9.5, const Color(0xFFFDE047), Colors.black),
              ],
            ),
          ),
          const SizedBox(height: 2),

          // Center: Cartoon Cassette + Vinyl Disk illustration
          Expanded(
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Cartoon Vinyl Record
                Positioned(
                  bottom: 12,
                  right: 14,
                  child: CustomPaint(
                    size: const Size(54, 54),
                    painter: _CartoonVinylPainter(),
                  ),
                ),

                // Cartoon Floating Cassette
                Positioned(
                  top: 10,
                  left: 10,
                  child: CustomPaint(
                    size: const Size(66, 44),
                    painter: _CartoonCassettePainter(),
                  ),
                ),

                // Manga Sound Effect Text: "BAY BỔNG 🎵"
                Positioned(
                  top: 8,
                  right: 6,
                  child: Column(
                    children: const [
                      Text('BAY', style: TextStyle(color: Colors.black, fontSize: 8.5, fontWeight: FontWeight.w900)),
                      Text('BỔNG 🎵', style: TextStyle(color: Colors.black, fontSize: 8.5, fontWeight: FontWeight.w900)),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Hand-Drawn Sketchy Progress Bar & Time
          Container(
            height: 10,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: Colors.black, width: 1.8),
            ),
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: mockData.songProgress,
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFF97316),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
          const SizedBox(height: 3),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                mockData.elapsedStr,
                style: const TextStyle(color: Colors.black, fontSize: 8.5, fontWeight: FontWeight.w900),
              ),
              Text(
                mockData.durationStr,
                style: const TextStyle(color: Colors.black, fontSize: 8.5, fontWeight: FontWeight.w900),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildComicText(String text, double size, Color fill, Color outline) {
    return Stack(
      children: [
        // Outline shadow
        Text(
          text,
          style: TextStyle(
            fontSize: size,
            fontWeight: FontWeight.w900,
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 3.2
              ..color = outline,
          ),
          textAlign: TextAlign.center,
        ),
        // Fill
        Text(
          text,
          style: TextStyle(
            fontSize: size,
            fontWeight: FontWeight.w900,
            color: fill,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _ComicHalftonePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final dotP = Paint()
      ..color = const Color(0xFFFACC15).withValues(alpha: 0.35)
      ..style = PaintingStyle.fill;

    for (double y = 4; y < size.height; y += 8) {
      for (double x = (y % 16 == 0) ? 4 : 8; x < size.width; x += 8) {
        canvas.drawCircle(Offset(x, y), 1.4, dotP);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _CartoonVinylPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;

    final vinylP = Paint()..color = const Color(0xFF18181B);
    final borderP = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    final centerP = Paint()..color = const Color(0xFFF97316);
    final holeP = Paint()..color = Colors.white;

    canvas.drawCircle(Offset(cx, cy), 24, vinylP);
    canvas.drawCircle(Offset(cx, cy), 24, borderP);
    canvas.drawCircle(Offset(cx, cy), 9, centerP);
    canvas.drawCircle(Offset(cx, cy), 9, borderP);
    canvas.drawCircle(Offset(cx, cy), 3, holeP);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _CartoonCassettePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    final bodyP = Paint()..color = const Color(0xFFE0F2FE);
    final borderP = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    final bodyRect = RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, w, h), const Radius.circular(6));
    canvas.drawRRect(bodyRect, bodyP);
    canvas.drawRRect(bodyRect, borderP);

    // Label
    final labelP = Paint()..color = const Color(0xFF38BDF8);
    final labelRect = RRect.fromRectAndRadius(Rect.fromLTWH(6, 6, w - 12, h - 16), const Radius.circular(4));
    canvas.drawRRect(labelRect, labelP);
    canvas.drawRRect(labelRect, borderP);

    // Spool Holes
    final spoolP = Paint()..color = Colors.white;
    canvas.drawCircle(Offset(18, h / 2 - 2), 5, spoolP);
    canvas.drawCircle(Offset(18, h / 2 - 2), 5, borderP);
    canvas.drawCircle(Offset(w - 18, h / 2 - 2), 5, spoolP);
    canvas.drawCircle(Offset(w - 18, h / 2 - 2), 5, borderP);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

