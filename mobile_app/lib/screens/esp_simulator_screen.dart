import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/simulator_presets.dart';
import '../models/esp32_interface.dart';
import '../services/ble_service.dart';
import '../services/esp_stream_service.dart';
import '../services/phone_call_service.dart';
import '../services/phone_media_service.dart';
import '../widgets/simulator/carbon_sport_theme.dart';
import '../widgets/simulator/cassette_wave_theme.dart';
import '../widgets/simulator/comic_strip_theme.dart';
import '../widgets/simulator/custom_static_theme.dart';
import '../widgets/simulator/cyber_radar_theme.dart';
import '../widgets/simulator/esp32_bezel.dart';
import '../widgets/simulator/retro_mac_theme.dart';

/// Màn hình mô phỏng ESP32 (ESP32 Simulator / Emulator)
/// Cho phép chọn 6 giao diện màn chờ, tải ảnh nền, xem trước thời gian thực và đồng bộ sang ESP32
class EspSimulatorScreen extends StatefulWidget {
  final VoidCallback? onBackToMap;

  const EspSimulatorScreen({super.key, this.onBackToMap});

  @override
  State<EspSimulatorScreen> createState() => _EspSimulatorScreenState();
}

class _EspSimulatorScreenState extends State<EspSimulatorScreen> {
  static const String _prefThemeKey = 'esp32_interface_theme';
  static const String _prefBgPathKey = 'esp32_custom_bg_path';

  ESP32Interface _selectedTheme = ESP32Interface.customStatic;
  String? _customBgPath;
  DateTime _currentTime = DateTime.now();
  Timer? _clockTimer;
  final SimulatorMockData _mockData = SimulatorMockData.defaultPreset;
  bool _useRealMedia = true;
  bool _isCompressingBg = false;
  final GlobalKey _simulatorKey = GlobalKey();
  bool _isCapturingFrame = false;

  @override
  void initState() {
    super.initState();
    _loadSavedPreferences();
    _startClockTimer();
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    try {
      final ble = context.read<BleService>();
      if (ble.isConnected) {
        ble.sendRawJson(jsonEncode({'type': 'EXIT_SIMULATOR'}));
      }
    } catch (_) {}
    super.dispose();
  }

