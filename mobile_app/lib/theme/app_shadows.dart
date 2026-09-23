import 'package:flutter/material.dart';

class AppShadows {
  // Apple-style soft, diffuse, shallow shadows
  static const List<BoxShadow> card = [
    BoxShadow(
      color: Color(0x0A000000), // 4% black
      blurRadius: 10,
      offset: Offset(0, 2),
    ),
    BoxShadow(
      color: Color(0x06000000), // 2.5% black
      blurRadius: 20,
      offset: Offset(0, 6),
    ),
  ];

  static const List<BoxShadow> floating = [
    BoxShadow(
      color: Color(0x0D000000), // 5% black
      blurRadius: 12,
      offset: Offset(0, 4),
    ),
    BoxShadow(
      color: Color(0x0A000000),
      blurRadius: 24,
      offset: Offset(0, 8),
    ),
  ];

  static const List<BoxShadow> sheet = [
    BoxShadow(
      color: Color(0x12000000), // 7% black
      blurRadius: 24,
      offset: Offset(0, -4),
    ),
  ];

  static const List<BoxShadow> button = [
    BoxShadow(
      color: Color(0x14007AFF), // 8% blue
      blurRadius: 12,
      offset: Offset(0, 4),
    ),
  ];
}
