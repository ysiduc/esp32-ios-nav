import 'dart:convert';
import 'dart:io';
import 'package:latlong2/latlong.dart';
import '../models/route_model.dart';
import 'goong_service.dart';
import 'search_service.dart';

class GoogleMapsParser {
  final SearchService _searchService = SearchService();

  /// Parse DMS (Degrees Minutes Seconds) format into decimal LatLng
  /// Supports English (N, S, E, W) and Vietnamese (B, N, Đ, T)
  /// Example: 20°59'07.8"N 105°50'29.4"E or 21°01'42.6"B 105°51'15.5"Đ
  static LatLng? parseDms(String text) {
    // 1. Vietnamese & English DMS pattern:
    // Lat: digits° minutes' seconds" [N/S/B/Nam]
    // Lon: digits° minutes' seconds" [E/W/Đ/Dong/T/Tay]
    final dmsRegex = RegExp(
      r'(\d+)\s*°\s*(\d+)\s*[\x27\u2032]?\s*([\d.]+)\s*[\x22\u2033]?\s*([NSBĐTEWnsbđtew])\b'
      r'[,;\s\+]+'
      r'(\d+)\s*°\s*(\d+)\s*[\x27\u2032]?\s*([\d.]+)\s*[\x22\u2033]?\s*([NSBĐTEWnsbđtew])\b',
      caseSensitive: false,
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
        // 'S' in English is South. 'N' in Vietnamese could be Nam (South) if paired with 'B' (Bac),
        // but Vietnam is strictly North (+8 to +24). If S or clearly South, invert:
        if (dirLat == 'S') lat = -lat;

        double lon = degLon + (minLon / 60.0) + (secLon / 3600.0);
        // 'W' or 'T' (Tây) is West
        if (dirLon == 'W' || dirLon == 'T') lon = -lon;

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

    // DMS format: 20°59'07.8"N 105°50'29.4"E or 21°01'42.6"B 105°51'15.5"Đ
    if (parseDms(text) != null) return true;

    // Coordinate pattern: 21.0285, 105.8542 or 21.0285 105.8542
    final coordRegex = RegExp(r'(\-?\d{1,2}\.\d{3,})[\s,;]+(\-?\d{1,3}\.\d{3,})');
    if (coordRegex.hasMatch(text)) return true;

    // Plus code pattern: e.g. 7P6V+2X Ha Noi or 2R4M+8Q Cau Giay
    final plusCodeRegex = RegExp(r'\b[23456789CFGHJMPQRVWX]{4,8}\+[23456789CFGHJMPQRVWX]{2,3}\b');
    return plusCodeRegex.hasMatch(text);
  }

  /// Clean Vietnamese Google Maps prefixes like "Đã ghim", "Gần", "Dropped pin"
  static String cleanGoogleMapsPrefix(String text) {
    var s = text.trim();
    s = s.replaceAll(RegExp(r'^(?:Đã ghim|Da ghim|Dropped pin|Vị trí đã ghim|Vi tri da ghim)\s*[,:\-]?\s*', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'^(?:Gần|Gan|Near)\s*[,:\-]?\s*', caseSensitive: false), '');
    return s.trim();
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
      // If not a URL, clean up prefix and fallback to search
      final cleanedQuery = cleanGoogleMapsPrefix(trimmed);
      final searchList = await _searchService.searchPlaces(
        cleanedQuery.isNotEmpty ? cleanedQuery : trimmed,
        nearLocation: userLocation,
      );
      if (searchList.isNotEmpty) {
        var top = searchList.first;
        if (top.placeId != null && (top.coordinate.latitude == 0 && top.coordinate.longitude == 0)) {
          final detailed = await GoongService().getPlaceDetail(top.placeId!);
          if (detailed != null) top = detailed;
        }
        return top;
      }
      return null;
    }

    String urlStr = urlMatch.group(0)!;
    String rawPrefixName = trimmed.replaceFirst(urlStr, '').replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim();
    String userPrefixName = cleanGoogleMapsPrefix(rawPrefixName);

    // 4. Resolve Shortlinks & Redirects (maps.app.goo.gl, goo.gl/maps, etc.)
    final isShortLink = urlStr.contains('maps.app.goo.gl') ||
        urlStr.contains('goo.gl') ||
        urlStr.contains('bit.ly') ||
        urlStr.contains('t.co') ||
        urlStr.length < 50;

    String resolvedHtml = '';
    if (isShortLink) {
      try {
        final redirectResult = await _resolveRedirectsWithHtml(urlStr);
        if (redirectResult.finalUrl.isNotEmpty) {
          urlStr = redirectResult.finalUrl;
        }
        resolvedHtml = redirectResult.htmlBody;
      } catch (_) {}
    }

    // 5. Check if an explicit query or address exists in URL or shared text
    String? queryName = (userPrefixName.isNotEmpty ? userPrefixName : null) ??
        _extractPlaceNameFromUrl(urlStr) ??
        _extractQueryFromUrl(urlStr);

    // 6. Extract Coordinates from Google Maps URL
    LatLng? extractedCoord = _extractCoordinateFromUrl(urlStr);

    // If explicit coordinates were found in the URL, use them
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

    // 7. If no coordinates in URL but we have an explicit address/place query, resolve it!
    queryName ??= (resolvedHtml.isNotEmpty ? _extractTitleFromHtml(resolvedHtml) : null);
    if (queryName != null && queryName.isNotEmpty) {
      final resolvedPlace = await _resolveAddressQuery(queryName, userLocation: userLocation);
      if (resolvedPlace != null) return resolvedPlace;
    }

    // 8. Fallback: Only extract coordinates from HTML if no valid address query was found
    if (resolvedHtml.isNotEmpty) {
      extractedCoord = _extractCoordinateFromHtml(resolvedHtml);
      if (extractedCoord != null) {
        return await _searchService.reverseGeocode(extractedCoord);
      }
    }

    return null;
  }

