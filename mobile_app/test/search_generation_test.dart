import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile_app/models/route_model.dart';
import 'package:mobile_app/services/google_maps_parser.dart';
import 'package:mobile_app/services/search_service.dart';

class DelayedMockResolver implements GoogleMapsRedirectResolver {
  final Duration delay;
  final String targetUrl;
  DelayedMockResolver(this.delay, this.targetUrl);

  @override
  Future<({String finalUrl, String htmlBody})> resolve(String url) async {
    await Future.delayed(delay);
    return (finalUrl: targetUrl, htmlBody: '');
  }
}

void main() {
  group('Search Generation & Race Safety Tests', () {
    test('Section 46 & 47: Calling cancelCurrentQuery or newer search increments generation', () {
      final searchService = SearchService();
      final initialGen = searchService.currentQueryGeneration;

      searchService.cancelCurrentQuery();
      expect(searchService.currentQueryGeneration, greaterThan(initialGen));

      searchService.cancelCurrentQuery();
      expect(searchService.currentQueryGeneration, greaterThan(initialGen + 1));
    });

    test('Section 48: Stale Google Maps link resolution does not overwrite newer link', () async {
      // Link A is slow (takes 200ms)
      // Link B is fast (takes 10ms)
      // Late resolution of Link A must return unresolved / be discarded

      final resolverA = DelayedMockResolver(
        const Duration(milliseconds: 150),
        'https://www.google.com/maps/place/PlaceA/data=!4m2!3m1!1s0x0:0x0!8m2!3d21.011111!4d105.811111',
      );

      final parser = GoogleMapsParser(redirectResolver: resolverA);

      // Start slow request A
      final futureA = parser.parseResolvedLink('https://maps.app.goo.gl/linkA');

      // Immediately start request B (direct coordinate, finishes immediately)
      final resB = await parser.parseResolvedLink('21.028511, 105.854212');
      expect(resB.confidence, GoogleMapsResolutionConfidence.exactPin);
      expect(resB.exactCoordinate!.latitude, closeTo(21.028511, 0.00001));

      // Wait for slow request A to complete
      final resA = await futureA;
      // Because link B bumped the generation, late request A must be marked unresolved
      expect(resA.confidence, GoogleMapsResolutionConfidence.unresolved);
    });
  });
}
