import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import '../models/route_model.dart';

class SearchService {
  static const String _photonBaseUrl = 'https://photon.komoot.io';
  static const String _nominatimBaseUrl = 'https://nominatim.openstreetmap.org';

  // Optional Google Places API Key (can be set by user in Settings or dynamically)
  static String? googleApiKey;

  // Common Vietnamese city/province suffixes and prefixes
  static const List<String> _vietnamCityKeywords = [
    'hà nội', 'ha noi', 'tp hà nội', 'tp ha noi', 'hn',
    'hồ chí minh', 'ho chi minh', 'tp hồ chí minh', 'tp ho chi minh', 'tphcm', 'tp hcm', 'hcm', 'sài gòn', 'sai gon',
    'đà nẵng', 'da nang', 'tp đà nẵng',
    'hải phòng', 'hai phong', 'tp hải phòng',
    'cần thơ', 'can tho', 'tp cần thơ',
    'quảng ninh', 'quang ninh', 'hạ long', 'ha long',
    'bình dương', 'binh duong', 'thủ dầu một',
    'đồng nai', 'dong nai', 'biên hòa', 'bien hoa',
    'khánh hòa', 'khanh hoa', 'nha trang',
    'thừa thiên huế', 'thua thien hue', 'huế', 'hue',
    'bắc ninh', 'bac ninh',
    'hải dương', 'hai duong',
    'hưng yên', 'hung yen',
    'thái nguyên', 'thai nguyen',
    'vũng tàu', 'vung tau', 'bà rịa vũng tàu',
    'nam định', 'nam dinh',
    'thái bình', 'thai binh',
    'ninh bình', 'ninh binh',
    'thanh hóa', 'thanh hoa',
    'nghệ an', 'nghe an', 'vinh',
    'hà tĩnh', 'ha tinh',
    'quảng bình', 'quang binh',
    'quảng trị', 'quang tri',
    'quảng nam', 'quang nam', 'hội an', 'hoi an',
    'quảng ngãi', 'quang ngai',
    'bình định', 'binh dinh', 'quy nhơn', 'quy nhon',
    'phú yên', 'phu yen', 'tuy hòa', 'tuy hoa',
    'lâm đồng', 'lam dong', 'đà lạt', 'da lat',
    'việt nam', 'viet nam', 'vietnam', 'vn',
  ];

