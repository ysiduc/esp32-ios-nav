import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/custom_theme_model.dart';

/// Manages built-in (0..5 Màn 1, 0..3 Màn 2), custom static wallpaper, and ZIP themes.
class CustomThemeService extends ChangeNotifier {
  static const String _prefsThemesKey = 'esp_custom_themes_v1';
  static const String _prefsActiveCustomKey = 'esp_active_custom_theme_id';
  static const String _prefsBuiltInIdxKey = 'esp_builtin_theme_idx';
  static const String _prefsMan2IdxKey = 'esp_man2_builtin_idx';
  static const String _prefsActiveMan2CustomKey =
      'esp_active_man2_custom_theme_id';
  static const String _prefsCustomStaticBgKey = 'esp32_custom_bg_path';
  static const String _prefsEspCustomStaticBgKey = 'esp32_custom_esp_bg_path';
  static const int maxEspBgBytes = 24000;
  static const MethodChannel _channel =
      MethodChannel('com.ysiduc.esp32_nav/location');

  final Directory? _overrideStorageDir;

  List<ImportedCustomTheme> _themes = [];
  int _builtInIndex = 0;
  int _man2BuiltInIndex = 0;
  String? _activeCustomThemeId;
  String? _activeMan2CustomThemeId;
  String? _customStaticBgPath;
  String? _espCustomStaticBgPath;
  bool _loaded = false;
  bool _isImporting = false;
  String? _lastError;

  CustomThemeService({Directory? overrideStorageDir})
      : _overrideStorageDir = overrideStorageDir;

  List<ImportedCustomTheme> get themes => List.unmodifiable(_themes);
  List<ImportedCustomTheme> themesForScreen(int screen) =>
      _themes.where((t) => t.targetScreen == screen).toList(growable: false);

  int get builtInIndex => _builtInIndex;
  int get man2BuiltInIndex => _man2BuiltInIndex;
  String? get activeCustomThemeId => _activeCustomThemeId;
  String? get activeMan2CustomThemeId => _activeMan2CustomThemeId;
  String? get customStaticBgPath => _customStaticBgPath;
  String? get espCustomStaticBgPath => _espCustomStaticBgPath;
  bool get isImporting => _isImporting;
  String? get lastError => _lastError;

  ImportedCustomTheme? get activeCustomTheme {
    if (_activeCustomThemeId == null) return null;
    for (final t in _themes) {
      if (t.id == _activeCustomThemeId && t.targetScreen == 1) return t;
    }
    return null;
  }

  ImportedCustomTheme? get activeMan2CustomTheme {
    if (_activeMan2CustomThemeId == null) return null;
    for (final t in _themes) {
      if (t.id == _activeMan2CustomThemeId && t.targetScreen == 2) return t;
    }
    return null;
  }

  bool get isCustomThemeActive => activeCustomTheme != null;
  bool get isMan2CustomThemeActive => activeMan2CustomTheme != null;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _builtInIndex = (prefs.getInt(_prefsBuiltInIdxKey) ?? 0).clamp(0, 5);
      _man2BuiltInIndex = (prefs.getInt(_prefsMan2IdxKey) ?? 0).clamp(0, 3);
      _activeCustomThemeId = prefs.getString(_prefsActiveCustomKey);
      _activeMan2CustomThemeId = prefs.getString(_prefsActiveMan2CustomKey);

      final simStatic = prefs.getString(_prefsCustomStaticBgKey);
      if (simStatic != null && simStatic.isNotEmpty && File(simStatic).existsSync()) {
        _customStaticBgPath = simStatic;
      }
      final espStatic = prefs.getString(_prefsEspCustomStaticBgKey);
      if (espStatic != null && espStatic.isNotEmpty && File(espStatic).existsSync()) {
        _espCustomStaticBgPath = espStatic;
      }

