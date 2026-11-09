import 'dart:io';
import 'package:flutter/material.dart';
import '../../config/simulator_presets.dart';

/// Theme 0: Màn Chờ Mặc Định (customStatic)
/// Ảnh nền người dùng chọn (hoặc nền mặc định tối sẫm) + Thanh trạng thái Waybar Hybrid
class CustomStaticTheme extends StatelessWidget {
  final String? customBgPath;
  final DateTime currentTime;
  final SimulatorMockData mockData;

  const CustomStaticTheme({
    super.key,
    this.customBgPath,
    required this.currentTime,
    this.mockData = SimulatorMockData.defaultPreset,
  });

  @override
  Widget build(BuildContext context) {
    final hStr = currentTime.hour.toString().padLeft(2, '0');
    final mStr = currentTime.minute.toString().padLeft(2, '0');
    final timeStr = '$hStr:$mStr';

    return Stack(
      children: [
        // 1. Background (Custom image or default dark sunflower dusk)
        Positioned.fill(
          child: _buildBackground(),
        ),

        // 2. Subtle Dark Vignette for contrast
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.45),
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.65),
                ],
                stops: const [0.0, 0.4, 1.0],
              ),
            ),
          ),
        ),

        // 3. Center Glowing Status Badge
        Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A).withValues(alpha: 0.88),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: const Color(0xFF38BDF8).withValues(alpha: 0.85),
                width: 1.4,
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF0284C7).withValues(alpha: 0.45),
                  blurRadius: 16,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: const Color(0xFF38BDF8),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF38BDF8).withValues(alpha: 0.9),
                            blurRadius: 6,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'SẴN SÀNG',
                      style: TextStyle(
                        color: Color(0xFF38BDF8),
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  'ĐANG CHỜ KẾT NỐI APP',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Mở app trên iPhone để kết nối BLE',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.65),
                    fontSize: 9.5,
                  ),
                ),
              ],
            ),
          ),
        ),

        // 4. Top Status Waybar (26px high, Waybar Pill Modules)
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 26,
          child: Container(
            color: const Color(0xFF0F172A).withValues(alpha: 0.82),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Module Pill 1: [🕒 Giờ]
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E293B),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFF334155), width: 0.8),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.access_time_filled_rounded, color: Color(0xFF38BDF8), size: 11),
                      const SizedBox(width: 3),
                      Text(
                        timeStr,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),

                // Module Pill 2: [💬 Tin nhắn rút gọn]
                Expanded(
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E293B),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFF334155), width: 0.8),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.chat_bubble_rounded, color: Color(0xFFFB923C), size: 10),
                        const SizedBox(width: 3),
                        Expanded(
                          child: Text(
                            '${mockData.sender}: ${mockData.message}',
                            style: const TextStyle(
                              color: Color(0xFFE2E8F0),
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // Module Pill 3: [🎵 Bài hát đang phát]
                Container(
                  constraints: const BoxConstraints(maxWidth: 100),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E293B),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFF334155), width: 0.8),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.music_note_rounded, color: Color(0xFFFACC15), size: 11),
                      const SizedBox(width: 2),
                      Expanded(
                        child: Text(
                          mockData.songTitle,
                          style: const TextStyle(
                            color: Color(0xFFFEF08A),
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBackground() {
    if (customBgPath != null && customBgPath!.isNotEmpty) {
      final file = File(customBgPath!);
      if (file.existsSync()) {
        return Image.file(
          file,
          fit: BoxFit.cover,
          width: 320,
          height: 240,
          errorBuilder: (_, __, ___) => _buildDefaultWallpaper(),
        );
      }
    }
    return _buildDefaultWallpaper();
  }

  Widget _buildDefaultWallpaper() {
    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0.4, -0.2),
          radius: 1.1,
          colors: [
            Color(0xFF2C1E11), // Warm dark amber
            Color(0xFF14121A), // Deep dusk
            Color(0xFF090A0E), // Pure dark base
          ],
        ),
      ),
      child: CustomPaint(
        painter: _SunflowerWatermarkPainter(),
      ),
    );
  }
}

class _SunflowerWatermarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final petalPaint = Paint()
      ..color = const Color(0xFFE5A93C).withValues(alpha: 0.09)
      ..style = PaintingStyle.fill;

    final centerPaint = Paint()
      ..color = const Color(0xFF78350F).withValues(alpha: 0.12)
      ..style = PaintingStyle.fill;

    final cx = size.width * 0.78;
    final cy = size.height * 0.72;

    for (int i = 0; i < 16; i++) {
      canvas.save();
      canvas.translate(cx, cy);
      canvas.rotate(i * 3.14159 / 8.0);
      canvas.drawOval(
        Rect.fromCenter(center: const Offset(42, 0), width: 44, height: 16),
        petalPaint,
      );
      canvas.restore();
    }
    canvas.drawCircle(Offset(cx, cy), 24, centerPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

