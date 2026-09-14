import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile_app/services/google_maps_parser.dart';

void main() {
  test('User Google Maps Link Parsing', () async {
    final parser = GoogleMapsParser();
    final input = "https://maps.app.goo.gl/RDvVV9s3nxfB5TYu6?g_st=ic";

    final place = await parser.parseInput(input, userLocation: const LatLng(20.98, 105.83));
    expect(place, isNotNull);
    expect(place!.coordinate.latitude, closeTo(20.975, 0.01));
    expect(place.coordinate.longitude, closeTo(105.835, 0.01));
  });
}
