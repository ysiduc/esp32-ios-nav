import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../config/simulator_presets.dart';

/// GIAO DIỆN 2: CYBERPUNK NEON HUD (100% Pure Flutter Canvas & Widgets 320x240)
class CyberRadarTheme extends StatelessWidget {
  final DateTime currentTime;
  final SimulatorMockData mockData;

  const CyberRadarTheme({
    super.key,
    required this.currentTime,
    this.mockData = SimulatorMockData.defaultPreset,
  });

  @override
  Widget build(BuildContext context) {
    final hStr = currentTime.hour.toString().padLeft(2, '0');
    final mStr = currentTime.minute.toString().padLeft(2, '0');
    final sStr = currentTime.second.toString().padLeft(2, '0');
    final dateStr = 'T${currentTime.weekday == 7 ? 'CN' : currentTime.weekday + 1}, ${currentTime.day.toString().padLeft(2, '0')}.${currentTime.month.toString().padLeft(2, '0')}.${currentTime.year}';

    return Container(
      width: 320,
      height: 240,
      color: const Color(0xFF070614),
      child: Stack(
        children: [
          // 0. Background 3D Perspective Grid & Concentric Radar Rings
          Positioned.fill(
            child: CustomPaint(
              painter: _CyberGridAndRadarPainter(),
            ),
          ),

          // Khung Trái - Đồng hồ Neon (x: 8, y: 8, w: 184, h: 176)
          Positioned(
            left: 8,
            top: 8,
            width: 184,
            height: 176,
            child: _buildClockPanel(hStr, mStr, sStr, dateStr),
          ),

          // Khung Phải - Tin nhắn Cyber (x: 196, y: 8, w: 116, h: 176)
          Positioned(
            left: 196,
            top: 8,
            width: 116,
            height: 176,
            child: _buildMessagePanel(),
          ),

          // Thanh Đáy - Sóng Nhạc Cyber (x: 8, y: 190, w: 304, h: 42)
          Positioned(
            left: 8,
            top: 190,
            width: 304,
            height: 42,
            child: _buildMusicConsole(),
          ),
        ],
      ),
    );
  }

