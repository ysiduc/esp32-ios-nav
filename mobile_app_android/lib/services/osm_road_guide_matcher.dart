import 'dart:math' as math;
import 'package:latlong2/latlong.dart';
import 'osm_vector_tile.dart';

class OsmGuideMatchResult {
  final List<LatLng> guidePolyline;
  final double? snappedHeadingDeg;
  final LatLng? snappedLocation;
  final bool matchedRoad;
  final bool usedIntersectionBranch;

  const OsmGuideMatchResult({
    this.guidePolyline = const <LatLng>[],
    this.snappedHeadingDeg,
    this.snappedLocation,
    this.matchedRoad = false,
    this.usedIntersectionBranch = false,
  });

  static const OsmGuideMatchResult empty = OsmGuideMatchResult();
}

class _WorldRoad {
  final int tier;
  final List<double> xy; // interleaved [wx0, wy0, wx1, wy1, ...] in displayZoom pixels relative to user
  final double minX;
  final double minY;
  final double maxX;
  final double maxY;

  const _WorldRoad({
    required this.tier,
    required this.xy,
    required this.minX,
    required this.minY,
    required this.maxX,
    required this.maxY,
  });

  int get vertexCount => xy.length >> 1;
  double xAt(int idx) => xy[idx << 1];
  double yAt(int idx) => xy[(idx << 1) + 1];
}

class _WorldLabel {
  final String normalized;
  final double wx;
  final double wy;

  const _WorldLabel({
    required this.normalized,
    required this.wx,
    required this.wy,
  });
}

class _TraceNode {
  final double wx;
  final double wy;
  final double cumM;
  final double bearingDeg;

  const _TraceNode({
    required this.wx,
    required this.wy,
    required this.cumM,
    required this.bearingDeg,
  });
}

class _RoadStartCandidate {
  final int roadIdx;
  final int segIdx;
  final bool forward;
  final double snapX;
  final double snapY;
  final double distM;
  final double brgDeg;
  final double score;

  const _RoadStartCandidate({
    required this.roadIdx,
    required this.segIdx,
    required this.forward,
    required this.snapX,
    required this.snapY,
    required this.distM,
    required this.brgDeg,
    required this.score,
  });
}

/// Snaps vehicle orientation onto nearby OpenStreetMap vector road centerlines
/// and traces turn-by-turn external guidance directly along real street geometry.
class OsmRoadGuideMatcher {
  @pragma('vm:prefer-inline')
  static double _hypot(double dx, double dy) => math.sqrt(dx * dx + dy * dy);

  static double absAngleDiffDeg(double a, double b) {
    final diff = ((a - b + 540.0) % 360.0) - 180.0;
    return diff.abs();
  }

  static double signedAngleDiffDeg(double target, double reference) {
    return ((target - reference + 540.0) % 360.0) - 180.0;
  }

  static double vectorBearingDeg(double dx, double dy) {
    return (math.atan2(dx, -dy) * (180.0 / math.pi) + 360.0) % 360.0;
  }

  static double lerpAngleDeg(
    double current,
    double target,
    double t, {
    double maxStepDeg = 6.0,
  }) {
    final diff = signedAngleDiffDeg(target, current);
    double step = diff * t;
    if (maxStepDeg > 0 && step.abs() > maxStepDeg) {
      step = step.isNegative ? -maxStepDeg : maxStepDeg;
    }
    return (current + step + 360.0) % 360.0;
  }

  static LatLng worldOffsetToLatLng(
    double wx,
    double wy, {
    required double userWorldX,
    required double userWorldY,
    required double totalWorldPx,
  }) {
    final gx = userWorldX + wx;
    final gy = userWorldY + wy;
    final lon = (gx / totalWorldPx) * 360.0 - 180.0;
    final mercY = math.pi * (1.0 - 2.0 * (gy / totalWorldPx));
    final sinhVal = (math.exp(mercY) - math.exp(-mercY)) * 0.5;
    final lat = math.atan(sinhVal) * (180.0 / math.pi);
    return LatLng(lat.clamp(-85.0511, 85.0511), lon);
  }

