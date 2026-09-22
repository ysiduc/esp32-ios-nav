import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile_app/models/route_model.dart';
import 'package:mobile_app/services/route_geometry.dart';

void main() {
  group('RouteGeometry & RouteProjection Tests (P5.5 Sections 4 - 7, 14, 18)', () {
    test('Equirectangular distanceBetween & bearing calculations', () {
      // Hanoi coordinates
      const p1 = LatLng(21.0285, 105.8542);
      // ~111m north
      const p2 = LatLng(21.0295, 105.8542);

      final dist = RouteGeometry.distanceBetween(p1, p2);
      expect(dist, greaterThan(110.0));
      expect(dist, lessThan(112.0));

      final b = RouteGeometry.bearing(p1, p2);
      expect(b, closeTo(0.0, 1.0)); // Heading north is ~0°
    });

    test('Point-to-segment projection clamps and calculates lateral distance accurately', () {
      // Horizontal segment going east along equator/latitude
      const a = LatLng(21.0000, 105.8000);
      const b = LatLng(21.0000, 105.8100);
      final geom = RouteGeometry([a, b]);

      expect(geom.segmentCount, equals(1));
      final segLen = geom.totalDistanceMeters;
      expect(segLen, greaterThan(1000.0));

      // Point exactly halfway along segment, shifted slightly north (lateral offset)
      final midLon = (a.longitude + b.longitude) / 2.0;
      final testPoint = LatLng(21.0002, midLon); // ~22m north

      final proj = geom.projectOnSegment(point: testPoint, segmentIndex: 0);

      expect(proj.segmentIndex, equals(0));
      expect(proj.fractionOnSegment, closeTo(0.5, 0.05));
      expect(proj.lateralDistanceMeters, closeTo(22.2, 1.0));
      expect(proj.distanceAlongRouteMeters, closeTo(segLen * 0.5, 5.0));
      expect(proj.routeBearingDegrees, closeTo(90.0, 2.0)); // Going east = ~90°
    });

    test('Point projected before start and after end clamps fraction to 0.0 and 1.0', () {
      const a = LatLng(21.0000, 105.8000);
      const b = LatLng(21.0000, 105.8100);
      final geom = RouteGeometry([a, b]);

      // Point before start
      const beforePoint = LatLng(21.0000, 105.7990);
      final projBefore = geom.projectOnSegment(point: beforePoint, segmentIndex: 0);
      expect(projBefore.fractionOnSegment, equals(0.0));
      expect(projBefore.distanceAlongRouteMeters, equals(0.0));

      // Point after end
      const afterPoint = LatLng(21.0000, 105.8110);
      final projAfter = geom.projectOnSegment(point: afterPoint, segmentIndex: 0);
      expect(projAfter.fractionOnSegment, equals(1.0));
      expect(projAfter.distanceAlongRouteMeters, closeTo(geom.totalDistanceMeters, 0.01));
    });

    test('Nearest projection selects closest segment across multi-segment route', () {
      // 3 segments: (0,0) -> (0, 0.01) -> (0.01, 0.01) -> (0.01, 0.02)
      const p0 = LatLng(21.000, 105.800);
      const p1 = LatLng(21.000, 105.810);
      const p2 = LatLng(21.010, 105.810);
      const p3 = LatLng(21.010, 105.820);
      final geom = RouteGeometry([p0, p1, p2, p3]);

      expect(geom.segmentCount, equals(3));

      // Point near segment 1 (vertical segment going north)
      const target = LatLng(21.005, 105.8101);
      final nearest = geom.nearestProjection(target);

      expect(nearest, isNotNull);
      expect(nearest!.segmentIndex, equals(1));
      expect(nearest.lateralDistanceMeters, lessThan(20.0));
      expect(nearest.routeBearingDegrees, closeTo(0.0, 2.0));
    });

    test('coordinateAtDistance interpolates along route monotonically', () {
      const p0 = LatLng(21.000, 105.800);
      const p1 = LatLng(21.000, 105.810);
      final geom = RouteGeometry([p0, p1]);
      final total = geom.totalDistanceMeters;

      final startCoord = geom.coordinateAtDistance(0.0);
      expect(startCoord?.latitude, closeTo(p0.latitude, 1e-6));
      expect(startCoord?.longitude, closeTo(p0.longitude, 1e-6));

      final midCoord = geom.coordinateAtDistance(total * 0.5);
      expect(midCoord?.latitude, closeTo(p0.latitude, 1e-6));
      expect(midCoord?.longitude, closeTo((p0.longitude + p1.longitude) * 0.5, 1e-5));

      final endCoord = geom.coordinateAtDistance(total);
      expect(endCoord?.latitude, closeTo(p1.latitude, 1e-6));
      expect(endCoord?.longitude, closeTo(p1.longitude, 1e-6));
    });

    test('trimmedPolyline strips passed vertices and begins at progressMeters', () {
      // 4 points along a straight road: 0m, ~1000m, ~2000m, ~3000m
      const p0 = LatLng(21.000, 105.800);
      const p1 = LatLng(21.000, 105.810);
      const p2 = LatLng(21.000, 105.820);
      const p3 = LatLng(21.000, 105.830);
      final geom = RouteGeometry([p0, p1, p2, p3]);

      // Progress at 0m: polyline has 4 points starting at p0
      final poly0 = geom.trimmedPolyline(0.0);
      expect(poly0.length, equals(4));
      expect(poly0.first.longitude, closeTo(p0.longitude, 1e-5));

      // Advance to 1500m (between p1 and p2)
      final seg1Dist = geom.cumulativeDistances[1];
      final seg2Dist = geom.cumulativeDistances[2];
      final targetProgress = (seg1Dist + seg2Dist) / 2.0;

      final polyTrimmed = geom.trimmedPolyline(targetProgress);

      // p0 and p1 should be removed!
      // First point must be the exact interpolated coordinate at targetProgress
      expect(polyTrimmed.length, equals(3)); // [interpolatedCoord, p2, p3]
      expect(polyTrimmed.first.longitude, closeTo((p1.longitude + p2.longitude) / 2.0, 1e-5));
      expect(polyTrimmed[1], equals(p2));
      expect(polyTrimmed[2], equals(p3));
    });

    test('maneuverBeginDistancesAlongRoute precomputes step boundaries monotonically', () {
      const p0 = LatLng(21.000, 105.800);
      const p1 = LatLng(21.000, 105.810);
      const p2 = LatLng(21.000, 105.820);
      const p3 = LatLng(21.000, 105.830);

      final steps = [
        NavStep(
          stepIndex: 0,
          instruction: 'Depart',
          streetName: 'Street 1',
          distanceMeters: 1000,
          durationSeconds: 100,
          coordinate: p0,
          maneuverTypeStr: 'depart',
          beginShapeIndex: 0,
          endShapeIndex: 1,
        ),
        NavStep(
          stepIndex: 1,
          instruction: 'Turn right',
          streetName: 'Street 2',
          distanceMeters: 1000,
          durationSeconds: 100,
          coordinate: p1,
          maneuverTypeStr: 'turn right',
          beginShapeIndex: 1,
          endShapeIndex: 2,
        ),
        NavStep(
          stepIndex: 2,
          instruction: 'Arrive',
          streetName: 'Destination',
          distanceMeters: 1000,
          durationSeconds: 100,
          coordinate: p3,
          maneuverTypeStr: 'arrive',
          beginShapeIndex: 2,
          endShapeIndex: 3,
        ),
      ];

      final geom = RouteGeometry([p0, p1, p2, p3], steps: steps);

      expect(geom.maneuverBeginDistancesAlongRoute.length, equals(3));
      expect(geom.maneuverBeginDistancesAlongRoute[0], equals(0.0));
      expect(geom.maneuverBeginDistancesAlongRoute[1], closeTo(geom.cumulativeDistances[1], 1e-3));
      expect(geom.maneuverBeginDistancesAlongRoute[2], closeTo(geom.cumulativeDistances[2], 1e-3));
      expect(geom.maneuverEndDistancesAlongRoute[2], closeTo(geom.totalDistanceMeters, 1e-3));
    });
    test('matchLocation bounds candidate forward window, ignoring distant loops/overpasses', () {
      // Loop route:
      // p0 -> p1 (East 1000m)
      // p1 -> p2 (North 1000m)
      // p2 -> p3 (West 1000m)
      // p3 -> p4 (South 1000m, passing 10m north of p0, total length ~4000m)
      const p0 = LatLng(21.0000, 105.8000);
      const p1 = LatLng(21.0000, 105.8100);
      const p2 = LatLng(21.0100, 105.8100);
      const p3 = LatLng(21.0100, 105.8000);
      const p4 = LatLng(21.0001, 105.8000); // 11m north of p0

      final geom = RouteGeometry([p0, p1, p2, p3, p4]);
      expect(geom.totalDistanceMeters, greaterThan(3000.0));

      // Vehicle is at start (p0)
      final initialProj = geom.projectOnSegment(point: p0, segmentIndex: 0);
      expect(initialProj.distanceAlongRouteMeters, equals(0.0));

      // GPS sample at (21.0001, 105.8005): 11m north of p0.
      // This point is right next to the final loop segment (segment 3: p3 -> p4),
      // but 11m away from segment 0 (p0 -> p1).
      const sample = LatLng(21.0001, 105.8005);

      // matchLocation with continuity from initialProj must stay on segment 0
      final matched = geom.matchLocation(
        sample,
        lastProjection: initialProj,
        searchForwardMeters: 150.0,
      );

      expect(matched, isNotNull);
      expect(matched!.segmentIndex, equals(0), reason: 'Must NOT jump 3000m ahead to distant loop segment');
      expect(matched.distanceAlongRouteMeters, lessThan(150.0));
    });
  });
}
