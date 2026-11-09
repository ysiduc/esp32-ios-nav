import 'package:flutter/material.dart';

/// Renders a realistic 2.4" ESP32-S3 hardware enclosure with matte black chassis,
/// tactile buttons, status LED, and sunken 4:3 320x240 display viewport.
class Esp32Bezel extends StatelessWidget {
  final Widget child;
  final double scale;

  const Esp32Bezel({
    super.key,
    required this.child,
    this.scale = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1E2126),
          borderRadius: BorderRadius.circular(22),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(180),
              blurRadius: 28,
              offset: const Offset(0, 14),
            ),
            BoxShadow(
              color: const Color(0xFF38BDF8).withAlpha(35),
              blurRadius: 18,
              spreadRadius: 1,
            ),
          ],
          border: Border.all(
            color: const Color(0xFF374151),
            width: 1.8,
          ),
        ),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Top Chassis Details: 2 tactile buttons & status LED
            Padding(
              padding: const EdgeInsets.only(bottom: 8.0, left: 24, right: 24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Left: Dual Hardware Button nubs
                  Row(
                    children: [
                      _buildChassisButtonNub(),
                      const SizedBox(width: 8),
                      _buildChassisButtonNub(),
                    ],
                  ),
                  // Center: Logo text
                  const Text(
                    'ESP32-S3 • 2.4" ST7789 (320x240)',
                    style: TextStyle(
                      color: Color(0xFF6B7280),
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.1,
                    ),
                  ),
                  // Right: Status LED
                  Row(
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFF10B981),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF10B981).withAlpha(180),
                              blurRadius: 6,
                              spreadRadius: 1.5,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 5),
                      const Text(
                        'PWR',
                        style: TextStyle(
                          color: Color(0xFF9CA3AF),
                          fontSize: 8.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Sunken Screen Viewport: Exactly 320x240 ratio 4:3
            Container(
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: const Color(0xFF111827),
                  width: 3.0,
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black,
                    blurRadius: 6,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: SizedBox(
                  width: 320 * scale,
                  height: 240 * scale,
                  child: FittedBox(
                    fit: BoxFit.contain,
                    child: SizedBox(
                      width: 320,
                      height: 240,
                      child: child,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChassisButtonNub() {
    return Container(
      width: 22,
      height: 5,
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(2),
        border: Border.all(color: const Color(0xFF4B5563), width: 0.8),
      ),
    );
  }
}
