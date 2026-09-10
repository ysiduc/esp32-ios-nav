import 'dart:io';
import 'package:latlong2/latlong.dart';
import '../models/route_model.dart';
import 'search_service.dart';

class ParsedGoogleRoute {
  final LatLng? origin;
  final LatLng destination;
  final List<LatLng> waypoints;
  final String? originName;
  final String destinationName;
  final List<String> waypointNames;
  final String? summary;

  List<LatLng> get allStops {
    final list = <LatLng>[];
    if (origin != null) list.add(origin!);
    list.addAll(waypoints);
    list.add(destination);
    return list;
  }

  ParsedGoogleRoute({
    this.origin,
    required this.destination,
    this.waypoints = const [],
    this.originName,
    required this.destinationName,
    this.waypointNames = const [],
    this.summary,
  });
}

class GoogleMapsParser {
  final SearchService _searchService = SearchService();

  /// Check if an input text contains a Google Maps link or coordinates
  static bool isGoogleMapsOrCoordInput(String text) {
    final t = text.toLowerCase().trim();
    if (t.contains('maps.app.goo.gl') ||
        t.contains('goo.gl/maps') ||
        t.contains('google.com/maps') ||
        t.contains('maps.google.com') ||
        t.contains('geo:') ||
        t.contains('/dir/')) {
      return true;
    }

    // Coordinate pattern: 21.0285, 105.8542
    final coordRegex = RegExp(r'(\-?\d{1,2}\.\d{3,})\s*,\s*(\-?\d{1,3}\.\d{3,})');
    return coordRegex.hasMatch(text);
  }

  /// Check if input is specifically a multi-point directions / route link
  static bool isDirectionsRouteInput(String text) {
    final t = text.toLowerCase().trim();
    return t.contains('/maps/dir/') ||
        t.contains('destination=') ||
        (t.contains('origin=') && t.contains('destination='));
  }

  /// Parse either a full Shared Route or a Single Destination Place
  Future<dynamic> parseInputOrRoute(String input, {LatLng? userLocation}) async {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;

    // 1. Check if it's a URL (shortlink or long Google Maps link)
    final urlRegex = RegExp(r'https?://[^\s]+');
    final urlMatch = urlRegex.firstMatch(trimmed);
    String urlStr = urlMatch != null ? urlMatch.group(0)! : '';
    String userPrefixName = urlMatch != null ? trimmed.replaceFirst(urlStr, '').trim() : '';

    if (urlStr.isNotEmpty) {
      final isShortLink = urlStr.contains('maps.app.goo.gl') ||
          urlStr.contains('goo.gl') ||
          urlStr.contains('bit.ly') ||
          urlStr.contains('t.co') ||
          urlStr.length < 45;

      if (isShortLink) {
        try {
          final resolved = await _resolveRedirects(urlStr);
          if (resolved.isNotEmpty) {
            urlStr = resolved;
          }
        } catch (_) {}
      }

      // Check if resolved URL is a Directions / Route link
      if (urlStr.contains('/maps/dir/') || urlStr.contains('destination=')) {
        final parsedRoute = await _parseDirectionsUrl(urlStr, userPrefixName: userPrefixName, userLocation: userLocation);
        if (parsedRoute != null) {
          return parsedRoute;
        }
      }
    }

    // 2. Fallback to standard single-place parser
    return await parseInput(input, userLocation: userLocation);
  }

