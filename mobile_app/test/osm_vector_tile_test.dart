import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/models/esp_payload.dart';
import 'package:mobile_app/services/esp_stream_service.dart';
import 'package:mobile_app/services/osm_vector_tile.dart';

int _abgr(int r, int g, int b) =>
    0xFF000000 | ((b & 0xFF) << 16) | ((g & 0xFF) << 8) | (r & 0xFF);

void _writeVarint(BytesBuilder b, int value) {
  int v = value;
  while (true) {
    if ((v & ~0x7F) == 0) {
      b.addByte(v & 0x7F);
      return;
    }
    b.addByte((v & 0x7F) | 0x80);
    v = (v >> 7) & 0x01FFFFFFFFFFFFFF;
  }
}

void _writeLengthPrefixed(BytesBuilder b, int fieldNumber, Uint8List payload) {
  _writeVarint(b, (fieldNumber << 3) | 2);
  _writeVarint(b, payload.length);
  b.add(payload);
}

int _zigzag(int n) => (n << 1) ^ (n < 0 ? -1 : 0);

Uint8List _encodePolygonRings(List<List<List<int>>> rings) {
  final b = BytesBuilder(copy: false);
  int cx = 0;
  int cy = 0;
  for (final ring in rings) {
    if (ring.isEmpty) continue;
    _writeVarint(b, (1 << 3) | 1); // MoveTo(1)
    _writeVarint(b, _zigzag(ring[0][0] - cx));
    _writeVarint(b, _zigzag(ring[0][1] - cy));
    cx = ring[0][0];
    cy = ring[0][1];

    if (ring.length > 1) {
      _writeVarint(b, ((ring.length - 1) << 3) | 2); // LineTo(n - 1)
      for (int i = 1; i < ring.length; i++) {
        _writeVarint(b, _zigzag(ring[i][0] - cx));
        _writeVarint(b, _zigzag(ring[i][1] - cy));
        cx = ring[i][0];
        cy = ring[i][1];
      }
    }
    _writeVarint(b, (1 << 3) | 7); // ClosePath(1)
  }
  return b.toBytes();
}

Uint8List _encodeLineString(List<List<int>> pts) {
  final b = BytesBuilder(copy: false);
  int cx = 0;
  int cy = 0;
  _writeVarint(b, (1 << 3) | 1); // MoveTo(1)
  _writeVarint(b, _zigzag(pts[0][0] - cx));
  _writeVarint(b, _zigzag(pts[0][1] - cy));
  cx = pts[0][0];
  cy = pts[0][1];
  _writeVarint(b, ((pts.length - 1) << 3) | 2); // LineTo
  for (int i = 1; i < pts.length; i++) {
    _writeVarint(b, _zigzag(pts[i][0] - cx));
    _writeVarint(b, _zigzag(pts[i][1] - cy));
    cx = pts[i][0];
    cy = pts[i][1];
  }
  return b.toBytes();
}

Uint8List _encodeStringValue(String s) {
  final b = BytesBuilder(copy: false);
  _writeLengthPrefixed(b, 1, Uint8List.fromList(utf8.encode(s)));
  return b.toBytes();
}

Uint8List _encodeDoubleValue(double v) {
  final b = BytesBuilder(copy: false);
  _writeVarint(b, (3 << 3) | 1);
  final bd = ByteData(8)..setFloat64(0, v, Endian.little);
  b.add(bd.buffer.asUint8List());
  return b.toBytes();
}

Uint8List _encodeBoolValue(bool v) {
  final b = BytesBuilder(copy: false);
  _writeVarint(b, (7 << 3) | 0);
  b.addByte(v ? 1 : 0);
  return b.toBytes();
}

