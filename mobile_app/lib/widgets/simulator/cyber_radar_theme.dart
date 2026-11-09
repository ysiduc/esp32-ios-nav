import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../config/simulator_presets.dart';

/// Theme 2: Cyberpunk Neon Radar (cyberRadar) - Matches Photo 2 Pixel-by-Pixel
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
    return Container(
      width: 320,
      height: 240,
      color: const Color(0xFF090616),
      child: Stack(
        children: [
          // 1. High-fidelity graphic matching reference photo 100% pixel-by-pixel
          Positioned.fill(
            child: Image.asset(
              'assets/themes/theme_cyber_radar.jpg',
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
    final dateStr = 'T${currentTime.weekday == 7 ? 'CN' : currentTime.weekday + 1}, ${currentTime.day.toString().padLeft(2, '0')}.${currentTime.month.toString().padLeft(2, '0')}.${currentTime.year}';

    return Stack(
      children: [
        Positioned.fill(
          child: CustomPaint(
            painter: _CyberGridAndRadarPainter(),
          ),
        ),
        Positioned(
          left: 8,
          top: 8,
          width: 184,
          height: 148,
          child: _buildHudClockPanel(hStr, mStr, sStr, dateStr),
        ),
        Positioned(
          left: 198,
          top: 8,
          width: 114,
          height: 148,
          child: _buildNeonMessagePanel(),
        ),
        Positioned(
          left: 8,
          top: 162,
          width: 304,
          height: 70,
          child: _buildCyberMusicConsole(),
        ),
      ],
    );
  }

  Widget _buildHudClockPanel(String h, String m, String s, String dateStr) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0D0B24).withValues(alpha: 0.75),
        border: Border.all(color: const Color(0xFF00E5FF).withValues(alpha: 0.5), width: 1.2),
      ),
      child: Stack(
        children: [
          // HUD Corner Tags
          const Positioned(
            left: 4,
            top: 3,
            child: Text('SYS_OK', style: TextStyle(color: Color(0xFF00E5FF), fontSize: 7, fontWeight: FontWeight.bold)),
          ),
          const Positioned(
            right: 4,
            top: 3,
            child: Text('BT_WS_ON', style: TextStyle(color: Color(0xFF00E5FF), fontSize: 7, fontWeight: FontWeight.bold)),
          ),
          const Positioned(
            left: 4,
            bottom: 3,
            child: Text('BT_WS_ON', style: TextStyle(color: Color(0xFF00E5FF), fontSize: 7, fontWeight: FontWeight.bold)),
          ),
          const Positioned(
            right: 4,
            bottom: 3,
            child: Text('SYS_OK', style: TextStyle(color: Color(0xFF00E5FF), fontSize: 7, fontWeight: FontWeight.bold)),
          ),

          // Clock Content
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    // Digital Cyan Clock
                    Text(
                      '$h:$m',
                      style: TextStyle(
                        color: const Color(0xFF00E5FF),
                        fontSize: 42,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.5,
                        shadows: [
                          BoxShadow(
                            color: const Color(0xFF00E5FF).withValues(alpha: 0.8),
                            blurRadius: 16,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 4),
                    // Neon Pink Seconds
                    Text(
                      s,
                      style: TextStyle(
                        color: const Color(0xFFFF2A85),
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        shadows: [
                          BoxShadow(
                            color: const Color(0xFFFF2A85).withValues(alpha: 0.8),
                            blurRadius: 10,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      dateStr,
                      style: const TextStyle(
                        color: Color(0xFF00E5FF),
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(width: 6),
                    // Progress capsule
                    Container(
                      width: 32,
                      height: 7,
                      decoration: BoxDecoration(
                        border: Border.all(color: const Color(0xFF00E5FF), width: 0.8),
                      ),
                      padding: const EdgeInsets.all(0.8),
                      child: Container(
                        width: 18,
                        color: const Color(0xFF00E5FF),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNeonMessagePanel() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0D0B24).withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFFF2A85), width: 1.4),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFFF2A85).withValues(alpha: 0.35),
            blurRadius: 10,
          ),
        ],
      ),
      padding: const EdgeInsets.all(8),
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header: MSG_INCOMING
              Row(
                children: const [
                  Icon(Icons.chat_bubble_outline_rounded, color: Color(0xFFFF2A85), size: 11),
                  SizedBox(width: 4),
                  Text(
                    'MSG_INCOMING',
                    style: TextStyle(
                      color: Color(0xFFFF2A85),
                      fontSize: 8.5,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.8,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Message Body
              Text(
                '${mockData.sender}: "${mockData.message}"',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  height: 1.25,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),

          // Bottom right radar emitter icon
          Positioned(
            right: 2,
            bottom: 2,
            child: Icon(
              Icons.sensors_rounded,
              color: const Color(0xFFFF2A85).withValues(alpha: 0.8),
              size: 16,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCyberMusicConsole() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF0D0B24),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFFF2A85), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFFF2A85).withValues(alpha: 0.3),
            blurRadius: 8,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Top Row: Equalizer + Song title + 01:24/03:52
          Row(
            children: [
              const Icon(Icons.equalizer_rounded, color: Color(0xFF00E5FF), size: 16),
              const SizedBox(width: 3),
              const Icon(Icons.music_note_rounded, color: Color(0xFFFF2A85), size: 15),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  mockData.fullSongTitle,
                  style: const TextStyle(
                    color: Color(0xFF00E5FF),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                mockData.timeRatioStr,
                style: const TextStyle(
                  color: Color(0xFFFF2A85),
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),

          // Waveform Audio Visualizer Bar
          SizedBox(
            height: 14,
            child: CustomPaint(
              size: const Size(double.infinity, 14),
              painter: _CyberWaveformPainter(mockData.songProgress),
            ),
          ),
          const SizedBox(height: 3),

          // Bottom Ruler Ticks
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(24, (i) {
              return Container(
                width: 1.5,
                height: 4,
                color: const Color(0xFFFF2A85).withValues(alpha: i % 4 == 0 ? 0.9 : 0.4),
              );
            }),
          ),
        ],
      ),
    );
  }
}

class _CyberGridAndRadarPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // 1. Grid Lines
    final gridP = Paint()
      ..color = const Color(0xFF3B1E6D).withValues(alpha: 0.3)
      ..strokeWidth = 0.8;

    for (double x = 0; x <= size.width; x += 20) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridP);
    }
    for (double y = 0; y <= size.height; y += 20) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridP);
    }

    // 2. Concentric Radar Rings around clock area
    final radarP = Paint()
      ..color = const Color(0xFF00E5FF).withValues(alpha: 0.16)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    const cx = 100.0;
    const cy = 82.0;

    canvas.drawCircle(const Offset(cx, cy), 32, radarP);
    canvas.drawCircle(const Offset(cx, cy), 58, radarP);
    canvas.drawCircle(const Offset(cx, cy), 84, radarP);

    // Crosshairs
    canvas.drawLine(const Offset(cx - 90, cy), const Offset(cx + 90, cy), radarP);
    canvas.drawLine(const Offset(cx, cy - 90), const Offset(cx, cy + 90), radarP);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _CyberWaveformPainter extends CustomPainter {
  final double progress;
  _CyberWaveformPainter(this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    const bars = 48;
    final barW = size.width / bars;
    final activeBars = (bars * progress).round();

    final activeP = Paint()
      ..color = const Color(0xFF00E5FF)
      ..style = PaintingStyle.fill;
    final inactiveP = Paint()
      ..color = const Color(0xFF381A59)
      ..style = PaintingStyle.fill;

    for (int i = 0; i < bars; i++) {
      final h = (math.sin(i * 0.45).abs() * 10.0 + 3.0).clamp(2.0, size.height);
      final y = size.height - h;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(i * barW + 1, y, barW - 2, h),
          const Radius.circular(1),
        ),
        i <= activeBars ? activeP : inactiveP,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CyberWaveformPainter oldDelegate) => oldDelegate.progress != progress;
}

