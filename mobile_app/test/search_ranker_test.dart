import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile_app/models/route_model.dart';
import 'package:mobile_app/models/search_query_intent.dart';
import 'package:mobile_app/services/search_ranker.dart';

void main() {
  group('SearchQueryIntent Parsing', () {
    test('Classifies coordinate input correctly', () {
      final intent = SearchQueryIntent.parse('21.0285, 105.8542');
      expect(intent.type, SearchQueryIntentType.coordinate);
      expect(intent.targetCoordinate?.latitude, closeTo(21.0285, 0.0001));
      expect(intent.targetCoordinate?.longitude, closeTo(105.8542, 0.0001));
    });

    test('Classifies house address query correctly', () {
      final intent1 = SearchQueryIntent.parse('96 Định Công');
      expect(intent1.type, SearchQueryIntentType.houseAddress);
      expect(intent1.houseNumber, '96');
      expect(intent1.streetName, 'Định Công');

      final intent2 = SearchQueryIntent.parse('Số 157 Nguyễn Cảnh Dị');
      expect(intent2.type, SearchQueryIntentType.houseAddress);
      expect(intent2.houseNumber, '157');
      expect(intent2.streetName, 'Nguyễn Cảnh Dị');
    });

    test('Classifies POI queries correctly', () {
      expect(SearchQueryIntent.parse('Bệnh viện Bạch Mai').type, SearchQueryIntentType.poi);
      expect(SearchQueryIntent.parse('Đại học Bách khoa Hà Nội').type, SearchQueryIntentType.poi);
      expect(SearchQueryIntent.parse('Keangnam Landmark 72').type, SearchQueryIntentType.poi);
      expect(SearchQueryIntent.parse('Hầm chui Kim Đồng').type, SearchQueryIntentType.poi);
      expect(SearchQueryIntent.parse('Bến xe Giáp Bát').type, SearchQueryIntentType.poi);
    });

    test('Classifies street queries correctly', () {
      expect(SearchQueryIntent.parse('Đường Nguyễn Trãi').type, SearchQueryIntentType.street);
      expect(SearchQueryIntent.parse('Phố Định Công').type, SearchQueryIntentType.street);
      expect(SearchQueryIntent.parse('Đ. Láng').type, SearchQueryIntentType.street);
    });

    test('Classifies district and city queries correctly', () {
      expect(SearchQueryIntent.parse('Hoàng Mai').type, SearchQueryIntentType.districtOrCity);
      expect(SearchQueryIntent.parse('Hà Nội').type, SearchQueryIntentType.districtOrCity);
      expect(SearchQueryIntent.parse('Hải Phòng').type, SearchQueryIntentType.districtOrCity);
    });
  });

  group('SearchRanker Tests', () {
    test('Exact address test: 96 Định Công ranks exact house over street and unrelated POI', () {
      final intent = SearchQueryIntent.parse('96 Định Công');

      final candA = MapPlace(
        name: '96 Định Công',
        displayName: '96 Định Công, Phương Liệt, Thanh Xuân, Hà Nội',
        coordinate: const LatLng(20.9901, 105.8390),
        precision: PlacePrecision.exactAddress,
        source: 'maptiler',
        distanceMeters: 500.0,
      );

      final candB = MapPlace(
        name: 'Phố Định Công',
        displayName: 'Phố Định Công, Hoàng Mai, Hà Nội',
        coordinate: const LatLng(20.9850, 105.8370),
        precision: PlacePrecision.street,
        source: 'photon',
        distanceMeters: 400.0,
      );

      final candC = MapPlace(
        name: 'Quán Cà Phê 96',
        displayName: '96 Giải Phóng, Phương Mai, Đống Đa, Hà Nội',
        coordinate: const LatLng(20.9950, 105.8420),
        precision: PlacePrecision.poi,
        source: 'apple_mapkit',
        distanceMeters: 200.0,
      );

      final scoreA = SearchRanker.rank(
        intent: intent,
        candidateTitle: candA.name,
        candidateAddress: candA.displayName,
        precision: candA.precision,
        source: candA.source,
        distanceMeters: candA.distanceMeters,
      );

      final scoreB = SearchRanker.rank(
        intent: intent,
        candidateTitle: candB.name,
        candidateAddress: candB.displayName,
        precision: candB.precision,
        source: candB.source,
        distanceMeters: candB.distanceMeters,
      );

      final scoreC = SearchRanker.rank(
        intent: intent,
        candidateTitle: candC.name,
        candidateAddress: candC.displayName,
        precision: candC.precision,
        source: candC.source,
        distanceMeters: candC.distanceMeters,
      );

      expect(scoreA.finalScore, greaterThan(scoreB.finalScore));
      expect(scoreA.finalScore, greaterThan(scoreC.finalScore));
      expect(scoreA.debugReason, contains('exact_house_evidence'));
    });

    test('No exact address test: Phố Định Công is tagged as street, not fake house', () {
      final intent = SearchQueryIntent.parse('96 Định Công');

      final streetCand = MapPlace(
        name: 'Phố Định Công',
        displayName: 'Phố Định Công, Hoàng Mai, Hà Nội',
        coordinate: const LatLng(20.9850, 105.8370),
        precision: PlacePrecision.street,
        source: 'photon',
        distanceMeters: 400.0,
      );

      final score = SearchRanker.rank(
        intent: intent,
        candidateTitle: streetCand.name,
        candidateAddress: streetCand.displayName,
        precision: streetCand.precision,
        source: streetCand.source,
        distanceMeters: streetCand.distanceMeters,
      );

      expect(score.debugReason, contains('street_match_no_house'));
      expect(streetCand.precision, PlacePrecision.street);
      expect(streetCand.name, isNot(contains('96')));
    });

    test('Typo tolerance: Bounded fuzzy matching handles typical Vietnamese typos', () {
      final intent = SearchQueryIntent.parse('benh vien bach maii');

      final candExact = MapPlace(
        name: 'Bệnh viện Bạch Mai',
        displayName: '78 Đường Giải Phóng, Phương Mai, Đống Đa, Hà Nội',
        coordinate: const LatLng(20.9998, 105.8415),
        precision: PlacePrecision.poi,
        source: 'apple_mapkit',
      );

      final candUnrelated = MapPlace(
        name: 'Bệnh viện Da Liễu',
        displayName: 'Đống Đa, Hà Nội',
        coordinate: const LatLng(21.0100, 105.8300),
        precision: PlacePrecision.poi,
        source: 'photon',
      );

      final scoreExact = SearchRanker.rank(
        intent: intent,
        candidateTitle: candExact.name,
        candidateAddress: candExact.displayName,
        precision: candExact.precision,
        source: candExact.source,
      );

      final scoreUnrelated = SearchRanker.rank(
        intent: intent,
        candidateTitle: candUnrelated.name,
        candidateAddress: candUnrelated.displayName,
        precision: candUnrelated.precision,
        source: candUnrelated.source,
      );

      expect(scoreExact.finalScore, greaterThan(scoreUnrelated.finalScore));
      expect(scoreExact.titleMatch, greaterThan(60.0));
    });

    test('Far-but-exact test: Distant exact POI outranks nearby unrelated POI', () {
      // User is in Hanoi (21.0285, 105.8542)
      // Searching for Cat Bi Airport in Hai Phong (~100km away)
      final intent = SearchQueryIntent.parse('Sân bay Cát Bi Hải Phòng');

      final catBi = MapPlace(
        name: 'Sân bay Quốc tế Cát Bi',
        displayName: 'Đường Lê Hồng Phong, Hải An, Hải Phòng',
        coordinate: const LatLng(20.8193, 106.7247), // ~100 km away
        precision: PlacePrecision.poi,
        source: 'apple_mapkit',
        distanceMeters: 98000.0,
      );

      final localWeak = MapPlace(
        name: 'Quán Cà Phê Cát Bi',
        displayName: '10 Ngõ Gần Đây, Đống Đa, Hà Nội',
        coordinate: const LatLng(21.0200, 105.8500), // ~1 km away
        precision: PlacePrecision.poi,
        source: 'local',
        distanceMeters: 1000.0,
      );

      final scoreCatBi = SearchRanker.rank(
        intent: intent,
        candidateTitle: catBi.name,
        candidateAddress: catBi.displayName,
        precision: catBi.precision,
        source: catBi.source,
        distanceMeters: catBi.distanceMeters,
      );

      final scoreLocalWeak = SearchRanker.rank(
        intent: intent,
        candidateTitle: localWeak.name,
        candidateAddress: localWeak.displayName,
        precision: localWeak.precision,
        source: localWeak.source,
        distanceMeters: localWeak.distanceMeters,
      );

      expect(scoreCatBi.finalScore, greaterThan(scoreLocalWeak.finalScore));
    });

    test('Deduplication: Merges candidate places within 30m with same normalized title', () {
      final place1 = MapPlace(
        name: 'Bệnh viện Bạch Mai',
        displayName: '78 Giải Phóng, Phương Mai, Hà Nội',
        coordinate: const LatLng(20.99980, 105.84150),
        precision: PlacePrecision.poi,
        source: 'maptiler',
      );

      final place2 = MapPlace(
        name: 'BV Bạch Mai',
        displayName: 'Đường Giải Phóng, Đống Đa, Hà Nội',
        coordinate: const LatLng(20.99982, 105.84155), // ~6m away
        precision: PlacePrecision.poi,
        source: 'apple_mapkit',
      );

      final place3 = MapPlace(
        name: 'Đại học Bách khoa Hà Nội',
        displayName: '1 Đại Cồ Việt, Hai Bà Trưng, Hà Nội',
        coordinate: const LatLng(21.0050, 105.8430),
        precision: PlacePrecision.poi,
        source: 'apple_mapkit',
      );

      final deduped = SearchRanker.deduplicate([place1, place2, place3], maxDistanceMeters: 30.0);
      expect(deduped.length, 2);
      expect(deduped.any((p) => p.name.contains('Bạch Mai') || p.name.contains('BV')), isTrue);
      expect(deduped.any((p) => p.name.contains('Bách khoa')), isTrue);
    });
  });
}
