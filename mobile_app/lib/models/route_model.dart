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

  /// Convert OSRM / Valhalla maneuver type & modifier to ManeuverType enum
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
  
  // Alternative route classification tags
  final String title;
  final String subtitle;
  final bool isFastest;
  final bool isShortest;
  final bool isTollFree;
  final Color themeColor;
  final int durationDiffMinutes;
  final double distanceDiffKm;

  NavRoute({
    required this.totalDistanceMeters,
    required this.totalDurationSeconds,
    required this.polylinePoints,
    required this.steps,
    required this.summary,
    this.title = 'Lộ trình đề xuất',
    this.subtitle = 'Lộ trình tối ưu',
    this.isFastest = false,
    this.isShortest = false,
    this.isTollFree = true,
    this.themeColor = const Color(0xFF00F0FF),
    this.durationDiffMinutes = 0,
    this.distanceDiffKm = 0.0,
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
      if (remainingMins == 0) return '$hours giờ';
      return '$hours giờ $remainingMins phút';
    }
    return '$minutes phút';
  }

  String get formattedDiffTag {
    if (durationDiffMinutes == 0 && distanceDiffKm == 0) {
      return isFastest ? '⚡ Nhanh nhất' : (isShortest ? '📏 Ngắn nhất' : '⭐ Tốt nhất');
    }
    final parts = <String>[];
    if (durationDiffMinutes > 0) {
      parts.add('+$durationDiffMinutes phút');
    } else if (durationDiffMinutes < 0) {
      parts.add('${durationDiffMinutes.abs()} phút nhanh hơn');
    }

    if (distanceDiffKm > 0) {
      parts.add('+${distanceDiffKm.toStringAsFixed(1)} km');
    } else if (distanceDiffKm < 0) {
      parts.add('-${distanceDiffKm.abs().toStringAsFixed(1)} km');
    }
    return parts.join(' • ');
  }

  NavRoute copyWith({
    double? totalDistanceMeters,
    double? totalDurationSeconds,
    List<LatLng>? polylinePoints,
    List<NavStep>? steps,
    String? summary,
    String? title,
    String? subtitle,
    bool? isFastest,
    bool? isShortest,
    bool? isTollFree,
    Color? themeColor,
    int? durationDiffMinutes,
    double? distanceDiffKm,
  }) {
    return NavRoute(
      totalDistanceMeters: totalDistanceMeters ?? this.totalDistanceMeters,
      totalDurationSeconds: totalDurationSeconds ?? this.totalDurationSeconds,
      polylinePoints: polylinePoints ?? this.polylinePoints,
      steps: steps ?? this.steps,
      summary: summary ?? this.summary,
      title: title ?? this.title,
      subtitle: subtitle ?? this.subtitle,
      isFastest: isFastest ?? this.isFastest,
      isShortest: isShortest ?? this.isShortest,
      isTollFree: isTollFree ?? this.isTollFree,
      themeColor: themeColor ?? this.themeColor,
      durationDiffMinutes: durationDiffMinutes ?? this.durationDiffMinutes,
      distanceDiffKm: distanceDiffKm ?? this.distanceDiffKm,
    );
  }
}

class MapPlace {
  final String displayName;
  final String name;
  final LatLng coordinate;
  final String? type;
  final String? category;
  final double? distanceMeters;

  MapPlace({
    required this.displayName,
    required this.name,
    required this.coordinate,
    this.type,
    this.category,
    this.distanceMeters,
  });

  factory MapPlace.fromJson(Map<String, dynamic> json, {LatLng? userLocation}) {
    final lat = double.tryParse(json['lat']?.toString() ?? '0') ?? 0.0;
    final lon = double.tryParse(json['lon']?.toString() ?? '0') ?? 0.0;
    final displayName = json['display_name'] as String? ?? 'Địa điểm';
    final name = json['name'] as String? ?? displayName.split(',').first;
    final coord = LatLng(lat, lon);

    double? dist;
    if (userLocation != null) {
      const distanceCalculator = Distance();
      dist = distanceCalculator.as(LengthUnit.Meter, userLocation, coord);
    }

    return MapPlace(
      displayName: displayName,
      name: name,
      coordinate: coord,
      type: json['type'] as String?,
      category: json['class'] as String? ?? json['category'] as String?,
      distanceMeters: dist,
    );
  }

