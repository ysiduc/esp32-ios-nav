import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
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
          // Fast abort: If redirect location already contains exact coordinates, return immediately
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

        // Check canonical URL in HTML (P5.4.1.1 Section 6)
        final canonicalUrl = GoogleMapsParser.extractCanonicalUrl(body);
        if (canonicalUrl != null && GoogleMapsParser.hasAuthoritativeCoordinates(canonicalUrl)) {
          return (finalUrl: canonicalUrl, htmlBody: body);
        }

        // Check og:url in HTML (P5.4.1.1 Section 7)
        final ogUrl = GoogleMapsParser.extractOgUrl(body);
        if (ogUrl != null && GoogleMapsParser.hasAuthoritativeCoordinates(ogUrl)) {
          return (finalUrl: ogUrl, htmlBody: body);
        }

        // Meta refresh check
        final metaMatch = RegExp(
          r'<meta[^>]*http-equiv=["\x27]refresh["\x27][^>]*content=["\x27]\d+;\s*url=([^"\x27]+)["\x27]',
          caseSensitive: false,
        ).firstMatch(body);
        if (metaMatch != null) {
          final nextUrl = GoogleMapsParser.decodeHtmlEntities(metaMatch.group(1)!.trim());
          if (nextUrl.startsWith('http')) {
            currentUrl = nextUrl;
            if (GoogleMapsParser.hasAuthoritativeCoordinates(currentUrl)) {
              return (finalUrl: currentUrl, htmlBody: '');
            }
            continue;
          }
        }

        // Bounded 1-hop canonical/og follow if URL has no coordinates yet (P5.4.1.1 Section 8)
        if (canonicalUrl != null &&
            !visited.contains(canonicalUrl) &&
            canonicalUrl.startsWith('http') &&
            canonicalUrl.contains('google.com/maps') &&
            i < 4) {
          currentUrl = canonicalUrl;
          continue;
        }

        break;
      }
    } finally {
      // Guaranteed HttpClient cleanup in finally
      client.close(force: true);
    }
    return (finalUrl: currentUrl, htmlBody: lastBody);
  }
}


class GoogleTargetMetadata {
  final LatLng? targetCoordinate;
  final String? placeIdentity;
  final String? title;
  final String source;
  final double confidence;

  const GoogleTargetMetadata({
    this.targetCoordinate,
    this.placeIdentity,
    this.title,
    this.source = 'identity_bound_payload',
    this.confidence = 1.0,
  });
}

class GoogleMapsTargetMetadataParser {
  /// Extract identity-bound Google Maps target metadata from HTML body.
  /// A coordinate is accepted ONLY if bound to the target place identity.
  static GoogleTargetMetadata? extract({
    required String finalUrl,
    required String htmlBody,
    String? knownPlaceIdentity,
    String? pageTitle,
  }) {
    if (htmlBody.isEmpty) return null;

    final candidates = <String>[];
    if (knownPlaceIdentity != null && knownPlaceIdentity.isNotEmpty) {
      candidates.add(knownPlaceIdentity);
    }

    // 1. ChIJ place ID priority (Section 8)
    final chijRegex = RegExp(r'\b(ChIJ[a-zA-Z0-9_\-]{20,})\b');
    for (final match in chijRegex.allMatches(finalUrl)) {
      final id = match.group(1)!;
      if (!candidates.contains(id)) candidates.add(id);
    }
    for (final match in chijRegex.allMatches(htmlBody)) {
      final id = match.group(1)!;
      if (!candidates.contains(id)) candidates.add(id);
    }

    // 2. CID priority (decimal)
    final cidUrlRegex = RegExp(r'[?&]cid=(\d+)');
    for (final match in cidUrlRegex.allMatches(finalUrl)) {
      final id = match.group(1)!;
      if (!candidates.contains(id)) candidates.add(id);
      if (!candidates.contains('cid:$id')) candidates.add('cid:$id');
    }
    final cidHtmlRegex = RegExp(r'(?:data-cid=["\x27]|"cid"\s*:\s*["\x27]?)(\d+)');
    for (final match in cidHtmlRegex.allMatches(htmlBody)) {
      final id = match.group(1)!;
      if (!candidates.contains(id)) candidates.add(id);
      if (!candidates.contains('cid:$id')) candidates.add('cid:$id');
    }

    // 3. Hex place ID pair: 0x...:0x...
    final hexRegex = RegExp(r'(0x[0-9a-fA-F]+:0x[0-9a-fA-F]+)');
    for (final match in hexRegex.allMatches(finalUrl)) {
      final id = match.group(1)!;
      if (!candidates.contains(id)) candidates.add(id);
    }
    for (final match in hexRegex.allMatches(htmlBody)) {
      final id = match.group(1)!;
      if (!candidates.contains(id)) candidates.add(id);
    }

    // 4. Canonical target URL identity / place name slug
    final placeNameRegex = RegExp(r'/place/([^/@?]+)');
    final pMatch = placeNameRegex.firstMatch(finalUrl);
    if (pMatch != null) {
      final raw = pMatch.group(1)!;
      if (!RegExp(r'^\-?\d{1,2}\.\d+').hasMatch(raw)) {
        final slug = raw.trim();
        if (slug.isNotEmpty && !candidates.contains(slug)) candidates.add(slug);
      }
    }

    if (candidates.isEmpty) {
      return null;
    }

    // For each candidate identity in priority order, search for an identity-bound coordinate
    for (final identity in candidates) {
      final searchToken = identity.startsWith('cid:') ? identity.substring(4) : identity;
      int startIndex = 0;
      while (startIndex < htmlBody.length) {
        final idx = htmlBody.indexOf(searchToken, startIndex);
        if (idx == -1) break;
        startIndex = idx + searchToken.length;

        // Isolate enclosing structured block (JSON object, array, script, or tag) (Section 7)
        final blockInfo = _isolateStructuredBlock(htmlBody, idx, searchToken.length);
        if (blockInfo != null) {
          final coord = _findClosestCoordinateInBlock(blockInfo.block, blockInfo.tokenOffset);
          if (coord != null) {
            return GoogleTargetMetadata(
              targetCoordinate: coord,
              placeIdentity: identity,
              title: pageTitle,
              source: 'identity_bound_payload',
              confidence: 1.0,
            );
          }
        }
      }
    }

    return null;
  }

