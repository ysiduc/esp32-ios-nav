import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../config/simulator_presets.dart';

/// Theme 1: Sunflower Carbon HUD (carbonSport) - Matches Photo 1 Pixel-by-Pixel
class CarbonSportTheme extends StatelessWidget {
  final DateTime currentTime;
  final SimulatorMockData mockData;

  const CarbonSportTheme({
    super.key,
    required this.currentTime,
    this.mockData = SimulatorMockData.defaultPreset,
  });

  @override
  Widget build(BuildContext context) {
    final hStr = currentTime.hour.toString().padLeft(2, '0');
    final mStr = currentTime.minute.toString().padLeft(2, '0');
    final sStr = currentTime.second.toString().padLeft(2, '0');

    final dateStr = _formatDateVietnamese(currentTime);

    return Container(
      width: 320,
      height: 240,
      color: const Color(0xFF0C0E12),
      child: Stack(
        children: [
          // 1. Top-Left Clock & Date Card (x: 8, y: 8, w: 140, h: 86)
          Positioned(
            left: 8,
            top: 8,
            width: 140,
            height: 86,
            child: _buildClockCard(hStr, mStr, sStr, dateStr),
          ),

          // 2. Bottom-Left Sunflower Bouquet Card (x: 8, y: 100, w: 140, h: 86)
          Positioned(
            left: 8,
            top: 100,
            width: 140,
            height: 86,
            child: _buildSunflowerBouquetCard(),
          ),

          // 3. Right Message Card (x: 154, y: 8, w: 158, h: 178)
          Positioned(
            left: 154,
            top: 8,
            width: 158,
            height: 178,
            child: _buildMessageCard(),
          ),

          // 4. Bottom Music & Progress Bar (x: 8, y: 192, w: 304, h: 40)
          Positioned(
            left: 8,
            top: 192,
            width: 304,
            height: 40,
            child: _buildMusicBar(),
          ),
        ],
      ),
    );
  }

