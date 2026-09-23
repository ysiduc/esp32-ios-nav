import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import '../models/route_model.dart';
import 'routing_service.dart';

class ValhallaService implements RoutingService {
  static const String _valhallaBaseUrl = 'https://valhalla1.openstreetmap.de';

  
  static Uri routeUri() => Uri.parse('$_valhallaBaseUrl/route');

  static const Map<String, String> _defaultHeaders = {
    'Content-Type': 'application/json',
    'User-Agent': 'ESP32Nav/2.0 (contact@esp32nav.app)',
    'X-Client-Id': 'esp32-ios-nav',
  };

  @override
  Future<NavRoute?> calculateSingleRoute(
    LatLng start,
    LatLng destination, {
    String costing = 'motorcycle',
  }) {
    return calculateRoute(start, destination, costing: costing);
  }

  /// Calculate Turn-by-Turn Route using Valhalla with rich diagnostic output
  Future<ProviderRouteResult> calculateRouteDetailed(
    LatLng start,
    LatLng destination, {
    String costing = 'motorcycle',
    Duration timeout = const Duration(seconds: 6),
    bool allowLanguageFallback = true,
  }) async {
    final stopwatch = Stopwatch()..start();
    final url = routeUri();

    if (!url.hasScheme || !url.hasAuthority || url.host.isEmpty) {
      return ProviderRouteResult.failure(
        provider: 'valhalla',
        latency: Duration.zero,
        errorType: 'invalidUri',
        safeMessage: 'Cấu hình URL Valhalla không hợp lệ (thiếu host: $url)',
      );
    }

    Map<String, dynamic> buildPayload({bool includeLanguage = true}) {
      final directionsOptions = <String, dynamic>{
        'units': 'kilometers',
      };
      if (includeLanguage) {
        directionsOptions['language'] = 'vi-VN';
      }

      return {
        'locations': [
          {'lat': start.latitude, 'lon': start.longitude, 'type': 'break', 'search_cutoff': 500},
          {'lat': destination.latitude, 'lon': destination.longitude, 'type': 'break', 'search_cutoff': 500}
        ],
        'costing': costing,
        'costing_options': {
          'auto': {'country_crossing_penalty': 2000.0}
        },
        'directions_options': directionsOptions,
      };
    }

    try {
      var response = await http.post(
        url,
        headers: _defaultHeaders,
        body: jsonEncode(buildPayload(includeLanguage: true)),
      ).timeout(timeout);

      // If server rejected custom narrative language (HTTP 400 with language error), retry once without language
      if (response.statusCode == 400 && allowLanguageFallback) {
        final bodyLower = response.body.toLowerCase();
        if (bodyLower.contains('language') || bodyLower.contains('locale')) {
          debugPrint('[Valhalla] Server rejected vi-VN locale, retrying once without custom language...');
          response = await http.post(
            url,
            headers: _defaultHeaders,
            body: jsonEncode(buildPayload(includeLanguage: false)),
          ).timeout(timeout);
        }
      }

      final latency = stopwatch.elapsed;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final route = parseValhallaResponse(data, start, destination);
        if (route != null) {
          return ProviderRouteResult.success(
            provider: 'valhalla',
            routes: [route],
            latency: latency,
            httpStatus: 200,
            apiCode: 'Ok',
          );
        } else {
          return ProviderRouteResult.failure(
            provider: 'valhalla',
            latency: latency,
            httpStatus: 200,
            apiCode: 'EmptyTrip',
            errorType: 'emptyResponse',
            safeMessage: 'Dữ liệu lộ trình Valhalla rỗng',
          );
        }
      }

      // HTTP Non-200 Diagnostic Handling
      String errorType = 'http';
      String? apiCode;
      String safeMessage = 'Lỗi máy chủ Valhalla (HTTP ${response.statusCode})';

      try {
        final errJson = jsonDecode(response.body) as Map<String, dynamic>;
        final errCode = errJson['error_code']?.toString() ?? errJson['status_code']?.toString();
        final errMsg = errJson['error']?.toString() ?? errJson['status']?.toString();
        apiCode = errCode;

        if (response.statusCode == 429) {
          errorType = 'rateLimited';
          safeMessage = 'Dịch vụ định tuyến Valhalla đang quá tải. Hãy thử lại.';
        } else if (response.statusCode == 400) {
          if (errCode == '170' || errCode == '171' || (errMsg != null && (errMsg.contains('No suitable edges') || errMsg.contains('No route found')))) {
            errorType = 'noSegment';
            safeMessage = 'Không tìm thấy đoạn đường phù hợp gần tọa độ (Valhalla)';
          } else {
            errorType = 'invalidRequest';
            safeMessage = 'Yêu cầu định tuyến Valhalla không hợp lệ: ${errMsg ?? ""}';
          }
        }
      } catch (_) {
        if (response.statusCode == 429) {
          errorType = 'rateLimited';
          safeMessage = 'Dịch vụ định tuyến Valhalla đang quá tải. Hãy thử lại.';
        }
      }

      debugPrint('[Valhalla] Failed: status=${response.statusCode}, type=$errorType, code=$apiCode, latency=${latency.inMilliseconds}ms');
      return ProviderRouteResult.failure(
        provider: 'valhalla',
        latency: latency,
        httpStatus: response.statusCode,
        apiCode: apiCode,
        errorType: errorType,
        safeMessage: safeMessage,
      );
    } on TimeoutException {
      final latency = stopwatch.elapsed;
      debugPrint('[Valhalla] Timeout after ${latency.inMilliseconds}ms');
      return ProviderRouteResult.failure(
        provider: 'valhalla',
        latency: latency,
        errorType: 'timeout',
        safeMessage: 'Quá thời gian kết nối dịch vụ Valhalla',
      );
    } on SocketException catch (e) {
      final latency = stopwatch.elapsed;
      final isDns = e.message.toLowerCase().contains('failed host lookup');
      final errorType = isDns ? 'dns' : 'network';
      debugPrint('[Valhalla] Network error ($errorType): $e');
      return ProviderRouteResult.failure(
        provider: 'valhalla',
        latency: latency,
        errorType: errorType,
        safeMessage: isDns
            ? 'Không thể phân giải địa chỉ máy chủ Valhalla (DNS)'
            : 'Không thể kết nối mạng tới Valhalla',
      );
    } on HandshakeException catch (e) {
      final latency = stopwatch.elapsed;
      debugPrint('[Valhalla] TLS error: $e');
      return ProviderRouteResult.failure(
        provider: 'valhalla',
        latency: latency,
        errorType: 'tls',
        safeMessage: 'Lỗi bảo mật kết nối Valhalla (TLS)',
      );
    } catch (e) {
      final latency = stopwatch.elapsed;
      final errStr = e.toString().toLowerCase();
      String errorType = 'network';
      if (errStr.contains('no host specified') || errStr.contains('invalid uri') || errStr.contains('relative uri')) {
        errorType = 'invalidUri';
      } else if (errStr.contains('handshake') || errStr.contains('certificate')) {
        errorType = 'tls';
      } else if (errStr.contains('failed host lookup')) {
        errorType = 'dns';
      } else if (e is FormatException) {
        errorType = 'parseError';
      }
      debugPrint('[Valhalla] Exception ($errorType): $e');
      return ProviderRouteResult.failure(
        provider: 'valhalla',
        latency: latency,
        errorType: errorType,
        safeMessage: 'Lỗi kết nối Valhalla: $e',
      );
    }
  }

  /// Backward-compatible single route calculation
  Future<NavRoute?> calculateRoute(
    LatLng start,
    LatLng destination, {
    String costing = 'motorcycle',
  }) async {
    final result = await calculateRouteDetailed(start, destination, costing: costing);
    return result.routes.isNotEmpty ? result.routes.first : null;
  }

  /// Public parser helper for production response or offline test fixtures
  static NavRoute? parseValhallaResponse(
    Map<String, dynamic> data,
    LatLng start,
    LatLng destination,
  ) {
    try {
      final trip = data['trip'] as Map<String, dynamic>?;
      if (trip == null || (trip['legs'] as List).isEmpty) {
        return null;
      }

      final leg = trip['legs'][0] as Map<String, dynamic>;
      final summary = trip['summary'] as Map<String, dynamic>;
      final totalDistanceMeters = ((summary['length'] as num).toDouble()) * 1000.0;
      final totalDurationSeconds = (summary['time'] as num).toDouble();

      // Decode Valhalla Encoded Shape (Polyline6)
      final shapeStr = leg['shape'] as String;
      final polylinePoints = decodePolyline6(shapeStr);

      // Parse Valhalla Maneuvers for Turn-by-Turn & ESP32
      final steps = <NavStep>[];
      final maneuvers = leg['maneuvers'] as List? ?? [];

      int globalIndex = 0;
      for (final m in maneuvers) {
        final instruction = (m['instruction'] as String? ?? '').trim();
        final streetNames = (m['street_names'] as List?)?.map((e) => e.toString()).toList() ?? [];
        final streetName = streetNames.isNotEmpty ? streetNames.first : 'Tiếp tục đi thẳng';
        final distanceMeters = ((m['length'] as num).toDouble()) * 1000.0;
        final durationSeconds = (m['time'] as num).toDouble();

        final valhallaType = m['type'] as int? ?? 0;
        final shapeIndex = m['begin_shape_index'] as int? ?? 0;
        final endShapeIndex = m['end_shape_index'] as int?;
        final coord = (shapeIndex < polylinePoints.length)
            ? polylinePoints[shapeIndex]
            : (polylinePoints.isNotEmpty ? polylinePoints.last : start);

        final mappedTypeStr = mapValhallaTypeToString(valhallaType);

        steps.add(NavStep(
          stepIndex: globalIndex++,
          instruction: instruction.isNotEmpty ? instruction : 'Tiếp tục trên $streetName',
          streetName: streetName,
          distanceMeters: distanceMeters,
          durationSeconds: durationSeconds,
          coordinate: coord,
          maneuverTypeStr: mappedTypeStr,
          maneuverModifier: mapValhallaTypeToModifier(valhallaType),
          beginShapeIndex: shapeIndex,
          endShapeIndex: endShapeIndex,
          valhallaType: valhallaType,
        ));
      }

      return NavRoute(
        title: leg['summary']?['name'] ?? 'Lộ trình Valhalla',
        subtitle: 'Tuyến xe máy tối ưu',
        totalDistanceMeters: totalDistanceMeters,
        totalDurationSeconds: totalDurationSeconds,
        polylinePoints: polylinePoints,
        steps: steps,
        summary: leg['summary']?['name'] ?? 'Lộ trình Valhalla',
        provider: 'valhalla',
        isFallbackSynthetic: false,
      );
    } catch (e) {
      debugPrint('[Valhalla] Parsing error: $e');
      return null;
    }
  }

  /// Decode Valhalla Precision 6 Polyline
  static List<LatLng> decodePolyline6(String encoded) {
    final poly = <LatLng>[];
    int index = 0, len = encoded.length;
    int lat = 0, lng = 0;

    while (index < len) {
      int b, shift = 0, result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lat += dlat;

      shift = 0;
      result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lng += dlng;

      poly.add(LatLng(lat / 1e6, lng / 1e6));
    }
    return poly;
  }

  static String mapValhallaTypeToString(int type) {
    if (type == 4 || type == 5 || type == 6) return 'arrive';
    if (type == 1 || type == 2 || type == 3) return 'depart';
    if (type == 26 || type == 27) return 'roundabout';
    if (type == 17 || type == 18 || type == 19) return 'ramp';
    if (type == 20 || type == 21) return 'exit';
    if (type == 25) return 'merge';
    return 'turn';
  }

  static String mapValhallaTypeToModifier(int type) {
    switch (type) {
      case 2: // kStartRight
      case 9: // kSlightRight
      case 18: // kRampRight
      case 20: // kExitRight
      case 23: // kStayRight
        return 'slight right';
      case 10: // kRight
        return 'right';
      case 11: // kSharpRight
        return 'sharp right';
      case 12: // kUturnRight
      case 13: // kUturnLeft
        return 'u-turn';
      case 14: // kSharpLeft
        return 'sharp left';
      case 15: // kLeft
        return 'left';
      case 3: // kStartLeft
      case 16: // kSlightLeft
      case 19: // kRampLeft
      case 21: // kExitLeft
      case 24: // kStayLeft
        return 'slight left';
      case 7: // kBecomes
      case 8: // kContinue
      case 17: // kRampStraight
      case 22: // kStayStraight
      default:
        return 'straight';
    }
  }
}