  /// Parse Google Maps link or shared text or coordinates into a MapPlace
  Future<MapPlace?> parseInput(String input, {LatLng? userLocation}) async {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;

    // 1. Direct Coordinate Match (only when input is not a URL, e.g. "21.0285, 105.8542")
    if (!trimmed.toLowerCase().startsWith('http://') && !trimmed.toLowerCase().startsWith('https://')) {
      final coordRegex = RegExp(r'^\s*(\-?\d{1,2}\.\d{3,})\s*,\s*(\-?\d{1,3}\.\d{3,})\s*$');
      final match = coordRegex.firstMatch(trimmed);
      if (match != null) {
        final lat = double.tryParse(match.group(1)!);
        final lon = double.tryParse(match.group(2)!);
        if (lat != null && lon != null && lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180) {
          final coord = LatLng(lat, lon);
          return MapPlace(
            name: 'Tọa độ (${coord.latitude.toStringAsFixed(4)}, ${coord.longitude.toStringAsFixed(4)})',
            displayName: 'Tọa độ GPS: ${coord.latitude.toStringAsFixed(6)}, ${coord.longitude.toStringAsFixed(6)}',
            coordinate: coord,
            type: 'coordinate',
            category: 'place',
          );
        }
      }
    }

    // 2. Extract URL and leading/trailing title
    final urlRegex = RegExp(r'https?://[^\s]+');
    final urlMatch = urlRegex.firstMatch(trimmed);
    if (urlMatch == null) {
      // Fallback to regular search
      final searchList = await _searchService.searchPlaces(trimmed, nearLocation: userLocation);
      return searchList.isNotEmpty ? searchList.first : null;
    }

    String urlStr = urlMatch.group(0)!;
    String userPrefixName = trimmed.replaceFirst(urlStr, '').trim();

    // 3. Fast Coordinate Extraction BEFORE redirect if URL already contains coordinates (0 ms!)
    final fastCoord = _extractCoordinateFromUrl(urlStr);
    if (fastCoord != null) {
      final urlPlaceName = _extractPlaceNameFromUrl(urlStr);
      final placeName = userPrefixName.isNotEmpty
          ? userPrefixName
          : (urlPlaceName != null && urlPlaceName.isNotEmpty
              ? urlPlaceName
              : 'Điểm Google Maps (${fastCoord.latitude.toStringAsFixed(4)}, ${fastCoord.longitude.toStringAsFixed(4)})');

      return MapPlace(
        name: placeName,
        displayName: '$placeName (${fastCoord.latitude.toStringAsFixed(4)}, ${fastCoord.longitude.toStringAsFixed(4)})',
        coordinate: fastCoord,
        type: 'destination',
        category: 'place',
      );
    }

    // 4. Resolve Shortlinks & Redirects if it's a short URL
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

    // 5. Extract Coordinates from resolved Google Maps URL
    final extractedCoord = _extractCoordinateFromUrl(urlStr);
    if (extractedCoord != null) {
      final urlPlaceName = _extractPlaceNameFromUrl(urlStr);
      final placeName = userPrefixName.isNotEmpty
          ? userPrefixName
          : (urlPlaceName != null && urlPlaceName.isNotEmpty
              ? urlPlaceName
              : 'Điểm Google Maps (${extractedCoord.latitude.toStringAsFixed(4)}, ${extractedCoord.longitude.toStringAsFixed(4)})');

      return MapPlace(
        name: placeName,
        displayName: '$placeName (${extractedCoord.latitude.toStringAsFixed(4)}, ${extractedCoord.longitude.toStringAsFixed(4)})',
        coordinate: extractedCoord,
        type: 'destination',
        category: 'place',
      );
    }

    // 6. If only a query exists in the URL (e.g. ?q=Landmark+72)
    final queryName = _extractQueryFromUrl(urlStr) ?? (userPrefixName.isNotEmpty ? userPrefixName : null);
    if (queryName != null && queryName.isNotEmpty) {
      final list = await _searchService.searchPlaces(queryName, nearLocation: userLocation);
      if (list.isNotEmpty) return list.first;
    }

    return null;
  }

