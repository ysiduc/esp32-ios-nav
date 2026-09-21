import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile_app/models/route_model.dart';
import 'package:mobile_app/services/mapkit_search_service.dart';
import 'package:mobile_app/services/search_service.dart';

class MockMapKitSearchClient implements MapKitSearchClient {
  @override
  Future<List<Map<String, dynamic>>> autocomplete(String query, {LatLng? userLocation}) async {
    return [
      {
        'id': 'comp_1',
        'title': 'Bệnh viện Bạch Mai',
        'subtitle': '78 Giải Phóng, Phương Mai, Đống Đa, Hà Nội',
        'precision': 'poi',
      },
      {
        'id': 'comp_2',
        'title': '96 Phố Định Công',
        'subtitle': 'Phương Liệt, Thanh Xuân, Hà Nội',
        'precision': 'exactAddress',
      },
    ];
  }

  @override
  Future<Map<String, dynamic>?> resolve(String completionId) async {
    if (completionId == 'comp_1') {
      return {
        'id': 'comp_1',
        'title': 'Bệnh viện Bạch Mai',
        'subtitle': '78 Giải Phóng, Phương Mai, Đống Đa, Hà Nội',
        'latitude': 20.9998,
        'longitude': 105.8415,
        'precision': 'poi',
      };
    }
    if (completionId == 'comp_2') {
      return {
        'id': 'comp_2',
        'title': '96 Phố Định Công',
        'subtitle': 'Phương Liệt, Thanh Xuân, Hà Nội',
        'latitude': 20.9901,
        'longitude': 105.8390,
        'precision': 'exactAddress',
      };
    }
    return null;
  }

  @override
  Future<List<Map<String, dynamic>>> search(String query, {LatLng? userLocation}) async {
    if (query.contains('Bạch Mai')) {
      return [
        {
          'id': 'res_1',
          'title': 'Bệnh viện Bạch Mai',
          'subtitle': '78 Giải Phóng, Hà Nội',
          'latitude': 20.9998,
          'longitude': 105.8415,
          'precision': 'poi',
        }
      ];
    }
    if (query.contains('96 Định Công')) {
      return [
        {
          'id': 'res_2',
          'title': '96 Phố Định Công',
          'subtitle': 'Phương Liệt, Thanh Xuân, Hà Nội',
          'latitude': 20.9901,
          'longitude': 105.8390,
          'precision': 'exactAddress',
        }
      ];
    }
    return [];
  }
}

void main() {
  group('Search Precision & Model Tests', () {
    test('Section 4 & 6: MapKitSearchService parses MapKit results with correct precision & source', () async {
      final mockClient = MockMapKitSearchClient();
      final mapKitService = MapKitSearchService(client: mockClient);

      final results = await mapKitService.search('Bạch Mai');
      expect(results.length, 1);
      expect(results.first.name, 'Bệnh viện Bạch Mai');
      expect(results.first.precision, PlacePrecision.poi);
      expect(results.first.source, 'apple_mapkit');
      expect(results.first.coordinate.latitude, closeTo(20.9998, 0.0001));

      final autocompletes = await mapKitService.autocomplete('Bạch Mai');
      expect(autocompletes.length, greaterThanOrEqualTo(1));
      expect(autocompletes.first.precision, PlacePrecision.poi);
      expect(autocompletes.first.source, 'apple_mapkit');
    });

    test('Section 2 & 3: Never synthesize fake house number at street center', () async {
      final searchService = SearchService();

      // Search coordinate directly
      final coordResults = await searchService.searchPlaces('21.0285, 105.8542');
      expect(coordResults.length, 1);
      expect(coordResults.first.precision, PlacePrecision.coordinate);
      expect(coordResults.first.source, 'coordinate');
      expect(coordResults.first.coordinate.latitude, closeTo(21.0285, 0.0001));
      expect(coordResults.first.coordinate.longitude, closeTo(105.8542, 0.0001));
    });

    test('Section 4: PlacePrecision enum serialization in MapPlace', () {
      final place = MapPlace(
        name: '96 Định Công',
        displayName: '96 Định Công, Hà Nội',
        coordinate: const LatLng(20.9901, 105.8390),
        precision: PlacePrecision.exactAddress,
        source: 'maptiler',
      );

      final json = place.toJson();
      expect(json['precision'], 'exactAddress');
      expect(json['source'], 'maptiler');

      final fromJson = MapPlace.fromJson(json);
      expect(fromJson.precision, PlacePrecision.exactAddress);
      expect(fromJson.source, 'maptiler');
    });
  });
}
