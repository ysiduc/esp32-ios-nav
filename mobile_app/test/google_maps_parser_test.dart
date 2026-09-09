import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/services/google_maps_parser.dart';

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

  group('GoogleMapsParser Detection Tests', () {
    test('isGoogleMapsOrCoordInput detects various formats', () {
      expect(GoogleMapsParser.isGoogleMapsOrCoordInput('https://maps.app.goo.gl/abc123xyz'), isTrue);
      expect(GoogleMapsParser.isGoogleMapsOrCoordInput('Check this out: https://goo.gl/maps/abc123xyz'), isTrue);
      expect(GoogleMapsParser.isGoogleMapsOrCoordInput('https://www.google.com/maps/place/Keangnam/@21.0169,105.7836,17z'), isTrue);
      expect(GoogleMapsParser.isGoogleMapsOrCoordInput('21.0285, 105.8542'), isTrue);
      expect(GoogleMapsParser.isGoogleMapsOrCoordInput('20.9848,105.8385'), isTrue);
      expect(GoogleMapsParser.isGoogleMapsOrCoordInput('Định Công Hà Nội'), isFalse);
    });
  });

  group('GoogleMapsParser Parsing Tests', () {
    final parser = GoogleMapsParser();

    test('Parses raw coordinate string', () async {
      final place = await parser.parseInput('21.0169, 105.7836');
      expect(place, isNotNull);
      expect((place!.coordinate.latitude - 21.0169).abs() < 0.01, isTrue);
      expect((place.coordinate.longitude - 105.7836).abs() < 0.01, isTrue);
      print('Parsed raw coordinate -> ${place.name}, ${place.displayName}');
    });

    test('Parses Google Maps URL with @coordinates', () async {
      final url = 'https://www.google.com/maps/place/Keangnam+Hanoi+Landmark+Tower/@21.016922,105.783688,17z/data=!3m1!4b1';
      final place = await parser.parseInput(url);
      print('TEST 2 PLACE: name="${place?.name}", displayName="${place?.displayName}"');
      expect(place, isNotNull);
      expect(place!.name.contains('Keangnam'), isTrue);
      expect((place.coordinate.latitude - 21.016922).abs() < 0.001, isTrue);
      print('Parsed URL @coord -> ${place.name}, coord: ${place.coordinate}');
    });

    test('Parses Google Maps URL with protobuf !3d !4d coordinates', () async {
      final url = 'https://www.google.com/maps/place/Hoan+Kiem+Lake/data=!4m2!3m1!1s0x0:0x0!8m2!3d21.028511!4d105.854212';
      final place = await parser.parseInput(url);
      expect(place, isNotNull);
      expect((place!.coordinate.latitude - 21.028511).abs() < 0.001, isTrue);
      print('Parsed protobuf -> ${place.name}, coord: ${place.coordinate}');
    });

    test('Parses shared text containing place name and URL', () async {
      final sharedText = 'Landmark 72 Tower\nhttps://www.google.com/maps/place/Landmark+72/@21.016922,105.783688,17z';
      final place = await parser.parseInput(sharedText);
      expect(place, isNotNull);
      expect((place!.coordinate.latitude - 21.016922).abs() < 0.001, isTrue);
      print('Parsed shared text -> ${place.name}, coord: ${place.coordinate}');
    });
  });
}