  // --- Khung Trái: Đồng hồ Neon & HUD ---
  Widget _buildClockPanel(String h, String m, String s, String dateStr) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF070614).withValues(alpha: 0.65),
        border: Border.all(color: const Color(0xFF00F0FF), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF00F0FF).withValues(alpha: 0.20),
            blurRadius: 10,
          ),
        ],
      ),
      padding: const EdgeInsets.all(8),
      child: Stack(
        children: [
          // 4 HUD Corner Brackets and Status Tags
          const Positioned(
            left: 0,
            top: 0,
            child: Text(
              'SYS_OK',
              style: TextStyle(color: Color(0xFF00F0FF), fontSize: 7, fontWeight: FontWeight.bold, letterSpacing: 0.5),
            ),
          ),
          const Positioned(
            right: 0,
            top: 0,
            child: Text(
              'BT_WS_ON',
              style: TextStyle(color: Color(0xFF00F0FF), fontSize: 7, fontWeight: FontWeight.bold, letterSpacing: 0.5),
            ),
          ),
          const Positioned(
            left: 0,
            bottom: 0,
            child: Text(
              'BT_WS_ON',
              style: TextStyle(color: Color(0xFF00F0FF), fontSize: 7, fontWeight: FontWeight.bold, letterSpacing: 0.5),
            ),
          ),
          const Positioned(
            right: 0,
            bottom: 0,
            child: Text(
              'SYS_OK',
              style: TextStyle(color: Color(0xFF00F0FF), fontSize: 7, fontWeight: FontWeight.bold, letterSpacing: 0.5),
            ),
          ),

          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Giờ HH:mm (LED cyan phát sáng) + Giây ss (hồng neon)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      '$h:$m',
                      style: const TextStyle(
                        color: Color(0xFF00F0FF),
                        fontSize: 44,
                        fontWeight: FontWeight.w900,
                        fontFamily: 'monospace',
                        letterSpacing: -1.5,
                        shadows: [
                          Shadow(color: Color(0xFF00F0FF), blurRadius: 14),
                          Shadow(color: Color(0xFF0891B2), blurRadius: 24),
                        ],
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      s,
                      style: const TextStyle(
                        color: Color(0xFFFF007F),
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        fontFamily: 'monospace',
                        shadows: [
                          Shadow(color: Color(0xFFFF007F), blurRadius: 10),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),

                // Ngày tháng & Progress bar
                Text(
                  dateStr,
                  style: const TextStyle(
                    color: Color(0xFF00F0FF),
                    fontSize: 10.5,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 8),

                // Rectangular progress bar
                Container(
                  width: 120,
                  height: 8,
                  decoration: BoxDecoration(
                    border: Border.all(color: const Color(0xFF00F0FF), width: 1.2),
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      width: 120 * mockData.songProgress,
                      color: const Color(0xFF00F0FF),
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

  // --- Khung Phải: Tin nhắn Cyber ---
  Widget _buildMessagePanel() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF070614).withValues(alpha: 0.70),
        border: Border.all(color: const Color(0xFF00F0FF), width: 1.2),
      ),
      padding: const EdgeInsets.all(4),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(
            color: const Color(0xFFFF007F),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFFF007F).withValues(alpha: 0.18),
              blurRadius: 8,
            ),
          ],
        ),
        padding: const EdgeInsets.all(6),
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header: MSG_INCOMING
                Row(
                  children: const [
                    Icon(Icons.chat_bubble_outline_rounded, color: Color(0xFFFF007F), size: 10),
                    SizedBox(width: 3),
                    Text(
                      'MSG_INCOMING',
                      style: TextStyle(
                        color: Color(0xFFFF007F),
                        fontSize: 9.5,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Container(height: 1, color: const Color(0xFFFF007F).withValues(alpha: 0.7)),
                const SizedBox(height: 6),

                // Dynamic Message Body
                Expanded(
                  child: Text(
                    '${mockData.sender}:\n"${mockData.message}"',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      height: 1.25,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ),

            // Bottom-right pink warning triangle / radar icon
            Positioned(
              right: 2,
              bottom: 2,
              child: Icon(
                Icons.warning_amber_rounded,
                color: const Color(0xFFFF007F).withValues(alpha: 0.85),
                size: 16,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- Thanh Đáy: Sóng Nhạc Cyber ---
  Widget _buildMusicConsole() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF070614).withValues(alpha: 0.85),
        border: Border.all(color: const Color(0xFFFF007F), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFFF007F).withValues(alpha: 0.22),
            blurRadius: 10,
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: Row(
        children: [
          // Left: Equalizer bars + note
          const Icon(Icons.equalizer_rounded, color: Color(0xFF00F0FF), size: 16),
          const SizedBox(width: 3),
          const Icon(Icons.music_note_rounded, color: Color(0xFFFF007F), size: 15),
          const SizedBox(width: 8),

          // Center: Song title, Artist, and Soundwave Equalizer
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        '${mockData.songTitle} - ${mockData.songArtist}',
                        style: const TextStyle(
                          color: Color(0xFF67E8F9),
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.3,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      mockData.timeRatioStr,
                      style: const TextStyle(
                        color: Color(0xFFFF007F),
                        fontSize: 9.5,
                        fontWeight: FontWeight.w800,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),

                // Audio Equalizer bars & Tick gauge
                SizedBox(
                  height: 12,
                  child: CustomPaint(
                    size: const Size(double.infinity, 12),
                    painter: _EqualizerBarsPainter(progress: mockData.songProgress),
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

/// 3D Perspective Grid & Concentric Radar Circles
class _CyberGridAndRadarPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final purpleGrid = Paint()
      ..color = const Color(0xFF3B0764).withValues(alpha: 0.45)
      ..strokeWidth = 0.8;

    final cyanRadar = Paint()
      ..color = const Color(0xFF083344).withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9;

    // Grid lines
    for (double x = 0; x <= size.width; x += 16) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), purpleGrid);
    }
    for (double y = 0; y <= size.height; y += 16) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), purpleGrid);
    }

    // Concentric Radar Rings centered at (100, 96)
    const center = Offset(100, 96);
    canvas.drawCircle(center, 30, cyanRadar);
    canvas.drawCircle(center, 55, cyanRadar);
    canvas.drawCircle(center, 80, cyanRadar);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Dãy vạch sóng âm Equalizer bars & Thước đo
class _EqualizerBarsPainter extends CustomPainter {
  final double progress;
  _EqualizerBarsPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final barCyan = Paint()..color = const Color(0xFF00F0FF);
    final barDim = Paint()..color = const Color(0xFF083344);

    const int totalBars = 32;
    final barWidth = (size.width / totalBars) - 1.5;
    final activeCount = (progress * totalBars).round();

    for (int i = 0; i < totalBars; i++) {
      final x = i * (barWidth + 1.5);
      // Realistic equalizer pattern
      final hFactor = (math.sin(i * 0.7) * 0.5 + 0.5);
      final barHeight = (size.height * (0.3 + 0.7 * hFactor)).clamp(2.0, size.height);
      final y = size.height - barHeight;

      final p = (i <= activeCount) ? barCyan : barDim;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(x, y, barWidth, barHeight), const Radius.circular(1)),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _EqualizerBarsPainter oldDelegate) => oldDelegate.progress != progress;
}
