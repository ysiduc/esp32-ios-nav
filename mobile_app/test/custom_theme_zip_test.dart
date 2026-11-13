import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:mobile_app/models/custom_theme_model.dart';
import 'package:mobile_app/services/custom_theme_service.dart';
import 'package:mobile_app/services/navigation_manager.dart';
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

  test('Màn 1 sample ZIP imports cleanly with <=24KB ESP32 JPEG & <=6 ESP boxes', () async {
    final service = CustomThemeService(overrideStorageDir: tempDir);
    final sampleZip = service.buildSampleMan1ZipBytes();

    final imported = await service.importZipBytes(
      sampleZip,
      fileName: 'esp32_theme_man1_sunset_horizon.zip',
    );

    expect(imported.length, 1);
    final theme = imported.first;
    expect(theme.name, 'Sunset Horizon Màn 1');
    expect(theme.targetScreen, 1);
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

  test('Màn 2 sample ZIP imports with targetScreen 2 and valid ESP32 Man2 JSON', () async {
    final service = CustomThemeService(overrideStorageDir: tempDir);
    final man2Zip = service.buildSampleMan2ZipBytes();

    final imported = await service.importZipBytes(
      man2Zip,
      fileName: 'theme_man2_emerald_cockpit.zip',
    );

    expect(imported.length, 1);
    final t = imported.first;
    expect(t.name, 'Emerald Cockpit Màn 2');
    expect(t.targetScreen, 2);
    expect(service.isMan2CustomThemeActive, isTrue);
    expect(service.activeMan2CustomTheme?.id, t.id);

    final espBytes = await File(t.espBgImagePath).readAsBytes();
    expect(espBytes.length, lessThanOrEqualTo(CustomThemeService.maxEspBgBytes));

    final man2Json = t.spec.toEsp32Man2CompactJson();
    expect((man2Json['minimap'] as Map)['w'], 144);
    expect((man2Json['panel'] as Map)['fill'], '#0A191B');
    expect((man2Json['notif'] as Map)['visible'], isTrue);
    expect((man2Json['song'] as Map)['boxY'], 80);
  });

  test('saveDefaultStaticBackground saves 640x480 sim & <=24KB 320x240 esp JPEG', () async {
    final service = CustomThemeService(overrideStorageDir: tempDir);
    await service.selectBuiltIn(3);
    final res = await service.saveDefaultStaticBackground(
      _makeSolidPng(width: 1200, height: 800, r: 45, g: 110, b: 200),
    );

    expect(service.builtInIndex, 0);
    expect(service.customStaticBgPath, res.simPath);
    expect(await File(res.simPath).exists(), isTrue);
    expect(res.espJpeg.length, lessThanOrEqualTo(CustomThemeService.maxEspBgBytes));
    final decodedEsp = img.decodeJpg(res.espJpeg)!;
    expect(decodedEsp.width, 320);
    expect(decodedEsp.height, 240);
  });

  test('normalizeRoadPillName strips street prefixes & house numbers cleanly', () {
    expect(
      NavigationManager.normalizeRoadPillName('Phố Nguyễn Cảnh Dị'),
      'Nguyễn Cảnh Dị',
    );
    expect(
      NavigationManager.normalizeRoadPillName('42 Đường Nguyễn Hữu Thọ'),
      'Nguyễn Hữu Thọ',
    );
    expect(
      NavigationManager.normalizeRoadPillName('Đường Láng'),
      'Đường Láng',
    );
  });
}
