/// Cấu hình Goong Map (goong.io)
/// Goong cung cấp bản đồ và dữ liệu dẫn đường chuẩn nhất cho Việt Nam.
class GoongConfig {
  // ============================================================
  // 1. GOONG MAP TILES KEY (Hiển thị bản đồ MapLibre GL)
  // Lấy tại: https://account.goong.io/keys -> Mục MapTiles Key
  // ============================================================
  static String maptilesKey = 'i8CAxB85uuHXj0YbYO4YM7SjkqLmwdvChoQK36ds';

  // ============================================================
  // 2. GOONG REST API KEY (Tìm kiếm địa điểm, Autocomplete & Dẫn đường)
  // Lấy tại: https://account.goong.io/keys -> Mục API Key
  // ============================================================
  static String restApiKey = 'LyG3pKyU88XZHKpKudhyUoG9jsB5i8twzm8vXfIq';

  // ============================================================
  // Goong MapLibre Style URLs (GPU Vector Rendering)
  // ============================================================
  static String get styleStreets =>
      'https://tiles.goong.io/assets/goong_map_web.json?api_key=$maptilesKey';

  static String get styleDark =>
      'https://tiles.goong.io/assets/goong_map_dark.json?api_key=$maptilesKey';

  static String get styleNavigationDay =>
      'https://tiles.goong.io/assets/navigation_day.json?api_key=$maptilesKey';

  static String get styleNavigationNight =>
      'https://tiles.goong.io/assets/navigation_night.json?api_key=$maptilesKey';

  // ============================================================
  // REST API Endpoints
  // ============================================================
  static const String placeAutoCompleteUrl = 'https://rsapi.goong.io/Place/AutoComplete';
  static const String placeDetailUrl = 'https://rsapi.goong.io/Place/Detail';
  static const String geocodeUrl = 'https://rsapi.goong.io/geocode';
  static const String directionUrl = 'https://rsapi.goong.io/Direction';

  /// Kiểm tra xem người dùng đã điền key hay chưa
  static bool get hasMapTilesKey =>
      maptilesKey.trim().isNotEmpty && !maptilesKey.startsWith('YOUR_');

  static bool get hasRestApiKey =>
      restApiKey.trim().isNotEmpty && !restApiKey.startsWith('YOUR_');

  static bool get isConfigured => hasMapTilesKey && hasRestApiKey;
}
