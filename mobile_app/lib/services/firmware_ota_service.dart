import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter/services.dart';

/// Parsed and validated ESP32-S3 OTA firmware package extracted from a `.zip` file.
class ParsedFirmwarePackage {
  final String zipFileName;
  final String binFileName;
  final Uint8List binBytes;
  final String md5Hex;
  final String version;
  final String board;
  final String notes;
  final int chipId;

  const ParsedFirmwarePackage({
    required this.zipFileName,
    required this.binFileName,
    required this.binBytes,
    required this.md5Hex,
    required this.version,
    required this.board,
    required this.notes,
    required this.chipId,
  });

  int get sizeBytes => binBytes.length;

  String get formattedSize {
    final kb = sizeBytes / 1024.0;
    if (kb >= 1024.0) {
      return '${(kb / 1024.0).toStringAsFixed(2)} MB (${kb.round()} KB)';
    }
    return '${kb.toStringAsFixed(1)} KB';
  }
}

enum FirmwareOtaPhase {
  idle,
  connecting,
  starting,
  uploading,
  verifying,
  completed,
  cancelled,
  error,
}

class FirmwareOtaProgress {
  final FirmwareOtaPhase phase;
  final int bytesSent;
  final int totalBytes;
  final double speedKbPerSec;
  final String message;

  const FirmwareOtaProgress({
    required this.phase,
    this.bytesSent = 0,
    this.totalBytes = 0,
    this.speedKbPerSec = 0.0,
    this.message = '',
  });

  double get fraction => totalBytes > 0 ? (bytesSent / totalBytes).clamp(0.0, 1.0) : 0.0;
  int get percent => (fraction * 100).round().clamp(0, 100);
  bool get isBusy =>
      phase == FirmwareOtaPhase.connecting ||
      phase == FirmwareOtaPhase.starting ||
      phase == FirmwareOtaPhase.uploading ||
      phase == FirmwareOtaPhase.verifying;
}

/// Minimal transport interface implemented by [EspStreamService] (and fakes in unit tests).
abstract class EspOtaTransport {
  bool get hasActiveTcpStream;
  String? get activeTcpEndpointLabel;

  Future<bool> ensureWifiTcpConnectedForOta({Duration timeout});

  void beginOtaTransport({
    required void Function(Uint8List chunk) onRx,
    required void Function(String reason) onDisconnected,
  });

  Future<bool> sendOtaRawPacket(Uint8List packet);

  void endOtaTransport();
}

class FirmwareOtaException implements Exception {
  final String message;
  const FirmwareOtaException(this.message);

  @override
  String toString() => message;
}

/// Handles picking a firmware `.zip`, validating ESP32-S3 binary headers & MD5,
/// and streaming chunks over the live Wi-Fi TCP connection (SoftAP :8081 or Hotspot :8082).
class FirmwareOtaService {
  static const MethodChannel _channel = MethodChannel('com.ysiduc.esp32_nav/location');

  static const int espImageMagic = 0xE9;
  static const int esp32S3ChipId = 9;
  static const int minFirmwareBytes = 65536; // 64 KB
  static const int maxFirmwareBytes = 0x330000; // 3,342,336 bytes (default_8MB.csv app0/app1)
  static const int otaChunkSize = 4096; // Matches ESP32 SPI Flash sector size

  static const int pktOtaBegin = 0xE0;
  static const int pktOtaData = 0xE1;
  static const int pktOtaEnd = 0xE2;
  static const int pktOtaAbort = 0xE3;

  static const int respOk = 0x4F; // 'O'
  static const int respReboot = 0x52; // 'R'
  static const int respError = 0x45; // 'E'
  static const int respAborted = 0x41; // 'A'
  static const int respStreamAck = 0x4B; // 'K' (ignored during OTA)

  static const List<String> _ignoredBinPrefixes = [
    'bootloader',
    'partition',
    'boot_app',
    'spiffs',
    'littlefs',
    'otadata',
    'ota_data',
    'nvs',
  ];