  static OsmGuideMatchResult matchAndTrace({
    required Iterable<OsmVectorTile> tiles,
    required LatLng userPos,
    required int displayZoom,
    required double rawHeadingDeg,
    required bool hasHeadingLock,
    required int turnCode,
    required double distanceToTurnMeters,
    String currentStreetName = '',
    String nextStreetName = '',
  }) {
    final double n = math.pow(2.0, displayZoom).toDouble();
    final double totalWorldPx = n * 256.0;
    final double latRad = userPos.latitude * (math.pi / 180.0);
    final double userWorldX = (userPos.longitude + 180.0) / 360.0 * totalWorldPx;
    final double userWorldY =
        (1.0 - (math.log(math.tan(latRad) + 1.0 / math.cos(latRad)) / math.pi)) /
            2.0 *
            totalWorldPx;

    final double metersPerPx =
        ((40075016.68557849 * math.cos(latRad).abs().clamp(0.15, 1.0)) / totalWorldPx)
            .clamp(0.05, 50.0);
    final double pxPerMeter = 1.0 / metersPerPx;
    final double cullRadiusPx = 360.0 * pxPerMeter;

    final roads = <_WorldRoad>[];
    final labels = <_WorldLabel>[];
    final seenLabelKeys = <String>{};

    for (final tile in tiles) {
      final double tileSizePx = 256.0 * math.pow(2.0, displayZoom - tile.z).toDouble();
      final double ox = tile.x * tileSizePx - userWorldX;
      final double oy = tile.y * tileSizePx - userWorldY;

      for (final r in tile.roads) {
        if (r.tier < 0 || r.pts.length < 4) continue;
        final double rMinX = ox + r.minX * tileSizePx;
        final double rMaxX = ox + r.maxX * tileSizePx;
        final double rMinY = oy + r.minY * tileSizePx;
        final double rMaxY = oy + r.maxY * tileSizePx;
        if (rMaxX < -cullRadiusPx ||
            rMinX > cullRadiusPx ||
            rMaxY < -cullRadiusPx ||
            rMinY > cullRadiusPx) {
          continue;
        }
        final xy = List<double>.filled(r.pts.length, 0.0, growable: false);
        for (int i = 0; i < r.pts.length; i += 2) {
          xy[i] = ox + r.pts[i] * tileSizePx;
          xy[i + 1] = oy + r.pts[i + 1] * tileSizePx;
        }
        roads.add(
          _WorldRoad(
            tier: r.tier,
            xy: xy,
            minX: rMinX,
            minY: rMinY,
            maxX: rMaxX,
            maxY: rMaxY,
          ),
        );
      }

      for (final lbl in tile.roadLabels) {
        final norm = _normalizeStreetName(lbl.name);
        if (norm.isEmpty) continue;
        final double wx = ox + lbl.midX * tileSizePx;
        final double wy = oy + lbl.midY * tileSizePx;
        if (wx.abs() > cullRadiusPx || wy.abs() > cullRadiusPx) continue;
        final key = '$norm:${(wx / 20).round()}:${(wy / 20).round()}';
        if (seenLabelKeys.add(key)) {
          labels.add(_WorldLabel(normalized: norm, wx: wx, wy: wy));
        }
      }
    }

    if (roads.isEmpty) return OsmGuideMatchResult.empty;

    final String normCurStreet = _normalizeStreetName(currentStreetName);
    final String normNextStreet = _normalizeStreetName(nextStreetName);
    final double maxSnapPx = 28.0 * pxPerMeter;

    _RoadStartCandidate? bestStart;

    for (int ri = 0; ri < roads.length; ri++) {
      final road = roads[ri];
      if (road.maxX < -maxSnapPx ||
          road.minX > maxSnapPx ||
          road.maxY < -maxSnapPx ||
          road.minY > maxSnapPx) {
        continue;
      }
      final vc = road.vertexCount;
      for (int si = 0; si < vc - 1; si++) {
        final ax = road.xAt(si);
        final ay = road.yAt(si);
        final bx = road.xAt(si + 1);
        final by = road.yAt(si + 1);
        final dx = bx - ax;
        final dy = by - ay;
        final lenSq = dx * dx + dy * dy;
        if (lenSq < 0.25) continue;

        final t = (-(ax * dx + ay * dy) / lenSq).clamp(0.0, 1.0);
        final px = ax + dx * t;
        final py = ay + dy * t;
        final distM = _hypot(px, py) / pxPerMeter;
        if (distM > 28.0) continue;

        final brgFwd = vectorBearingDeg(dx, dy);
        final brgRev = (brgFwd + 180.0) % 360.0;
        final double streetBonus = _streetNameNearbyBonus(
          normCurStreet,
          px,
          py,
          labels,
          pxPerMeter,
        );
        final double tierBonus = road.tier.clamp(0, 5) * 1.1;

        for (final isFwd in const [true, false]) {
          final candBrg = isFwd ? brgFwd : brgRev;
          final angErr = absAngleDiffDeg(candBrg, rawHeadingDeg);
          double score = distM - tierBonus - streetBonus;
          if (hasHeadingLock) {
            score += angErr * 0.55 + (angErr > 58.0 ? 80.0 : 0.0);
          } else {
            score += angErr * 0.05;
          }

          final cand = _RoadStartCandidate(
            roadIdx: ri,
            segIdx: si,
            forward: isFwd,
            snapX: px,
            snapY: py,
            distM: distM,
            brgDeg: candBrg,
            score: score,
          );
          if (bestStart == null || cand.score < bestStart.score) {
            bestStart = cand;
          }
        }
      }
    }

    if (bestStart == null) return OsmGuideMatchResult.empty;

    // When stationary with no prior course lock, break 180-deg two-way tie by checking
    // which direction leads to the upcoming turn intersection matching turnCode/nextStreetName.
    _RoadStartCandidate chosenStart = bestStart;
    if (!hasHeadingLock &&
        _isTurnManeuver(turnCode) &&
        distanceToTurnMeters > 0 &&
        distanceToTurnMeters <= 245.0) {
      final oppositeStart = _RoadStartCandidate(
        roadIdx: bestStart.roadIdx,
        segIdx: bestStart.segIdx,
        forward: !bestStart.forward,
        snapX: bestStart.snapX,
        snapY: bestStart.snapY,
        distM: bestStart.distM,
        brgDeg: (bestStart.brgDeg + 180.0) % 360.0,
        score: bestStart.score,
      );
      final resA = _traceWithIntersection(
        roads: roads,
        labels: labels,
        start: bestStart,
        pxPerMeter: pxPerMeter,
        turnCode: turnCode,
        distanceToTurnMeters: distanceToTurnMeters,
        normNextStreet: normNextStreet,
      );
      final resB = _traceWithIntersection(
        roads: roads,
        labels: labels,
        start: oppositeStart,
        pxPerMeter: pxPerMeter,
        turnCode: turnCode,
        distanceToTurnMeters: distanceToTurnMeters,
        normNextStreet: normNextStreet,
      );
      if (resB.matchQuality > resA.matchQuality + 1.0) {
        chosenStart = oppositeStart;
      }
    }

    final traced = _traceWithIntersection(
      roads: roads,
      labels: labels,
      start: chosenStart,
      pxPerMeter: pxPerMeter,
      turnCode: turnCode,
      distanceToTurnMeters: distanceToTurnMeters,
      normNextStreet: normNextStreet,
    );

    if (traced.points.length < 2) {
      return OsmGuideMatchResult.empty;
    }

    final double lookaheadBrg = _lookaheadBearing(traced.backbone, 20.0);
    final guideLatLngs = traced.points
        .map(
          (p) => worldOffsetToLatLng(
            p.x,
            p.y,
            userWorldX: userWorldX,
            userWorldY: userWorldY,
            totalWorldPx: totalWorldPx,
          ),
        )
        .toList(growable: false);
    final snappedLatLng = worldOffsetToLatLng(
      chosenStart.snapX,
      chosenStart.snapY,
      userWorldX: userWorldX,
      userWorldY: userWorldY,
      totalWorldPx: totalWorldPx,
    );

    return OsmGuideMatchResult(
      guidePolyline: guideLatLngs,
      snappedHeadingDeg: lookaheadBrg,
      snappedLocation: snappedLatLng,
      matchedRoad: true,
      usedIntersectionBranch: traced.usedIntersectionBranch,
    );
  }