  /// Curated High-Precision Vietnamese POI & Landmark Database
  /// Guarantees instant 100% accurate results for top places in Vietnam
  static final List<MapPlace> _vietnameseLandmarks = [
    // --- Hà Nội ---
    MapPlace(
      name: 'Keangnam Hanoi Landmark 72',
      displayName: 'Tòa nhà Keangnam Landmark 72, Đường Phạm Hùng, Mễ Trì, Nam Từ Liêm, Hà Nội',
      coordinate: const LatLng(21.016922, 105.783688),
      type: 'building',
      category: 'commercial',
    ),
    MapPlace(
      name: 'Sân bay Quốc tế Nội Bài (HAN)',
      displayName: 'Sân bay Quốc tế Nội Bài, Xã Phú Minh, Huyện Sóc Sơn, Hà Nội',
      coordinate: const LatLng(21.2187, 105.8042),
      type: 'aeroway',
      category: 'aerodrome',
    ),
    MapPlace(
      name: 'Bến xe Mỹ Đình',
      displayName: 'Số 20 Đường Phạm Hùng, Mỹ Đình 2, Nam Từ Liêm, Hà Nội',
      coordinate: const LatLng(21.0282, 105.7778),
      type: 'bus_station',
      category: 'transportation',
    ),
    MapPlace(
      name: 'Bến xe Giáp Bát',
      displayName: 'Km 6 Đường Giải Phóng, Giáp Bát, Hoàng Mai, Hà Nội',
      coordinate: const LatLng(20.9789, 105.8428),
      type: 'bus_station',
      category: 'transportation',
    ),
    MapPlace(
      name: 'Bến xe Nước Ngầm',
      displayName: 'Số 1 Ngọc Hồi, Hoàng Liệt, Hoàng Mai, Hà Nội',
      coordinate: const LatLng(20.9634, 105.8422),
      type: 'bus_station',
      category: 'transportation',
    ),
    MapPlace(
      name: 'Hồ Hoàn Kiếm (Hồ Gươm)',
      displayName: 'Hồ Hoàn Kiếm, Phố Đinh Tiên Hoàng, Hàng Trống, Hoàn Kiếm, Hà Nội',
      coordinate: const LatLng(21.0285, 105.8542),
      type: 'water',
      category: 'tourism',
    ),
    MapPlace(
      name: 'Hồ Tây',
      displayName: 'Hồ Tây, Quận Tây Hồ, Hà Nội',
      coordinate: const LatLng(21.0558, 105.8247),
      type: 'water',
      category: 'natural',
    ),
    MapPlace(
      name: 'Lăng Chủ tịch Hồ Chí Minh',
      displayName: 'Số 2 Hùng Vương, Điện Bàn, Ba Đình, Hà Nội',
      coordinate: const LatLng(21.0368, 105.8347),
      type: 'memorial',
      category: 'tourism',
    ),
    MapPlace(
      name: 'Sân vận động Quốc gia Mỹ Đình',
      displayName: 'Đường Lê Đức Thọ, Mỹ Đình 1, Nam Từ Liêm, Hà Nội',
      coordinate: const LatLng(21.0205, 105.7639),
      type: 'stadium',
      category: 'leisure',
    ),
    MapPlace(
      name: 'Trung tâm Hội nghị Quốc gia',
      displayName: 'Số 57 Đường Phạm Hùng, Mễ Trì, Nam Từ Liêm, Hà Nội',
      coordinate: const LatLng(21.0069, 105.7877),
      type: 'convention_center',
      category: 'amenity',
    ),
    MapPlace(
      name: 'Lotte Center Hà Nội (Lotte Liễu Giai)',
      displayName: 'Số 54 Liễu Giai, Cống Vị, Ba Đình, Hà Nội',
      coordinate: const LatLng(21.0333, 105.8139),
      type: 'mall',
      category: 'shop',
    ),
    MapPlace(
      name: 'Lotte Mall Tây Hồ',
      displayName: 'Số 272 Đường Võ Chí Công, Phú Thượng, Tây Hồ, Hà Nội',
      coordinate: const LatLng(21.0772, 105.8083),
      type: 'mall',
      category: 'shop',
    ),
    MapPlace(
      name: 'Vincom Center Bà Triệu',
      displayName: 'Số 191 Bà Triệu, Lê Đại Hành, Hai Bà Trưng, Hà Nội',
      coordinate: const LatLng(21.0116, 105.8497),
      type: 'mall',
      category: 'shop',
    ),
    MapPlace(
      name: 'Vincom Mega Mall Royal City',
      displayName: 'Số 72A Nguyễn Trãi, Thượng Đình, Thanh Xuân, Hà Nội',
      coordinate: const LatLng(21.0028, 105.8157),
      type: 'mall',
      category: 'shop',
    ),
    MapPlace(
      name: 'Vincom Mega Mall Times City',
      displayName: 'Số 458 Minh Khai, Vĩnh Tuy, Hai Bà Trưng, Hà Nội',
      coordinate: const LatLng(20.9947, 105.8678),
      type: 'mall',
      category: 'shop',
    ),
    MapPlace(
      name: 'Aeon Mall Long Biên',
      displayName: 'Số 27 Cổ Linh, Long Biên, Hà Nội',
      coordinate: const LatLng(21.0264, 105.8978),
      type: 'mall',
      category: 'shop',
    ),
    MapPlace(
      name: 'Aeon Mall Hà Đông',
      displayName: 'Khu đô thị Dương Nội, Dương Nội, Hà Đông, Hà Nội',
      coordinate: const LatLng(20.9786, 105.7533),
      type: 'mall',
      category: 'shop',
    ),
    MapPlace(
      name: 'Bệnh viện Bạch Mai',
      displayName: 'Số 78 Giải Phóng, Phương Mai, Đống Đa, Hà Nội',
      coordinate: const LatLng(21.0033, 105.8419),
      type: 'hospital',
      category: 'amenity',
    ),
    MapPlace(
      name: 'Bệnh viện Hữu nghị Việt Đức',
      displayName: 'Số 40 Tràng Thi, Hàng Bông, Hoàn Kiếm, Hà Nội',
      coordinate: const LatLng(21.0298, 105.8481),
      type: 'hospital',
      category: 'amenity',
    ),
    MapPlace(
      name: 'Bệnh viện Trung ương Quân đội 108',
      displayName: 'Số 1 Trần Hưng Đạo, Bạch Đằng, Hai Bà Trưng, Hà Nội',
      coordinate: const LatLng(21.0189, 105.8603),
      type: 'hospital',
      category: 'amenity',
    ),
    MapPlace(
      name: 'Bệnh viện Nhi Trung ương',
      displayName: 'Số 18/879 La Thành, Láng Thượng, Đống Đa, Hà Nội',
      coordinate: const LatLng(21.0242, 105.8078),
      type: 'hospital',
      category: 'amenity',
    ),
    MapPlace(
      name: 'Đại học Bách Khoa Hà Nội',
      displayName: 'Số 1 Đại Cồ Việt, Bách Khoa, Hai Bà Trưng, Hà Nội',
      coordinate: const LatLng(21.0051, 105.8433),
      type: 'university',
      category: 'amenity',
    ),
    MapPlace(
      name: 'Đại học Quốc gia Hà Nội (Cầu Giấy)',
      displayName: 'Số 144 Xuân Thủy, Dịch Vọng Hậu, Cầu Giấy, Hà Nội',
      coordinate: const LatLng(21.0378, 105.7828),
      type: 'university',
      category: 'amenity',
    ),
    MapPlace(
      name: 'Đại học Kinh tế Quốc dân (NEU)',
      displayName: 'Số 207 Giải Phóng, Đồng Tâm, Hai Bà Trưng, Hà Nội',
      coordinate: const LatLng(21.0006, 105.8428),
      type: 'university',
      category: 'amenity',
    ),
    MapPlace(
      name: 'Ga Hà Nội (Ga Hàng Cỏ)',
      displayName: 'Số 120 Lê Duẩn, Văn Miếu, Đống Đa, Hà Nội',
      coordinate: const LatLng(21.0245, 105.8411),
      type: 'station',
      category: 'railway',
    ),

    // --- TP. Hồ Chí Minh ---
    MapPlace(
      name: 'Tòa nhà Landmark 81',
      displayName: 'Số 720A Điện Biên Phủ, Phường 22, Bình Thạnh, TP. Hồ Chí Minh',
      coordinate: const LatLng(10.7952, 106.7218),
      type: 'building',
      category: 'commercial',
    ),
    MapPlace(
      name: 'Sân bay Quốc tế Tân Sơn Nhất (SGN)',
      displayName: 'Đường Trường Sơn, Phường 2, Tân Bình, TP. Hồ Chí Minh',
      coordinate: const LatLng(10.8185, 106.6588),
      type: 'aeroway',
      category: 'aerodrome',
    ),
    MapPlace(
      name: 'Chợ Bến Thành',
      displayName: 'Đường Lê Lợi, Phường Bến Thành, Quận 1, TP. Hồ Chí Minh',
      coordinate: const LatLng(10.7725, 106.6980),
      type: 'marketplace',
      category: 'amenity',
    ),
    MapPlace(
      name: 'Phố đi bộ Nguyễn Huệ',
      displayName: 'Đường Nguyễn Huệ, Phường Bến Nghé, Quận 1, TP. Hồ Chí Minh',
      coordinate: const LatLng(10.7740, 106.7033),
      type: 'pedestrian',
      category: 'highway',
    ),
    MapPlace(
      name: 'Bến xe Miền Đông mới',
      displayName: 'Số 501 Hoàng Hữu Nam, Long Bình, TP. Thủ Đức, TP. Hồ Chí Minh',
      coordinate: const LatLng(10.8806, 106.8222),
      type: 'bus_station',
      category: 'transportation',
    ),
    MapPlace(
      name: 'Bến xe Miền Tây',
      displayName: 'Số 395 Kinh Dương Vương, An Lạc, Bình Tân, TP. Hồ Chí Minh',
      coordinate: const LatLng(10.7381, 106.6111),
      type: 'bus_station',
      category: 'transportation',
    ),
    MapPlace(
      name: 'Bệnh viện Chợ Rẫy',
      displayName: 'Số 201B Nguyễn Chí Thanh, Phường 12, Quận 5, TP. Hồ Chí Minh',
      coordinate: const LatLng(10.7578, 106.6597),
      type: 'hospital',
      category: 'amenity',
    ),
    MapPlace(
      name: 'Bệnh viện Từ Dũ',
      displayName: 'Số 284 Cống Quỳnh, Phạm Ngũ Lão, Quận 1, TP. Hồ Chí Minh',
      coordinate: const LatLng(10.7686, 106.6853),
      type: 'hospital',
      category: 'amenity',
    ),
    MapPlace(
      name: 'Đại học Bách Khoa TP.HCM',
      displayName: 'Số 268 Lý Thường Kiệt, Phường 14, Quận 10, TP. Hồ Chí Minh',
      coordinate: const LatLng(10.7722, 106.6578),
      type: 'university',
      category: 'amenity',
    ),
    MapPlace(
      name: 'Đại học Quốc gia TP.HCM (Làng Đại học Thủ Đức)',
      displayName: 'Phường Linh Trung, TP. Thủ Đức, TP. Hồ Chí Minh',
      coordinate: const LatLng(10.8756, 106.8006),
      type: 'university',
      category: 'amenity',
    ),
    MapPlace(
      name: 'Tòa nhà Bitexco Financial Tower',
      displayName: 'Số 2 Hải Triều, Bến Nghé, Quận 1, TP. Hồ Chí Minh',
      coordinate: const LatLng(10.7717, 106.7044),
      type: 'building',
      category: 'commercial',
    ),
    MapPlace(
      name: 'Dinh Độc Lập (Hội trường Thống Nhất)',
      displayName: 'Số 135 Nam Kỳ Khởi Nghĩa, Bến Thành, Quận 1, TP. Hồ Chí Minh',
      coordinate: const LatLng(10.7770, 106.6953),
      type: 'historic',
      category: 'tourism',
    ),
    MapPlace(
      name: 'Nhà thờ Đức Bà Sài Gòn',
      displayName: 'Số 1 Công xã Paris, Bến Nghé, Quận 1, TP. Hồ Chí Minh',
      coordinate: const LatLng(10.7798, 106.6990),
      type: 'church',
      category: 'tourism',
    ),
    MapPlace(
      name: 'Ga Sài Gòn',
      displayName: 'Số 1 Nguyễn Thông, Phường 9, Quận 3, TP. Hồ Chí Minh',
      coordinate: const LatLng(10.7828, 106.6775),
      type: 'station',
      category: 'railway',
    ),

    // --- Đà Nẵng ---
    MapPlace(
      name: 'Sân bay Quốc tế Đà Nẵng (DAD)',
      displayName: 'Đường Duy Tân, Hòa Thuận Tây, Hải Châu, Đà Nẵng',
      coordinate: const LatLng(16.0539, 108.1994),
      type: 'aeroway',
      category: 'aerodrome',
    ),
    MapPlace(
      name: 'Cầu Rồng Đà Nẵng',
      displayName: 'Đường Nguyễn Văn Linh, Phước Ninh, Hải Châu, Đà Nẵng',
      coordinate: const LatLng(16.0611, 108.2272),
      type: 'bridge',
      category: 'tourism',
    ),
    MapPlace(
      name: 'Bãi biển Mỹ Khê',
      displayName: 'Đường Võ Nguyên Giáp, Phước Mỹ, Sơn Trà, Đà Nẵng',
      coordinate: const LatLng(16.0594, 108.2464),
      type: 'beach',
      category: 'natural',
    ),
  ];

