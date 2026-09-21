import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile_app/models/route_model.dart';
import 'package:mobile_app/services/google_maps_parser.dart';
import 'package:mobile_app/services/google_link_controller.dart';

class CountingMockRedirectResolver implements GoogleMapsRedirectResolver {
  int callCount = 0;
  final Future<String> Function(String url)? resolverFn;

  CountingMockRedirectResolver({this.resolverFn});

  @override
  Future<({String finalUrl, String htmlBody})> resolve(String url) async {
    callCount++;
    if (resolverFn != null) {
      final res = await resolverFn!(url);
      return (finalUrl: res, htmlBody: '');
    }
    return (finalUrl: url, htmlBody: '');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('P5.4.1 Google Maps Link Resolution & Non-Stuck Controller Tests', () {
    test('Local Fast-Path: Full URL with !3d/!4d coordinates requires ZERO network redirect calls', () async {
      final mockResolver = CountingMockRedirectResolver();
      final parser = GoogleMapsParser(redirectResolver: mockResolver);

      const fullUrl = 'https://www.google.com/maps/place/Hanoi/@21.028511,105.854167,17z/data=!3m1!4b1!4m6!3m5!1s0x3135ab9bdad19623:0x1b1c67d1d2b!8m2!3d21.028511!4d105.854167';

      final place = await parser.parseInput(fullUrl);

      expect(place, isNotNull);
      expect(mockResolver.callCount, equals(0), reason: 'Authoritative coordinates in full URL must bypass network completely');
      expect(place!.coordinate.latitude, closeTo(21.028511, 0.0001));
      expect(place.coordinate.longitude, closeTo(105.854167, 0.0001));
    });

    test('Shortlink Success: Redirect resolves to exact coordinate without reverse geocoding block', () async {
      final mockResolver = CountingMockRedirectResolver(
        resolverFn: (shortUrl) async {
          // Simulate 1 hop redirect
          return 'https://maps.google.com/?q=21.0368,105.8345';
        },
      );

      final parser = GoogleMapsParser(redirectResolver: mockResolver);
      final place = await parser.parseInput('https://maps.app.goo.gl/abc1234');

      expect(place, isNotNull);
      expect(mockResolver.callCount, equals(1));
      expect(place!.coordinate.latitude, closeTo(21.0368, 0.0001));
      expect(place.coordinate.longitude, closeTo(105.8345, 0.0001));
      expect(place.precision, equals(PlacePrecision.coordinate));
    });

    test('Authoritative Coordinate Detection: Recognizes exact coordinate markers in URL', () async {
      expect(GoogleMapsParser.hasAuthoritativeCoordinates('https://maps.google.com/?q=21.0285,105.8542'), isTrue);
      expect(GoogleMapsParser.hasAuthoritativeCoordinates('https://www.google.com/maps/place/21.0285,105.8542'), isTrue);
      expect(GoogleMapsParser.hasAuthoritativeCoordinates('https://www.google.com/maps/search/21.0285,105.8542'), isTrue);
      expect(GoogleMapsParser.hasAuthoritativeCoordinates('https://maps.app.goo.gl/short'), isFalse);
    });

    test('Google Link Generation: Rapid paste supersedes slow initial link', () async {
      final slowMock = CountingMockRedirectResolver(
        resolverFn: (url) async {
          if (url.contains('slow')) {
            await Future.delayed(const Duration(milliseconds: 300));
            return 'https://maps.google.com/?q=20.1234,100.1234';
          } else {
            await Future.delayed(const Duration(milliseconds: 40));
            return 'https://maps.google.com/?q=21.0285,105.8542';
          }
        },
      );

      final parser = GoogleMapsParser(redirectResolver: slowMock);
      final controller = GoogleLinkResolutionController(parser: parser);

      // Paste link 1 (slow)
      final f1 = controller.resolve('https://maps.app.goo.gl/slow_link');
      // 10ms later, paste link 2 (fast)
      await Future.delayed(const Duration(milliseconds: 10));
      final f2 = controller.resolve('https://maps.app.goo.gl/fast_link');

      final results = await Future.wait([f1, f2]);

      // Result 1 should be superseded (null returned to caller or ignored)
      expect(results[0], isNull);
      // Result 2 should be the active resolved place
      expect(results[1], isNotNull);
      expect(results[1]!.coordinate.latitude, closeTo(21.0285, 0.001));
      expect(controller.state.resolvedPlace, isNotNull);
      expect(controller.state.resolvedPlace!.coordinate.latitude, closeTo(21.0285, 0.001));
    });

    test('Lifecycle & Invariant Safety: isLoading is ALWAYS false after success, failure, timeout, cancel', () async {
      // 1. Success case
      final fastParser = GoogleMapsParser(
        redirectResolver: CountingMockRedirectResolver(
          resolverFn: (_) async => 'https://maps.google.com/?q=21.0285,105.8542',
        ),
      );
      final ctrlSuccess = GoogleLinkResolutionController(parser: fastParser);
      expect(ctrlSuccess.state.isLoading, isFalse);

      final pSuccess = await ctrlSuccess.resolve('https://maps.app.goo.gl/valid');
      expect(pSuccess, isNotNull);
      expect(ctrlSuccess.state.isLoading, isFalse);
      expect(ctrlSuccess.state.status, equals(GoogleLinkResolutionStatus.success));

      // 2. Failure case (invalid link)
      final failParser = GoogleMapsParser(
        redirectResolver: CountingMockRedirectResolver(
          resolverFn: (_) async => 'https://invalid-non-maps-url.com',
        ),
      );
      final ctrlFail = GoogleLinkResolutionController(parser: failParser);
      final pFail = await ctrlFail.resolve('https://invalid-non-maps-url.com');
      expect(pFail, isNull);
      expect(ctrlFail.state.isLoading, isFalse);
      expect(ctrlFail.state.status, equals(GoogleLinkResolutionStatus.failed));

      // 3. Timeout case
      final hangingParser = GoogleMapsParser(
        redirectResolver: CountingMockRedirectResolver(
          resolverFn: (_) async {
            await Future.delayed(const Duration(milliseconds: 1000));
            return 'https://maps.google.com/?q=21.0285,105.8542';
          },
        ),
      );
      final ctrlTimeout = GoogleLinkResolutionController(
        parser: hangingParser,
        timeoutBudget: const Duration(milliseconds: 150),
      );
      final pTimeout = await ctrlTimeout.resolve('https://maps.app.goo.gl/hang');
      expect(pTimeout, isNull);
      expect(ctrlTimeout.state.isLoading, isFalse);
      expect(ctrlTimeout.state.status, equals(GoogleLinkResolutionStatus.timedOut));

      // 4. Cancel case
      final ctrlCancel = GoogleLinkResolutionController(parser: hangingParser);
      final cancelFuture = ctrlCancel.resolve('https://maps.app.goo.gl/hang');
      await Future.delayed(const Duration(milliseconds: 50));
      ctrlCancel.cancel();
      expect(ctrlCancel.state.isLoading, isFalse);
      expect(ctrlCancel.state.status, equals(GoogleLinkResolutionStatus.cancelled));
      await cancelFuture;
      expect(ctrlCancel.state.isLoading, isFalse);
    });
  });
}
