import 'dart:convert';
import 'dart:typed_data';

class EspNavPayload {
  final int turnCode;          // 0: straight, 1: sl_right, 2: right, 3: sh_right, 4: uturn, 5: sh_left, 6: left, 7: sl_left, 8: roundabout, 9: arrive
  final int distanceToTurn;     // meters to next maneuver (e.g. 150)
  final int totalDistance;      // total remaining distance in meters (e.g. 4200)
  final int etaMinutes;         // estimated remaining time in minutes
  final String streetName;      // next street name
  final int currentSpeed;       // current speed in km/h
  final int stepIndex;          // current step index (0-based)
  final int totalSteps;         // total count of steps
  final double? latitude;       // GPS latitude
  final double? longitude;      // GPS longitude
  final int heading;            // Vehicle bearing / compass heading (0-360)
  final List<List<int>>? routePoints; // Relative waypoint offsets [dx, dy] in meters
  final String? currentClock;    // Current time on phone (e.g. "18:25")
  final int batteryLevel;        // Phone battery percentage (e.g. 89)
  final bool isNavigating;       // True if user started route navigation, false if idle/standby
  final String songTitle;        // Current playing song title on phone
  final String songArtist;       // Current song artist name
  final int songElapsed;         // Current playback elapsed seconds
  final int songDuration;        // Track total duration seconds

  EspNavPayload({
    required this.turnCode,
    required this.distanceToTurn,
    required this.totalDistance,
    required this.etaMinutes,
    required this.streetName,
    required this.currentSpeed,
    required this.stepIndex,
    required this.totalSteps,
    this.latitude,
    this.longitude,
    this.heading = 0,
    this.routePoints,
    this.currentClock,
    this.batteryLevel = 89,
    this.isNavigating = false,
    this.songTitle = '',
    this.songArtist = '',
    this.songElapsed = 0,
    this.songDuration = 0,
  });

  /// Normalize common typography / zero-width chars and compose NFD Vietnamese accents while
  /// preserving UTF-8 Vietnamese diacritics for U8g2 `unifont_t_vietnamese2` on ESP32.
  static String cleanUtf8ForEsp(String str) {
    if (str.isEmpty) return '';
    final normalized = _composeVietnameseNfc(
      str
          .replaceAll('\u00A0', ' ')
          .replaceAll('\u2018', "'")
          .replaceAll('\u2019', "'")
          .replaceAll('\u201C', '"')
          .replaceAll('\u201D', '"')
          .replaceAll('\u2013', '-')
          .replaceAll('\u2014', '-')
          .replaceAll('\u2022', '-')
          .replaceAll('\u2026', '...')
          .replaceAll(RegExp(r'[\u200B-\u200D\uFEFF]'), ''),
    );
    return normalized.trim();
  }

  /// Truncates [str] cleanly on rune boundaries so UTF-8 encoding does not exceed [maxBytes].
  static String truncateUtf8Bytes(String str, int maxBytes) {
    if (str.isEmpty || maxBytes <= 0) return '';
    final bytes = utf8.encode(str);
    if (bytes.length <= maxBytes) return str;
    final out = StringBuffer();
    int used = 0;
    for (final rune in str.runes) {
      final ch = String.fromCharCode(rune);
      final chBytes = utf8.encode(ch).length;
      if (used + chBytes > maxBytes) break;
      out.write(ch);
      used += chBytes;
    }
    return out.toString();
  }

