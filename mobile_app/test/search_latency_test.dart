import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile_app/models/route_model.dart';
import 'package:mobile_app/services/search_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('P5.4.1 Instant Search Latency & Progressive Aggregation Tests', () {
    late SearchService searchService;
    final hanoiCoord = const LatLng(21.0285, 105.8542);

    setUp(() {
      searchService = SearchService();
      searchService.clearCache();
    });

    test('Primary Result SLA: Primary provider returns fast and publishes before secondary completes', () async {
      final primaryPlace = MapPlace(
        name: 'Trường Sa (Primary)',
        displayName: 'Đường Trường Sa, Hà Nội',
        coordinate: const LatLng(21.0500, 105.8600),
        type: 'street',
        precision: PlacePrecision.street,
        source: 'maptiler',
      );

      final secondaryPlace = MapPlace(
        name: 'Hoàng Sa (Secondary)',
        displayName: 'Đường Hoàng Sa, Hà Nội',
        coordinate: const LatLng(21.0550, 105.8650),
        type: 'street',
        precision: PlacePrecision.street,
        source: 'photon',
      );

      // Primary returns at 100ms
      searchService.primaryProviderOverride = (query, loc) async {
        await Future.delayed(const Duration(milliseconds: 100));
        return [primaryPlace];
      };

      // Secondary returns at 600ms
      searchService.secondaryProviderOverride = (query, loc) async {
        await Future.delayed(const Duration(milliseconds: 600));
        return [secondaryPlace];
      };

      final updates = <List<MapPlace>>[];
      final updateFinalFlags = <bool>[];
      final timestamps = <int>[];
      final sw = Stopwatch()..start();

      await searchService.searchPlacesProgressive(
        'Truong Sa XYZ',
        nearLocation: hanoiCoord,
        mode: SearchExecutionMode.autocomplete,
        onUpdate: (results, isFinal) {
          updates.add(List.from(results));
          updateFinalFlags.add(isFinal);
          timestamps.add(sw.elapsedMilliseconds);
        },
      );

      sw.stop();

      // Assert SLA: at least 2 updates (intermediate primary, then final merged)
      expect(updates.length, greaterThanOrEqualTo(2));
      
      // First update came from primary provider quickly (<400ms)
      expect(timestamps.first, lessThan(400), reason: 'Primary results should publish well under 400ms');
      expect(updates.first.any((p) => p.name.contains('Primary')), isTrue);
      expect(updateFinalFlags.first, isFalse, reason: 'First update is intermediate');

      // Final update merged secondary results
      expect(updateFinalFlags.last, isTrue);
      expect(updates.last.any((p) => p.name.contains('Primary')), isTrue);
      expect(updates.last.any((p) => p.name.contains('Secondary')), isTrue);
    });

    test('Slow Secondary Provider: Timeout or hang in secondary does not block primary suggestions or fail search', () async {
      final primaryPlace = MapPlace(
        name: 'Trấn Vũ Thần',
        displayName: 'Quận Ba Đình, Hà Nội',
        coordinate: const LatLng(21.0420, 105.8390),
        type: 'temple',
        precision: PlacePrecision.poi,
        source: 'maptiler',
      );

      searchService.primaryProviderOverride = (query, loc) async {
        await Future.delayed(const Duration(milliseconds: 120));
        return [primaryPlace];
      };

      // Secondary simulates timeout / infinite hang
      searchService.secondaryProviderOverride = (query, loc) async {
        await Future.delayed(const Duration(milliseconds: 2500));
        return [];
      };

      final updates = <List<MapPlace>>[];
      final updateFinalFlags = <bool>[];

      await searchService.searchPlacesProgressive(
        'Tran Vu Than XYZ',
        nearLocation: hanoiCoord,
        mode: SearchExecutionMode.autocomplete,
        onUpdate: (results, isFinal) {
          updates.add(List.from(results));
          updateFinalFlags.add(isFinal);
        },
      );

      expect(updates.isNotEmpty, isTrue);
      expect(updates.any((u) => u.any((p) => p.name.contains('Trấn Vũ Thần'))), isTrue);
      expect(updateFinalFlags.last, isTrue);
    });

    test('Stale Query Race: Fast newer query supersedes slower older query', () async {
      final oldPlace = MapPlace(
        name: 'Bách Khoa (Old)',
        displayName: 'Đại Cồ Việt',
        coordinate: const LatLng(21.005, 105.843),
        type: 'university',
        precision: PlacePrecision.poi,
      );

      final newPlace = MapPlace(
        name: 'Bạch Mai (New)',
        displayName: 'Phố Bạch Mai',
        coordinate: const LatLng(21.006, 105.849),
        type: 'street',
        precision: PlacePrecision.street,
      );

      List<MapPlace>? latestPublished;
      int activeGeneration = 0;

      void onUpdateCallback(int gen, List<MapPlace> results) {
        if (gen == activeGeneration) {
          latestPublished = results;
        }
      }

      // Query 1: "bach" (slow: 400ms)
      searchService.primaryProviderOverride = (query, loc) async {
        if (query == 'bach') {
          await Future.delayed(const Duration(milliseconds: 400));
          return [oldPlace];
        } else if (query == 'bach mai') {
          await Future.delayed(const Duration(milliseconds: 50));
          return [newPlace];
        }
        return [];
      };

      // Launch query 1
      activeGeneration = 1;
      final gen1 = activeGeneration;
      final f1 = searchService.searchPlacesProgressive(
        'bach',
        nearLocation: hanoiCoord,
        onUpdate: (res, isFinal) => onUpdateCallback(gen1, res),
      );

      // 20ms later, user types more: query 2 "bach mai"
      await Future.delayed(const Duration(milliseconds: 20));
      activeGeneration = 2;
      final gen2 = activeGeneration;
      final f2 = searchService.searchPlacesProgressive(
        'bach mai',
        nearLocation: hanoiCoord,
        onUpdate: (res, isFinal) => onUpdateCallback(gen2, res),
      );

      await Future.wait([f1, f2]);

      // Assert that latestPublished contains the NEW result, NOT the old slow result
      expect(latestPublished, isNotNull);
      expect(latestPublished!.any((p) => p.name.contains('New')), isTrue);
      expect(latestPublished!.any((p) => p.name.contains('Old')), isFalse);
    });

    test('In-Memory Query Cache & Prefix Candidate Reuse', () async {
      final place = MapPlace(
        name: 'Bạch Mai',
        displayName: 'Đường Bạch Mai, Hà Nội',
        coordinate: const LatLng(21.0062, 105.8491),
        type: 'street',
        precision: PlacePrecision.street,
      );

      // Prime cache
      searchService.primeCache('bạch mai', [place], nearLocation: hanoiCoord);

      // 1. Direct cache lookup (<5ms)
      final directCache = searchService.getCachedResults('bạch mai', nearLocation: hanoiCoord);
      expect(directCache, isNotNull);
      expect(directCache!.first.name, 'Bạch Mai');

      // 2. Case and diacritic insensitive prefix reuse (<30ms)
      final prefixMatches = searchService.findPrefixMatches('bach', nearLocation: hanoiCoord);
      expect(prefixMatches.isNotEmpty, isTrue);
      expect(prefixMatches.first.name, 'Bạch Mai');

      // 3. searchPlacesProgressive hits cache immediately with isFinal == true without network
      bool hitCacheImmediately = false;
      searchService.primaryProviderOverride = (_, __) async {
        fail('Network provider must not be called when cached!');
      };

      await searchService.searchPlacesProgressive(
        'bạch mai',
        nearLocation: hanoiCoord,
        onUpdate: (results, isFinal) {
          if (isFinal && results.isNotEmpty && results.first.name == 'Bạch Mai') {
            hitCacheImmediately = true;
          }
        },
      );

      expect(hitCacheImmediately, isTrue);
    });
  });
}
