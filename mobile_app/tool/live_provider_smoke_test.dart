import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile_app/services/mapbox_directions_service.dart';
import 'package:mobile_app/services/valhalla_service.dart';

// Fixed public coordinates in Hanoi, Vietnam
const startHanoi = LatLng(21.0285, 105.8542); // Hoan Kiem
const destHanoi = LatLng(21.0478, 105.8368);  // West Lake
const startDinhCong = LatLng(20.9785, 105.8340); // Dinh Cong / Dai Kim
const destTanTien = LatLng(20.8950, 105.6550);   // Tan Tien, Chuong My

void main() {
  test('P5.9.3 Live Routing Provider Smoke Test & Production Services', () async {
    HttpOverrides.global = null;

    print('===============================================================');
    print('P5.9.3 LIVE ROUTING PROVIDER SMOKE TEST (VIETNAM / HANOI)');
    print('===============================================================');

    // 1. RAW PROBE: Valhalla
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final sw = Stopwatch()..start();
      final req = await client.postUrl(ValhallaService.routeUri());
      req.headers.set('Content-Type', 'application/json');
      req.headers.set('User-Agent', 'ESP32Nav/2.0 (contact@esp32nav.app)');
      req.headers.set('X-Client-Id', 'esp32-ios-nav');

      final body = jsonEncode({
        'locations': [
          {'lat': startHanoi.latitude, 'lon': startHanoi.longitude, 'type': 'break', 'search_cutoff': 500},
          {'lat': destHanoi.latitude, 'lon': destHanoi.longitude, 'type': 'break', 'search_cutoff': 500}
        ],
        'costing': 'motorcycle',
        'directions_options': {'units': 'kilometers', 'language': 'vi-VN'}
      });
      req.write(body);
      final resp = await req.close();
      final ms = sw.elapsedMilliseconds;
      print('[SMOKE] Valhalla raw: HTTP ${resp.statusCode}, ${ms}ms');
    } catch (e) {
      print('[SMOKE] Valhalla raw exception: $e');
    }

    // 2. RAW PROBE: OSRM Primary
    try {
      final sw = Stopwatch()..start();
      final uri = Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/${startHanoi.longitude},${startHanoi.latitude};${destHanoi.longitude},${destHanoi.latitude}?overview=full&geometries=geojson&steps=true&alternatives=true'
      );
      final req = await client.getUrl(uri);
      req.headers.set('User-Agent', 'ESP32Nav/2.0 (contact@esp32nav.app)');
      final resp = await req.close();
      final ms = sw.elapsedMilliseconds;
      print('[SMOKE] OSRM primary raw: HTTP ${resp.statusCode}, ${ms}ms');
    } catch (e) {
      print('[SMOKE] OSRM primary raw exception: $e');
    }

    // 3. RAW PROBE: OSRM Secondary
    try {
      final sw = Stopwatch()..start();
      final uri = Uri.parse(
        'https://routing.openstreetmap.de/routed-car/route/v1/driving/${startHanoi.longitude},${startHanoi.latitude};${destHanoi.longitude},${destHanoi.latitude}?overview=full&geometries=geojson&steps=true&alternatives=true'
      );
      final req = await client.getUrl(uri);
      req.headers.set('User-Agent', 'ESP32Nav/2.0 (contact@esp32nav.app)');
      final resp = await req.close();
      final ms = sw.elapsedMilliseconds;
      print('[SMOKE] OSRM secondary raw: HTTP ${resp.statusCode}, ${ms}ms');
    } catch (e) {
      print('[SMOKE] OSRM secondary raw exception: $e');
    }

    client.close();

    // 4. PRODUCTION SERVICE SMOKE: ValhallaService
    final valhallaService = ValhallaService();
    final valRes = await valhallaService.calculateRouteDetailed(
      startHanoi,
      destHanoi,
      costing: 'motorcycle',
    );
    final valPass = valRes.success && valRes.routes.isNotEmpty && valRes.routes.first.polylinePoints.length > 2;
    if (valPass) {
      print('[PROD-SMOKE] ValhallaService: PASS (HTTP ${valRes.httpStatus}, ${valRes.latency.inMilliseconds}ms, dist=${valRes.routes.first.formattedDistance})');
    } else {
      print('[PROD-SMOKE] ValhallaService: FAIL (${valRes.errorType}: ${valRes.safeMessage})');
    }

    // 5. FULL PRODUCTION ROUTING PIPELINE: MapboxDirectionsService (Bike)
    final pipeline = MapboxDirectionsService();
    final pipeRes = await pipeline.calculateRoutesDetailed(
      startHanoi,
      destHanoi,
      mode: 'bike',
    );
    final pipePass = pipeRes.isSuccess && pipeRes.routes.isNotEmpty && pipeRes.routes.first.polylinePoints.length > 2;
    if (pipePass) {
      print('[PROD-SMOKE] RoutingPipeline bike: PASS (${pipeRes.provider.name}, ${pipeRes.latency.inMilliseconds}ms, routes=${pipeRes.routes.length})');
    } else {
      print('[PROD-SMOKE] RoutingPipeline bike: FAIL (${pipeRes.errorMessage})');
    }

    // 6. FIELD-LIKE ROUTING: Dinh Cong -> Tan Tien (Bike)
    final fieldRes = await pipeline.calculateRoutesDetailed(
      startDinhCong,
      destTanTien,
      mode: 'bike',
    );
    final fieldPass = fieldRes.isSuccess && fieldRes.routes.isNotEmpty && fieldRes.routes.first.totalDistanceMeters > 20000;
    if (fieldPass) {
      print('[PROD-SMOKE] Field Route Dinh Cong -> Tan Tien: PASS (${fieldRes.provider.name}, ${fieldRes.latency.inMilliseconds}ms, dist=${fieldRes.routes.first.formattedDistance})');
    } else {
      print('[PROD-SMOKE] Field Route Dinh Cong -> Tan Tien: FAIL (${fieldRes.errorMessage})');
    }

    print('===============================================================');

    // Assert that the production pipeline succeeded
    expect(pipePass || valPass, isTrue, reason: 'At least one production service (Valhalla or full pipeline) must pass');
  });
}