  static ({String block, int tokenOffset})? _isolateStructuredBlock(String html, int idx, int tokenLen) {
    // 1. Check enclosing JSON object { ... }
    final braceOpen = html.lastIndexOf('{', idx);
    final braceClose = html.indexOf('}', idx + tokenLen);
    if (braceOpen != -1 && braceClose != -1 && (idx - braceOpen) < 400 && (braceClose - idx) < 400) {
      return (
        block: html.substring(braceOpen, braceClose + 1),
        tokenOffset: idx - braceOpen,
      );
    }

    // 2. Check enclosing JSON array [ ... ]
    final bracketOpen = html.lastIndexOf('[', idx);
    final bracketClose = html.indexOf(']', idx + tokenLen);
    if (bracketOpen != -1 && bracketClose != -1 && (idx - bracketOpen) < 400 && (bracketClose - idx) < 400) {
      return (
        block: html.substring(bracketOpen, bracketClose + 1),
        tokenOffset: idx - bracketOpen,
      );
    }

    // 3. Check enclosing <script> ... </script>
    final scriptOpen = html.lastIndexOf(RegExp(r'<script\b[^>]*>', caseSensitive: false), idx);
    final scriptClose = html.indexOf(RegExp(r'</script>', caseSensitive: false), idx + tokenLen);
    if (scriptOpen != -1 && scriptClose != -1 && scriptOpen < idx && scriptClose > idx) {
      final sStart = scriptOpen;
      final sEnd = scriptClose + 9;
      if (sEnd - sStart < 3000) {
        return (
          block: html.substring(sStart, sEnd),
          tokenOffset: idx - sStart,
        );
      }
    }

    // 4. Check enclosing HTML tag <tag ... >
    final tagOpen = html.lastIndexOf('<', idx);
    final tagClose = html.indexOf('>', idx + tokenLen);
    if (tagOpen != -1 && tagClose != -1 && tagOpen < idx && tagClose > idx && (tagClose - tagOpen) < 400) {
      final tagStr = html.substring(tagOpen, tagClose + 1);
      // Ensure it is an actual element tag and not a comment
      if (!tagStr.startsWith('<!--')) {
        return (
          block: tagStr,
          tokenOffset: idx - tagOpen,
        );
      }
    }

    return null;
  }

