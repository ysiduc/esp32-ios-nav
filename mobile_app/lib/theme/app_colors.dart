import 'package:flutter/material.dart';

class AppColors {
  // Primary brand / accents (Apple Maps blue & iOS system accents)
  static const Color primary = Color(0xFF007AFF);
  static const Color primaryLight = Color(0xFFE5F1FF);
  static const Color secondary = Color(0xFF5E5CE6);
  static const Color secondaryLight = Color(0xFFEFEBFF);

  // Backgrounds & Surfaces (Apple clean light theme)
  static const Color canvas = Color(0xFFF2F2F7);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color surfaceSecondary = Color(0xFFF9F9FB);
  static const Color surfaceTranslucent = Color(0xEEFFFFFF);
  static const Color surfaceGlass = Color(0xCCFFFFFF);

  // Semantic Status
  static const Color success = Color(0xFF34C759);
  static const Color successLight = Color(0xFFE8F9ED);
  static const Color warning = Color(0xFFFF9500);
  static const Color warningLight = Color(0xFFFFF4E5);
  static const Color danger = Color(0xFFFF3B30);
  static const Color dangerLight = Color(0xFFFFEBEA);
  static const Color info = Color(0xFF007AFF);

  // Hairlines, Dividers & Borders
  static const Color border = Color(0x14000000);         // ~8% black
  static const Color borderSubtle = Color(0x0A000000);   // ~4% black
  static const Color divider = Color(0x1A000000);        // ~10% black
  static const Color handleBar = Color(0x33000000);      // ~20% black

  // Typography Colors
  static const Color textPrimary = Color(0xFF1C1C1E);
  static const Color textSecondary = Color(0xFF8E8E93);
  static const Color textTertiary = Color(0xFFC7C7CC);
  static const Color textInverse = Color(0xFFFFFFFF);

  // Map & Navigation Accents
  static const Color routePrimary = Color(0xFF007AFF);
  static const Color routeSecondary = Color(0xFF8E8E93);
  static const Color destinationPin = Color(0xFFFF3B30);
  static const Color userLocation = Color(0xFF007AFF);
}
