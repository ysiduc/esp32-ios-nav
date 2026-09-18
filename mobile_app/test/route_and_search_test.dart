import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile_app/models/esp_payload.dart';
import 'package:mobile_app/models/route_model.dart';
import 'package:mobile_app/services/search_service.dart';
import 'package:mobile_app/services/voice_guidance_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('Route & Search Model Tests', () {
    test('MapPlace distance calculation and formatting', () {
      final place = MapPlace(
        name: 'Số 96 Phố Định Công',
        displayName: 'Số 96 Phố Định Công, Phương Liệt, Hoàng Mai, Hà Nội',
        coordinate: const LatLng(20.9848, 105.8385),
        distanceMeters: 2450.0,
      );

      expect(place.formattedDistance, '2.5 km');
      expect(place.shortSubtitle, 'Phương Liệt, Hoàng Mai, Hà Nội');
    });

    test('NavRoute formatting and diff tags', () {
      final routeFastest = NavRoute(
        totalDistanceMeters: 12500,
        totalDurationSeconds: 1500, // 25 mins
        polylinePoints: const [LatLng(21.0, 105.8), LatLng(21.1, 105.9)],
        steps: [],
        summary: 'Qua Cao tốc',
        title: '⚡ Nhanh nhất (Tránh tắc)',
        isFastest: true,
        durationDiffMinutes: 0,
        distanceDiffKm: 0,
      );

      final routeShortest = NavRoute(
        totalDistanceMeters: 9800, // 9.8 km
        totalDurationSeconds: 1800, // 30 mins
        polylinePoints: const [LatLng(21.0, 105.8), LatLng(21.1, 105.9)],
        steps: [],
        summary: 'Qua Đường nội đô',
        title: '📏 Ngắn nhất',
        isShortest: true,
        durationDiffMinutes: 5,
        distanceDiffKm: -2.7,
      );

      expect(routeFastest.formattedDistance, '12.5 km');
      expect(routeFastest.formattedDuration, '25 phút');
      expect(routeFastest.formattedDiffTag, '⚡ Nhanh nhất');

      expect(routeShortest.formattedDistance, '9.8 km');
      expect(routeShortest.formattedDuration, '30 phút');
      expect(routeShortest.formattedDiffTag, '+5 phút • -2.7 km');
    });

    test('SearchService city suffix stripping and diacritics', () {
      expect(SearchService.stripCitySuffix('Định công hà nội'), 'Định công');
      expect(SearchService.stripCitySuffix('Cầu giấy hn'), 'Cầu giấy');
      expect(SearchService.stripCitySuffix('Chợ Bến Thành tphcm'), 'Chợ Bến Thành');
      expect(SearchService.stripCitySuffix('157 nguyễn cảnh dị hà nội'), '157 nguyễn cảnh dị');
      expect(SearchService.removeDiacritics('Định Công'), 'Dinh Cong');
    });

    test('SearchService recent searches storage', () {
      final searchService = SearchService();
      final p1 = MapPlace(
        name: 'Số 96 Định Công',
        displayName: '96 Phố Định Công, Hà Nội',
        coordinate: const LatLng(20.9848, 105.8385),
      );

      searchService.addRecentSearch(p1);
      expect(searchService.recentSearches.first.name, 'Số 96 Định Công');
    });

    test('QuickSearchCategory definitions', () {
      expect(QuickSearchCategory.defaultCategories.isNotEmpty, isTrue);
      expect(QuickSearchCategory.defaultCategories.first.title, 'Cây xăng');
    });

    test('EspNavPayload formatting and JSON serialization', () {
      final payload = EspNavPayload(
        turnCode: 2, // right turn
        distanceToTurn: 150,
        totalDistance: 5400,
        etaMinutes: 18,
        streetName: 'Đường Nguyễn Trãi',
        currentSpeed: 42,
        stepIndex: 1,
        totalSteps: 5,
      );

      expect(payload.formattedDist, '150 m');
      expect(payload.formattedTotalDist, '5.4 km');
      expect(payload.formattedRemainingTime, '18 phút');
      expect(payload.sanitizedStreet, 'Duong Nguyen Trai');
      expect(payload.arrivalTimeClock.contains(':'), isTrue);

      final jsonStr = payload.toJsonString();
      expect(jsonStr.contains('"turn":2'), isTrue);
      expect(jsonStr.contains('"dist":150'), isTrue);
      expect(jsonStr.contains('"street":"Duong Nguyen Trai"'), isTrue);
      expect(jsonStr.contains('"arr":"${payload.arrivalTimeClock}"'), isTrue);
    });
    test('SearchService saved places operations', () async {
      final searchService = SearchService();
      final fav = MapPlace(
        name: 'Văn phòng Công ty',
        displayName: 'Tòa nhà Landmark 72, Nam Từ Liêm, Hà Nội',
        coordinate: const LatLng(21.0169, 105.7836),
      );

      // Initially not saved
      expect(searchService.isPlaceSaved(fav), isFalse);

      // Save place
      await searchService.savePlace(fav);
      expect(searchService.isPlaceSaved(fav), isTrue);
      expect(searchService.savedPlaces.first.name, 'Văn phòng Công ty');

      // Toggle save (should remove)
      final stateAfterToggle = await searchService.toggleSavePlace(fav);
      expect(stateAfterToggle, isFalse);
      expect(searchService.isPlaceSaved(fav), isFalse);

      // Re-save and remove
      await searchService.savePlace(fav);
      expect(searchService.isPlaceSaved(fav), isTrue);
      await searchService.removeSavedPlace(fav);
      expect(searchService.isPlaceSaved(fav), isFalse);
    });

    test('SearchService deleteRecentSearch and clearRecentSearches', () async {
      final searchService = SearchService();
      final p1 = MapPlace(
        name: 'Hồ Gươm Plaza',
        displayName: 'Trần Phú, Hà Đông, Hà Nội',
        coordinate: const LatLng(20.9785, 105.7852),
      );
      await searchService.addRecentSearch(p1);
      expect(searchService.recentSearches.any((p) => p.name == 'Hồ Gươm Plaza'), isTrue);

      await searchService.deleteRecentSearch(p1);
      expect(searchService.recentSearches.any((p) => p.name == 'Hồ Gươm Plaza'), isFalse);

      await searchService.clearRecentSearches();
      expect(searchService.recentSearches.isEmpty, isTrue);
    });

    test('VoiceGuidanceService mute and state management', () {
      final voice = VoiceGuidanceService();
      expect(voice.isMuted, isFalse);

      voice.toggleMute();
      expect(voice.isMuted, isTrue);

      voice.toggleMute();
      expect(voice.isMuted, isFalse);

      voice.setMuted(true);
      expect(voice.isMuted, isTrue);
      voice.setMuted(false);
      expect(voice.isMuted, isFalse);
    });
  });
}
