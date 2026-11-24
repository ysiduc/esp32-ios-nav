import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../config/simulator_presets.dart';
import '../models/custom_theme_model.dart';
import '../models/esp32_interface.dart';
import '../services/ble_service.dart';
import '../services/custom_theme_service.dart';
import '../services/esp_stream_service.dart';
import '../services/navigation_manager.dart';
import '../services/phone_call_service.dart';
import '../services/phone_media_service.dart';
import '../widgets/simulator/carbon_sport_theme.dart';
import '../widgets/simulator/cassette_wave_theme.dart';
import '../widgets/simulator/comic_strip_theme.dart';
import '../widgets/simulator/custom_static_theme.dart';
import '../widgets/simulator/cyber_radar_theme.dart';
import '../widgets/simulator/dynamic_custom_theme.dart';
import '../widgets/simulator/esp32_bezel.dart';
import '../widgets/simulator/esp_man2_preview.dart';
import '../widgets/simulator/retro_mac_theme.dart';

class _Man2ThemePreset {
  final int styleIndex;
  final String name;
  final String subtitle;
  final Color accent;
  final IconData icon;

  const _Man2ThemePreset({
    required this.styleIndex,
    required this.name,
    required this.subtitle,
    required this.accent,
    required this.icon,
  });
}

/// Unified "Giao diện ESP32" screen combining:
/// 1. Screen brightness slider
/// 2. Synchronized Màn 1 / Màn 2 preview bezel + ESP32 hardware sync
/// 3. Màn 1 & Màn 2 themes (built-in + "+" custom photo + ZIP theme importer)
/// 4. Minimap zoom level
/// 5. Minimap source style
class EspInterfaceScreen extends StatefulWidget {
  final VoidCallback? onBackToMap;
  final bool isActive;

  const EspInterfaceScreen({
    super.key,
    this.onBackToMap,
    this.isActive = true,
  });

  @override
  State<EspInterfaceScreen> createState() => _EspInterfaceScreenState();
}

class _EspInterfaceScreenState extends State<EspInterfaceScreen> {
  // 0 = Màn 1 (Màn chờ / Theme), 1 = Màn 2 (Bản đồ chờ / Minimap)
  int _previewScreen = 0;
  DateTime _currentTime = DateTime.now();
  Timer? _clockTimer;
  Timer? _brightnessDebounce;
  bool _isUploadingZipToEsp = false;

  static const List<_Man2ThemePreset> _man2Presets = [
    _Man2ThemePreset(
      styleIndex: 0,
      name: 'Màn 2 Mặc định',
      subtitle: 'Minimap trái + HUD tối',
      accent: Color(0xFF007AFF),
      icon: Icons.splitscreen_rounded,
    ),
    _Man2ThemePreset(
      styleIndex: 1,
      name: 'Neon Cyber Map',
      subtitle: 'Khung Cyber hồng & 7-đoạn',
      accent: Color(0xFFEC4899),
      icon: Icons.bolt_rounded,
    ),
    _Man2ThemePreset(
      styleIndex: 2,
      name: 'Sunflower Warm',
      subtitle: 'Hổ phách vàng ấm dịu mắt',
      accent: Color(0xFFEAB308),
      icon: Icons.wb_sunny_rounded,
    ),
    _Man2ThemePreset(
      styleIndex: 3,
      name: 'Minimap Bên Phải',
      subtitle: 'Đảo minimap sang phải ngọc',
      accent: Color(0xFF10B981),
      icon: Icons.compare_arrows_rounded,
    ),
  ];

  static const _zoomDescriptions = <int, String>{
    14: 'Toàn thành phố & trục giao thông chính',
    15: 'Tổng quan quận / khu vực rộng',
    16: 'Cân bằng giữa tầm nhìn & đường phố',
    17: 'Độ chi tiết cao: toà nhà, số nhà & POI',
    18: 'Cận cảnh từng ngõ hẻm & giao lộ',
  };

  @override
  void initState() {
    super.initState();
    if (widget.isActive) {
      _activateScreenSession();
    }
  }

