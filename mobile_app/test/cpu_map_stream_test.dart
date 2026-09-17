import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  test('Pure CPU Map Renderer benchmark and functionality test', () {
    final stopwatch = Stopwatch()..start();

    // 1. Create mock tile (256x256)
    final tile = img.Image(width: 256, height: 256);
    img.fill(tile, color: img.ColorRgba8(235, 240, 240, 255));
    // Draw mock street
    img.drawLine(tile, x1: 128, y1: 0, x2: 128, y2: 255, color: img.ColorRgba8(255, 255, 255, 255), thickness: 12);
    // Draw mock river
    img.drawLine(tile, x1: 0, y1: 60, x2: 255, y2: 80, color: img.ColorRgba8(140, 210, 255, 255), thickness: 20);

    // 2. Composite onto 280x280 patch
    final patch = img.Image(width: 280, height: 280);
    img.fill(patch, color: img.ColorRgba8(235, 240, 240, 255));
    img.compositeImage(patch, tile, dstX: 12, dstY: 12);

    // 3. Rotate by heading (e.g. 45 degrees)
    final rotated = img.copyRotate(patch, angle: -45);

    // 4. Crop 144x208 for ESP32 screen
    final cx = rotated.width ~/ 2;
    final cy = rotated.height ~/ 2;
    final frame = img.copyCrop(
      rotated,
      x: cx - 72,
      y: cy - 104,
      width: 144,
      height: 208,
    );

    // 5. Draw active route line
    img.drawLine(frame, x1: 72, y1: 140, x2: 72, y2: 70, color: img.ColorRgba8(0, 120, 230, 255), thickness: 6);
    img.drawLine(frame, x1: 72, y1: 70, x2: 30, y2: 70, color: img.ColorRgba8(0, 120, 230, 255), thickness: 6);
    img.drawLine(frame, x1: 72, y1: 140, x2: 72, y2: 70, color: img.ColorRgba8(0, 230, 255, 255), thickness: 3);
    img.drawLine(frame, x1: 72, y1: 70, x2: 30, y2: 70, color: img.ColorRgba8(0, 230, 255, 255), thickness: 3);

    // 6. Draw vehicle puck at (72, 140)
    img.fillCircle(frame, x: 72, y: 140, radius: 7, color: img.ColorRgba8(0, 150, 255, 255));
    img.drawCircle(frame, x: 72, y: 140, radius: 7, color: img.ColorRgba8(255, 255, 255, 255));

    // 7. Encode to JPEG
    final jpegBytes = Uint8List.fromList(img.encodeJpg(frame, quality: 70));

    stopwatch.stop();
    print('Pure CPU Map Frame Render Time: ${stopwatch.elapsedMilliseconds} ms, JPEG size: ${jpegBytes.length} bytes');

    expect(frame.width, 144);
    expect(frame.height, 208);
    expect(jpegBytes.length, greaterThan(500));
    expect(jpegBytes[0], 0xFF);
    expect(jpegBytes[1], 0xD8); // Valid JPEG
  });

  test('Surrounding 3x3 tiles composite with negative coordinates test', () {
    final patch = img.Image(width: 320, height: 320);
    final tile = img.Image(width: 256, height: 256);
    img.fill(tile, color: img.ColorRgba8(200, 200, 200, 255));

    // Test tiles at dx=-1, dy=-1 (which produce negative dstX, dstY)
    for (int dx = -1; dx <= 1; dx++) {
      for (int dy = -1; dy <= 1; dy++) {
        final int dstX = (160 + (dx * 256.0) - 128.0).round();
        final int dstY = (160 + (dy * 256.0) - 128.0).round();
        img.compositeImage(patch, tile, dstX: dstX, dstY: dstY);
      }
    }

    final frame = img.copyCrop(patch, x: 88, y: 56, width: 144, height: 208);
    final jpg = img.encodeJpg(frame, quality: 78);
    expect(jpg, isNotEmpty);
    expect(jpg[0], 0xFF);
    expect(jpg[1], 0xD8);
  });
}
