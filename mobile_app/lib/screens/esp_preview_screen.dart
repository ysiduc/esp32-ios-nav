import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import '../services/ble_service.dart';
import '../services/esp_stream_service.dart';
import '../services/navigation_manager.dart';
import '../services/phone_media_service.dart';
import '../services/phone_call_service.dart';

class EspPreviewScreen extends StatefulWidget {
  final VoidCallback? onBackToMap;
  const EspPreviewScreen({super.key, this.onBackToMap});

  @override
  State<EspPreviewScreen> createState() => _EspPreviewScreenState();
}

class _EspPreviewScreenState extends State<EspPreviewScreen> {
  final GlobalKey _streamBoundaryKey = GlobalKey();

  bool _showCallPopup = false;
  bool _showSmsPopup = false;
  final TextEditingController _callerNameCtrl = TextEditingController(text: 'Mẹ');
  final TextEditingController _callerNumCtrl = TextEditingController(text: '0912 345 678');
  final TextEditingController _smsSenderCtrl = TextEditingController(text: 'Zalo: Anh Nam');
  final TextEditingController _smsMsgCtrl = TextEditingController(text: 'Bạn đang ở đâu đấy?');

  Timer? _popupDismissTimer;
  Timer? _autoStartTimer;
  Timer? _previewSyncTimer;

  // Background Upload State
  bool _isUploadingBg = false;
  double _uploadProgress = 0.0;
  String _uploadStatusText = '';
  Uint8List? _waitImagePreview;
  Uint8List? _mapImagePreview;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Auto-start headless 20-30 FPS JPEG streaming immediately
      _autoStartTimer = Timer(const Duration(milliseconds: 200), () {
        if (mounted) {
          final streamService = Provider.of<EspStreamService>(context, listen: false);
          if (!streamService.isStreaming) {
            streamService.startStreaming();
          }
        }
      });

