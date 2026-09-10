import 'dart:io';
import 'package:latlong2/latlong.dart';
import '../models/route_model.dart';
import 'search_service.dart';

class GoogleMapsParser {
  final SearchService _searchService = SearchService();

  /// Check if an input text contains a Google Maps link or coordinates
  static bool isGoogleMapsOrCoordInput(String text) {
    final t = text.toLowerCase().trim();
    if (t.contains('maps.app.goo.gl') ||
        t.contains('goo.gl/maps') ||
        t.contains('google.com/maps') ||
        t.contains('maps.google.com') ||
        t.contains('geo:')) {
      return true;
    }

    // Coordinate pattern: 21.0285, 105.8542
    final coordRegex = RegExp(r'(\-?\d{1,2}\.\d{3,})\s*,\s*(\-?\d{1,3}\.\d{3,})');
    return coordRegex.hasMatch(text);
  }

  /// Parse Google Maps link or shared text or coordinates into a MapPlace
  Future<MapPlace?> parseInput(String input, {LatLng? userLocation}) async {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;

    // 1. Direct Coordinate Match (only when input is not a URL, e.g. "21.0285, 105.8542" or "20.9848, 105.8385")
    if (!trimmed.toLowerCase().startsWith('http://') && !trimmed.toLowerCase().startsWith('https://')) {
      final coordRegex = RegExp(r'^\s*(\-?\d{1,2}\.\d{3,})\s*,\s*(\-?\d{1,3}\.\d{3,})\s*$');
      final match = coordRegex.firstMatch(trimmed);
      if (match != null) {
        final lat = double.tryParse(match.group(1)!);
        final lon = double.tryParse(match.group(2)!);
        if (lat != null && lon != null && lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180) {
          final coord = LatLng(lat, lon);
          return await _searchService.reverseGeocode(coord);
        }
      }
    }

    // 2. Extract URL and leading/trailing title from text (users often share "Quán Ăn Ngon https://maps.app.goo.gl/...")
    final urlRegex = RegExp(r'https?://[^\s]+');
    final urlMatch = urlRegex.firstMatch(trimmed);
    if (urlMatch == null) {
      // If not a URL, fallback to regular search
      final searchList = await _searchService.searchPlaces(trimmed, nearLocation: userLocation);
      return searchList.isNotEmpty ? searchList.first : null;
    }

    String urlStr = urlMatch.group(0)!;
    String userPrefixName = trimmed.replaceFirst(urlStr, '').trim();

    // 3. Resolve Shortlinks & Redirects if it's a short URL
    final isShortLink = urlStr.contains('maps.app.goo.gl') ||
        urlStr.contains('goo.gl') ||
        urlStr.contains('bit.ly') ||
        urlStr.contains('t.co') ||
        urlStr.length < 45;

    if (isShortLink) {
      try {
        final finalUrl = await _resolveRedirects(urlStr);
        if (finalUrl.isNotEmpty) {
          urlStr = finalUrl;
        }
      } catch (_) {}
    }

    // 4. Extract Coordinates from Google Maps URL
    final extractedCoord = _extractCoordinateFromUrl(urlStr);
    if (extractedCoord != null) {
      // Try to extract place name from user text or URL path (e.g. /place/Hồ+Hoàn+Kiếm/)
      final urlPlaceName = _extractPlaceNameFromUrl(urlStr);
      final placeName = userPrefixName.isNotEmpty
          ? userPrefixName
          : (urlPlaceName != null && urlPlaceName.isNotEmpty ? urlPlaceName : null);

      final reversePlace = await _searchService.reverseGeocode(extractedCoord);

      if (placeName != null && placeName.isNotEmpty) {
        return MapPlace(
          name: placeName,
          displayName: '$placeName, ${reversePlace.displayName}',
          coordinate: extractedCoord,
          type: reversePlace.type,
          category: reversePlace.category,
        );
      }
      return reversePlace;
    }

    // 5. If only a query exists in the URL (e.g. ?q=Landmark+72)
    final queryName = _extractQueryFromUrl(urlStr) ?? (userPrefixName.isNotEmpty ? userPrefixName : null);
    if (queryName != null && queryName.isNotEmpty) {
      final list = await _searchService.searchPlaces(queryName, nearLocation: userLocation);
      if (list.isNotEmpty) return list.first;
    }

    return null;
  }