  String get formattedDistance {
    if (distanceMeters == null) return '';
    if (distanceMeters! >= 1000) {
      return '${(distanceMeters! / 1000).toStringAsFixed(1)} km';
    }
    return '${distanceMeters!.round()} m';
  }

  String get shortSubtitle {
    final parts = displayName.split(',');
    if (parts.length > 1) {
      return parts.sublist(1).take(3).map((e) => e.trim()).join(', ');
    }
    return displayName;
  }

  IconData get categoryIcon {
    final t = (type ?? category ?? '').toLowerCase();
    if (t.contains('fuel') || t.contains('gas') || t.contains('petrol')) {
      return Icons.local_gas_station_rounded;
    }
    if (t.contains('restaurant') || t.contains('food') || t.contains('cafe') || t.contains('fast_food')) {
      return Icons.restaurant_rounded;
    }
    if (t.contains('hospital') || t.contains('clinic') || t.contains('pharmacy') || t.contains('doctors')) {
      return Icons.local_hospital_rounded;
    }
    if (t.contains('parking')) {
      return Icons.local_parking_rounded;
    }
    if (t.contains('supermarket') || t.contains('convenience') || t.contains('mall') || t.contains('shop')) {
      return Icons.shopping_cart_rounded;
    }
    if (t.contains('hotel') || t.contains('motel') || t.contains('lodging')) {
      return Icons.hotel_rounded;
    }
    if (t.contains('bank') || t.contains('atm')) {
      return Icons.account_balance_rounded;
    }
    if (t.contains('school') || t.contains('university') || t.contains('college')) {
      return Icons.school_rounded;
    }
    return Icons.location_on_rounded;
  }
}

class QuickSearchCategory {
  final String title;
  final String query;
  final IconData icon;
  final Color color;

  const QuickSearchCategory({
    required this.title,
    required this.query,
    required this.icon,
    required this.color,
  });

  static const List<QuickSearchCategory> defaultCategories = [
    QuickSearchCategory(
      title: 'Cây xăng',
      query: 'cây xăng, trạm xăng petrolimex',
      icon: Icons.local_gas_station_rounded,
      color: Color(0xFFFF9F1C),
    ),
    QuickSearchCategory(
      title: 'Quán ăn',
      query: 'quán ăn, nhà hàng',
      icon: Icons.restaurant_rounded,
      color: Color(0xFFFF4081),
    ),
    QuickSearchCategory(
      title: 'Cà phê',
      query: 'quán cafe, cà phê',
      icon: Icons.local_cafe_rounded,
      color: Color(0xFF8D6E63),
    ),
    QuickSearchCategory(
      title: 'Bệnh viện',
      query: 'bệnh viện, phòng khám, nhà thuốc',
      icon: Icons.local_hospital_rounded,
      color: Color(0xFFEF4444),
    ),
    QuickSearchCategory(
      title: 'Bãi đỗ xe',
      query: 'bãi gửi xe, đỗ xe',
      icon: Icons.local_parking_rounded,
      color: Color(0xFF3B82F6),
    ),
    QuickSearchCategory(
      title: 'Siêu thị',
      query: 'siêu thị, winmart, bách hóa xanh',
      icon: Icons.shopping_cart_rounded,
      color: Color(0xFF10B981),
    ),
    QuickSearchCategory(
      title: 'ATM / Ngân hàng',
      query: 'cây atm, ngân hàng',
      icon: Icons.account_balance_rounded,
      color: Color(0xFF00C2FF),
    ),
  ];
}