  static ({
    List<({double x, double y})> points,
    List<_TraceNode> backbone,
    bool usedIntersectionBranch,
    double matchQuality,
  }) _traceWithIntersection({
    required List<_WorldRoad> roads,
    required List<_WorldLabel> labels,
    required _RoadStartCandidate start,
    required double pxPerMeter,
    required int turnCode,
    required double distanceToTurnMeters,
    required String normNextStreet,
  }) {
    final bool hasNearbyTurn =
        _isTurnManeuver(turnCode) && distanceToTurnMeters > 0 && distanceToTurnMeters <= 245.0;
    final double targetApproachM =
        hasNearbyTurn ? math.min(255.0, distanceToTurnMeters + 35.0) : 210.0;

    final tracedBackbone = _traceRoadChain(
      roads: roads,
      roadIdx: start.roadIdx,
      segIdx: start.segIdx,
      forward: start.forward,
      startX: start.snapX,
      startY: start.snapY,
      startBearing: start.brgDeg,
      maxMeters: targetApproachM,
      pxPerMeter: pxPerMeter,
    );

    final backboneNodes = tracedBackbone.nodes;
    if (backboneNodes.length < 2) {
      return (
        points: const [],
        backbone: backboneNodes,
        usedIntersectionBranch: false,
        matchQuality: 0.0,
      );
    }

    if (!hasNearbyTurn) {
      return (
        points: backboneNodes.map((n) => (x: n.wx, y: n.wy)).toList(growable: false),
        backbone: backboneNodes,
        usedIntersectionBranch: false,
        matchQuality: 0.0,
      );
    }

    // Look for an intersecting road near distanceToTurnMeters matching the requested turn angle.
    final branch = _findBestIntersectionBranch(
      roads: roads,
      labels: labels,
      backbone: backboneNodes,
      usedRoadIndices: tracedBackbone.usedRoadIndices,
      targetDistM: distanceToTurnMeters,
      turnCode: turnCode,
      normNextStreet: normNextStreet,
      pxPerMeter: pxPerMeter,
    );

    if (branch != null) {
      final points = <({double x, double y})>[];
      for (int i = 0; i <= branch.backboneNodeIdx; i++) {
        points.add((x: backboneNodes[i].wx, y: backboneNodes[i].wy));
      }
      final lastPt = points.last;
      if (_hypot(lastPt.x - branch.junctionX, lastPt.y - branch.junctionY) > 1.2) {
        points.add((x: branch.junctionX, y: branch.junctionY));
      }
      final postTurnChain = _traceRoadChain(
        roads: roads,
        roadIdx: branch.roadIdx,
        segIdx: branch.segIdx,
        forward: branch.forward,
        startX: branch.junctionX,
        startY: branch.junctionY,
        startBearing: branch.branchBrgDeg,
        maxMeters: 68.0,
        pxPerMeter: pxPerMeter,
      );
      for (int i = 1; i < postTurnChain.nodes.length; i++) {
        points.add((x: postTurnChain.nodes[i].wx, y: postTurnChain.nodes[i].wy));
      }
      return (
        points: points,
        backbone: backboneNodes,
        usedIntersectionBranch: true,
        matchQuality: branch.qualityScore,
      );
    }

    // No cross-street polygon decoded near distanceToTurnMeters -> trim approach cleanly at
    // distanceToTurnMeters and append synthetic bend relative to the road's own real tangent.
    final double clampedTurnM = distanceToTurnMeters.clamp(12.0, 220.0);
    final trimmed = <({double x, double y})>[];
    _TraceNode prevNode = backboneNodes.first;
    trimmed.add((x: prevNode.wx, y: prevNode.wy));
    double endBrg = prevNode.bearingDeg;

    for (int i = 1; i < backboneNodes.length; i++) {
      final cur = backboneNodes[i];
      if (cur.cumM >= clampedTurnM) {
        final spanM = math.max(0.01, cur.cumM - prevNode.cumM);
        final ratio = ((clampedTurnM - prevNode.cumM) / spanM).clamp(0.0, 1.0);
        final tx = prevNode.wx + (cur.wx - prevNode.wx) * ratio;
        final ty = prevNode.wy + (cur.wy - prevNode.wy) * ratio;
        if (_hypot(tx - trimmed.last.x, ty - trimmed.last.y) > 0.5) {
          trimmed.add((x: tx, y: ty));
        }
        endBrg = cur.bearingDeg;
        break;
      }
      trimmed.add((x: cur.wx, y: cur.wy));
      prevNode = cur;
      endBrg = cur.bearingDeg;
    }

    final turnEnd = trimmed.last;
    final idealDelta = _turnSpec(turnCode).idealDelta;
    final double outBrgRad = (endBrg + idealDelta) * (math.pi / 180.0);
    final double legPx = 65.0 * pxPerMeter;
    trimmed.add((
      x: turnEnd.x + math.sin(outBrgRad) * legPx,
      y: turnEnd.y - math.cos(outBrgRad) * legPx,
    ));

    return (
      points: trimmed,
      backbone: backboneNodes,
      usedIntersectionBranch: false,
      matchQuality: 0.5,
    );
  }