  static LatLng? _findClosestCoordinateInBlock(String block, int tokenOffset) {
    LatLng? bestCoord;
    int minDistance = 999999;

    // Pattern 1: Google array format [null, null, lat, lon] or [lat, lon]
    final protoArrayRegex = RegExp(r'\[\s*(?:null\s*,\s*null\s*,\s*)?(\-\d{1,2}\.\d{4,}|\d{1,2}\.\d{4,})\s*,\s*(\-\d{1,3}\.\d{4,}|\d{1,3}\.\d{4,})\s*\]');
    for (final m in protoArrayRegex.allMatches(block)) {
      final lat = double.tryParse(m.group(1)!);
      final lon = double.tryParse(m.group(2)!);
      if (lat != null && lon != null && _isValidCoord(lat, lon)) {
        final dist = (m.start - tokenOffset).abs();
        if (dist < minDistance) {
          minDistance = dist;
          bestCoord = LatLng(lat, lon);
        }
      }
    }

    // Pattern 2: JSON key-value: "lat": 21.xxx, "lng": 105.xxx
    final jsonKvRegex = RegExp(r'"?(?:latitude|lat)"?\s*:\s*"?(\-\d{1,2}\.\d{4,}|\d{1,2}\.\d{4,})"?\s*,\s*"?(?:longitude|lng|lon|long)"?\s*:\s*"?(\-\d{1,3}\.\d{4,}|\d{1,3}\.\d{4,})"?', caseSensitive: false);
    for (final m in jsonKvRegex.allMatches(block)) {
      final lat = double.tryParse(m.group(1)!);
      final lon = double.tryParse(m.group(2)!);
      if (lat != null && lon != null && _isValidCoord(lat, lon)) {
        final dist = (m.start - tokenOffset).abs();
        if (dist < minDistance) {
          minDistance = dist;
          bestCoord = LatLng(lat, lon);
        }
      }
    }

    // Pattern 3: Inverted JSON key-value: "lng": 105.xxx, "lat": 21.xxx
    final invJsonKvRegex = RegExp(r'"?(?:longitude|lng|lon|long)"?\s*:\s*"?(\-\d{1,3}\.\d{4,}|\d{1,3}\.\d{4,})"?\s*,\s*"?(?:latitude|lat)"?\s*:\s*"?(\-\d{1,2}\.\d{4,}|\d{1,2}\.\d{4,})"?', caseSensitive: false);
    for (final m in invJsonKvRegex.allMatches(block)) {
      final lon = double.tryParse(m.group(1)!);
      final lat = double.tryParse(m.group(2)!);
      if (lat != null && lon != null && _isValidCoord(lat, lon)) {
        final dist = (m.start - tokenOffset).abs();
        if (dist < minDistance) {
          minDistance = dist;
          bestCoord = LatLng(lat, lon);
        }
      }
    }

    // Pattern 4: Protobuf !3dlat!4dlon embedded in data string
    final protoTokenRegex = RegExp(r'!3d(\-\d{1,2}\.\d{4,}|\d{1,2}\.\d{4,})[^!]*!4d(\-\d{1,3}\.\d{4,}|\d{1,3}\.\d{4,})');
    for (final m in protoTokenRegex.allMatches(block)) {
      final lat = double.tryParse(m.group(1)!);
      final lon = double.tryParse(m.group(2)!);
      if (lat != null && lon != null && _isValidCoord(lat, lon)) {
        final dist = (m.start - tokenOffset).abs();
        if (dist < minDistance) {
          minDistance = dist;
          bestCoord = LatLng(lat, lon);
        }
      }
    }

    // Pattern 5: HTML data attributes data-lat="21.xxx" data-lng="105.xxx"
    final dataAttrRegex = RegExp(r'data-(?:lat|latitude)=["\x27](\-\d{1,2}\.\d{4,}|\d{1,2}\.\d{4,})["\x27]\s+data-(?:lng|lon|longitude)=["\x27](\-\d{1,3}\.\d{4,}|\d{1,3}\.\d{4,})["\x27]', caseSensitive: false);
    for (final m in dataAttrRegex.allMatches(block)) {
      final lat = double.tryParse(m.group(1)!);
      final lon = double.tryParse(m.group(2)!);
      if (lat != null && lon != null && _isValidCoord(lat, lon)) {
        final dist = (m.start - tokenOffset).abs();
        if (dist < minDistance) {
          minDistance = dist;
          bestCoord = LatLng(lat, lon);
        }
      }
    }

    return bestCoord;
  }