  /// Intelligently parse and resolve complex Google Maps shared address queries
  Future<MapPlace?> _resolveAddressQuery(String rawQuery, {LatLng? userLocation}) async {
    var cleaned = cleanGoogleMapsPrefix(rawQuery);
    cleaned = cleaned.replaceAll(RegExp(r'\([^)]*\)'), ' ');
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
      final wardOrDistrict = parts[1];
      final city = parts.last;
      final streetOnly = place.replaceAll(RegExp(r'^\d+[a-zA-Z]?(\/\d+[a-zA-Z]?)?\s*'), '').trim();

      // In Vietnam, searching "Số nhà + Đường, Phường/Quận" gives 100% precision in OSM/Photon:
      candidates.add('$place, $wardOrDistrict');
      if (streetOnly.isNotEmpty && streetOnly != place) {
        candidates.add('$streetOnly, $wardOrDistrict');
      }
      candidates.add(place);
      if (streetOnly.isNotEmpty && streetOnly != place) {
        candidates.add(streetOnly);
      }
      candidates.add('$place, $wardOrDistrict, $city');
      candidates.add('$place, $city');
      candidates.add(cleaned);
    } else if (parts.length == 2) {
      final place = parts.first;
      final city = parts.last;
      final streetOnly = place.replaceAll(RegExp(r'^\d+[a-zA-Z]?(\/\d+[a-zA-Z]?)?\s*'), '').trim();

      candidates.add('$place, $city');
      if (streetOnly.isNotEmpty && streetOnly != place) {
        candidates.add('$streetOnly, $city');
      }
      candidates.add(place);
      if (streetOnly.isNotEmpty && streetOnly != place) {
        candidates.add(streetOnly);
      }
      candidates.add(cleaned);
    } else {
      candidates.add(cleaned);
    }

    for (final cand in candidates) {
      final results = await _searchService.searchPlaces(cand, nearLocation: userLocation);
      if (results.isNotEmpty) {
        // Pick best matching place: prioritize exact house number / street name over random nearby POIs
        MapPlace top = results.first;

        // Extract house number and street keywords from query
        final houseNumMatch = RegExp(r'\b(\d+[a-zA-Z]?)\b').firstMatch(parts.isNotEmpty ? parts.first : cleaned);
        final houseNum = houseNumMatch?.group(1);
        final streetKey = SearchService.cleanStreetKeyword(parts.isNotEmpty ? parts.first : cleaned);

        // 1. Priority: Result with matching house number and street keyword
        MapPlace? bestMatch;
        if (houseNum != null) {
          for (final r in results) {
            final n = r.name.toLowerCase();
            final dn = r.displayName.toLowerCase();
            final matchesNum = n.contains(houseNum) || dn.contains(houseNum);
            final matchesStreet = streetKey.isEmpty ||
                SearchService.isExactStreetMatch(r.name, streetKey) ||
                SearchService.isExactStreetMatch(r.displayName, streetKey);
            if (matchesNum && matchesStreet) {
              bestMatch = r;
              break;
            }
          }
        }

        // 2. Priority: Result matching the street name directly
        if (bestMatch == null && streetKey.isNotEmpty) {
          for (final r in results) {
            if (SearchService.isExactStreetMatch(r.name, streetKey) ||
                SearchService.isExactStreetMatch(r.displayName, streetKey)) {
              bestMatch = r;
              break;
            }
          }
        }

        if (bestMatch != null) {
          top = bestMatch;
        } else if (userLocation != null && results.length > 1) {
          // If disambiguating between multiple cities, prefer the one near user's region (< 80km)
          const distCalc = Distance();
          for (final r in results) {
            final d = distCalc.as(LengthUnit.Meter, userLocation, r.coordinate);
            if (d < 80000) {
              top = r;
              break;
            }
          }
        }

        if (top.placeId != null && (top.coordinate.latitude == 0 && top.coordinate.longitude == 0)) {
          final detailed = await GoongService().getPlaceDetail(top.placeId!);
          if (detailed != null) {
            top = detailed;
          }
        }

        final finalName = parts.isNotEmpty ? parts.first : top.name;
        return MapPlace(
          name: finalName,
          displayName: '$finalName, ${top.displayName}',
          coordinate: top.coordinate,
          type: top.type,
          category: top.category,
          distanceMeters: top.distanceMeters,
          placeId: top.placeId,
        );
      }
    }

