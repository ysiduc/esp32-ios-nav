import 'package:flutter/material.dart';
import '../../config/simulator_presets.dart';

/// Theme 3: Retro Macintosh OS (retroMac) - Matches Photo 3 Pixel-by-Pixel
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
      color: const Color(0xFF6B767E),
      child: Stack(
        children: [
          // 0. Fine Pixel Dither Pattern Background
          Positioned.fill(
            child: CustomPaint(
              painter: _MacDitherPainter(),
            ),
          ),

          // 1. Top White Mac Menu Bar (height: 14px)
          Positioned(
            left: 0,
            top: 0,
            right: 0,
            height: 14,
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
                children: [
                  // Rainbow Apple Icon
                  const Text('🍎', style: TextStyle(fontSize: 9)),
                  const SizedBox(width: 4),
                  const Text(
                    'Retro Macintosh/OS',
                    style: TextStyle(
                      color: Colors.black,
                      fontSize: 8.5,
                      fontWeight: FontWeight.w900,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ),
          ),

          // 2. Desktop Icons on Right (My Computer & Trash)
          Positioned(
            left: 172,
            top: 20,
            child: _buildDesktopIcon(Icons.computer_rounded, 'My Computer'),
          ),
          Positioned(
            right: 18,
            top: 20,
            child: _buildDesktopIcon(Icons.delete_outline_rounded, 'Trash'),
          ),
          Positioned(
            right: 18,
            bottom: 12,
            child: _buildDesktopIcon(Icons.delete_rounded, 'Thùng rác'),
          ),

          // 3. Window 1: CLOCK.EXE (x: 8, y: 22, w: 146, h: 84)
          Positioned(
            left: 8,
            top: 22,
            width: 146,
            height: 84,
            child: _buildClockWindow(hStr, mStr, sStr, dStr, dayEn),
          ),

          // 4. Window 2: MAIL.APP (x: 8, y: 112, w: 146, h: 82)
          Positioned(
            left: 8,
            top: 112,
            width: 146,
            height: 82,
            child: _buildMailWindow(),
          ),

          // 5. Window 3: PLAYER.EXE (x: 160, y: 52, w: 152, h: 120)
          Positioned(
            left: 160,
            top: 52,
            width: 152,
            height: 120,
            child: _buildPlayerWindow(),
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

  Widget _buildClockWindow(String h, String m, String s, String dStr, String dayEn) {
    return _buildClassicWindow(
      title: 'CLOCK.EXE',
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  '$h:$m',
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 26,
                    fontWeight: FontWeight.w900,
                    fontFamily: 'monospace',
                    letterSpacing: -1,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  s,
                  style: const TextStyle(
                    color: Color(0xFF6B7280),
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              dStr,
              style: const TextStyle(
                color: Colors.black,
                fontSize: 10,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
              ),
            ),
            Text(
              dayEn,
              style: const TextStyle(
                color: Colors.black,
                fontSize: 9.5,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMailWindow() {
    return _buildClassicWindow(
      title: 'MAIL.APP',
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.mail_outline_rounded, size: 13, color: Colors.black),
                const SizedBox(width: 4),
                Text(
                  'From: ${mockData.sender}',
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 9.5,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              mockData.message,
              style: const TextStyle(
                color: Colors.black,
                fontSize: 9.5,
                fontFamily: 'monospace',
                height: 1.25,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlayerWindow() {
    return _buildClassicWindow(
      title: 'PLAYER.EXE',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Black Title Strip
          Container(
            color: Colors.black,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Text(
              mockData.fullSongTitle,
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

          // Center: Vinyl Disk + Equalizer
          Expanded(
            child: Row(
              children: [
                const SizedBox(width: 6),
                // Vinyl Record
                CustomPaint(
                  size: const Size(44, 44),
                  painter: _VinylRecordPainter(),
                ),
                const SizedBox(width: 8),
                // Equalizer wave
                Expanded(
                  child: CustomPaint(
                    size: const Size(double.infinity, 38),
                    painter: _PixelEqualizerPainter(),
                  ),
                ),
                const SizedBox(width: 6),
              ],
            ),
          ),

          // Player Buttons
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: const [
                    Text('|<< ', style: TextStyle(fontSize: 8, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
                    Text('> ', style: TextStyle(fontSize: 8, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
                    Text('|| ', style: TextStyle(fontSize: 8, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
                    Text('>>|', style: TextStyle(fontSize: 8, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
                  ],
                ),
                Text(
                  mockData.timeRatioStr,
                  style: const TextStyle(fontSize: 7.5, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildClassicWindow({required String title, required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.black, width: 1.2),
        boxShadow: const [
          BoxShadow(
            color: Colors.black54,
            offset: Offset(2, 2),
            blurRadius: 0,
          ),
        ],
      ),
      child: Column(
        children: [
          // Striped Window Title Bar
          Container(
            height: 12,
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Colors.black, width: 1.0)),
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(painter: _TitleStripesPainter()),
                ),
                Center(
                  child: Container(
                    color: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      title,
                      style: const TextStyle(
                        color: Colors.black,
                        fontSize: 7.5,
                        fontWeight: FontWeight.w900,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: 2,
                  top: 1,
                  bottom: 1,
                  child: Container(
                    width: 9,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.black, width: 0.8),
                    ),
                    child: const Center(
                      child: Text('x', style: TextStyle(fontSize: 6, fontWeight: FontWeight.bold, height: 1.0)),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Window Body
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _MacDitherPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final ditherP = Paint()
      ..color = Colors.black.withValues(alpha: 0.08)
      ..strokeWidth = 1.0;

    for (double y = 0; y < size.height; y += 2) {
      for (double x = (y % 4 == 0) ? 0 : 2; x < size.width; x += 4) {
        canvas.drawCircle(Offset(x, y), 0.6, ditherP);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _TitleStripesPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.black
      ..strokeWidth = 0.8;
    for (double y = 2; y < size.height - 1; y += 2) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _VinylRecordPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;

    final discP = Paint()..color = const Color(0xFF1E2124);
    final grooveP = Paint()
      ..color = const Color(0xFF4B5563)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;
    final labelP = Paint()..color = Colors.white;
    final holeP = Paint()..color = const Color(0xFF111827);

    canvas.drawCircle(Offset(cx, cy), 20, discP);
    canvas.drawCircle(Offset(cx, cy), 16, grooveP);
    canvas.drawCircle(Offset(cx, cy), 12, grooveP);
    canvas.drawCircle(Offset(cx, cy), 8, labelP);
    canvas.drawCircle(Offset(cx, cy), 2.5, holeP);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _PixelEqualizerPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.fill;

    const cols = 8;
    const heights = [14.0, 22.0, 18.0, 28.0, 24.0, 16.0, 20.0, 12.0];
    final colW = size.width / cols;

    for (int i = 0; i < cols; i++) {
      final h = heights[i];
      for (double y = 0; y < h; y += 3) {
        canvas.drawRect(Rect.fromLTWH(i * colW + 1, size.height - y - 2, colW - 2, 2), p);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