  bool _cancelRequested = false;

  void requestCancel() {
    _cancelRequested = true;
  }

  /// Opens native iOS Files / Android Document Picker to select a firmware `.zip`.
  /// Returns `null` if user cancelled. Throws [FirmwareOtaException] on invalid archive/binary.
  Future<ParsedFirmwarePackage?> pickAndValidateFirmwareZip() async {
    final raw = await _channel.invokeMethod<dynamic>('pickZipFile');
    if (raw == null || raw is! Map) return null;
    final name = (raw['name'] as String?)?.trim() ?? 'firmware.zip';
    final rawBytes = raw['bytes'];
    if (rawBytes is! Uint8List || rawBytes.isEmpty) {
      throw const FirmwareOtaException('Không đọc được dữ liệu từ file ZIP đã chọn.');
    }
    return extractFirmwareFromZip(rawBytes, zipFileName: name);
  }

  /// Extracts, validates, and hashes an ESP32-S3 application `.bin` inside [zipBytes].
  static ParsedFirmwarePackage extractFirmwareFromZip(
    Uint8List zipBytes, {
    String zipFileName = 'firmware.zip',
  }) {
    if (zipBytes.length < 4 || zipBytes[0] != 0x50 || zipBytes[1] != 0x4B) {
      throw const FirmwareOtaException(
        'File không phải định dạng nén .zip hợp lệ (thiếu header PK).',
      );
    }

    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(zipBytes);
    } catch (e) {
      throw FirmwareOtaException('Không thể giải nén file ZIP: $e');
    }

    final files = archive.files.where((f) {
      if (!f.isFile) return false;
      final norm = f.name.replaceAll('\\', '/');
      if (norm.startsWith('__MACOSX/') || norm.contains('/__MACOSX/')) return false;
      final base = _basename(norm);
      if (base.startsWith('._')) return false;
      return true;
    }).toList();

    if (files.isEmpty) {
      throw const FirmwareOtaException('File ZIP trống, không chứa file firmware (.bin).');
    }

    // 1. Parse optional manifest.json / firmware.json / info.json
    Map<String, dynamic>? manifest;
    for (final f in files) {
      final lowerBase = _basename(f.name).toLowerCase();
      if (lowerBase == 'manifest.json' ||
          lowerBase == 'firmware.json' ||
          lowerBase == 'info.json') {
        try {
          final txt = utf8.decode(_archiveFileBytes(f), allowMalformed: true);
          final parsed = jsonDecode(txt);
          if (parsed is Map) {
            manifest = Map<String, dynamic>.from(parsed);
            break;
          }
        } catch (_) {}
      }
    }

    final manifestFile = (manifest?['file'] as String?)?.trim();
    final manifestMd5 = (manifest?['md5'] as String?)?.trim().toLowerCase();
    final manifestVersion = (manifest?['version'] as String?)?.trim() ?? '';
    final manifestBoard = (manifest?['board'] as String?)?.trim().toLowerCase() ?? '';
    final manifestNotes = (manifest?['notes'] as String?)?.trim() ?? '';

    if (manifestBoard.isNotEmpty &&
        !manifestBoard.contains('esp32-s3') &&
        !manifestBoard.contains('esp32s3')) {
      throw FirmwareOtaException(
        'Firmware trong gói dành cho board "$manifestBoard", không tương thích ESP32-S3.',
      );
    }

    // 2. Select application firmware .bin
    final binCandidates = files
        .where((f) => _basename(f.name).toLowerCase().endsWith('.bin'))
        .toList();

    if (binCandidates.isEmpty) {
      throw const FirmwareOtaException(
        'Không tìm thấy file firmware (.bin) nào bên trong file ZIP.',
      );
    }