  /// Resolve HTTP redirects for shortlinks
  Future<String> _resolveRedirects(String urlStr) async {
    final client = HttpClient();
    client.userAgent = 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15';

    String currentUrl = urlStr;
    for (int redirectCount = 0; redirectCount < 6; redirectCount++) {
      final uri = Uri.tryParse(currentUrl);
      if (uri == null) break;

      final request = await client.getUrl(uri);
      request.followRedirects = false;
      final response = await request.close();

      if (response.isRedirect) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location != null && location.isNotEmpty) {
          if (location.startsWith('http')) {
            currentUrl = location;
          } else {
            currentUrl = uri.resolve(location).toString();
          }
        } else {
          break;
        }
      } else {
        break;
      }
    }
    client.close();
    return currentUrl;
  }

  /// Extract LatLng from various Google Maps URL formats
  LatLng? _extractCoordinateFromUrl(String url) {
    final decoded = Uri.decodeFull(url);

    // Format A: @21.028511,105.854212
    final atRegex = RegExp(r'@(\-?\d{1,2}\.\d{3,}),(\-?\d{1,3}\.\d{3,})');
    final atMatch = atRegex.firstMatch(decoded);
    if (atMatch != null) {
      final lat = double.tryParse(atMatch.group(1)!);
      final lon = double.tryParse(atMatch.group(2)!);
      if (lat != null && lon != null) return LatLng(lat, lon);
    }

    // Format B: !3d21.028511!4d105.854212 (Google Maps Protobuf data string)
    final protoRegex = RegExp(r'!3d(\-?\d{1,2}\.\d{3,})!4d(\-?\d{1,3}\.\d{3,})');
    final protoMatch = protoRegex.firstMatch(decoded);
    if (protoMatch != null) {
      final lat = double.tryParse(protoMatch.group(1)!);
      final lon = double.tryParse(protoMatch.group(2)!);
      if (lat != null && lon != null) return LatLng(lat, lon);
    }

    // Format C: ?q=21.028511,105.854212 or ?ll=21.028511,105.854212
    final qRegex = RegExp(r'[?&](?:q|ll|destination|center)=(\-?\d{1,2}\.\d{3,}),(\-?\d{1,3}\.\d{3,})');
    final qMatch = qRegex.firstMatch(decoded);
    if (qMatch != null) {
      final lat = double.tryParse(qMatch.group(1)!);
      final lon = double.tryParse(qMatch.group(2)!);
      if (lat != null && lon != null) return LatLng(lat, lon);
    }

    // Format D: /place/.../data=...!8m2!3d21.0285!4d105.8542
    final dataRegex = RegExp(r'!3d(\-?\d{1,2}\.\d{3,})!4d(\-?\d{1,3}\.\d{3,})');
    final dataMatch = dataRegex.firstMatch(decoded);
    if (dataMatch != null) {
      final lat = double.tryParse(dataMatch.group(1)!);
      final lon = double.tryParse(dataMatch.group(2)!);
      if (lat != null && lon != null) return LatLng(lat, lon);
    }

    return null;
  }

  String? _extractPlaceNameFromUrl(String url) {
    final decoded = Uri.decodeFull(url);
    final placeRegex = RegExp(r'/place/([^/@?]+)');
    final match = placeRegex.firstMatch(decoded);
    if (match != null) {
      final raw = match.group(1)!;
      return raw.replaceAll('+', ' ').trim();
    }
    return null;
  }

  String? _extractQueryFromUrl(String url) {
    final decoded = Uri.decodeFull(url);
    final qRegex = RegExp(r'[?&]q=([^&]+)');
    final match = qRegex.firstMatch(decoded);
    if (match != null) {
      final raw = match.group(1)!;
      return raw.replaceAll('+', ' ').trim();
    }
    return null;
  }
}
