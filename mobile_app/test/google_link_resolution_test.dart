import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile_app/models/route_model.dart';
import 'package:mobile_app/services/google_maps_parser.dart';
import 'package:mobile_app/services/google_link_controller.dart';
import 'package:mobile_app/services/search_service.dart';

class CountingMockRedirectResolver implements GoogleMapsRedirectResolver {
  int callCount = 0;
  final Future<String> Function(String url)? resolverFn;
  final Future<({String finalUrl, String htmlBody})> Function(String url)? resolverFullFn;

  CountingMockRedirectResolver({this.resolverFn, this.resolverFullFn});

  @override
  Future<({String finalUrl, String htmlBody})> resolve(String url) async {
    callCount++;
    if (resolverFullFn != null) {
      return await resolverFullFn!(url);
    }
    if (resolverFn != null) {
      final res = await resolverFn!(url);
      return (finalUrl: res, htmlBody: '');
    }
    return (finalUrl: url, htmlBody: '');
  }
}

class TrackingMockSearchService extends SearchService {
  int searchPlacesCallCount = 0;
  List<MapPlace> cannedResults = [];

  @override
  Future<List<MapPlace>> searchPlaces(String query, {LatLng? nearLocation, SearchExecutionMode mode = SearchExecutionMode.autocomplete}) async {
    searchPlacesCallCount++;
    return cannedResults;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('P5.4.1 & P5.4.1.1 Google Maps Link Resolution & Pin Fidelity Tests', () {
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

    test('HTML Canonical Link Extraction: decodes HTML entities and supports either attribute order', () {
      const html1 = '<link rel="canonical" href="https://www.google.com/maps/place/Target/@21.03655,105.85165,17z/data=!3m1!4b1!4m6!3m5!1s0x0:0x0!8m2!3d21.03698!4d105.85234">';
      expect(GoogleMapsParser.extractCanonicalUrl(html1), contains('!3d21.03698!4d105.85234'));

      const html2 = '<link href="https://www.google.com/maps/place/Target/?data=!3d21.03698&amp;4d105.85234" rel="canonical">';
      final url2 = GoogleMapsParser.extractCanonicalUrl(html2);
      expect(url2, isNotNull);
      expect(url2, contains('&4d105.85234')); // Decoded &amp;
    });

    test('HTML OG:URL Extraction: decodes HTML entities and supports attribute order variations', () {
      const html1 = '<meta property="og:url" content="https://www.google.com/maps/place/Target/...!3d21.04567!4d105.84321">';
      expect(GoogleMapsParser.extractOgUrl(html1), contains('!3d21.04567!4d105.84321'));

      const html2 = '<meta content="https://www.google.com/maps/place/Target/...!3d21.04567!4d105.84321" property="og:url">';
      expect(GoogleMapsParser.extractOgUrl(html2), contains('!3d21.04567!4d105.84321'));
    });

    test('Section 21 & 22 Failure Model: Final URL has no pin, camera @21.03655,105.85165, HTML canonical has true target pin', () async {
      final mockSearch = TrackingMockSearchService();
      final mockResolver = CountingMockRedirectResolver(
        resolverFullFn: (url) async {
          return (
            finalUrl: 'https://www.google.com/maps/place/Ph%E1%BB%91+Nguy%E1%BB%85n+Si%C3%AAu/@21.03655,105.85165,17z',
            htmlBody: '''
              <!DOCTYPE html><html><head>
              <title>Phố Nguyễn Siêu - Google Maps</title>
              <link rel="canonical" href="https://www.google.com/maps/place/Target+Store/@21.03655,105.85165,17z/data=!3m1!4b1!4m6!3m5!1s0x3135abb6b9c9f655:0x89e5c70753ba03cb!8m2!3d21.03698!4d105.85234">
              </head><body></body></html>
            ''',
          );
        },
      );

      final parser = GoogleMapsParser(
        searchService: mockSearch,
        redirectResolver: mockResolver,
      );

      final resolved = await parser.parseResolvedLink('https://maps.app.goo.gl/Ph7FpKY9xDfo7CBF8?g_st=ic');

      // Assert Authority 3: Canonical URL wins over camera or title search
      expect(resolved.resolutionSource, equals('canonical_url'));
      expect(resolved.confidence, equals(GoogleMapsResolutionConfidence.exactPin));
      expect(resolved.isExact, isTrue);
      expect(resolved.requiresConfirmation, isFalse);

      // Must be the TRUE target pin from canonical (!3d21.03698!4d105.85234)
      expect(resolved.exactDestinationCoordinate, isNotNull);
      expect(resolved.exactDestinationCoordinate!.latitude, closeTo(21.03698, 0.00001));
      expect(resolved.exactDestinationCoordinate!.longitude, closeTo(105.85234, 0.00001));

      // Must NOT be the camera coordinate @21.03655,105.85165
      expect(resolved.exactDestinationCoordinate!.latitude, isNot(closeTo(21.03655, 0.0001)));

      // SearchService must NOT be called when canonical provides exact pin (Section 26)
      expect(mockSearch.searchPlacesCallCount, equals(0));
    });

    test('Section 23: OG:URL has target pin', () async {
      final mockSearch = TrackingMockSearchService();
      final mockResolver = CountingMockRedirectResolver(
        resolverFullFn: (url) async {
          return (
            finalUrl: 'https://www.google.com/maps/place/Target/@21.03655,105.85165,17z',
            htmlBody: '''
              <!DOCTYPE html><html><head>
              <meta property="og:url" content="https://www.google.com/maps/place/Target/...!3d21.04567!4d105.84321">
              </head><body></body></html>
            ''',
          );
        },
      );

      final parser = GoogleMapsParser(
        searchService: mockSearch,
        redirectResolver: mockResolver,
      );

      final resolved = await parser.parseResolvedLink('https://maps.app.goo.gl/og_pin_test');

      expect(resolved.resolutionSource, equals('og_url'));
      expect(resolved.confidence, equals(GoogleMapsResolutionConfidence.exactPin));
      expect(resolved.exactDestinationCoordinate!.latitude, closeTo(21.04567, 0.00001));
      expect(resolved.exactDestinationCoordinate!.longitude, closeTo(105.84321, 0.00001));
      expect(mockSearch.searchPlacesCallCount, equals(0));
    });

    test('Section 24: Title-only link without exact pin requires confirmation and is NOT exactPin', () async {
      final mockSearch = TrackingMockSearchService();
      mockSearch.cannedResults = [
        MapPlace(
          name: 'Phố Nguyễn Siêu',
          displayName: 'Phố Nguyễn Siêu, Hàng Buồm, Hoàn Kiếm, Hà Nội',
          coordinate: const LatLng(21.03655, 105.85165),
          type: 'street',
          precision: PlacePrecision.street,
        ),
      ];

      final mockResolver = CountingMockRedirectResolver(
        resolverFullFn: (url) async {
          return (
            finalUrl: 'https://www.google.com/maps/place/Ph%E1%BB%91+Nguy%E1%BB%85n+Si%C3%AAu/@21.03655,105.85165,17z',
            htmlBody: '<title>Phố Nguyễn Siêu - Google Maps</title>',
          );
        },
      );

      final parser = GoogleMapsParser(
        searchService: mockSearch,
        redirectResolver: mockResolver,
      );

      final resolved = await parser.parseResolvedLink('https://maps.app.goo.gl/title_only');

      // Assert Authority 6: Independent search candidate
      expect(resolved.resolutionSource, equals('independent_search'));
      expect(resolved.confidence, equals(GoogleMapsResolutionConfidence.resolvedByIndependentSearch));
      expect(resolved.confidence, isNot(equals(GoogleMapsResolutionConfidence.exactPin)));
      expect(resolved.confidence, isNot(equals(GoogleMapsResolutionConfidence.exactDestination)));

      // Exact coordinate fields must be null (Section 15)
      expect(resolved.exactCoordinate, isNull);
      expect(resolved.exactDestinationCoordinate, isNull);
      expect(resolved.isExact, isFalse);

      // Candidate coordinate stored in independentSearchCandidateCoordinate
      expect(resolved.independentSearchCandidateCoordinate, isNotNull);
      expect(resolved.independentSearchCandidateCoordinate!.latitude, closeTo(21.03655, 0.0001));

      // targetCoordinate must NOT automatically return unverified candidate (Section 16)
      expect(resolved.targetCoordinate, isNull);

      // Must require user confirmation (Section 12 & 13)
      expect(resolved.requiresConfirmation, isTrue);
    });

    test('Section 25: Independent search candidate disagrees with camera -> requires confirmation', () async {
      final mockSearch = TrackingMockSearchService();
      mockSearch.cannedResults = [
        MapPlace(
          name: 'Nhà Hàng A',
          displayName: '123 Đường Cầu Giấy',
          coordinate: const LatLng(21.0300, 105.7900), // Disagrees with camera
        ),
      ];

      final mockResolver = CountingMockRedirectResolver(
        resolverFullFn: (url) async {
          return (
            finalUrl: 'https://www.google.com/maps/place/Nha+Hang+A/@21.03655,105.85165,17z',
            htmlBody: '',
          );
        },
      );

      final parser = GoogleMapsParser(
        searchService: mockSearch,
        redirectResolver: mockResolver,
      );

      final resolved = await parser.parseResolvedLink('https://maps.app.goo.gl/disagree');

      expect(resolved.requiresConfirmation, isTrue);
      expect(resolved.isExact, isFalse);
      expect(resolved.exactDestinationCoordinate, isNull);
      expect(resolved.cameraCoordinate, isNotNull);
      expect(resolved.cameraCoordinate!.latitude, closeTo(21.03655, 0.0001));
    });

    test('Section 27: Camera viewport link @lat,lon must NEVER become exact coordinate', () async {
      final parser = GoogleMapsParser(
        redirectResolver: CountingMockRedirectResolver(
          resolverFn: (_) async => 'https://www.google.com/maps/@21.03655,105.85165,17z',
        ),
      );

      final resolved = await parser.parseResolvedLink('https://maps.app.goo.gl/camera_only');

      expect(resolved.confidence, equals(GoogleMapsResolutionConfidence.approximate));
      expect(resolved.isExact, isFalse);
      expect(resolved.exactDestinationCoordinate, isNull);
      expect(resolved.cameraCoordinate, isNotNull);
      expect(resolved.targetCoordinate, isNull);
      expect(resolved.requiresConfirmation, isTrue);
      expect(resolved.resolutionSource, equals('camera_approximate'));
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
