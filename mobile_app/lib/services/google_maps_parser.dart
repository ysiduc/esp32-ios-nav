import 'dart:convert';
import 'dart:io';
import 'package:latlong2/latlong.dart';
import '../models/route_model.dart';
import 'search_service.dart';

class GoogleMapsParser {
  final SearchService _searchService = SearchService();

  /// Parse DMS (Degrees Minutes Seconds) format into decimal LatLng
  /// Example: 20°59'07.8"N 105°50'29.4"E or 20°59'7.8"N, 105°50'29.4"E
  static LatLng? parseDms(String text) {
    final dmsRegex = RegExp(
      r'(\d+)\s*°\s*(\d+)\s*[\x27\u2032]?\s*([\d.]+)\s*[\x22\u2033]?\s*([NSns])\s*[,;\s]+\s*(\d+)\s*°\s*(\d+)\s*[\x27\u2032]?\s*([\d.]+)\s*[\x22\u2033]?\s*([EWew])',
    );
    final m = dmsRegex.firstMatch(text);
    if (m != null) {
      final degLat = double.tryParse(m.group(1)!);
      final minLat = double.tryParse(m.group(2)!);
      final secLat = double.tryParse(m.group(3)!);
      final dirLat = m.group(4)!.toUpperCase();

      final degLon = double.tryParse(m.group(5)!);
      final minLon = double.tryParse(m.group(6)!);
      final secLon = double.tryParse(m.group(7)!);
      final dirLon = m.group(8)!.toUpperCase();

      if (degLat != null && minLat != null && secLat != null &&
          degLon != null && minLon != null && secLon != null) {
        double lat = degLat + (minLat / 60.0) + (secLat / 3600.0);
        if (dirLat == 'S') lat = -lat;

        double lon = degLon + (minLon / 60.0) + (secLon / 3600.0);
        if (dirLon == 'W') lon = -lon;

        if (lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180) {
          return LatLng(lat, lon);
        }
      }
    }
    return null;
  }

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

    // DMS format: 20°59'07.8"N 105°50'29.4"E
    if (parseDms(text) != null) return true;

