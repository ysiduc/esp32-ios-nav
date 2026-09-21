import 'package:latlong2/latlong.dart';

enum SearchQueryIntentType {
  coordinate,
  houseAddress,
  street,
  poi,
  districtOrCity,
  general,
}

class SearchQueryIntent {
  final SearchQueryIntentType type;
  final String rawQuery;
  final String? houseNumber;
  final String? streetName;
  final LatLng? targetCoordinate;

  const SearchQueryIntent({
    required this.type,
    required this.rawQuery,
    this.houseNumber,
    this.streetName,
    this.targetCoordinate,
  });

  static const List<String> _poiKeywords = [
    'bệnh viện', 'benh vien', 'bv',
    'đại học', 'dai hoc', 'đh', 'dh',
    'trường', 'truong', 'thpt', 'thcs', 'tiểu học', 'mầm non',
    'khách sạn', 'khach san', 'hotel', 'resort', 'homestay',
    'hồ', 'công viên', 'cong vien',
    'bến xe', 'ben xe', 'bx',
    'sân bay', 'san bay', 'airport',
    'tòa nhà', 'toa nha', 'building', 'tower',
    'keangnam', 'royal city', 'times city', 'landmark',
    'hầm chui', 'ham chui', 'hầm', 'ham',
    'chùa', 'chua', 'đền', 'den', 'nhà thờ', 'nha tho',
    'siêu thị', 'sieu thi', 'chợ', 'cho ',
    'vincom', 'aeon', 'lotte', 'big c', 'go!', 'mega market',
    'ga ', 'cầu ', 'cau ', 'trung tâm', 'trung tam',
  ];

  static const List<String> _streetKeywords = [
    'phố', 'pho', 'đường', 'duong', 'đ.', 'd.', 'ngõ', 'ngo', 'ngách', 'ngach', 'hẻm', 'hem',
  ];

  static const List<String> _districtOrCityKeywords = [
        'hoàng mai', 'hoang mai', 'đống đa', 'dong da', 'ba đình', 'ba dinh',
    'hai bà trưng', 'hai ba trung', 'cầu giấy', 'cau giay', 'thanh xuân', 'thanh xuan',
    'tây hồ', 'tay ho', 'long biên', 'long bien', 'nam từ liêm', 'nam tu liem',
    'bắc từ liêm', 'bac tu liem', 'hà đông', 'ha dong', 'thanh trì', 'thanh tri',
    'gia lâm', 'gia lam', 'đông anh', 'dong anh', 'sóc sơn', 'soc son',
    'quận 1', 'quan 1', 'quận 2', 'quan 2', 'quận 3', 'quan 3', 'quận 7', 'quan 7',
    'bình thạnh', 'binh thanh', 'thủ đức', 'thu duc', 'gò vấp', 'go vap',
    'hải châu', 'hai chau', 'sơn trà', 'son tra', 'ngũ hành sơn', 'ngu hanh son',
    'hải an', 'hai an', 'ngô quyền', 'ngo quyen', 'lê chân', 'le chan',
    'quận', 'quan', 'q.', 'huyện', 'huyen', 'h.', 'thị xã', 'thi xa', 'tx',
    'thành phố', 'thanh pho', 'tp', 'tp.', 'tỉnh', 'tinh', 'phường', 'phuong', 'p.', 'xã', 'xa',
    'hà nội', 'ha noi', 'hồ chí minh', 'ho chi minh', 'hcm', 'sài gòn', 'sai gon',
    'đà nẵng', 'da nang', 'hải phòng', 'hai phong', 'cần thơ', 'can tho',
    'bắc ninh', 'bac ninh', 'hạ long', 'ha long', 'quảng ninh', 'quang ninh',
    'hải dương', 'hai duong', 'nội bài', 'noi bai', 'cát bi', 'cat bi',
  ];

  /// Classify query intent
  static SearchQueryIntent parse(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return SearchQueryIntent(type: SearchQueryIntentType.general, rawQuery: trimmed);
    }