  @override
  void didUpdateWidget(covariant EspInterfaceScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isActive && widget.isActive) {
      _activateScreenSession();
    } else if (oldWidget.isActive && !widget.isActive) {
      _deactivateScreenSession();
    }
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _brightnessDebounce?.cancel();
    _releaseHardwarePreviewLock();
    super.dispose();
  }

  void _activateScreenSession() {
    _startClockTimer();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncPreviewScreenToEsp(_previewScreen);
    });
  }

  void _deactivateScreenSession() {
    _clockTimer?.cancel();
    _clockTimer = null;
    _releaseHardwarePreviewLock();
  }

  void _releaseHardwarePreviewLock() {
    try {
      final ble = context.read<BleService>();
      if (ble.isConnected) {
        ble.setPreviewScreenMode(0);
        ble.sendRawJson(jsonEncode({'type': 'RESTORE_IDLE_MAP'}));
      }
    } catch (_) {}
  }

  void _startClockTimer() {
    _clockTimer?.cancel();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {
          _currentTime = DateTime.now();
        });
      }
    });
  }

  Future<void> _syncPreviewScreenToEsp(int screenIdx) async {
    final ble = context.read<BleService>();
    final customThemes = context.read<CustomThemeService>();
    await customThemes.ensureLoaded();
    if (!ble.isConnected) return;

    if (screenIdx == 0) {
      await ble.setPreviewScreenMode(1);
      final activeCustom = customThemes.activeCustomTheme;
      await ble.sendRawJson(jsonEncode({
        'type': 'THEME_SELECT',
        'theme': activeCustom != null ? 250 : customThemes.builtInIndex,
      }));
    } else {
      await ble.setPreviewScreenMode(2);
      final activeMan2 = customThemes.activeMan2CustomTheme;
      await ble.sendMan2StyleToEsp32(
        activeMan2 != null ? 250 : customThemes.man2BuiltInIndex,
      );
    }
  }

  void _switchPreviewScreen(int screenIdx) {
    if (_previewScreen != screenIdx) {
      setState(() => _previewScreen = screenIdx);
    }
    _syncPreviewScreenToEsp(screenIdx);
  }

  void _onBrightnessChanged(double value) {
    final pct = value.round().clamp(5, 100);
    final ble = context.read<BleService>();
    ble.setBrightness(pct, sendToDevice: false);

    _brightnessDebounce?.cancel();
    _brightnessDebounce = Timer(const Duration(milliseconds: 70), () {
      if (!mounted) return;
      context.read<BleService>().setBrightness(pct, sendToDevice: true);
    });
  }

  void _onBrightnessChangeEnd(double value) {
    _brightnessDebounce?.cancel();
    final pct = value.round().clamp(5, 100);
    context.read<BleService>().setBrightness(pct, sendToDevice: true);
  }

  Future<void> _selectBuiltInTheme(int index) async {
    final customThemes = context.read<CustomThemeService>();
    final ble = context.read<BleService>();

    await customThemes.selectBuiltIn(index);
    setState(() => _previewScreen = 0);

    if (ble.isConnected) {
      await ble.setPreviewScreenMode(1);
      await ble.sendRawJson(jsonEncode({'type': 'THEME_SELECT', 'theme': index}));
    }
  }

  Future<void> _selectMan2BuiltInTheme(int styleIndex) async {
    final customThemes = context.read<CustomThemeService>();
    final ble = context.read<BleService>();

    await customThemes.selectMan2BuiltIn(styleIndex);
    setState(() => _previewScreen = 1);

    if (ble.isConnected) {
      await ble.setPreviewScreenMode(2);
      await ble.sendMan2StyleToEsp32(styleIndex);
    }
  }

  Future<void> _pickAndSaveScreenImage({
    required int previewScreenIndex,
    required Future<({String simPath, Uint8List espJpeg})> Function(
      Uint8List rawBytes,
    ) saveLocal,
    required Future<bool> Function(Uint8List espJpeg) uploadBle,
    required String espSuccessMsg,
    required String localSuccessMsg,
  }) async {
    final ble = context.read<BleService>();
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(source: ImageSource.gallery);
      if (picked == null || !mounted) return;

      final rawBytes = await picked.readAsBytes();
      setState(() {
        _previewScreen = previewScreenIndex;
        _isUploadingZipToEsp = true;
      });

      final saved = await saveLocal(rawBytes);
      if (ble.isConnected) {
        await ble.setPreviewScreenMode(previewScreenIndex + 1);
        final ok = await uploadBle(saved.espJpeg);
        if (mounted) {
          _showSnack(
            ok ? espSuccessMsg : 'Đã đổi ảnh trên app, chưa gửi được sang ESP32',
            isError: !ok,
          );
        }
      } else if (mounted) {
        _showSnack(localSuccessMsg);
      }
    } catch (e) {
      if (mounted) {
        _showSnack('Không thể chọn ảnh: $e', isError: true);
      }
    } finally {
      if (mounted) setState(() => _isUploadingZipToEsp = false);
    }
  }

  Future<void> _pickDefaultWaitImage() {
    final customThemes = context.read<CustomThemeService>();
    final ble = context.read<BleService>();
    return _pickAndSaveScreenImage(
      previewScreenIndex: 0,
      saveLocal: customThemes.saveDefaultStaticBackground,
      uploadBle: ble.sendDefaultWallpaperToEsp32,
      espSuccessMsg: 'Đã đổi ảnh nền Màn Chờ Mặc Định sang ESP32!',
      localSuccessMsg: 'Đã cập nhật ảnh nền Màn Chờ Mặc Định!',
    );
  }

  Future<void> _pickMan2DefaultImage() {
    final customThemes = context.read<CustomThemeService>();
    final ble = context.read<BleService>();
    return _pickAndSaveScreenImage(
      previewScreenIndex: 1,
      saveLocal: customThemes.saveMan2DefaultBackground,
      uploadBle: ble.sendMan2DefaultImageToEsp32,
      espSuccessMsg: 'Đã gửi ảnh hiển thị Màn 2 sang ESP32!',
      localSuccessMsg: 'Đã lưu ảnh thay map chờ Màn 2!',
    );
  }

  Future<void> _selectCustomTheme(ImportedCustomTheme theme) async {
    final customThemes = context.read<CustomThemeService>();
    if (theme.targetScreen == 2) {
      await customThemes.selectMan2Custom(theme.id);
      setState(() => _previewScreen = 1);
    } else {
      await customThemes.selectCustom(theme.id);
      setState(() => _previewScreen = 0);
    }
    await _pushCustomThemeToEsp(theme);
  }

  Future<void> _pushCustomThemeToEsp(ImportedCustomTheme theme) async {
    final ble = context.read<BleService>();
    if (!ble.isConnected) return;

    setState(() => _isUploadingZipToEsp = true);
    try {
      final espFile = File(theme.espBgImagePath);
      final bgBytes =
          await espFile.exists() ? await espFile.readAsBytes() : Uint8List(0);
      final isMan2 = theme.targetScreen == 2;

      await ble.setPreviewScreenMode(isMan2 ? 2 : 1);
      final ok = isMan2
          ? await ble.sendCustomMan2ThemeToEsp32(
              bgJpegBytes: bgBytes,
              specJson: theme.spec.toEsp32Man2CompactJson(),
            )
          : await ble.sendCustomThemeToEsp32(
              bgJpegBytes: bgBytes,
              specJson: theme.spec.toEsp32CompactJson(),
            );
      if (mounted) {
        if (ok) {
          _showSnack('Đã đồng bộ theme "${theme.name}" sang ESP32!');
        } else {
          _showSnack('Đồng bộ ESP32 không thành công', isError: true);
        }
      }
    } finally {
      if (mounted) setState(() => _isUploadingZipToEsp = false);
    }
  }

  Future<void> _importZipTheme() async {
    final customThemes = context.read<CustomThemeService>();
    try {
      final imported = await customThemes.importFromPicker(
        defaultTargetScreen: _previewScreen + 1,
      );
      if (!mounted || imported.isEmpty) return;

      final first = imported.first;
      setState(() => _previewScreen = first.targetScreen == 2 ? 1 : 0);

      final ble = context.read<BleService>();
      if (ble.isConnected) {
        await _pushCustomThemeToEsp(first);
      } else {
        _showSnack(
          imported.length > 1
              ? 'Đã nhập ${imported.length} theme Màn ${first.targetScreen} từ ZIP!'
              : 'Đã nhập theme "${first.name}" (Màn ${first.targetScreen})!',
        );
      }
    } catch (e) {
      if (mounted) {
        _showSnack(
          'Lỗi nhập file ZIP: ${e.toString().replaceFirst('FormatException: ', '')}',
          isError: true,
        );
      }
    }
  }

  Future<void> _confirmDeleteCustomTheme(ImportedCustomTheme theme) async {
    final customThemes = context.read<CustomThemeService>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text(
          'Xóa theme tùy chỉnh?',
          style: TextStyle(color: Color(0xFF1C1C1E), fontWeight: FontWeight.w700),
        ),
        content: Text(
          'Bạn có muốn xóa theme "${theme.name}" đã nhập từ file ZIP không?',
          style: const TextStyle(color: Color(0xFF3C3C43)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Hủy', style: TextStyle(color: Color(0xFF8E8E93))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Xóa',
              style: TextStyle(color: Color(0xFFFF3B30), fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final wasActive1 = customThemes.activeCustomThemeId == theme.id;
    final wasActive2 = customThemes.activeMan2CustomThemeId == theme.id;
    await customThemes.deleteCustomTheme(theme.id);
    if (wasActive1 && _previewScreen == 0) {
      await _selectBuiltInTheme(customThemes.builtInIndex);
    } else if (wasActive2 && _previewScreen == 1) {
      await _selectMan2BuiltInTheme(customThemes.man2BuiltInIndex);
    }
  }

  void _showZipTemplateGuide() {
    final customThemes = context.read<CustomThemeService>();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Row(
          children: [
            Icon(Icons.folder_zip_rounded, color: Color(0xFF007AFF)),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Cấu trúc File ZIP Theme',
                style: TextStyle(
                  color: Color(0xFF1C1C1E),
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
        content: const SingleChildScrollView(
          child: Text(
            'Hỗ trợ ZIP cho cả Màn 1 (Màn chờ) & Màn 2 (Minimap chờ) trên canvas 240x240px:\n\n'
            '1. Ảnh nền: bg.jpg hoặc bg.png (tỷ lệ 1:1 — 240x240 hoặc 480x480).\n'
            '2. File theme.json (hoặc code .dart/.h):\n'
            '   • "screen": 1 (Màn 1) hoặc "screen": 2 (Màn 2)\n'
            '   • Màn 2 hỗ trợ panel, minimap, clock, date, song, notif.\n\n'
            'Chọn xuất file mẫu bên dưới để tải nhanh mẫu Màn 1 hoặc Màn 2.',
            style: TextStyle(color: Color(0xFF3C3C43), fontSize: 13.5, height: 1.45),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Đóng', style: TextStyle(color: Color(0xFF8E8E93))),
          ),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF007AFF),
              side: const BorderSide(color: Color(0xFF007AFF)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                await customThemes.exportSampleThemeZip(screen: 1);
              } catch (e) {
                if (mounted) _showSnack('Không thể chia sẻ mẫu Màn 1: $e', isError: true);
              }
            },
            icon: const Icon(Icons.ios_share_rounded, size: 16),
            label: const Text('Mẫu Màn 1', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF007AFF),
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                await customThemes.exportSampleThemeZip(screen: 2);
              } catch (e) {
                if (mounted) _showSnack('Không thể chia sẻ mẫu Màn 2: $e', isError: true);
              }
            },
            icon: const Icon(Icons.ios_share_rounded, size: 16),
            label: const Text('Mẫu Màn 2', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? const Color(0xFFFF3B30) : const Color(0xFF34C759),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _handleBack() {
    _releaseHardwarePreviewLock();
    if (widget.onBackToMap != null) {
      widget.onBackToMap!();
    } else if (Navigator.canPop(context)) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bleService = context.watch<BleService>();
    final customThemes = context.watch<CustomThemeService>();
    final streamService = context.watch<EspStreamService>();
    final navManager = context.watch<NavigationManager>();
    final mediaService = context.watch<PhoneMediaService>();
    final callService = context.watch<PhoneCallService>();

    return Scaffold(
      backgroundColor: const Color(0xFFF2F2F7),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Color(0xFF007AFF), size: 20),
          onPressed: _handleBack,
        ),
        title: const Text(
          'Giao diện ESP32',
          style: TextStyle(
            color: Color(0xFF1C1C1E),
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 14),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: bleService.isConnected
                  ? const Color(0xFF34C759).withValues(alpha: 0.14)
                  : const Color(0xFF8E8E93).withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  bleService.isConnected
                      ? Icons.bluetooth_connected_rounded
                      : Icons.bluetooth_disabled_rounded,
                  size: 14,
                  color: bleService.isConnected
                      ? const Color(0xFF248A3D)
                      : const Color(0xFF8E8E93),
                ),
                const SizedBox(width: 4),
                Text(
                  bleService.isConnected ? 'Đã kết nối' : 'Ngoại tuyến',
                  style: TextStyle(
                    color: bleService.isConnected
                        ? const Color(0xFF248A3D)
                        : const Color(0xFF6E6E73),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 36),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 1. Độ sáng màn hình
            _buildBrightnessCard(bleService),
            const SizedBox(height: 16),

            // 2. Màn hình mô phỏng (Màn 1 / Màn 2 đồng bộ)
            _buildSimulatorSection(
              bleService: bleService,
              customThemes: customThemes,
              streamService: streamService,
              navManager: navManager,
              mediaService: mediaService,
              callService: callService,
            ),
            const SizedBox(height: 18),

            // 3. Lựa chọn giao diện (6 themes + Nhập ZIP)
            _buildThemeSection(customThemes),
            const SizedBox(height: 18),

            // 4. Tỉ lệ phóng to minimap
            _buildMinimapZoomCard(streamService),
            const SizedBox(height: 16),

            // 5. Bản đồ minimap
            _buildMinimapStyleCard(streamService),
          ],
        ),
      ),
    );
  }

  Widget _cardContainer({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE5E5EA)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: child,
    );
  }

  // ---------------------------------------------------------------------------
  // 1. ĐỘ SÁNG MÀN HÌNH
  // ---------------------------------------------------------------------------
  Widget _buildBrightnessCard(BleService bleService) {
    final pct = bleService.brightnessPct;
    return _cardContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.wb_sunny_rounded, color: Color(0xFFFF9500), size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'ĐỘ SÁNG MÀN HÌNH',
                  style: TextStyle(
                    color: Color(0xFF1C1C1E),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFFF9500).withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$pct%',
                  style: const TextStyle(
                    color: Color(0xFFB25000),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const Icon(Icons.brightness_low_rounded, color: Color(0xFF8E8E93), size: 18),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: const Color(0xFFFF9500),
                    inactiveTrackColor: const Color(0xFFE5E5EA),
                    thumbColor: Colors.white,
                    overlayColor: const Color(0xFFFF9500).withValues(alpha: 0.2),
                    trackHeight: 6,
                  ),
                  child: Slider(
                    value: pct.toDouble(),
                    min: 5,
                    max: 100,
                    divisions: 19,
                    onChanged: _onBrightnessChanged,
                    onChangeEnd: _onBrightnessChangeEnd,
                  ),
                ),
              ),
              const Icon(Icons.brightness_high_rounded, color: Color(0xFFFF9500), size: 20),
            ],
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 2. MÀN HÌNH MÔ PHỎNG (Màn 1 / Màn 2 đồng bộ giữa App và ESP32)
  // ---------------------------------------------------------------------------
  Widget _buildSimulatorSection({
    required BleService bleService,
    required CustomThemeService customThemes,
    required EspStreamService streamService,
    required NavigationManager navManager,
    required PhoneMediaService mediaService,
    required PhoneCallService callService,
  }) {
    final brightnessDim = (1.0 - (bleService.brightnessPct / 100.0)).clamp(0.0, 0.72) * 0.65;

    return _cardContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Top header & segmented switch Màn 1 / Màn 2
          Row(
            children: [
              const Icon(Icons.monitor_rounded, color: Color(0xFF5856D6), size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'MÀN HÌNH MÔ PHỎNG',
                  style: TextStyle(
                    color: Color(0xFF1C1C1E),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
              Text(
                _previewScreen == 0 ? 'Đang hiện Màn 1' : 'Đang hiện Màn 2',
                style: const TextStyle(
                  color: Color(0xFF5856D6),
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: const Color(0xFFF2F2F7),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                _buildScreenSegmentButton(
                  index: 0,
                  title: 'Màn 1 • Giao diện chờ',
                  icon: Icons.watch_rounded,
                ),
                const SizedBox(width: 4),
                _buildScreenSegmentButton(
                  index: 1,
                  title: 'Màn 2 • Bản đồ chờ',
                  icon: Icons.map_rounded,
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // Bezel with simulated LCD backlight dimming overlay
          Esp32Bezel(
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (_previewScreen == 0)
                  _buildMan1ThemeWidget(
                    customThemes: customThemes,
                    bleService: bleService,
                    mediaService: mediaService,
                    callService: callService,
                  )
                else
                  EspMan2Preview(
                    bleService: bleService,
                    streamService: streamService,
                    navManager: navManager,
                    mediaService: mediaService,
                    callService: callService,
                    currentTime: _currentTime,
                    man2BuiltInStyle: customThemes.man2BuiltInIndex,
                    man2CustomTheme: customThemes.activeMan2CustomTheme,
                    man2DefaultBgPath: customThemes.man2DefaultBgPath,
                  ),
                if (brightnessDim > 0.02)
                  IgnorePointer(
                    child: Container(
                      color: Colors.black.withValues(alpha: brightnessDim),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),

          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.sync_rounded, size: 14, color: Color(0xFF8E8E93)),
              const SizedBox(width: 6),
              Text(
                _previewScreen == 0
                    ? 'App và ESP32 đều đang hiển thị Màn 1'
                    : 'App và ESP32 đều đang hiển thị Màn 2 (Minimap)',
                style: const TextStyle(
                  color: Color(0xFF6E6E73),
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildScreenSegmentButton({
    required int index,
    required String title,
    required IconData icon,
  }) {
    final selected = _previewScreen == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => _switchPreviewScreen(index),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 8),
          decoration: BoxDecoration(
            color: selected ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 16,
                color: selected ? const Color(0xFF007AFF) : const Color(0xFF8E8E93),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected ? const Color(0xFF1C1C1E) : const Color(0xFF6E6E73),
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMan1ThemeWidget({
    required CustomThemeService customThemes,
    required BleService bleService,
    required PhoneMediaService mediaService,
    required PhoneCallService callService,
  }) {
    final hasCall = callService.isRinging;
    final hasSms = callService.showSmsNotification;
    final activeSender = hasCall
        ? callService.callerName
        : (hasSms ? callService.lastSmsSender : '');
    final activeMsg = hasCall
        ? (callService.phoneNumber.isNotEmpty
            ? 'Cuộc gọi đến • ${callService.phoneNumber}'
            : 'Cuộc gọi đến...')
        : (hasSms ? callService.lastSmsMessage : '');

    final activeCustom = customThemes.activeCustomTheme;
    if (activeCustom != null) {
      final hh = _currentTime.hour.toString().padLeft(2, '0');
      final mm = _currentTime.minute.toString().padLeft(2, '0');
      final songText = mediaService.hasMedia
          ? (mediaService.songArtist.isNotEmpty
              ? '${mediaService.songTitle} - ${mediaService.songArtist}'
              : mediaService.songTitle)
          : '';
      return DynamicCustomTheme(
        bgImagePath: activeCustom.bgImagePath,
        spec: activeCustom.spec,
        formattedTime: '$hh:$mm',
        now: _currentTime,
        songTitle: songText,
        songElapsedSec: mediaService.elapsedTime.round(),
        songDurationSec: mediaService.duration.round(),
        notifTitle: activeSender,
        notifMsg: activeMsg,
      );
    }

    final builtIn = ESP32InterfaceExt.fromIndex(customThemes.builtInIndex);
    final mock = SimulatorMockData(
      sender: activeSender.isNotEmpty ? activeSender : bleService.customBleName,
      message: activeMsg.isNotEmpty ? activeMsg : 'Sẵn sàng hiển thị thông báo',
      songTitle: mediaService.hasMedia ? mediaService.songTitle : 'Nhac tat',
      songArtist: mediaService.hasMedia && mediaService.songArtist.isNotEmpty
          ? mediaService.songArtist
          : 'Hoa hướng dương',
      elapsedSec: mediaService.hasMedia ? mediaService.elapsedTime.round() : 0,
      durationSec: mediaService.hasMedia ? mediaService.duration.round() : 0,
      batteryLevel: bleService.lastKnownBattery,
      isWifiConnected: bleService.isWifiConnected,
      isBleConnected: bleService.isConnected,
    );

    switch (builtIn) {
      case ESP32Interface.customStatic:
        return CustomStaticTheme(
          currentTime: _currentTime,
          mockData: mock,
          customBgPath: customThemes.customStaticBgPath,
        );
      case ESP32Interface.carbonSport:
        return CarbonSportTheme(currentTime: _currentTime, mockData: mock);
      case ESP32Interface.cyberRadar:
        return CyberRadarTheme(currentTime: _currentTime, mockData: mock);
      case ESP32Interface.retroMac:
        return RetroMacTheme(currentTime: _currentTime, mockData: mock);
      case ESP32Interface.cassetteWave:
        return CassetteWaveTheme(currentTime: _currentTime, mockData: mock);
      case ESP32Interface.comicStrip:
        return ComicStripTheme(currentTime: _currentTime, mockData: mock);
    }
  }

  // ---------------------------------------------------------------------------
  // 3. LỰA CHỌN GIAO DIỆN (MÀN 1 + MÀN 2 • CÓ SẴN + "+" ẢNH NỀN + NHẬP FILE ZIP)
  // ---------------------------------------------------------------------------
  Widget _buildThemeSection(CustomThemeService customThemes) {
    final busy = customThemes.isImporting || _isUploadingZipToEsp;
    final screenNum = _previewScreen + 1;
    final importedForTab = customThemes.themesForScreen(screenNum);

    return _cardContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.palette_rounded, color: Color(0xFF007AFF), size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'LỰA CHỌN GIAO DIỆN',
                  style: TextStyle(
                    color: Color(0xFF1C1C1E),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF5856D6),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: _showZipTemplateGuide,
                icon: const Icon(Icons.help_outline_rounded, size: 16),
                label: const Text(
                  'Mẫu ZIP',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 4),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF007AFF),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: busy ? null : _importZipTheme,
                icon: busy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.folder_zip_rounded, size: 16),
                label: Text(
                  _isUploadingZipToEsp ? 'Đang gửi...' : 'Nhập file ZIP',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Screen 1 / Screen 2 theme selector (synchronized with bezel preview & ESP32)
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: const Color(0xFFF2F2F7),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                _buildScreenSegmentButton(
                  index: 0,
                  title: 'Theme Màn 1',
                  icon: Icons.watch_rounded,
                ),
                const SizedBox(width: 4),
                _buildScreenSegmentButton(
                  index: 1,
                  title: 'Theme Màn 2',
                  icon: Icons.map_rounded,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          if (_previewScreen == 0)
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                childAspectRatio: 2.0,
              ),
              itemCount: ESP32Interface.values.length,
              itemBuilder: (context, index) {
                final theme = ESP32Interface.values[index];
                final isSelected = !customThemes.isCustomThemeActive &&
                    customThemes.builtInIndex == index;
                final isDefaultWaybar = index == 0;
                final hasCustomPhoto =
                    isDefaultWaybar && customThemes.customStaticBgPath != null;

                return _buildPresetTile(
                  title: theme.displayName,
                  subtitle: hasCustomPhoto
                      ? 'Đã chọn ảnh nền riêng'
                      : theme.subtitle,
                  accent: _builtInAccent(theme),
                  icon: _builtInIcon(theme),
                  isSelected: isSelected,
                  onTap: () => _selectBuiltInTheme(index),
                  trailingAction: isDefaultWaybar
                      ? _buildCirclePlusButton(
                          tooltip: 'Thêm / đổi ảnh nền từ thư viện',
                          onTap: busy ? null : _pickDefaultWaitImage,
                        )
                      : null,
                );
              },
            )
          else
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                childAspectRatio: 2.0,
              ),
              itemCount: _man2Presets.length,
              itemBuilder: (context, index) {
                final preset = _man2Presets[index];
                final isSelected = !customThemes.isMan2CustomThemeActive &&
                    customThemes.man2BuiltInIndex == preset.styleIndex;
                final isDefaultMan2 = preset.styleIndex == 0;
                final hasMan2Photo =
                    isDefaultMan2 && customThemes.man2DefaultBgPath != null;

                return _buildPresetTile(
                  title: preset.name,
                  subtitle: hasMan2Photo
                      ? 'Đã chọn ảnh thay map chờ'
                      : preset.subtitle,
                  accent: preset.accent,
                  icon: preset.icon,
                  isSelected: isSelected,
                  onTap: () => _selectMan2BuiltInTheme(preset.styleIndex),
                  trailingAction: isDefaultMan2
                      ? _buildCirclePlusButton(
                          tooltip: 'Thêm / đổi ảnh thay map khi chưa có Wi-Fi',
                          onTap: busy ? null : _pickMan2DefaultImage,
                        )
                      : null,
                );
              },
            ),

          // Imported custom ZIP themes for the active screen tab
          if (importedForTab.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              'THEME MÀN $screenNum ĐÃ NHẬP TỪ ZIP (${importedForTab.length})',
              style: const TextStyle(
                color: Color(0xFF6E6E73),
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.4,
              ),
            ),
            const SizedBox(height: 8),
            Column(
              children: importedForTab.map((t) {
                final selected = screenNum == 2
                    ? customThemes.activeMan2CustomThemeId == t.id
                    : customThemes.activeCustomThemeId == t.id;
                final accent = t.accentColor;
                final bgFile = t.bgImagePath.isNotEmpty ? File(t.bgImagePath) : null;
                final hasThumb = bgFile != null && bgFile.existsSync();

                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: selected
                        ? accent.withValues(alpha: 0.08)
                        : const Color(0xFFF9F9FB),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: selected ? accent : const Color(0xFFE5E5EA),
                      width: selected ? 1.8 : 1.0,
                    ),
                  ),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: busy ? null : () => _selectCustomTheme(t),
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: SizedBox(
                              width: 44,
                              height: 44,
                              child: hasThumb
                                  ? Image.file(bgFile, fit: BoxFit.cover)
                                  : Container(
                                      color: accent.withValues(alpha: 0.2),
                                      child: Icon(Icons.wallpaper_rounded, color: accent, size: 20),
                                    ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  t.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: selected ? accent : const Color(0xFF1C1C1E),
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  t.sourceSummary,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Color(0xFF8E8E93),
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (selected)
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: Icon(Icons.check_circle_rounded, color: accent, size: 19),
                            ),
                          IconButton(
                            tooltip: 'Xóa theme ZIP',
                            onPressed: () => _confirmDeleteCustomTheme(t),
                            icon: const Icon(
                              Icons.delete_outline_rounded,
                              color: Color(0xFFFF3B30),
                              size: 20,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCirclePlusButton({
    required String tooltip,
    required VoidCallback? onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: const Color(0xFF007AFF).withValues(alpha: 0.14),
            shape: BoxShape.circle,
            border: Border.all(
              color: const Color(0xFF007AFF).withValues(alpha: 0.4),
            ),
          ),
          child: const Icon(
            Icons.add_rounded,
            size: 17,
            color: Color(0xFF007AFF),
          ),
        ),
      ),
    );
  }

  Widget _buildPresetTile({
    required String title,
    required String subtitle,
    required Color accent,
    required IconData icon,
    required bool isSelected,
    required VoidCallback onTap,
    Widget? trailingAction,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? accent.withValues(alpha: 0.08)
              : const Color(0xFFF9F9FB),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected ? accent : const Color(0xFFE5E5EA),
            width: isSelected ? 1.8 : 1.0,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, color: accent, size: 17),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isSelected ? accent : const Color(0xFF1C1C1E),
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF8E8E93),
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
            if (isSelected)
              Icon(Icons.check_circle_rounded, color: accent, size: 16),
            if (trailingAction != null) ...[
              const SizedBox(width: 4),
              trailingAction,
            ],
          ],
        ),
      ),
    );
  }

  Color _builtInAccent(ESP32Interface t) {
    switch (t) {
      case ESP32Interface.customStatic:
        return const Color(0xFF007AFF);
      case ESP32Interface.carbonSport:
        return const Color(0xFFEAB308);
      case ESP32Interface.cyberRadar:
        return const Color(0xFF06B6D4);
      case ESP32Interface.retroMac:
        return const Color(0xFF6366F1);
      case ESP32Interface.cassetteWave:
        return const Color(0xFFEC4899);
      case ESP32Interface.comicStrip:
        return const Color(0xFFF97316);
    }
  }

  IconData _builtInIcon(ESP32Interface t) {
    switch (t) {
      case ESP32Interface.customStatic:
        return Icons.wallpaper_rounded;
      case ESP32Interface.carbonSport:
        return Icons.wb_sunny_rounded;
      case ESP32Interface.cyberRadar:
        return Icons.radar_rounded;
      case ESP32Interface.retroMac:
        return Icons.computer_rounded;
      case ESP32Interface.cassetteWave:
        return Icons.album_rounded;
      case ESP32Interface.comicStrip:
        return Icons.auto_stories_rounded;
    }
  }

  // ---------------------------------------------------------------------------
  // 4. TỈ LỆ PHÓNG TO MINIMAP
  // ---------------------------------------------------------------------------
  Widget _buildMinimapZoomCard(EspStreamService streamService) {
    final zoom = streamService.minimapZoom;
    return _cardContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.zoom_in_rounded, color: Color(0xFF007AFF), size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'TỈ LỆ PHÓNG TO MINIMAP',
                  style: TextStyle(
                    color: Color(0xFF1C1C1E),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFF007AFF).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  'Zoom x$zoom',
                  style: const TextStyle(
                    color: Color(0xFF007AFF),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            _zoomDescriptions[zoom] ?? '',
            style: const TextStyle(color: Color(0xFF6E6E73), fontSize: 12),
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: const Color(0xFF007AFF),
              inactiveTrackColor: const Color(0xFFE5E5EA),
              thumbColor: Colors.white,
              overlayColor: const Color(0xFF007AFF).withValues(alpha: 0.2),
              trackHeight: 6,
            ),
            child: Slider(
              value: zoom.toDouble(),
              min: 14,
              max: 18,
              divisions: 4,
              onChanged: (v) {
                streamService.minimapZoom = v.round();
                _switchPreviewScreen(1);
              },
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildZoomPresetChip(streamService, 14, 'x14 Xa'),
              _buildZoomPresetChip(streamService, 15, 'x15 Vùng'),
              _buildZoomPresetChip(streamService, 16, 'x16 Chuẩn'),
              _buildZoomPresetChip(streamService, 17, 'x17 Chi tiết'),
              _buildZoomPresetChip(streamService, 18, 'x18 Cận cảnh'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildZoomPresetChip(
    EspStreamService streamService,
    int z,
    String label,
  ) {
    final selected = streamService.minimapZoom == z;
    return GestureDetector(
      onTap: () {
        streamService.minimapZoom = z;
        _switchPreviewScreen(1);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF007AFF) : const Color(0xFFF2F2F7),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : const Color(0xFF3C3C43),
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 5. BẢN ĐỒ MINIMAP
  // ---------------------------------------------------------------------------
  Widget _buildMinimapStyleCard(EspStreamService streamService) {
    return _cardContainer(
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF5856D6).withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.layers_rounded, color: Color(0xFF5856D6), size: 20),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'BẢN ĐỒ MINIMAP',
                  style: TextStyle(
                    color: Color(0xFF1C1C1E),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.4,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Nguồn map & phong cách gửi sang ESP32',
                  style: TextStyle(color: Color(0xFF8E8E93), fontSize: 11),
                ),
              ],
            ),
          ),
          DropdownButton<String>(
            value: EspStreamService.supportedMapStyles.contains(streamService.streamMapStyle)
                ? streamService.streamMapStyle
                : 'osm-3d',
            dropdownColor: Colors.white,
            underline: const SizedBox(),
            icon: const Icon(Icons.arrow_drop_down_rounded, color: Color(0xFF007AFF)),
            style: const TextStyle(
              color: Color(0xFF007AFF),
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
            items: const [
              DropdownMenuItem(value: 'osm-3d', child: Text('OSM 3D Khối')),
              DropdownMenuItem(value: 'osm-3d-dark', child: Text('OSM 3D Khối (Tối)')),
              DropdownMenuItem(value: 'goong-streets', child: Text('Bản đồ Việt Nam (Sáng)')),
              DropdownMenuItem(value: 'goong-dark', child: Text('Bản đồ Việt Nam (Tối)')),
              DropdownMenuItem(value: 'streets-v2', child: Text('Bản đồ đường phố (Sáng)')),
              DropdownMenuItem(value: 'streets-v2-dark', child: Text('Bản đồ đường phố (Tối)')),
              DropdownMenuItem(value: 'hybrid', child: Text('Hybrid (Vệ tinh)')),
            ],
            onChanged: (val) {
              if (val == null) return;
              streamService.setUserMapStyle(val);
              _switchPreviewScreen(1);
            },
          ),
        ],
      ),
    );
  }
}

