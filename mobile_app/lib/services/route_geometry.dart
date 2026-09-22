import 'dart:math' as math;
import 'package:latlong2/latlong.dart';
import '../models/route_model.dart';

/// Projection of a location coordinate onto a specific route polyline segment.
class RouteProjection {
  final LatLng coordinate;
  final int segmentIndex;
  final double fractionOnSegment;
  final double lateralDistanceMeters;
  final double distanceAlongRouteMeters;
  final double routeBearingDegrees;

  const RouteProjection({
    required this.coordinate,
    required this.segmentIndex,
    required this.fractionOnSegment,
    required this.lateralDistanceMeters,
    required this.distanceAlongRouteMeters,
    required this.routeBearingDegrees,
  });

  @override
  String toString() =>
      'RouteProjection(seg: $segmentIndex, frac: ${fractionOnSegment.toStringAsFixed(2)}, '
      'lateral: ${lateralDistanceMeters.toStringAsFixed(1)}m, '
      'along: ${distanceAlongRouteMeters.toStringAsFixed(1)}m, '
      'bearing: ${routeBearingDegrees.toStringAsFixed(1)}°)';
}

/// Precomputed route polyline geometry, cumulative distances along the route,
/// point-to-segment projection, and monotonic trimming.
class RouteGeometry {
  final List<LatLng> coordinates;
  final List<double> cumulativeDistances;
  final double totalDistanceMeters;
  final List<double> maneuverBeginDistancesAlongRoute;
  final List<double> maneuverEndDistancesAlongRoute;

  int get segmentCount => coordinates.length > 1 ? coordinates.length - 1 : 0;

  RouteGeometry(
    List<LatLng> coords, {
    List<NavStep> steps = const [],
  })  : coordinates = List.unmodifiable(coords),
        cumulativeDistances = _precomputeCumulativeDistances(coords),
        totalDistanceMeters = _computeTotalDistance(coords),
        maneuverBeginDistancesAlongRoute = _precomputeManeuverBeginDistances(coords, steps),
        maneuverEndDistancesAlongRoute = _precomputeManeuverEndDistances(coords, steps);

  static List<double> _precomputeCumulativeDistances(List<LatLng> coords) {
    if (coords.isEmpty) return const [];
    final list = <double>[0.0];
    double total = 0.0;
    for (int i = 0; i < coords.length - 1; i++) {
      total += distanceBetween(coords[i], coords[i + 1]);
      list.add(total);
    }
    return List.unmodifiable(list);
  }

  static double _computeTotalDistance(List<LatLng> coords) {
    if (coords.length < 2) return 0.0;
    double total = 0.0;
    for (int i = 0; i < coords.length - 1; i++) {
      total += distanceBetween(coords[i], coords[i + 1]);
    }
    return total;
  }

  static List<double> _precomputeManeuverBeginDistances(List<LatLng> coords, List<NavStep> steps) {
    if (steps.isEmpty || coords.isEmpty) return const [];
    final cumDist = _precomputeCumulativeDistances(coords);
    final beginDists = <double>[];
    double lastBegin = 0.0;

    for (int i = 0; i < steps.length; i++) {
      final step = steps[i];
      double dist = 0.0;

      if (step.beginDistanceAlongRoute != null && step.beginDistanceAlongRoute! >= 0.0) {
        dist = step.beginDistanceAlongRoute!;
      } else if (step.beginShapeIndex != null &&
          step.beginShapeIndex! >= 0 &&
          step.beginShapeIndex! < cumDist.length) {
        dist = cumDist[step.beginShapeIndex!];
      } else if (i == 0) {
        dist = 0.0;
      } else {
        // Find closest coordinate along route
        double bestDist = double.infinity;
        double bestAlong = lastBegin;
        for (int cIdx = 0; cIdx < coords.length; cIdx++) {
          final d = distanceBetween(step.coordinate, coords[cIdx]);
          if (d < bestDist) {
            bestDist = d;
            bestAlong = cumDist[cIdx];
          }
        }
        dist = bestAlong;
      }

      // Guarantee monotonic step ordering
      dist = math.max(lastBegin, dist);
      beginDists.add(dist);
      lastBegin = dist;
    }
    return List.unmodifiable(beginDists);
  }

