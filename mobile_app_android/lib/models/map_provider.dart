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
        return 'Chế độ tự động (Khuyên dùng)';
      case MapProvider.goong:
        return 'Máy chủ Việt Nam (Dự phòng)';
    }
  }

  String get shortName {
    switch (this) {
      case MapProvider.appleMaps:
        return 'Tự động';
      case MapProvider.goong:
        return 'Máy chủ VN';
    }
  }

  String get description {
    switch (this) {
      case MapProvider.appleMaps:
        return 'Tìm địa điểm chuẩn Việt Nam, tính lộ trình & dẫn đường thời gian thực.';
      case MapProvider.goong:
        return 'Dùng máy chủ bản đồ Việt Nam cho cả tìm kiếm và tính lộ trình (tiêu tốn lượt gọi API).';
    }
  }

  static MapProvider fromId(String? id) {
    if (id == 'goong') {
      return MapProvider.goong;
    }
    return MapProvider.appleMaps; // Mặc định dùng Apple Maps
  }
}

