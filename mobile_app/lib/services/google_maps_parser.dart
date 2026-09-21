import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:latlong2/latlong.dart';
import '../models/route_model.dart';
import 'search_service.dart';

abstract class GoogleMapsRedirectResolver {
  Future<({String finalUrl, String htmlBody})> resolve(String url);
}

class HttpGoogleMapsRedirectResolver implements GoogleMapsRedirectResolver {
  @override
  Future<({String finalUrl, String htmlBody})> resolve(String url) async {
    String currentUrl = url;
    String lastBody = '';
    final visited = <String>{};
    final client = HttpClient();
    client.connectionTimeout = const Duration(milliseconds: 1500);
    client.userAgent =
        'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148';

    try {
      for (int i = 0; i < 5; i++) {
        // Redirect loop protection (Section 24 & 45)
        if (!visited.add(currentUrl)) {
          break;
        }

        final uri = Uri.parse(currentUrl);
        final request = await client.getUrl(uri).timeout(const Duration(milliseconds: 1500));
        request.followRedirects = false;
        final response = await request.close().timeout(const Duration(milliseconds: 1500));

        final location = response.headers.value('location');
        if (location != null && location.isNotEmpty) {
          currentUrl = Uri.parse(currentUrl).resolve(location).toString();
          // Fast abort: If redirect location already contains exact coordinates, return immediately (Section 26)
          if (GoogleMapsParser.hasAuthoritativeCoordinates(currentUrl)) {
            return (finalUrl: currentUrl, htmlBody: '');
          }
          continue;
        }

        final bodyBytes = await response
            .timeout(const Duration(milliseconds: 1500))
            .fold<List<int>>([], (prev, element) => prev..addAll(element));
        final body = utf8.decode(bodyBytes, allowMalformed: true);
        lastBody = body;

        // Meta refresh check
        final metaMatch = RegExp(
          r'<meta[^>]*http-equiv=["\x27]refresh["\x27][^>]*content=["\x27]\d+;\s*url=([^"\x27]+)["\x27]',
          caseSensitive: false,
        ).firstMatch(body);
        if (metaMatch != null) {
          final nextUrl = metaMatch.group(1)!.trim();
          if (nextUrl.startsWith('http')) {
            currentUrl = nextUrl;
            if (GoogleMapsParser.hasAuthoritativeCoordinates(currentUrl)) {
              return (finalUrl: currentUrl, htmlBody: '');
            }
            continue;
          }
        }

        // og:url check
        final ogMatch = RegExp(
          r'<meta[^>]*property=["\x27]og:url["\x27][^>]*content=["\x27]([^"\x27]+)["\x27]',
          caseSensitive: false,
        ).firstMatch(body);
        if (ogMatch != null) {
          final ogUrl = ogMatch.group(1)!.trim();
          if (ogUrl.startsWith('http') && ogUrl.contains('google.com/maps')) {
            currentUrl = ogUrl;
            if (GoogleMapsParser.hasAuthoritativeCoordinates(currentUrl)) {
              return (finalUrl: currentUrl, htmlBody: '');
            }
            continue;
          }
        }
        break;
      }
    } finally {
      // Guaranteed HttpClient cleanup in finally (Section 25)
      client.close(force: true);
    }
    return (finalUrl: currentUrl, htmlBody: lastBody);
  }
}

class GoogleMapsParser {
  final SearchService _searchService;
  final GoogleMapsRedirectResolver _redirectResolver;
  int _linkResolutionGeneration = 0;

  GoogleMapsParser({
    SearchService? searchService,
    GoogleMapsRedirectResolver? redirectResolver,
  })  : _searchService = searchService ?? SearchService(),
        _redirectResolver = redirectResolver ?? HttpGoogleMapsRedirectResolver();

  int get currentLinkResolutionGeneration => _linkResolutionGeneration;