    // Coordinate pattern: 21.0285, 105.8542 or 21.0285 105.8542
    final coordRegex = RegExp(r'(\-?\d{1,2}\.\d{3,})[\s,;]+(\-?\d{1,3}\.\d{3,})');
    return coordRegex.hasMatch(text);
  }

  /// Parse Google Maps link or shared text or coordinates into a MapPlace
  Future<MapPlace?> parseInput(String input, {LatLng? userLocation}) async {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;

    // 1. DMS Coordinate Match
    final dmsCoord = parseDms(trimmed);
    if (dmsCoord != null) {
      return await _searchService.reverseGeocode(dmsCoord);
    }

    // 2. Direct Decimal Coordinate Match (e.g. "21.0285, 105.8542" or "20.9848 105.8385")
    if (!trimmed.toLowerCase().startsWith('http://') && !trimmed.toLowerCase().startsWith('https://')) {
      final coordRegex = RegExp(r'^\s*(\-?\d{1,2}\.\d{3,})[\s,;]+(\-?\d{1,3}\.\d{3,})\s*$');
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

    // 3. Extract URL and leading/trailing title from text
    final urlRegex = RegExp(r'https?://[^\s]+');
    final urlMatch = urlRegex.firstMatch(trimmed);
    if (urlMatch == null) {
      // If not a URL, fallback to regular search
      final searchList = await _searchService.searchPlaces(trimmed, nearLocation: userLocation);
      return searchList.isNotEmpty ? searchList.first : null;
    }

    String urlStr = urlMatch.group(0)!;
    String userPrefixName = trimmed.replaceFirst(urlStr, '').replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim();

    // 4. Resolve Shortlinks & Redirects if it's a short URL
    final isShortLink = urlStr.contains('maps.app.goo.gl') ||
        urlStr.contains('goo.gl') ||
        urlStr.contains('bit.ly') ||
        urlStr.contains('t.co') ||
        urlStr.length < 50;

    if (isShortLink) {
      try {
        final finalUrl = await _resolveRedirects(urlStr);
        if (finalUrl.isNotEmpty) {
          urlStr = finalUrl;
        }
      } catch (_) {}
    }

    // 5. Extract Coordinates from Google Maps URL
    final extractedCoord = _extractCoordinateFromUrl(urlStr);
    if (extractedCoord != null) {
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

    // 6. If only a query exists in the URL (e.g. ?q=Landmark+72 or /place/Quán+Ăn/)
    final queryName = _extractPlaceNameFromUrl(urlStr) ??
        _extractQueryFromUrl(urlStr) ??
        (userPrefixName.isNotEmpty ? userPrefixName : null);

    if (queryName != null && queryName.isNotEmpty) {
      final list = await _searchService.searchPlaces(queryName, nearLocation: userLocation);
      if (list.isNotEmpty) return list.first;
    }

    return null;
  }

  /// Resolve HTTP redirects for shortlinks (including HTTP 3xx and meta refresh)
  Future<String> _resolveRedirects(String urlStr) async {
    final client = HttpClient();
    client.userAgent =
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

    String currentUrl = urlStr;
    for (int redirectCount = 0; redirectCount < 8; redirectCount++) {
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
          continue;
        }
      }

      // Check if response has meta refresh or JS redirect in HTML body
      final contentType = response.headers.contentType?.mimeType ?? '';
      if (contentType.contains('html') || contentType.contains('text')) {
        final body = await response.transform(utf8.decoder).join();
        final metaRegex = RegExp(
          r'<meta[^>]*content=["\x27]\d+;\s*url=([^"\x27>]+)["\x27]',
          caseSensitive: false,
        );
        final metaMatch = metaRegex.firstMatch(body);
        if (metaMatch != null) {
          final target = metaMatch.group(1)!.trim();
          currentUrl = target.startsWith('http') ? target : uri.resolve(target).toString();
          continue;
        }

        final jsRegex = RegExp(r'window\.location(?:\.href|\.replace)?\s*=\s*["\x27]([^"\x27]+)["\x27]');
        final jsMatch = jsRegex.firstMatch(body);
        if (jsMatch != null) {
          final target = jsMatch.group(1)!.trim();
          currentUrl = target.startsWith('http') ? target : uri.resolve(target).toString();
          continue;
        }
      }
      break;
    }
    client.close();
    return currentUrl;
  }

  /// Extract LatLng from various Google Maps URL formats
  LatLng? _extractCoordinateFromUrl(String url) {
    final decoded = Uri.decodeFull(url);

    // Priority 1: !3d21.028511!4d105.854212 (Exact Google Maps Place/POI/Pin Protobuf coordinates)
    final protoRegex = RegExp(r'!3d(\-?\d{1,2}\.\d{3,})!4d(\-?\d{1,3}\.\d{3,})');
    final protoMatch = protoRegex.firstMatch(decoded);
    if (protoMatch != null) {
      final lat = double.tryParse(protoMatch.group(1)!);
      final lon = double.tryParse(protoMatch.group(2)!);
      if (lat != null && lon != null) return LatLng(lat, lon);
    }

    // Priority 2: ?q=21.028511,105.854212 or ?destination=... or ?ll=... or ?daddr=... (Explicit Pin/Query)
    final qRegex = RegExp(
      r'[?&](?:q|ll|destination|center|daddr|saddr|query)=(\-?\d{1,2}\.\d{3,})[,\s\+]+(\-?\d{1,3}\.\d{3,})',
    );
    final qMatch = qRegex.firstMatch(decoded);
    if (qMatch != null) {
      final lat = double.tryParse(qMatch.group(1)!);
      final lon = double.tryParse(qMatch.group(2)!);
      if (lat != null && lon != null) return LatLng(lat, lon);
    }

    // Priority 3: /search/21.028511,+105.854212 or /search/21.028511,105.854212
    final searchCoordRegex = RegExp(
      r'/search/(\-?\d{1,2}\.\d{3,})[,\s\+]+(\-?\d{1,3}\.\d{3,})',
    );
    final searchMatch = searchCoordRegex.firstMatch(decoded);
    if (searchMatch != null) {
      final lat = double.tryParse(searchMatch.group(1)!);
      final lon = double.tryParse(searchMatch.group(2)!);
      if (lat != null && lon != null) return LatLng(lat, lon);
    }

    // Priority 4: Embedded DMS in URL e.g. /place/20°59'07.8"N+105°50'29.4"E
    final dmsCoord = parseDms(decoded);
    if (dmsCoord != null) return dmsCoord;

    // Priority 5 (Fallback only): @21.028511,105.854212 (Camera viewport center)
    final atRegex = RegExp(r'@(\-?\d{1,2}\.\d{3,}),(\-?\d{1,3}\.\d{3,})');
    final atMatch = atRegex.firstMatch(decoded);
    if (atMatch != null) {
      final lat = double.tryParse(atMatch.group(1)!);
      final lon = double.tryParse(atMatch.group(2)!);
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
      // Filter out raw coordinates from place name (e.g. 21.0285,105.8542)
      if (RegExp(r'^\-?\d{1,2}\.\d+').hasMatch(raw)) return null;
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
      if (RegExp(r'^\-?\d{1,2}\.\d+').hasMatch(raw)) return null;
      return raw.replaceAll('+', ' ').trim();
    }
    return null;
  }
}