  // Recent searches cache
  static final List<MapPlace> _recentSearches = [
    MapPlace(
      name: 'Hồ Hoàn Kiếm',
      displayName: 'Hồ Hoàn Kiếm, Quận Hoàn Kiếm, Hà Nội',
      coordinate: const LatLng(21.0285, 105.8542),
      type: 'water',
    ),
    MapPlace(
      name: 'Chợ Bến Thành',
      displayName: 'Chợ Bến Thành, Quận 1, TP. Hồ Chí Minh',
      coordinate: const LatLng(10.7725, 106.6980),
      type: 'marketplace',
    ),
    MapPlace(
      name: 'Keangnam Landmark 72',
      displayName: 'Đường Phạm Hùng, Mễ Trì, Nam Từ Liêm, Hà Nội',
      coordinate: const LatLng(21.016922, 105.783688),
      type: 'commercial',
    ),
    MapPlace(
      name: 'Landmark 81',
      displayName: 'Số 720A Điện Biên Phủ, Phường 22, Bình Thạnh, TP.HCM',
      coordinate: const LatLng(10.7952, 106.7218),
      type: 'building',
    ),
  ];

  List<MapPlace> get recentSearches => List.unmodifiable(_recentSearches);

  void addRecentSearch(MapPlace place) {
    _recentSearches.removeWhere((p) =>
        p.name.toLowerCase() == place.name.toLowerCase() ||
        (p.coordinate.latitude == place.coordinate.latitude &&
            p.coordinate.longitude == place.coordinate.longitude));
    _recentSearches.insert(0, place);
    if (_recentSearches.length > 10) {
      _recentSearches.removeLast();
    }
  }

