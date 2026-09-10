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
  final int batteryLevel;       // Phone Battery level (0-100)

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
    this.batteryLevel = 100,
  });

  /// Remove Vietnamese diacritics so standard ESP32 display fonts (U8g2 / Adafruit / TFT_eSPI)
  /// can render names cleanly without unprintable character glitches
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

  String get sanitizedStreet => removeDiacritics(streetName);

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

  /// JSON payload format for easy parsing with ArduinoJson on ESP32
  String toJsonString() {
    final map = {
      'turn': turnCode,
      'dist': distanceToTurn,
      'tot_dist': totalDistance,
      'eta': etaMinutes,
      'street': sanitizedStreet,
      'speed': currentSpeed,
      'step': stepIndex + 1,
      'tot_steps': totalSteps,
      'arrival': arrivalTimeClock,
      'lat': latitude != null ? double.parse(latitude!.toStringAsFixed(6)) : null,
      'lng': longitude != null ? double.parse(longitude!.toStringAsFixed(6)) : null,
      'head': heading,
      'bat': batteryLevel,
    };
    return jsonEncode(map);
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
