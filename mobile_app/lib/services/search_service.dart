import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import '../models/route_model.dart';

class SearchService {
  static const String _photonBaseUrl = 'https://photon.komoot.io';

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
      name: 'Phố Nguyễn Cảnh Dị',
      displayName: 'Phố Nguyễn Cảnh Dị, Định Công, Hoàng Mai, Hà Nội',
      coordinate: const LatLng(20.9828, 105.8350),
      type: 'street',
    ),
    MapPlace(
      name: 'Landmark 72',
      displayName: 'Đường Phạm Hùng, Mễ Trì, Nam Từ Liêm, Hà Nội',
      coordinate: const LatLng(21.0173, 105.7836),
      type: 'commercial',
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

  /// Ultra-Fast Parallel Multi-Engine Search with Diacritic Normalization, City Stripping & House Number Expansion
  Future<List<MapPlace>> searchPlaces(
    String query, {
    LatLng? nearLocation,
  }) async {
    final cleanQuery = query.trim();
    if (cleanQuery.isEmpty) return [];

    final unaccented = removeDiacritics(cleanQuery);
    final strippedCity = stripCitySuffix(cleanQuery);
    final strippedCityUnaccented = removeDiacritics(strippedCity);

    // Extract house number if user types "157 nguyễn cảnh", "96 định công", "12/4 láng hạ"
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

    // Execute parallel searches for all permutations
    final futures = querySet.map((q) => _executePhotonQuery(q, nearLocation: nearLocation)).toList();
    final nestedResults = await Future.wait(futures);

    final mergedResults = <MapPlace>[];
    final seenKeys = <String>{};

    // If query had a house number, synthesize top-ranked house number places for matching streets
    if (houseNumber != null) {
      for (final list in nestedResults) {
        for (final p in list) {
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

            final key = customName.toLowerCase();
            if (!seenKeys.contains(key)) {
              seenKeys.add(key);
              mergedResults.add(MapPlace(
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
      }
    }

    // Add all direct search results
    for (final list in nestedResults) {
      for (final p in list) {
        final key = '${p.name}_${p.coordinate.latitude.toStringAsFixed(4)}_${p.coordinate.longitude.toStringAsFixed(4)}'.toLowerCase();
        if (!seenKeys.contains(key)) {
          seenKeys.add(key);
          mergedResults.add(p);
        }
      }
    }

    // Fallback: If still 0 results, search globally without bbox
    if (mergedResults.isEmpty) {
      final globalList = await _executePhotonQuery(strippedCityUnaccented, nearLocation: nearLocation, useBbox: false);
      for (final p in globalList) {
        final key = '${p.name}_${p.coordinate.latitude.toStringAsFixed(4)}_${p.coordinate.longitude.toStringAsFixed(4)}'.toLowerCase();
        if (!seenKeys.contains(key)) {
          seenKeys.add(key);
          mergedResults.add(p);
        }
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
      var urlStr = '$_photonBaseUrl/api?q=${Uri.encodeComponent(query)}&limit=15';
      if (useBbox) {
        urlStr += '&bbox=102.14,8.18,109.46,23.39';
      }
      if (nearLocation != null) {
        urlStr += '&lat=${nearLocation.latitude}&lon=${nearLocation.longitude}';
      }

      final response = await http.get(
        Uri.parse(urlStr),
        headers: {'User-Agent': 'ESP32_Smart_Navigator/2.0'},
      ).timeout(const Duration(seconds: 4));

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        final features = data['features'] as List? ?? [];
        return _parseFeatures(features, nearLocation);
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

  List<MapPlace> _parseFeatures(List features, LatLng? nearLocation) {
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