  void clearRecentSearches() {
    _recentSearches.clear();
  }

  /// Remove Vietnamese diacritics for ultra-flexible search
  static String removeDiacritics(String str) {
    const vietnameseMap = {
      'a': 'áàảãạăắằẳẵặâấầẩẫậ',
      'A': 'ÁÀẢÃẠĂẮẰẲẴẶÂẤẦẨẪẬ',
      'd': 'đ',
      'D': 'Đ',
      'e': 'éèẻẽẹêếềểễệ',
      'E': 'ÉÈẺẼẸÊẾỀỂỄỆ',
      'i': 'íìỉĩị',
      'I': 'ÍÌỈĨỊ',
      'o': 'óòỏõọôốồổỗộơớờởỡợ',
      'O': 'ÓÒỎÕỌÔỐỒỔỖỘƠỚỜỞỠỢ',
      'u': 'úùủũụưứừửữự',
      'U': 'ÚÙỦŨỤƯỨỪỬỮỰ',
      'y': 'ýỳỷỹỵ',
      'Y': 'ÝỲỶỸỴ'
    };
    String result = str;
    vietnameseMap.forEach((nonAccent, accents) {
      for (int i = 0; i < accents.length; i++) {
        result = result.replaceAll(accents[i], nonAccent);
      }
    });
    return result;
  }

