import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile_app/services/search_service.dart';

class RealHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback = (X509Certificate cert, String host, int port) => true;
  }
}

void main() {
  setUp(() {
    HttpOverrides.global = RealHttpOverrides();
  });

  test('Comprehensive live search test for all Vietnamese queries', () async {
    final service = SearchService();
    final hanoi = const LatLng(21.0285, 105.8542);

    final queries = [
      'Định công hà nội',
      '157 nguyễn cảnh',
      '96 định công',
      'Keangnam',
      'Sân bay Nội Bài',
      'Bến xe Mỹ Đình',
    ];

    for (final q in queries) {
      final results = await service.searchPlaces(q, nearLocation: hanoi);
      print('=== Search "$q" -> ${results.length} results ===');
      for (final r in results.take(3)) {
        print('   * ${r.name} (${r.displayName})');
      }
      expect(results.isNotEmpty, isTrue, reason: 'Failed to find results for "$q"');
    }
  });
}