  /// Parse a Google Maps Directions / Route URL with Origin, Waypoints & Destination
  Future<ParsedGoogleRoute?> _parseDirectionsUrl(
    String url, {
    String userPrefixName = '',
    LatLng? userLocation,
  }) async {
    final decoded = Uri.decodeFull(url);
    final uri = Uri.tryParse(decoded);

    // List to store parsed coordinates in sequential order
    final List<LatLng> collectedCoords = [];
    final List<String> stopNames = [];

    // --- Format 1: Query parameters (?origin=...&destination=...&waypoints=...) ---
    if (uri != null && (uri.queryParameters.containsKey('destination') || uri.queryParameters.containsKey('origin'))) {
      final originParam = uri.queryParameters['origin'];
      final destParam = uri.queryParameters['destination'];
      final waypointsParam = uri.queryParameters['waypoints'];

      LatLng? originCoord;
      LatLng? destCoord;
      final List<LatLng> waypointCoords = [];

      if (originParam != null && originParam.isNotEmpty) {
        originCoord = _parseCoordString(originParam) ?? await _geocodePlaceName(originParam, userLocation);
      }
      if (destParam != null && destParam.isNotEmpty) {
        destCoord = _parseCoordString(destParam) ?? await _geocodePlaceName(destParam, userLocation);
      }
      if (waypointsParam != null && waypointsParam.isNotEmpty) {
        final parts = waypointsParam.split(RegExp(r'\||%7C'));
        for (final p in parts) {
          final c = _parseCoordString(p) ?? await _geocodePlaceName(p, userLocation);
          if (c != null) waypointCoords.add(c);
        }
      }

      if (destCoord != null) {
        return ParsedGoogleRoute(
          origin: originCoord,
          destination: destCoord,
          waypoints: waypointCoords,
          originName: originParam ?? 'Điểm xuất phát',
          destinationName: destParam ?? (userPrefixName.isNotEmpty ? userPrefixName : 'Điểm đến Google Maps'),
          summary: 'Lộ trình Google Maps với ${waypointCoords.length} điểm dừng',
        );
      }
    }

    // --- Format 2: Path segments in /maps/dir/part1/part2/part3/... ---
    if (decoded.contains('/maps/dir/')) {
      final afterDir = decoded.substring(decoded.indexOf('/maps/dir/') + 10);
      // Remove everything after @ or ? or data=
      final pathPart = afterDir.split(RegExp(r'[@?]|/data='))[0];
      final segments = pathPart.split('/').where((s) => s.trim().isNotEmpty).toList();

      if (segments.length >= 2) {
        for (final seg in segments) {
          final coord = _parseCoordString(seg) ?? await _geocodePlaceName(seg.replaceAll('+', ' '), userLocation);
          if (coord != null) {
            collectedCoords.add(coord);
            stopNames.add(seg.replaceAll('+', ' '));
          }
        }
      }
    }

    // --- Format 3: Protobuf coordinates in data= parameter (!1d<lon>!2d<lat> or !3d<lat>!4d<lon>) ---
    if (collectedCoords.length < 2) {
      final protoRegex = RegExp(r'(?:!3d(\-?\d{1,2}\.\d{3,})!4d(\-?\d{1,3}\.\d{3,}))|(?:!1d(\-?\d{1,3}\.\d{3,})!2d(\-?\d{1,2}\.\d{3,}))');
      final matches = protoRegex.allMatches(decoded);
      for (final m in matches) {
        if (m.group(1) != null && m.group(2) != null) {
          final lat = double.tryParse(m.group(1)!);
          final lon = double.tryParse(m.group(2)!);
          if (lat != null && lon != null) {
            collectedCoords.add(LatLng(lat, lon));
          }
        } else if (m.group(3) != null && m.group(4) != null) {
          final lon = double.tryParse(m.group(3)!);
          final lat = double.tryParse(m.group(4)!);
          if (lat != null && lon != null) {
            collectedCoords.add(LatLng(lat, lon));
          }
        }
      }
    }

    if (collectedCoords.length >= 2) {
      final origin = collectedCoords.first;
      final destination = collectedCoords.last;
      final waypoints = collectedCoords.sublist(1, collectedCoords.length - 1);

      final originName = stopNames.isNotEmpty ? stopNames.first : 'Điểm bắt đầu';
      final destName = stopNames.length > 1
          ? stopNames.last
          : (userPrefixName.isNotEmpty ? userPrefixName : 'Điểm đến Google Maps');

      return ParsedGoogleRoute(
        origin: origin,
        destination: destination,
        waypoints: waypoints,
        originName: originName,
        destinationName: destName,
        summary: 'Lộ trình Google Maps (${collectedCoords.length} điểm)',
      );
    }

    return null;
  }

  LatLng? _parseCoordString(String str) {
    final clean = str.trim();
    final coordRegex = RegExp(r'^(\-?\d{1,2}\.\d{3,})\s*,\s*(\-?\d{1,3}\.\d{3,})$');
    final match = coordRegex.firstMatch(clean);
    if (match != null) {
      final lat = double.tryParse(match.group(1)!);
      final lon = double.tryParse(match.group(2)!);
      if (lat != null && lon != null && lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180) {
        return LatLng(lat, lon);
      }
    }
    return null;
  }

  Future<LatLng?> _geocodePlaceName(String query, LatLng? nearLocation) async {
    final clean = query.trim().replaceAll('+', ' ');
    if (clean.isEmpty) return null;
    try {
      final places = await _searchService.searchPlaces(clean, nearLocation: nearLocation);
      if (places.isNotEmpty) {
        return places.first.coordinate;
      }
    } catch (_) {}
    return null;
  }

  /// Resolve HTTP redirects for shortlinks (fast 1200ms timeout)
  Future<String> _resolveRedirects(String urlStr) async {
    try {
      final client = HttpClient()..connectionTimeout = const Duration(milliseconds: 1200);
      client.userAgent = 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15';

      String currentUrl = urlStr;
      for (int redirectCount = 0; redirectCount < 4; redirectCount++) {
        final uri = Uri.tryParse(currentUrl);
        if (uri == null) break;

        final request = await client.getUrl(uri).timeout(const Duration(milliseconds: 1200));
        request.followRedirects = false;
        final response = await request.close().timeout(const Duration(milliseconds: 1200));

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
    } catch (_) {
      return urlStr;
    }
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