  static bool _isValidCoord(double lat, double lon) {
    if (lat < -90.0 || lat > 90.0 || lon < -180.0 || lon > 180.0) return false;
    if (lat.abs() < 0.0001 && lon.abs() < 0.0001) return false;
    return true;
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

  /// Decode common HTML entities (P5.4.1.1 Section 6)
  static String decodeHtmlEntities(String input) {
    var s = input;
    s = s.replaceAll('&amp;', '&');
    s = s.replaceAll('&quot;', '"');
    s = s.replaceAll('&apos;', "'");
    s = s.replaceAll('&#39;', "'");
    s = s.replaceAll('&lt;', '<');
    s = s.replaceAll('&gt;', '>');
    return s;
  }

  /// Extract <link rel="canonical" href="..."> supporting either attribute order (P5.4.1.1 Section 6)
  static String? extractCanonicalUrl(String html) {
    if (html.isEmpty) return null;
    final r1 = RegExp(r'<link[^>]*rel=["\x27]canonical["\x27][^>]*href=["\x27]([^"\x27]+)["\x27]', caseSensitive: false);
    final m1 = r1.firstMatch(html);
    if (m1 != null) {
      return decodeHtmlEntities(m1.group(1)!.trim());
    }

    final r2 = RegExp(r'<link[^>]*href=["\x27]([^"\x27]+)["\x27][^>]*rel=["\x27]canonical["\x27]', caseSensitive: false);
    final m2 = r2.firstMatch(html);
    if (m2 != null) {
      return decodeHtmlEntities(m2.group(1)!.trim());
    }

    return null;
  }

  /// Extract <meta property="og:url" content="..."> supporting attribute-order variations (P5.4.1.1 Section 7)
  static String? extractOgUrl(String html) {
    if (html.isEmpty) return null;
    final r1 = RegExp(r'<meta[^>]*(?:property|name)=["\x27]og:url["\x27][^>]*content=["\x27]([^"\x27]+)["\x27]', caseSensitive: false);
    final m1 = r1.firstMatch(html);
    if (m1 != null) {
      return decodeHtmlEntities(m1.group(1)!.trim());
    }

    final r2 = RegExp(r'<meta[^>]*content=["\x27]([^"\x27]+)["\x27][^>]*(?:property|name)=["\x27]og:url["\x27]', caseSensitive: false);
    final m2 = r2.firstMatch(html);
    if (m2 != null) {
      return decodeHtmlEntities(m2.group(1)!.trim());
    }

    return null;
  }

  /// Extract Google Place Identity info (ChIJ, CID, Hex Place ID, Slug) with P5.4.1.2 Section 8 Priority
  static String? extractGooglePlaceIdentity(String url, String html) {
    // 1. ChIJ place ID (Priority 1)
    final chijRegex = RegExp(r'\b(ChIJ[a-zA-Z0-9_\-]{20,})\b');
    final chijMatch = chijRegex.firstMatch(url) ?? chijRegex.firstMatch(html);
    if (chijMatch != null) {
      return chijMatch.group(1);
    }

    // 2. cid query parameter or data-cid (Priority 2)
    final cidRegex = RegExp(r'[?&]cid=(\d+)');
    final cidHtmlRegex = RegExp(r'(?:data-cid=["\x27]|"cid"\s*:\s*["\x27]?)(\d+)');
    final cidMatch = cidRegex.firstMatch(url) ?? cidRegex.firstMatch(html) ?? cidHtmlRegex.firstMatch(html);
    if (cidMatch != null) {
      return 'cid:${cidMatch.group(1)}';
    }

    // 3. Data token containing hex place ID pair: 0x...:0x... (Priority 3)
    final hexIdRegex = RegExp(r'(0x[0-9a-fA-F]+:0x[0-9a-fA-F]+)');
    final hexMatch = hexIdRegex.firstMatch(url) ?? hexIdRegex.firstMatch(html);
    if (hexMatch != null) {
      return hexMatch.group(1);
    }

    // 4. Canonical target URL identity / place name (Priority 4)
    final placeNameRegex = RegExp(r'/place/([^/@?]+)');
    final pMatch = placeNameRegex.firstMatch(url);
    if (pMatch != null) {
      final raw = pMatch.group(1)!;
      if (!RegExp(r'^\-?\d{1,2}\.\d+').hasMatch(raw)) {
        return raw.replaceAll('+', ' ').trim();
      }
    }

    return null;
  }

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

  /// Parse DMS format into decimal LatLng
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

  /// Strict URL coordinate extraction respecting Authority Priority
  ({LatLng? exactCoord, LatLng? cameraCoord, String? placeName, String? destQuery}) _parseUrlSemantics(String url) {
    final decoded = Uri.decodeFull(url);
    LatLng? exactCoord;
    LatLng? cameraCoord;
    String? placeName;
    String? destQuery;

    // 1. Camera coordinate: @lat,lon (P5.4.1.1 Section 10 & 27: Never use as exact POI!)
    final atRegex = RegExp(r'@(\-?\d{1,2}\.\d{3,}),(\-?\d{1,3}\.\d{3,})');
    final atMatch = atRegex.firstMatch(decoded);
    if (atMatch != null) {
      final lat = double.tryParse(atMatch.group(1)!);
      final lon = double.tryParse(atMatch.group(2)!);
      if (lat != null && lon != null) {
        cameraCoord = LatLng(lat, lon);
      }
    }

    // 2. Explicit Protobuf destination coordinates: !3dLAT!4dLON or !4dLON!3dLAT
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

    // Protobuf !1d/!2d
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

    // 3. Explicit destination query parameters (?q=LAT,LON, ?destination=LAT,LON, ?daddr=LAT,LON)
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

    // 4. Explicit /place/LAT,LON (Dropped pin)
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

    // 5. Explicit /search/LAT,LON
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

    // 6. /dir/ path - extract destination ONLY
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

  String? _extractTitleFromHtml(String html) {
    if (html.isEmpty) return null;
    final titleMatch = RegExp(r'<title>(.*?)</title>', caseSensitive: false).firstMatch(html);
    if (titleMatch != null) {
      var t = titleMatch.group(1)!.trim();
      t = t.replaceAll(RegExp(r'\s*-\s*Google Maps\s*$', caseSensitive: false), '');
      t = cleanGoogleMapsPrefix(t);
      if (t.isNotEmpty && !t.contains('Google Maps') && !t.contains('404')) {
        return decodeHtmlEntities(t);
      }
    }
    final ogTitleMatch = RegExp(r'<meta[^>]*property=["\x27]og:title["\x27][^>]*content=["\x27]([^"\x27]+)["\x27]', caseSensitive: false).firstMatch(html)
        ?? RegExp(r'<meta[^>]*content=["\x27]([^"\x27]+)["\x27][^>]*property=["\x27]og:title["\x27]', caseSensitive: false).firstMatch(html);
    if (ogTitleMatch != null) {
      var t = ogTitleMatch.group(1)!.trim();
      t = t.replaceAll(RegExp(r'\s*-\s*Google Maps\s*$', caseSensitive: false), '');
      t = cleanGoogleMapsPrefix(t);
      if (t.isNotEmpty && !t.contains('Google Maps')) {
        return decodeHtmlEntities(t);
      }
    }
    return null;
  }

  /// Parse input text / URL and return rich GoogleMapsResolvedLink adhering to P5.4.1.1 Authority Order
  Future<GoogleMapsResolvedLink> parseResolvedLink(String input, {LatLng? userLocation}) async {
    _linkResolutionGeneration++;
    final myGen = _linkResolutionGeneration;

    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      return GoogleMapsResolvedLink(confidence: GoogleMapsResolutionConfidence.unresolved, resolutionSource: 'unresolved');
    }

    // Step 0: DMS Coordinate Check (< 1ms)
    final dmsCoord = parseDms(trimmed);
    if (dmsCoord != null) {
      return GoogleMapsResolvedLink(
        exactCoordinate: dmsCoord,
        exactDestinationCoordinate: dmsCoord,
        confidence: GoogleMapsResolutionConfidence.exactPin,
        precision: PlacePrecision.coordinate,
        resolutionSource: 'original_url',
        rawQuery: trimmed,
        requiresConfirmation: false,
      );
    }

    // Step 0b: Direct Decimal Coordinate Check without URL (e.g. "21.0285, 105.8542")
    final textWithoutUrl = trimmed.replaceAll(RegExp(r'https?://[^\s]+'), '').trim();
    if (textWithoutUrl.isNotEmpty) {
      final coordRegex = RegExp(r'^(\-?\d{1,2}\.\d{3,})[\s,;]+(\-?\d{1,3}\.\d{3,})$');
      final match = coordRegex.firstMatch(textWithoutUrl);
      if (match != null) {
        final lat = double.tryParse(match.group(1)!);
        final lon = double.tryParse(match.group(2)!);
        if (lat != null && lon != null && lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180) {
          final pt = LatLng(lat, lon);
          return GoogleMapsResolvedLink(
            exactCoordinate: pt,
            exactDestinationCoordinate: pt,
            confidence: GoogleMapsResolutionConfidence.exactPin,
            precision: PlacePrecision.coordinate,
            resolutionSource: 'original_url',
            rawQuery: trimmed,
            requiresConfirmation: false,
          );
        }
      }
    }

    // Step 0c: Extract URL
    final urlRegex = RegExp(r'https?://[^\s]+');
    final urlMatch = urlRegex.firstMatch(trimmed);
    if (urlMatch == null) {
      final cleaned = cleanGoogleMapsPrefix(trimmed);
      return GoogleMapsResolvedLink(
        confidence: GoogleMapsResolutionConfidence.unresolved,
        resolutionSource: 'unresolved',
        rawQuery: cleaned,
      );
    }

    String originalUrl = urlMatch.group(0)!;
    String rawPrefix = trimmed.replaceFirst(originalUrl, '').replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim();
    String userPrefix = cleanGoogleMapsPrefix(rawPrefix);

    // Diagnostics tracking (P5.4.1.1 Section 19)
    final origUri = Uri.tryParse(originalUrl);
    int hopCount = 0;
    bool canonicalFound = false;
    bool canonicalHasExact = false;
    bool ogUrlFound = false;
    bool ogUrlHasExact = false;
    bool chijPresent = false;
    bool cidPresent = false;
    bool hexPresent = false;

    // AUTHORITY 1: Exact coordinate already present in original full URL
    final semanticsOriginal = _parseUrlSemantics(originalUrl);
    if (semanticsOriginal.exactCoord != null) {
      final isDir = originalUrl.contains('/dir/');
      return GoogleMapsResolvedLink(
        finalUri: origUri,
        placeName: userPrefix.isNotEmpty ? userPrefix : semanticsOriginal.placeName,
        exactCoordinate: semanticsOriginal.exactCoord,
        exactDestinationCoordinate: semanticsOriginal.exactCoord,
        cameraCoordinate: semanticsOriginal.cameraCoord,
        confidence: isDir
            ? GoogleMapsResolutionConfidence.exactDestination
            : GoogleMapsResolutionConfidence.exactPin,
        precision: semanticsOriginal.placeName != null ? PlacePrecision.poi : PlacePrecision.coordinate,
        resolutionSource: 'original_url',
        requiresConfirmation: false,
        rawQuery: trimmed,
      );
    }

    // Resolve Shortlink or Full URL via Bounded Redirect Resolver
    final isShortLink = originalUrl.contains('maps.app.goo.gl') ||
        originalUrl.contains('goo.gl') ||
        originalUrl.contains('bit.ly') ||
        originalUrl.length < 50;

    String finalUrl = originalUrl;
    String resolvedHtml = '';

    try {
      final resolved = await _redirectResolver.resolve(originalUrl);
      if (myGen != _linkResolutionGeneration) {
        return GoogleMapsResolvedLink(confidence: GoogleMapsResolutionConfidence.unresolved, resolutionSource: 'unresolved');
      }
      if (resolved.finalUrl.isNotEmpty) {
        finalUrl = resolved.finalUrl;
        hopCount = isShortLink ? 1 : 0;
      }
      resolvedHtml = resolved.htmlBody;
    } catch (_) {}

    chijPresent = RegExp(r'\b(ChIJ[a-zA-Z0-9_\-]{20,})\b').hasMatch(finalUrl) ||
        RegExp(r'\b(ChIJ[a-zA-Z0-9_\-]{20,})\b').hasMatch(resolvedHtml);
    cidPresent = RegExp(r'[?&]cid=\d+').hasMatch(finalUrl) ||
        RegExp(r'(?:data-cid=["\x27]|"cid"\s*:\s*["\x27]?)\d+').hasMatch(resolvedHtml);
    hexPresent = RegExp(r'(0x[0-9a-fA-F]+:0x[0-9a-fA-F]+)').hasMatch(finalUrl) ||
        RegExp(r'(0x[0-9a-fA-F]+:0x[0-9a-fA-F]+)').hasMatch(resolvedHtml);

    // AUTHORITY 2: Exact coordinate present in redirected final URL
    final semanticsFinal = _parseUrlSemantics(finalUrl);

    if (semanticsFinal.exactCoord != null) {
      final isDir = finalUrl.contains('/dir/');
      return GoogleMapsResolvedLink(
        finalUri: Uri.tryParse(finalUrl),
        placeName: (userPrefix.isNotEmpty ? userPrefix : null) ?? semanticsFinal.placeName ?? semanticsFinal.destQuery,
        exactCoordinate: semanticsFinal.exactCoord,
        exactDestinationCoordinate: semanticsFinal.exactCoord,
        cameraCoordinate: semanticsFinal.cameraCoord,
        confidence: isDir
            ? GoogleMapsResolutionConfidence.exactDestination
            : GoogleMapsResolutionConfidence.exactPin,
        precision: semanticsFinal.placeName != null ? PlacePrecision.poi : PlacePrecision.coordinate,
        resolutionSource: 'redirected_url',
        requiresConfirmation: false,
        rawQuery: trimmed,
      );
    }

    // AUTHORITY 3: Exact coordinate present in canonical URL from HTML (P5.4.1.1 Section 6)
    final canonicalUrl = extractCanonicalUrl(resolvedHtml);
    if (canonicalUrl != null) {
      canonicalFound = true;
      final semanticsCanonical = _parseUrlSemantics(canonicalUrl);
      if (semanticsCanonical.exactCoord != null) {
        canonicalHasExact = true;
        return GoogleMapsResolvedLink(
          finalUri: Uri.tryParse(canonicalUrl),
          placeName: (userPrefix.isNotEmpty ? userPrefix : null) ?? semanticsCanonical.placeName ?? semanticsFinal.placeName,
          exactCoordinate: semanticsCanonical.exactCoord,
          exactDestinationCoordinate: semanticsCanonical.exactCoord,
          cameraCoordinate: semanticsCanonical.cameraCoord ?? semanticsFinal.cameraCoord,
          confidence: GoogleMapsResolutionConfidence.exactPin,
          precision: PlacePrecision.poi,
          resolutionSource: 'canonical_url',
          requiresConfirmation: false,
          rawQuery: trimmed,
          debugDiagnostics: _formatDiagnostics(
            host: origUri?.host ?? 'maps.app.goo.gl',
            hops: hopCount,
            finalExact: false,
            canonical: true,
            canonicalExact: true,
            og: false,
            ogExact: false,
            chijPresent: chijPresent,
            cidPresent: cidPresent,
            hexPresent: hexPresent,
            identityBoundFound: false,
            source: 'canonical_url',
            confidence: 'exactPin',
            requiresConfirmation: false,
          ),
        );
      }
    }

    // AUTHORITY 4: Exact coordinate present in og:url from HTML (P5.4.1.1 Section 7)
    final ogUrl = extractOgUrl(resolvedHtml);
    if (ogUrl != null) {
      ogUrlFound = true;
      final semanticsOg = _parseUrlSemantics(ogUrl);
      if (semanticsOg.exactCoord != null) {
        ogUrlHasExact = true;
        return GoogleMapsResolvedLink(
          finalUri: Uri.tryParse(ogUrl),
          placeName: (userPrefix.isNotEmpty ? userPrefix : null) ?? semanticsOg.placeName ?? semanticsFinal.placeName,
          exactCoordinate: semanticsOg.exactCoord,
          exactDestinationCoordinate: semanticsOg.exactCoord,
          cameraCoordinate: semanticsOg.cameraCoord ?? semanticsFinal.cameraCoord,
          confidence: GoogleMapsResolutionConfidence.exactPin,
          precision: PlacePrecision.poi,
          resolutionSource: 'og_url',
          requiresConfirmation: false,
          rawQuery: trimmed,
          debugDiagnostics: _formatDiagnostics(
            host: origUri?.host ?? 'maps.app.goo.gl',
            hops: hopCount,
            finalExact: false,
            canonical: canonicalFound,
            canonicalExact: false,
            og: true,
            ogExact: true,
            chijPresent: chijPresent,
            cidPresent: cidPresent,
            hexPresent: hexPresent,
            identityBoundFound: false,
            source: 'og_url',
            confidence: 'exactPin',
            requiresConfirmation: false,
          ),
        );
      }
    }

    // AUTHORITY 5: Identity-bound structured target metadata in HTML (P5.4.1.2 Section 5-9)
    final placeIdentity = extractGooglePlaceIdentity(finalUrl, resolvedHtml);

    final placeTitle = (userPrefix.isNotEmpty ? userPrefix : null) ??
        semanticsFinal.placeName ??
        semanticsFinal.destQuery ??
        _extractTitleFromHtml(resolvedHtml);

    final targetMetadata = GoogleMapsTargetMetadataParser.extract(
      finalUrl: finalUrl,
      htmlBody: resolvedHtml,
      knownPlaceIdentity: placeIdentity,
      pageTitle: placeTitle,
    );

    if (targetMetadata?.targetCoordinate != null) {
        return GoogleMapsResolvedLink(
        finalUri: Uri.tryParse(finalUrl),
        placeName: (userPrefix.isNotEmpty ? userPrefix : null) ?? targetMetadata!.title ?? placeTitle ?? 'Vị trí Google Maps',
        exactCoordinate: targetMetadata!.targetCoordinate,
        exactDestinationCoordinate: targetMetadata.targetCoordinate,
        cameraCoordinate: semanticsFinal.cameraCoord,
        confidence: GoogleMapsResolutionConfidence.exactPin,
        precision: PlacePrecision.poi,
        resolutionSource: 'identity_bound_payload',
        googlePlaceIdentity: targetMetadata.placeIdentity ?? placeIdentity,
        requiresConfirmation: false,
        rawQuery: trimmed,
        debugDiagnostics: _formatDiagnostics(
          host: origUri?.host ?? 'maps.app.goo.gl',
          hops: hopCount,
          finalExact: false,
          canonical: canonicalFound,
          canonicalExact: canonicalHasExact,
          og: ogUrlFound,
          ogExact: ogUrlHasExact,
          chijPresent: chijPresent,
          cidPresent: cidPresent,
          hexPresent: hexPresent,
          identityBoundFound: true,
          source: 'identity_bound_payload',
          confidence: 'exactPin',
          requiresConfirmation: false,
        ),
      );
    }

    // AUTHORITY 6: Named-place resolution with identity validation (P5.4.1.1 Section 12 & 13)
    // IMPORTANT: Named fallback MUST be approximate by default! NOT exactCoordinate!
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
        return GoogleMapsResolvedLink(confidence: GoogleMapsResolutionConfidence.unresolved, resolutionSource: 'unresolved');
      }

      if (searchList.isNotEmpty) {
        final top = searchList.first;
        return GoogleMapsResolvedLink(
          finalUri: Uri.tryParse(finalUrl),
          placeName: top.name,
          exactCoordinate: null, // P5.4.1.1 Section 12 & 15: Must NOT be exactCoordinate!
          exactDestinationCoordinate: null,
          cameraCoordinate: semanticsFinal.cameraCoord,
          independentSearchCandidateCoordinate: top.coordinate, // Store in explicit candidate field
          confidence: GoogleMapsResolutionConfidence.resolvedByIndependentSearch,
          precision: PlacePrecision.approximate,
          address: top.displayName,
          resolutionSource: 'independent_search',
          googlePlaceIdentity: placeIdentity,
          requiresConfirmation: true, // P5.4.1.1 Section 13: Must require confirmation!
          rawQuery: trimmed,
          debugDiagnostics: _formatDiagnostics(
            host: origUri?.host ?? 'maps.app.goo.gl',
            hops: hopCount,
            finalExact: false,
            canonical: canonicalFound,
            canonicalExact: false,
            og: ogUrlFound,
            ogExact: false,
            chijPresent: chijPresent,
            cidPresent: cidPresent,
            hexPresent: hexPresent,
            identityBoundFound: false,
            source: 'independent_search',
            confidence: 'resolvedByIndependentSearch',
            requiresConfirmation: true,
          ),
        );
      }
    }