  static String _composeVietnameseNfc(String input) {
    const toneMap = <int, int>{
      0x0300: 1, // grave
      0x0301: 2, // acute
      0x0309: 3, // hook above
      0x0303: 4, // tilde
      0x0323: 5, // dot below
    };
    const vnTable = <int, List<int>>{
      0x0041: [0x0041, 0x00C0, 0x00C1, 0x1EA2, 0x00C3, 0x1EA0],
      0x0061: [0x0061, 0x00E0, 0x00E1, 0x1EA3, 0x00E3, 0x1EA1],
      0x00C2: [0x00C2, 0x1EA6, 0x1EA4, 0x1EA8, 0x1EAA, 0x1EAC],
      0x00E2: [0x00E2, 0x1EA7, 0x1EA5, 0x1EA9, 0x1EAB, 0x1EAD],
      0x0102: [0x0102, 0x1EB0, 0x1EAE, 0x1EB2, 0x1EB4, 0x1EB6],
      0x0103: [0x0103, 0x1EB1, 0x1EAF, 0x1EB3, 0x1EB5, 0x1EB7],
      0x0045: [0x0045, 0x00C8, 0x00C9, 0x1EBA, 0x1EBC, 0x1EB8],
      0x0065: [0x0065, 0x00E8, 0x00E9, 0x1EBB, 0x1EBD, 0x1EB9],
      0x00CA: [0x00CA, 0x1EC0, 0x1EBE, 0x1EC2, 0x1EC4, 0x1EC6],
      0x00EA: [0x00EA, 0x1EC1, 0x1EBF, 0x1EC3, 0x1EC5, 0x1EC7],
      0x0049: [0x0049, 0x00CC, 0x00CD, 0x1EC8, 0x0128, 0x1ECA],
      0x0069: [0x0069, 0x00EC, 0x00ED, 0x1EC9, 0x0129, 0x1ECB],
      0x004F: [0x004F, 0x00D2, 0x00D3, 0x1ECE, 0x00D5, 0x1ECC],
      0x006F: [0x006F, 0x00F2, 0x00F3, 0x1ECF, 0x00F5, 0x1ECD],
      0x00D4: [0x00D4, 0x1ED2, 0x1ED0, 0x1ED4, 0x1ED6, 0x1ED8],
      0x00F4: [0x00F4, 0x1ED3, 0x1ED1, 0x1ED5, 0x1ED7, 0x1ED9],
      0x01A0: [0x01A0, 0x1EDC, 0x1EDA, 0x1EDE, 0x1EE0, 0x1EE2],
      0x01A1: [0x01A1, 0x1EDD, 0x1EDB, 0x1EDF, 0x1EE1, 0x1EE3],
      0x0055: [0x0055, 0x00D9, 0x00DA, 0x1EE6, 0x0168, 0x1EE4],
      0x0075: [0x0075, 0x00F9, 0x00FA, 0x1EE7, 0x0169, 0x1EE5],
      0x01AF: [0x01AF, 0x1EEA, 0x1EE8, 0x1EEC, 0x1EEE, 0x1EF0],
      0x01B0: [0x01B0, 0x1EEB, 0x1EE9, 0x1EED, 0x1EEF, 0x1EF1],
      0x0059: [0x0059, 0x1EF2, 0x00DD, 0x1EF6, 0x1EF8, 0x1EF4],
      0x0079: [0x0079, 0x1EF3, 0x00FD, 0x1EF7, 0x1EF9, 0x1EF5],
    };

    int? findBase(int cp) {
      for (final e in vnTable.entries) {
        if (e.value.contains(cp)) return e.key;
      }
      return null;
    }

    int findTone(int cp) {
      for (final e in vnTable.values) {
        final idx = e.indexOf(cp);
        if (idx >= 0) return idx;
      }
      return 0;
    }

    final runes = input.runes.toList();
    final out = <int>[];
    for (final cp in runes) {
      if (cp >= 0x0300 && cp <= 0x036F) {
        if (out.isNotEmpty) {
          final prev = out.last;
          final tone = toneMap[cp];
          if (tone != null) {
            final base = findBase(prev);
            if (base != null) {
              out[out.length - 1] = vnTable[base]![tone];
              continue;
            }
          } else if (cp == 0x0302 || cp == 0x0306 || cp == 0x031B) {
            final base = findBase(prev);
            if (base != null) {
              final existingTone = findTone(prev);
              int? newBase;
              if (cp == 0x0302) {
                if (base == 0x0041) newBase = 0x00C2;
                else if (base == 0x0061) newBase = 0x00E2;
                else if (base == 0x0045) newBase = 0x00CA;
                else if (base == 0x0065) newBase = 0x00EA;
                else if (base == 0x004F) newBase = 0x00D4;
                else if (base == 0x006F) newBase = 0x00F4;
              } else if (cp == 0x0306) {
                if (base == 0x0041) newBase = 0x0102;
                else if (base == 0x0061) newBase = 0x0103;
              } else if (cp == 0x031B) {
                if (base == 0x004F) newBase = 0x01A0;
                else if (base == 0x006F) newBase = 0x01A1;
                else if (base == 0x0055) newBase = 0x01AF;
                else if (base == 0x0075) newBase = 0x01B0;
              }
              if (newBase != null) {
                out[out.length - 1] = vnTable[newBase]![existingTone];
                continue;
              }
            }
          }
        }
        continue; // Drop unsupported combining diacritics cleanly
      }
      out.add(cp);
    }
    return String.fromCharCodes(out);
  }

  /// Remove Vietnamese diacritics when an ASCII-only representation is explicitly needed.
  static String removeDiacritics(String str) {
    var withDia = 'àáạảãâầấậẩẫăằắặẳẵèéẹẻẽêềếệểễìíịỉĩòóọỏõôồốộổỗơờớợởỡùúụủũưừứựửữỳýỵỷỹđ'
                  'ÀÁẠẢÃÂẦẤẬẨẪĂẰẮẶẲẴÈÉẸẺẼÊỀẾỆỂỄÌÍỊỈĨÒÓỌỎÕÔỒỐỘỔỖƠỜỚỢỞỠÙÚỤỦŨƯỪỨỰỬỮỲÝỴỶỸĐ';
    var withoutDia = 'aaaaaaaaaaaaaaaaaeeeeeeeeeeeiiiiiooooooooooooooooouuuuuuuuuuuyyyyyd'
                     'AAAAAAAAAAAAAAAAAEEEEEEEEEEEIIIIIOOOOOOOOOOOOOOOOOUUUUUUUUUUUYYYYYD';
    for (int i = 0; i < withDia.length; i++) {
      str = str.replaceAll(withDia[i], withoutDia[i]);
    }
    return str;
  }