Uint8List _encodeFeature({
  required List<int> tags,
  required int geomType,
  required Uint8List geomBytes,
}) {
  final b = BytesBuilder(copy: false);
  if (tags.isNotEmpty) {
    final tb = BytesBuilder(copy: false);
    for (final t in tags) {
      _writeVarint(tb, t);
    }
    _writeLengthPrefixed(b, 2, tb.toBytes());
  }
  _writeVarint(b, (3 << 3) | 0);
  _writeVarint(b, geomType);
  _writeLengthPrefixed(b, 4, geomBytes);
  return b.toBytes();
}

Uint8List _encodeLayer({
  required String name,
  required List<String> keys,
  required List<Uint8List> encodedValues,
  required List<Uint8List> features,
  int extent = 4096,
}) {
  final b = BytesBuilder(copy: false);
  _writeLengthPrefixed(b, 1, Uint8List.fromList(utf8.encode(name)));
  for (final f in features) {
    _writeLengthPrefixed(b, 2, f);
  }
  for (final k in keys) {
    _writeLengthPrefixed(b, 3, Uint8List.fromList(utf8.encode(k)));
  }
  for (final v in encodedValues) {
    _writeLengthPrefixed(b, 4, v);
  }
  _writeVarint(b, (5 << 3) | 0);
  _writeVarint(b, extent);
  return b.toBytes();
}

Uint8List _buildSyntheticOsmTile() {
  final parkLayer = _encodeLayer(
    name: 'park',
    keys: ['class'],
    encodedValues: [_encodeStringValue('park')],
    features: [
      _encodeFeature(
        tags: [0, 0],
        geomType: 3,
        geomBytes: _encodePolygonRings([
          [
            [1450, 2080],
            [1950, 2080],
            [1950, 2400],
            [1450, 2400],
          ],
        ]),
      ),
    ],
  );

  final waterLayer = _encodeLayer(
    name: 'water',
    keys: ['class'],
    encodedValues: [_encodeStringValue('lake')],
    features: [
      _encodeFeature(
        tags: [0, 0],
        geomType: 3,
        geomBytes: _encodePolygonRings([
          [
            [2150, 2080],
            [2650, 2080],
            [2650, 2400],
            [2150, 2400],
          ],
        ]),
      ),
    ],
  );

  final transportLayer = _encodeLayer(
    name: 'transportation',
    keys: ['class', 'brunnel'],
    encodedValues: [
      _encodeStringValue('primary'),
      _encodeStringValue('secondary'),
      _encodeStringValue('tunnel'),
    ],
    features: [
      _encodeFeature(
        tags: [0, 0],
        geomType: 2,
        geomBytes: _encodeLineString([
          [2048, 100],
          [2048, 3996],
        ]),
      ),
      _encodeFeature(
        tags: [0, 1],
        geomType: 2,
        geomBytes: _encodeLineString([
          [100, 2048],
          [3996, 2048],
        ]),
      ),
      _encodeFeature(
        tags: [0, 0, 1, 2],
        geomType: 2,
        geomBytes: _encodeLineString([
          [100, 100],
          [500, 500],
        ]),
      ),
    ],
  );

  final buildingLayer = _encodeLayer(
    name: 'building',
    keys: ['render_height', 'hide_3d'],
    encodedValues: [
      _encodeDoubleValue(14.0),
      _encodeDoubleValue(68.5),
      _encodeBoolValue(true),
    ],
    features: [
      // Standard building with a CCW inner hole ring (hole must be ignored)
      _encodeFeature(
        tags: [0, 0],
        geomType: 3,
        geomBytes: _encodePolygonRings([
          [
            [1200, 1400],
            [1800, 1400],
            [1800, 1950],
            [1200, 1950],
          ],
          [
            [1350, 1550],
            [1350, 1800],
            [1650, 1800],
            [1650, 1550],
          ],
        ]),
      ),
      // Tall skyscraper tower
      _encodeFeature(
        tags: [0, 1],
        geomType: 3,
        geomBytes: _encodePolygonRings([
          [
            [2300, 1400],
            [2950, 1400],
            [2950, 1950],
            [2300, 1950],
          ],
        ]),
      ),
      // Hidden 3D structure (must be filtered out)
      _encodeFeature(
        tags: [0, 0, 1, 2],
        geomType: 3,
        geomBytes: _encodePolygonRings([
          [
            [100, 3000],
            [500, 3000],
            [500, 3400],
            [100, 3400],
          ],
        ]),
      ),
    ],
  );

  final tileBuilder = BytesBuilder(copy: false);
  for (final layer in [parkLayer, waterLayer, transportLayer, buildingLayer]) {
    _writeLengthPrefixed(tileBuilder, 3, layer);
  }
  return tileBuilder.toBytes();
}

