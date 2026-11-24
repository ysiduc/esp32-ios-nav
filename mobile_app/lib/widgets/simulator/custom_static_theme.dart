import 'marquee_text.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import '../../config/simulator_presets.dart';

/// GIAO DIỆN 6: ẢNH NỀN TỪ MÁY + THANH WAYBAR
/// Dùng ImagePicker chọn ảnh bất kỳ từ iPhone làm lớp nền 240x240, và vẽ đè thanh Waybar mỏng (height: 24px) ở cạnh dưới
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

    return SizedBox(
      width: 240,
      height: 240,
      child: Stack(
        children: [
          // 1. Ảnh nền từ máy (hoặc ảnh mặc định nếu chưa chọn)
          Positioned.fill(
            child: _buildBackground(),
          ),

          // 2. Subtle Dark Vignette cho tương phản
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.35),
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.55),
                  ],
                  stops: const [0.0, 0.5, 1.0],
                ),
              ),
            ),
          ),

          // 3. Khung Trạng Thái Trung Tâm: SẴN SÀNG / ĐANG CHỜ KẾT NỐI
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
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

          // 4. Thanh Waybar mỏng (height: 24px) ở cạnh dưới: [Giờ] | [Tin nhắn] | [Nhạc]
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            height: 24,
            child: Container(
              color: const Color(0xFF0F172A).withValues(alpha: 0.85),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Row(
                children: [
                  // Module Pill 1: [🕒 Giờ]
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E293B),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF334155), width: 0.8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.access_time_filled_rounded, color: Color(0xFF38BDF8), size: 10),
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

                  // Divider '|'
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      '|',
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 10),
                    ),
                  ),

                  // Module Pill 2: [🎵 Nhạc] (Kéo dài toàn bộ phần còn lại của Waybar, bỏ tin nhắn)
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1.5),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFF334155), width: 0.8),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.music_note_rounded, color: Color(0xFFFACC15), size: 11),
                          const SizedBox(width: 4),
                          Expanded(
                            child: MarqueeText(
                              text: mockData.fullSongTitle,
                              width: 145,
                              style: const TextStyle(
                                color: Color(0xFFFEF08A),
                                fontSize: 9.0,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBackground() {
    if (customBgPath != null && customBgPath!.isNotEmpty) {
      final file = File(customBgPath!);
      if (file.existsSync()) {
        return Image.file(
          file,
          fit: BoxFit.cover,
          width: 240,
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
