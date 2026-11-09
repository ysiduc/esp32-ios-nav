import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../config/simulator_presets.dart';

/// GIAO DIỆN 4: 80s SYNTHWAVE CASSETTE (100% Pure Flutter Canvas & Widgets 320x240)
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
    final hStr = currentTime.hour.toString().padLeft(2, '0');
    final mStr = currentTime.minute.toString().padLeft(2, '0');
    final sStr = currentTime.second.toString().padLeft(2, '0');
    final dStr = 'T${currentTime.weekday == 7 ? 'CN' : currentTime.weekday + 1}, ${currentTime.day.toString().padLeft(2, '0')} TH${currentTime.month.toString().padLeft(2, '0')}';

    return Container(
      width: 320,
      height: 240,
      color: const Color(0xFF090514),
      child: Stack(
        children: [
          // Vertical divider line in purple neon at x: 158
          Positioned(
            left: 158,
            top: 10,
            bottom: 10,
            width: 1,
            child: Container(
              color: const Color(0xFF701A75).withValues(alpha: 0.6),
            ),
          ),

          // Nửa Trái Trên - Đồng hồ Synthwave (x: 8, y: 10, w: 146, h: 105)
          Positioned(
            left: 8,
            top: 10,
            width: 146,
            height: 105,
            child: _buildSynthwaveClock(hStr, mStr, sStr, dStr, currentTime.year.toString()),
          ),

          // Nửa Trái Dưới - Hộp MESSAGES (x: 8, y: 122, w: 146, h: 110)
          Positioned(
            left: 8,
            top: 122,
            width: 146,
            height: 110,
            child: _buildMessagesBox(),
          ),

          // Nửa Phải - Băng Cassette Cổ Điển & Nhạc (x: 164, y: 10, w: 148, h: 222)
          Positioned(
            left: 164,
            top: 10,
            width: 148,
            height: 222,
            child: _buildCassettePanel(),
          ),
        ],
      ),
    );
  }

  // --- Nửa Trái Trên: Đồng hồ & Mặt trời Synthwave ---
  Widget _buildSynthwaveClock(String h, String m, String s, String dateStr, String yearStr) {
    return Stack(
      children: [
        // Synthwave Sun in top-right of the clock zone
        Positioned(
          right: 4,
          top: 6,
          width: 52,
          height: 52,
          child: CustomPaint(
            painter: _SynthwaveSunPainter(),
          ),
        ),

        // Clock Text and Date
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  '$h:$m',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 40,
                    fontWeight: FontWeight.w900,
                    fontFamily: 'monospace',
                    letterSpacing: -1.5,
                    shadows: [
                      Shadow(color: Color(0xFFEC4899), blurRadius: 14),
                      Shadow(color: Color(0xFFBE185D), blurRadius: 24),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  s,
                  style: const TextStyle(
                    color: Color(0xFFFACC15),
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Text(
                  dateStr,
                  style: const TextStyle(
                    color: Color(0xFF22D3EE),
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  yearStr,
                  style: const TextStyle(
                    color: Color(0xFFFACC15),
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  // --- Nửa Trái Dưới: Hộp MESSAGES ---
  Widget _buildMessagesBox() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF13091E).withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFEC4899), width: 1.4),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFEC4899).withValues(alpha: 0.25),
            blurRadius: 10,
          ),
        ],
      ),
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: MESSAGES + Lightning
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: const [
              Row(
                children: [
                  Icon(Icons.chat_bubble_rounded, color: Color(0xFFF472B6), size: 12),
                  SizedBox(width: 4),
                  Text(
                    'MESSAGES',
                    style: TextStyle(
                      color: Color(0xFFF472B6),
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.6,
                    ),
                  ),
                ],
              ),
              Icon(Icons.bolt_rounded, color: Color(0xFF22D3EE), size: 14),
            ],
          ),
          const SizedBox(height: 6),

          // Message Body
          Expanded(
            child: Text(
              '${mockData.sender}:\n"${mockData.message}"',
              style: const TextStyle(
                color: Color(0xFFA5F3FC),
                fontSize: 11.5,
                fontWeight: FontWeight.bold,
                height: 1.25,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),

          // Bottom: 3 Lightning bolts + Heartbeat line
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: const [
                  Icon(Icons.flash_on_rounded, color: Color(0xFFEC4899), size: 11),
                  Icon(Icons.flash_on_rounded, color: Color(0xFFFACC15), size: 11),
                  Icon(Icons.flash_on_rounded, color: Color(0xFF22D3EE), size: 11),
                ],
              ),
              // Mini EKG line
              CustomPaint(
                size: const Size(40, 10),
                painter: _HeartbeatPainter(),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // --- Nửa Phải: Băng Cassette 2D Cổ Điển ---
  Widget _buildCassettePanel() {
    return Column(
      children: [
        // Cassette 2D Body
        Expanded(
          child: CustomPaint(
            size: const Size(double.infinity, double.infinity),
            painter: _DetailedCassetteTapePainter(
              songTitle: mockData.songTitle.toUpperCase(),
              artist: mockData.songArtist.toUpperCase(),
              progress: mockData.songProgress,
            ),
          ),
        ),
        const SizedBox(height: 6),

        // Time and Progress Bar below Cassette
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              mockData.elapsedStr,
              style: const TextStyle(
                color: Color(0xFF22D3EE),
                fontSize: 10,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
              ),
            ),
            Text(
              mockData.durationStr,
              style: const TextStyle(
                color: Color(0xFF22D3EE),
                fontSize: 10,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ),
        const SizedBox(height: 3),

        // Cyan capsule progress bar
        Container(
          width: double.infinity,
          height: 6,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: const Color(0xFF22D3EE), width: 1),
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Container(
              width: 148 * mockData.songProgress,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                color: const Color(0xFF22D3EE),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Mặt trời Synthwave gradient vàng-hồng có sọc ngang
class _SynthwaveSunPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2;

    final sunGrad = const LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xFFFDE047), Color(0xFFF97316), Color(0xFFEC4899)],
    ).createShader(Rect.fromCircle(center: center, radius: r));

    canvas.drawCircle(center, r, Paint()..shader = sunGrad);

    // Dark horizontal slits in bottom half
    final darkP = Paint()..color = const Color(0xFF090514);
    for (int i = 0; i < 4; i++) {
      final y = center.dy + 4 + (i * 6.0);
      final h = 1.0 + (i * 0.8);
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, h), darkP);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Mini Heartbeat / EKG line
class _HeartbeatPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = const Color(0xFFEC4899)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    final path = Path();
    path.moveTo(0, size.height / 2);
    path.lineTo(12, size.height / 2);
    path.lineTo(16, 1);
    path.lineTo(22, size.height - 1);
    path.lineTo(26, size.height / 2);
    path.lineTo(size.width, size.height / 2);

    canvas.drawPath(path, p);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Băng Cassette 2D chi tiết với 2 trục quay bánh răng màu vàng
class _DetailedCassetteTapePainter extends CustomPainter {
  final String songTitle;
  final String artist;
  final double progress;

  _DetailedCassetteTapePainter({
    required this.songTitle,
    required this.artist,
    required this.progress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // 1. Cassette Outer Plastic Shell (Purple with Neon Pink Border)
    final shellRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(2, 2, w - 4, h - 4),
      const Radius.circular(8),
    );
    canvas.drawRRect(shellRect, Paint()..color = const Color(0xFF5B21B6));
    canvas.drawRRect(
      shellRect,
      Paint()
        ..color = const Color(0xFFEC4899)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    // 2. Screws in 4 corners
    final screwP = Paint()..color = const Color(0xFFC084FC);
    canvas.drawCircle(const Offset(8, 8), 1.8, screwP);
    canvas.drawCircle(Offset(w - 8, 8), 1.8, screwP);
    canvas.drawCircle(Offset(14, h - 8), 1.8, screwP);
    canvas.drawCircle(Offset(w - 14, h - 8), 1.8, screwP);

    // 3. Top Label (Side A Badge + Song Title)
    final labelTop = RRect.fromRectAndRadius(
      Rect.fromLTWH(10, 12, w - 20, 26),
      const Radius.circular(4),
    );
    canvas.drawRRect(labelTop, Paint()..color = const Color(0xFF2E1065));

    // Badge "A"
    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(14, 15, 14, 20), const Radius.circular(3)),
      Paint()..color = const Color(0xFFEC4899),
    );
    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    textPainter.text = const TextSpan(
      text: 'A',
      style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
    );
    textPainter.layout();
    textPainter.paint(canvas, const Offset(17, 18));

    // Dynamic Song Title in Label
    textPainter.text = TextSpan(
      text: songTitle,
      style: const TextStyle(color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.w900),
    );
    textPainter.layout(maxWidth: w - 55);
    textPainter.paint(canvas, const Offset(34, 19));

    // 4. Center Clear Window with 2 Rotating Tape Reels
    final windowRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(14, 44, w - 28, 54),
      const Radius.circular(6),
    );
    canvas.drawRRect(windowRect, Paint()..color = const Color(0xFF1E1135));
    canvas.drawRRect(
      windowRect,
      Paint()
        ..color = const Color(0xFFD946EF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );

    // Tape Bridge between reels
    canvas.drawRect(
      Rect.fromLTWH(30, 68, w - 60, 6),
      Paint()..color = const Color(0xFF3B0764),
    );

    // Reel 1 (Left, center at x: 42, y: 71)
    _drawReel(canvas, const Offset(42, 71), 16, progress * 4 * math.pi);

    // Reel 2 (Right, center at x: w - 42, y: 71)
    _drawReel(canvas, Offset(w - 42, 71), 16, progress * 4 * math.pi);

    // 5. Bottom Label (Artist Name)
    final labelBottom = RRect.fromRectAndRadius(
      Rect.fromLTWH(10, 104, w - 20, 20),
      const Radius.circular(4),
    );
    canvas.drawRRect(labelBottom, Paint()..color = const Color(0xFF2E1065));

    textPainter.text = TextSpan(
      text: artist,
      style: const TextStyle(color: Color(0xFFFDE047), fontSize: 9, fontWeight: FontWeight.bold),
    );
    textPainter.layout(maxWidth: w - 24);
    textPainter.paint(canvas, Offset((w - textPainter.width) / 2, 108));

    // 6. Bottom Trapezoid Section & 4 Holes
    final trap = Path();
    trap.moveTo(22, h - 4);
    trap.lineTo(34, 130);
    trap.lineTo(w - 34, 130);
    trap.lineTo(w - 22, h - 4);
    trap.close();
    canvas.drawPath(trap, Paint()..color = const Color(0xFF4C1D95));
    canvas.drawPath(
      trap,
      Paint()
        ..color = const Color(0xFFEC4899)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    // 4 Tape Guide Holes
    final holeP = Paint()..color = const Color(0xFF090514);
    canvas.drawCircle(Offset(44, h - 14), 3.5, holeP);
    canvas.drawCircle(Offset(64, h - 14), 2.5, holeP);
    canvas.drawCircle(Offset(w - 64, h - 14), 2.5, holeP);
    canvas.drawCircle(Offset(w - 44, h - 14), 3.5, holeP);
  }

  void _drawReel(Canvas canvas, Offset center, double radius, double rotAngle) {
    // White hub circle
    canvas.drawCircle(center, radius, Paint()..color = Colors.white);
    canvas.drawCircle(center, radius, Paint()..color = Colors.black..style = PaintingStyle.stroke..strokeWidth = 1);

    // 6 Gold Teeth
    final toothPaint = Paint()..color = const Color(0xFFFACC15);
    for (int i = 0; i < 6; i++) {
      final a = rotAngle + (i * 60 * math.pi / 180);
      final tx = center.dx + (radius * 0.65) * math.cos(a);
      final ty = center.dy + (radius * 0.65) * math.sin(a);
      canvas.drawCircle(Offset(tx, ty), 2.2, toothPaint);
    }

    // Center Hole
    canvas.drawCircle(center, 4, Paint()..color = const Color(0xFF1E1135));
  }

  @override
  bool shouldRepaint(covariant _DetailedCassetteTapePainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.songTitle != songTitle;
}
