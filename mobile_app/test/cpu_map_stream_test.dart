import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  test('Pure CPU Map Renderer benchmark and functionality test', () {
    final stopwatch = Stopwatch()..start();

    final sw0 = Stopwatch()..start();
    final tile = img.Image(width: 256, height: 256);
    img.fill(tile, color: img.ColorRgba8(235, 240, 240, 255));
    img.drawLine(tile, x1: 128, y1: 0, x2: 128, y2: 255, color: img.ColorRgba8(255, 255, 255, 255), thickness: 12);
    img.drawLine(tile, x1: 0, y1: 60, x2: 255, y2: 80, color: img.ColorRgba8(140, 210, 255, 255), thickness: 20);

    final sw1 = Stopwatch()..start();
    final patch = img.Image(width: 360, height: 360);
    img.fill(patch, color: img.ColorRgba8(235, 240, 240, 255));
    for (int i = 0; i < 4; i++) {
      img.compositeImage(patch, tile, dstX: (i % 2) * 180, dstY: (i ~/ 2) * 180, blend: img.BlendMode.direct);
    }
    final tCompositeDirect = sw1.elapsedMilliseconds;

    final sw2 = Stopwatch()..start();
    final rotated = img.copyRotate(patch, angle: -45, interpolation: img.Interpolation.linear);
    final tRotateLinear = sw2.elapsedMilliseconds;

    final sw2b = Stopwatch()..start();
    img.copyRotate(patch, angle: -45, interpolation: img.Interpolation.nearest);
    final tRotateNearest = sw2b.elapsedMilliseconds;

    final sw3 = Stopwatch()..start();
    final cx = rotated.width ~/ 2;
    final cy = rotated.height ~/ 2;
    final frame = img.copyCrop(
      rotated,
      x: cx - 72,
      y: cy - 104,
      width: 144,
      height: 208,
    );
    final tCrop = sw3.elapsedMilliseconds;

    final sw4 = Stopwatch()..start();
    final jpeg82 = img.encodeJpg(frame, quality: 82);
    final tJpg82 = sw4.elapsedMilliseconds;

    final sw5 = Stopwatch()..start();
    final jpeg75 = img.encodeJpg(frame, quality: 75);
    final tJpg75 = sw5.elapsedMilliseconds;

    print('TIMINGS: CompositeDirect(4 tiles)=$tCompositeDirect ms | RotateLinear=$tRotateLinear ms | RotateNearest=$tRotateNearest ms | Crop=$tCrop ms | Jpg82=$tJpg82 ms | Jpg75=$tJpg75 ms');
    print('TOTAL LINEAR=${tCompositeDirect + tRotateLinear + tCrop + tJpg82} ms | TOTAL NEAREST=${tCompositeDirect + tRotateNearest + tCrop + tJpg75} ms');

    expect(frame.width, 144);
    expect(frame.height, 208);
    expect(jpeg82.length, greaterThan(500));
    expect(jpeg82[0], 0xFF);
    expect(jpeg82[1], 0xD8); // Valid JPEG
  });

  test('Optimized pipeline benchmark in Isolate.run', () async {
    final tile = img.Image(width: 256, height: 256);
    img.fill(tile, color: img.ColorRgba8(235, 240, 240, 255));

    final sw = Stopwatch()..start();
    final result = await Isolate.run(() {
      const int patchSize = 320;
      final patch = img.Image(width: patchSize, height: patchSize);
      img.fill(patch, color: img.ColorRgba8(235, 240, 240, 255));
      for (int i = 0; i < 4; i++) {
        img.compositeImage(patch, tile, dstX: (i % 2) * 160, dstY: (i ~/ 2) * 160, blend: img.BlendMode.direct);
      }
      final rotated = img.copyRotate(patch, angle: -45, interpolation: img.Interpolation.linear);
      final cx = rotated.width ~/ 2;
      final cy = rotated.height ~/ 2;
      final frame = img.copyCrop(rotated, x: cx - 72, y: cy - 140, width: 144, height: 208);
      return img.encodeJpg(frame, quality: 76);
    });
    print('OPTIMIZED PIPELINE in Isolate.run: ${sw.elapsedMilliseconds} ms | Size: ${result.length} bytes');
    expect(result.length, greaterThan(500));
  });
}
