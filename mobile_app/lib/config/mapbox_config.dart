/// Map Configuration (MapTiler + OpenStreetMap)
/// MapTiler provides vector tiles compatible with MapLibre GL
class MapboxConfig {
  // ============================================================
  // MAPTILER API KEY
  // ============================================================
  static const String maptilerApiKey = 'dtGJ2HGvyxQPKNlHznvY';

  // Fallback / legacy Mapbox token (optional)
  static const String accessToken = '';

  // ============================================================
  // MapTiler Vector Style URLs (Native GPU rendering via MapLibre)
  // ============================================================
  static const String styleStreets =
      'https://api.maptiler.com/maps/streets-v2/style.json?key=$maptilerApiKey';
  static const String styleSatelliteStreets =
      'https://api.maptiler.com/maps/hybrid/style.json?key=$maptilerApiKey';
  static const String styleNavigationNight =
      'https://api.maptiler.com/maps/streets-v2-dark/style.json?key=$maptilerApiKey';
  static const String styleNavigationDay =
      'https://api.maptiler.com/maps/streets-v2/style.json?key=$maptilerApiKey';
  static const String styleDark =
      'https://api.maptiler.com/maps/streets-v2-dark/style.json?key=$maptilerApiKey';
  static const String styleOutdoors =
      'https://api.maptiler.com/maps/outdoor-v2/style.json?key=$maptilerApiKey';

  // ============================================================
  // MapTiler Geocoding API Endpoints
  // ============================================================
  static String geocodingUrl({
    required String query,
    double? proximityLng,
    double? proximityLat,
    int limit = 10,
  }) {
    var url =
        'https://api.maptiler.com/geocoding/${Uri.encodeComponent(query)}.json?key=$maptilerApiKey&language=vi&country=vn&limit=$limit';
    if (proximityLng != null && proximityLat != null) {
      url += '&proximity=$proximityLng,$proximityLat';
    }
    return url;
  }

  // Directions endpoint (if using Mapbox token, otherwise OSRM handles routing)
  static String directionsUrl({
    required String profile,
    required double startLng,
    required double startLat,
    required double endLng,
    required double endLat,
    bool steps = true,
    String geometries = 'geojson',
    String overview = 'full',
    bool alternatives = true,
  }) {
    return 'https://api.mapbox.com/directions/v5/mapbox/$profile/$startLng,$startLat;$endLng,$endLat'
        '?steps=$steps&geometries=$geometries&overview=$overview'
        '&alternatives=$alternatives&language=vi&access_token=$accessToken';
  }

  /// True if a real MapTiler or Mapbox token has been configured
  static bool get isConfigured =>
      maptilerApiKey.isNotEmpty && !maptilerApiKey.startsWith('YOUR_');
}
