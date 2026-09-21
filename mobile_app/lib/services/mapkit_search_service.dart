import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';
import '../models/route_model.dart';

abstract class MapKitSearchClient {
  Future<List<Map<String, dynamic>>> autocomplete(String query, {LatLng? userLocation});
  Future<Map<String, dynamic>?> resolve(String completionId);
  Future<List<Map<String, dynamic>>> search(String query, {LatLng? userLocation});
}

class MethodChannelMapKitSearchClient implements MapKitSearchClient {
  static const MethodChannel _channel = MethodChannel('com.ysiduc.esp32_nav/mapkit_search');

  bool get _isIos => !kIsWeb && Platform.isIOS;

  @override
  Future<List<Map<String, dynamic>>> autocomplete(String query, {LatLng? userLocation}) async {
    if (!_isIos) return [];
    try {
      final res = await _channel.invokeListMethod<dynamic>('autocomplete', {
        'query': query,
        if (userLocation != null) 'userLat': userLocation.latitude,
        if (userLocation != null) 'userLon': userLocation.longitude,
      });
      if (res == null) return [];
      return res.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (_) {
      return [];
    }
  }

  @override
  Future<Map<String, dynamic>?> resolve(String completionId) async {
    if (!_isIos) return null;
    try {
      final res = await _channel.invokeMapMethod<dynamic, dynamic>('resolve', {
        'completionID': completionId,
      });
      return res != null ? Map<String, dynamic>.from(res) : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<Map<String, dynamic>>> search(String query, {LatLng? userLocation}) async {
    if (!_isIos) return [];
    try {
      final res = await _channel.invokeListMethod<dynamic>('search', {
        'query': query,
        if (userLocation != null) 'userLat': userLocation.latitude,
        if (userLocation != null) 'userLon': userLocation.longitude,
      });
      if (res == null) return [];
      return res.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (_) {
      return [];
    }
  }
}

class MapKitSearchService {
  final MapKitSearchClient _client;

  MapKitSearchService({MapKitSearchClient? client})
      : _client = client ?? MethodChannelMapKitSearchClient();

  static PlacePrecision _parsePrecision(String? precStr) {
    if (precStr == null) return PlacePrecision.poi;
    switch (precStr.toLowerCase()) {
      case 'exactaddress':
      case 'address':
        return PlacePrecision.exactAddress;
      case 'building':
        return PlacePrecision.building;
      case 'street':
        return PlacePrecision.street;
      case 'district':
        return PlacePrecision.district;
      case 'city':
        return PlacePrecision.city;
      case 'neighborhood':
        return PlacePrecision.neighborhood;
      case 'poi':
      default:
        return PlacePrecision.poi;
    }
  }

  /// Perform direct search using Apple MapKit
  Future<List<MapPlace>> search(String query, {LatLng? userLocation}) async {
    final rawResults = await _client.search(query, userLocation: userLocation);
    const distCalc = Distance();

    return rawResults.map((item) {
      final lat = (item['latitude'] as num?)?.toDouble() ?? 0.0;
      final lon = (item['longitude'] as num?)?.toDouble() ?? 0.0;
      final coord = LatLng(lat, lon);
      final title = (item['title'] as String?) ?? query;
      final subtitle = (item['subtitle'] as String?) ?? '';
      final displayName = subtitle.isNotEmpty ? '$title, $subtitle' : title;
      final prec = _parsePrecision(item['precision'] as String?);

      double? dist;
      if (userLocation != null && lat != 0.0 && lon != 0.0) {
        dist = distCalc.as(LengthUnit.Meter, userLocation, coord);
      }

      return MapPlace(
        name: title,
        displayName: displayName,
        coordinate: coord,
        placeId: item['id'] as String?,
        precision: prec,
        source: 'apple_mapkit',
        distanceMeters: dist,
      );
    }).where((p) => p.coordinate.latitude != 0.0 && p.coordinate.longitude != 0.0).toList();
  }

  /// Autocomplete and resolve top completions
  Future<List<MapPlace>> autocomplete(String query, {LatLng? userLocation, int maxResolve = 5}) async {
    final completions = await _client.autocomplete(query, userLocation: userLocation);
    if (completions.isEmpty) return [];

    final resolved = <MapPlace>[];
    for (int i = 0; i < completions.length && i < maxResolve; i++) {
      final c = completions[i];
      final id = c['id'] as String?;
      if (id != null) {
        final res = await _client.resolve(id);
        if (res != null) {
          final lat = (res['latitude'] as num?)?.toDouble() ?? 0.0;
          final lon = (res['longitude'] as num?)?.toDouble() ?? 0.0;
          if (lat != 0.0 && lon != 0.0) {
            final coord = LatLng(lat, lon);
            final title = (res['title'] as String?) ?? (c['title'] as String?) ?? query;
            final subtitle = (res['subtitle'] as String?) ?? (c['subtitle'] as String?) ?? '';
            final displayName = subtitle.isNotEmpty ? '$title, $subtitle' : title;
            final prec = _parsePrecision(res['precision'] as String?);

            double? dist;
            if (userLocation != null) {
              dist = const Distance().as(LengthUnit.Meter, userLocation, coord);
            }

            resolved.add(MapPlace(
              name: title,
              displayName: displayName,
              coordinate: coord,
              placeId: id,
              precision: prec,
              source: 'apple_mapkit',
              distanceMeters: dist,
            ));
          }
        }
      }
    }
    return resolved;
  }
}
