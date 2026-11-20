import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/ble_service.dart';
import '../services/esp_stream_service.dart';
import '../services/firmware_ota_service.dart';

/// Shows the iOS/Android modal sheet for updating ESP32-S3 firmware from a `.zip` file.
Future<void> showFirmwareUpdateSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    backgroundColor: Colors.transparent,
    builder: (_) => const FirmwareUpdateSheet(),
  );
}

class FirmwareUpdateSheet extends StatefulWidget {
  const FirmwareUpdateSheet({super.key});

  @override
  State<FirmwareUpdateSheet> createState() => _FirmwareUpdateSheetState();
}

class _FirmwareUpdateSheetState extends State<FirmwareUpdateSheet> {
  static const Color _bgColor = Color(0xFFF2F2F7);
  static const Color _cardColor = Color(0xFFFFFFFF);
  static const Color _primaryBlue = Color(0xFF007AFF);
  static const Color _successGreen = Color(0xFF34C759);
  static const Color _dangerRed = Color(0xFFFF3B30);
  static const Color _warningAmber = Color(0xFFFF9500);
  static const Color _textPrimary = Color(0xFF1C1C1E);
  static const Color _textSecondary = Color(0xFF8E8E93);
  static const Color _borderColor = Color(0xFFE5E5EA);

  final FirmwareOtaService _otaService = FirmwareOtaService();

  ParsedFirmwarePackage? _selectedPackage;
  String? _pickError;
  bool _picking = false;
  FirmwareOtaProgress _progress = const FirmwareOtaProgress(phase: FirmwareOtaPhase.idle);