  static ({List<_TraceNode> nodes, Set<int> usedRoadIndices}) _traceRoadChain({
    required List<_WorldRoad> roads,
    required int roadIdx,
    required int segIdx,
    required bool forward,
    required double startX,
    required double startY,
    required double startBearing,
    required double maxMeters,
    required double pxPerMeter,
  }) {
    final nodes = <_TraceNode>[
      _TraceNode(wx: startX, wy: startY, cumM: 0.0, bearingDeg: startBearing),
    ];
    final usedRoadIndices = <int>{roadIdx};

    int curRoadIdx = roadIdx;
    int curSegIdx = segIdx;
    bool curFwd = forward;
    double curX = startX;
    double curY = startY;
    double curBrg = startBearing;
    double cumM = 0.0;

    for (int hop = 0; hop < 8 && cumM < maxMeters; hop++) {
      final road = roads[curRoadIdx];
      final vc = road.vertexCount;
      int nextVertex = curFwd ? (curSegIdx + 1) : curSegIdx;

      while (nextVertex >= 0 && nextVertex < vc && cumM < maxMeters) {
        final nx = road.xAt(nextVertex);
        final ny = road.yAt(nextVertex);
        final segLenM = _hypot(nx - curX, ny - curY) / pxPerMeter;
        if (segLenM >= 0.4) {
          final segBrg = vectorBearingDeg(nx - curX, ny - curY);
          if (cumM + segLenM >= maxMeters) {
            final remainM = maxMeters - cumM;
            final ratio = (remainM / segLenM).clamp(0.0, 1.0);
            final fx = curX + (nx - curX) * ratio;
            final fy = curY + (ny - curY) * ratio;
            nodes.add(_TraceNode(wx: fx, wy: fy, cumM: maxMeters, bearingDeg: segBrg));
            cumM = maxMeters;
            curBrg = segBrg;
            break;
          }
          cumM += segLenM;
          nodes.add(_TraceNode(wx: nx, wy: ny, cumM: cumM, bearingDeg: segBrg));
          curX = nx;
          curY = ny;
          curBrg = segBrg;
        }
        nextVertex += curFwd ? 1 : -1;
      }

      if (cumM >= maxMeters) break;

      // Reached end of road piece (e.g., tile seam or split way) -> stitch to continuing road.
      final join = _findContinuationRoad(
        roads: roads,
        usedRoadIndices: usedRoadIndices,
        endX: curX,
        endY: curY,
        incomingBrg: curBrg,
        pxPerMeter: pxPerMeter,
      );
      if (join == null) break;
      usedRoadIndices.add(join.roadIdx);
      curRoadIdx = join.roadIdx;
      curSegIdx = join.segIdx;
      curFwd = join.forward;
    }

    return (nodes: nodes, usedRoadIndices: usedRoadIndices);
  }

