import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../config/simulator_presets.dart';

/// GIAO DIỆN 3: RETRO MACINTOSH / PIXEL OS (100% Pure Flutter Canvas & Widgets 320x240)
class RetroMacTheme extends StatelessWidget {
  final DateTime currentTime;
  final SimulatorMockData mockData;

  const RetroMacTheme({
    super.key,
    required this.currentTime,
    this.mockData = SimulatorMockData.defaultPreset,
  });

  @override
  Widget build(BuildContext context) {
    final hStr = currentTime.hour.toString().padLeft(2, '0');
    final mStr = currentTime.minute.toString().padLeft(2, '0');
    final sStr = currentTime.second.toString().padLeft(2, '0');
    final dStr = '${currentTime.day.toString().padLeft(2, '0')}/${currentTime.month.toString().padLeft(2, '0')}/${currentTime.year}';
    const daysEn = ['MONDAY', 'TUESDAY', 'WEDNESDAY', 'THURSDAY', 'FRIDAY', 'SATURDAY', 'SUNDAY'];
    final dayEn = daysEn[currentTime.weekday - 1];

    return Container(
      width: 320,
      height: 240,
      color: const Color(0xFF6B7280),
      child: Stack(
        children: [
          // 0. Checkerboard Dither Pattern Canvas
          Positioned.fill(
            child: CustomPaint(
              painter: _MacCheckerboardPainter(),
            ),
          ),

          // Thanh Menu Trên Cùng (x: 0, y: 0, w: 320, h: 18)
          Positioned(
            left: 0,
            top: 0,
            right: 0,
            height: 18,
            child: _buildMenuBar(),
          ),

          // Desktop Icons on right (My Computer & Trash)
          Positioned(
            left: 172,
            top: 22,
            child: _buildDesktopIcon(Icons.computer_rounded, 'My Computer'),
          ),
          Positioned(
            right: 18,
            top: 22,
            child: _buildDesktopIcon(Icons.delete_outline_rounded, 'Trash'),
          ),
          Positioned(
            right: 18,
            bottom: 6,
            child: _buildDesktopIcon(Icons.delete_rounded, 'Thùng rác'),
          ),

          // Cửa sổ 1 - CLOCK.EXE (x: 8, y: 24, w: 146, h: 102)
          Positioned(
            left: 8,
            top: 24,
            width: 146,
            height: 102,
            child: _buildClockWindow(hStr, mStr, sStr, dStr, dayEn),
          ),

          // Cửa sổ 2 - MAIL.APP (x: 8, y: 132, w: 146, h: 100)
          Positioned(
            left: 8,
            top: 132,
            width: 146,
            height: 100,
            child: _buildMailWindow(),
          ),

          // Cửa sổ 3 - PLAYER.EXE (x: 162, y: 54, w: 150, h: 136)
          Positioned(
            left: 162,
            top: 54,
            width: 150,
            height: 136,
            child: _buildPlayerWindow(),
          ),
        ],
      ),
    );
  }