    // AUTHORITY 7: Camera coordinate only as APPROXIMATE (P5.4.1.1 Section 10 & 27)
    if (semanticsFinal.cameraCoord != null) {
      return GoogleMapsResolvedLink(
        finalUri: Uri.tryParse(finalUrl),
        placeName: placeTitle ?? 'Tâm bản đồ Google Maps',
        exactCoordinate: null,
        exactDestinationCoordinate: null,
        cameraCoordinate: semanticsFinal.cameraCoord,
        confidence: GoogleMapsResolutionConfidence.approximate,
        precision: PlacePrecision.approximate,
        resolutionSource: 'camera_approximate',
        googlePlaceIdentity: placeIdentity,
        requiresConfirmation: true,
        rawQuery: trimmed,
        debugDiagnostics: _formatDiagnostics(
          host: origUri?.host ?? 'maps.app.goo.gl',
          hops: hopCount,
          finalExact: false,
          canonical: canonicalFound,
          canonicalExact: false,
          og: ogUrlFound,
          ogExact: false,
          chijPresent: chijPresent,
          cidPresent: cidPresent,
          hexPresent: hexPresent,
          identityBoundFound: false,
          source: 'camera_approximate',
          confidence: 'approximate',
          requiresConfirmation: true,
        ),
      );
    }