  static ({int roadIdx, int segIdx, bool forward})? _findContinuationRoad({
    required List<_WorldRoad> roads,
    required Set<int> usedRoadIndices,
    required double endX,
    required double endY,
    required double incomingBrg,
    required double pxPerMeter,
  }) {
    final double maxJoinPx = 9.0 * pxPerMeter;
    double bestScore = double.infinity;
    ({int roadIdx, int segIdx, bool forward})? best;

    for (int ri = 0; ri < roads.length; ri++) {
      if (usedRoadIndices.contains(ri)) continue;
      final r = roads[ri];
      if (r.maxX < endX - maxJoinPx ||
          r.minX > endX + maxJoinPx ||
          r.maxY < endY - maxJoinPx ||
          r.minY > endY + maxJoinPx) {
        continue;
      }
      final vc = r.vertexCount;
      for (int vi = 0; vi < vc; vi++) {
        final vx = r.xAt(vi);
        final vy = r.yAt(vi);
        final dM = _hypot(vx - endX, vy - endY) / pxPerMeter;
        if (dM > 9.0) continue;

        if (vi + 1 < vc) {
          final outBrg = vectorBearingDeg(r.xAt(vi + 1) - vx, r.yAt(vi + 1) - vy);
          final angErr = absAngleDiffDeg(outBrg, incomingBrg);
          if (angErr <= 52.0) {
            final score = dM * 2.0 + angErr * 0.4;
            if (score < bestScore) {
              bestScore = score;
              best = (roadIdx: ri, segIdx: vi, forward: true);
            }
          }
        }
        if (vi - 1 >= 0) {
          final outBrg = vectorBearingDeg(r.xAt(vi - 1) - vx, r.yAt(vi - 1) - vy);
          final angErr = absAngleDiffDeg(outBrg, incomingBrg);
          if (angErr <= 52.0) {
            final score = dM * 2.0 + angErr * 0.4;
            if (score < bestScore) {
              bestScore = score;
              best = (roadIdx: ri, segIdx: vi - 1, forward: false);
            }
          }
        }
      }
    }
    return best;
  }

