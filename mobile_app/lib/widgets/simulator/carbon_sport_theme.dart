import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../config/simulator_presets.dart';

/// GIAO DIỆN 1: SUNFLOWER BENTO GRID (100% Pure Flutter Canvas & Widgets 320x240)
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
      color: const Color(0xFF12100E),
      child: Stack(
        children: [
          // Ô 1 - Đồng hồ (Góc trên trái: x: 8, y: 8, w: 148, h: 92)
          Positioned(
            left: 8,
            top: 8,
            width: 148,
            height: 92,
            child: _buildClockCard(hStr, mStr, sStr, dateStr),
          ),

          // Ô 2 - Hoa Hướng Dương Nghệ Thuật (Góc dưới trái: x: 8, y: 106, w: 148, h: 86)
          Positioned(
            left: 8,
            top: 106,
            width: 148,
            height: 86,
            child: _buildSunflowerArtCard(),
          ),

          // Ô 3 - Tin nhắn mới (Cột phải: x: 162, y: 8, w: 150, h: 184)
          Positioned(
            left: 162,
            top: 8,
            width: 150,
            height: 184,
            child: _buildMessageCard(),
          ),

          // Ô 4 - Thanh Nhạc Đang Phát (Đáy: x: 8, y: 198, w: 304, h: 36)
          Positioned(
            left: 8,
            top: 198,
            width: 304,
            height: 36,
            child: _buildMusicBar(),
          ),
        ],
      ),
    );
  }

  // --- Ô 1: Đồng hồ & Thứ Ngày ---
  Widget _buildClockCard(String h, String m, String s, String dateStr) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF29231C),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF6B5B45), width: 1.2),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Stack(
        children: [
          // Watermark sunflower faint at bottom right
          Positioned(
            right: -6,
            bottom: -6,
            width: 48,
            height: 48,
            child: Opacity(
              opacity: 0.18,
              child: CustomPaint(
                painter: _SingleSunflowerPainter(hasStem: false),
              ),
            ),
          ),

          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Dòng Giờ : Phút + Giây
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    '$h:$m',
                    style: const TextStyle(
                      color: Color(0xFFFACC15),
                      fontSize: 34,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -1.0,
                      height: 1.0,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    s,
                    style: const TextStyle(
                      color: Color(0xFFF97316),
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      height: 1.0,
                    ),
                  ),
                ],
              ),

              // Dòng Thứ & Ngày
              Text(
                dateStr,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // --- Ô 2: Hoa Hướng Dương 2D Nghệ Thuật ---
  Widget _buildSunflowerArtCard() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1C1917),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF44403C), width: 1.2),
      ),
      clipBehavior: Clip.antiAlias,
      child: CustomPaint(
        painter: _TwinSunflowersPainter(),
      ),
    );
  }

  // --- Ô 3: Tin nhắn mới ---
  Widget _buildMessageCard() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0F0E0E),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFACC15), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFFACC15).withValues(alpha: 0.12),
            blurRadius: 10,
          ),
        ],
      ),
      padding: const EdgeInsets.all(10),
      child: Stack(
        children: [
          // Corner decorative sunflower with stem at bottom-right
          Positioned(
            right: -8,
            bottom: -6,
            width: 72,
            height: 72,
            child: Opacity(
              opacity: 0.95,
              child: CustomPaint(
                painter: _SingleSunflowerPainter(hasStem: true),
              ),
            ),
          ),

          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header: Chat bubble + "TIN NHẮN MỚI"
              Row(
                children: const [
                  Icon(Icons.chat_bubble_rounded, color: Color(0xFFFB923C), size: 13),
                  SizedBox(width: 5),
                  Text(
                    'TIN NHẮN MỚI',
                    style: TextStyle(
                      color: Color(0xFFFB923C),
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.6,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // Sender name
              Text(
                mockData.sender,
                style: const TextStyle(
                  color: Color(0xFFFACC15),
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),

              // Message Body
              Expanded(
                child: Text(
                  mockData.message,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    height: 1.3,
                  ),
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // --- Ô 4: Thanh Nhạc Đang Phát ---
  Widget _buildMusicBar() {
    final progress = mockData.songProgress;
    const totalDots = 18;
    final activeDotIndex = (progress * (totalDots - 1)).round();

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1C1917),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF44403C), width: 1.2),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Row(
        children: [
          // Left: Sunflower + Note icon
          const Icon(Icons.wb_sunny_rounded, color: Color(0xFFFACC15), size: 14),
          const SizedBox(width: 3),
          const Icon(Icons.music_note_rounded, color: Color(0xFFFACC15), size: 14),
          const SizedBox(width: 8),

          // Middle: Dynamic Song title - Artist + Dot Progress Bar
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${mockData.songTitle} - ${mockData.songArtist}',
                  style: const TextStyle(
                    color: Color(0xFFFEF08A),
                    fontSize: 10.5,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                // Dot progress line
                Row(
                  children: List.generate(totalDots, (i) {
                    final isCurrent = i == activeDotIndex;
                    final isPast = i < activeDotIndex;
                    return Container(
                      margin: const EdgeInsets.symmetric(horizontal: 1.2),
                      width: isCurrent ? 5.0 : 3.0,
                      height: isCurrent ? 5.0 : 3.0,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isCurrent
                            ? const Color(0xFFF97316)
                            : (isPast ? const Color(0xFFFB923C) : const Color(0xFF52525B)),
                      ),
                    );
                  }),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),

          // Right: cur / tot
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                mockData.elapsedStr,
                style: const TextStyle(
                  color: Color(0xFFF97316),
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                mockData.durationStr,
                style: const TextStyle(
                  color: Color(0xFFA1A1AA),
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

  String _formatDateVietnamese(DateTime dt) {
    const days = ['THỨ HAI', 'THỨ BA', 'THỨ TƯ', 'THỨ NĂM', 'THỨ SÁU', 'THỨ BẢY', 'CHỦ NHẬT'];
    final dow = days[dt.weekday - 1];
    final d = dt.day.toString().padLeft(2, '0');
    final m = dt.month.toString().padLeft(2, '0');
    return '$dow, $d/$m';
  }
}

/// Painter vẽ 2 bông hoa hướng dương nghệ thuật 2D ở Ô 2
class _TwinSunflowersPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // 1. Vẽ lá xanh ở dưới
    final leafPaint = Paint()..color = const Color(0xFF3F6212);
    final leafVeinPaint = Paint()
      ..color = const Color(0xFF4D7C0F)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    // Lá 1 bên trái
    final leaf1 = Path();
    leaf1.moveTo(15, size.height);
    leaf1.quadraticBezierTo(20, 25, 45, 35);
    leaf1.quadraticBezierTo(50, 70, 45, size.height);
    leaf1.close();
    canvas.drawPath(leaf1, leafPaint);
    canvas.drawLine(const Offset(25, 75), const Offset(42, 40), leafVeinPaint);

    // Lá 2 ở giữa
    final leaf2 = Path();
    leaf2.moveTo(70, size.height);
    leaf2.quadraticBezierTo(90, 40, 115, 50);
    leaf2.quadraticBezierTo(105, 80, 95, size.height);
    leaf2.close();
    canvas.drawPath(leaf2, leafPaint);

    // 2. Bông hoa 1 (Lớn, góc dưới trái)
    _drawSunflower(canvas, const Offset(48, 62), 34, 14);

    // 3. Bông hoa 2 (Vừa, góc phải hơi chếch lên)
    _drawSunflower(canvas, const Offset(106, 44), 30, 12);
  }

  void _drawSunflower(Canvas canvas, Offset center, double outerR, double innerR) {
    final petalGold = Paint()..color = const Color(0xFFFBBF24);
    final petalOrange = Paint()..color = const Color(0xFFF59E0B);
    final centerDark = Paint()..color = const Color(0xFF451A03);
    final seedGold = Paint()..color = const Color(0xFFFDE047);

    const int petalCount = 14;
    // Layer 1: Cánh hoa cam phía sau
    for (int i = 0; i < petalCount; i++) {
      final angle = (i * 360 / petalCount + 12) * math.pi / 180;
      final tipX = center.dx + outerR * math.cos(angle);
      final tipY = center.dy + outerR * math.sin(angle);

      final p = Path();
      p.moveTo(center.dx, center.dy);
      p.lineTo(tipX + 3 * math.sin(angle), tipY - 3 * math.cos(angle));
      p.lineTo(tipX, tipY);
      p.lineTo(tipX - 3 * math.sin(angle), tipY + 3 * math.cos(angle));
      p.close();
      canvas.drawPath(p, petalOrange);
    }

    // Layer 2: Cánh hoa vàng phía trước
    for (int i = 0; i < petalCount; i++) {
      final angle = (i * 360 / petalCount) * math.pi / 180;
      final tipX = center.dx + (outerR - 2) * math.cos(angle);
      final tipY = center.dy + (outerR - 2) * math.sin(angle);

      final p = Path();
      p.moveTo(center.dx, center.dy);
      p.lineTo(tipX + 4 * math.sin(angle), tipY - 4 * math.cos(angle));
      p.lineTo(tipX, tipY);
      p.lineTo(tipX - 4 * math.sin(angle), tipY + 4 * math.cos(angle));
      p.close();
      canvas.drawPath(p, petalGold);
    }

    // Nhụy hoa tròn nâu đậm
    canvas.drawCircle(center, innerR, centerDark);

    // Hạt nhụy vàng li ti
    for (int s = 0; s < 7; s++) {
      final sAngle = s * 51 * math.pi / 180;
      final sx = center.dx + (innerR * 0.55) * math.cos(sAngle);
      final sy = center.dy + (innerR * 0.55) * math.sin(sAngle);
      canvas.drawCircle(Offset(sx, sy), 1.2, seedGold);
    }
    canvas.drawCircle(center, 1.4, seedGold);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Painter vẽ 1 bông hoa hướng dương kèm cành lá trang trí góc (cho Ô 1 & Ô 3)
class _SingleSunflowerPainter extends CustomPainter {
  final bool hasStem;
  _SingleSunflowerPainter({this.hasStem = false});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width * 0.6, size.height * 0.6);

    if (hasStem) {
      final stemPaint = Paint()
        ..color = const Color(0xFF4D7C0F)
        ..strokeWidth = 2.0
        ..style = PaintingStyle.stroke;
      final stemPath = Path();
      stemPath.moveTo(center.dx, center.dy);
      stemPath.quadraticBezierTo(center.dx - 10, size.height * 0.85, center.dx - 20, size.height);
      canvas.drawPath(stemPath, stemPaint);

      // Chiếc lá nhỏ bên cành
      final leafP = Paint()..color = const Color(0xFF3F6212);
      final leaf = Path();
      leaf.moveTo(center.dx - 12, size.height * 0.88);
      leaf.quadraticBezierTo(center.dx - 28, size.height * 0.80, center.dx - 30, size.height * 0.90);
      leaf.close();
      canvas.drawPath(leaf, leafP);
    }

    final petalPaint = Paint()..color = const Color(0xFFFBBF24);
    const int petals = 12;
    const double r = 20;

    for (int i = 0; i < petals; i++) {
      final a = (i * 360 / petals) * math.pi / 180;
      final tx = center.dx + r * math.cos(a);
      final ty = center.dy + r * math.sin(a);
      final p = Path();
      p.moveTo(center.dx, center.dy);
      p.lineTo(tx + 2.5 * math.sin(a), ty - 2.5 * math.cos(a));
      p.lineTo(tx, ty);
      p.lineTo(tx - 2.5 * math.sin(a), ty + 2.5 * math.cos(a));
      p.close();
      canvas.drawPath(p, petalPaint);
    }

    canvas.drawCircle(center, 8.5, Paint()..color = const Color(0xFF451A03));
    canvas.drawCircle(center, 1.2, Paint()..color = const Color(0xFFFDE047));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