  static List<double> _precomputeManeuverEndDistances(List<LatLng> coords, List<NavStep> steps) {
    if (steps.isEmpty || coords.isEmpty) return const [];
    final cumDist = _precomputeCumulativeDistances(coords);
    final total = cumDist.isNotEmpty ? cumDist.last : 0.0;
    final endDists = <double>[];
    double lastEnd = 0.0;

    for (int i = 0; i < steps.length; i++) {
      final step = steps[i];
      double dist = 0.0;

      if (step.endShapeIndex != null &&
          step.endShapeIndex! >= 0 &&
          step.endShapeIndex! < cumDist.length) {
        dist = cumDist[step.endShapeIndex!];
      } else if (i == steps.length - 1) {
        dist = total;
      } else {
        double bestDist = double.infinity;
        double bestAlong = lastEnd;
        for (int cIdx = 0; cIdx < coords.length; cIdx++) {
          final d = distanceBetween(step.coordinate, coords[cIdx]);
          if (d < bestDist) {
            bestDist = d;
            bestAlong = cumDist[cIdx];
          }
        }
        dist = bestAlong;
      }

      dist = math.max(lastEnd, dist);
      endDists.add(dist);
      lastEnd = dist;
    }
    return List.unmodifiable(endDists);
  }

  /// Geodesic distance in meters using equirectangular projection.
  static double distanceBetween(LatLng a, LatLng b) {
    final midLat = (a.latitude + b.latitude) * 0.5 * (math.pi / 180.0);
    const mLat = 111319.9;
    final mLon = 111319.9 * math.cos(midLat);

    final dx = (b.longitude - a.longitude) * mLon;
    final dy = (b.latitude - a.latitude) * mLat;
    return math.sqrt(dx * dx + dy * dy);
  }

  /// Bearing in degrees [0, 360) from coordinate a to b.
  static double bearing(LatLng a, LatLng b) {
    final lat1 = a.latitude * math.pi / 180.0;
    final lat2 = b.latitude * math.pi / 180.0;
    final dLon = (b.longitude - a.longitude) * math.pi / 180.0;

    final y = math.sin(dLon) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
    final radians = math.atan2(y, x);
    final degrees = radians * 180.0 / math.pi;
    return (degrees + 360.0) % 360.0;
  }

  /// Project a point onto a specific segment [segmentIndex, segmentIndex + 1].
  RouteProjection projectOnSegment({
    required LatLng point,
    required int segmentIndex,
  }) {
    if (segmentIndex < 0 || segmentIndex >= segmentCount) {
      final fallback = coordinates.isNotEmpty ? coordinates.first : point;
      return RouteProjection(
        coordinate: fallback,
        segmentIndex: 0,
        fractionOnSegment: 0.0,
        lateralDistanceMeters: distanceBetween(point, fallback),
        distanceAlongRouteMeters: 0.0,
        routeBearingDegrees: 0.0,
      );
    }

    final a = coordinates[segmentIndex];
    final b = coordinates[segmentIndex + 1];

    final midLat = (a.latitude + b.latitude) * 0.5 * (math.pi / 180.0);
    const mLat = 111319.9;
    final mLon = 111319.9 * math.cos(midLat);

    final vx = (b.longitude - a.longitude) * mLon;
    final vy = (b.latitude - a.latitude) * mLat;
    final ux = (point.longitude - a.longitude) * mLon;
    final uy = (point.latitude - a.latitude) * mLat;

    final len2 = vx * vx + vy * vy;
    final double t;
    if (len2 > 1e-10) {
      t = ((ux * vx + uy * vy) / len2).clamp(0.0, 1.0);
    } else {
      t = 0.0;
    }

    final projLat = a.latitude + (t * vy) / mLat;
    final projLon = a.longitude + (t * vx) / mLon;
    final projCoord = LatLng(projLat, projLon);

    final dx = (point.longitude - projLon) * mLon;
    final dy = (point.latitude - projLat) * mLat;
    final lateralDist = math.sqrt(dx * dx + dy * dy);

    final segLen = math.sqrt(len2);
    final distAlong = cumulativeDistances[segmentIndex] + t * segLen;
    final segBearing = bearing(a, b);

    return RouteProjection(
      coordinate: projCoord,
      segmentIndex: segmentIndex,
      fractionOnSegment: t,
      lateralDistanceMeters: lateralDist,
      distanceAlongRouteMeters: distAlong,
      routeBearingDegrees: segBearing,
    );
  }

