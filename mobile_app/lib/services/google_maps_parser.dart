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
      r'(\d+)\s*°\s*(\d+)\s*[\x27\u2032]?\s*([\d.]+)\s*[\x22\u2033]?\s*([NSns])\s*[,;\s\+]+\s*(\d+)\s*°\s*(\d+)\s*[\x27\u2032]?\s*([\d.]+)\s*[\x22\u2033]?\s*([EWew])',
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

    // 1. DMS Coordinate Match anywhere in the raw text
    final dmsCoord = parseDms(trimmed);
    if (dmsCoord != null) {
      return await _searchService.reverseGeocode(dmsCoord);
    }

    // 2. Direct Decimal Coordinate Match without URL (e.g. "21.0285, 105.8542" or "20.9848 105.8385")
    final textWithoutUrl = trimmed.replaceAll(RegExp(r'https?://[^\s]+'), '').trim();
    if (textWithoutUrl.isNotEmpty) {
      final coordRegex = RegExp(r'(\-?\d{1,2}\.\d{3,})[\s,;]+(\-?\d{1,3}\.\d{3,})');
      final match = coordRegex.firstMatch(textWithoutUrl);
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
    LatLng? extractedCoord = _extractCoordinateFromUrl(urlStr);

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

    // 6. If only a query or address exists in the URL (e.g. ?q=Trường+Tiểu+học+Nguyễn+Siêu or /place/Quán+Ăn/)
    final queryName = _extractPlaceNameFromUrl(urlStr) ??
        _extractQueryFromUrl(urlStr) ??
        (userPrefixName.isNotEmpty ? userPrefixName : null);

    if (queryName != null && queryName.isNotEmpty) {
      final resolvedPlace = await _resolveAddressQuery(queryName, userLocation: userLocation);
      if (resolvedPlace != null) return resolvedPlace;
    }

    return null;
  }

  /// Intelligently parse and resolve complex Google Maps shared address queries
  /// (e.g. "Trường Tiểu học Nguyễn Siêu (Nguyen Sieu Primary School), 38 P. Nguyễn Xuân Nham, Yên Hòa, Hà Nội 100000")
  Future<MapPlace?> _resolveAddressQuery(String rawQuery, {LatLng? userLocation}) async {
    var cleaned = rawQuery.replaceAll(RegExp(r'\([^)]*\)'), ' ');
    cleaned = cleaned.replaceAll(RegExp(r'\b\d{5,6}\b'), ' ');
    cleaned = cleaned.replaceAll(RegExp(r'\bP\.\s*', caseSensitive: false), 'Phố ');
    cleaned = cleaned.replaceAll(RegExp(r'\bĐ\.\s*', caseSensitive: false), 'Đường ');
    cleaned = cleaned.replaceAll(RegExp(r'\bQ\.\s*', caseSensitive: false), 'Quận ');
    cleaned = cleaned.replaceAll(RegExp(r'\bH\.\s*', caseSensitive: false), 'Huyện ');
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();

    final parts = cleaned.split(',').map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
    final candidates = <String>[];

    if (parts.length >= 3) {
      final place = parts.first;
      final street = parts[1];
      final ward = parts[2];
      final city = parts.last;

      candidates.add('$street, $ward, $city');
      candidates.add('$street, $city');
      candidates.add('$place, $ward, $city');
      candidates.add('$place, $city');
      candidates.add(street);
      candidates.add(place);
    } else if (parts.length == 2) {
      final place = parts.first;
      final city = parts.last;
      candidates.add('$place, $city');
      candidates.add(place);
    } else {
      candidates.add(cleaned);
    }

    for (final cand in candidates) {
      final results = await _searchService.searchPlaces(cand, nearLocation: userLocation);
      if (results.isNotEmpty) {
        final top = results.first;
        final finalName = parts.isNotEmpty ? parts.first : top.name;
        return MapPlace(
          name: finalName,
          displayName: '$finalName, ${top.displayName}',
          coordinate: top.coordinate,
          type: top.type,
          category: top.category,
          distanceMeters: top.distanceMeters,
        );
      }
    }

    return null;
  }

  /// Resolve HTTP redirects for shortlinks (including HTTP 3xx and meta refresh)
  Future<String> _resolveRedirects(String urlStr) async {
    final client = HttpClient();
    client.userAgent = 'curl/8.5.0'; // curl UA ensures clean HTTP 302 without Google consent walls

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

      // Check if response has meta refresh in HTML body
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
      }
      break;
    }
    client.close();
    return currentUrl;
  }

  /// Extract LatLng from various Google Maps URL formats
  LatLng? _extractCoordinateFromUrl(String url) {
    final decoded = Uri.decodeFull(url);

    // Priority 1: !3d/!4d or !4d/!3d (Exact Google Maps Place/POI/Pin Protobuf coordinates)
    final protoRegex = RegExp(r'(?:!3d(\-?\d{1,2}\.\d{3,})[^!]*!4d(\-?\d{1,3}\.\d{3,})|!4d(\-?\d{1,3}\.\d{3,})[^!]*!3d(\-?\d{1,2}\.\d{3,}))');
    final protoMatch = protoRegex.firstMatch(decoded);
    if (protoMatch != null) {
      final latStr = protoMatch.group(1) ?? protoMatch.group(4);
      final lonStr = protoMatch.group(2) ?? protoMatch.group(3);
      if (latStr != null && lonStr != null) {
        final lat = double.tryParse(latStr);
        final lon = double.tryParse(lonStr);
        if (lat != null && lon != null) return LatLng(lat, lon);
      }
    }

    // Priority 1b: !1d/!2d (Protobuf route pins)
    final proto12Regex = RegExp(r'(?:!1d(\-?\d{1,3}\.\d{3,})[^!]*!2d(\-?\d{1,2}\.\d{3,})|!2d(\-?\d{1,2}\.\d{3,})[^!]*!1d(\-?\d{1,3}\.\d{3,}))');
    final proto12Match = proto12Regex.firstMatch(decoded);
    if (proto12Match != null) {
      final lonStr = proto12Match.group(1) ?? proto12Match.group(4);
      final latStr = proto12Match.group(2) ?? proto12Match.group(3);
      if (latStr != null && lonStr != null) {
        final lat = double.tryParse(latStr);
        final lon = double.tryParse(lonStr);
        if (lat != null && lon != null) return LatLng(lat, lon);
      }
    }

    // Priority 2: ?q=21.028511,105.854212 or ?destination=... or ?ll=... or ?daddr=... (Explicit Pin/Query)
    final qRegex = RegExp(
      r'[?&](?:q|ll|destination|center|daddr|saddr|query|dest)=(?:loc:)?(\-?\d{1,2}\.\d{3,})[,\s\+]+(\-?\d{1,3}\.\d{3,})',
    );
    final qMatch = qRegex.firstMatch(decoded);
    if (qMatch != null) {
      final lat = double.tryParse(qMatch.group(1)!);
      final lon = double.tryParse(qMatch.group(2)!);
      if (lat != null && lon != null) return LatLng(lat, lon);
    }

    // Priority 3: /place/21.028511,105.854212 (Exact dropped pin in /place/ path before viewport @)
    final placeCoordRegex = RegExp(r'/place/(\-?\d{1,2}\.\d{3,})[,\s\+]+(\-?\d{1,3}\.\d{3,})');
    final placeMatch = placeCoordRegex.firstMatch(decoded);
    if (placeMatch != null) {
      final lat = double.tryParse(placeMatch.group(1)!);
      final lon = double.tryParse(placeMatch.group(2)!);
      if (lat != null && lon != null) return LatLng(lat, lon);
    }

    // Priority 4: /dir/.../21.028511,105.854212 (Destination coordinates in directions path)
    if (decoded.contains('/dir/')) {
      final dirSection = decoded.split('/@').first;
      final dirCoordRegex = RegExp(r'(\-?\d{1,2}\.\d{3,})[,\s\+]+(\-?\d{1,3}\.\d{3,})');
      final matches = dirCoordRegex.allMatches(dirSection).toList();
      if (matches.isNotEmpty) {
        final last = matches.last;
        final lat = double.tryParse(last.group(1)!);
        final lon = double.tryParse(last.group(2)!);
        if (lat != null && lon != null) return LatLng(lat, lon);
      }
    }

    // Priority 5: /search/21.028511,+105.854212 or /search/21.028511,105.854212
    final searchCoordRegex = RegExp(
      r'/search/(\-?\d{1,2}\.\d{3,})[,\s\+]+(\-?\d{1,3}\.\d{3,})',
    );
    final searchMatch = searchCoordRegex.firstMatch(decoded);
    if (searchMatch != null) {
      final lat = double.tryParse(searchMatch.group(1)!);
      final lon = double.tryParse(searchMatch.group(2)!);
      if (lat != null && lon != null) return LatLng(lat, lon);
    }

    // Priority 6: Embedded DMS in URL e.g. /place/20°59'07.8"N+105°50'29.4"E
    final dmsCoord = parseDms(decoded);
    if (dmsCoord != null) return dmsCoord;

    // Priority 7 (Fallback only): @21.028511,105.854212 (Camera viewport center)
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