  static ({
    int backboneNodeIdx,
    double junctionX,
    double junctionY,
    int roadIdx,
    int segIdx,
    bool forward,
    double branchBrgDeg,
    double qualityScore,
  })? _findBestIntersectionBranch({
    required List<_WorldRoad> roads,
    required List<_WorldLabel> labels,
    required List<_TraceNode> backbone,
    required Set<int> usedRoadIndices,
    required double targetDistM,
    required int turnCode,
    required String normNextStreet,
    required double pxPerMeter,
  }) {
    final double searchMinM = math.max(5.0, targetDistM - 30.0);
    final double searchMaxM = targetDistM + 35.0;
    final double maxJunctionPx = 10.0 * pxPerMeter;
    final spec = _turnSpec(turnCode);

    double bestCost = double.infinity;
    double bestQuality = 0.0;
    int bestNodeIdx = -1;
    double bestJx = 0.0;
    double bestJy = 0.0;
    int bestRi = -1;
    int bestSi = -1;
    bool bestFwd = true;
    double bestBranchBrg = 0.0;

    for (int ni = 0; ni < backbone.length; ni++) {
      final node = backbone[ni];
      if (node.cumM < searchMinM || node.cumM > searchMaxM) continue;

      for (int ri = 0; ri < roads.length; ri++) {
        if (usedRoadIndices.contains(ri)) continue;
        final r = roads[ri];
        if (r.maxX < node.wx - maxJunctionPx ||
            r.minX > node.wx + maxJunctionPx ||
            r.maxY < node.wy - maxJunctionPx ||
            r.minY > node.wy + maxJunctionPx) {
          continue;
        }
        final vc = r.vertexCount;
        for (int si = 0; si < vc - 1; si++) {
          final ax = r.xAt(si);
          final ay = r.yAt(si);
          final bx = r.xAt(si + 1);
          final by = r.yAt(si + 1);
          final dx = bx - ax;
          final dy = by - ay;
          final lenSq = dx * dx + dy * dy;
          if (lenSq < 0.25) continue;

          final t = (((node.wx - ax) * dx + (node.wy - ay) * dy) / lenSq).clamp(0.0, 1.0);
          final jx = ax + dx * t;
          final jy = ay + dy * t;
          final jDistM = _hypot(jx - node.wx, jy - node.wy) / pxPerMeter;
          if (jDistM > 10.0) continue;

          for (final fwd in const [true, false]) {
            final branchBrg = _branchMeasureBearing(r, si, fwd, jx, jy, pxPerMeter);
            if (branchBrg == null) continue;
            final delta = signedAngleDiffDeg(branchBrg, node.bearingDeg);
            if (!_matchesTurnAngle(turnCode, delta, spec)) continue;

            final distErr = (node.cumM - targetDistM).abs();
            final angErr = turnCode == 5
                ? (180.0 - delta.abs())
                : absAngleDiffDeg(delta, spec.idealDelta);
            final streetMatchBonus = normNextStreet.isNotEmpty
                ? _streetNameNearbyBonus(
                    normNextStreet,
                    jx + math.sin(branchBrg * math.pi / 180.0) * 18.0 * pxPerMeter,
                    jy - math.cos(branchBrg * math.pi / 180.0) * 18.0 * pxPerMeter,
                    labels,
                    pxPerMeter,
                    weight: 42.0,
                  )
                : 0.0;

            final cost =
                jDistM * 1.4 + distErr * 0.75 + angErr * 0.55 - r.tier * 1.3 - streetMatchBonus;
            if (cost < bestCost) {
              bestCost = cost;
              bestQuality = 10.0 + streetMatchBonus - distErr * 0.1 - angErr * 0.05;
              bestNodeIdx = ni;
              bestJx = jx;
              bestJy = jy;
              bestRi = ri;
              bestSi = si;
              bestFwd = fwd;
              bestBranchBrg = branchBrg;
            }
          }
        }
      }
    }

    if (bestNodeIdx < 0) return null;
    return (
      backboneNodeIdx: bestNodeIdx,
      junctionX: bestJx,
      junctionY: bestJy,
      roadIdx: bestRi,
      segIdx: bestSi,
      forward: bestFwd,
      branchBrgDeg: bestBranchBrg,
      qualityScore: bestQuality,
    );
  }

