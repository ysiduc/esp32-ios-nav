import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile_app/models/route_model.dart';
import 'package:mobile_app/services/search_service.dart';

void main() {
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
  });
}