    ArchiveFile? selected;
    if (manifestFile != null && manifestFile.isNotEmpty) {
      final wantedNorm = manifestFile.replaceAll('\\', '/').toLowerCase();
      final wantedBase = _basename(wantedNorm);
      for (final f in binCandidates) {
        final norm = f.name.replaceAll('\\', '/').toLowerCase();
        if (norm == wantedNorm || _basename(norm) == wantedBase) {
          selected = f;
          break;
        }
      }
      if (selected == null) {
        throw FirmwareOtaException(
          'manifest.json khai báo "$manifestFile" nhưng không tìm thấy file này trong ZIP.',
        );
      }
    }

    selected ??= _findByBasename(binCandidates, 'firmware.bin');

    if (selected == null) {
      final appBins = binCandidates.where((f) {
        final base = _basename(f.name).toLowerCase();
        return !_ignoredBinPrefixes.any((prefix) => base.startsWith(prefix));
      }).toList();
      if (appBins.isEmpty) {
        throw const FirmwareOtaException(
          'File ZIP chỉ chứa file hệ thống (bootloader/partitions), không có firmware ứng dụng (.bin).',
        );
      }
      appBins.sort((a, b) => b.size.compareTo(a.size));
      selected = appBins.first;
    }

    final binBytes = _archiveFileBytes(selected);
    final binName = _basename(selected.name);

    // 3. Validate ESP32-S3 image header & size bounds
    if (binBytes.length < minFirmwareBytes) {
      throw FirmwareOtaException(
        'File "$binName" quá nhỏ (${(binBytes.length / 1024).toStringAsFixed(1)} KB), không phải firmware ESP32-S3 hợp lệ.',
      );
    }
    if (binBytes.length > maxFirmwareBytes) {
      throw FirmwareOtaException(
        'File "$binName" vượt quá dung lượng phân vùng OTA ESP32-S3 (${(binBytes.length / 1048576).toStringAsFixed(2)} MB > 3.18 MB).',
      );
    }
    if (binBytes[0] != espImageMagic) {
      throw FirmwareOtaException(
        'File "$binName" sai mã đầu ảnh ESP32 (0x${binBytes[0].toRadixString(16).padLeft(2, '0')} != 0xE9).',
      );
    }
    final chipId = binBytes[12] | (binBytes[13] << 8);
    if (chipId != esp32S3ChipId) {
      throw FirmwareOtaException(
        'File "$binName" không phải firmware cho ESP32-S3 (Chip ID = $chipId, yêu cầu = $esp32S3ChipId).',
      );
    }

    // 4. Compute & verify MD5 checksum
    final computedMd5 = computeMd5Hex(binBytes);
    if (manifestMd5 != null && manifestMd5.isNotEmpty) {
      if (manifestMd5 != computedMd5) {
        throw const FirmwareOtaException(
          'File firmware trong ZIP bị hỏng hoặc sai mã kiểm tra MD5 so với manifest.json.',
        );
      }
    }

