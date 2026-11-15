/// Nhà cung cấp dịch vụ Bản đồ & Dẫn đường
enum MapProvider {
  appleMaps,
  goong,
}

extension MapProviderExtension on MapProvider {
  String get id {
    switch (this) {
      case MapProvider.appleMaps:
        return 'apple_maps';
      case MapProvider.goong:
        return 'goong';
    }
  }

  String get displayName {
    switch (this) {
      case MapProvider.appleMaps:
        return 'Goong Search + Apple Maps Routing';
      case MapProvider.goong:
        return 'Goong API Toàn diện (Key riêng)';
    }
  }

  String get shortName {
    switch (this) {
      case MapProvider.appleMaps:
        return 'Goong + Apple Maps';
      case MapProvider.goong:
        return 'Goong Map';
    }
  }

  String get description {
    switch (this) {
      case MapProvider.appleMaps:
        return 'Tìm địa điểm bằng Goong Map chuẩn VN + Tính lộ trình & Dẫn đường Realtime bằng Apple Maps (iOS).';
      case MapProvider.goong:
        return 'Dùng Goong API cho cả Tìm kiếm và Tính lộ trình (tiêu tốn quota Direction API).';
    }
  }

  static MapProvider fromId(String? id) {
    if (id == 'goong') {
      return MapProvider.goong;
    }
    return MapProvider.appleMaps; // Mặc định dùng Apple Maps
  }
}