    return null;
  }

  /// Resolve HTTP redirects for shortlinks, capturing final URL and HTML
  Future<({String finalUrl, String htmlBody})> _resolveRedirectsWithHtml(String urlStr) async {
    final client = HttpClient();
    client.userAgent = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148';

    String currentUrl = urlStr;
    String lastBody = '';

    for (int redirectCount = 0; redirectCount < 8; redirectCount++) {
      final uri = Uri.tryParse(currentUrl);
      if (uri == null) break;

      // Check if redirected to Google Consent page: extract 'continue' target
      if (currentUrl.contains('consent.google.com')) {
        final continueUrl = uri.queryParameters['continue'];
        if (continueUrl != null && continueUrl.isNotEmpty) {
          currentUrl = continueUrl;
          continue;
        }
      }

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

      // Check if response has meta refresh or canonical/og:url in body
      final contentType = response.headers.contentType?.mimeType ?? '';
      if (contentType.contains('html') || contentType.contains('text')) {
        final body = await response.transform(utf8.decoder).join();
        lastBody = body;

        // 1. Meta refresh with static URL
        final metaRegex = RegExp(
          r'<meta[^>]*content=["\x27]\d+;\s*url=([^"\x27>+]+)["\x27]',
          caseSensitive: false,
        );
        final metaMatch = metaRegex.firstMatch(body);
        if (metaMatch != null) {
          final target = metaMatch.group(1)!.trim();
          if (!target.contains('\'') && !target.contains('"')) {
            currentUrl = target.startsWith('http') ? target : uri.resolve(target).toString();
            continue;
          }
        }

        // 2. og:url meta tag
        final ogMatch = RegExp(r'<meta[^>]*property=["\x27]og:url["\x27][^>]*content=["\x27]([^"\x27]+)["\x27]', caseSensitive: false).firstMatch(body);
        if (ogMatch != null) {
          final ogUrl = ogMatch.group(1)!.trim();
          if (ogUrl.startsWith('http') && ogUrl.contains('google.com/maps')) {
            currentUrl = ogUrl;
            continue;
          }
        }

        // 3. link rel=canonical
        final canonicalMatch = RegExp(r'<link[^>]*rel=["\x27]canonical["\x27][^>]*href=["\x27]([^"\x27]+)["\x27]', caseSensitive: false).firstMatch(body);
        if (canonicalMatch != null) {
          final cUrl = canonicalMatch.group(1)!.trim();
          if (cUrl.startsWith('http') && cUrl.contains('google.com/maps')) {
            currentUrl = cUrl;
            continue;
          }
        }
      }
      break;
    }
    client.close();
    return (finalUrl: currentUrl, htmlBody: lastBody);
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

    // Priority 2: ?q=21.028511,105.854212 or ?destination=... or ?query=... or ?daddr=... (Explicit Pin/Query)
    final qRegex = RegExp(
      r'[?&](?:q|query|destination|daddr|saddr|dest|ll|center)=(?:loc:)?(\-?\d{1,2}\.\d{3,})[,\s\+]+(\-?\d{1,3}\.\d{3,})',
    );
    final qMatch = qRegex.firstMatch(decoded);
    if (qMatch != null) {
      final lat = double.tryParse(qMatch.group(1)!);
      final lon = double.tryParse(qMatch.group(2)!);
      if (lat != null && lon != null) return LatLng(lat, lon);
    }

    // Priority 3: /place/21.028511,105.854212 (Exact dropped pin in /place/ path)
    final placeCoordRegex = RegExp(r'/place/(\-?\d{1,2}\.\d{3,})[,\s\+]+(\-?\d{1,3}\.\d{3,})');
    final placeMatch = placeCoordRegex.firstMatch(decoded);
    if (placeMatch != null) {
      final lat = double.tryParse(placeMatch.group(1)!);
      final lon = double.tryParse(placeMatch.group(2)!);
      if (lat != null && lon != null) return LatLng(lat, lon);
    }

    // Priority 4: /search/21.028511,+105.854212 or /search/21.028511,105.854212
    final searchCoordRegex = RegExp(
      r'/search/(\-?\d{1,2}\.\d{3,})[,\s\+]+(\-?\d{1,3}\.\d{3,})',
    );
    final searchMatch = searchCoordRegex.firstMatch(decoded);
    if (searchMatch != null) {
      final lat = double.tryParse(searchMatch.group(1)!);
      final lon = double.tryParse(searchMatch.group(2)!);
      if (lat != null && lon != null) return LatLng(lat, lon);
    }

    // Priority 5: Embedded DMS in URL e.g. /place/20°59'07.8"N+105°50'29.4"E or 21°01'42.6"B
    final dmsCoord = parseDms(decoded);
    if (dmsCoord != null) return dmsCoord;

    // Priority 6: /dir/ path - extract only if the DESTINATION (last segment before /@) has coordinates
    if (decoded.contains('/dir/')) {
      final dirSection = decoded.split('/dir/').last.split('/@').first;
      final lastSegment = dirSection.split('/').where((s) => s.isNotEmpty).lastOrNull;
      if (lastSegment != null) {
        final coordMatch = RegExp(r'(\-?\d{1,2}\.\d{3,})[,\s\+]+(\-?\d{1,3}\.\d{3,})').firstMatch(lastSegment);
        if (coordMatch != null) {
          final lat = double.tryParse(coordMatch.group(1)!);
          final lon = double.tryParse(coordMatch.group(2)!);
          if (lat != null && lon != null) return LatLng(lat, lon);
        }
      }
    }

    // Priority 7 (Fallback only if no place name is present): @21.028511,105.854212 (Camera viewport center)
    final atRegex = RegExp(r'@(\-?\d{1,2}\.\d{3,}),(\-?\d{1,3}\.\d{3,})');
    final atMatch = atRegex.firstMatch(decoded);
    if (atMatch != null) {
      final lat = double.tryParse(atMatch.group(1)!);
      final lon = double.tryParse(atMatch.group(2)!);
      if (lat != null && lon != null) return LatLng(lat, lon);
    }

    return null;
  }

  /// Extract coordinates from Google Maps HTML page (staticmap image or APP_INITIALIZATION_STATE)
  LatLng? _extractCoordinateFromHtml(String html) {
    // 1. Staticmap image URL with explicit markers=lat,lon (Must be a marker pin, not just broad regional center=)
    final markerMatch = RegExp(r'staticmap\?[^"\x27]*?markers=(?:color:[^|]+\|)?(\-?\d{1,2}\.\d{3,})%2C(\-?\d{1,3}\.\d{3,})').firstMatch(html);
    if (markerMatch != null) {
      final lat = double.tryParse(markerMatch.group(1)!);
      final lon = double.tryParse(markerMatch.group(2)!);
      if (lat != null && lon != null) return LatLng(lat, lon);
    }

    // 2. Staticmap with high zoom (>= 15) indicates exact place center, not regional province view
    final staticHighZoomMatch = RegExp(r'staticmap\?[^"\x27]*?center=(\-?\d{1,2}\.\d{3,})%2C(\-?\d{1,3}\.\d{3,})[^"\x27]*?zoom=(?:1[5-9]|2\d)').firstMatch(html);
    if (staticHighZoomMatch != null) {
      final lat = double.tryParse(staticHighZoomMatch.group(1)!);
      final lon = double.tryParse(staticHighZoomMatch.group(2)!);
      if (lat != null && lon != null) return LatLng(lat, lon);
    }

    // 3. Coordinates in Google JSON data: [null,null,lat,lon]
    final jsonCoordMatch = RegExp(r'\[\s*null\s*,\s*null\s*,\s*(\-?\d{1,2}\.\d{4,})\s*,\s*(\-?\d{1,3}\.\d{4,})\s*\]').firstMatch(html);
    if (jsonCoordMatch != null) {
      final lat = double.tryParse(jsonCoordMatch.group(1)!);
      final lon = double.tryParse(jsonCoordMatch.group(2)!);
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
    final qRegex = RegExp(r'[?&](?:q|query|destination|daddr)=([^&]+)');
    final match = qRegex.firstMatch(decoded);
    if (match != null) {
      final raw = match.group(1)!;
      if (RegExp(r'^\-?\d{1,2}\.\d+').hasMatch(raw)) return null;
      return raw.replaceAll('+', ' ').trim();
    }
    return null;
  }

  String? _extractTitleFromHtml(String html) {
    final titleMatch = RegExp(r'<title>([^<]+)</title>', caseSensitive: false).firstMatch(html);
    if (titleMatch != null) {
      var t = titleMatch.group(1)!.trim();
      t = t.replaceAll(RegExp(r'\s*-\s*Google Maps.*$', caseSensitive: false), '').trim();
      if (t.isNotEmpty && t.toLowerCase() != 'google maps') {
        return t;
      }
    }
    return null;
  }
}