  Widget _buildClockCard(String h, String m, String s, String dateStr) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1B1916),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF78350F).withValues(alpha: 0.8), width: 1.2),
      ),
      child: Stack(
        children: [
          // Watermark sunflower outline in bottom right
          Positioned(
            right: -6,
            bottom: -6,
            child: Opacity(
              opacity: 0.16,
              child: CustomPaint(
                size: const Size(48, 48),
                painter: _SingleSunflowerPainter(),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
            child: Column(
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
                        color: Color(0xFFFDE047), // Vibrant yellow
                        fontSize: 32,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.5,
                        height: 1.0,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      s,
                      style: const TextStyle(
                        color: Color(0xFFF97316), // Orange
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        height: 1.0,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  dateStr,
                  style: const TextStyle(
                    color: Color(0xFFF8FAFC),
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSunflowerBouquetCard() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1B1916),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF78350F).withValues(alpha: 0.8), width: 1.2),
      ),
      clipBehavior: Clip.antiAlias,
      child: CustomPaint(
        size: const Size(140, 86),
        painter: _BouquetSunflowerPainter(),
      ),
    );
  }

  Widget _buildMessageCard() {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF1B1916),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFD97706), width: 1.5),
      ),
      child: Stack(
        children: [
          // Single standing sunflower at bottom right
          Positioned(
            right: 0,
            bottom: 0,
            child: CustomPaint(
              size: const Size(56, 68),
              painter: _StandingSunflowerPainter(),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header: Chat icon + TIN NHẮN MỚI
              Row(
                children: const [
                  Icon(Icons.chat_bubble_rounded, color: Color(0xFFF97316), size: 13),
                  SizedBox(width: 6),
                  Text(
                    'TIN NHẮN MỚI',
                    style: TextStyle(
                      color: Color(0xFFF97316),
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.8,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // Sender Name
              Text(
                mockData.sender,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 4),
              // Message Body
              SizedBox(
                width: 105,
                child: Text(
                  mockData.message,
                  style: const TextStyle(
                    color: Color(0xFFF1F5F9),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    height: 1.25,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMusicBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF1B1916),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF573418), width: 1.0),
      ),
      child: Row(
        children: [
          // Sunflower + Music Note
          Row(
            children: const [
              Icon(Icons.wb_sunny_rounded, color: Color(0xFFFBBF24), size: 14),
              SizedBox(width: 3),
              Icon(Icons.music_note_rounded, color: Color(0xFFF97316), size: 14),
            ],
          ),
          const SizedBox(width: 8),

          // Track + Dot progress bar
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  mockData.fullSongTitle,
                  style: const TextStyle(
                    color: Color(0xFFFEF08A),
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                _buildBeadProgressBar(mockData.songProgress),
              ],
            ),
          ),
          const SizedBox(width: 8),

          // Time labels (01:24 / 03:52)
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                mockData.elapsedStr,
                style: const TextStyle(
                  color: Color(0xFFF97316),
                  fontSize: 9.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                mockData.durationStr,
                style: const TextStyle(
                  color: Color(0xFF94A3B8),
                  fontSize: 8.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBeadProgressBar(double progress) {
    const totalDots = 28;
    final activeIndex = (progress * totalDots).round();

    return Row(
      children: List.generate(totalDots, (i) {
        final isHead = i == activeIndex;
        final isPassed = i < activeIndex;
        return Padding(
          padding: const EdgeInsets.only(right: 2.5),
          child: Container(
            width: isHead ? 6 : (isPassed ? 4 : 3),
            height: isHead ? 6 : (isPassed ? 4 : 3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isHead
                  ? const Color(0xFFF97316)
                  : (isPassed ? const Color(0xFFE5A93C) : const Color(0xFF452E1B)),
              boxShadow: isHead
                  ? [
                      BoxShadow(
                        color: const Color(0xFFF97316).withValues(alpha: 0.8),
                        blurRadius: 4,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
          ),
        );
      }),
    );
  }

  String _formatDateVietnamese(DateTime dt) {
    const days = ['THỨ HAI', 'THỨ BA', 'THỨ TƯ', 'THỨ NĂM', 'THỨ SÁU', 'THỨ BẢY', 'CHỦ NHẬT'];
    final dName = days[dt.weekday - 1];
    final day = dt.day.toString().padLeft(2, '0');
    final mon = dt.month.toString().padLeft(2, '0');
    return '$dName, $day/$mon';
  }
}

// ─── Custom Vector Sunflower Painters ──────────────────────────────────────────

class _SingleSunflowerPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final petalP = Paint()
      ..color = const Color(0xFFFBBF24)
      ..style = PaintingStyle.fill;
    final centerP = Paint()
      ..color = const Color(0xFF78350F)
      ..style = PaintingStyle.fill;

    final cx = size.width / 2;
    final cy = size.height / 2;
    const numPetals = 14;

    for (int i = 0; i < numPetals; i++) {
      canvas.save();
      canvas.translate(cx, cy);
      canvas.rotate(i * 2 * math.pi / numPetals);
      canvas.drawOval(
        Rect.fromCenter(center: const Offset(16, 0), width: 16, height: 6),
        petalP,
      );
      canvas.restore();
    }
    canvas.drawCircle(Offset(cx, cy), 9, centerP);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _BouquetSunflowerPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // Leaves
    final leafP = Paint()
      ..color = const Color(0xFF47606F)
      ..style = PaintingStyle.fill;

    // Draw teal-slate leaves in background
    canvas.save();
    canvas.translate(35, 60);
    canvas.rotate(-math.pi / 4);
    canvas.drawOval(const Rect.fromLTWH(0, -10, 42, 20), leafP);
    canvas.restore();

    canvas.save();
    canvas.translate(75, 65);
    canvas.rotate(math.pi / 5);
    canvas.drawOval(const Rect.fromLTWH(0, -10, 48, 20), leafP);
    canvas.restore();

    // Left Sunflower
    _drawFlower(canvas, 48, 52, 26);
    // Right Sunflower (Slightly larger, overlapping)
    _drawFlower(canvas, 94, 42, 30);
  }

  void _drawFlower(Canvas canvas, double cx, double cy, double radius) {
    final petalP1 = Paint()..color = const Color(0xFFF59E0B);
    final petalP2 = Paint()..color = const Color(0xFFFBBF24);
    final centerP = Paint()..color = const Color(0xFF78350F);

    const petals = 16;
    for (int i = 0; i < petals; i++) {
      canvas.save();
      canvas.translate(cx, cy);
      canvas.rotate(i * 2 * math.pi / petals);
      canvas.drawOval(
        Rect.fromCenter(center: Offset(radius * 0.72, 0), width: radius * 0.8, height: radius * 0.32),
        (i % 2 == 0) ? petalP1 : petalP2,
      );
      canvas.restore();
    }
    canvas.drawCircle(Offset(cx, cy), radius * 0.42, centerP);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _StandingSunflowerPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final stemP = Paint()
      ..color = const Color(0xFFE5A93C)
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke;

    final leafP = Paint()
      ..color = const Color(0xFFE5A93C).withValues(alpha: 0.6)
      ..style = PaintingStyle.fill;

    final cx = size.width * 0.55;
    final cy = size.height * 0.45;

    // Stem
    canvas.drawLine(Offset(cx, cy + 18), Offset(cx + 6, size.height), stemP);

    // Leaves
    canvas.drawOval(Rect.fromCenter(center: Offset(cx + 12, cy + 32), width: 14, height: 6), leafP);

    // Flower head
    final petalP = Paint()..color = const Color(0xFFFBBF24);
    final centerP = Paint()..color = const Color(0xFF78350F);

    const petals = 14;
    for (int i = 0; i < petals; i++) {
      canvas.save();
      canvas.translate(cx, cy);
      canvas.rotate(i * 2 * math.pi / petals);
      canvas.drawOval(
        Rect.fromCenter(center: const Offset(13, 0), width: 14, height: 5),
        petalP,
      );
      canvas.restore();
    }
    canvas.drawCircle(Offset(cx, cy), 7, centerP);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