    return ParsedFirmwarePackage(
      zipFileName: zipFileName,
      binFileName: binName,
      binBytes: binBytes,
      md5Hex: computedMd5,
      version: manifestVersion.isNotEmpty ? manifestVersion : _inferVersionFromName(zipFileName),
      board: manifestBoard.isNotEmpty ? manifestBoard : 'esp32-s3',
      notes: manifestNotes,
      chipId: chipId,
    );
  }

  /// Builds a framed binary packet `0xAA <type> <lenH> <lenL> <payload>`.
  static Uint8List buildOtaPacket(int pktType, List<int> payload) {
    final len = payload.length;
    final out = Uint8List(4 + len);
    out[0] = 0xAA;
    out[1] = pktType & 0xFF;
    out[2] = (len >> 8) & 0xFF;
    out[3] = len & 0xFF;
    out.setRange(4, 4 + len, payload);
    return out;
  }

  /// Streams [package] to ESP32 over [transport] using lock-step verified chunks.
  Future<void> flashFirmware({
    required EspOtaTransport transport,
    required ParsedFirmwarePackage package,
    required void Function(FirmwareOtaProgress progress) onProgress,
    void Function(String logLine, {bool isError})? onLog,
    Duration settleDelay = const Duration(milliseconds: 160),
    Duration beginTimeout = const Duration(seconds: 10),
    Duration chunkTimeout = const Duration(seconds: 8),
    Duration endTimeout = const Duration(seconds: 12),
  }) async {
    _cancelRequested = false;

    onProgress(FirmwareOtaProgress(
      phase: FirmwareOtaPhase.connecting,
      totalBytes: package.sizeBytes,
      message: 'Đang kiểm tra kết nối Wi-Fi TCP tới ESP32...',
    ));

    final connected = await transport.ensureWifiTcpConnectedForOta(
      timeout: const Duration(seconds: 6),
    );
    if (!connected || !transport.hasActiveTcpStream) {
      const msg = 'Chưa có kết nối Wi-Fi với ESP32. Hãy kết nối Wi-Fi "Hoa hướng dương" hoặc bật Hotspot rồi thử lại.';
      onProgress(FirmwareOtaProgress(
        phase: FirmwareOtaPhase.error,
        totalBytes: package.sizeBytes,
        message: msg,
      ));
      throw const FirmwareOtaException(msg);
    }

    final waiter = _OtaAckWaiter();
    bool completedReboot = false;

    transport.beginOtaTransport(
      onRx: waiter.addChunk,
      onDisconnected: (reason) {
        if (!completedReboot) {
          waiter.failDisconnect(reason);
        }
      },
    );

    try {
      if (settleDelay > Duration.zero) {
        await Future<void>.delayed(settleDelay);
      }
      waiter.clear();

      // 1. Send OTA_BEGIN (0xE0)
      onProgress(FirmwareOtaProgress(
        phase: FirmwareOtaPhase.starting,
        totalBytes: package.sizeBytes,
        message: 'Đang khởi tạo phân vùng OTA trên ESP32...',
      ));
      onLog?.call(
        '[OTA] Bắt đầu nạp ${package.binFileName} (${package.formattedSize}, MD5=${package.md5Hex.substring(0, 8)}...)',
      );

      final beginJson = utf8.encode(jsonEncode({
        'size': package.sizeBytes,
        'md5': package.md5Hex,
        'name': package.binFileName,
        if (package.version.isNotEmpty) 'ver': package.version,
      }));
      final beginSent = await transport.sendOtaRawPacket(
        buildOtaPacket(pktOtaBegin, beginJson),
      );
      if (!beginSent) {
        throw const FirmwareOtaException('Không gửi được lệnh khởi tạo OTA tới ESP32.');
      }

      final beginResp = await waiter.waitForResponse(
        timeout: beginTimeout,
        timeoutHint:
            'ESP32 không phản hồi lệnh OTA. Nếu mạch đang chạy bản cũ chưa hỗ trợ OTA, hãy nạp bản mới lần đầu qua cáp USB.',
      );
      if (beginResp.code != respOk) {
        throw FirmwareOtaException(_describeEspError(beginResp));
      }

      // 2. Stream OTA_DATA (0xE1) in 4KB Flash-aligned lock-step chunks
      final total = package.sizeBytes;
      final sw = Stopwatch()..start();
      int offset = 0;

      while (offset < total) {
        if (_cancelRequested) {
          onLog?.call('[OTA] Đang hủy cập nhật theo yêu cầu người dùng...');
          await transport.sendOtaRawPacket(buildOtaPacket(pktOtaAbort, const [0x00]));
          try {
            await waiter.waitForResponse(timeout: const Duration(seconds: 2));
          } catch (_) {}
          onProgress(FirmwareOtaProgress(
            phase: FirmwareOtaPhase.cancelled,
            bytesSent: offset,
            totalBytes: total,
            message: 'Đã hủy cập nhật — ESP32 giữ nguyên firmware cũ.',
          ));
          return;
        }

        final end = (offset + otaChunkSize < total) ? offset + otaChunkSize : total;
        final slice = Uint8List.sublistView(package.binBytes, offset, end);
        final sent = await transport.sendOtaRawPacket(buildOtaPacket(pktOtaData, slice));
        if (!sent) {
          throw const FirmwareOtaException(
            'Mất kết nối Wi-Fi khi đang truyền dữ liệu — ESP32 vẫn giữ nguyên firmware cũ.',
          );
        }

        final chunkResp = await waiter.waitForResponse(
          timeout: chunkTimeout,
          timeoutHint: 'Quá thời gian chờ ESP32 ghi bộ nhớ Flash.',
        );
        if (chunkResp.code != respOk) {
          throw FirmwareOtaException(_describeEspError(chunkResp));
        }

        offset = end;
        final elapsedSec = sw.elapsedMilliseconds / 1000.0;
        final speedKb = elapsedSec > 0.05 ? (offset / 1024.0) / elapsedSec : 0.0;
        onProgress(FirmwareOtaProgress(
          phase: FirmwareOtaPhase.uploading,
          bytesSent: offset,
          totalBytes: total,
          speedKbPerSec: speedKb,
          message: 'Đang nạp Flash ESP32...',
        ));
      }

      // 3. Send OTA_END (0xE2) with big-endian uint32 total size for final MD5 verification
      onProgress(FirmwareOtaProgress(
        phase: FirmwareOtaPhase.verifying,
        bytesSent: total,
        totalBytes: total,
        message: 'Đang kiểm tra mã toàn vẹn MD5 trên ESP32...',
      ));

      final endPayload = Uint8List(4)
        ..[0] = (total >> 24) & 0xFF
        ..[1] = (total >> 16) & 0xFF
        ..[2] = (total >> 8) & 0xFF
        ..[3] = total & 0xFF;
      final endSent = await transport.sendOtaRawPacket(buildOtaPacket(pktOtaEnd, endPayload));
      if (!endSent) {
        throw const FirmwareOtaException('Không gửi được lệnh xác nhận hoàn tất OTA tới ESP32.');
      }

      final endResp = await waiter.waitForResponse(
        timeout: endTimeout,
        timeoutHint: 'Quá thời gian chờ ESP32 kiểm tra MD5.',
      );
      if (endResp.code != respReboot) {
        throw FirmwareOtaException(_describeEspError(endResp));
      }

      completedReboot = true;
      final elapsedSec = (sw.elapsedMilliseconds / 1000.0).clamp(0.1, 9999.0);
      final avgKb = (total / 1024.0) / elapsedSec;
      onLog?.call(
        '[OTA] Cập nhật thành công (${(total / 1024).round()} KB trong ${elapsedSec.toStringAsFixed(1)}s, ${avgKb.toStringAsFixed(0)} KB/s). ESP32 đang khởi động lại!',
      );
      onProgress(FirmwareOtaProgress(
        phase: FirmwareOtaPhase.completed,
        bytesSent: total,
        totalBytes: total,
        speedKbPerSec: avgKb,
        message: 'Cập nhật thành công! ESP32 đang khởi động lại và sẽ tự kết nối lại sau vài giây.',
      ));
    } catch (e) {
      final msg = e is FirmwareOtaException ? e.message : 'Lỗi cập nhật OTA: $e';
      onLog?.call('[OTA] Thất bại: $msg', isError: true);
      onProgress(FirmwareOtaProgress(
        phase: FirmwareOtaPhase.error,
        totalBytes: package.sizeBytes,
        message: msg,
      ));
      rethrow;
    } finally {
      transport.endOtaTransport();
    }
  }

  static String _describeEspError(_OtaResponse resp) {
    if (resp.code == respError) {
      switch (resp.detail) {
        case 0x31: // '1'
          return 'ESP32 không mở được phân vùng OTA (kiểm tra kích thước firmware).';
        case 0x32: // '2'
          return 'Lỗi ghi bộ nhớ Flash trên ESP32 — đã khôi phục bản cũ.';
        case 0x33: // '3'
          return 'ESP32 báo sai mã kiểm tra MD5 — đã hủy và giữ nguyên firmware cũ.';
        case 0x34: // '4'
          return 'Dung lượng firmware ESP32 nhận được không khớp — đã hủy cập nhật.';
        case 0x35: // '5'
          return 'Trạng thái OTA không đồng bộ trên ESP32 — hãy thử nạp lại.';
        default:
          return 'ESP32 báo lỗi OTA (mã ${resp.detail ?? 0}) — đã giữ nguyên firmware cũ.';
      }
    }
    if (resp.code == respAborted) {
      return 'ESP32 đã hủy quá trình cập nhật.';
    }
    return 'Phản hồi OTA không hợp lệ từ ESP32 (0x${resp.code.toRadixString(16)}).';
  }

  static ArchiveFile? _findByBasename(List<ArchiveFile> files, String targetLower) {
    for (final f in files) {
      if (_basename(f.name).toLowerCase() == targetLower) return f;
    }
    return null;
  }

  static String _basename(String path) {
    final norm = path.replaceAll('\\', '/');
    final idx = norm.lastIndexOf('/');
    return idx >= 0 ? norm.substring(idx + 1) : norm;
  }

  static Uint8List _archiveFileBytes(ArchiveFile file) {
    return file.content;
  }

  static String _inferVersionFromName(String fileName) {
    final m = RegExp(r'v?(\d+\.\d+(?:\.\d+)?)', caseSensitive: false).firstMatch(fileName);
    return m != null ? m.group(1)! : '';
  }

  /// Pure-Dart RFC 1321 MD5 digest returning 32 lowercase hexadecimal characters.
  static String computeMd5Hex(Uint8List input) {
    const k = <int>[
      0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
      0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
      0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
      0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
      0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
      0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
      0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
      0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
      0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
      0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
      0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
      0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
      0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
      0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
      0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
      0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
    ];
    const s = <int>[
      7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
      5,  9, 14, 20, 5,  9, 14, 20, 5,  9, 14, 20, 5,  9, 14, 20,
      4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
      6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ];

    final origLen = input.length;
    final bitLen = origLen * 8;
    final padLen = ((56 - (origLen + 1) % 64) + 64) % 64;
    final totalLen = origLen + 1 + padLen + 8;
    final msg = Uint8List(totalLen);
    msg.setRange(0, origLen, input);
    msg[origLen] = 0x80;
    final bd = ByteData.sublistView(msg);
    bd.setUint32(totalLen - 8, bitLen & 0xFFFFFFFF, Endian.little);
    bd.setUint32(totalLen - 4, (bitLen ~/ 0x100000000) & 0xFFFFFFFF, Endian.little);

    int a0 = 0x67452301;
    int b0 = 0xefcdab89;
    int c0 = 0x98badcfe;
    int d0 = 0x10325476;
    final m = Uint32List(16);

    for (int offset = 0; offset < totalLen; offset += 64) {
      for (int j = 0; j < 16; j++) {
        m[j] = bd.getUint32(offset + j * 4, Endian.little);
      }
      int a = a0;
      int b = b0;
      int c = c0;
      int d = d0;

      for (int i = 0; i < 64; i++) {
        int f;
        int g;
        if (i < 16) {
          f = (b & c) | ((~b) & d);
          g = i;
        } else if (i < 32) {
          f = (d & b) | ((~d) & c);
          g = (5 * i + 1) & 15;
        } else if (i < 48) {
          f = b ^ c ^ d;
          g = (3 * i + 5) & 15;
        } else {
          f = c ^ (b | (~d));
          g = (7 * i) & 15;
        }
        f = (f + a + k[i] + m[g]) & 0xFFFFFFFF;
        a = d;
        d = c;
        c = b;
        final shift = s[i];
        final rot = ((f << shift) | (f >>> (32 - shift))) & 0xFFFFFFFF;
        b = (b + rot) & 0xFFFFFFFF;
      }

      a0 = (a0 + a) & 0xFFFFFFFF;
      b0 = (b0 + b) & 0xFFFFFFFF;
      c0 = (c0 + c) & 0xFFFFFFFF;
      d0 = (d0 + d) & 0xFFFFFFFF;
    }

    final digest = Uint8List(16);
    final outBd = ByteData.sublistView(digest);
    outBd.setUint32(0, a0, Endian.little);
    outBd.setUint32(4, b0, Endian.little);
    outBd.setUint32(8, c0, Endian.little);
    outBd.setUint32(12, d0, Endian.little);

    final sb = StringBuffer();
    for (final byte in digest) {
      sb.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}

class _OtaResponse {
  final int code;
  final int? detail;
  const _OtaResponse(this.code, [this.detail]);
}

class _OtaAckWaiter {
  final List<int> _buffer = [];
  Completer<_OtaResponse>? _pending;
  Timer? _errorDetailTimer;
  String? _disconnectError;

  void clear() {
    _buffer.clear();
    _disconnectError = null;
    _errorDetailTimer?.cancel();
    _errorDetailTimer = null;
  }

  void addChunk(Uint8List chunk) {
    for (final b in chunk) {
      // Ignore stray 'K' (0x4B) map stream ACKs
      if (b == FirmwareOtaService.respStreamAck) continue;
      _buffer.add(b);
    }
    _tryResolve();
  }

  void failDisconnect(String reason) {
    _disconnectError =
        'Mất kết nối Wi-Fi với ESP32 ($reason) — thiết bị đã tự giữ nguyên firmware cũ.';
    _errorDetailTimer?.cancel();
    _errorDetailTimer = null;
    final p = _pending;
    if (p != null && !p.isCompleted) {
      _pending = null;
      p.completeError(FirmwareOtaException(_disconnectError!));
    }
  }

  Future<_OtaResponse> waitForResponse({
    required Duration timeout,
    String? timeoutHint,
  }) {
    if (_disconnectError != null) {
      return Future.error(FirmwareOtaException(_disconnectError!));
    }
    final completer = Completer<_OtaResponse>();
    _pending = completer;
    _tryResolve();
    if (completer.isCompleted) {
      return completer.future;
    }
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        if (identical(_pending, completer)) {
          _pending = null;
        }
        _errorDetailTimer?.cancel();
        _errorDetailTimer = null;
        throw FirmwareOtaException(
          timeoutHint ?? 'Quá thời gian chờ phản hồi OTA từ ESP32.',
        );
      },
    );
  }

  void _tryResolve() {
    final p = _pending;
    if (p == null || p.isCompleted || _buffer.isEmpty) return;

    while (_buffer.isNotEmpty) {
      final b = _buffer.first;
      if (b == FirmwareOtaService.respOk ||
          b == FirmwareOtaService.respReboot ||
          b == FirmwareOtaService.respAborted) {
        _buffer.removeAt(0);
        _errorDetailTimer?.cancel();
        _errorDetailTimer = null;
        _pending = null;
        p.complete(_OtaResponse(b));
        return;
      }
      if (b == FirmwareOtaService.respError) {
        if (_buffer.length >= 2) {
          _buffer.removeAt(0);
          final detail = _buffer.removeAt(0);
          _errorDetailTimer?.cancel();
          _errorDetailTimer = null;
          _pending = null;
          p.complete(_OtaResponse(FirmwareOtaService.respError, detail));
          return;
        }
        // Wait briefly for the 2nd error-code byte if TCP split the 2-byte error reply
        _errorDetailTimer ??= Timer(const Duration(milliseconds: 120), () {
          _errorDetailTimer = null;
          final active = _pending;
          if (active != null &&
              !active.isCompleted &&
              _buffer.isNotEmpty &&
              _buffer.first == FirmwareOtaService.respError) {
            _buffer.removeAt(0);
            _pending = null;
            active.complete(const _OtaResponse(FirmwareOtaService.respError));
          }
        });
        return;
      }
      // Drop any unexpected stray byte before OTA sync
      _buffer.removeAt(0);
    }
  }
}