  Future<void> _pickZipFile() async {
    if (_picking || _progress.isBusy) return;
    setState(() {
      _picking = true;
      _pickError = null;
    });
    try {
      final pkg = await _otaService.pickAndValidateFirmwareZip();
      if (!mounted) return;
      if (pkg != null) {
        setState(() {
          _selectedPackage = pkg;
          _progress = const FirmwareOtaProgress(phase: FirmwareOtaPhase.idle);
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _pickError = e is FirmwareOtaException ? e.message : 'Không thể đọc file ZIP: $e';
      });
    } finally {
      if (mounted) {
        setState(() => _picking = false);
      }
    }
  }

  Future<void> _startFlash() async {
    final pkg = _selectedPackage;
    if (pkg == null || _progress.isBusy) return;

    final bleService = Provider.of<BleService>(context, listen: false);
    final streamService = Provider.of<EspStreamService>(context, listen: false);

    setState(() {
      _pickError = null;
    });

    try {
      await _otaService.flashFirmware(
        transport: streamService,
        package: pkg,
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _progress = p);
        },
        onLog: (line, {bool isError = false}) {
          if (isError) {
            bleService.logInfo('⚠️ $line');
          } else {
            bleService.logInfo(line);
          }
        },
      );
    } catch (_) {
      // Progress state already updated with error message
    }
  }

  @override
  Widget build(BuildContext context) {
    final bleService = context.watch<BleService>();
    final streamService = context.watch<EspStreamService>();
    final bool hasWifiTcp = streamService.hasActiveTcpStream;
    final bool isBusy = _progress.isBusy;
    final String? endpoint = streamService.activeTcpEndpointLabel;
    final String? curFwVer = bleService.espFirmwareVersion;

    return PopScope(
      canPop: !isBusy,
      child: Container(
        decoration: const BoxDecoration(
          color: _bgColor,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 12,
          bottom: MediaQuery.of(context).viewInsets.bottom +
              MediaQuery.of(context).padding.bottom +
              18,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4.5,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.black.withAlpha(35),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: const Color(0xFF5856D6).withAlpha(24),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.system_update_rounded,
                      color: Color(0xFF5856D6),
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Cập nhật Firmware ESP32 (.zip)',
                          style: TextStyle(
                            color: _textPrimary,
                            fontSize: 16.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.3,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          curFwVer != null && curFwVer.isNotEmpty
                              ? 'Firmware trên mạch: v$curFwVer • ESP32-S3 OTA'
                              : 'Nạp không dây qua Wi-Fi (SoftAP hoặc Hotspot)',
                          style: const TextStyle(color: _textSecondary, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: isBusy ? null : () => Navigator.of(context).pop(),
                    icon: Icon(
                      Icons.close_rounded,
                      color: isBusy ? _textSecondary.withAlpha(90) : _textSecondary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // 1. Wi-Fi Transport Status Banner
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: (hasWifiTcp ? _successGreen : _warningAmber).withAlpha(18),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: (hasWifiTcp ? _successGreen : _warningAmber).withAlpha(75),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      hasWifiTcp ? Icons.wifi_rounded : Icons.wifi_off_rounded,
                      color: hasWifiTcp ? _successGreen : _warningAmber,
                      size: 21,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            hasWifiTcp
                                ? 'Wi-Fi tốc độ cao đã sẵn sàng ($endpoint)'
                                : 'Chưa kết nối Wi-Fi tới ESP32',
                            style: TextStyle(
                              color: hasWifiTcp ? const Color(0xFF1E8E3E) : const Color(0xFFB25E00),
                              fontWeight: FontWeight.w700,
                              fontSize: 12.5,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            hasWifiTcp
                                ? 'Hỗ trợ cả Wi-Fi ESP32 (SoftAP) và Điểm phát sóng Hotspot. Luồng bản đồ sẽ tạm dừng khi nạp.'
                                : 'Hãy kết nối Wi-Fi "${bleService.wifiSsid}" hoặc bật Hotspot cá nhân trước khi bấm Nạp.',
                            style: const TextStyle(color: Color(0xFF3A3A3C), fontSize: 11.5, height: 1.35),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // 2. ZIP Picker Card
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: _cardColor,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _borderColor),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Gói Firmware (.zip)',
                            style: TextStyle(
                              color: _textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _primaryBlue.withAlpha(22),
                            foregroundColor: _primaryBlue,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          onPressed: (_picking || isBusy) ? null : _pickZipFile,
                          icon: _picking
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: _primaryBlue),
                                )
                              : const Icon(Icons.folder_zip_rounded, size: 17),
                          label: Text(
                            _selectedPackage == null ? 'Chọn file .zip' : 'Chọn file khác',
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5),
                          ),
                        ),
                      ],
                    ),
                    if (_pickError != null) ...[
                      const SizedBox(height: 10),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: _dangerRed.withAlpha(18),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: _dangerRed.withAlpha(70)),
                        ),
                        child: Text(
                          _pickError!,
                          style: const TextStyle(color: _dangerRed, fontSize: 12, height: 1.35),
                        ),
                      ),
                    ],
                    if (_selectedPackage == null && _pickError == null) ...[
                      const SizedBox(height: 8),
                      const Text(
                        'Chọn file .zip chứa firmware.bin cho ESP32-S3 (hỗ trợ cả file .zip kèm manifest.json hoặc file .zip nén trực tiếp firmware.bin).',
                        style: TextStyle(color: _textSecondary, fontSize: 12, height: 1.4),
                      ),
                    ],
                    if (_selectedPackage != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: _bgColor,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: _successGreen.withAlpha(90)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.verified_rounded, color: _successGreen, size: 17),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    _selectedPackage!.zipFileName,
                                    style: const TextStyle(
                                      color: _textPrimary,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 13,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            _buildMetaRow('File ảnh:', _selectedPackage!.binFileName),
                            if (_selectedPackage!.version.isNotEmpty)
                              _buildMetaRow('Phiên bản:', 'v${_selectedPackage!.version}'),
                            _buildMetaRow('Dung lượng:', _selectedPackage!.formattedSize),
                            _buildMetaRow(
                              'Kiểm tra:',
                              'ESP32-S3 hợp lệ (Magic 0xE9 • Chip #${_selectedPackage!.chipId})',
                            ),
                            _buildMetaRow(
                              'MD5:',
                              _selectedPackage!.md5Hex,
                              monospace: true,
                            ),
                            if (_selectedPackage!.notes.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                _selectedPackage!.notes,
                                style: const TextStyle(
                                  color: Color(0xFF3A3A3C),
                                  fontSize: 11.5,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              // 3. Progress Section
              if (_progress.phase != FirmwareOtaPhase.idle) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: _cardColor,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: _progress.phase == FirmwareOtaPhase.error
                          ? _dangerRed.withAlpha(110)
                          : (_progress.phase == FirmwareOtaPhase.completed
                              ? _successGreen.withAlpha(130)
                              : _primaryBlue.withAlpha(90)),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (isBusy)
                            const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2.2, color: _primaryBlue),
                            )
                          else
                            Icon(
                              _progress.phase == FirmwareOtaPhase.completed
                                  ? Icons.check_circle_rounded
                                  : (_progress.phase == FirmwareOtaPhase.error
                                      ? Icons.error_rounded
                                      : Icons.info_rounded),
                              color: _progress.phase == FirmwareOtaPhase.completed
                                  ? _successGreen
                                  : (_progress.phase == FirmwareOtaPhase.error
                                      ? _dangerRed
                                      : _warningAmber),
                              size: 19,
                            ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _progress.message,
                              style: TextStyle(
                                color: _progress.phase == FirmwareOtaPhase.error
                                    ? _dangerRed
                                    : (_progress.phase == FirmwareOtaPhase.completed
                                        ? const Color(0xFF1E8E3E)
                                        : _textPrimary),
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                                height: 1.35,
                              ),
                            ),
                          ),
                          if (isBusy || _progress.phase == FirmwareOtaPhase.completed)
                            Text(
                              '${_progress.percent}%',
                              style: const TextStyle(
                                color: _primaryBlue,
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                        ],
                      ),
                      if (isBusy || _progress.phase == FirmwareOtaPhase.completed) ...[
                        const SizedBox(height: 10),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: LinearProgressIndicator(
                            value: _progress.phase == FirmwareOtaPhase.connecting ||
                                    _progress.phase == FirmwareOtaPhase.starting
                                ? null
                                : _progress.fraction,
                            minHeight: 9,
                            backgroundColor: _bgColor,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              _progress.phase == FirmwareOtaPhase.completed
                                  ? _successGreen
                                  : _primaryBlue,
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              '${(_progress.bytesSent / 1024).round()} / ${(_progress.totalBytes / 1024).round()} KB',
                              style: const TextStyle(color: _textSecondary, fontSize: 11.5),
                            ),
                            if (_progress.speedKbPerSec > 0)
                              Text(
                                '${_progress.speedKbPerSec.toStringAsFixed(0)} KB/s',
                                style: const TextStyle(
                                  color: _primaryBlue,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 12),

              // 4. Safety Hint
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  '• Không tắt nguồn ESP32 và giữ màn hình điện thoại mở trong lúc nạp (~5–10 giây).\n'
                  '• Phân vùng OTA kép tự động bảo vệ mạch: nếu mất Wi-Fi hoặc sai MD5, ESP32 tự giữ bản cũ.',
                  style: TextStyle(color: _textSecondary, fontSize: 11.2, height: 1.4),
                ),
              ),
              const SizedBox(height: 14),

              // 5. Action Buttons
              Row(
                children: [
                  if (isBusy)
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: _dangerRed,
                          side: const BorderSide(color: _dangerRed),
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        onPressed: () => _otaService.requestCancel(),
                        icon: const Icon(Icons.stop_circle_outlined, size: 18),
                        label: const Text(
                          'Hủy nạp firmware',
                          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                        ),
                      ),
                    )
                  else ...[
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF5856D6),
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: Colors.grey.shade300,
                          disabledForegroundColor: Colors.grey.shade600,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        onPressed: _selectedPackage != null ? _startFlash : null,
                        icon: const Icon(Icons.bolt_rounded, size: 20),
                        label: Text(
                          _progress.phase == FirmwareOtaPhase.completed
                              ? 'Nạp lại Firmware'
                              : 'Bắt đầu nạp Firmware (OTA)',
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMetaRow(String label, String value, {bool monospace = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 78,
            child: Text(
              label,
              style: const TextStyle(color: _textSecondary, fontSize: 11.5),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: _textPrimary,
                fontSize: monospace ? 10.5 : 11.5,
                fontWeight: FontWeight.w600,
                fontFamily: monospace ? 'monospace' : null,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

