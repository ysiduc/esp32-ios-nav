import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/services/firmware_ota_service.dart';

Uint8List _makeFakeEsp32S3Bin({
  int size = 70000,
  int magic = 0xE9,
  int chipId = 9,
}) {
  final bytes = Uint8List(size);
  bytes[0] = magic;
  bytes[12] = chipId & 0xFF;
  bytes[13] = (chipId >> 8) & 0xFF;
  for (int i = 24; i < size; i++) {
    bytes[i] = (i * 31 + 7) & 0xFF;
  }
  return bytes;
}

Uint8List _encodeZip(Map<String, List<int>> entries) {
  final archive = Archive();
  entries.forEach((name, data) {
    archive.addFile(ArchiveFile(name, data.length, data));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

class _FakeOtaTransport implements EspOtaTransport {
  @override
  bool hasActiveTcpStream = true;

  @override
  String? activeTcpEndpointLabel = '192.168.4.1:8081';

  bool otaModeActive = false;
  void Function(Uint8List chunk)? _onRx;
  void Function(String reason)? _onDisconnected;

  final List<int> receivedFirmwareBytes = [];
  Map<String, dynamic>? beginMeta;
  int? endReportedSize;
  bool abortReceived = false;
  int? failChunkIndex;
  List<int> failReply = const [0x45, 0x33]; // 'E', '3'
  int _dataChunkCount = 0;
  bool injectStrayStreamAcks = true;
  void Function(int chunkIndex)? onDataChunkHandled;

  @override
  Future<bool> ensureWifiTcpConnectedForOta({
    Duration timeout = const Duration(seconds: 6),
  }) async {
    return hasActiveTcpStream;
  }

  @override
  void beginOtaTransport({
    required void Function(Uint8List chunk) onRx,
    required void Function(String reason) onDisconnected,
  }) {
    otaModeActive = true;
    _onRx = onRx;
    _onDisconnected = onDisconnected;
  }

  @override
  Future<bool> sendOtaRawPacket(Uint8List packet) async {
    if (!otaModeActive || !hasActiveTcpStream) return false;
    expect(packet.length, greaterThanOrEqualTo(5));
    expect(packet[0], 0xAA);
    final pktType = packet[1];
    final len = (packet[2] << 8) | packet[3];
    expect(packet.length, 4 + len);
    final payload = packet.sublist(4);

    if (pktType == FirmwareOtaService.pktOtaBegin) {
      beginMeta = jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
      scheduleMicrotask(() {
        if (injectStrayStreamAcks) {
          _onRx?.call(Uint8List.fromList([0x4B, 0x4B, 0x4F])); // stray 'K','K' then 'O'
        } else {
          _onRx?.call(Uint8List.fromList([0x4F]));
        }
      });
      return true;
    }

    if (pktType == FirmwareOtaService.pktOtaData) {
      final idx = _dataChunkCount++;
      if (failChunkIndex != null && idx == failChunkIndex) {
        // Test split 2-byte error reply ('E' then error code in second TCP segment)
        scheduleMicrotask(() => _onRx?.call(Uint8List.fromList([failReply.first])));
        Future<void>.delayed(const Duration(milliseconds: 10), () {
          if (failReply.length > 1) {
            _onRx?.call(Uint8List.fromList([failReply[1]]));
          }
        });
        return true;
      }
      receivedFirmwareBytes.addAll(payload);
      onDataChunkHandled?.call(idx);
      scheduleMicrotask(() => _onRx?.call(Uint8List.fromList([0x4F])));
      return true;
    }

    if (pktType == FirmwareOtaService.pktOtaEnd) {
      expect(payload.length, 4);
      endReportedSize = (payload[0] << 24) |
          (payload[1] << 16) |
          (payload[2] << 8) |
          payload[3];
      scheduleMicrotask(() {
        _onRx?.call(Uint8List.fromList([0x52])); // 'R' rebooting OK
      });
      return true;
    }

    if (pktType == FirmwareOtaService.pktOtaAbort) {
      abortReceived = true;
      scheduleMicrotask(() => _onRx?.call(Uint8List.fromList([0x41]))); // 'A'
      return true;
    }

    return false;
  }

  void simulateDisconnect(String reason) {
    hasActiveTcpStream = false;
    _onDisconnected?.call(reason);
  }

  @override
  void endOtaTransport() {
    otaModeActive = false;
    _onRx = null;
    _onDisconnected = null;
  }
}

void main() {
  group('FirmwareOtaService MD5 & ZIP Validation', () {
    test('computes RFC 1321 MD5 test vectors accurately', () {
      expect(
        FirmwareOtaService.computeMd5Hex(Uint8List(0)),
        'd41d8cd98f00b204e9800998ecf8427e',
      );
      expect(
        FirmwareOtaService.computeMd5Hex(Uint8List.fromList(utf8.encode('abc'))),
        '900150983cd24fb0d6963f7d28e17f72',
      );
      expect(
        FirmwareOtaService.computeMd5Hex(Uint8List.fromList(utf8.encode('message digest'))),
        'f96b697d7cb7938d525a2f31aaf161d0',
      );
      expect(
        FirmwareOtaService.computeMd5Hex(
          Uint8List.fromList(utf8.encode('abcdefghijklmnopqrstuvwxyz')),
        ),
        'c3fcd3d76192e4007dfb496cca67e13b',
      );
    });

    test('extracts ESP32-S3 firmware.bin + manifest.json and ignores bootloader/MACOSX files', () {
      final fwBin = _makeFakeEsp32S3Bin(size: 72100);
      final md5 = FirmwareOtaService.computeMd5Hex(fwBin);
      final zipBytes = _encodeZip({
        '__MACOSX/._firmware.bin': [1, 2, 3, 4],
        'build/bootloader.bin': _makeFakeEsp32S3Bin(size: 16384),
        'build/partitions.bin': List<int>.filled(3072, 0xAA),
        'build/firmware.bin': fwBin,
        'manifest.json': utf8.encode(jsonEncode({
          'version': '2.1.0',
          'board': 'esp32-s3',
          'file': 'firmware.bin',
          'md5': md5,
          'notes': 'Bản cập nhật OTA thử nghiệm',
        })),
      });

      final parsed = FirmwareOtaService.extractFirmwareFromZip(
        zipBytes,
        zipFileName: 'hoa_huong_duong_v2.1.0.zip',
      );

      expect(parsed.binFileName, 'firmware.bin');
      expect(parsed.sizeBytes, 72100);
      expect(parsed.md5Hex, md5);
      expect(parsed.version, '2.1.0');
      expect(parsed.chipId, 9);
      expect(parsed.notes, 'Bản cập nhật OTA thử nghiệm');
    });

    test('rejects wrong chip ID, invalid magic, or MD5 mismatch safely', () {
      // Wrong chip ID (classic ESP32 = 0 instead of ESP32-S3 = 9)
      final wrongChipZip = _encodeZip({
        'firmware.bin': _makeFakeEsp32S3Bin(size: 70000, chipId: 0),
      });
      expect(
        () => FirmwareOtaService.extractFirmwareFromZip(wrongChipZip),
        throwsA(isA<FirmwareOtaException>().having(
          (e) => e.message,
          'message',
          contains('ESP32-S3'),
        )),
      );

      // Bad magic byte
      final wrongMagicZip = _encodeZip({
        'firmware.bin': _makeFakeEsp32S3Bin(size: 70000, magic: 0x00),
      });
      expect(
        () => FirmwareOtaService.extractFirmwareFromZip(wrongMagicZip),
        throwsA(isA<FirmwareOtaException>().having(
          (e) => e.message,
          'message',
          contains('0xE9'),
        )),
      );

      // Bad MD5 vs manifest.json
      final badMd5Zip = _encodeZip({
        'firmware.bin': _makeFakeEsp32S3Bin(size: 70000),
        'manifest.json': utf8.encode(jsonEncode({
          'file': 'firmware.bin',
          'md5': '00000000000000000000000000000000',
        })),
      });
      expect(
        () => FirmwareOtaService.extractFirmwareFromZip(badMd5Zip),
        throwsA(isA<FirmwareOtaException>().having(
          (e) => e.message,
          'message',
          contains('MD5'),
        )),
      );
    });
  });

  group('FirmwareOtaService Lock-Step TCP Protocol', () {
    test('streams 4KB chunks, ignores stray K ACKs, verifies size & MD5, and completes', () async {
      final fwBin = _makeFakeEsp32S3Bin(size: 70005); // non-multiple of 4096
      final zipBytes = _encodeZip({'firmware.bin': fwBin});
      final pkg = FirmwareOtaService.extractFirmwareFromZip(zipBytes);
      final transport = _FakeOtaTransport();
      final ota = FirmwareOtaService();
      final progressLog = <FirmwareOtaProgress>[];

      await ota.flashFirmware(
        transport: transport,
        package: pkg,
        onProgress: progressLog.add,
        settleDelay: Duration.zero,
      );

      expect(transport.otaModeActive, isFalse);
      expect(transport.beginMeta?['size'], fwBin.length);
      expect(transport.beginMeta?['md5'], pkg.md5Hex);
      expect(transport.endReportedSize, fwBin.length);
      expect(Uint8List.fromList(transport.receivedFirmwareBytes), fwBin);
      expect(progressLog.last.phase, FirmwareOtaPhase.completed);
      expect(progressLog.last.percent, 100);
    });

    test('surfaces ESP32 MD5/Flash error code and restores transport', () async {
      final fwBin = _makeFakeEsp32S3Bin(size: 70000);
      final pkg = FirmwareOtaService.extractFirmwareFromZip(
        _encodeZip({'firmware.bin': fwBin}),
      );
      final transport = _FakeOtaTransport()
        ..failChunkIndex = 2
        ..failReply = const [0x45, 0x32]; // 'E', '2' = Flash write failure
      final ota = FirmwareOtaService();

      await expectLater(
        ota.flashFirmware(
          transport: transport,
          package: pkg,
          onProgress: (_) {},
          settleDelay: Duration.zero,
        ),
        throwsA(isA<FirmwareOtaException>().having(
          (e) => e.message,
          'message',
          contains('Flash'),
        )),
      );
      expect(transport.otaModeActive, isFalse);
    });

    test('sends OTA_ABORT (0xE3) cleanly when user cancels mid-upload', () async {
      final fwBin = _makeFakeEsp32S3Bin(size: 70000);
      final pkg = FirmwareOtaService.extractFirmwareFromZip(
        _encodeZip({'firmware.bin': fwBin}),
      );
      final ota = FirmwareOtaService();
      final transport = _FakeOtaTransport();
      transport.onDataChunkHandled = (idx) {
        if (idx == 3) ota.requestCancel();
      };

      FirmwareOtaProgress? lastProgress;
      await ota.flashFirmware(
        transport: transport,
        package: pkg,
        onProgress: (p) => lastProgress = p,
        settleDelay: Duration.zero,
      );

      expect(transport.abortReceived, isTrue);
      expect(transport.otaModeActive, isFalse);
      expect(lastProgress?.phase, FirmwareOtaPhase.cancelled);
    });
  });
}