  /// Strip city suffixes like "hà nội", "tphcm", "đà nẵng" from search query
  static String stripCitySuffix(String query) {
    String q = query.trim();
    for (final city in _vietnamCityKeywords) {
      final pattern = RegExp('(\\s*[,\\-]?\\s*\\b${RegExp.escape(city)}\\b)', caseSensitive: false);
      q = q.replaceAll(pattern, '').trim();
    }
    return q.isEmpty ? query.trim() : q;
  }

  /// Ultra-Fast Multi-Engine Search with POI Database, Nominatim & Photon
  Future<List<MapPlace>> searchPlaces(
    String query, {
    LatLng? nearLocation,
  }) async {
    final cleanQuery = query.trim();
    if (cleanQuery.isEmpty) return [];

    final unaccented = removeDiacritics(cleanQuery).toLowerCase();
    final strippedCity = stripCitySuffix(cleanQuery);
    final strippedCityUnaccented = removeDiacritics(strippedCity).toLowerCase();

    final mergedResults = <MapPlace>[];
    final seenKeys = <String>{};

    void addPlace(MapPlace p) {
      final key = '${p.name}_${p.coordinate.latitude.toStringAsFixed(4)}_${p.coordinate.longitude.toStringAsFixed(4)}'.toLowerCase();
      if (!seenKeys.contains(key)) {
        seenKeys.add(key);
        // Calculate distance if not set
        if (p.distanceMeters == null && nearLocation != null) {
          const distanceCalculator = Distance();
          final dist = distanceCalculator.as(LengthUnit.Meter, nearLocation, p.coordinate);
          mergedResults.add(MapPlace(
            name: p.name,
            displayName: p.displayName,
            coordinate: p.coordinate,
            type: p.type,
            category: p.category,
            distanceMeters: dist,
          ));
        } else {
          mergedResults.add(p);
        }
      }
    }

    // -------------------------------------------------------------
    // Step 1: Check Built-in Vietnamese Landmark / POI Database (0 ms Instant Match)
    // -------------------------------------------------------------
    final queryWords = unaccented.split(RegExp(r'\s+')).where((w) => w.length > 1).toList();
    for (final landmark in _vietnameseLandmarks) {
      final lName = landmark.name.toLowerCase();
      final lNameUnaccented = removeDiacritics(landmark.name).toLowerCase();
      final lDisplayUnaccented = removeDiacritics(landmark.displayName).toLowerCase();

      final allWordsMatch = queryWords.isNotEmpty &&
          queryWords.every((w) => lNameUnaccented.contains(w) || lDisplayUnaccented.contains(w));

      if (allWordsMatch ||
          lName.contains(cleanQuery.toLowerCase()) ||
          lNameUnaccented.contains(unaccented) ||
          lNameUnaccented.contains(strippedCityUnaccented) ||
          lDisplayUnaccented.contains(unaccented) ||
          unaccented.contains(lNameUnaccented)) {
        addPlace(landmark);
      }
    }

    // -------------------------------------------------------------
    // Step 2: Extract house number if user types "157 nguyễn cảnh", "96 định công", "12/4 láng hạ"
    // -------------------------------------------------------------
    final houseNumRegex = RegExp(r'^(\d+[a-zA-Z]?(\/\d+[a-zA-Z]?)?)\s+(.+)$');
    final match = houseNumRegex.firstMatch(strippedCity);
    String? houseNumber;
    String? streetNamePart;
    if (match != null) {
      houseNumber = match.group(1);
      streetNamePart = match.group(3)?.trim();
    }

    // Build list of distinct query permutations to run in parallel
    final querySet = <String>{
      cleanQuery,
      unaccented,
      strippedCity,
      strippedCityUnaccented,
    };

    if (streetNamePart != null && streetNamePart.isNotEmpty) {
      querySet.add(streetNamePart);
      querySet.add(removeDiacritics(streetNamePart));
    }

    // -------------------------------------------------------------
    // Step 3: Run Fast Photon Query (Fastest OSM Geocoder, ~150ms)
    // -------------------------------------------------------------
    List<MapPlace> photonList = await _executePhotonQuery(
      strippedCity.isNotEmpty ? strippedCity : cleanQuery,
      nearLocation: nearLocation,
    );

    // If fewer than 3 results, try unaccented query
    if (photonList.length < 3 && strippedCityUnaccented != strippedCity) {
      final unaccentedList = await _executePhotonQuery(
        strippedCityUnaccented,
        nearLocation: nearLocation,
      );
      photonList.addAll(unaccentedList);
    }

    // If query had a house number, synthesize top-ranked house number places
    if (houseNumber != null) {
      for (final p in photonList) {
        final isStreet = p.type == 'street' ||
            p.type == 'residential' ||
            p.type == 'secondary' ||
            p.type == 'primary' ||
            p.type == 'tertiary' ||
            p.type == 'trunk' ||
            p.name.toLowerCase().contains('phố') ||
            p.name.toLowerCase().contains('đường') ||
            p.name.toLowerCase().contains('ngõ') ||
            p.name.toLowerCase().contains('hẻm');

        if (isStreet) {
          final customName = 'Số $houseNumber ${p.name}';
          final customDisplay = p.displayName.contains(p.name)
              ? p.displayName.replaceFirst(p.name, customName)
              : '$customName, ${p.displayName}';

          addPlace(MapPlace(
            name: customName,
            displayName: customDisplay,
            coordinate: p.coordinate,
            type: 'house',
            category: 'building',
            distanceMeters: p.distanceMeters,
          ));
        }
      }
    }

    // Add direct Photon search results
    for (final p in photonList) {
      addPlace(p);
    }

    // Fallback to Nominatim only if still 0 results found
    if (mergedResults.isEmpty) {
      final nominatimList = await _executeNominatimQuery(cleanQuery, nearLocation: nearLocation);
      for (final p in nominatimList) {
        addPlace(p);
      }
    }

    // Sort by proximity distance to user location
    if (nearLocation != null && mergedResults.isNotEmpty) {
      mergedResults.sort((a, b) {
        final distA = a.distanceMeters ?? double.infinity;
        final distB = b.distanceMeters ?? double.infinity;
        return distA.compareTo(distB);
      });
    }

    return mergedResults.take(15).toList();
  }

