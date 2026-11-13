import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:mobile_app/models/custom_theme_model.dart';
import 'package:mobile_app/services/custom_theme_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

Uint8List _makeSolidPng({int width = 800, int height = 400, int r = 20, int g = 40, int b = 80}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(r, g, b));
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('custom_theme_zip_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('sample template ZIP imports cleanly with <=24KB ESP32 JPEG & <=6 ESP boxes', () async {
    final service = CustomThemeService(overrideStorageDir: tempDir);
    final sampleZip = service.buildSampleThemeZipBytes();

    final imported = await service.importZipBytes(
      sampleZip,
      fileName: 'esp32_theme_template.zip',
    );

    expect(imported.length, 1);
    final theme = imported.first;
    expect(theme.name, 'Midnight Neon Studio');
    expect(service.isCustomThemeActive, isTrue);
    expect(service.activeCustomTheme?.id, theme.id);

    final simBytes = await File(theme.bgImagePath).readAsBytes();
    final espBytes = await File(theme.espBgImagePath).readAsBytes();
    expect(espBytes.length, lessThanOrEqualTo(CustomThemeService.maxEspBgBytes));

    final simImg = img.decodeJpg(simBytes)!;
    final espImg = img.decodeJpg(espBytes)!;
    expect(simImg.width, 640);
    expect(simImg.height, 480);
    expect(espImg.width, 320);
    expect(espImg.height, 240);

    final compact = theme.spec.toEsp32CompactJson();
    expect((compact['boxes'] as List).length, lessThanOrEqualTo(6));
    expect((compact['labels'] as List).length, lessThanOrEqualTo(6));
  });

  test('ignores __MACOSX metadata and center-crops non-4:3 images', () async {
    final service = CustomThemeService(overrideStorageDir: tempDir);
    final archive = Archive();

    // Junk macOS AppleDouble files that must be skipped
    archive.addFile(ArchiveFile.string('__MACOSX/._theme.json', 'corrupt binary'));
    archive.addFile(ArchiveFile.string('my_theme/._bg.png', 'corrupt binary'));
    archive.addFile(ArchiveFile.bytes('my_theme/bg.png', _makeSolidPng(width: 800, height: 400)));
    archive.addFile(
      ArchiveFile.string(
        'my_theme/theme.json',
        jsonEncode({
          'name': 'Cyber Drift',
          'accentColor': '#22D3EE',
          'showWaybar': false,
          'boxes': List.generate(
            8,
            (i) => {'x': i * 10, 'y': 10, 'w': 20, 'h': 20, 'border': '#22D3EE'},
          ),
        }),
      ),
    );

    final zipBytes = Uint8List.fromList(ZipEncoder().encode(archive));
    final imported = await service.importZipBytes(zipBytes, fileName: 'bundle.zip');

    expect(imported.length, 1);
    expect(imported.first.name, 'Cyber Drift');
    expect(imported.first.spec.boxes.length, 8);
    expect((imported.first.spec.toEsp32CompactJson()['boxes'] as List).length, 6);

    final espImg = img.decodeJpg(await File(imported.first.espBgImagePath).readAsBytes())!;
    expect(espImg.width, 320);
    expect(espImg.height, 240);
  });

  test('parses theme layout and accent colors from .dart code fallback ZIP', () async {
    final service = CustomThemeService(overrideStorageDir: tempDir);
    final archive = Archive();

    archive.addFile(ArchiveFile.bytes('bg.png', _makeSolidPng(width: 640, height: 480)));
    archive.addFile(
      ArchiveFile.string(
        'neon_hud.dart',
        '''
class CustomNeonWidget {
  // bottom waybar indicator
  Widget build() => Stack(children: [
    Positioned(left: 28, top: 36, child: Text('12:00', style: TextStyle(color: Color(0xFFFF4081), fontSize: 44))),
    Positioned(left: 190, top: 50, child: Text('Notif', style: TextStyle(color: Color(0xFF00E5FF)))),
  ]);
}
''',
      ),
    );

    final zipBytes = Uint8List.fromList(ZipEncoder().encode(archive));
    final imported = await service.importZipBytes(zipBytes, fileName: 'neon_dart_theme.zip');

    expect(imported.length, 1);
    final t = imported.first;
    expect(t.name, 'neon dart theme');
    expect(t.accentHex, '#FF4081');
    expect(t.spec.clock.x, 28);
    expect(t.spec.clock.y, 36);
    expect(t.spec.clock.fontSize, 44);
    expect(t.spec.showWaybar, isTrue);
  });

  test('supports multi-theme folder ZIP and deleting active custom theme restores built-in', () async {
    final service = CustomThemeService(overrideStorageDir: tempDir);
    final archive = Archive();

    archive.addFile(ArchiveFile.bytes('alpha/bg.png', _makeSolidPng(width: 320, height: 240, r: 90)));
    archive.addFile(ArchiveFile.string('alpha/theme.json', jsonEncode({'name': 'Alpha UI'})));
    archive.addFile(ArchiveFile.bytes('beta/bg.png', _makeSolidPng(width: 320, height: 240, b: 140)));
    archive.addFile(ArchiveFile.string('beta/theme.json', jsonEncode({'name': 'Beta UI'})));

    final zipBytes = Uint8List.fromList(ZipEncoder().encode(archive));
    final imported = await service.importZipBytes(zipBytes, fileName: 'pack.zip');

    expect(imported.length, 2);
    expect(service.themes.map((e) => e.name).toSet(), {'Alpha UI', 'Beta UI'});

    final activeId = service.activeCustomThemeId!;
    final bgPath = service.activeCustomTheme!.bgImagePath;
    expect(await File(bgPath).exists(), isTrue);

    await service.deleteCustomTheme(activeId);
    expect(service.themes.length, 1);
    expect(service.isCustomThemeActive, isFalse);
    expect(await File(bgPath).exists(), isFalse);
  });

  test('toEsp32CompactJson normalizes ARGB hex colors to #RRGGBB', () {
    const spec = CustomThemeSpec(
      name: 'HexTest',
      bgColor: '0xFF123456',
      accentColor: '#AAFF00AA',
    );
    final compact = spec.toEsp32CompactJson();
    expect(compact['bgColor'], '#123456');
  });
}