  static double? _branchMeasureBearing(
    _WorldRoad road,
    int segIdx,
    bool forward,
    double startX,
    double startY,
    double pxPerMeter,
  ) {
    final vc = road.vertexCount;
    double cumM = 0.0;
    double curX = startX;
    double curY = startY;
    int idx = forward ? (segIdx + 1) : segIdx;

    while (idx >= 0 && idx < vc) {
      final nx = road.xAt(idx);
      final ny = road.yAt(idx);
      final dM = _hypot(nx - curX, ny - curY) / pxPerMeter;
      cumM += dM;
      curX = nx;
      curY = ny;
      if (cumM >= 18.0) break;
      idx += forward ? 1 : -1;
    }

    if (cumM < 8.0) return null;
    final totalPx = _hypot(curX - startX, curY - startY);
    if (totalPx < 1.5) return null;
    return vectorBearingDeg(curX - startX, curY - startY);
  }

  static double _lookaheadBearing(List<_TraceNode> nodes, double targetM) {
    if (nodes.length < 2) return 0.0;
    final origin = nodes.first;
    _TraceNode target = nodes.last;
    for (int i = 1; i < nodes.length; i++) {
      target = nodes[i];
      if (target.cumM >= targetM) break;
    }
    if (_hypot(target.wx - origin.wx, target.wy - origin.wy) < 1.0) {
      return origin.bearingDeg;
    }
    return vectorBearingDeg(target.wx - origin.wx, target.wy - origin.wy);
  }

  static bool _isTurnManeuver(int turnCode) =>
      turnCode >= 2 && turnCode <= 9;

  static ({double minDelta, double maxDelta, double idealDelta}) _turnSpec(int turnCode) {
    switch (turnCode) {
      case 2:
        return (minDelta: 30.0, maxDelta: 145.0, idealDelta: 90.0);
      case 3:
        return (minDelta: 12.0, maxDelta: 75.0, idealDelta: 40.0);
      case 4:
        return (minDelta: 95.0, maxDelta: 170.0, idealDelta: 135.0);
      case 5:
        return (minDelta: 130.0, maxDelta: 180.0, idealDelta: -175.0);
      case 6:
        return (minDelta: -145.0, maxDelta: -30.0, idealDelta: -90.0);
      case 7:
        return (minDelta: -75.0, maxDelta: -12.0, idealDelta: -40.0);
      case 8:
        return (minDelta: -170.0, maxDelta: -95.0, idealDelta: -135.0);
      case 9:
        return (minDelta: 15.0, maxDelta: 150.0, idealDelta: 55.0);
      default:
        return (minDelta: -35.0, maxDelta: 35.0, idealDelta: 0.0);
    }
  }

  static bool _matchesTurnAngle(
    int turnCode,
    double delta,
    ({double minDelta, double maxDelta, double idealDelta}) spec,
  ) {
    if (turnCode == 5) {
      return delta.abs() >= 130.0;
    }
    if (turnCode == 9) {
      return (delta >= 15.0 && delta <= 150.0) || (delta <= -15.0 && delta >= -85.0);
    }
    return delta >= spec.minDelta && delta <= spec.maxDelta;
  }

  static double _streetNameNearbyBonus(
    String normTarget,
    double wx,
    double wy,
    List<_WorldLabel> labels,
    double pxPerMeter, {
    double weight = 8.0,
  }) {
    if (normTarget.isEmpty || labels.isEmpty) return 0.0;
    final maxDistPx = 75.0 * pxPerMeter;
    for (final lbl in labels) {
      if ((lbl.wx - wx).abs() > maxDistPx || (lbl.wy - wy).abs() > maxDistPx) continue;
      if (Osm3dRenderer.streetNamesMatch(lbl.normalized, normTarget)) {
        return weight;
      }
    }
    return 0.0;
  }

  static String _normalizeStreetName(String raw) =>
      Osm3dRenderer.normalizeStreetNameForMatch(raw);
}