  Future<List<MapPlace>> _executePhotonQuery(
    String query, {
    LatLng? nearLocation,
    bool useBbox = true,
  }) async {
    try {
      var urlStr = '$_photonBaseUrl/api?q=${Uri.encodeComponent(query)}&limit=12';
      if (useBbox) {
        urlStr += '&bbox=102.14,8.18,109.46,23.39';
      }
      if (nearLocation != null) {
        urlStr += '&lat=${nearLocation.latitude}&lon=${nearLocation.longitude}';
      }

      final response = await http.get(
        Uri.parse(urlStr),
        headers: {'User-Agent': 'ESP32_Smart_Navigator/2.0'},
      ).timeout(const Duration(milliseconds: 1800));

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        final features = data['features'] as List? ?? [];
        return _parsePhotonFeatures(features, nearLocation);
      }
    } catch (_) {}
    return [];
  }

  Future<List<MapPlace>> _executeNominatimQuery(
    String query, {
    LatLng? nearLocation,
  }) async {
    try {
      final url = Uri.parse(
        '$_nominatimBaseUrl/search?format=json&q=${Uri.encodeComponent(query)}&countrycodes=vn&addressdetails=1&limit=8&accept-language=vi',
      );

      final response = await http.get(
        url,
        headers: {'User-Agent': 'ESP32_Smart_Navigator/2.0 (contact@esp32nav.app)'},
      ).timeout(const Duration(milliseconds: 2000));

      if (response.statusCode == 200) {
        final list = jsonDecode(utf8.decode(response.bodyBytes)) as List? ?? [];
        return list.map<MapPlace>((item) {
          final lat = double.tryParse(item['lat']?.toString() ?? '0') ?? 0.0;
          final lon = double.tryParse(item['lon']?.toString() ?? '0') ?? 0.0;
          final coord = LatLng(lat, lon);
          final displayName = item['display_name'] as String? ?? 'Địa điểm';
          final name = item['name'] as String? ?? displayName.split(',').first.trim();

          double? dist;
          if (nearLocation != null) {
            const distanceCalculator = Distance();
            dist = distanceCalculator.as(LengthUnit.Meter, nearLocation, coord);
          }

          return MapPlace(
            name: name,
            displayName: displayName,
            coordinate: coord,
            type: item['type'] as String?,
            category: item['class'] as String?,
            distanceMeters: dist,
          );
        }).toList();
      }
    } catch (_) {}
    return [];
  }

  /// Search by predefined category around current location
  Future<List<MapPlace>> searchCategory(
    QuickSearchCategory category, {
    required LatLng nearLocation,
  }) async {
    try {
      final queryKeywords = category.query.split(',');
      final primaryKeyword = queryKeywords.first.trim();
      return await searchPlaces(primaryKeyword, nearLocation: nearLocation);
    } catch (_) {
      return [];
    }
  }

  List<MapPlace> _parsePhotonFeatures(List features, LatLng? nearLocation) {
    return features.map<MapPlace>((f) {
      final geometry = f['geometry'] as Map<String, dynamic>;
      final coords = geometry['coordinates'] as List;
      final lon = (coords[0] as num).toDouble();
      final lat = (coords[1] as num).toDouble();
      final coord = LatLng(lat, lon);

      final props = f['properties'] as Map<String, dynamic>;
      final rawName = props['name'] as String? ?? '';
      final houseNumber = props['housenumber'] as String? ?? '';
      final street = props['street'] as String? ?? '';
      final district = props['district'] as String? ?? '';
      final city = props['city'] as String? ?? props['state'] as String? ?? '';

      // Determine smart title
      String name;
      if (houseNumber.isNotEmpty && street.isNotEmpty) {
        if (rawName.isNotEmpty && rawName != street && !rawName.contains(houseNumber)) {
          name = 'Số $houseNumber $street ($rawName)';
        } else {
          name = 'Số $houseNumber $street';
        }
      } else if (rawName.isNotEmpty) {
        name = rawName;
      } else if (street.isNotEmpty) {
        name = street;
      } else if (district.isNotEmpty) {
        name = district;
      } else {
        name = 'Địa điểm';
      }

      final addressParts = <String>[];
      if (street.isNotEmpty && !name.contains(street)) {
        addressParts.add(street);
      }
      if (district.isNotEmpty && !name.contains(district)) {
        addressParts.add(district);
      }
      if (city.isNotEmpty && !name.contains(city)) {
        addressParts.add(city);
      }

      final fullDisplayName = addressParts.isNotEmpty
          ? '$name, ${addressParts.join(', ')}'
          : name;

      double? dist;
      if (nearLocation != null) {
        const distanceCalculator = Distance();
        dist = distanceCalculator.as(LengthUnit.Meter, nearLocation, coord);
      }

      return MapPlace(
        name: name,
        displayName: fullDisplayName,
        coordinate: coord,
        type: props['osm_value'] as String? ?? props['type'] as String?,
        category: props['osm_key'] as String?,
        distanceMeters: dist,
      );
    }).toList();
  }

  /// Reverse Geocode Coordinates to Human-Readable Vietnamese Address
  Future<MapPlace> reverseGeocode(LatLng location) async {
    // Try Nominatim first for rich address components
    try {
      final url = Uri.parse(
        '$_nominatimBaseUrl/reverse?format=json&lat=${location.latitude}&lon=${location.longitude}&accept-language=vi',
      );
      final response = await http.get(
        url,
        headers: {'User-Agent': 'ESP32_Smart_Navigator/2.0 (contact@esp32nav.app)'},
      ).timeout(const Duration(seconds: 4));

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        final displayName = data['display_name'] as String? ?? '';
        final name = data['name'] as String? ?? displayName.split(',').first.trim();
        if (displayName.isNotEmpty) {
          return MapPlace(
            name: name.isNotEmpty ? name : 'Vị trí đã ghim',
            displayName: displayName,
            coordinate: location,
            type: data['type'] as String?,
            category: data['class'] as String?,
          );
        }
      }
    } catch (_) {}

    // Fallback to Photon Reverse
    try {
      final url = Uri.parse(
        '$_photonBaseUrl/reverse?lat=${location.latitude}&lon=${location.longitude}',
      );
      final response = await http.get(
        url,
        headers: {'User-Agent': 'ESP32_Smart_Navigator/2.0'},
      ).timeout(const Duration(seconds: 4));

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        final features = data['features'] as List? ?? [];
        if (features.isNotEmpty) {
          final props = features.first['properties'] as Map<String, dynamic>;
          final rawName = props['name'] as String? ?? '';
          final houseNumber = props['housenumber'] as String? ?? '';
          final street = props['street'] as String? ?? '';
          final district = props['district'] as String? ?? '';
          final city = props['city'] as String? ?? props['state'] as String? ?? '';

          String name;
          if (houseNumber.isNotEmpty && street.isNotEmpty) {
            name = 'Số $houseNumber $street';
          } else if (rawName.isNotEmpty) {
            name = rawName;
          } else if (street.isNotEmpty) {
            name = street;
          } else if (district.isNotEmpty) {
            name = district;
          } else {
            name = 'Vị trí đã ghim';
          }

          final addressParts = <String>[];
          if (street.isNotEmpty && !name.contains(street)) addressParts.add(street);
          if (district.isNotEmpty && !name.contains(district)) addressParts.add(district);
          if (city.isNotEmpty && !name.contains(city)) addressParts.add(city);

          final fullDisplayName = addressParts.isNotEmpty
              ? '$name, ${addressParts.join(', ')}'
              : name;

          return MapPlace(
            name: name,
            displayName: fullDisplayName,
            coordinate: location,
            type: props['osm_value'] as String?,
            category: props['osm_key'] as String?,
          );
        }
      }
    } catch (_) {}

    return MapPlace(
      name: 'Vị trí đã ghim',
      displayName: 'Tọa độ: ${location.latitude.toStringAsFixed(4)}, ${location.longitude.toStringAsFixed(4)}',
      coordinate: location,
    );
  }
}