  void _startClockTimer() {
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {
          _currentTime = DateTime.now();
        });
        _captureAndStreamFrame();
      }
    });
  }

  Future<void> _captureAndStreamFrame() async {
    if (_isCapturingFrame) return;
    _isCapturingFrame = true;
    try {
      final boundary = _simulatorKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null || !boundary.hasSize) return;

      final double pixelRatio = (320.0 / boundary.size.width).clamp(0.5, 2.0);
      final ui.Image image = await boundary.toImage(pixelRatio: pixelRatio);
      final ByteData? byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();

      if (byteData != null) {
        final rawRgba = byteData.buffer.asUint8List();
        final imgObj = img.Image.fromBytes(
          width: 320,
          height: 240,
          bytes: rawRgba.buffer,
          order: img.ChannelOrder.rgba,
        );

        final jpgBytes = Uint8List.fromList(img.encodeJpg(imgObj, quality: 75));

        if (mounted) {
          final streamService = context.read<EspStreamService>();
          streamService.transmitSimulatorFrame(jpgBytes);
        }
      }
    } catch (_) {
    } finally {
      _isCapturingFrame = false;
    }
  }

  Future<void> _loadSavedPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedThemeIndex = prefs.getInt(_prefThemeKey);
      final savedBgPath = prefs.getString(_prefBgPathKey);

      if (mounted) {
        setState(() {
          if (savedThemeIndex != null) {
            _selectedTheme = ESP32InterfaceExt.fromIndex(savedThemeIndex);
          }
          _customBgPath = savedBgPath;
        });
      }
    } catch (e) {
      debugPrint('[Simulator] Lỗi tải SharedPreferences: $e');
    }
  }

  Future<void> _selectTheme(ESP32Interface theme) async {
    setState(() {
      _selectedTheme = theme;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefThemeKey, theme.index);

      // Đồng bộ sang ESP32 qua BLE và WebSocket
      _syncThemeToEsp32(theme);

      WidgetsBinding.instance.addPostFrameCallback((_) {
        _captureAndStreamFrame();
      });
    } catch (e) {
      debugPrint('[Simulator] Lỗi lưu theme: $e');
    }
  }

  Future<void> _pickCustomBackground() async {
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1280,
        maxHeight: 960,
      );

      if (picked == null) return;

      setState(() {
        _customBgPath = picked.path;
        _selectedTheme = ESP32Interface.customStatic;
      });

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefBgPathKey, picked.path);
      await prefs.setInt(_prefThemeKey, ESP32Interface.customStatic.index);

      // Nén ảnh sang 320x240 và đồng bộ sang ESP32
      await _compressAndSyncBackground(picked.path);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Đã cập nhật ảnh nền Màn Chờ ESP32 thành công!'),
            backgroundColor: Color(0xFF05FFA1),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      debugPrint('[Simulator] Lỗi chọn ảnh nền: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Lỗi chọn ảnh: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  Future<void> _compressAndSyncBackground(String imagePath) async {
    setState(() => _isCompressingBg = true);
    try {
      final file = File(imagePath);
      if (!await file.exists()) return;

      final bytes = await file.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded != null) {
        // Cắt ảnh theo tỉ lệ 4:3 từ tâm (tránh méo / mờ khi ảnh chụp từ iPhone là ảnh dọc)
        final srcW = decoded.width;
        final srcH = decoded.height;
        int cropW = srcW;
        int cropH = srcH;
        int cropX = 0;
        int cropY = 0;

        if (srcW * 3 > srcH * 4) {
          cropW = (srcH * 4) ~/ 3;
          cropX = (srcW - cropW) ~/ 2;
        } else {
          cropH = (srcW * 3) ~/ 4;
          cropY = (srcH - cropH) ~/ 2;
        }

        final cropped = img.copyCrop(
          decoded,
          x: cropX,
          y: cropY,
          width: cropW,
          height: cropH,
        );

        // Resize chính xác 320x240 chuẩn màn hình ST7789 bằng bộ lọc cubic sắc nét
        final resized = img.copyResize(
          cropped,
          width: 320,
          height: 240,
          interpolation: img.Interpolation.cubic,
        );
        final jpgBytes = Uint8List.fromList(img.encodeJpg(resized, quality: 92));

        // Lưu bản 320x240 này vào file để Simulator hiển thị nét tuyệt đối
        final processedPath = '${file.parent.path}/esp32_wallpaper_320x240.jpg';
        await File(processedPath).writeAsBytes(jpgBytes);

        if (mounted) {
          setState(() {
            _customBgPath = processedPath;
          });
        }
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_prefBgPathKey, processedPath);

        // 1. Gửi cấu hình theme sang ESP32
        _syncThemeToEsp32(ESP32Interface.customStatic, bgBytes: jpgBytes);

        // 2. Nạp ảnh nền tùy chọn lên Flash SPIFFS của ESP32 qua BLE chunks (Magic 0xBC)
        await _uploadCustomBgToEsp32(jpgBytes);
      }
    } catch (e) {
      debugPrint('[Simulator] Lỗi nén ảnh nền: $e');
    } finally {
      if (mounted) {
        setState(() => _isCompressingBg = false);
      }
    }
  }

  Future<void> _uploadCustomBgToEsp32(Uint8List jpegBytes) async {
    try {
      final bleService = context.read<BleService>();
      if (!bleService.isConnected) return;

      final int chunkSize = bleService.safeChunkSize;
      final int totalLen = jpegBytes.length;
      final int totalChunks = (totalLen / chunkSize).ceil();
      const int magic2 = 0xBC; // 0xBC: standby pairing background /bg_wait.jpg

      for (int i = 0; i < totalChunks; i++) {
        if (!mounted || !bleService.isConnected) break;
        final start = i * chunkSize;
        final end = (start + chunkSize > totalLen) ? totalLen : start + chunkSize;
        final slice = jpegBytes.sublist(start, end);

        final packet = Uint8List(5 + slice.length);
        packet[0] = 0xAA;
        packet[1] = magic2;
        packet[2] = 0;
        packet[3] = totalChunks;
        packet[4] = i;
        packet.setRange(5, 5 + slice.length, slice);

        await bleService.sendRawBytes(packet);
        await Future.delayed(const Duration(milliseconds: 15));
      }
      debugPrint('[Simulator] Đã nạp ảnh nền tùy chọn lên ESP32 Flash SPIFFS');
    } catch (e) {
      debugPrint('[Simulator] Lỗi tải ảnh nền lên ESP32: $e');
    }
  }

  void _syncThemeToEsp32(ESP32Interface theme, {Uint8List? bgBytes}) {
    try {
      final ble = context.read<BleService>();
      final payload = jsonEncode({
        'type': 'THEME_SELECT',
        'theme': theme.index,
        'themeId': theme.id,
        'bgPath': _customBgPath,
        'hasCustomBg': _customBgPath != null && _customBgPath!.isNotEmpty,
      });

      ble.sendRawJson(payload);
      debugPrint('[Simulator] Đã đồng bộ theme sang ESP32: $payload');
    } catch (e) {
      debugPrint('[Simulator] Lỗi đồng bộ theme BLE: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Tự động cập nhật bài hát thực tế từ iPhone nếu người dùng bật
    final mediaService = context.watch<PhoneMediaService>();
    final effectiveMock = _buildEffectiveMockData(mediaService);

    return Scaffold(
      backgroundColor: const Color(0xFF0B1017),
      appBar: AppBar(
        backgroundColor: const Color(0xFF131B26),
        elevation: 0,
        leading: widget.onBackToMap != null
            ? IconButton(
                icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                onPressed: widget.onBackToMap,
              )
            : null,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Mô phỏng Màn hình ESP32',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
            ),
            Text(
              'ST7789 2.4" 320x240 • 6 Giao diện thời gian thực',
              style: TextStyle(color: Color(0xFF00F0FF), fontSize: 10, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Chọn ảnh nền cho Màn Chờ',
            icon: const Icon(Icons.add_photo_alternate_rounded, color: Color(0xFF00F0FF)),
            onPressed: _pickCustomBackground,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // ─── 1. ESP32 BEZEL SIMULATOR (Ratio 4:3) ───
            Esp32Bezel(
              scale: 1.05, // Phóng to nhẹ để xem rõ ràng sắc nét trên iPhone
              child: RepaintBoundary(
                key: _simulatorKey,
                child: SizedBox(
                  width: 320,
                  height: 240,
                  child: _buildCurrentInterfaceView(effectiveMock),
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Indicator label
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF161F2E),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFF00F0FF).withValues(alpha: 0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.visibility_rounded, color: Color(0xFF00F0FF), size: 14),
                  const SizedBox(width: 6),
                  Text(
                    'ĐANG XEM: ${_selectedTheme.displayName.toUpperCase()}',
                    style: const TextStyle(
                      color: Color(0xFF00F0FF),
                      fontSize: 10.5,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // ─── 2. THEME SELECTOR LIST (6 GIAO DIỆN) ───
            _buildThemeSelectorSection(),

            const SizedBox(height: 20),

            // ─── 3. SIMULATOR CONTROLS & TEST TOOLS ───
            _buildSimulatorToolsCard(mediaService),

            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildCurrentInterfaceView(SimulatorMockData mock) {
    switch (_selectedTheme) {
      case ESP32Interface.customStatic:
        return CustomStaticTheme(
          customBgPath: _customBgPath,
          currentTime: _currentTime,
          mockData: mock,
        );
      case ESP32Interface.carbonSport:
        return CarbonSportTheme(
          currentTime: _currentTime,
          mockData: mock,
        );
      case ESP32Interface.cyberRadar:
        return CyberRadarTheme(
          currentTime: _currentTime,
          mockData: mock,
        );
      case ESP32Interface.retroMac:
        return RetroMacTheme(
          currentTime: _currentTime,
          mockData: mock,
        );
      case ESP32Interface.cassetteWave:
        return CassetteWaveTheme(
          currentTime: _currentTime,
          mockData: mock,
        );
      case ESP32Interface.comicStrip:
        return ComicStripTheme(
          currentTime: _currentTime,
          mockData: mock,
        );
    }
  }

  Widget _buildThemeSelectorSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'LỰA CHỌN GIAO DIỆN (6 THEMES)',
              style: TextStyle(
                color: Colors.white,
                fontSize: 12.5,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.8,
              ),
            ),
            if (_isCompressingBg)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00F0FF)),
              ),
          ],
        ),
        const SizedBox(height: 10),

        // Grid of 6 Theme Cards
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 2.1,
          ),
          itemCount: ESP32Interface.values.length,
          itemBuilder: (context, index) {
            final theme = ESP32Interface.values[index];
            final isSelected = _selectedTheme == theme;

            return InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () {
                _selectTheme(theme);
                if (theme == ESP32Interface.customStatic) {
                  _pickCustomBackground();
                }
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: isSelected
                      ? const Color(0xFF00F0FF).withValues(alpha: 0.16)
                      : const Color(0xFF131B26),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isSelected ? const Color(0xFF00F0FF) : Colors.white12,
                    width: isSelected ? 1.8 : 1.0,
                  ),
                  boxShadow: isSelected
                      ? [
                          BoxShadow(
                            color: const Color(0xFF00F0FF).withValues(alpha: 0.25),
                            blurRadius: 10,
                          ),
                        ]
                      : null,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: _getThemeAccentColor(theme).withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(_getThemeIcon(theme), color: _getThemeAccentColor(theme), size: 18),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            theme.displayName,
                            style: TextStyle(
                              color: isSelected ? const Color(0xFF00F0FF) : Colors.white,
                              fontSize: 10.5,
                              fontWeight: FontWeight.bold,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            theme.subtitle,
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 8.5,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    if (isSelected)
                      const Icon(Icons.check_circle_rounded, color: Color(0xFF00F0FF), size: 16),
                  ],
                ),
              ),
            );
          },
        ),

        const SizedBox(height: 12),

        // Button: Pick Custom Background for Màn Chờ
        SizedBox(
          width: double.infinity,
          height: 44,
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF162130),
              foregroundColor: const Color(0xFF00F0FF),
              elevation: 0,
              side: const BorderSide(color: Color(0xFF00F0FF), width: 1.2),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.photo_library_rounded, size: 18),
            label: Text(
              _customBgPath != null
                  ? 'Đổi ảnh nền Màn Chờ (Hiện: ${_customBgPath!.split('/').last})'
                  : 'Chọn ảnh từ Album làm Màn Chờ',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onPressed: _pickCustomBackground,
          ),
        ),
      ],
    );
  }

  Widget _buildSimulatorToolsCard(PhoneMediaService mediaService) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF131B26),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(Icons.tune_rounded, color: Color(0xFF05FFA1), size: 18),
                  SizedBox(width: 8),
                  Text(
                    'CÔNG CỤ TEST DỮ LIỆU GIẢ LẬP',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.6,
                    ),
                  ),
                ],
              ),
              // Switch: Use real iPhone media vs preset mock
              Row(
                children: [
                  const Text('Nhạc thật:', style: TextStyle(color: Colors.white60, fontSize: 10.5)),
                  const SizedBox(width: 4),
                  Switch(
                    value: _useRealMedia,
                    activeTrackColor: const Color(0xFF05FFA1),
                    activeThumbColor: const Color(0xFF0B1017),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onChanged: (val) => setState(() => _useRealMedia = val),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Action Chips to trigger mock alerts
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ActionChip(
                avatar: const Icon(Icons.call_rounded, size: 14, color: Color(0xFF05FFA1)),
                backgroundColor: const Color(0xFF05FFA1).withValues(alpha: 0.12),
                side: const BorderSide(color: Color(0xFF05FFA1)),
                label: const Text('Test Cuộc gọi đến', style: TextStyle(color: Color(0xFF05FFA1), fontSize: 11, fontWeight: FontWeight.bold)),
                onPressed: () {
                  final callService = context.read<PhoneCallService>();
                  callService.triggerMockCall(name: 'Vợ', number: '083 567 8628');
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Đã kích hoạt cuộc gọi giả lập trên ESP32!'), behavior: SnackBarBehavior.floating),
                  );
                },
              ),
              ActionChip(
                avatar: const Icon(Icons.chat_bubble_rounded, size: 14, color: Color(0xFFFFB800)),
                backgroundColor: const Color(0xFFFFB800).withValues(alpha: 0.12),
                side: const BorderSide(color: Color(0xFFFFB800)),
                label: const Text('Test Tin nhắn Vợ', style: TextStyle(color: Color(0xFFFFB800), fontSize: 11, fontWeight: FontWeight.bold)),
                onPressed: () {
                  final ble = context.read<BleService>();
                  ble.sendRawJson(jsonEncode({
                    'type': 'NOTIFICATION',
                    'title': 'Vợ',
                    'msg': 'Mua đồ ăn tối chưa anh ơi?',
                    'app': 'imessage',
                  }));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Đã gửi tin nhắn giả lập sang ESP32!'), behavior: SnackBarBehavior.floating),
                  );
                },
              ),
              ActionChip(
                avatar: const Icon(Icons.sync_rounded, size: 14, color: Color(0xFF38BDF8)),
                backgroundColor: const Color(0xFF38BDF8).withValues(alpha: 0.12),
                side: const BorderSide(color: Color(0xFF38BDF8)),
                label: const Text('Gửi theme sang ESP32', style: TextStyle(color: Color(0xFF38BDF8), fontSize: 11, fontWeight: FontWeight.bold)),
                onPressed: () {
                  _syncThemeToEsp32(_selectedTheme);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Đã gửi lệnh chuyển sang ${_selectedTheme.displayName} sang ESP32!'), behavior: SnackBarBehavior.floating),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  SimulatorMockData _buildEffectiveMockData(PhoneMediaService mediaService) {
    if (_useRealMedia && mediaService.hasMedia) {
      return _mockData.copyWith(
        songTitle: mediaService.songTitle,
        songArtist: mediaService.songArtist,
        elapsedSec: mediaService.elapsedTime.round(),
        durationSec: mediaService.duration > 0 ? mediaService.duration.round() : 232,
      );
    }
    return _mockData;
  }

  Color _getThemeAccentColor(ESP32Interface theme) {
    switch (theme) {
      case ESP32Interface.customStatic:
        return const Color(0xFF38BDF8);
      case ESP32Interface.carbonSport:
        return const Color(0xFFFBBF24);
      case ESP32Interface.cyberRadar:
        return const Color(0xFF00E5FF);
      case ESP32Interface.retroMac:
        return const Color(0xFF94A3B8);
      case ESP32Interface.cassetteWave:
        return const Color(0xFFFF3399);
      case ESP32Interface.comicStrip:
        return const Color(0xFFF97316);
    }
  }

  IconData _getThemeIcon(ESP32Interface theme) {
    switch (theme) {
      case ESP32Interface.customStatic:
        return Icons.wallpaper_rounded;
      case ESP32Interface.carbonSport:
        return Icons.wb_sunny_rounded;
      case ESP32Interface.cyberRadar:
        return Icons.radar_rounded;
      case ESP32Interface.retroMac:
        return Icons.desktop_windows_rounded;
      case ESP32Interface.cassetteWave:
        return Icons.album_rounded;
      case ESP32Interface.comicStrip:
        return Icons.auto_stories_rounded;
    }
  }
}