  /// Pure Euclidean nearest projection to the entire route geometry.
  /// Does NOT apply previous-projection continuity bias.
  /// Used for physical off-route evidence and physical distance computation.
  RouteProjection? nearestProjection(LatLng coordinate) {
    if (segmentCount == 0) {
      if (coordinates.isNotEmpty) {
        return RouteProjection(
          coordinate: coordinates.first,
          segmentIndex: 0,
          fractionOnSegment: 0.0,
          lateralDistanceMeters: distanceBetween(coordinate, coordinates.first),
          distanceAlongRouteMeters: 0.0,
          routeBearingDegrees: 0.0,
        );
      }
      return null;
    }

    RouteProjection? bestProj;
    double bestDist = double.infinity;

    for (int segIdx = 0; segIdx < segmentCount; segIdx++) {
      final proj = projectOnSegment(point: coordinate, segmentIndex: segIdx);
      if (proj.lateralDistanceMeters < bestDist) {
        bestDist = proj.lateralDistanceMeters;
        bestProj = proj;
      }
    }

    return bestProj;
  }

  /// Matches a GPS location onto this route geometry using continuity search.
  /// When lastProjection is available, searches a window ahead of current progress.
  RouteProjection? matchLocation(
    LatLng location, {
    RouteProjection? lastProjection,
    double searchForwardMeters = 150.0,
    bool stuckRecovery = false,
  }) {
    if (segmentCount == 0) {
      return nearestProjection(location);
    }

    if (lastProjection == null || stuckRecovery) {
      return nearestProjection(location);
    }

    // Local window search: look from (lastSegmentIndex - 1) up to searchForwardMeters ahead
    final startSeg = math.max(0, lastProjection.segmentIndex - 1);
    final currentDistAlong = lastProjection.distanceAlongRouteMeters;
    final maxDistAlong = currentDistAlong + searchForwardMeters;

    RouteProjection? bestLocalProj;
    double bestLocalDist = double.infinity;

    for (int segIdx = startSeg; segIdx < segmentCount; segIdx++) {
      if (cumulativeDistances[segIdx] > maxDistAlong && segIdx > startSeg + 1) {
        break;
      }
      final proj = projectOnSegment(point: location, segmentIndex: segIdx);
      if (proj.lateralDistanceMeters < bestLocalDist) {
        bestLocalDist = proj.lateralDistanceMeters;
        bestLocalProj = proj;
      }
    }

    final globalNearest = nearestProjection(location);
    if (globalNearest == null) return bestLocalProj;
    if (bestLocalProj == null) return globalNearest;

    // If global nearest is substantially better than local (e.g., jump over sharp turn or detour),
    // and global is not backwards by more than 30m:
    final globalDeltaAlong = globalNearest.distanceAlongRouteMeters - currentDistAlong;
    if (globalNearest.lateralDistanceMeters < bestLocalProj.lateralDistanceMeters * 0.5 &&
        globalDeltaAlong > -30.0) {
      return globalNearest;
    }

    return bestLocalProj;
  }

  /// Exact coordinate along the route at the given along-route distance.
  LatLng? coordinateAtDistance(double meters) {
    if (coordinates.isEmpty) return null;
    if (coordinates.length == 1) return coordinates.first;
    final targetDist = meters.clamp(0.0, totalDistanceMeters);

    int segIdx = 0;
    while (segIdx + 1 < cumulativeDistances.length && cumulativeDistances[segIdx + 1] < targetDist) {
      segIdx++;
    }
    segIdx = math.min(segIdx, segmentCount - 1);

    final a = coordinates[segIdx];
    final b = coordinates[segIdx + 1];
    final segStartDist = cumulativeDistances[segIdx];
    final segLen = cumulativeDistances[segIdx + 1] - segStartDist;
    final fraction = segLen > 1e-6 ? ((targetDist - segStartDist) / segLen).clamp(0.0, 1.0) : 0.0;

    final lat = a.latitude + fraction * (b.latitude - a.latitude);
    final lon = a.longitude + fraction * (b.longitude - a.longitude);
    return LatLng(lat, lon);
  }

  /// Returns the remaining polyline coordinates starting from the specified along-route distance.
  /// Passed geometry is promptly removed without requiring reroute.
  /// The first coordinate corresponds to distanceAlongRouteMeters.
  List<LatLng> trimmedPolyline(
    double progressMeters, {
    LatLng? snappedCoordinate,
  }) {
    if (coordinates.length < 2) return coordinates;
    final targetDist = progressMeters.clamp(0.0, totalDistanceMeters);

    final startCoord = snappedCoordinate ?? coordinateAtDistance(targetDist) ?? coordinates.first;

    int segIdx = 0;
    while (segIdx + 1 < cumulativeDistances.length && cumulativeDistances[segIdx + 1] < targetDist) {
      segIdx++;
    }
    segIdx = math.min(segIdx, segmentCount - 1);

    final remaining = <LatLng>[startCoord];
    if (segIdx + 1 < coordinates.length) {
      remaining.addAll(coordinates.sublist(segIdx + 1));
    }
    return remaining;
  }
}