      final rawList = prefs.getString(_prefsThemesKey);
      if (rawList != null && rawList.isNotEmpty) {
        final decoded = jsonDecode(rawList);
        if (decoded is List) {
          _themes = decoded
              .whereType<Map>()
              .map((m) =>
                  ImportedCustomTheme.fromJson(Map<String, dynamic>.from(m)))
              .toList();
        }
      }
      if (_activeCustomThemeId != null && activeCustomTheme == null) {
        _activeCustomThemeId = null;
      }
      if (_activeMan2CustomThemeId != null && activeMan2CustomTheme == null) {
        _activeMan2CustomThemeId = null;
      }
    } catch (e) {
      debugPrint('[CustomThemeService] Load error: $e');
    }
    notifyListeners();
  }

  Future<void> selectBuiltIn(int index) async {
    await ensureLoaded();
    _builtInIndex = index.clamp(0, 5);
    _activeCustomThemeId = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefsBuiltInIdxKey, _builtInIndex);
    await prefs.remove(_prefsActiveCustomKey);
    notifyListeners();
  }

  Future<void> selectCustom(String id) async {
    await ensureLoaded();
    if (!_themes.any((t) => t.id == id && t.targetScreen == 1)) return;
    _activeCustomThemeId = id;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsActiveCustomKey, id);
    notifyListeners();
  }

  Future<void> selectMan2BuiltIn(int index) async {
    await ensureLoaded();
    _man2BuiltInIndex = index.clamp(0, 3);
    _activeMan2CustomThemeId = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefsMan2IdxKey, _man2BuiltInIndex);
    await prefs.remove(_prefsActiveMan2CustomKey);
    notifyListeners();
  }

  Future<void> selectMan2Custom(String id) async {
    await ensureLoaded();
    if (!_themes.any((t) => t.id == id && t.targetScreen == 2)) return;
    _activeMan2CustomThemeId = id;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsActiveMan2CustomKey, id);
    notifyListeners();
  }

  /// Resizes & stores a custom gallery wallpaper for Màn 1 default Waybar theme (index 0).
  Future<({String simPath, Uint8List espJpeg})> saveDefaultStaticBackground(
    Uint8List rawBytes,
  ) async {
    await ensureLoaded();
    final rootDir = await _resolveThemeRootDir();
    final prepared = _prepareThemeImages(
      rawBytes,
      fallbackBgHex: '#0B111A',
      songSampleX: 160,
      songSampleY: 206,
    );
    final simPath = '${rootDir.path}/default_wait_sim.jpg';
    final espPath = '${rootDir.path}/default_wait_esp.jpg';
    await File(simPath).writeAsBytes(prepared.simJpeg, flush: true);
    await File(espPath).writeAsBytes(prepared.espJpeg, flush: true);

    _customStaticBgPath = simPath;
    _espCustomStaticBgPath = espPath;
    _builtInIndex = 0;
    _activeCustomThemeId = null;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsCustomStaticBgKey, simPath);
    await prefs.setString(_prefsEspCustomStaticBgKey, espPath);
    await prefs.setInt(_prefsBuiltInIdxKey, 0);
    await prefs.remove(_prefsActiveCustomKey);
    notifyListeners();
    return (simPath: simPath, espJpeg: prepared.espJpeg);
  }

  Future<void> clearDefaultStaticBackground() async {
    await ensureLoaded();
    if (_customStaticBgPath != null) {
      await _tryDeleteFile(_customStaticBgPath!);
    }
    if (_espCustomStaticBgPath != null) {
      await _tryDeleteFile(_espCustomStaticBgPath!);
    }
    _customStaticBgPath = null;
    _espCustomStaticBgPath = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsCustomStaticBgKey);
    await prefs.remove(_prefsEspCustomStaticBgKey);
    notifyListeners();
  }

  Future<void> deleteCustomTheme(String id) async {
    await ensureLoaded();
    final idx = _themes.indexWhere((t) => t.id == id);
    if (idx < 0) return;
    final removed = _themes.removeAt(idx);
    await _tryDeleteFile(removed.bgImagePath);
    await _tryDeleteFile(removed.espBgImagePath);

    if (_activeCustomThemeId == id) {
      _activeCustomThemeId = null;
    }
    if (_activeMan2CustomThemeId == id) {
      _activeMan2CustomThemeId = null;
    }
    await _saveThemesMetadata();
    notifyListeners();
  }

  Future<void> _tryDeleteFile(String path) async {
    if (path.isEmpty) return;
    try {
      final f = File(path);
      if (await f.exists()) {
        await f.delete();
      }
    } catch (_) {}
  }

  Future<void> _saveThemesMetadata() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsThemesKey,
      jsonEncode(_themes.map((t) => t.toJson()).toList()),
    );
    if (_activeCustomThemeId != null) {
      await prefs.setString(_prefsActiveCustomKey, _activeCustomThemeId!);
    } else {
      await prefs.remove(_prefsActiveCustomKey);
    }
    if (_activeMan2CustomThemeId != null) {
      await prefs.setString(
          _prefsActiveMan2CustomKey, _activeMan2CustomThemeId!);
    } else {
      await prefs.remove(_prefsActiveMan2CustomKey);
    }
  }

  Future<Directory> _resolveThemeRootDir() async {
    if (_overrideStorageDir != null) {
      final d = Directory('${_overrideStorageDir.path}/custom_themes');
      if (!await d.exists()) await d.create(recursive: true);
      return d;
    }
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory('${docs.path}/custom_themes');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// Opens native iOS UIDocumentPickerViewController to pick a `.zip` file and imports it.
  Future<List<ImportedCustomTheme>> importFromPicker({
    int defaultTargetScreen = 1,
  }) async {
    _lastError = null;
    try {
      final res = await _channel.invokeMethod<dynamic>('pickZipFile');
      if (res == null) {
        return []; // User cancelled
      }
      if (res is! Map) {
        throw const FormatException('Dữ liệu file ZIP không hợp lệ');
      }
      final rawBytes = res['bytes'];
      final fileName = res['name']?.toString() ?? 'theme.zip';
      if (rawBytes is! Uint8List || rawBytes.isEmpty) {
        throw const FormatException('Không đọc được nội dung file ZIP');
      }
      return await importZipBytes(
        rawBytes,
        fileName: fileName,
        defaultTargetScreen: defaultTargetScreen,
      );
    } catch (e) {
      _lastError = e.toString().replaceFirst('Exception: ', '');
      notifyListeners();
      rethrow;
    }
  }

  /// Shares a sample template `.zip` archive via iOS UIActivityViewController.
  Future<void> exportSampleThemeZip({int screen = 1}) async {
    final isMan2 = screen == 2;
    final bytes =
        isMan2 ? buildSampleMan2ZipBytes() : buildSampleMan1ZipBytes();
    await _channel.invokeMethod('shareFileBytes', {
      'fileName': isMan2
          ? 'esp32_theme_man2_emerald_cockpit.zip'
          : 'esp32_theme_man1_sunset_horizon.zip',
      'bytes': bytes,
    });
  }

  /// Imports one or multiple custom themes from `.zip` archive bytes.
  Future<List<ImportedCustomTheme>> importZipBytes(
    Uint8List zipBytes, {
    String? fileName,
    int defaultTargetScreen = 1,
  }) async {
    await ensureLoaded();
    _isImporting = true;
    _lastError = null;
    notifyListeners();

    try {
      final archive = ZipDecoder().decodeBytes(zipBytes);
      final validFiles = archive.where((f) {
        if (!f.isFile) return false;
        final lower = f.name.toLowerCase();
        if (lower.startsWith('__macosx/') || lower.contains('/__macosx/')) {
          return false;
        }
        final base = _basename(f.name);
        if (base.startsWith('.') || base.startsWith('._')) return false;
        return _isSupportedThemeAsset(lower);
      }).toList();

      if (validFiles.isEmpty) {
        throw const FormatException(
          'File ZIP không chứa ảnh (.jpg/.png) hoặc mã theme (.json/.dart/.h)',
        );
      }

      final groups = _groupArchiveEntries(validFiles);
      final rootDir = await _resolveThemeRootDir();
      final imported = <ImportedCustomTheme>[];
      final baseTs = DateTime.now().millisecondsSinceEpoch;

      for (var i = 0; i < groups.length; i++) {
        final group = groups[i];
        final fallbackTitle = _deriveGroupTitle(
          groupKey: group.key,
          zipFileName: fileName,
          index: i,
          totalGroups: groups.length,
        );

        final parsed = _parseGroupToTheme(
          entries: group.entries,
          fallbackName: fallbackTitle,
          defaultTargetScreen: defaultTargetScreen,
        );

        final themeId = 'zip_${baseTs}_$i';
        final preparedImages = _prepareThemeImages(
          parsed.imageBytes,
          fallbackBgHex: parsed.spec.bgColor,
          songSampleX: parsed.spec.song.x.round(),
          songSampleY: parsed.spec.song.y.round(),
        );

        final simPath = '${rootDir.path}/${themeId}_sim.jpg';
        final espPath = '${rootDir.path}/${themeId}_esp.jpg';
        await File(simPath).writeAsBytes(preparedImages.simJpeg, flush: true);
        await File(espPath).writeAsBytes(preparedImages.espJpeg, flush: true);

        final finalSpec = (parsed.spec.targetScreen == 1 &&
                !parsed.explicitSongBg &&
                preparedImages.sampledSongBgHex != null)
            ? parsed.spec.copyWith(
                song: parsed.spec.song
                    .copyWith(bgColor: preparedImages.sampledSongBgHex),
              )
            : parsed.spec;

        final theme = ImportedCustomTheme(
          id: themeId,
          name: finalSpec.name,
          subtitle: finalSpec.subtitle,
          accentHex: finalSpec.accentColor,
          bgImagePath: simPath,
          espBgImagePath: espPath,
          sourceSummary: parsed.sourceSummary,
          createdAt: DateTime.now(),
          spec: finalSpec,
        );

        _themes.add(theme);
        imported.add(theme);
      }

      final firstMan1 = imported.where((t) => t.targetScreen == 1).firstOrNull;
      final firstMan2 = imported.where((t) => t.targetScreen == 2).firstOrNull;
      if (firstMan1 != null) {
        _activeCustomThemeId = firstMan1.id;
      }
      if (firstMan2 != null) {
        _activeMan2CustomThemeId = firstMan2.id;
      }
      await _saveThemesMetadata();
      return imported;
    } catch (e) {
      _lastError = e.toString().replaceFirst('Exception: ', '');
      rethrow;
    } finally {
      _isImporting = false;
      notifyListeners();
    }
  }

  /// Alias preserving backwards compatibility for Màn 1 sample archive generation.
  Uint8List buildSampleThemeZipBytes() => buildSampleMan1ZipBytes();

  /// Builds a 320x240 Màn 1 custom `.zip` theme ("Sunset Horizon").
  Uint8List buildSampleMan1ZipBytes() {
    final spec = CustomThemeSpec(
      targetScreen: 1,
      name: 'Sunset Horizon Màn 1',
      subtitle: 'Mẫu ZIP Màn chờ 320x240',
      accentColor: '#F59E0B',
      bgColor: '#120C18',
      showWaybar: false,
      boxes: const [
        CustomThemeBox(
          x: 10,
          y: 12,
          w: 152,
          h: 170,
          r: 12,
          fill: '#1A1328',
          border: '#F59E0B',
        ),
        CustomThemeBox(
          x: 170,
          y: 12,
          w: 140,
          h: 170,
          r: 12,
          fill: '#1A1328',
          border: '#4C1D95',
        ),
        CustomThemeBox(
          x: 10,
          y: 190,
          w: 300,
          h: 40,
          r: 10,
          fill: '#160F24',
          border: '#7C3AED',
        ),
      ],
      labels: const [
        CustomThemeLabel(
          text: 'HOÀNG HÔN',
          x: 20,
          y: 22,
          maxW: 120,
          fontSize: 9,
          color: '#FBBF24',
        ),
        CustomThemeLabel(
          text: 'THÔNG BÁO',
          x: 180,
          y: 22,
          maxW: 118,
          fontSize: 9,
          color: '#C084FC',
        ),
      ],
      clock: const CustomThemeClockSpec(
        visible: true,
        x: 20,
        y: 44,
        fontSize: 40,
        font: 'sans',
        color: '#FEF3C7',
      ),
      date: const CustomThemeDateSpec(
        visible: true,
        x: 20,
        y: 104,
        fontSize: 11,
        color: '#FDBA74',
        format: 'vn_short',
      ),
      song: const CustomThemeSongSpec(
        visible: true,
        x: 20,
        y: 203,
        w: 206,
        fontSize: 11,
        color: '#FDE047',
        bgColor: '#160F24',
      ),
      duration: const CustomThemeDurationSpec(
        visible: true,
        mode: 'ratio',
        x: 232,
        y: 205,
        fontSize: 10,
        color: '#F59E0B',
        secondaryColor: '#DDD6FE',
      ),
      notifTitle: const CustomThemeNotifTitleSpec(
        visible: true,
        x: 180,
        y: 44,
        maxW: 120,
        fontSize: 11,
        color: '#FBBF24',
      ),
      notifMsg: const CustomThemeNotifMsgSpec(
        visible: true,
        x: 180,
        y: 64,
        maxW: 120,
        maxLines: 4,
        lineHeight: 16,
        fontSize: 10,
        color: '#F3E8FF',
      ),
    );

    final bgBytes = _encodeGradientJpg(
      topRgb: (28, 12, 46),
      bottomRgb: (78, 28, 36),
    );
    const readme = '''HƯỚNG DẪN THEME ZIP MÀN 1 (MÀN CHỜ ESP32 - 320x240)
- screen: 1 (Màn chờ đồng hồ & thông báo)
- Đặt bg.jpg (tỷ lệ 4:3, app tự nén <= 24KB) và theme.json.
- Nén thành .zip -> mở "Giao diện ESP32" -> chọn tab Màn 1 -> "Nhập file ZIP".
''';
    return _packThemeZip(bgBytes: bgBytes, spec: spec, readme: readme);
  }

  /// Builds a 320x240 Màn 2 custom `.zip` theme ("Emerald Cockpit").
  Uint8List buildSampleMan2ZipBytes() {
    final spec = CustomThemeSpec(
      targetScreen: 2,
      name: 'Emerald Cockpit Màn 2',
      subtitle: 'Mẫu ZIP Minimap chờ 320x240',
      accentColor: '#10B981',
      bgColor: '#050D0E',
      showPanel: true,
      panel: const CustomThemeBox(
        x: 158,
        y: 6,
        w: 158,
        h: 228,
        r: 12,
        fill: '#0A191B',
        border: '#10B981',
      ),
      minimap: const CustomMan2MinimapSpec(
        x: 6,
        y: 8,
        w: 144,
        h: 224,
        r: 10,
        border: '#34D399',
      ),
      clock: const CustomThemeClockSpec(
        visible: true,
        x: 237,
        y: 14,
        fontSize: 28,
        font: 'sans',
        color: '#ECFDF5',
        center: true,
      ),
      date: const CustomThemeDateSpec(
        visible: true,
        x: 237,
        y: 46,
        fontSize: 10,
        color: '#6EE7B7',
        format: 'vn_short',
        center: true,
      ),
      song: const CustomThemeSongSpec(
        visible: true,
        boxX: 164,
        boxY: 80,
        boxW: 146,
        boxH: 40,
        color: '#FDE68A',
        bgColor: '#061214',
        border: '#059669',
        durColor: '#34D399',
      ),
      notif: const CustomMan2NotifSpec(
        visible: true,
        x: 164,
        y: 124,
        w: 146,
        h: 106,
        r: 8,
        fill: '#061214',
        border: '#115E59',
        titleColor: '#34D399',
        msgColor: '#E2E8F0',
      ),
    );

    final bgBytes = _encodeGradientJpg(
      topRgb: (4, 16, 20),
      bottomRgb: (12, 42, 36),
    );
    const readme = '''HƯỚNG DẪN THEME ZIP MÀN 2 (MINIMAP CHỜ ESP32 - 320x240)
- screen: 2 (Bản đồ minimap + Panel đồng hồ/nhạc/thông báo)
- Các khối chính trong theme.json:
  * bgColor, showPanel
  * panel: {x, y, w, h, r, fill, border}
  * minimap: {x, y, w (60..144), h (60..224), r, border}
  * clock: {visible, x, y, fontSize, font, color}
  * date: {visible, x, y, color, format}
  * song: {visible, boxX, boxY, boxW, boxH, bgColor, border, color, durColor}
  * notif: {visible, x, y, w, h, fill, border, titleColor, msgColor}
- Nén bg.jpg + theme.json thành .zip -> tab Màn 2 -> "Nhập file ZIP".
''';
    return _packThemeZip(bgBytes: bgBytes, spec: spec, readme: readme);
  }

  Uint8List _encodeGradientJpg({
    required (int, int, int) topRgb,
    required (int, int, int) bottomRgb,
  }) {
    final canvas = img.Image(width: 320, height: 240);
    for (var y = 0; y < 240; y++) {
      final t = y / 239.0;
      final r = (topRgb.$1 + t * (bottomRgb.$1 - topRgb.$1)).round().clamp(0, 255);
      final g = (topRgb.$2 + t * (bottomRgb.$2 - topRgb.$2)).round().clamp(0, 255);
      final b = (topRgb.$3 + t * (bottomRgb.$3 - topRgb.$3)).round().clamp(0, 255);
      for (var x = 0; x < 320; x++) {
        canvas.setPixelRgb(x, y, r, g, b);
      }
    }
    return Uint8List.fromList(img.encodeJpg(canvas, quality: 88));
  }

  Uint8List _packThemeZip({
    required Uint8List bgBytes,
    required CustomThemeSpec spec,
    required String readme,
  }) {
    final jsonStr = const JsonEncoder.withIndent('  ').convert(spec.toJson());
    final archive = Archive();
    archive.addFile(ArchiveFile.bytes('bg.jpg', bgBytes));
    archive.addFile(ArchiveFile.string('theme.json', jsonStr));
    archive.addFile(ArchiveFile.string('README.txt', readme));
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  static bool _isSupportedThemeAsset(String lower) {
    return lower.endsWith('.json') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.bmp') ||
        lower.endsWith('.dart') ||
        lower.endsWith('.h') ||
        lower.endsWith('.hpp') ||
        lower.endsWith('.cpp') ||
        lower.endsWith('.c');
  }

  static String _basename(String path) {
    final parts = path.split('/');
    return parts.isEmpty ? path : parts.last;
  }

  static String _stripExtension(String name) {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// Splits ZIP entries into 1 theme group (flat or single wrapper folder) or N multi-theme folder groups.
  List<_ArchiveGroup> _groupArchiveEntries(List<ArchiveFile> files) {
    final hasRootFiles = files.any((f) => !f.name.contains('/'));
    if (hasRootFiles) {
      return [_ArchiveGroup('root', files)];
    }

    final firstDirs = files.map((f) => f.name.split('/').first).toSet();
    if (firstDirs.length > 1) {
      return firstDirs
          .map((d) => _ArchiveGroup(
              d, files.where((f) => f.name.split('/').first == d).toList()))
          .toList();
    }

    // All files live under a single top-level directory; check if depth-2 holds multiple themes.
    final prefix = '${firstDirs.first}/';
    final subDirs = <String>{};
    var hasDirectUnderPrefix = false;
    for (final f in files) {
      final rel = f.name.substring(prefix.length);
      if (!rel.contains('/')) {
        hasDirectUnderPrefix = true;
      } else {
        subDirs.add(rel.split('/').first);
      }
    }
    if (!hasDirectUnderPrefix && subDirs.length > 1) {
      return subDirs
          .map((d) => _ArchiveGroup(
              d,
              files
                  .where((f) => f.name.startsWith('$prefix$d/'))
                  .toList()))
          .toList();
    }

    return [_ArchiveGroup(firstDirs.first, files)];
  }

  String _deriveGroupTitle({
    required String groupKey,
    required String? zipFileName,
    required int index,
    required int totalGroups,
  }) {
    if (groupKey != 'root' && groupKey.trim().isNotEmpty) {
      return _beautifyName(groupKey);
    }
    if (zipFileName != null && zipFileName.trim().isNotEmpty) {
      final clean = _beautifyName(_stripExtension(_basename(zipFileName)));
      if (totalGroups > 1) return '$clean #${index + 1}';
      return clean;
    }
    return totalGroups > 1 ? 'Theme ZIP #${index + 1}' : 'Theme ZIP';
  }

  static String _beautifyName(String raw) {
    return raw.replaceAll(RegExp(r'[_-]+'), ' ').trim();
  }

  _ParsedGroup _parseGroupToTheme({
    required List<ArchiveFile> entries,
    required String fallbackName,
    int defaultTargetScreen = 1,
  }) {
    ArchiveFile? jsonFile;
    final codeFiles = <ArchiveFile>[];
    final imgFiles = <ArchiveFile>[];

    for (final f in entries) {
      final lower = f.name.toLowerCase();
      if (lower.endsWith('.json')) {
        // Prefer theme.json or manifest.json over any auxiliary json
        final base = _basename(lower);
        if (base == 'theme.json' || jsonFile == null) {
          jsonFile = f;
        }
      } else if (lower.endsWith('.dart') ||
          lower.endsWith('.h') ||
          lower.endsWith('.hpp') ||
          lower.endsWith('.cpp') ||
          lower.endsWith('.c')) {
        codeFiles.add(f);
      } else if (lower.endsWith('.jpg') ||
          lower.endsWith('.jpeg') ||
          lower.endsWith('.png') ||
          lower.endsWith('.webp') ||
          lower.endsWith('.bmp')) {
        imgFiles.add(f);
      }
    }

    // Prefer primary background image filename ("bg", "background", "wallpaper") over small icons.
    Uint8List? pickedImageBytes;
    String? pickedImageName;
    if (imgFiles.isNotEmpty) {
      imgFiles.sort((a, b) {
        int score(String n) {
          final l = _basename(n).toLowerCase();
          if (l.startsWith('bg') ||
              l.contains('background') ||
              l.contains('wallpaper')) {
            return 0;
          }
          if (l.contains('preview') || l.contains('cover')) return 2;
          return 1;
        }

        final diff = score(a.name).compareTo(score(b.name));
        if (diff != 0) return diff;
        return b.size.compareTo(a.size);
      });
      pickedImageBytes = imgFiles.first.readBytes();
      pickedImageName = _basename(imgFiles.first.name);
    }

    CustomThemeSpec? spec;
    var explicitSongBg = false;
    var codeSourceTag = '';

    if (jsonFile != null) {
      try {
        final rawText = utf8.decode(jsonFile.readBytes() ?? const []);
        final decoded = jsonDecode(rawText);
        if (decoded is Map<String, dynamic>) {
          spec = CustomThemeSpec.fromJson(
            decoded,
            fallbackName: fallbackName,
            defaultTargetScreen: defaultTargetScreen,
          );
          if (decoded['song'] is Map &&
              (decoded['song'] as Map).containsKey('bgColor')) {
            explicitSongBg = true;
          }
          codeSourceTag = _basename(jsonFile.name);
        }
      } catch (e) {
        debugPrint('[CustomThemeService] JSON parse fallback: $e');
      }
    }

    if (spec == null && codeFiles.isNotEmpty) {
      final combinedCode = codeFiles
          .map((c) => utf8.decode(c.readBytes() ?? const [], allowMalformed: true))
          .join('\n');
      spec = _parseThemeFromSourceCode(
        combinedCode,
        fallbackName: fallbackName,
        defaultTargetScreen: defaultTargetScreen,
      );
      codeSourceTag = _basename(codeFiles.first.name);
    }

    spec ??= defaultTargetScreen == 2
        ? CustomThemeSpec(
            targetScreen: 2,
            name: fallbackName,
            subtitle: 'Theme ảnh nền Màn 2 tùy chỉnh',
            clock: const CustomThemeClockSpec(
              x: 237,
              y: 14,
              fontSize: 28,
              color: '#FFFFFF',
              center: true,
            ),
            date: const CustomThemeDateSpec(
              x: 237,
              y: 46,
              color: '#94A3B8',
              center: true,
            ),
          )
        : CustomThemeSpec(
            targetScreen: 1,
            name: fallbackName,
            subtitle: 'Ảnh nền tùy chỉnh',
            showWaybar: false,
          );

    final summaryParts = <String>[
      if (codeSourceTag.isNotEmpty) codeSourceTag,
      if (pickedImageName != null) pickedImageName,
    ];

    return _ParsedGroup(
      spec: spec,
      imageBytes: pickedImageBytes,
      explicitSongBg: explicitSongBg,
      sourceSummary:
          summaryParts.isEmpty ? 'Theme mặc định' : summaryParts.join(' + '),
    );
  }

  /// Extracts layout positions, colors & font hints when a ZIP supplies `.dart` or `.h` theme code without `theme.json`.
  CustomThemeSpec _parseThemeFromSourceCode(
    String code, {
    required String fallbackName,
    int defaultTargetScreen = 1,
  }) {
    final hexColors = <String>[];

    // Match 0xFFRRGGBB (Flutter Color) & #RRGGBB (CSS/JSON)
    for (final m in RegExp(r'0x(?:FF)?([0-9A-Fa-f]{6})\b').allMatches(code)) {
      hexColors.add('#${m.group(1)!.toUpperCase()}');
    }
    for (final m in RegExp(r'#([0-9A-Fa-f]{6})\b').allMatches(code)) {
      hexColors.add('#${m.group(1)!.toUpperCase()}');
    }

    final distinctAccents = hexColors
        .where((c) =>
            c != '#000000' &&
            c != '#FFFFFF' &&
            c != '#0B111A' &&
            c != '#0F172A')
        .toList();
    final accent =
        distinctAccents.isNotEmpty ? distinctAccents.first : '#00E5FF';
    final secondaryAccent =
        distinctAccents.length > 1 ? distinctAccents[1] : '#FACC15';

    // Extract Positioned(left: X, top: Y) hints in Dart or drawString(..., X, Y) in C++
    final dartPosRegex = RegExp(
      r'Positioned\([^)]*?left:\s*([\d.]+)[^)]*?top:\s*([\d.]+)',
      dotAll: true,
    );
    final coords = dartPosRegex
        .allMatches(code)
        .map((m) => (
              double.tryParse(m.group(1) ?? '') ?? 20,
              double.tryParse(m.group(2) ?? '') ?? 24,
            ))
        .toList();

    final lower = code.toLowerCase();
    final detectedScreen =
        lower.contains('minimap') || lower.contains('screen: 2')
            ? 2
            : defaultTargetScreen;
    final hasSevenSeg =
        lower.contains('monospace') || lower.contains('7seg') || code.contains(', 7)');
    final showWaybar = lower.contains('waybar');

    // Look for largest fontSize mentioned near clock
    double clockSize = detectedScreen == 2 ? 28 : 40;
    for (final m in RegExp(r'fontSize:\s*([\d.]+)').allMatches(code)) {
      final v = double.tryParse(m.group(1) ?? '') ?? 0;
      if (v >= 24 && v <= 56 && v > clockSize) {
        clockSize = v;
      }
    }

    if (detectedScreen == 2) {
      return CustomThemeSpec(
        targetScreen: 2,
        name: fallbackName,
        subtitle: 'Tự phân tích Màn 2 từ mã nguồn ZIP',
        accentColor: accent,
        bgColor: '#0B111A',
        panel: CustomThemeBox(
          x: 158,
          y: 6,
          w: 158,
          h: 228,
          r: 12,
          fill: '#131B26',
          border: accent,
        ),
        minimap: CustomMan2MinimapSpec(
          x: 6,
          y: 8,
          w: 144,
          h: 224,
          r: 10,
          border: accent,
        ),
        clock: CustomThemeClockSpec(
          visible: true,
          x: 237,
          y: 14,
          fontSize: clockSize,
          font: hasSevenSeg ? '7seg' : 'sans',
          color: '#FFFFFF',
          center: true,
        ),
        date: CustomThemeDateSpec(
          visible: true,
          x: 237,
          y: 46,
          fontSize: 10,
          color: accent,
          center: true,
        ),
        song: CustomThemeSongSpec(
          visible: true,
          boxX: 164,
          boxY: 80,
          boxW: 146,
          boxH: 40,
          color: secondaryAccent,
          bgColor: '#0B111A',
          border: accent,
          durColor: accent,
        ),
        notif: CustomMan2NotifSpec(
          visible: true,
          x: 164,
          y: 124,
          w: 146,
          h: 106,
          r: 8,
          fill: '#0B111A',
          border: '#1E293B',
          titleColor: secondaryAccent,
          msgColor: '#FFFFFF',
        ),
      );
    }

    final clockX = coords.isNotEmpty ? coords[0].$1.clamp(4, 220).toDouble() : 20.0;
    final clockY = coords.isNotEmpty ? coords[0].$2.clamp(4, 160).toDouble() : 24.0;
    final notifX = coords.length > 1 ? coords[1].$1.clamp(120, 220).toDouble() : 180.0;
    final notifY = coords.length > 1 ? coords[1].$2.clamp(12, 140).toDouble() : 46.0;
    final songX = coords.length > 2 ? coords[2].$1.clamp(8, 120).toDouble() : 20.0;
    final songY = coords.length > 2 ? coords[2].$2.clamp(160, 220).toDouble() : 202.0;

    return CustomThemeSpec(
      targetScreen: 1,
      name: fallbackName,
      subtitle: 'Tự phân tích từ mã nguồn ZIP',
      accentColor: accent,
      bgColor: '#0B111A',
      showWaybar: showWaybar,
      clock: CustomThemeClockSpec(
        visible: true,
        x: clockX,
        y: clockY,
        fontSize: clockSize,
        font: hasSevenSeg ? '7seg' : 'sans',
        color: accent,
      ),
      date: CustomThemeDateSpec(
        visible: true,
        x: clockX,
        y: (clockY + clockSize + 8).clamp(40, 175),
        fontSize: 11,
        color: '#FFFFFF',
      ),
      song: CustomThemeSongSpec(
        visible: true,
        x: songX,
        y: songY,
        w: 200,
        fontSize: 11,
        color: secondaryAccent,
      ),
      duration: CustomThemeDurationSpec(
        visible: true,
        mode: 'ratio',
        x: (songX + 208).clamp(210, 250),
        y: songY + 2,
        fontSize: 10,
        color: accent,
      ),
      notifTitle: CustomThemeNotifTitleSpec(
        visible: true,
        x: notifX,
        y: notifY,
        maxW: (312 - notifX).clamp(70, 140),
        fontSize: 11,
        color: secondaryAccent,
      ),
      notifMsg: CustomThemeNotifMsgSpec(
        visible: true,
        x: notifX,
        y: notifY + 18,
        maxW: (312 - notifX).clamp(70, 140),
        maxLines: 4,
        lineHeight: 15,
        fontSize: 10,
        color: '#FFFFFF',
      ),
    );
  }

  _PreparedImages _prepareThemeImages(
    Uint8List? rawBytes, {
    required String fallbackBgHex,
    required int songSampleX,
    required int songSampleY,
  }) {
    img.Image? decoded;
    if (rawBytes != null && rawBytes.isNotEmpty) {
      decoded = img.decodeImage(rawBytes);
    }

    if (decoded == null) {
      final c = CustomThemeSpec.parseColor(
        fallbackBgHex,
        const Color(0xFF0B111A),
      );
      decoded = img.Image(width: 320, height: 240);
      img.fill(
        decoded,
        color: img.ColorRgb8(
          (c.r * 255).round(),
          (c.g * 255).round(),
          (c.b * 255).round(),
        ),
      );
    }

    // Center-crop to exact 4:3 ratio
    final srcW = decoded.width;
    final srcH = decoded.height;
    const targetRatio = 320.0 / 240.0;
    final srcRatio = srcW / srcH;

    img.Image cropped;
    if ((srcRatio - targetRatio).abs() < 0.01) {
      cropped = decoded;
    } else if (srcRatio > targetRatio) {
      final cropW = (srcH * targetRatio).round();
      final offsetX = ((srcW - cropW) / 2).round().clamp(0, srcW - 1);
      cropped = img.copyCrop(decoded, x: offsetX, y: 0, width: cropW, height: srcH);
    } else {
      final cropH = (srcW / targetRatio).round();
      final offsetY = ((srcH - cropH) / 2).round().clamp(0, srcH - 1);
      cropped = img.copyCrop(decoded, x: 0, y: offsetY, width: srcW, height: cropH);
    }

    final simImg = img.copyResize(
      cropped,
      width: 640,
      height: 480,
      interpolation: img.Interpolation.linear,
    );
    final simJpeg = Uint8List.fromList(img.encodeJpg(simImg, quality: 88));

    final espImg = img.copyResize(
      cropped,
      width: 320,
      height: 240,
      interpolation: img.Interpolation.linear,
    );

    // Sample pixel around song area so ESP32 marquee box background stays seamless
    final sx = songSampleX.clamp(0, 319);
    final sy = (songSampleY + 6).clamp(0, 239);
    final px = espImg.getPixel(sx, sy);
    final sampledSongBgHex =
        '#${px.r.toInt().toRadixString(16).padLeft(2, '0')}'
        '${px.g.toInt().toRadixString(16).padLeft(2, '0')}'
        '${px.b.toInt().toRadixString(16).padLeft(2, '0')}';

    Uint8List espJpeg = Uint8List(0);
    for (final q in [82, 72, 62, 52, 42, 32]) {
      espJpeg = Uint8List.fromList(img.encodeJpg(espImg, quality: q));
      if (espJpeg.length <= maxEspBgBytes) break;
    }

    return _PreparedImages(
      simJpeg: simJpeg,
      espJpeg: espJpeg,
      sampledSongBgHex: sampledSongBgHex.toUpperCase(),
    );
  }
}

class _ArchiveGroup {
  final String key;
  final List<ArchiveFile> entries;
  _ArchiveGroup(this.key, this.entries);
}

class _ParsedGroup {
  final CustomThemeSpec spec;
  final Uint8List? imageBytes;
  final bool explicitSongBg;
  final String sourceSummary;

  _ParsedGroup({
    required this.spec,
    required this.imageBytes,
    required this.explicitSongBg,
    required this.sourceSummary,
  });
}

class _PreparedImages {
  final Uint8List simJpeg;
  final Uint8List espJpeg;
  final String? sampledSongBgHex;

  _PreparedImages({
    required this.simJpeg,
    required this.espJpeg,
    required this.sampledSongBgHex,
  });
}