      // Synchronize HUD navigation telemetry with physical ESP32 screen
      _previewSyncTimer = Timer.periodic(const Duration(milliseconds: 1200), (_) {
        if (mounted) {
          final nav = Provider.of<NavigationManager>(context, listen: false);
          nav.sendPreviewPayloadToEsp32();
        }
      });
      final nav = Provider.of<NavigationManager>(context, listen: false);
      nav.sendPreviewPayloadToEsp32();
    });
  }

  void _triggerCall({String? name, String? number}) {
    _popupDismissTimer?.cancel();
    final callName = name ?? _callerNameCtrl.text.trim();
    final callNum = number ?? _callerNumCtrl.text.trim();

    setState(() {
      _showCallPopup = true;
      _showSmsPopup = false;
    });

    final callService = Provider.of<PhoneCallService>(context, listen: false);
    callService.triggerMockCall(name: callName, number: callNum);

    _popupDismissTimer = Timer(const Duration(seconds: 10), () {
      if (mounted) setState(() => _showCallPopup = false);
    });
  }

  void _dismissCall() {
    _popupDismissTimer?.cancel();
    setState(() => _showCallPopup = false);
    final bleService = Provider.of<BleService>(context, listen: false);
    if (bleService.isConnected) {
      bleService.sendRawString('{"type":"CALL_END"}');
    }
  }

  void _triggerSms({String? sender, String? message}) {
    _popupDismissTimer?.cancel();
    final sName = sender ?? _smsSenderCtrl.text.trim();
    final sMsg = message ?? _smsMsgCtrl.text.trim();

    setState(() {
      _showSmsPopup = true;
      _showCallPopup = false;
    });

    final callService = Provider.of<PhoneCallService>(context, listen: false);
    callService.triggerMockSms(sender: sName, message: sMsg);

    _popupDismissTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) setState(() => _showSmsPopup = false);
    });
  }

  Future<void> _pickAndUploadImage({required bool isWaitScreen}) async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery, imageQuality: 95);
    if (picked == null) return;

    final bytes = await picked.readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Không thể giải mã file ảnh!'), backgroundColor: Colors.red),
        );
      }
      return;
    }

    final int targetW = isWaitScreen ? 320 : 144;
    final int targetH = isWaitScreen ? 240 : 208;
    final double targetRatio = targetW / targetH;
    final double currentRatio = decoded.width / decoded.height;

    int cropW = decoded.width;
    int cropH = decoded.height;
    int cropX = 0;
    int cropY = 0;

    if (currentRatio > targetRatio) {
      cropW = (decoded.height * targetRatio).round();
      cropX = (decoded.width - cropW) ~/ 2;
    } else {
      cropH = (decoded.width / targetRatio).round();
      cropY = (decoded.height - cropH) ~/ 2;
    }

    final cropped = img.copyCrop(decoded, x: cropX, y: cropY, width: cropW, height: cropH);
    final resized = img.copyResize(cropped, width: targetW, height: targetH, interpolation: img.Interpolation.linear);
    final jpegBytes = Uint8List.fromList(img.encodeJpg(resized, quality: 82));

    setState(() {
      if (isWaitScreen) {
        _waitImagePreview = jpegBytes;
      } else {
        _mapImagePreview = jpegBytes;
      }
    });

    await _sendImageToEsp32(jpegBytes: jpegBytes, isWaitScreen: isWaitScreen);
  }

  Future<void> _sendImageToEsp32({required Uint8List jpegBytes, required bool isWaitScreen}) async {
    final bleService = Provider.of<BleService>(context, listen: false);
    final streamService = Provider.of<EspStreamService>(context, listen: false);

    if (!bleService.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Vui lòng kết nối ESP32 qua Bluetooth trước!'), backgroundColor: Colors.orange),
      );
      return;
    }

    final bool wasStreaming = streamService.isStreaming;
    if (wasStreaming) {
      streamService.stopStreaming();
    }

    setState(() {
      _isUploadingBg = true;
      _uploadProgress = 0.0;
      _uploadStatusText = 'Đang tải ảnh (${(jpegBytes.length / 1024).toStringAsFixed(1)} KB)...';
    });

    final int chunkSize = bleService.safeChunkSize;
    final int totalLen = jpegBytes.length;
    final int totalChunks = (totalLen / chunkSize).ceil();
    final int magic2 = isWaitScreen ? 0xBC : 0xBD;

    bool uploadSuccess = true;

    for (int i = 0; i < totalChunks; i++) {
      if (!mounted || !bleService.isConnected) {
        uploadSuccess = false;
        break;
      }

      final start = i * chunkSize;
      final end = (start + chunkSize > totalLen) ? totalLen : start + chunkSize;
      final slice = jpegBytes.sublist(start, end);

      // Packet: [0xAA, magic2, 0, totalChunks, chunkIdx, ...slice]
      final packet = Uint8List(5 + slice.length);
      packet[0] = 0xAA;
      packet[1] = magic2;
      packet[2] = 0;
      packet[3] = totalChunks;
      packet[4] = i;
      packet.setRange(5, 5 + slice.length, slice);

      final success = await bleService.sendRawBytes(packet);
      if (!success) {
        uploadSuccess = false;
        break;
      }

      setState(() {
        _uploadProgress = (i + 1) / totalChunks;
        _uploadStatusText = 'Đang nạp Flash: ${((i + 1) / totalChunks * 100).toInt()}% (${i + 1}/$totalChunks)';
      });

      await Future.delayed(const Duration(milliseconds: 15));
    }

    if (wasStreaming && mounted) {
      streamService.startStreaming();
    }

    if (mounted) {
      setState(() {
        _isUploadingBg = false;
      });

      if (uploadSuccess) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isWaitScreen
                  ? '✓ Đã lưu ảnh màn chờ vào Flash ESP32 thành công!'
                  : '✓ Đã lưu ảnh màn Map vào Flash ESP32 thành công!',
            ),
            backgroundColor: const Color(0xFF05FFA1),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Lỗi gửi ảnh sang ESP32!'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _deleteBgImage({required bool isWaitScreen}) async {
    final bleService = Provider.of<BleService>(context, listen: false);
    if (!bleService.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Vui lòng kết nối ESP32 qua Bluetooth!'), backgroundColor: Colors.orange),
      );
      return;
    }

    final target = isWaitScreen ? 'wait' : 'map';
    await bleService.sendRawString('{"type":"DEL_BG","target":"$target"}');

    setState(() {
      if (isWaitScreen) {
        _waitImagePreview = null;
      } else {
        _mapImagePreview = null;
      }
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isWaitScreen ? 'Đã xóa ảnh màn chờ, khôi phục mặc định.' : 'Đã xóa ảnh màn Map, khôi phục mặc định.'),
          backgroundColor: Colors.blueAccent,
        ),
      );
    }
  }

  @override
  void dispose() {
    _autoStartTimer?.cancel();
    _previewSyncTimer?.cancel();
    _popupDismissTimer?.cancel();
    _callerNameCtrl.dispose();
    _callerNumCtrl.dispose();
    _smsSenderCtrl.dispose();
    _smsMsgCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final navManager = context.watch<NavigationManager>();
    final bleService = context.watch<BleService>();
    final streamService = context.watch<EspStreamService>();
    final mediaService = context.watch<PhoneMediaService>();
    final phoneCallService = context.watch<PhoneCallService>();

    final isCallActive = _showCallPopup || phoneCallService.isRinging;
    final isSmsActive = _showSmsPopup || phoneCallService.showSmsNotification;
    final activeCallerName = phoneCallService.isRinging ? phoneCallService.callerName : _callerNameCtrl.text;
    final activeCallerNum = phoneCallService.isRinging ? phoneCallService.phoneNumber : _callerNumCtrl.text;
    final activeSmsSender = phoneCallService.showSmsNotification ? phoneCallService.lastSmsSender : _smsSenderCtrl.text;
    final activeSmsMsg = phoneCallService.showSmsNotification ? phoneCallService.lastSmsMessage : _smsMsgCtrl.text;

    final userLoc = navManager.currentLocation ??
        (navManager.activeRoute?.polylinePoints.isNotEmpty == true
            ? navManager.activeRoute!.polylinePoints.first
            : const LatLng(20.9832, 105.8425));



    return Scaffold(
      backgroundColor: const Color(0xFF0B0F17),
      appBar: AppBar(
        backgroundColor: const Color(0xFF131B26),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Color(0xFF00F0FF)),
          tooltip: 'Quay lại Bản đồ',
          onPressed: () {
            if (widget.onBackToMap != null) {
              widget.onBackToMap!();
            } else if (Navigator.canPop(context)) {
              Navigator.pop(context);
            }
          },
        ),
        title: const Row(
          children: [
            Icon(Icons.tv_rounded, color: Color(0xFF00F0FF)),
            SizedBox(width: 10),
            Text('Mô phỏng Màn hình ESP32', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          ],
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Stream Control & FPS Bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF131B26),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: streamService.isStreaming ? const Color(0xFF00F0FF) : Colors.white12),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: streamService.isStreaming ? const Color(0xFF05FFA1) : Colors.grey,
                              boxShadow: streamService.isStreaming
                                  ? [BoxShadow(color: const Color(0xFF05FFA1).withAlpha(180), blurRadius: 6)]
                                  : [],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            streamService.isStreaming ? 'Đang Stream JPEG Zoom x16 sang ESP32' : 'Dừng Stream',
                            style: TextStyle(
                              color: streamService.isStreaming ? const Color(0xFF05FFA1) : Colors.white54,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                      Switch.adaptive(
                        value: streamService.isStreaming,
                        activeTrackColor: const Color(0xFF00F0FF),
                        onChanged: (val) {
                          if (val) {
                            streamService.startStreaming(boundaryKey: _streamBoundaryKey);
                          } else {
                            streamService.stopStreaming();
                          }
                        },
                      ),
                    ],
                  ),
                  const Divider(color: Colors.white12, height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      Column(
                        children: [
                          const Text('FPS THỰC TẾ', style: TextStyle(color: Colors.white54, fontSize: 10, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 2),
                          Text(
                            '${streamService.actualFps.toStringAsFixed(1)} FPS',
                            style: const TextStyle(color: Color(0xFF05FFA1), fontSize: 14, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
                          ),
                        ],
                      ),
                      Container(width: 1, height: 24, color: Colors.white12),
                      Column(
                        children: [
                          const Text('KÍCH THƯỚC FRAME', style: TextStyle(color: Colors.white54, fontSize: 10, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 2),
                          Text(
                            '${streamService.frameSizeKb} KB',
                            style: const TextStyle(color: Color(0xFF00F0FF), fontSize: 14, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
                          ),
                        ],
                      ),
                      Container(width: 1, height: 24, color: Colors.white12),
                      Column(
                        children: [
                          const Text('MỤC TIÊU', style: TextStyle(color: Colors.white54, fontSize: 10, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 2),
                          Text(
                            '${streamService.targetFps} FPS',
                            style: const TextStyle(color: Color(0xFFFFB800), fontSize: 14, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // =========================================================
            // Minimap Zoom Level Slider (14 to 18)
            // Controls Map Detail on both Simulation Screen & ESP32
            // =========================================================
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF131B26),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF00F0FF).withAlpha(100)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.zoom_in_rounded, color: Color(0xFF00F0FF), size: 20),
                          SizedBox(width: 8),
                          Text(
                            'TỶ LỆ PHÓNG TO MINIMAP',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ],
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFF00F0FF).withAlpha(30),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFF00F0FF)),
                        ),
                        child: Text(
                          'Zoom x${streamService.minimapZoom}',
                          style: const TextStyle(
                            color: Color(0xFF00F0FF),
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    streamService.minimapZoom >= 17
                        ? 'Độ chi tiết cao: Hiển thị toà nhà, khu dân cư, số nhà & POI (khớp ảnh chụp)'
                        : 'Toàn cảnh: Hiển thị trục đường chính và các góc rẽ',
                    style: TextStyle(
                      color: streamService.minimapZoom >= 17 ? const Color(0xFF05FFA1) : Colors.white60,
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: const Color(0xFF00F0FF),
                      inactiveTrackColor: Colors.white12,
                      thumbColor: const Color(0xFF00F0FF),
                      overlayColor: const Color(0xFF00F0FF).withAlpha(40),
                      trackHeight: 6,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
                    ),
                    child: Slider(
                      value: streamService.minimapZoom.toDouble(),
                      min: 14.0,
                      max: 18.0,
                      divisions: 4,
                      onChanged: (val) {
                        streamService.minimapZoom = val.round();
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
            ),
            const SizedBox(height: 16),

            // =========================================================
            // 1. EXACT 100% REPLICA OF TARGET DESIGN (320x240 Aspect)
            // =========================================================
            Center(
              child: Container(
                width: 350,
                height: 235,
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFF202A36), width: 5),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha(240),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Column(
                  children: [
                    // Top Status Bar: ESP32 BLE (Cyan) | Time (White) | 100% (Green)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      child: Row(
                        children: [
                          // 1/6: * ysiduc
                          Expanded(
                            flex: 1,
                            child: Row(
                              children: [
                                Icon(
                                  bleService.isConnected ? Icons.bluetooth_connected : Icons.bluetooth,
                                  color: const Color(0xFF00F0FF),
                                  size: 11,
                                ),
                                const SizedBox(width: 2),
                                const Text(
                                  '* ysiduc',
                                  style: TextStyle(
                                    color: Color(0xFF00F0FF),
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),

                          // 3/6: Marquee / Current Track Title & Artist
                          Expanded(
                            flex: 3,
                            child: Center(
                              child: Text(
                                mediaService.hasMedia
                                    ? '♫ ${mediaService.songTitle}${mediaService.songArtist.isNotEmpty ? " - ${mediaService.songArtist}" : ""}'
                                    : '-- Chưa phát nhạc --',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: mediaService.hasMedia ? const Color(0xFFFBBF24) : Colors.white38,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),

                          // 1/6: Current Clock
                          Expanded(
                            flex: 1,
                            child: Center(
                              child: Text(
                                _getCurrentClock(),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),

                          // 1/6: Battery & Icon
                          const Expanded(
                            flex: 1,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                Text(
                                  '89%',
                                  style: TextStyle(
                                    color: Color(0xFF05FFA1),
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                SizedBox(width: 2),
                                Icon(Icons.battery_5_bar_rounded, color: Color(0xFF05FFA1), size: 12),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),

                    // Main Split Screen Body (50% Map Zoom x16 | 50% HUD Cards)
                    Expanded(
                      child: isCallActive
                          ? _buildCallPopup(activeCallerName, activeCallerNum)
                          : isSmsActive
                              ? _buildSmsPopup(activeSmsSender, activeSmsMsg)
                              : _buildSplitView(navManager, streamService, userLoc),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 14),

            // Goong Map / MapTiler Minimap Style Switcher
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF131B26),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFF00F0FF).withAlpha(60)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.layers_rounded, color: Color(0xFF00F0FF), size: 18),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'BẢN ĐỒ MINIMAP ESP32',
                          style: TextStyle(color: Color(0xFF00F0FF), fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Nguồn map & style gửi sang ESP32',
                          style: TextStyle(color: Colors.white54, fontSize: 10),
                        ),
                      ],
                    ),
                  ),
                  DropdownButton<String>(
                    value: streamService.streamMapStyle,
                    dropdownColor: const Color(0xFF1E293B),
                    underline: const SizedBox(),
                    icon: const Icon(Icons.arrow_drop_down, color: Color(0xFF00F0FF)),
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                    items: const [
                      DropdownMenuItem(value: 'goong-streets', child: Text('Goong Map VN (Mặc định)')),
                      DropdownMenuItem(value: 'goong-dark', child: Text('Goong Map Dark')),
                      DropdownMenuItem(value: 'streets-v2', child: Text('MapTiler Streets')),
                      DropdownMenuItem(value: 'streets-v2-dark', child: Text('MapTiler Dark')),
                      DropdownMenuItem(value: 'hybrid', child: Text('Hybrid (Vệ tinh)')),
                    ],
                    onChanged: (val) {
                      if (val != null) {
                        setState(() {
                          streamService.streamMapStyle = val;
                        });
                      }
                    },
                  ),
                ],
              ),
            ),

            const SizedBox(height: 14),

            // Music & Standby Control
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF131B26),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF00F0FF).withAlpha(60)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.music_note_rounded, color: Color(0xFF00F0FF), size: 16),
                          SizedBox(width: 6),
                          Text(
                            'ĐIỀU KHIỂN NHẠC & CHẾ ĐỘ MÀN HÌNH',
                            style: TextStyle(color: Color(0xFF00F0FF), fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: navManager.isNavigating ? const Color(0xFF00F0FF).withAlpha(30) : const Color(0xFF05FFA1).withAlpha(30),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: navManager.isNavigating ? const Color(0xFF00F0FF) : const Color(0xFF05FFA1)),
                        ),
                        child: Text(
                          navManager.isNavigating ? 'DẪN ĐƯỜNG' : 'CHẾ ĐỘ CHỜ',
                          style: TextStyle(
                            color: navManager.isNavigating ? const Color(0xFF00F0FF) : const Color(0xFF05FFA1),
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  // Real-time iOS Now Playing Detection Status Banner
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0B111A),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: mediaService.hasMedia ? const Color(0xFF05FFA1).withAlpha(140) : Colors.white12,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          mediaService.hasMedia ? Icons.graphic_eq_rounded : Icons.music_off_rounded,
                          color: mediaService.hasMedia ? const Color(0xFF05FFA1) : Colors.white38,
                          size: 20,
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                mediaService.hasMedia ? 'PHÁT HIỆN TỪ IPHONE (REAL-TIME)' : 'CHƯA PHÁT NHẠC TRÊN IPHONE',
                                style: TextStyle(
                                  color: mediaService.hasMedia ? const Color(0xFF05FFA1) : Colors.white38,
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                mediaService.hasMedia
                                    ? '${mediaService.songTitle} - ${mediaService.songArtist}'
                                    : 'Mở Spotify, Apple Music, YouTube hoặc Zing MP3...',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: mediaService.hasMedia ? Colors.white : Colors.white54,
                                  fontSize: 12,
                                  fontWeight: mediaService.hasMedia ? FontWeight.bold : FontWeight.normal,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      ActionChip(
                        avatar: const Icon(Icons.refresh_rounded, size: 14, color: Color(0xFF00F0FF)),
                        backgroundColor: const Color(0xFF00F0FF).withAlpha(25),
                        side: const BorderSide(color: Color(0xFF00F0FF)),
                        label: const Text('Lấy lại nhạc iPhone', style: TextStyle(color: Color(0xFF00F0FF), fontSize: 11, fontWeight: FontWeight.bold)),
                        onPressed: () => mediaService.pollNowPlaying(),
                      ),
                      ActionChip(
                        backgroundColor: const Color(0xFF0E1520),
                        side: const BorderSide(color: Color(0xFF1E293B)),
                        label: const Text('Simulate: Waiting For You', style: TextStyle(color: Colors.white70, fontSize: 11)),
                        onPressed: () => mediaService.setMockSong('Waiting For You', 'MONO'),
                      ),
                      ActionChip(
                        backgroundColor: const Color(0xFF0E1520),
                        side: const BorderSide(color: Color(0xFF1E293B)),
                        label: const Text('Simulate: Nơi Này Có Anh', style: TextStyle(color: Colors.white70, fontSize: 11)),
                        onPressed: () => mediaService.setMockSong('Noi Nay Co Anh', 'Son Tung M-TP'),
                      ),
                      ActionChip(
                        avatar: const Icon(Icons.edit, size: 14, color: Color(0xFF00F0FF)),
                        backgroundColor: const Color(0xFF0E1520),
                        side: const BorderSide(color: Color(0xFF1E293B)),
                        label: const Text('Nhập tùy ý...', style: TextStyle(color: Colors.white70, fontSize: 11)),
                        onPressed: () => _showEditSongDialog(context, navManager),
                      ),
                    ],
                  ),
                  if (navManager.isNavigating) ...[
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.redAccent,
                          side: const BorderSide(color: Colors.redAccent),
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        icon: const Icon(Icons.stop_rounded, size: 16),
                        label: const Text('Dừng dẫn đường (Về chế độ chờ)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                        onPressed: () => navManager.stopNavigation(),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 14),

            // -------------------------------------------------------------
            // CÀI ĐẶT ẢNH NỀN ESP32 (LƯU VĨNH VIỄN VÀO FLASH SPIFFS)
            // -------------------------------------------------------------
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF131B26),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF00F0FF).withAlpha(80)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.photo_library_rounded, color: Color(0xFF00F0FF), size: 20),
                      SizedBox(width: 8),
                      Text(
                        'CÀI ĐẶT HÌNH NỀN TÙY CHỌN (FLASH ESP32)',
                        style: TextStyle(color: Color(0xFF00F0FF), fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Ảnh được nạp và lưu vĩnh viễn vào bộ nhớ Flash SPIFFS của ESP32 đến khi bạn thay mới.',
                    style: TextStyle(color: Colors.white60, fontSize: 11),
                  ),
                  const SizedBox(height: 12),

                  if (_isUploadingBg) ...[
                    Container(
                      padding: const EdgeInsets.all(10),
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F172A),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFF00F0FF)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(_uploadStatusText, style: const TextStyle(color: Color(0xFF05FFA1), fontSize: 12, fontWeight: FontWeight.bold)),
                              Text('${(_uploadProgress * 100).toInt()}%', style: const TextStyle(color: Color(0xFF00F0FF), fontWeight: FontWeight.bold)),
                            ],
                          ),
                          const SizedBox(height: 8),
                          LinearProgressIndicator(
                            value: _uploadProgress,
                            backgroundColor: Colors.white12,
                            valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF00F0FF)),
                          ),
                        ],
                      ),
                    ),
                  ],

                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 1. Ảnh Ngang Màn Chờ (320x240)
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0B111A),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.white12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              const Text('Ảnh Ngang (Màn Chờ)', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                              const SizedBox(height: 2),
                              const Text('320 x 240 px', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 10)),
                              const SizedBox(height: 8),
                              AspectRatio(
                                aspectRatio: 320 / 240,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.black26,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: Colors.white24),
                                  ),
                                  child: _waitImagePreview != null
                                      ? ClipRRect(
                                          borderRadius: BorderRadius.circular(7),
                                          child: Image.memory(_waitImagePreview!, fit: BoxFit.cover),
                                        )
                                      : const Column(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            Icon(Icons.wallpaper_rounded, color: Colors.white38, size: 28),
                                            SizedBox(height: 4),
                                            Text('Màn chờ kết nối', style: TextStyle(color: Colors.white38, fontSize: 9)),
                                          ],
                                        ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF00F0FF),
                                    foregroundColor: Colors.black,
                                    padding: const EdgeInsets.symmetric(vertical: 8),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  ),
                                  icon: const Icon(Icons.file_upload_outlined, size: 16),
                                  label: const Text('Chọn ảnh', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                  onPressed: _isUploadingBg ? null : () => _pickAndUploadImage(isWaitScreen: true),
                                ),
                              ),
                              TextButton(
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(vertical: 4),
                                  visualDensity: VisualDensity.compact,
                                ),
                                onPressed: _isUploadingBg ? null : () => _deleteBgImage(isWaitScreen: true),
                                child: const Text('Xóa / Mặc định', style: TextStyle(color: Colors.redAccent, fontSize: 10)),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),

                      // 2. Ảnh Dọc Màn Map Chờ (144x208)
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0B111A),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.white12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              const Text('Ảnh Dọc (Màn Map)', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                              const SizedBox(height: 2),
                              const Text('144 x 208 px', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 10)),
                              const SizedBox(height: 8),
                              AspectRatio(
                                aspectRatio: 144 / 208,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.black26,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: Colors.white24),
                                  ),
                                  child: _mapImagePreview != null
                                      ? ClipRRect(
                                          borderRadius: BorderRadius.circular(7),
                                          child: Image.memory(_mapImagePreview!, fit: BoxFit.cover),
                                        )
                                      : const Column(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            Icon(Icons.map_outlined, color: Colors.white38, size: 28),
                                            SizedBox(height: 4),
                                            Text('Chờ xuất phát', style: TextStyle(color: Colors.white38, fontSize: 9)),
                                          ],
                                        ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF05FFA1),
                                    foregroundColor: Colors.black,
                                    padding: const EdgeInsets.symmetric(vertical: 8),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  ),
                                  icon: const Icon(Icons.file_upload_outlined, size: 16),
                                  label: const Text('Chọn ảnh', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                  onPressed: _isUploadingBg ? null : () => _pickAndUploadImage(isWaitScreen: false),
                                ),
                              ),
                              TextButton(
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(vertical: 4),
                                  visualDensity: VisualDensity.compact,
                                ),
                                onPressed: _isUploadingBg ? null : () => _deleteBgImage(isWaitScreen: false),
                                child: const Text('Xóa / Mặc định', style: TextStyle(color: Colors.redAccent, fontSize: 10)),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // -------------------------------------------------------------
            // THÔNG BÁO CUỘC GỌI & TIN NHẮN (ANCS)
            // -------------------------------------------------------------
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF131B26),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.notifications_active_rounded, color: Color(0xFFFFB800), size: 20),
                      SizedBox(width: 8),
                      Text(
                        'THÔNG BÁO CUỘC GỌI & TIN NHẮN (ANCS)',
                        style: TextStyle(color: Color(0xFFFFB800), fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // ANCS Setup Guide
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F1B2A),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFF00F0FF).withAlpha(80)),
                    ),
                    child: const Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline_rounded, color: Color(0xFF00F0FF), size: 18),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Để iPhone tự động gửi tên người gọi & tin nhắn thật đến ESP32:\n'
                            '1. Mở Cài đặt iPhone ➔ Bluetooth\n'
                            '2. Bấm chữ (i) bên cạnh "ESP32-S3 Navi"\n'
                            '3. BẬT mục "Chia sẻ thông báo hệ thống" (Share System Notifications).',
                            style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11, height: 1.4),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Call Controls
                  Row(
                    children: [
                      Expanded(
                        flex: 5,
                        child: TextField(
                          controller: _callerNameCtrl,
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                          decoration: const InputDecoration(
                            isDense: true,
                            labelText: 'Tên người gọi',
                            labelStyle: TextStyle(color: Color(0xFF05FFA1), fontSize: 11),
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 4,
                        child: TextField(
                          controller: _callerNumCtrl,
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                          decoration: const InputDecoration(
                            isDense: true,
                            labelText: 'Số điện thoại',
                            labelStyle: TextStyle(color: Color(0xFF05FFA1), fontSize: 11),
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF05FFA1).withAlpha(40),
                            foregroundColor: const Color(0xFF05FFA1),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            side: const BorderSide(color: Color(0xFF05FFA1)),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          icon: const Icon(Icons.phone_in_talk_rounded, size: 16),
                          label: const Text('Thử gọi đến', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                          onPressed: () => _triggerCall(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.redAccent,
                          side: const BorderSide(color: Colors.redAccent),
                          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        icon: const Icon(Icons.call_end_rounded, size: 16),
                        label: const Text('Tắt máy', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                        onPressed: _dismissCall,
                      ),
                    ],
                  ),

                  const Divider(color: Colors.white12, height: 20),

                  // SMS Controls
                  Row(
                    children: [
                      Expanded(
                        flex: 4,
                        child: TextField(
                          controller: _smsSenderCtrl,
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                          decoration: const InputDecoration(
                            isDense: true,
                            labelText: 'Người gửi SMS/Zalo',
                            labelStyle: TextStyle(color: Color(0xFFFFB800), fontSize: 11),
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 5,
                        child: TextField(
                          controller: _smsMsgCtrl,
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                          decoration: const InputDecoration(
                            isDense: true,
                            labelText: 'Nội dung tin nhắn',
                            labelStyle: TextStyle(color: Color(0xFFFFB800), fontSize: 11),
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFFB800).withAlpha(40),
                        foregroundColor: const Color(0xFFFFB800),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        side: const BorderSide(color: Color(0xFFFFB800)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      icon: const Icon(Icons.mark_chat_unread_rounded, size: 16),
                      label: const Text('Thử gửi tin nhắn SMS sang ESP32', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                      onPressed: () => _triggerSms(),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showEditSongDialog(BuildContext context, NavigationManager navManager) {
    final titleCtrl = TextEditingController(text: navManager.currentSongTitle);
    final artistCtrl = TextEditingController(text: navManager.currentSongArtist);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF131B26),
        title: const Text('Đổi bài hát đang phát', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleCtrl,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Tên bài hát',
                labelStyle: TextStyle(color: Color(0xFF00F0FF)),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF00F0FF))),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: artistCtrl,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Tên ca sĩ / nghệ sĩ',
                labelStyle: TextStyle(color: Color(0xFF00F0FF)),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF00F0FF))),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Hủy', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00F0FF),
              foregroundColor: Colors.black,
            ),
            onPressed: () {
              if (titleCtrl.text.trim().isNotEmpty) {
                navManager.setSong(titleCtrl.text.trim(), artistCtrl.text.trim());
              }
              Navigator.pop(ctx);
            },
            child: const Text('Cập nhật', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  String _getCurrentClock() {
    final now = DateTime.now();
    final h = now.hour.toString().padLeft(2, '0');
    final m = now.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  /// Split View: Left 50% Live Streamed Map (100% Mirror of ESP32) | Right 50% Standby Dashboard or Nav HUD
  Widget _buildSplitView(NavigationManager navManager, EspStreamService streamService, LatLng userLoc) {
    return Row(
      children: [
        // -----------------------------------------------------------------
        // LEFT 50%: EXACT 1:1 REAL-TIME ESP32 LIVE STREAM (144x208)
        // -----------------------------------------------------------------
        Expanded(
          flex: 1,
          child: Container(
            margin: const EdgeInsets.only(right: 5),
            decoration: BoxDecoration(
              color: const Color(0xFF0B111A),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF00F0FF), width: 1.5),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: ValueListenableBuilder<Uint8List?>(
                valueListenable: streamService.latestFrameNotifier,
                builder: (context, frameBytes, _) {
                  if (frameBytes != null) {
                    return Image.memory(
                      frameBytes,
                      fit: BoxFit.fill,
                      gaplessPlayback: true,
                    );
                  }
                  if (_mapImagePreview != null) {
                    return Image.memory(
                      _mapImagePreview!,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                    );
                  }
                  return CustomPaint(
                    painter: StandbyVectorMapPainter(navManager: navManager),
                    size: const Size(144, 208),
                  );
                },
              ),
            ),
          ),
        ),

        // -----------------------------------------------------------------
        // RIGHT 50%: HUD NAVIGATION CARDS OR STANDBY MUSIC / CLOCK DASHBOARD
        // -----------------------------------------------------------------
        Expanded(
          flex: 1,
          child: Container(
            margin: const EdgeInsets.only(left: 5),
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: const Color(0xFF131B26),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF202D3D), width: 1.2),
            ),
            child: !navManager.isNavigating
                ? _buildStandbyDashboard(navManager)
                : _buildNavigationHud(navManager),
          ),
        ),
      ],
    );
  }

  /// Standby Dashboard (Idle Mode): Clock, ysiduc, Current Song & Artist, Equalizer
  Widget _buildStandbyDashboard(NavigationManager navManager) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // 1. Large Elegant Digital Clock
        Text(
          _getCurrentClock(),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 26,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.0,
            height: 1.0,
          ),
        ),

        // 2. Driver / Branding Tag: * ysiduc
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: const Color(0xFF0E1520),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: const Color(0xFF0084FF), width: 1.2),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.bluetooth, color: Color(0xFF00F0FF), size: 12),
              SizedBox(width: 4),
              Text(
                'ysiduc',
                style: TextStyle(
                  color: Color(0xFF00F0FF),
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),

        // 3. Media / Music Player Card
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFF0B111A),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF1E293B)),
          ),
          child: Builder(
            builder: (context) {
              final hasSong = navManager.currentSongTitle.isNotEmpty && navManager.currentSongTitle != 'CHUA PHAT NHAC';
              return Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        hasSong ? Icons.play_arrow_rounded : Icons.headphones_rounded,
                        color: hasSong ? const Color(0xFFFFB800) : Colors.white38,
                        size: 13,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        hasSong ? 'ĐANG PHÁT' : 'CHƯA PHÁT NHẠC',
                        style: TextStyle(
                          color: hasSong ? const Color(0xFFFFB800) : Colors.white38,
                          fontSize: 9,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    (hasSong ? navManager.currentSongTitle : 'MỞ NHẠC TRÊN IPHONE').toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: hasSong ? Colors.white : Colors.white54,
                      fontSize: 9.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    (hasSong ? navManager.currentSongArtist : 'SPOTIFY / APPLE MUSIC').toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFF94A3B8),
                      fontSize: 8.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 5),
                  // Audio Sound Equalizer visualizer bars
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: (hasSong
                            ? [4, 10, 16, 12, 6, 14, 18, 8, 12, 6]
                            : [2, 2, 2, 2, 2, 2, 2, 2, 2, 2])
                        .map((h) => Container(
                              width: 3.5,
                              height: h.toDouble(),
                              margin: const EdgeInsets.symmetric(horizontal: 1.5),
                              decoration: BoxDecoration(
                                color: hasSong ? const Color(0xFF00F0FF) : const Color(0xFF1E293B),
                                borderRadius: BorderRadius.circular(1.5),
                              ),
                            ))
                        .toList(),
                  ),
                ],
              );
            },
          ),
        ),

        // 4. Bottom Standby Status
        const Text(
          'SẴN SÀNG DI CHUYỂN',
          style: TextStyle(
            color: Color(0xFF05FFA1),
            fontSize: 10,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }

  /// Active Navigation Turn Maneuver HUD
  Widget _buildNavigationHud(NavigationManager navManager) {
    final step = navManager.currentStep;
    final dist = navManager.distanceToNextManeuver.round() > 0 ? navManager.distanceToNextManeuver.round() : 208;
    final distStr = dist >= 1000 ? '${(dist / 1000).toStringAsFixed(1)}km' : '${dist}m';
    final street = step?.streetName.isNotEmpty == true ? step!.streetName : 'CẦU SÔNG LỪ';
    final speed = navManager.currentSpeedKmh.round();
    final etaMins = navManager.isNavigating
        ? (navManager.remainingEtaMinutes > 0 ? navManager.remainingEtaMinutes : 1)
        : (navManager.remainingEtaMinutes > 0 ? navManager.remainingEtaMinutes : 11);
    final totalDistKm = navManager.remainingTotalDistance > 0
        ? (navManager.remainingTotalDistance >= 1000
            ? '${(navManager.remainingTotalDistance / 1000).toStringAsFixed(1)} km'
            : '${navManager.remainingTotalDistance.round()} m')
        : (navManager.isNavigating ? '0 m' : '5.9 km');

    final arrivalTime = DateTime.now().add(Duration(minutes: etaMins));
    final arrivalClock = '${arrivalTime.hour.toString().padLeft(2, '0')}:${arrivalTime.minute.toString().padLeft(2, '0')}';

    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // Top Row: Maneuver Icon + Distance + Speed
        Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: const Color(0xFF0E1520),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF00F0FF), width: 1.8),
              ),
              child: Icon(
                _getTurnIcon(step?.turnCode ?? 6),
                color: const Color(0xFF00F0FF),
                size: 28,
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    distStr,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      height: 1.1,
                    ),
                  ),
                  Text(
                    '$speed km/h',
                    style: const TextStyle(
                      color: Color(0xFF00F0FF),
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),

        // Middle Row: Upcoming Street Name Pill
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          decoration: BoxDecoration(
            color: const Color(0xFF0B111A),
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: const Color(0xFF1E293B)),
          ),
          child: Text(
            street.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.left,
            style: const TextStyle(
              color: Color(0xFFFFB800),
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),

        // Bottom Row: ETA & Distance
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'DỰ KIẾN',
                  style: TextStyle(color: Color(0xFF64748B), fontSize: 8, fontWeight: FontWeight.bold),
                ),
                Text(
                  arrivalClock,
                  style: const TextStyle(
                    color: Color(0xFF00F0FF),
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  totalDistKm,
                  style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 10, fontWeight: FontWeight.w600),
                ),
                Text(
                  etaMins >= 60
                      ? '${etaMins ~/ 60}h${(etaMins % 60).toString().padLeft(2, '0')}'
                      : '$etaMins ph',
                  style: const TextStyle(
                    color: Color(0xFF05FFA1),
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildCallPopup(String name, String number) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF022C22),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF05FFA1), width: 1.5),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.phone_in_talk_rounded, color: Color(0xFF05FFA1), size: 30),
          const SizedBox(height: 4),
          const Text('CUỘC GỌI ĐẾN', style: TextStyle(color: Color(0xFF05FFA1), fontSize: 11, fontWeight: FontWeight.bold)),
          const SizedBox(height: 2),
          Text(name, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis),
          if (number.isNotEmpty && number != 'unknown')
            Text(number, style: const TextStyle(color: Color(0xFF05FFA1), fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _buildSmsPopup(String sender, String content) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0B192C),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF00F0FF), width: 1.5),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.mark_chat_unread_rounded, color: Color(0xFF00F0FF), size: 28),
          const SizedBox(height: 4),
          Text(sender, style: const TextStyle(color: Color(0xFFFFB800), fontSize: 15, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 2),
          Text(content, style: const TextStyle(color: Colors.white, fontSize: 11), textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }

  IconData _getTurnIcon(int turnCode) {
    switch (turnCode) {
      case 1:
      case 2:
      case 3:
        return Icons.turn_right_rounded;
      case 4:
        return Icons.u_turn_left_rounded;
      case 5:
      case 6:
      case 7:
        return Icons.turn_left_rounded;
      case 8:
        return Icons.roundabout_right_rounded;
      case 9:
        return Icons.flag_rounded;
      default:
        return Icons.straight_rounded;
    }
  }

  Widget _buildZoomPresetChip(EspStreamService streamService, int zoomVal, String label) {
    final isSelected = streamService.minimapZoom == zoomVal;
    return InkWell(
      onTap: () {
        streamService.minimapZoom = zoomVal;
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF00F0FF) : const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: isSelected ? const Color(0xFF00F0FF) : Colors.white10),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.black : Colors.white70,
            fontSize: 10,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

class StandbyVectorMapPainter extends CustomPainter {
  final NavigationManager navManager;
  StandbyVectorMapPainter({required this.navManager});

  void _drawCasedRoad(Canvas canvas, Offset p1, Offset p2, double roadWidth, double borderWidth, Color asphalt, Color border) {
    canvas.drawLine(
      p1,
      p2,
      Paint()
        ..color = border
        ..strokeWidth = roadWidth + borderWidth * 2
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawLine(
      p1,
      p2,
      Paint()
        ..color = asphalt
        ..strokeWidth = roadWidth
        ..strokeCap = StrokeCap.round,
    );
  }

  void _drawRouteLine(Canvas canvas, Offset p1, Offset p2, Color glow, Color active) {
    canvas.drawLine(
      p1,
      p2,
      Paint()
        ..color = glow
        ..strokeWidth = 6.0
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawLine(
      p1,
      p2,
      Paint()
        ..color = active
        ..strokeWidth = 4.0
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawLine(
      p1,
      p2,
      Paint()
        ..color = Colors.white
        ..strokeWidth = 1.2
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final cx = w / 2.0;

    // 1. Color Palette: Garmin / Apple Maps HUD Dark Slate Navy
    const cMapBg       = Color(0xFF0B111A);
    const cRadarRing   = Color(0xFF142030);
    const cRadarText   = Color(0xFF3C5069);
    const cAsphaltBed  = Color(0xFF1C2636);
    const cRoadBorder  = Color(0xFF374B64);
    const cRouteGlow   = Color(0xFF0078B4);
    const cRouteActive = Color(0xFF00F0FF);
    const cYellowBadge = Color(0xFFFACC15);

    // Background Card
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, w, h), const Radius.circular(10)),
      Paint()..color = cMapBg,
    );

    final isNav = navManager.isNavigating;

    if (isNav) {
      // -----------------------------------------------------------------------
      // ACTIVE NAVIGATION MODE: Real Route Geometry, Actual Turn & Road Corridor
      // -----------------------------------------------------------------------
      final cy = h * 0.72; // Vehicle anchor position at lower 1/3 (matching ESP32 cy=175)

      // 2. Concentric Distance Range Rings (50m, 100m)
      final ringPaint = Paint()
        ..color = cRadarRing
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0;
      canvas.drawCircle(Offset(cx, cy), 38.0, ringPaint);
      canvas.drawCircle(Offset(cx, cy), 74.0, ringPaint);
      canvas.drawCircle(Offset(cx, cy), 110.0, ringPaint);
      canvas.drawLine(Offset(cx - 65, cy), Offset(cx + 65, cy), ringPaint);
      canvas.drawLine(Offset(cx, 12), Offset(cx, h - 12), ringPaint);

      final r50Tp = TextPainter(
        text: const TextSpan(text: '50m', style: TextStyle(color: cRadarText, fontSize: 8)),
        textDirection: TextDirection.ltr,
      )..layout();
      r50Tp.paint(canvas, Offset(cx + 41, cy - 8));

      final r100Tp = TextPainter(
        text: const TextSpan(text: '100m', style: TextStyle(color: cRadarText, fontSize: 8)),
        textDirection: TextDirection.ltr,
      )..layout();
      r100Tp.paint(canvas, Offset(cx + 77, cy - 8));

      final upcomingPts = navManager.computeUpcomingRoutePoints();

      if (upcomingPts.length >= 2) {
        // Collect points clamped to canvas
        final pts = <Offset>[];
        pts.add(Offset(cx, cy));

        for (int i = 1; i < upcomingPts.length; i++) {
          if (upcomingPts[i][1] < -5) continue;
          final px = (cx + upcomingPts[i][0]).clamp(8.0, w - 8.0);
          final py = (cy - upcomingPts[i][1]).clamp(12.0, h - 8.0);
          pts.add(Offset(px, py));
        }

        if (pts.length >= 2) {
          // Road behind vehicle extending to bottom
          _drawCasedRoad(canvas, Offset(cx, cy), Offset(cx, h - 4), 12.0, 2.0, cAsphaltBed, cRoadBorder);

          // Pass 1 & 2: Cased Asphalt Road Bed along actual route
          for (int i = 1; i < pts.length; i++) {
            _drawCasedRoad(canvas, pts[i - 1], pts[i], 12.0, 2.0, cAsphaltBed, cRoadBorder);
          }

          // Pass 3: Detect upcoming turn intersection & draw Cross Street
          int turnIdx = 1;
          double maxDeflection = 0;
          for (int i = 1; i < pts.length - 1; i++) {
            if (cy - pts[i].dy < 16) continue; // Must be ahead of vehicle
            final v1x = pts[i].dx - pts[i - 1].dx;
            final v1y = pts[i].dy - pts[i - 1].dy;
            final v2x = pts[i + 1].dx - pts[i].dx;
            final v2y = pts[i + 1].dy - pts[i].dy;
            final cross = (v1x * v2y - v1y * v2x).abs();
            if (cross > 80) {
              turnIdx = i;
              break;
            }
            if (cross > maxDeflection) {
              maxDeflection = cross;
              turnIdx = i;
            }
          }

          if (cy - pts[turnIdx].dy < 16 && pts.length > 2) {
            turnIdx = pts.length ~/ 2;
          }

          final tx = pts[turnIdx].dx;
          final ty = pts[turnIdx].dy;

          // Draw cross street crossing through the intersection
          _drawCasedRoad(
            canvas,
            Offset((tx - 36).clamp(8.0, w - 8.0), ty),
            Offset((tx + 36).clamp(8.0, w - 8.0), ty),
            10.0,
            2.0,
            cAsphaltBed,
            cRoadBorder,
          );

          // Pass 4: Glowing Neon Navigation Route Core
          for (int i = 1; i < pts.length; i++) {
            _drawRouteLine(canvas, pts[i - 1], pts[i], cRouteGlow, cRouteActive);
          }

          // Pass 5: Direction Chevrons along route segments
          for (int i = 1; i < pts.length; i++) {
            final mx = (pts[i - 1].dx + pts[i].dx) / 2;
            final my = (pts[i - 1].dy + pts[i].dy) / 2;
            final dx = pts[i].dx - pts[i - 1].dx;
            final dy = pts[i].dy - pts[i - 1].dy;
            final chPath = Path();
            if (dy.abs() > dx.abs()) {
              if (dy < -6) {
                // Going UP
                chPath
                  ..moveTo(mx, my - 5)
                  ..lineTo(mx - 3, my + 1)
                  ..lineTo(mx + 3, my + 1)
                  ..close();
                canvas.drawPath(chPath, Paint()..color = Colors.white);
              }
            } else {
              if (dx < -6) {
                // Going LEFT
                chPath
                  ..moveTo(mx - 5, my)
                  ..lineTo(mx + 1, my - 3)
                  ..lineTo(mx + 1, my + 3)
                  ..close();
                canvas.drawPath(chPath, Paint()..color = Colors.white);
              } else if (dx > 6) {
                // Going RIGHT
                chPath
                  ..moveTo(mx + 5, my)
                  ..lineTo(mx - 1, my - 3)
                  ..lineTo(mx - 1, my + 3)
                  ..close();
                canvas.drawPath(chPath, Paint()..color = Colors.white);
              }
            }
          }

          // Pass 6: Maneuver Waypoint Node at upcoming turn
          canvas.drawCircle(Offset(tx, ty), 7.0, Paint()..color = cRouteActive..style = PaintingStyle.stroke..strokeWidth = 2.0);
          canvas.drawCircle(Offset(tx, ty), 2.0, Paint()..color = Colors.white);
        }
      } else {
        // Fallback: Dynamic Real Intersection Corridor from turnCode and distMeters
        final dist = navManager.distanceToNextManeuver;
        final turnFactor = (dist.clamp(0.0, 400.0) / 400.0);
        final turnY = (cy - (38.0 + (115.0 - 38.0) * turnFactor)).clamp(24.0, cy - 35.0);

        // A. Main Approach Road Bed
        _drawCasedRoad(canvas, Offset(cx, h - 4), Offset(cx, turnY), 12.0, 2.0, cAsphaltBed, cRoadBorder);

        // B. Cross Street at Intersection
        _drawCasedRoad(canvas, Offset(10, turnY), Offset(w - 10, turnY), 10.0, 2.0, cAsphaltBed, cRoadBorder);

        // C. Straight continuation road past intersection
        _drawCasedRoad(canvas, Offset(cx, turnY), Offset(cx, 16), 8.0, 2.0, cAsphaltBed, cRoadBorder);

        // D. Active Navigation Route
        _drawRouteLine(canvas, Offset(cx, cy), Offset(cx, turnY), cRouteGlow, cRouteActive);

        // Direction arrow along approach
        final midY = (cy + turnY) / 2;
        final fwdArrow = Path()
          ..moveTo(cx, midY - 6)
          ..lineTo(cx - 4, midY + 1)
          ..lineTo(cx + 4, midY + 1)
          ..close();
        canvas.drawPath(fwdArrow, Paint()..color = Colors.white);

        // Turn branch based on turnCode
        final turnCode = navManager.currentStep?.turnCode ?? 0;
        if (turnCode == 5 || turnCode == 6 || turnCode == 7) {
          // TURN LEFT (90 deg turn onto cross street)
          _drawRouteLine(canvas, Offset(cx, turnY), Offset(18, turnY), cRouteGlow, cRouteActive);
          final leftTip = Path()
            ..moveTo(18, turnY)
            ..lineTo(26, turnY - 5)
            ..lineTo(26, turnY + 5)
            ..close();
          canvas.drawPath(leftTip, Paint()..color = Colors.white);

        } else if (turnCode == 1 || turnCode == 2 || turnCode == 3) {
          // TURN RIGHT (90 deg turn onto cross street)
          _drawRouteLine(canvas, Offset(cx, turnY), Offset(w - 18, turnY), cRouteGlow, cRouteActive);
          final rightTip = Path()
            ..moveTo(w - 18, turnY)
            ..lineTo(w - 26, turnY - 5)
            ..lineTo(w - 26, turnY + 5)
            ..close();
          canvas.drawPath(rightTip, Paint()..color = Colors.white);

        } else if (turnCode == 4) {
          // U-TURN
          canvas.drawLine(Offset(cx, turnY), Offset(cx - 22, turnY), Paint()..color = cRouteActive..strokeWidth = 4.0..strokeCap = StrokeCap.round);
          canvas.drawLine(Offset(cx - 22, turnY), Offset(cx - 22, cy - 10), Paint()..color = cRouteActive..strokeWidth = 4.0..strokeCap = StrokeCap.round);

        } else if (turnCode == 8) {
          // ROUNDABOUT
          canvas.drawCircle(Offset(cx, turnY), 14.0, Paint()..color = cRouteActive..style = PaintingStyle.stroke..strokeWidth = 3.0);

        } else {
          // STRAIGHT / KEEP AHEAD
          _drawRouteLine(canvas, Offset(cx, turnY), Offset(cx, 16), cRouteGlow, cRouteActive);
          final straightTip = Path()
            ..moveTo(cx, 18)
            ..lineTo(cx - 4, 25)
            ..lineTo(cx + 4, 25)
            ..close();
          canvas.drawPath(straightTip, Paint()..color = Colors.white);
        }

        // Maneuver Waypoint Node at Intersection
        canvas.drawCircle(Offset(cx, turnY), 7.0, Paint()..color = cRouteActive..style = PaintingStyle.stroke..strokeWidth = 2.0);
        canvas.drawCircle(Offset(cx, turnY), 2.0, Paint()..color = Colors.white);
      }

      // 4. Vehicle Navigation Location Puck (at cx, cy pointing straight UP)
      canvas.drawCircle(Offset(cx, cy), 14.0, Paint()..color = const Color(0xFF003250));
      canvas.drawCircle(Offset(cx, cy), 8.0, Paint()..color = cRouteActive);
      canvas.drawCircle(Offset(cx, cy), 8.0, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 1.5);
      canvas.drawCircle(Offset(cx, cy), 3.0, Paint()..color = Colors.cyanAccent);

      // Aerodynamic forward arrow tip pointing UP
      final puckTip = Path()
        ..moveTo(cx, cy - 10)
        ..lineTo(cx - 4, cy - 3)
        ..lineTo(cx + 4, cy - 3)
        ..close();
      canvas.drawPath(puckTip, Paint()..color = Colors.white);

      // 5. Bottom-Left Turn Distance Badge (e.g. "205m" in yellow)
      final distM = navManager.distanceToNextManeuver.round();
      final distStr = distM >= 1000 ? '${(distM / 1000.0).toStringAsFixed(1)}km' : '${distM}m';
      final badgeTp = TextPainter(
        text: TextSpan(
          text: distStr,
          style: const TextStyle(color: cYellowBadge, fontSize: 13, fontWeight: FontWeight.bold),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      badgeTp.paint(canvas, Offset(12, h - 22));

    } else {
      // -----------------------------------------------------------------------
      // STANDBY / IDLE MODE: Clean Crossroad Intersection & Center Location Puck
      // -----------------------------------------------------------------------
      final cy = h * 0.55;

      // Range rings
      final ringPaint = Paint()
        ..color = cRadarRing
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0;
      canvas.drawCircle(Offset(cx, cy), 45.0, ringPaint);
      canvas.drawCircle(Offset(cx, cy), 85.0, ringPaint);

      // North-South Central Road
      _drawCasedRoad(canvas, Offset(cx, h - 6), Offset(cx, 6), 12.0, 2.0, cAsphaltBed, cRoadBorder);

      // East-West Crossroad
      _drawCasedRoad(canvas, Offset(6, cy), Offset(w - 6, cy), 12.0, 2.0, cAsphaltBed, cRoadBorder);

      // Standby Location Puck
      canvas.drawCircle(Offset(cx, cy), 12.0, Paint()..color = const Color(0xFF003250));
      canvas.drawCircle(Offset(cx, cy), 7.0, Paint()..color = cRouteActive);
      canvas.drawCircle(Offset(cx, cy), 7.0, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 1.5);

      final standbyTip = Path()
        ..moveTo(cx, cy - 9)
        ..lineTo(cx - 4, cy - 2)
        ..lineTo(cx + 4, cy - 2)
        ..close();
      canvas.drawPath(standbyTip, Paint()..color = Colors.white);

      final standbyTp = TextPainter(
        text: const TextSpan(
          text: 'CHẾ ĐỘ CHỜ',
          style: TextStyle(color: cRadarText, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 1.2),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      standbyTp.paint(canvas, Offset(cx - standbyTp.width / 2, h - 22));
    }

    // -------------------------------------------------------------------------
    // MINIMALIST OVERLAYS (No bulky pills, keeping entire map unobstructed)
    // -------------------------------------------------------------------------
    // Top-Left: Minimalist Compass North Indicator
    final compassTp = TextPainter(
      text: const TextSpan(
        text: 'N ▲',
        style: TextStyle(color: cRouteActive, fontSize: 10, fontWeight: FontWeight.bold),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    compassTp.paint(canvas, const Offset(10, 8));

    // Top-Right: Live GPS Status Dot
    canvas.drawCircle(
      Offset(w - 14, 14),
      3.5,
      Paint()..color = isNav ? const Color(0xFF22C55E) : cRouteActive,
    );

    // Bottom-Right: Subtle Map Scale Bar
    final scaleTp = TextPainter(
      text: const TextSpan(
        text: '50m ──',
        style: TextStyle(color: cRadarText, fontSize: 8, fontWeight: FontWeight.w600),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    scaleTp.paint(canvas, Offset(w - 44, h - 16));
  }

  @override
  bool shouldRepaint(covariant StandbyVectorMapPainter oldDelegate) => true;
}