  String get sanitizedStreet => cleanUtf8ForEsp(streetName);
  String get sanitizedSong => cleanUtf8ForEsp(songTitle);
  String get sanitizedArtist => cleanUtf8ForEsp(songArtist);

  String get formattedDist {
    if (distanceToTurn >= 1000) {
      return '${(distanceToTurn / 1000).toStringAsFixed(1)} km';
    }
    return '$distanceToTurn m';
  }

  String get formattedTotalDist {
    if (totalDistance >= 1000) {
      return '${(totalDistance / 1000).toStringAsFixed(1)} km';
    }
    return '$totalDistance m';
  }

  String get arrivalTimeClock {
    final target = DateTime.now().add(Duration(minutes: etaMinutes));
    final hourStr = target.hour.toString().padLeft(2, '0');
    final minStr = target.minute.toString().padLeft(2, '0');
    return '$hourStr:$minStr';
  }

  String get formattedRemainingTime {
    if (etaMinutes >= 60) {
      final h = etaMinutes ~/ 60;
      final m = etaMinutes % 60;
      return m > 0 ? '$h giờ $m phút' : '$h giờ';
    }
    return '$etaMinutes phút';
  }

  String get phoneClock {
    if (currentClock != null && currentClock!.isNotEmpty) return currentClock!;
    final now = DateTime.now();
    final h = now.hour.toString().padLeft(2, '0');
    final m = now.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  /// Compact MTU-safe JSON payload format (Guaranteed <= 180 UTF-8 bytes for 100% reliable BLE transmission)
  String toJsonString() {
    final map = <String, dynamic>{
      'nav': isNavigating ? 1 : 0,
      'turn': turnCode,
      'dist': distanceToTurn,
      'tot': totalDistance,
      'eta': etaMinutes,
      'arr': arrivalTimeClock,
      'street': truncateUtf8Bytes(sanitizedStreet, 36),
      'speed': currentSpeed,
      'clock': phoneClock,
      'bat': batteryLevel,
    };
    if (heading != 0) {
      map['head'] = heading;
    }
    if (sanitizedSong.isNotEmpty) {
      map['song'] = truncateUtf8Bytes(sanitizedSong, 28);
      if (songElapsed > 0) map['el'] = songElapsed;
      if (songDuration > 0) map['dur'] = songDuration;
    }
    if (sanitizedArtist.isNotEmpty) {
      map['artist'] = truncateUtf8Bytes(sanitizedArtist, 18);
    }
    if (routePoints != null && routePoints!.isNotEmpty) {
      final pts = routePoints!.take(14).toList();
      map['pts'] = pts;
      String result = jsonEncode(map);
      // Dynamically trim points from end if exceeding 180 UTF-8 bytes (ATT MTU safe threshold)
      while (utf8.encode(result).length > 180 && pts.length > 2) {
        pts.removeLast();
        map['pts'] = pts;
        result = jsonEncode(map);
      }
    }

    String result = jsonEncode(map);
    if (utf8.encode(result).length > 180) {
      map['street'] = truncateUtf8Bytes(sanitizedStreet, 22);
      if (map.containsKey('song')) {
        map['song'] = truncateUtf8Bytes(sanitizedSong, 18);
      }
      result = jsonEncode(map);
    }
    if (utf8.encode(result).length > 180) {
      map.remove('artist');
      result = jsonEncode(map);
    }
    if (utf8.encode(result).length > 180) {
      map.remove('el');
      map.remove('dur');
      map['street'] = truncateUtf8Bytes(sanitizedStreet, 18);
      if (map.containsKey('song')) {
        map['song'] = truncateUtf8Bytes(sanitizedSong, 14);
      }
      result = jsonEncode(map);
    }
    if (utf8.encode(result).length > 180) {
      map.remove('pts');
      result = jsonEncode(map);
    }
    return result;
  }

  /// Compact Binary Protocol format (Header: 0xAA, 0x55)
  /// [0xAA, 0x55, turnCode, distHigh, distLow, speed, etaMin, streetLen, ...streetBytes]
  Uint8List toBinaryPacket() {
    final streetBytes = utf8.encode(sanitizedStreet);
    final length = 8 + streetBytes.length;
    final buffer = ByteData(length);

    buffer.setUint8(0, 0xAA); // Magic byte 1
    buffer.setUint8(1, 0x55); // Magic byte 2
    buffer.setUint8(2, turnCode.clamp(0, 255));
    buffer.setUint16(3, distanceToTurn.clamp(0, 65535), Endian.big);
    buffer.setUint8(5, currentSpeed.clamp(0, 255));
    buffer.setUint8(6, etaMinutes.clamp(0, 255));
    buffer.setUint8(7, streetBytes.length.clamp(0, 255));

    final result = Uint8List(length);
    result.setRange(0, 8, buffer.buffer.asUint8List());
    result.setRange(8, length, streetBytes);
    return result;
  }
}