void main() {
  group('OSM Vector Tile Parser & 3D Block Renderer', () {
    test('parsePbf handles empty input, raw MVT, and GZip MVT cleanly', () {
      expect(OsmVectorTile.parsePbf(Uint8List(0), 15, 0, 0), isNull);

      final raw = _buildSyntheticOsmTile();
      final gz = Uint8List.fromList(const GZipEncoder().encode(raw));

      for (final bytes in [raw, gz]) {
        final tile = OsmVectorTile.parsePbf(bytes, 15, 26095, 14424);
        expect(tile, isNotNull);
        expect(tile!.z, 15);
        expect(tile.areas.length, 2); // park + water
        expect(tile.areas.where((a) => a.kind == 1).length, 1);
        expect(tile.areas.where((a) => a.kind == 2).length, 1);

        // Tunnel should be excluded, primary & secondary kept
        expect(tile.roads.length, 2);
        expect(tile.roads.any((r) => r.tier == 4), isTrue);
        expect(tile.roads.any((r) => r.tier == 3), isTrue);

        // Hole ring & hide_3d building excluded -> 2 extruded buildings
        expect(tile.buildings.length, 2);
        expect(tile.buildings[0].heightMeters, closeTo(14.0, 0.01));
        expect(tile.buildings[1].heightMeters, closeTo(68.5, 0.01));
      }
    });

    test('Osm3dRenderer rasterizes light and dark 3D blocks, walls, roads, park, water', () {
      final tile = OsmVectorTile.parsePbf(_buildSyntheticOsmTile(), 15, 26095, 14424)!;
      final renderer = Osm3dRenderer();
      const w = 320;
      const h = 216;
      final lightBuf = Uint32List(w * h);
      final darkBuf = Uint32List(w * h);

      // displayZoom = 17 => tileSizePx = 256 * 2^(17-15) = 1024; center = 0.5 tile = +512 px
      final userWorldX = tile.x * 1024.0 + 512.0;
      final userWorldY = tile.y * 1024.0 + 512.0;

      renderer.renderFrame(
        buf32: lightBuf,
        width: w,
        height: h,
        tiles: [tile],
        userWorldX: userWorldX,
        userWorldY: userWorldY,
        displayZoom: 17,
        headingDeg: 0.0,
        anchorX: w * 0.5,
        anchorY: h * 0.65,
        pitchY: 0.74,
        isDark: false,
      );

      renderer.renderFrame(
        buf32: darkBuf,
        width: w,
        height: h,
        tiles: [tile],
        userWorldX: userWorldX,
        userWorldY: userWorldY,
        displayZoom: 17,
        headingDeg: 0.0,
        anchorX: w * 0.5,
        anchorY: h * 0.65,
        pitchY: 0.74,
        isDark: true,
      );

      final lightColors = lightBuf.toSet();
      expect(lightColors.contains(_abgr(241, 239, 233)), isTrue); // ground
      expect(lightColors.contains(_abgr(235, 227, 217)), isTrue); // standard roof
      expect(lightColors.contains(_abgr(209, 221, 235)), isTrue); // tall roof
      expect(lightColors.contains(_abgr(252, 214, 146)), isTrue); // primary road
      expect(lightColors.contains(_abgr(199, 231, 173)), isTrue); // park
      expect(lightColors.contains(_abgr(150, 206, 236)), isTrue); // water
      // At least one 3D shaded wall pixel must be rasterized
      final lightWallColors = {
        _abgr(214, 204, 192),
        _abgr(191, 180, 167),
        _abgr(166, 154, 142),
        _abgr(180, 196, 216),
        _abgr(150, 169, 192),
        _abgr(122, 141, 166),
      };
      expect(lightColors.intersection(lightWallColors).isNotEmpty, isTrue);

      final darkColors = darkBuf.toSet();
      expect(darkColors.contains(_abgr(13, 21, 34)), isTrue); // night ground
      expect(darkColors.contains(_abgr(36, 51, 74)), isTrue); // night std roof
      expect(darkColors.contains(_abgr(46, 68, 98)), isTrue); // night tall roof

      int diffs = 0;
      for (int i = 0; i < lightBuf.length; i++) {
        if (lightBuf[i] != darkBuf[i]) diffs++;
      }
      expect(diffs, greaterThan(10000));
    });

    test('EspStreamService includes osm-3d and osm-3d-dark styles', () {
      expect(EspStreamService.supportedMapStyles.contains('osm-3d'), isTrue);
      expect(EspStreamService.supportedMapStyles.contains('osm-3d-dark'), isTrue);
    });
  });

  group('Vietnamese NFC Normalization & UTF-8 BLE Payload', () {
    test('cleanUtf8ForEsp composes NFD Vietnamese in both combining orders', () {
      const nfd1 = 'Tie\u0302\u0301ng Vie\u0323\u0302t - Nguye\u0302\u0303n Hu\u031B\u0303u Tho\u0323';
      const nfd2 = 'Tie\u0301\u0302ng Vie\u0302\u0323t - Nguye\u0303\u0302n Hu\u0303\u031Bu Tho\u0323';
      expect(EspNavPayload.cleanUtf8ForEsp(nfd1), 'Tiếng Việt - Nguyễn Hữu Thọ');
      expect(EspNavPayload.cleanUtf8ForEsp(nfd2), 'Tiếng Việt - Nguyễn Hữu Thọ');
      expect(
        EspNavPayload.cleanUtf8ForEsp('Đường Nguyễn Trãi • Phở… — Quận 1'),
        'Đường Nguyễn Trãi - Phở... - Quận 1',
      );
    });

    test('truncateUtf8Bytes never splits multi-byte UTF-8 sequences', () {
      const sample = 'Đường Nguyễn Thị Minh Khai - Ngã Tư Sở';
      for (int limit = 0; limit <= 45; limit++) {
        final truncated = EspNavPayload.truncateUtf8Bytes(sample, limit);
        final encoded = utf8.encode(truncated);
        expect(encoded.length, lessThanOrEqualTo(limit));
        expect(utf8.decode(encoded), truncated);
      }
    });

    test('EspNavPayload.toJsonString stays <= 180 UTF-8 bytes while keeping accents', () {
      final payload = EspNavPayload(
        turnCode: 3,
        distanceToTurn: 240,
        totalDistance: 12300,
        etaMinutes: 27,
        streetName: 'Đường Nguyễn Cảnh Dị nối dài khu đô thị Đại Kim',
        currentSpeed: 38,
        stepIndex: 4,
        totalSteps: 12,
        songTitle: 'Nơi Này Có Anh - Phiên Bản Acoustic Đêm Khuya',
        songArtist: 'Sơn Tùng M-TP ft. Ban Nhạc',
      );

      final jsonStr = payload.toJsonString();
      final bytes = utf8.encode(jsonStr);
      expect(bytes.length, lessThanOrEqualTo(180));
      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
      expect((decoded['street'] as String).contains('Đường Nguyễn'), isTrue);
      expect((decoded['song'] as String).contains('Nơi Này Có'), isTrue);
    });
  });
}