  // --- Top Menu Bar ---
  Widget _buildMenuBar() {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFF3F4F6),
        border: Border(bottom: BorderSide(color: Colors.black, width: 1)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          // 6-Color Apple Icon
          _buildAppleLogo(),
          const SizedBox(width: 5),
          const Text(
            'Retro Macintosh/OS',
            style: TextStyle(
              color: Colors.black,
              fontSize: 8.5,
              fontWeight: FontWeight.w900,
              fontFamily: 'monospace',
            ),
          ),
          const Spacer(),
          const Text(
            'Special',
            style: TextStyle(
              color: Colors.black,
              fontSize: 8.5,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAppleLogo() {
    return SizedBox(
      width: 10,
      height: 12,
      child: Column(
        children: const [
          Expanded(child: ColoredBox(color: Color(0xFF65A30D))), // Green
          Expanded(child: ColoredBox(color: Color(0xFFFACC15))), // Yellow
          Expanded(child: ColoredBox(color: Color(0xFFF97316))), // Orange
          Expanded(child: ColoredBox(color: Color(0xFFDC2626))), // Red
          Expanded(child: ColoredBox(color: Color(0xFF9333EA))), // Purple
          Expanded(child: ColoredBox(color: Color(0xFF2563EB))), // Blue
        ],
      ),
    );
  }

  // --- Cửa sổ 1: CLOCK.EXE ---
  Widget _buildClockWindow(String h, String m, String s, String dStr, String dayEn) {
    return _buildClassicWindow(
      title: '🕒 CLOCK.EXE',
      content: Padding(
        padding: const EdgeInsets.all(6),
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
                    color: Colors.black,
                    fontSize: 34,
                    fontWeight: FontWeight.w900,
                    fontFamily: 'monospace',
                    letterSpacing: -1.0,
                    height: 1.0,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  s,
                  style: const TextStyle(
                    color: Color(0xFF4B5563),
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              dStr,
              style: const TextStyle(
                color: Colors.black,
                fontSize: 10,
                fontWeight: FontWeight.w900,
                fontFamily: 'monospace',
              ),
            ),
            Text(
              dayEn,
              style: const TextStyle(
                color: Color(0xFF1F2937),
                fontSize: 9.5,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- Cửa sổ 2: MAIL.APP ---
  Widget _buildMailWindow() {
    return _buildClassicWindow(
      title: '💬 MAIL.APP',
      content: Padding(
        padding: const EdgeInsets.all(6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.mail_outline_rounded, color: Colors.black, size: 14),
                const SizedBox(width: 4),
                Text(
                  'From: ${mockData.sender}',
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 9.5,
                    fontWeight: FontWeight.w900,
                    fontFamily: 'monospace',
                    decoration: TextDecoration.underline,
                    decorationStyle: TextDecorationStyle.dotted,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Expanded(
              child: Text(
                mockData.message,
                style: const TextStyle(
                  color: Colors.black,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'monospace',
                  height: 1.25,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- Cửa sổ 3: PLAYER.EXE ---
  Widget _buildPlayerWindow() {
    return _buildClassicWindow(
      title: '🎵 PLAYER.EXE',
      content: Container(
        color: Colors.black,
        padding: const EdgeInsets.all(5),
        child: Column(
          children: [
            // Top: Song name bar
            Container(
              color: const Color(0xFF1E293B),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              width: double.infinity,
              child: Text(
                '${mockData.songTitle} - ${mockData.songArtist}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 8.5,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(height: 4),

            // Middle: CD Disc + Visualizer Spectrum
            Expanded(
              child: Row(
                children: [
                  // Spinning CD
                  SizedBox(
                    width: 44,
                    height: 44,
                    child: CustomPaint(
                      painter: _CdDiscPainter(progress: mockData.songProgress),
                    ),
                  ),
                  const SizedBox(width: 6),
                  // Audio spectrum bars
                  Expanded(
                    child: CustomPaint(
                      painter: _PixelSpectrumPainter(progress: mockData.songProgress),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),

            // Bottom 3D Bevel Buttons + Progress
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildBevelBtn('|<<'),
                _buildBevelBtn('>'),
                _buildBevelBtn('■'),
                _buildBevelBtn('>>|'),
              ],
            ),
            const SizedBox(height: 3),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  mockData.elapsedStr,
                  style: const TextStyle(color: Colors.white, fontSize: 8, fontFamily: 'monospace'),
                ),
                Expanded(
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    height: 4,
                    color: const Color(0xFF334155),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        width: 70 * mockData.songProgress,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
                Text(
                  mockData.durationStr,
                  style: const TextStyle(color: Colors.white, fontSize: 8, fontFamily: 'monospace'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // Khung cửa sổ Macintosh cổ điển viền 2px đen, thanh tiêu đề sọc, nút [X], thanh cuộn phải
  Widget _buildClassicWindow({required String title, required Widget content}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.black, width: 2),
        boxShadow: const [
          BoxShadow(color: Colors.black, offset: Offset(2, 2)),
        ],
      ),
      child: Column(
        children: [
          // Title Bar with Horizontal Retro Stripes and [X] button
          Container(
            height: 16,
            decoration: const BoxDecoration(
              color: Color(0xFFE5E7EB),
              border: Border(bottom: BorderSide(color: Colors.black, width: 1.5)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                // [X] Box button
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: Colors.black, width: 1),
                  ),
                  child: const Center(
                    child: Text('×', style: TextStyle(color: Colors.black, fontSize: 8, fontWeight: FontWeight.bold, height: 0.9)),
                  ),
                ),
                const SizedBox(width: 4),
                // Title
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 8.5,
                    fontWeight: FontWeight.w900,
                    fontFamily: 'monospace',
                  ),
                ),
                const Spacer(),
              ],
            ),
          ),

          // Content with Right Faux Scrollbar
          Expanded(
            child: Row(
              children: [
                Expanded(child: content),
                // Faux right scrollbar
                Container(
                  width: 10,
                  decoration: const BoxDecoration(
                    color: Color(0xFFE5E7EB),
                    border: Border(left: BorderSide(color: Colors.black, width: 1)),
                  ),
                  child: Column(
                    children: [
                      Container(height: 10, color: Colors.white, child: const Center(child: Text('▲', style: TextStyle(fontSize: 5)))),
                      Expanded(
                        child: Center(
                          child: Container(width: 8, height: 16, color: const Color(0xFF9CA3AF)),
                        ),
                      ),
                      Container(height: 10, color: Colors.white, child: const Center(child: Text('▼', style: TextStyle(fontSize: 5)))),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopIcon(IconData icon, String label) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: Colors.white, size: 16),
        const SizedBox(height: 1),
        Container(
          color: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.black,
              fontSize: 7.5,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBevelBtn(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: const Color(0xFFE2E8F0),
        border: Border.all(color: Colors.black, width: 1),
      ),
      child: Text(
        text,
        style: const TextStyle(color: Colors.black, fontSize: 7, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
      ),
    );
  }
}

/// Checkerboard Pattern Canvas
class _MacCheckerboardPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final darkP = Paint()..color = const Color(0xFF5F6573);
    for (double y = 0; y < size.height; y += 4) {
      for (double x = 0; x < size.width; x += 4) {
        if (((x ~/ 4) + (y ~/ 4)) % 2 == 0) {
          canvas.drawRect(Rect.fromLTWH(x, y, 2, 2), darkP);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Đĩa CD quay tròn với ánh cầu vồng
class _CdDiscPainter extends CustomPainter {
  final double progress;
  _CdDiscPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2;

    // Outer Silver Disc
    canvas.drawCircle(center, r, Paint()..color = const Color(0xFF94A3B8));
    canvas.drawCircle(center, r, Paint()..color = Colors.black..style = PaintingStyle.stroke..strokeWidth = 1);

    // Rainbow sheen reflection arc
    final sheenPaint = Paint()
      ..color = const Color(0xFF38BDF8).withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    final startAngle = progress * 2 * math.pi;
    canvas.drawArc(Rect.fromCircle(center: center, radius: r * 0.7), startAngle, math.pi / 2, false, sheenPaint);

    // Center Hole
    canvas.drawCircle(center, r * 0.35, Paint()..color = const Color(0xFFCBD5E1));
    canvas.drawCircle(center, r * 0.20, Paint()..color = Colors.black);
  }

  @override
  bool shouldRepaint(covariant _CdDiscPainter oldDelegate) => oldDelegate.progress != progress;
}

/// Cột sóng nhạc Pixel Spectrum trắng
class _PixelSpectrumPainter extends CustomPainter {
  final double progress;
  _PixelSpectrumPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = Colors.white;
    const int bars = 10;
    final w = (size.width / bars) - 1.5;

    for (int i = 0; i < bars; i++) {
      final hFactor = math.sin((i * 0.8) + (progress * 10)) * 0.5 + 0.5;
      final h = (size.height * (0.2 + 0.8 * hFactor)).clamp(2.0, size.height);
      final x = i * (w + 1.5);
      final y = size.height - h;
      canvas.drawRect(Rect.fromLTWH(x, y, w, h), p);
    }
  }

  @override
  bool shouldRepaint(covariant _PixelSpectrumPainter oldDelegate) => oldDelegate.progress != progress;
}
