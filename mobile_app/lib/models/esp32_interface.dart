enum ESP32Interface {
  customStatic,
  carbonSport,
  cyberRadar,
  retroMac,
  cassetteWave,
  comicStrip,
}

extension ESP32InterfaceExt on ESP32Interface {
  String get id {
    switch (this) {
      case ESP32Interface.customStatic:
        return 'customStatic';
      case ESP32Interface.carbonSport:
        return 'carbonSport';
      case ESP32Interface.cyberRadar:
        return 'cyberRadar';
      case ESP32Interface.retroMac:
        return 'retroMac';
      case ESP32Interface.cassetteWave:
        return 'cassetteWave';
      case ESP32Interface.comicStrip:
        return 'comicStrip';
    }
  }

  String get displayName {
    switch (this) {
      case ESP32Interface.customStatic:
        return 'Màn Chờ Mặc Định (Waybar)';
      case ESP32Interface.carbonSport:
        return 'Sunflower Carbon HUD';
      case ESP32Interface.cyberRadar:
        return 'Cyberpunk Neon Radar';
      case ESP32Interface.retroMac:
        return 'Retro Macintosh OS';
      case ESP32Interface.cassetteWave:
        return 'Cassette Retro Wave';
      case ESP32Interface.comicStrip:
        return 'Comic Strip Manga';
    }
  }

  String get subtitle {
    switch (this) {
      case ESP32Interface.customStatic:
        return 'Ảnh nền tùy chọn + Waybar Hybrid';
      case ESP32Interface.carbonSport:
        return 'Đồng hồ vàng cam, hoa hướng dương ấm áp';
      case ESP32Interface.cyberRadar:
        return 'Lưới Neon Cyberpunk, Radar quét số';
      case ESP32Interface.retroMac:
        return 'Giao diện Mac OS 8-bit hoài cổ';
      case ESP32Interface.cassetteWave:
        return 'Băng cassette thập niên 80s, mặt trời synthwave';
      case ESP32Interface.comicStrip:
        return 'Phác thảo Manga 2D viền đậm, bóng thoại vui nhộn';
    }
  }

  static ESP32Interface fromIndex(int index) {
    if (index >= 0 && index < ESP32Interface.values.length) {
      return ESP32Interface.values[index];
    }
    return ESP32Interface.customStatic;
  }

  static ESP32Interface fromId(String? id) {
    for (final val in ESP32Interface.values) {
      if (val.id == id || val.name == id) return val;
    }
    return ESP32Interface.customStatic;
  }
}
