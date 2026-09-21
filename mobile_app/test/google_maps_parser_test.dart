import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile_app/models/route_model.dart';
import 'package:mobile_app/services/google_maps_parser.dart';

class RealHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback = (X509Certificate cert, String host, int port) => true;
  }
}

class MockGoogleMapsRedirectResolver implements GoogleMapsRedirectResolver {
  final Map<String, ({String finalUrl, String htmlBody})> mocks;
  MockGoogleMapsRedirectResolver(this.mocks);

  @override
  Future<({String finalUrl, String htmlBody})> resolve(String url) async {
    if (mocks.containsKey(url)) return mocks[url]!;
    return (finalUrl: url, htmlBody: '');
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
      expect(GoogleMapsParser.isGoogleMapsOrCoordInput('20°59\'07.8"N 105°50\'29.4"E'), isTrue);
      expect(GoogleMapsParser.isGoogleMapsOrCoordInput('Định Công Hà Nội'), isFalse);
    });
  });

  group('GoogleMapsParser Fidelity & Semantics Tests', () {
    final parser = GoogleMapsParser();

    test('Section 35: Required Camera-Center Regression Test (!3d/!4d wins over @ camera center)', () async {
      // Camera center is at 21.000000, 105.800000
      // Actual POI coordinate is at 21.001234, 105.803456
      final url = 'https://www.google.com/maps/place/POI-ABC/@21.000000,105.800000,17z/data=!4m5!3m4!1s0x0:0x0!8m2!3d21.001234!4d105.803456';
      final resolved = await parser.parseResolvedLink(url);

      expect(resolved.exactCoordinate, isNotNull);
      expect(resolved.exactCoordinate!.latitude, closeTo(21.001234, 0.00001));
      expect(resolved.exactCoordinate!.longitude, closeTo(105.803456, 0.00001));

      expect(resolved.cameraCoordinate, isNotNull);
      expect(resolved.cameraCoordinate!.latitude, closeTo(21.000000, 0.00001));
      expect(resolved.cameraCoordinate!.longitude, closeTo(105.800000, 0.00001));

      // MUST NOT equal camera center!
      expect(resolved.targetCoordinate!.latitude, isNot(closeTo(21.000000, 0.0001)));
      expect(resolved.confidence, GoogleMapsResolutionConfidence.exactPin);
      expect(resolved.isExact, isTrue);
    });

    test('Section 36: Required No-Exact-Coord Test (Named POI with ONLY @ does NOT treat @ as exact)', () async {
      // URL has place name and @ camera center, but NO protobuf !3d/!4d or pin
      final url = 'https://www.google.com/maps/place/UnindexedSpecialPlaceXYZ/@21.016922,105.783688,16z';
      final resolved = await parser.parseResolvedLink(url);

      // Must NOT return camera @ as exact pin
      expect(resolved.exactCoordinate, isNull);
      expect(resolved.confidence, GoogleMapsResolutionConfidence.approximate);
      expect(resolved.precision, PlacePrecision.approximate);
      expect(resolved.isExact, isFalse);
      expect(resolved.cameraCoordinate, isNotNull);
      expect(resolved.cameraCoordinate!.latitude, closeTo(21.016922, 0.0001));
    });

    test('Section 37: Required Directions Link Test (Resolves destination, never origin or camera)', () async {
      // Origin: 20.9900,105.8000 (A)
      // Destination: 21.0285,105.8542 (B)
      // Camera: 21.0100,105.8200 (C)
      final url = 'https://www.google.com/maps/dir/20.9900,105.8000/21.0285,105.8542/@21.0100,105.8200,14z';
      final resolved = await parser.parseResolvedLink(url);

      expect(resolved.exactCoordinate, isNotNull);
      // Expected: B (Destination), NEVER A or C
      expect(resolved.exactCoordinate!.latitude, closeTo(21.0285, 0.0001));
      expect(resolved.exactCoordinate!.longitude, closeTo(105.8542, 0.0001));
      expect(resolved.confidence, GoogleMapsResolutionConfidence.exactDestination);
      expect(resolved.isExact, isTrue);

      // Verify it didn't pick origin or camera
      expect(resolved.exactCoordinate!.latitude, isNot(closeTo(20.9900, 0.001)));
      expect(resolved.exactCoordinate!.latitude, isNot(closeTo(21.0100, 0.001)));
    });

    test('Section 38: Required Mock Shortlink Test (Deterministic without Google network)', () async {
      final mockResolver = MockGoogleMapsRedirectResolver({
        'https://maps.app.goo.gl/mock123': (
          finalUrl: 'https://www.google.com/maps/place/Keangnam/@21.0000,105.7000,17z/data=!3m1!4b1!4m5!3m4!1s0x0:0x0!8m2!3d21.016922!4d105.783688',
          htmlBody: '',
        ),
      });

      final mockParser = GoogleMapsParser(redirectResolver: mockResolver);
      final resolved = await mockParser.parseResolvedLink('https://maps.app.goo.gl/mock123');

      expect(resolved.exactCoordinate, isNotNull);
      expect(resolved.exactCoordinate!.latitude, closeTo(21.016922, 0.00001));
      expect(resolved.exactCoordinate!.longitude, closeTo(105.783688, 0.00001));
      expect(resolved.isExact, isTrue);
      expect(resolved.confidence, GoogleMapsResolutionConfidence.exactPin);
    });

    test('Section 34: Dropped pin link in /place/LAT,LON', () async {
      final url = 'https://www.google.com/maps/place/21.028511,105.854212/@21.028511,105.854212,17z';
      final resolved = await parser.parseResolvedLink(url);

      expect(resolved.exactCoordinate, isNotNull);
      expect(resolved.exactCoordinate!.latitude, closeTo(21.028511, 0.00001));
      expect(resolved.exactCoordinate!.longitude, closeTo(105.854212, 0.00001));
      expect(resolved.confidence, GoogleMapsResolutionConfidence.exactPin);
    });

    test('Section 34: Explicit coordinate query parameter ?q=LAT,LON', () async {
      final url = 'https://www.google.com/maps?q=21.028511,105.854212';
      final resolved = await parser.parseResolvedLink(url);

      expect(resolved.exactCoordinate, isNotNull);
      expect(resolved.exactCoordinate!.latitude, closeTo(21.028511, 0.00001));
      expect(resolved.confidence, GoogleMapsResolutionConfidence.exactPin);
    });

    test('Section 34: Vietnamese DMS coordinate text', () async {
      final text = '20°59\'07.8"N 105°50\'29.4"E';
      final resolved = await parser.parseResolvedLink(text);

      expect(resolved.exactCoordinate, isNotNull);
      expect(resolved.exactCoordinate!.latitude, closeTo(20.9855, 0.001));
      expect(resolved.exactCoordinate!.longitude, closeTo(105.8415, 0.001));
      expect(resolved.confidence, GoogleMapsResolutionConfidence.exactPin);
    });

    test('Section 28 & 29: Exact coordinate is NEVER changed by reverse geocoding', () async {
      final exactPoint = const LatLng(21.028511, 105.854212);
      final place = await parser.parseInput('21.028511, 105.854212');

      expect(place, isNotNull);
      // The coordinate of the final MapPlace must remain EXACTLY what was passed!
      expect(place!.coordinate.latitude, 21.028511);
      expect(place.coordinate.longitude, 105.854212);
    });
  });
}