    // 1. Coordinate Pattern (e.g. "21.0285, 105.8542" or "21.0285 105.8542")
    final coordRegex = RegExp(r'^(\-?\d{1,2}\.\d{3,})[\s,;]+(\-?\d{1,3}\.\d{3,})$');
    final coordMatch = coordRegex.firstMatch(trimmed);
    if (coordMatch != null) {
      final lat = double.tryParse(coordMatch.group(1)!);
      final lon = double.tryParse(coordMatch.group(2)!);
      if (lat != null && lon != null && lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180) {
        return SearchQueryIntent(
          type: SearchQueryIntentType.coordinate,
          rawQuery: trimmed,
          targetCoordinate: LatLng(lat, lon),
        );
      }
    }

    final lower = trimmed.toLowerCase();

    // 2. House Address Pattern
    // Matches: "96 Định Công", "Số 157 Nguyễn Cảnh Dị", "12A Tôn Thất Tùng", "96/2 Định Công", "Ngõ 40 Tạ Quang Bửu"
    final houseRegex = RegExp(
      r'^(?:số\s+)?(\d+[a-zA-Z]?(?:[/-]\d+[a-zA-Z]?)?)\s+(?:phố|đường|đ\.|d\.)?\s*(.+)$',
      caseSensitive: false,
    );
    final houseMatch = houseRegex.firstMatch(trimmed);
    if (houseMatch != null) {
      final numStr = houseMatch.group(1)!.trim();
      final streetStr = houseMatch.group(2)!.trim();
      if (streetStr.isNotEmpty && !RegExp(r'^\d+$').hasMatch(streetStr)) {
        return SearchQueryIntent(
          type: SearchQueryIntentType.houseAddress,
          rawQuery: trimmed,
          houseNumber: numStr,
          streetName: streetStr,
        );
      }
    }

    // Secondary house pattern: "Ngõ 96 Định Công" or "Hẻm 12..."
    final ngoHouseRegex = RegExp(
      r'^(?:ngõ|ngo|ngách|ngach|hẻm|hem)\s+(\d+[a-zA-Z]?(?:[/-]\d+[a-zA-Z]?)?)\s*(?:phố|đường|đ\.|d\.)?\s*(.+)$',
      caseSensitive: false,
    );
    final ngoMatch = ngoHouseRegex.firstMatch(trimmed);
    if (ngoMatch != null) {
      final numStr = ngoMatch.group(1)!.trim();
      final streetStr = ngoMatch.group(2)!.trim();
      return SearchQueryIntent(
        type: SearchQueryIntentType.houseAddress,
        rawQuery: trimmed,
        houseNumber: numStr,
        streetName: streetStr.isNotEmpty ? streetStr : null,
      );
    }

    // 3. POI Pattern
    for (final kw in _poiKeywords) {
      if (lower.contains(kw)) {
        return SearchQueryIntent(type: SearchQueryIntentType.poi, rawQuery: trimmed);
      }
    }

    // 4. District / City Pattern
    for (final kw in _districtOrCityKeywords) {
      if (lower == kw || lower.startsWith('$kw ') || lower.endsWith(' $kw')) {
        return SearchQueryIntent(type: SearchQueryIntentType.districtOrCity, rawQuery: trimmed);
      }
    }

    // 5. Street Pattern
    for (final kw in _streetKeywords) {
      if (lower.startsWith('$kw ') || lower.startsWith('$kw.')) {
        final streetOnly = trimmed.substring(kw.length).replaceAll(RegExp(r'^[\s.]+'), '').trim();
        return SearchQueryIntent(
          type: SearchQueryIntentType.street,
          rawQuery: trimmed,
          streetName: streetOnly.isNotEmpty ? streetOnly : trimmed,
        );
      }
    }

    // If it ends with common street names or looks like a typical street query
    if (lower.contains('phố') || lower.contains('đường') || lower.contains('đại lộ')) {
      return SearchQueryIntent(type: SearchQueryIntentType.street, rawQuery: trimmed);
    }

    return SearchQueryIntent(type: SearchQueryIntentType.general, rawQuery: trimmed);
  }
}
