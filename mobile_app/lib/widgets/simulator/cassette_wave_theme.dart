import 'package:flutter/material.dart';
import '../../config/simulator_presets.dart';

/// Theme 4: Cassette Retro Wave (cassetteWave) - Matches Photo 4 Pixel-by-Pixel
class CassetteWaveTheme extends StatelessWidget {
  final DateTime currentTime;
  final SimulatorMockData mockData;

  const CassetteWaveTheme({
    super.key,
    required this.currentTime,
    this.mockData = SimulatorMockData.defaultPreset,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 320,
      height: 240,
      color: const Color(0xFF0F081D),
      child: Stack(
        children: [
          // 1. High-fidelity graphic matching reference photo 100% pixel-by-pixel
          Positioned.fill(
            child: Image.asset(
              'assets/themes/theme_cassette_wave.jpg',
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

    final dStr = 'T${currentTime.weekday == 7 ? 'CN' : currentTime.weekday + 1}, ${currentTime.day.toString().padLeft(2, '0')} TH${currentTime.month.toString().padLeft(2, '0')} ${currentTime.year}';

    return Stack(
      children: [
        Positioned(
          left: 8,
          top: 10,
          width: 152,
          height: 96,
          child: _buildClockAndSun(hStr, mStr, sStr, dStr),
        ),
        Positioned(
          left: 8,
          top: 114,
          width: 152,
          height: 116,
          child: _buildMessagesCard(),
        ),
        Positioned(
          left: 166,
          top: 10,
          width: 146,
          height: 220,
          child: _buildCassettePanel(),
        ),
      ],
    );
  }

  Widget _buildClockAndSun(String h, String m, String s, String dStr) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Big Glowing Magenta/Pink Time
            Text(
              '$h:$m',
              style: TextStyle(
                color: const Color(0xFFFF3399),
                fontSize: 34,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.5,
                shadows: [
                  BoxShadow(
                    color: const Color(0xFFFF3399).withValues(alpha: 0.8),
                    blurRadius: 16,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),

            // Segmented 80s Sunset Sun with Seconds inside
            Stack(
              alignment: Alignment.center,
              children: [
                CustomPaint(
                  size: const Size(38, 38),
                  painter: _SynthwaveSunPainter(),
                ),
                Text(
                  s,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                    shadows: [
                      BoxShadow(color: Colors.black, blurRadius: 4),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 6),
        // Neon Cyan Date
        Text(
          dStr,
          style: TextStyle(
            color: const Color(0xFF00F0FF),
            fontSize: 11.5,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.8,
            shadows: [
              BoxShadow(
                color: const Color(0xFF00F0FF).withValues(alpha: 0.6),
                blurRadius: 8,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMessagesCard() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF170E2E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFF3399), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFFF3399).withValues(alpha: 0.35),
            blurRadius: 10,
          ),
        ],
      ),
      padding: const EdgeInsets.all(9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: MESSAGES + Lightning
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: const [
              Row(
                children: [
                  Icon(Icons.chat_bubble_rounded, color: Colors.white, size: 12),
                  SizedBox(width: 5),
                  Text(
                    'MESSAGES',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.8,
                    ),
                  ),
                ],
              ),
              Icon(Icons.flash_on_rounded, color: Color(0xFF00F0FF), size: 14),
            ],
          ),
          const SizedBox(height: 6),

          // Message Body
          Expanded(
            child: Text(
              '${mockData.sender}: "${mockData.message}"',
              style: TextStyle(
                color: const Color(0xFF00F0FF),
                fontSize: 12,
                fontWeight: FontWeight.w700,
                height: 1.25,
                shadows: [
                  BoxShadow(
                    color: const Color(0xFF00F0FF).withValues(alpha: 0.45),
                    blurRadius: 6,
                  ),
                ],
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),

          // Bottom lightning icons & wave
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: const [
              Row(
                children: [
                  Icon(Icons.bolt_rounded, color: Color(0xFFFF3399), size: 13),
                  Icon(Icons.bolt_rounded, color: Color(0xFF00F0FF), size: 13),
                  Icon(Icons.bolt_rounded, color: Color(0xFFFDE047), size: 13),
                ],
              ),
              Icon(Icons.graphic_eq_rounded, color: Color(0xFF00F0FF), size: 14),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCassettePanel() {
    return Column(
      children: [
        // 2D Vector Cassette Tape
        Container(
          width: 146,
          height: 160,
          decoration: BoxDecoration(
            color: const Color(0xFF2E1052),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFFF3399), width: 1.6),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFFF3399).withValues(alpha: 0.35),
                blurRadius: 10,
              ),
            ],
          ),
          child: CustomPaint(
            painter: _CassetteTapePainter(
              songTitle: mockData.songTitle,
              songArtist: mockData.songArtist,
            ),
          ),
        ),
        const SizedBox(height: 10),

        // Progress Bar & Time
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              mockData.elapsedStr,
              style: const TextStyle(color: Color(0xFF00F0FF), fontSize: 9.5, fontWeight: FontWeight.bold),
            ),
            Text(
              mockData.durationStr,
              style: const TextStyle(color: Color(0xFF00F0FF), fontSize: 9.5, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Container(
          height: 6,
          decoration: BoxDecoration(
            color: const Color(0xFF1E1035),
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: const Color(0xFF00F0FF), width: 0.8),
          ),
          child: FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: mockData.songProgress,
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF00F0FF),
                borderRadius: BorderRadius.circular(2),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF00F0FF).withValues(alpha: 0.8),
                    blurRadius: 6,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SynthwaveSunPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width / 2;

    // Gradient background circle
    final sunP = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFFFDE047), Color(0xFFF97316), Color(0xFFFF3399)],
      ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: r));

    canvas.drawCircle(Offset(cx, cy), r, sunP);

    // Segmented horizontal cut lines
    final cutP = Paint()
      ..color = const Color(0xFF0F081D)
      ..strokeWidth = 2.0;

    for (double y = cy + 2; y < cy + r; y += 4.5) {
      canvas.drawLine(Offset(cx - r, y), Offset(cx + r, y), cutP);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _CassetteTapePainter extends CustomPainter {
  final String songTitle;
  final String songArtist;

  _CassetteTapePainter({required this.songTitle, required this.songArtist});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;

    // 1. Screws in corners
    final screwP = Paint()..color = const Color(0xFF6B21A8);
    canvas.drawCircle(const Offset(8, 8), 2.5, screwP);
    canvas.drawCircle(Offset(w - 8, 8), 2.5, screwP);
    canvas.drawCircle(const Offset(8, 140), 2.5, screwP);
    canvas.drawCircle(Offset(w - 8, 140), 2.5, screwP);

    // 2. White Cassette Label (Upper section)
    final labelP = Paint()..color = const Color(0xFFFAF5FF);
    final labelBorder = Paint()
      ..color = const Color(0xFFFF3399)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    final labelRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(12, 14, w - 24, 76),
      const Radius.circular(6),
    );
    canvas.drawRRect(labelRect, labelP);
    canvas.drawRRect(labelRect, labelBorder);

    // Text "A" badge + Song title on label
    final sideAPaint = Paint()..color = const Color(0xFFFF3399);
    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(16, 18, 14, 14), const Radius.circular(3)),
      sideAPaint,
    );

    // Text on label
    final textPainter = TextPainter(
      text: TextSpan(
        children: [
          TextSpan(
            text: '$songTitle\n',
            style: const TextStyle(color: Color(0xFF1E1035), fontSize: 9.5, fontWeight: FontWeight.w900),
          ),
          TextSpan(
            text: songArtist,
            style: const TextStyle(color: Color(0xFF6B21A8), fontSize: 8.5, fontWeight: FontWeight.bold),
          ),
        ],
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: w - 60);
    textPainter.paint(canvas, const Offset(36, 17));

    // 3. Center Reel Window with Spools
    final reelWindowP = Paint()..color = const Color(0xFF1A0A2E);
    final reelWindowRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(24, 48, w - 48, 34),
      const Radius.circular(4),
    );
    canvas.drawRRect(reelWindowRect, reelWindowP);

    // Spools (Yellow gear reels)
    final spoolP = Paint()..color = const Color(0xFFFACC15);
    final centerP = Paint()..color = const Color(0xFF1A0A2E);

    _drawSpool(canvas, 46, 65, spoolP, centerP);
    _drawSpool(canvas, w - 46, 65, spoolP, centerP);

    // 4. Bottom Trapezoid Tape Guide
    final guideP = Paint()..color = const Color(0xFF240C42);
    final guidePath = Path()
      ..moveTo(22, 114)
      ..lineTo(w - 22, 114)
      ..lineTo(w - 32, 148)
      ..lineTo(32, 148)
      ..close();
    canvas.drawPath(guidePath, guideP);

    // Tape guide holes
    final holeP = Paint()..color = const Color(0xFF0F081D);
    canvas.drawCircle(const Offset(48, 134), 4, holeP);
    canvas.drawCircle(Offset(w - 48, 134), 4, holeP);
  }

  void _drawSpool(Canvas canvas, double cx, double cy, Paint spoolP, Paint centerP) {
    canvas.drawCircle(Offset(cx, cy), 10, spoolP);
    canvas.drawCircle(Offset(cx, cy), 5, centerP);
  }

  @override
  bool shouldRepaint(covariant _CassetteTapePainter oldDelegate) =>
      oldDelegate.songTitle != songTitle || oldDelegate.songArtist != songArtist;
}
