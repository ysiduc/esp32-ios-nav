import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

enum ManeuverType {
  straight,
  slightRight,
  turnRight,
  sharpRight,
  uTurn,
  sharpLeft,
  turnLeft,
  slightLeft,
  roundabout,
  arrive,
  depart,
  fork,
  merge,
  offRamp,
  onRamp,
  unknown
}

class NavStep {
  final int stepIndex;
  final String instruction;
  final String streetName;
  final double distanceMeters;
  final double durationSeconds;
  final LatLng coordinate;
  final String maneuverTypeStr;
  final String? maneuverModifier;

  NavStep({
    required this.stepIndex,
    required this.instruction,
    required this.streetName,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.coordinate,
    required this.maneuverTypeStr,
    this.maneuverModifier,
  });

  /// Convert OSRM maneuver type & modifier to ManeuverType enum
  ManeuverType get maneuverType {
    if (maneuverTypeStr == 'arrive') return ManeuverType.arrive;
    if (maneuverTypeStr == 'depart') return ManeuverType.depart;
    if (maneuverTypeStr == 'roundabout' || maneuverTypeStr == 'rotary') {
      return ManeuverType.roundabout;
    }

    final mod = maneuverModifier?.toLowerCase() ?? '';
    if (mod.contains('sharp right')) return ManeuverType.sharpRight;
    if (mod.contains('slight right')) return ManeuverType.slightRight;
    if (mod.contains('right')) return ManeuverType.turnRight;
    if (mod.contains('sharp left')) return ManeuverType.sharpLeft;
    if (mod.contains('slight left')) return ManeuverType.slightLeft;
    if (mod.contains('left')) return ManeuverType.turnLeft;
    if (mod.contains('uturn') || mod.contains('u-turn')) return ManeuverType.uTurn;
    if (mod.contains('straight')) return ManeuverType.straight;

    if (maneuverTypeStr == 'fork') return ManeuverType.fork;
    if (maneuverTypeStr == 'merge') return ManeuverType.merge;
    if (maneuverTypeStr == 'off ramp') return ManeuverType.offRamp;
    if (maneuverTypeStr == 'on ramp') return ManeuverType.onRamp;

    return ManeuverType.straight;
  }

  /// Turn code mapping sent to ESP32:
  /// 0: Straight, 1: Slight Right, 2: Turn Right, 3: Sharp Right,
  /// 4: U-Turn, 5: Sharp Left, 6: Turn Left, 7: Slight Left,
  /// 8: Roundabout, 9: Arrive/Destination, 10: Depart/Start
  int get turnCode {
    switch (maneuverType) {
      case ManeuverType.straight:
        return 0;
      case ManeuverType.slightRight:
        return 1;
      case ManeuverType.turnRight:
        return 2;
      case ManeuverType.sharpRight:
        return 3;
      case ManeuverType.uTurn:
        return 4;
      case ManeuverType.sharpLeft:
        return 5;
      case ManeuverType.turnLeft:
        return 6;
      case ManeuverType.slightLeft:
        return 7;
      case ManeuverType.roundabout:
        return 8;
      case ManeuverType.arrive:
        return 9;
      case ManeuverType.depart:
        return 10;
      case ManeuverType.fork:
        return (maneuverModifier?.contains('left') ?? false) ? 7 : 1;
      case ManeuverType.merge:
      case ManeuverType.offRamp:
      case ManeuverType.onRamp:
      case ManeuverType.unknown:
        return 0;
    }
  }

  IconData get icon {
    switch (maneuverType) {
      case ManeuverType.straight:
        return Icons.arrow_upward_rounded;
      case ManeuverType.slightRight:
        return Icons.turn_slight_right_rounded;
      case ManeuverType.turnRight:
        return Icons.turn_right_rounded;
      case ManeuverType.sharpRight:
        return Icons.turn_sharp_right_rounded;
      case ManeuverType.uTurn:
        return Icons.u_turn_left_rounded;
      case ManeuverType.sharpLeft:
        return Icons.turn_sharp_left_rounded;
      case ManeuverType.turnLeft:
        return Icons.turn_left_rounded;
      case ManeuverType.slightLeft:
        return Icons.turn_slight_left_rounded;
      case ManeuverType.roundabout:
        return Icons.roundabout_right_rounded;
      case ManeuverType.arrive:
        return Icons.flag_rounded;
      case ManeuverType.depart:
        return Icons.navigation_rounded;
      default:
        return Icons.arrow_upward_rounded;
    }
  }
}

class NavRoute {
  final double totalDistanceMeters;
  final double totalDurationSeconds;
  final List<LatLng> polylinePoints;
  final List<NavStep> steps;
  final String summary;

  NavRoute({
    required this.totalDistanceMeters,
    required this.totalDurationSeconds,
    required this.polylinePoints,
    required this.steps,
    required this.summary,
  });

  String get formattedDistance {
    if (totalDistanceMeters >= 1000) {
      return '${(totalDistanceMeters / 1000).toStringAsFixed(1)} km';
    }
    return '${totalDistanceMeters.round()} m';
  }

  String get formattedDuration {
    final minutes = (totalDurationSeconds / 60).round();
    if (minutes >= 60) {
      final hours = minutes ~/ 60;
      final remainingMins = minutes % 60;
      return '$hours giờ $remainingMins phút';
    }
    return '$minutes phút';
  }
}

class MapPlace {
  final String displayName;
  final String name;
  final LatLng coordinate;
  final String? type;

  MapPlace({
    required this.displayName,
    required this.name,
    required this.coordinate,
    this.type,
  });

  factory MapPlace.fromJson(Map<String, dynamic> json) {
    final lat = double.tryParse(json['lat']?.toString() ?? '0') ?? 0.0;
    final lon = double.tryParse(json['lon']?.toString() ?? '0') ?? 0.0;
    final displayName = json['display_name'] as String? ?? 'Địa điểm';
    final name = json['name'] as String? ?? displayName.split(',').first;

    return MapPlace(
      displayName: displayName,
      name: name,
      coordinate: LatLng(lat, lon),
      type: json['type'] as String?,
    );
  }
}
