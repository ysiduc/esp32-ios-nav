import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import '../models/route_model.dart';

class PhotonService {
  // Public Photon Geocoding Server (or your self-hosted server: http://localhost:2322/api)
  static const String _photonBaseUrl = 'https://photon.komoot.io';

  /// Instant Autocomplete & Typo-Tolerant Search powered by Photon / Elasticsearch
  Future<List<MapPlace>> searchPlaces(String query, {LatLng? nearLocation}) async {
    if (query.trim().isEmpty) return [];

    try {
      var urlStr = '$_photonBaseUrl/api?q=${Uri.encodeComponent(query)}&limit=10&lang=vi';
      if (nearLocation != null) {
        // Bias search results towards current user location
        urlStr += '&lat=${nearLocation.latitude}&lon=${nearLocation.longitude}';
      }

      final response = await http.get(
        Uri.parse(urlStr),
        headers: {'User-Agent': 'ESP32_Photon_Navigator/1.0'},
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final features = data['features'] as List? ?? [];

        return features.map<MapPlace>((f) {
          final geometry = f['geometry'] as Map<String, dynamic>;
          final coords = geometry['coordinates'] as List;
          final lon = (coords[0] as num).toDouble();
          final lat = (coords[1] as num).toDouble();

          final props = f['properties'] as Map<String, dynamic>;
          final name = props['name'] as String? ?? props['street'] as String? ?? 'Địa điểm';
          final city = props['city'] as String? ?? props['state'] as String? ?? '';
          final country = props['country'] as String? ?? '';

          final displayParts = [name, props['street'], city, country]
              .where((e) => e != null && e.toString().trim().isNotEmpty)
              .toSet()
              .toList();

          return MapPlace(
            name: name,
            displayName: displayParts.join(', '),
            coordinate: LatLng(lat, lon),
            type: props['osm_value'] as String?,
          );
        }).toList();
      }
    } catch (_) {}
    return [];
  }

  /// Reverse Geocoding via Photon
  Future<String> reverseGeocode(LatLng location) async {
    try {
      final url = Uri.parse(
        '$_photonBaseUrl/reverse?lat=${location.latitude}&lon=${location.longitude}',
      );
      final response = await http.get(
        url,
        headers: {'User-Agent': 'ESP32_Photon_Navigator/1.0'},
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final features = data['features'] as List? ?? [];
        if (features.isNotEmpty) {
          final props = features.first['properties'] as Map<String, dynamic>;
          final name = props['name'] as String? ?? props['street'] as String? ?? '';
          final city = props['city'] as String? ?? '';
          if (name.isNotEmpty) {
            return city.isNotEmpty ? '$name, $city' : name;
          }
        }
      }
    } catch (_) {}
    return 'Vị trí (${location.latitude.toStringAsFixed(4)}, ${location.longitude.toStringAsFixed(4)})';
  }
}
