import 'dart:convert';
import 'dart:io';

// Fixed public coordinates in Hanoi, Vietnam (Hoan Kiem Lake to West Lake)
// Public landmarks only, zero private user data.
const double startLat = 21.0285;
const double startLon = 105.8542;
const double destLat = 21.0478;
const double destLon = 105.8368;

Future<void> main() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  int successCount = 0;

  print('===============================================================');
  print('P5.9.2 LIVE ROUTING PROVIDER SMOKE TEST (VIETNAM / HANOI)');
  print('Fixed Public Coordinates: Hoan Kiem ($startLat, $startLon) -> West Lake ($destLat, $destLon)');
  print('===============================================================');

  // 1. Valhalla Motorcycle
  try {
    final sw = Stopwatch()..start();
    final uri = Uri.parse('https://valhalla1.openstreetmap.de/route');
    final req = await client.postUrl(uri);
    req.headers.set('Content-Type', 'application/json');
    req.headers.set('User-Agent', 'ESP32Nav/2.0 (contact@esp32nav.app)');
    req.headers.set('X-Client-Id', 'esp32-ios-nav');

    final body = jsonEncode({
      'locations': [
        {'lat': startLat, 'lon': startLon, 'type': 'break', 'search_cutoff': 500},
        {'lat': destLat, 'lon': destLon, 'type': 'break', 'search_cutoff': 500}
      ],
      'costing': 'motorcycle',
      'directions_options': {
        'units': 'kilometers',
        'language': 'vi-VN'
      }
    });
    req.write(body);
    final resp = await req.close();
    final respBody = await resp.transform(utf8.decoder).join();
    final ms = sw.elapsedMilliseconds;

    if (resp.statusCode == 200) {
      final json = jsonDecode(respBody) as Map<String, dynamic>;
      final trip = json['trip'] as Map<String, dynamic>?;
      final legs = trip?['legs'] as List? ?? [];
      final shape = legs.isNotEmpty ? legs[0]['shape'] : null;
      if (trip != null && legs.isNotEmpty && shape != null) {
        final dist = trip['summary']?['length'] ?? 0;
        print('[SMOKE] Valhalla: HTTP 200, route OK (${dist}km), ${ms}ms');
        successCount++;
      } else {
        print('[SMOKE] Valhalla: HTTP 200, but empty legs/shape, ${ms}ms');
      }
    } else {
      print('[SMOKE] Valhalla: HTTP ${resp.statusCode}, ${ms}ms');
    }
  } catch (e) {
    print('[SMOKE] Valhalla: Exception: $e');
  }

  // 2. OSRM Primary (router.project-osrm.org)
  try {
    final sw = Stopwatch()..start();
    final uri = Uri.parse(
      'https://router.project-osrm.org/route/v1/driving/$startLon,$startLat;$destLon,$destLat?overview=full&geometries=geojson&steps=true&alternatives=true'
    );
    final req = await client.getUrl(uri);
    req.headers.set('User-Agent', 'ESP32Nav/2.0 (contact@esp32nav.app)');
    final resp = await req.close();
    final respBody = await resp.transform(utf8.decoder).join();
    final ms = sw.elapsedMilliseconds;

    if (resp.statusCode == 200) {
      final json = jsonDecode(respBody) as Map<String, dynamic>;
      final code = json['code'];
      final routes = json['routes'] as List? ?? [];
      if (code == 'Ok' && routes.isNotEmpty) {
        final dist = (routes[0]['distance'] as num).toDouble();
        final distKm = (dist / 1000).toStringAsFixed(1);
        print('[SMOKE] OSRM primary: HTTP 200, code=Ok, routes=${routes.length} (${distKm}km), ${ms}ms');
        successCount++;
      } else {
        print('[SMOKE] OSRM primary: HTTP 200, code=$code, routes=0, ${ms}ms');
      }
    } else {
      print('[SMOKE] OSRM primary: HTTP ${resp.statusCode}, ${ms}ms');
    }
  } catch (e) {
    print('[SMOKE] OSRM primary: Exception: $e');
  }

  // 3. OSRM Secondary (routing.openstreetmap.de/routed-car)
  try {
    final sw = Stopwatch()..start();
    final uri = Uri.parse(
      'https://routing.openstreetmap.de/routed-car/route/v1/driving/$startLon,$startLat;$destLon,$destLat?overview=full&geometries=geojson&steps=true&alternatives=true'
    );
    final req = await client.getUrl(uri);
    req.headers.set('User-Agent', 'ESP32Nav/2.0 (contact@esp32nav.app)');
    final resp = await req.close();
    final respBody = await resp.transform(utf8.decoder).join();
    final ms = sw.elapsedMilliseconds;

    if (resp.statusCode == 200) {
      final json = jsonDecode(respBody) as Map<String, dynamic>;
      final code = json['code'];
      final routes = json['routes'] as List? ?? [];
      if (code == 'Ok' && routes.isNotEmpty) {
        final dist = (routes[0]['distance'] as num).toDouble();
        final distKm = (dist / 1000).toStringAsFixed(1);
        print('[SMOKE] OSRM secondary: HTTP 200, code=Ok, routes=${routes.length} (${distKm}km), ${ms}ms');
        successCount++;
      } else {
        print('[SMOKE] OSRM secondary: HTTP 200, code=$code, routes=0, ${ms}ms');
      }
    } else {
      print('[SMOKE] OSRM secondary: HTTP ${resp.statusCode}, ${ms}ms');
    }
  } catch (e) {
    print('[SMOKE] OSRM secondary: Exception: $e');
  }

  // 4. OSRM Nearest Snap Endpoint
  try {
    final sw = Stopwatch()..start();
    final uri = Uri.parse(
      'https://router.project-osrm.org/nearest/v1/driving/105.820,21.055?number=1'
    );
    final req = await client.getUrl(uri);
    req.headers.set('User-Agent', 'ESP32Nav/2.0 (contact@esp32nav.app)');
    final resp = await req.close();
    final respBody = await resp.transform(utf8.decoder).join();
    final ms = sw.elapsedMilliseconds;

    if (resp.statusCode == 200) {
      final json = jsonDecode(respBody) as Map<String, dynamic>;
      final waypoints = json['waypoints'] as List? ?? [];
      if (json['code'] == 'Ok' && waypoints.isNotEmpty) {
        final dist = (waypoints[0]['distance'] as num).toDouble();
        final name = waypoints[0]['name'] ?? 'road';
        print('[SMOKE] OSRM nearest snap: HTTP 200, snapped dist=${dist.toStringAsFixed(1)}m ($name), ${ms}ms');
        successCount++;
      }
    }
  } catch (e) {
    print('[SMOKE] OSRM nearest: Exception: $e');
  }

  client.close();
  print('===============================================================');
  print('SMOKE SUMMARY: $successCount / 4 endpoints responsive and validated');
  print('===============================================================');

  if (successCount == 0) {
    exit(1);
  }
}