    // AUTHORITY 8: Otherwise UNRESOLVED
    return GoogleMapsResolvedLink(
      finalUri: Uri.tryParse(finalUrl),
      placeName: placeTitle,
      confidence: GoogleMapsResolutionConfidence.unresolved,
      resolutionSource: 'unresolved',
      googlePlaceIdentity: placeIdentity,
      requiresConfirmation: true,
      rawQuery: trimmed,
      debugDiagnostics: _formatDiagnostics(
        host: origUri?.host ?? 'maps.app.goo.gl',
        hops: hopCount,
        finalExact: false,
        canonical: canonicalFound,
        canonicalExact: false,
        og: ogUrlFound,
        ogExact: false,
        chijPresent: chijPresent,
        cidPresent: cidPresent,
        hexPresent: hexPresent,
        identityBoundFound: false,
        source: 'unresolved',
        confidence: 'unresolved',
        requiresConfirmation: true,
      ),
    );
  }

  /// Build a standard MapPlace from resolved link adhering to P5.4.1.1 exact vs approximate rules
  MapPlace? buildMapPlaceFromResolved(GoogleMapsResolvedLink resolved) {
    if (resolved.confidence == GoogleMapsResolutionConfidence.unresolved) {
      return null;
    }

    // Exact destination coordinate (Authority 1-5)
    if (resolved.exactDestinationCoordinate != null) {
      return MapPlace(
        name: resolved.placeName ?? 'Vị trí Google Maps',
        displayName: resolved.address ??
            resolved.placeName ??
            'Tọa độ Google Maps: ${resolved.exactDestinationCoordinate!.latitude.toStringAsFixed(5)}, ${resolved.exactDestinationCoordinate!.longitude.toStringAsFixed(5)}',
        coordinate: resolved.exactDestinationCoordinate!,
        precision: resolved.precision == PlacePrecision.approximate ? PlacePrecision.coordinate : resolved.precision,
        source: 'google_link_exact',
      );
    }

    // Independent search candidate (Authority 6)
    if (resolved.independentSearchCandidateCoordinate != null) {
      return MapPlace(
        name: resolved.placeName ?? 'Vị trí đề xuất',
        displayName: resolved.address ?? resolved.placeName ?? 'Vị trí ước tính từ tìm kiếm độc lập',
        coordinate: resolved.independentSearchCandidateCoordinate!,
        precision: PlacePrecision.approximate,
        source: 'google_link_approximate',
      );
    }

    // Camera coordinate approximate (Authority 7)
    if (resolved.cameraCoordinate != null) {
      return MapPlace(
        name: resolved.placeName ?? 'Tâm bản đồ Google Maps (Ước tính)',
        displayName: 'Vị trí tâm khung nhìn Google Maps: ${resolved.cameraCoordinate!.latitude.toStringAsFixed(5)}, ${resolved.cameraCoordinate!.longitude.toStringAsFixed(5)}',
        coordinate: resolved.cameraCoordinate!,
        precision: PlacePrecision.approximate,
        source: 'google_link_approximate',
      );
    }

    return null;
  }

  /// Parse input string into a MapPlace
  Future<MapPlace?> parseInput(String input, {LatLng? userLocation}) async {
    final resolved = await parseResolvedLink(input, userLocation: userLocation);
    return buildMapPlaceFromResolved(resolved);
  }

  static String? _formatDiagnostics({
    required String host,
    required int hops,
    required bool finalExact,
    required bool canonical,
    required bool canonicalExact,
    required bool og,
    required bool ogExact,
    required bool chijPresent,
    required bool cidPresent,
    required bool hexPresent,
    required bool identityBoundFound,
    required String source,
    required String confidence,
    required bool requiresConfirmation,
  }) {
    if (!kDebugMode) return null;
    return 'GoogleLinkDiagnostics:\n'
        'host=$host\n'
        'hops=$hops\n'
        'finalExact=$finalExact\n'
        'canonical=$canonical\n'
        'canonicalExact=$canonicalExact\n'
        'ogUrl=$og\n'
        'ogExact=$ogExact\n'
        'chijPresent=$chijPresent\n'
        'cidPresent=$cidPresent\n'
        'hexPresent=$hexPresent\n'
        'identityBoundFound=$identityBoundFound\n'
        'resolutionSource=$source\n'
        'confidence=$confidence\n'
        'requiresConfirmation=$requiresConfirmation';
  }
}
