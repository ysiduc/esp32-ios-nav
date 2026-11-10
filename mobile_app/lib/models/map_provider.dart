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
        return 'Apple Maps (Native iOS)';
      case MapProvider.goong:
        return 'Goong API (Key riêng)';
    }
  }

  String get shortName {
    switch (this) {
      case MapProvider.appleMaps:
        return 'Apple Maps';
      case MapProvider.goong:
        return 'Goong Map';
    }
  }

  String get description {
    switch (this) {
      case MapProvider.appleMaps:
        return 'Apple MapKit gốc trên iOS: Tìm kiếm & Chỉ đường miễn phí 100%, không giới hạn lượt dùng.';
      case MapProvider.goong:
        return 'Tối ưu tuyến đường xe máy, ngõ hẻm Việt Nam (Dùng quota API key riêng của bạn).';
    }
  }

  static MapProvider fromId(String? id) {
    if (id == 'goong') {
      return MapProvider.goong;
    }
    return MapProvider.appleMaps; // Mặc định dùng Apple Maps
  }
}