  /// Check if a URL already contains explicit authoritative coordinates
  static bool hasAuthoritativeCoordinates(String url) {
    final decoded = Uri.decodeFull(url);
    if (decoded.contains('!3d') || decoded.contains('!4d')) return true;
    if (RegExp(r'/place/(\-?\d{1,2}\.\d{3,})[,\s\+]+(\-?\d{1,3}\.\d{3,})').hasMatch(decoded)) return true;
    if (RegExp(r'/search/(\-?\d{1,2}\.\d{3,})[,\s\+]+(\-?\d{1,3}\.\d{3,})').hasMatch(decoded)) return true;
    if (RegExp(r'[?&](?:destination|daddr|dest|q|query)=(?:loc:)?(\-?\d{1,2}\.\d{3,})[,\s\+]+(\-?\d{1,3}\.\d{3,})').hasMatch(decoded)) return true;
    if (decoded.contains('/dir/')) {
      final dirSection = decoded.split('/dir/').last.split('/@').first.split('/data=').first;
      final segments = dirSection.split('/').where((s) => s.isNotEmpty).toList();
      if (segments.length >= 2) {
        if (RegExp(r'(\-?\d{1,2}\.\d{3,})[,\s\+]+(\-?\d{1,3}\.\d{3,})').hasMatch(segments.last)) {
          return true;
        }
      }
    }
    return false;
  }

  /// Parse DMS (Degrees Minutes Seconds) format into decimal LatLng
  static LatLng? parseDms(String text) {
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
        if (dirLat == 'S') lat = -lat;

        double lon = degLon + (minLon / 60.0) + (secLon / 3600.0);
        if (dirLon == 'W' || dirLon == 'T') lon = -lon;

        if (lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180) {
          return LatLng(lat, lon);
        }
      }
    }
    return null;
  }

  /// Check if input is a Google Maps link or raw coordinates
  static bool isGoogleMapsOrCoordInput(String text) {
    final t = text.toLowerCase().trim();
    if (t.contains('maps.app.goo.gl') ||
        t.contains('goo.gl/maps') ||
        t.contains('google.com/maps') ||
        t.contains('maps.google.com') ||
        t.contains('geo:')) {
      return true;
    }

    if (parseDms(text) != null) return true;

    final coordRegex = RegExp(r'(\-?\d{1,2}\.\d{3,})[\s,;]+(\-?\d{1,3}\.\d{3,})');
    if (coordRegex.hasMatch(text)) return true;

    final plusCodeRegex = RegExp(r'\b[23456789CFGHJMPQRVWX]{4,8}\+[23456789CFGHJMPQRVWX]{2,3}\b');
    return plusCodeRegex.hasMatch(text);
  }

  /// Clean Vietnamese Google Maps prefixes
  static String cleanGoogleMapsPrefix(String text) {
    var s = text.trim();
    s = s.replaceAll(RegExp(r'^(?:Đã ghim|Da ghim|Dropped pin|Vị trí đã ghim|Vi tri da ghim)\s*[,:\-]?\s*', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'^(?:Gần|Gan|Near)\s*[,:\-]?\s*', caseSensitive: false), '');
    return s.trim();
  }

  /// Strict URL coordinate extraction respecting Authority Priority (Sections 20, 21, 22, 24, 25)
  ({LatLng? exactCoord, LatLng? cameraCoord, String? placeName, String? destQuery}) _parseUrlSemantics(String url) {
    final decoded = Uri.decodeFull(url);
    LatLng? exactCoord;
    LatLng? cameraCoord;
    String? placeName;
    String? destQuery;

    // 1. Camera coordinate: @lat,lon (Section 20 & 21: Never use as exact POI!)
    final atRegex = RegExp(r'@(\-?\d{1,2}\.\d{3,}),(\-?\d{1,3}\.\d{3,})');
    final atMatch = atRegex.firstMatch(decoded);
    if (atMatch != null) {
      final lat = double.tryParse(atMatch.group(1)!);
      final lon = double.tryParse(atMatch.group(2)!);
      if (lat != null && lon != null) {
        cameraCoord = LatLng(lat, lon);
      }
    }

    // 2. Priority 1: Explicit Protobuf destination coordinates: !3dLAT!4dLON or !4dLON!3dLAT (Section 22 & 24)
    final protoRegex = RegExp(r'(?:!3d(\-?\d{1,2}\.\d{3,})[^!]*!4d(\-?\d{1,3}\.\d{3,})|!4d(\-?\d{1,3}\.\d{3,})[^!]*!3d(\-?\d{1,2}\.\d{3,}))');
    final protoMatch = protoRegex.firstMatch(decoded);
    if (protoMatch != null) {
      final latStr = protoMatch.group(1) ?? protoMatch.group(4);
      final lonStr = protoMatch.group(2) ?? protoMatch.group(3);
      if (latStr != null && lonStr != null) {
        final lat = double.tryParse(latStr);
        final lon = double.tryParse(lonStr);
        if (lat != null && lon != null) {
          exactCoord = LatLng(lat, lon);
        }
      }
    }

    // Priority 1b: !1d/!2d protobuf
    if (exactCoord == null) {
      final proto12Regex = RegExp(r'(?:!1d(\-?\d{1,3}\.\d{3,})[^!]*!2d(\-?\d{1,2}\.\d{3,})|!2d(\-?\d{1,2}\.\d{3,})[^!]*!1d(\-?\d{1,3}\.\d{3,}))');
      final proto12Match = proto12Regex.firstMatch(decoded);
      if (proto12Match != null) {
        final lonStr = proto12Match.group(1) ?? proto12Match.group(4);
        final latStr = proto12Match.group(2) ?? proto12Match.group(3);
        if (latStr != null && lonStr != null) {
          final lat = double.tryParse(latStr);
          final lon = double.tryParse(lonStr);
          if (lat != null && lon != null) {
            exactCoord = LatLng(lat, lon);
          }
        }
      }
    }

    // 3. Priority 2: Explicit destination query parameters (?q=LAT,LON, ?destination=LAT,LON, ?daddr=LAT,LON)
    if (exactCoord == null) {
      final qRegex = RegExp(
        r'[?&](?:destination|daddr|dest|q|query)=(?:loc:)?(\-?\d{1,2}\.\d{3,})[,\s\+]+(\-?\d{1,3}\.\d{3,})',
      );
      final qMatch = qRegex.firstMatch(decoded);
      if (qMatch != null) {
        final lat = double.tryParse(qMatch.group(1)!);
        final lon = double.tryParse(qMatch.group(2)!);
        if (lat != null && lon != null) {
          exactCoord = LatLng(lat, lon);
        }
      }
    }

    // 4. Priority 3: Explicit /place/LAT,LON (Dropped pin)
    if (exactCoord == null) {
      final placeCoordRegex = RegExp(r'/place/(\-?\d{1,2}\.\d{3,})[,\s\+]+(\-?\d{1,3}\.\d{3,})');
      final placeMatch = placeCoordRegex.firstMatch(decoded);
      if (placeMatch != null) {
        final lat = double.tryParse(placeMatch.group(1)!);
        final lon = double.tryParse(placeMatch.group(2)!);
        if (lat != null && lon != null) {
          exactCoord = LatLng(lat, lon);
        }
      }
    }

    // 5. Priority 4: Explicit /search/LAT,LON
    if (exactCoord == null) {
      final searchCoordRegex = RegExp(r'/search/(\-?\d{1,2}\.\d{3,})[,\s\+]+(\-?\d{1,3}\.\d{3,})');
      final searchMatch = searchCoordRegex.firstMatch(decoded);
      if (searchMatch != null) {
        final lat = double.tryParse(searchMatch.group(1)!);
        final lon = double.tryParse(searchMatch.group(2)!);
        if (lat != null && lon != null) {
          exactCoord = LatLng(lat, lon);
        }
      }
    }

    // 6. Priority 5: /dir/ path - extract destination ONLY (Section 25 & 37)
    if (decoded.contains('/dir/')) {
      final dirSection = decoded.split('/dir/').last.split('/@').first.split('/data=').first;
      final segments = dirSection.split('/').where((s) => s.isNotEmpty).toList();
      if (segments.length >= 2) {
        final destSegment = segments.last;
        final coordMatch = RegExp(r'(\-?\d{1,2}\.\d{3,})[,\s\+]+(\-?\d{1,3}\.\d{3,})').firstMatch(destSegment);
        if (coordMatch != null) {
          final lat = double.tryParse(coordMatch.group(1)!);
          final lon = double.tryParse(coordMatch.group(2)!);
          if (lat != null && lon != null) {
            exactCoord = LatLng(lat, lon);
          }
        } else {
          destQuery = destSegment.replaceAll('+', ' ').trim();
        }
      }
    }

    // 7. Extract Place Name from URL
    final placeNameRegex = RegExp(r'/place/([^/@?]+)');
    final pMatch = placeNameRegex.firstMatch(decoded);
    if (pMatch != null) {
      final raw = pMatch.group(1)!;
      if (!RegExp(r'^\-?\d{1,2}\.\d+').hasMatch(raw)) {
        placeName = raw.replaceAll('+', ' ').trim();
      }
    }

    // 8. Extract query from URL
    if (destQuery == null) {
      final qTextRegex = RegExp(r'[?&](?:destination|daddr|q|query)=([^&]+)');
      final qTextMatch = qTextRegex.firstMatch(decoded);
      if (qTextMatch != null) {
        final raw = qTextMatch.group(1)!;
        if (!RegExp(r'^\-?\d{1,2}\.\d+').hasMatch(raw)) {
          var clean = raw.replaceAll('+', ' ').trim();
          clean = clean.replaceAll(RegExp(r'\bP\.\s*', caseSensitive: false), 'Phố ');
          clean = clean.replaceAll(RegExp(r'\bĐ\.\s*', caseSensitive: false), 'Đường ');
          destQuery = clean;
        }
      }
    }

    return (
      exactCoord: exactCoord,
      cameraCoord: cameraCoord,
      placeName: placeName,
      destQuery: destQuery,
    );
  }

  /// Parse input text / URL and return rich GoogleMapsResolvedLink
  Future<GoogleMapsResolvedLink> parseResolvedLink(String input, {LatLng? userLocation}) async {
    _linkResolutionGeneration++;
    final myGen = _linkResolutionGeneration;

    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      return GoogleMapsResolvedLink(confidence: GoogleMapsResolutionConfidence.unresolved);
    }

    // 1. DMS Coordinate Check (< 1ms)
    final dmsCoord = parseDms(trimmed);
    if (dmsCoord != null) {
      return GoogleMapsResolvedLink(
        exactCoordinate: dmsCoord,
        confidence: GoogleMapsResolutionConfidence.exactPin,
        precision: PlacePrecision.coordinate,
        rawQuery: trimmed,
      );
    }

    // 2. Direct Decimal Coordinate Check without URL (e.g. "21.0285, 105.8542")
    final textWithoutUrl = trimmed.replaceAll(RegExp(r'https?://[^\s]+'), '').trim();
    if (textWithoutUrl.isNotEmpty) {
      final coordRegex = RegExp(r'^(\-?\d{1,2}\.\d{3,})[\s,;]+(\-?\d{1,3}\.\d{3,})$');
      final match = coordRegex.firstMatch(textWithoutUrl);
      if (match != null) {
        final lat = double.tryParse(match.group(1)!);
        final lon = double.tryParse(match.group(2)!);
        if (lat != null && lon != null && lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180) {
          return GoogleMapsResolvedLink(
            exactCoordinate: LatLng(lat, lon),
            confidence: GoogleMapsResolutionConfidence.exactPin,
            precision: PlacePrecision.coordinate,
            rawQuery: trimmed,
          );
        }
      }
    }

    // 3. Extract URL
    final urlRegex = RegExp(r'https?://[^\s]+');
    final urlMatch = urlRegex.firstMatch(trimmed);
    if (urlMatch == null) {
      final cleaned = cleanGoogleMapsPrefix(trimmed);
      return GoogleMapsResolvedLink(
        confidence: GoogleMapsResolutionConfidence.unresolved,
        rawQuery: cleaned,
      );
    }

    String urlStr = urlMatch.group(0)!;
    String rawPrefix = trimmed.replaceFirst(urlStr, '').replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim();
    String userPrefix = cleanGoogleMapsPrefix(rawPrefix);

    // 4. LOCAL FAST-PATH: If URL is a full Google URL with exact coordinates, parse immediately (0 HTTP calls!)
    // (Sections 27 & 42)
    final isShortLink = urlStr.contains('maps.app.goo.gl') ||
        urlStr.contains('goo.gl') ||
        urlStr.contains('bit.ly') ||
        urlStr.length < 50;

    String resolvedHtml = '';
    if (isShortLink) {
      try {
        final resolved = await _redirectResolver.resolve(urlStr);
        if (myGen != _linkResolutionGeneration) {
          return GoogleMapsResolvedLink(confidence: GoogleMapsResolutionConfidence.unresolved);
        }
        if (resolved.finalUrl.isNotEmpty) {
          urlStr = resolved.finalUrl;
        }
        resolvedHtml = resolved.htmlBody;
      } catch (_) {}
    }

    final semantics = _parseUrlSemantics(urlStr);
    final placeTitle = (userPrefix.isNotEmpty ? userPrefix : null) ??
        semantics.placeName ??
        semantics.destQuery ??
        _extractTitleFromHtml(resolvedHtml);

    // 5. Exact Coordinate Found in URL (Section 22 Priority 1-5, Section 28 & 29)
    if (semantics.exactCoord != null) {
      final isDir = urlStr.contains('/dir/');
      return GoogleMapsResolvedLink(
        finalUri: Uri.tryParse(urlStr),
        placeName: placeTitle,
        exactCoordinate: semantics.exactCoord,
        cameraCoordinate: semantics.cameraCoord,
        confidence: isDir
            ? GoogleMapsResolutionConfidence.exactDestination
            : GoogleMapsResolutionConfidence.exactPin,
        precision: placeTitle != null ? PlacePrecision.poi : PlacePrecision.coordinate,
        rawQuery: trimmed,
      );
    }

    // 6. Named Link Without Exact Coordinate (Section 21, 30, 35, 36)
    if (placeTitle != null && placeTitle.isNotEmpty) {
      var query = placeTitle
          .replaceAll(RegExp(r'\bP\.\s*', caseSensitive: false), 'Phố ')
          .replaceAll(RegExp(r'\bĐ\.\s*', caseSensitive: false), 'Đường ');
      var searchList = await _searchService.searchPlaces(query, nearLocation: userLocation);
      if (searchList.isEmpty && query.contains(',')) {
        final firstPart = query.split(',').first.trim();
        if (firstPart.isNotEmpty) {
          searchList = await _searchService.searchPlaces(firstPart, nearLocation: userLocation);
        }
      }
      if (myGen != _linkResolutionGeneration) {
        return GoogleMapsResolvedLink(confidence: GoogleMapsResolutionConfidence.unresolved);
      }

      if (searchList.isNotEmpty) {
        final top = searchList.first;
        return GoogleMapsResolvedLink(
          finalUri: Uri.tryParse(urlStr),
          placeName: top.name,
          exactCoordinate: top.coordinate,
          cameraCoordinate: semantics.cameraCoord,
          confidence: GoogleMapsResolutionConfidence.resolvedPlace,
          precision: top.precision,
          address: top.displayName,
          rawQuery: trimmed,
        );
      }

      // If search failed to resolve named place, fallback to camera coordinate as approximate
      if (semantics.cameraCoord != null) {
        return GoogleMapsResolvedLink(
          finalUri: Uri.tryParse(urlStr),
          placeName: placeTitle,
          exactCoordinate: null,
          cameraCoordinate: semantics.cameraCoord,
          confidence: GoogleMapsResolutionConfidence.approximate,
          precision: PlacePrecision.approximate,
          rawQuery: trimmed,
        );
      }
    }

    // 7. Pure Viewport / Camera Link (Section 23)
    if (semantics.cameraCoord != null) {
      return GoogleMapsResolvedLink(
        finalUri: Uri.tryParse(urlStr),
        placeName: null,
        exactCoordinate: null,
        cameraCoordinate: semantics.cameraCoord,
        confidence: GoogleMapsResolutionConfidence.approximate,
        precision: PlacePrecision.approximate,
        rawQuery: trimmed,
      );
    }

    return GoogleMapsResolvedLink(
      finalUri: Uri.tryParse(urlStr),
      confidence: GoogleMapsResolutionConfidence.unresolved,
      rawQuery: trimmed,
    );
  }

  /// Fast exact-pin parseInput returning MapPlace immediately without reverse-geocoding block (Section 30)
  Future<MapPlace?> parseInput(String input, {LatLng? userLocation}) async {
    final resolved = await parseResolvedLink(input, userLocation: userLocation);
    final target = resolved.targetCoordinate;
    if (target == null) return null;

    final name = resolved.placeName ??
        (resolved.confidence == GoogleMapsResolutionConfidence.exactPin ? 'Vị trí đã ghim' : 'Điểm đến Google Maps');
    final display = (resolved.address != null && resolved.address!.isNotEmpty)
        ? resolved.address!
        : (resolved.placeName != null
            ? resolved.placeName!
            : 'Tọa độ: ${target.latitude.toStringAsFixed(6)}, ${target.longitude.toStringAsFixed(6)}');

    return MapPlace(
      name: name,
      displayName: display,
      coordinate: target,
      precision: resolved.precision,
      source: resolved.isExact ? 'google_link_exact' : 'google_link_approx',
    );
  }

  String? _extractTitleFromHtml(String html) {
    if (html.isEmpty) return null;
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
