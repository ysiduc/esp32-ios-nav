import 'package:maplibre_gl/maplibre_gl.dart' as ml;
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// Design system variants for Liquid Glass components (P5.7 & P5.7.1)

/// Centralized Design System Tokens for Apple Maps Liquid Glass (P5.8.2)
/// Adheres strictly to Target Images 1 & 2 (light, airy, translucent, subtle frosted milk,
/// 0.5pt specular edges, diffused soft shadows) while rejecting Anti-reference Images 3 & 4.
/// Unified Liquid Glass Material Style (P6.2)
/// Authoritative reference is Image 4:
/// - Map texture and roads are visibly translucent through the glass body
/// - Milky frosted diffusion (blur 24)
/// - Translucent adaptive tint (light: milky white ~0.38; dark: dark neutral/navy ~0.30)
/// - Ultra-fine specular highlight edge (0.5 - 0.6pt white stroke)
/// - Soft ambient diffuse shadow (blur 20, no harsh drop)
/// - Unified across: Drawer, Search sheet, Right toolbar, Bottom search bar
class MapOverlayGlassStyle {
  // P6.8 Ultra-Clear Blur Constants (blur <= 10.0 preserves crisp map view)
  static const double toolbarBlur = 10.0;
  static const double bottomSearchBlur = 10.0;
  static const double largeSurfaceBlur = 8.0;
  static const double drawerBlur = 8.0;
  static const double sheetBlur = 8.0;
  static const double routeSheetBlur = 8.0;
  static const double referenceBlur = 10.0;
  static const double trueLiquidGlassBlur = 10.0;
  static const double blurSigma = 22.0; // P6.2 backwards compat
  static const double capsuleBlur = 22.0;

  static double blur({bool isDark = false, bool isLargeSurface = false}) {
    if (isLargeSurface) return largeSurfaceBlur;
    return blurSigma;
  }

  /// P6.2 Translucent fill (preserved for backwards-compatibility with P6.2 tests)
  static Color fill({required bool isDark, double opacityFactor = 1.0}) {
    if (isDark) {
      return const Color(0xFF1E2638).withOpacity(0.18 * opacityFactor);
    } else {
      return Colors.white.withOpacity(0.14 * opacityFactor);
    }
  }

  /// P6.8 Ultra-Clear Liquid Glass - Right toolbar fill (dark: 0.022, light: 0.055)
  static Color toolbarFill({required bool isDark, double opacityFactor = 1.0}) {
    if (isDark) {
      return Colors.white.withOpacity(0.022 * opacityFactor);
    } else {
      return Colors.white.withOpacity(0.055 * opacityFactor);
    }
  }

  /// P6.8 Ultra-Clear Liquid Glass - Bottom search pill fill (dark: 0.022, light: 0.055)
  static Color bottomSearchFill({required bool isDark}) {
    if (isDark) {
      return Colors.white.withOpacity(0.022);
    } else {
      return Colors.white.withOpacity(0.055);
    }
  }

  static Color searchBarFill({required bool isDark}) => bottomSearchFill(isDark: isDark);

  /// P6.8 Ultra-Clear Liquid Glass - Drawer fill (dark: 0.018, light: 0.045)
  static Color drawerFill({required bool isDark}) {
    if (isDark) {
      return Colors.white.withOpacity(0.018);
    } else {
      return Colors.white.withOpacity(0.045);
    }
  }

  /// P6.8 Ultra-Clear Liquid Glass - Search sheet fill (dark: 0.018, light: 0.045)
  static Color sheetFill({required bool isDark}) {
    if (isDark) {
      return Colors.white.withOpacity(0.018);
    } else {
      return Colors.white.withOpacity(0.045);
    }
  }

  /// P6.8 Ultra-Clear Liquid Glass - Route directions sheet fill (dark: 0.018, light: 0.045)
  static Color routeSheetFill({required bool isDark}) {
    if (isDark) {
      return Colors.white.withOpacity(0.018);
    } else {
      return Colors.white.withOpacity(0.045);
    }
  }

  static Color secondaryFill({required bool isDark}) {
    if (isDark) {
      return Colors.white.withOpacity(0.10);
    } else {
      return Colors.white.withOpacity(0.50);
    }
  }

  /// P6.4 Watery large surface gradient for Drawer & Search Sheet
  static Gradient wateryLargeSurfaceGradient({
    required bool isDark,
    double opacityFactor = 1.0,
  }) {
    return LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: isDark
          ? [
              const Color(0xFF1E2638).withOpacity(0.15 * opacityFactor),
              const Color(0xFF121824).withOpacity(0.10 * opacityFactor),
              const Color(0xFF1A2230).withOpacity(0.14 * opacityFactor),
            ]
          : [
              Colors.white.withOpacity(0.10 * opacityFactor),
              Colors.white.withOpacity(0.055 * opacityFactor),
              Colors.white.withOpacity(0.09 * opacityFactor),
            ],
      stops: const [0.0, 0.5, 1.0],
    );
  }

  /// P6.4 Outer specular highlight rim for Drawer (meniscus curve edge)
  static Gradient drawerRimGradient({required bool isDark}) {
    return LinearGradient(
      begin: Alignment.topRight,
      end: Alignment.bottomRight,
      colors: isDark
          ? [
              Colors.white.withOpacity(0.40),
              Colors.white.withOpacity(0.10),
              Colors.white.withOpacity(0.06),
              Colors.white.withOpacity(0.25),
            ]
          : [
              Colors.white.withOpacity(0.80),
              Colors.white.withOpacity(0.28),
              Colors.white.withOpacity(0.18),
              Colors.white.withOpacity(0.55),
            ],
      stops: const [0.0, 0.35, 0.70, 1.0],
    );
  }

  /// P6.8 Ultra-Clear Liquid Glass card fill (0.025 - 0.05, selected Apple blue tint 0.08 - 0.10)
  static Color cardFill({required bool isDark, bool isSelected = false}) {
    if (isSelected) {
      return const Color(0xFF007AFF).withOpacity(isDark ? 0.10 : 0.08);
    }
    return isDark ? Colors.white.withOpacity(0.025) : Colors.white.withOpacity(0.05);
  }

  static Color drawerCardFill({required bool isDark, bool isSelected = false}) =>
      cardFill(isDark: isDark, isSelected: isSelected);

  static Border drawerCardBorder({required bool isDark, bool isSelected = false}) {
    if (isSelected) {
      return Border.all(
        color: const Color(0xFF007AFF).withOpacity(isDark ? 0.65 : 0.60),
        width: 1.0,
      );
    }
    return Border.all(
      color: isDark ? Colors.white.withOpacity(0.16) : Colors.white.withOpacity(0.25),
      width: 0.7,
    );
  }

  /// P6.8 Search input field fill (0.06 dark / 0.09 light for crisp readability)
  static Color searchSheetFieldFill({required bool isDark}) {
    if (isDark) {
      return Colors.white.withOpacity(0.06);
    } else {
      return Colors.white.withOpacity(0.09);
    }
  }

  /// P6.8 Edge-defined reference border: dark 0.20, light 0.30, width 0.7
  static Border referenceBorder({required bool isDark, double width = 0.7}) {
    return Border.all(
      color: isDark ? Colors.white.withOpacity(0.20) : Colors.white.withOpacity(0.30),
      width: width,
    );
  }

  /// P6.8 Ultra-soft reference shadow: dark black 0.04 / blur 8 / y=2; light black 0.03 / blur 8 / y=2
  static List<BoxShadow> referenceShadow({required bool isDark}) {
    if (isDark) {
      return [
        BoxShadow(
          color: Colors.black.withOpacity(0.04),
          blurRadius: 8.0,
          offset: const Offset(0, 2),
        ),
      ];
    } else {
      return [
        BoxShadow(
          color: Colors.black.withOpacity(0.03),
          blurRadius: 8.0,
          offset: const Offset(0, 2),
        ),
      ];
    }
  }

  /// Refractive specular outer rim gradient (P6.3 watery edge)
  static Gradient specularRimGradient({required bool isDark}) {
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: isDark
          ? [
              Colors.white.withOpacity(0.42),
              Colors.white.withOpacity(0.12),
              Colors.white.withOpacity(0.06),
              Colors.white.withOpacity(0.22),
            ]
          : [
              Colors.white.withOpacity(0.85),
              Colors.white.withOpacity(0.35),
              Colors.white.withOpacity(0.20),
              Colors.white.withOpacity(0.60),
            ],
      stops: const [0.0, 0.35, 0.70, 1.0],
    );
  }

  /// Watery glass body gradient simulating meniscus / convex curve
  static Gradient wateryBodyGradient({required bool isDark, double opacityFactor = 1.0}) {
    return LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: isDark
          ? [
              const Color(0xFF222C3D).withOpacity(0.24 * opacityFactor),
              const Color(0xFF121824).withOpacity(0.14 * opacityFactor),
              const Color(0xFF1A2230).withOpacity(0.20 * opacityFactor),
            ]
          : [
              Colors.white.withOpacity(0.22 * opacityFactor),
              Colors.white.withOpacity(0.11 * opacityFactor),
              Colors.white.withOpacity(0.18 * opacityFactor),
            ],
      stops: const [0.0, 0.5, 1.0],
    );
  }

  static List<BoxShadow> softShadow({required bool isDark}) {
    return [
      BoxShadow(
        color: Colors.black.withOpacity(isDark ? 0.20 : 0.06),
        blurRadius: 20.0,
        spreadRadius: 0.0,
        offset: const Offset(0, 4),
      ),
    ];
  }

  static List<BoxShadow> shadow({required bool isDark}) => softShadow(isDark: isDark);

  static Border border({required bool isDark, double width = 0.5}) {
    if (isDark) {
      return Border.all(
        color: Colors.white.withOpacity(0.30),
        width: width,
      );
    } else {
      return Border.all(
        color: Colors.white.withOpacity(0.65),
        width: width,
      );
    }
  }

  static BoxDecoration decoration({
    required bool isDark,
    BorderRadius? borderRadius,
    double radius = 24.0,
    double borderWidth = 0.5,
    double opacityFactor = 1.0,
  }) {
    return BoxDecoration(
      color: fill(isDark: isDark, opacityFactor: opacityFactor),
      borderRadius: borderRadius ?? BorderRadius.circular(radius),
      border: border(isDark: isDark, width: borderWidth),
      boxShadow: shadow(isDark: isDark),
    );
  }
}

/// Exact Liquid Glass Reference Component restored from run 35895237697 (Commit 52cee9d)
/// Golden reference:
/// - width: 48 (toolbar) or custom
/// - fill: Colors.white.withOpacity(0.85) (or custom surface fill 0.78 - 0.88)
/// - border: Colors.white.withOpacity(0.70) / 0.8pt
/// - blur: sigma 20.0
/// - shadow: black.withOpacity(0.08) / blur 16 / offset (0, 4)
/// P6.6 True Frosted Liquid Glass reusable component
/// Visual Source of Truth matching Apple Maps liquid glass reference:
/// - ClipRRect (borderRadius)
///   - Positioned.fill -> BackdropFilter (sigma 24 ~ 32) -> blurs real map underneath
///   - Positioned.fill -> Translucent base tint (0.10 ~ 0.18) + subtle angled sheen gradient
///   - Positioned.fill -> Specular highlight / curved glass glint layer (top-left to bottom-right)
///   - Positioned.fill -> Inner rim / curved edge (meniscus droplet look)
///   - Positioned.fill -> Outer crisp specular border (white 0.30 ~ 0.45, 0.8 ~ 1.0pt)
///   - Child content with padding
class TrueLiquidGlass extends StatelessWidget {
  final Widget child;
  final double? width;
  final double? height;
  final BorderRadius? borderRadius;
  final double radius;
  final double blurSigma;
  final Color? fillColor;
  final Gradient? bodyGradient;
  final BoxBorder? border;
  final List<BoxShadow>? boxShadow;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final VoidCallback? onTap;
  final bool isDark;
  final bool showHighlight;
  final bool showInnerRim;

  const TrueLiquidGlass({
    super.key,
    required this.child,
    this.width,
    this.height,
    this.borderRadius,
    this.radius = 24.0,
    this.blurSigma = 10.0,
    this.fillColor,
    this.bodyGradient,
    this.border,
    this.boxShadow,
    this.padding,
    this.margin,
    this.onTap,
    this.isDark = false,
    this.showHighlight = true,
    this.showInnerRim = true,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveRadius = borderRadius ?? BorderRadius.circular(radius);

    // 1. Ultra-clear base fill (dark: 0.022, light: 0.055)
    final effectiveFill = fillColor ??
        (isDark
            ? Colors.white.withOpacity(0.022)
            : Colors.white.withOpacity(0.055));

    // 2. Body gradient is purely optional (default null - no body gradient overlay)
    final effectiveBodyGradient = bodyGradient;

    // 3. Crisp edge-defined outer border (dark: 0.20, light: 0.30, width: 0.7)
    final effectiveBorder = border ??
        Border.all(
          color: isDark
              ? Colors.white.withOpacity(0.20)
              : Colors.white.withOpacity(0.30),
          width: 0.7,
        );

    // 4. Ultra-soft shadow (dark: 0.04 / blur 8 / y=2; light: 0.03 / blur 8 / y=2)
    final effectiveShadow = boxShadow ??
        (isDark
            ? [
                BoxShadow(
                  color: Colors.black.withOpacity(0.04),
                  blurRadius: 8.0,
                  offset: const Offset(0, 2),
                ),
              ]
            : [
                BoxShadow(
                  color: Colors.black.withOpacity(0.03),
                  blurRadius: 8.0,
                  offset: const Offset(0, 2),
                ),
              ]);

    Widget content = Container(
      margin: margin,
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: effectiveRadius,
        boxShadow: effectiveShadow,
      ),
      child: ClipRRect(
        borderRadius: effectiveRadius,
        child: Stack(
          children: [
            // Layer 1: True optical BackdropFilter with gentle blur (8.0–10.0 preserves crisp map view)
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
                child: Container(color: Colors.transparent),
              ),
            ),

            // Layer 2: Ultra-clear neutral fill (+ optional caller bodyGradient)
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: effectiveFill,
                  gradient: effectiveBodyGradient,
                ),
              ),
            ),

            // Layer 3: Ultra-light Edge-Only Specular Highlight (sheen mỏng ở viền, center ~80% trong suốt)
            if (showHighlight)
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: isDark
                            ? [
                                Colors.white.withOpacity(0.06),
                                Colors.transparent,
                                Colors.transparent,
                                Colors.white.withOpacity(0.015),
                              ]
                            : [
                                Colors.white.withOpacity(0.10),
                                Colors.transparent,
                                Colors.transparent,
                                Colors.white.withOpacity(0.025),
                              ],
                        stops: const [0.0, 0.10, 0.85, 1.0],
                      ),
                    ),
                  ),
                ),
              ),

            // Layer 4: Subtle Inner Rim (dark 0.06, light 0.10, width 0.5)
            if (showInnerRim)
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    margin: const EdgeInsets.all(0.7),
                    decoration: BoxDecoration(
                      borderRadius: effectiveRadius,
                      border: Border.all(
                        color: isDark
                            ? Colors.white.withOpacity(0.06)
                            : Colors.white.withOpacity(0.10),
                        width: 0.5,
                      ),
                    ),
                  ),
                ),
              ),

            // Layer 5: Outer Crisp Specular Border
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: effectiveRadius,
                    border: effectiveBorder,
                  ),
                ),
              ),
            ),

            // Layer 6: Content
            Padding(
              padding: padding ?? EdgeInsets.zero,
              child: child,
            ),
          ],
        ),
      ),
    );

    if (onTap != null) {
      return GestureDetector(
        onTap: onTap,
        child: content,
      );
    }
    return content;
  }
}

typedef AppleStyleLiquidGlass = TrueLiquidGlass;
typedef AppleMapsReferenceGlass = TrueLiquidGlass;
typedef P61ReferenceGlassSurface = TrueLiquidGlass;

class ReferenceGlassSurface extends StatelessWidget {
  final Widget child;
  final double? width;
  final double? height;
  final BorderRadius? borderRadius;
  final double radius;
  final Color? fillColor;
  final BoxBorder? border;
  final List<BoxShadow>? boxShadow;
  final double blurSigma;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final VoidCallback? onTap;
  final bool isDark;

  const ReferenceGlassSurface({
    super.key,
    required this.child,
    this.width,
    this.height,
    this.borderRadius,
    this.radius = 24.0,
    this.fillColor,
    this.border,
    this.boxShadow,
    this.blurSigma = 10.0,
    this.padding,
    this.margin,
    this.onTap,
    this.isDark = false,
  });

  @override
  Widget build(BuildContext context) {
    return TrueLiquidGlass(
      width: width,
      height: height,
      borderRadius: borderRadius,
      radius: radius,
      fillColor: fillColor,
      border: border,
      boxShadow: boxShadow,
      blurSigma: blurSigma,
      padding: padding,
      margin: margin,
      onTap: onTap,
      isDark: isDark,
      child: child,
    );
  }
}

/// True Liquid Glass Watery Capsule (P6.3)
/// Renders a single continuous capsule with:
/// 1. Outer specular highlight gradient rim (0.8pt refractive edge)
/// 2. Soft ambient floating shadow (no harsh grey drop)
/// 3. Deep optical BackdropFilter (sigma 26.0)
/// 4. Watery body gradient with 0.10 - 0.18 translucent core
/// 5. Top/left inner specular meniscus sheen
class WateryLiquidGlassCapsule extends StatelessWidget {
  final Widget child;
  final double? width;
  final double? height;
  final double radius;
  final bool isDark;
  final double opacityFactor;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final VoidCallback? onTap;

  const WateryLiquidGlassCapsule({
    super.key,
    required this.child,
    this.width,
    this.height,
    this.radius = 24.0,
    required this.isDark,
    this.opacityFactor = 1.0,
    this.padding,
    this.margin,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final capsule = Container(
      margin: margin,
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: MapOverlayGlassStyle.specularRimGradient(isDark: isDark),
        boxShadow: MapOverlayGlassStyle.softShadow(isDark: isDark),
      ),
      padding: const EdgeInsets.all(0.8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius - 0.8),
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: MapOverlayGlassStyle.capsuleBlur,
            sigmaY: MapOverlayGlassStyle.capsuleBlur,
          ),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              gradient: MapOverlayGlassStyle.wateryBodyGradient(
                isDark: isDark,
                opacityFactor: opacityFactor,
              ),
              borderRadius: BorderRadius.circular(radius - 0.8),
            ),
            child: child,
          ),
        ),
      ),
    );

    if (onTap != null) {
      return GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: capsule,
      );
    }
    return capsule;
  }
}

class AppleGlassTokens {
  // --- 1. Run 35895237697 Reference Tokens ---
  static const double referenceBlur = 10.0;
  static const double toolbarBlur = 10.0;
  static const double largeSurfaceBlur = 8.0;
  static const double referenceBorderWidth = 0.7;
  static final Color referenceBorder = Colors.white.withOpacity(0.30);
  static final Color referenceFillToolbar = Colors.white.withOpacity(0.055);
  static final Color referenceFillSearchPill = Colors.white.withOpacity(0.055);
  static final Color referenceFillDrawer = Colors.white.withOpacity(0.045);
  static final Color referenceFillSheet = Colors.white.withOpacity(0.045);
  static final Color referenceFillRouteSheet = Colors.white.withOpacity(0.045);
  static final Color referenceFillCard = Colors.white.withOpacity(0.05);

  // --- Blur Intensities ---
  static const double blurLight = 16.0;
  static const double blurRegular = 20.0;
  static const double blurProminent = 24.0;
  static const double blurSheet = 30.0;

  // --- 2. Translucent Light Fills (Milky frosted, airy, low gray tint) ---
  static final Color fillLight = Colors.white.withOpacity(0.72);
  static final Color fillRegular = Colors.white.withOpacity(0.78);
  static final Color fillProminent = Colors.white.withOpacity(0.85);
  static final Color fillToolbar = Colors.white.withOpacity(0.14);
  static final Color fillSheet = Colors.white.withOpacity(0.24);
  static final Color fillSearchField = Colors.white.withOpacity(0.50);
  static const Color fillCard = Colors.white;

  // --- 3. Specular Border Strokes (0.5pt subtle, refined light highlights) ---
  static final Color borderSubtle = Colors.white.withOpacity(0.60);
  static final Color borderEdge = Colors.white.withOpacity(0.80);
  static final Color borderSheet = Colors.black.withOpacity(0.04);
  static final Color borderCard = Colors.black.withOpacity(0.06);

  // --- 4. Soft Apple Shadows (Subtle, diffused, no harsh dark drops) ---
  static final List<BoxShadow> shadowSoft = [
    BoxShadow(
      color: Colors.black.withOpacity(0.06),
      blurRadius: 16,
      offset: const Offset(0, 3),
    ),
  ];
  static final List<BoxShadow> shadowCard = [
    BoxShadow(
      color: Colors.black.withOpacity(0.04),
      blurRadius: 8,
      offset: const Offset(0, 2),
    ),
  ];
  static final List<BoxShadow> shadowSheet = [
    BoxShadow(
      color: Colors.black.withOpacity(0.12),
      blurRadius: 28,
      offset: const Offset(0, -6),
    ),
  ];

  // --- 5. Standard Corner Radii ---
  static const double radiusPill = 24.0;
  static const double radiusToolbar = 23.0;
  static const double radiusSheet = 24.0;
  static const double radiusCard = 16.0;

  // --- 6. Named Tone System Presets (P5.8.2 Requirement C.3) ---
  static BoxDecoration get glassLight => BoxDecoration(
    color: fillLight,
    borderRadius: BorderRadius.circular(radiusPill),
    border: Border.all(color: borderSubtle, width: 0.5),
    boxShadow: shadowSoft,
  );

  static BoxDecoration get glassProminentLight => BoxDecoration(
    color: fillProminent,
    borderRadius: BorderRadius.circular(radiusPill),
    border: Border.all(color: borderEdge, width: 0.5),
    boxShadow: shadowSoft,
  );

  static BoxDecoration get glassToolbar => BoxDecoration(
    color: fillToolbar,
    borderRadius: BorderRadius.circular(radiusToolbar),
    border: Border.all(color: borderEdge, width: 0.5),
    boxShadow: shadowSoft,
  );

  static BoxDecoration get glassSheet => BoxDecoration(
    color: fillSheet,
    borderRadius: const BorderRadius.vertical(top: Radius.circular(radiusSheet)),
    boxShadow: shadowSheet,
  );

  static BoxDecoration get glassSearchField => BoxDecoration(
    color: fillSearchField,
    borderRadius: BorderRadius.circular(23.0),
    border: Border.all(color: borderCard, width: 0.5),
    boxShadow: shadowCard,
  );

  /// Unified Map Overlay Glass material preset (P6.2)
  static BoxDecoration mapOverlayMaterial({
    required bool isDark,
    BorderRadius? borderRadius,
    double radius = 24.0,
    double borderWidth = 0.5,
    double opacityFactor = 1.0,
  }) => MapOverlayGlassStyle.decoration(
    isDark: isDark,
    borderRadius: borderRadius,
    radius: radius,
    borderWidth: borderWidth,
    opacityFactor: opacityFactor,
  );
}

enum AppGlassVariant {
  /// Balanced frosted diffusion with specular edge (default)
  regular,

  /// High transparency, crisp edge, ideal for unobtrusive floating chips
  clear,

  /// High density and contrast for driving navigation overlays where readability is paramount
  prominent,

  /// Crimson/reddish tinted glass for destructive and cancel actions
  danger,

  /// Unified Map Overlay Liquid Glass (P6.2 Image 4 reference)
  mapOverlay,
}

/// Active navigation/map overlay presentation mode (P5.8)
enum MapOverlayMode {
  none,
  search,
  drawer,
  dialog,
  reportSheet,
  placeDetails,
}

/// Representation of a registered glass surface geometry and style (P5.8.1)
class GlassSurfaceData {
  final String id;
  final Rect rect;
  final double radius;
  final String variant;
  final bool isSelected;
  final int? tint;
  final String? groupId;

  const GlassSurfaceData({
    required this.id,
    required this.rect,
    required this.radius,
    required this.variant,
    this.isSelected = false,
    this.tint,
    this.groupId,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'x': rect.left,
    'y': rect.top,
    'w': rect.width,
    'h': rect.height,
    'radius': radius,
    'variant': variant,
    'isSelected': isSelected,
    if (tint != null) 'tint': tint,
    if (groupId != null) 'groupId': groupId,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GlassSurfaceData &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          rect == other.rect &&
          radius == other.radius &&
          variant == other.variant &&
          isSelected == other.isSelected &&
          tint == other.tint &&
          groupId == other.groupId;

  @override
  int get hashCode => Object.hash(id, rect, radius, variant, isSelected, tint, groupId);
}

/// Controller coordinating native Liquid Glass surfaces inside MapLibre native view (P5.9 Architecture)
class MapNativeGlassController extends ChangeNotifier {
  static final MapNativeGlassController instance = MapNativeGlassController._internal();
  MapNativeGlassController._internal();

  MapOverlayMode _overlayMode = MapOverlayMode.none;
  MapOverlayMode get overlayMode => _overlayMode;
  MapOverlayMode get currentMode => _overlayMode;
  bool get isOverlayActive => _overlayMode != MapOverlayMode.none;

  final Map<String, GlassSurfaceData> _surfaces = {};
  Map<String, GlassSurfaceData> get surfaces => Map.unmodifiable(_surfaces);

  ml.MapLibreMapController? _mapController;
  GlobalKey? _mapKey;

  /// Global origin offset of MapLibre view, for testing and coordinate translation
  Offset? _mockMapOrigin;
  @visibleForTesting
  set mockMapOrigin(Offset? origin) => _mockMapOrigin = origin;

  bool _flushScheduled = false;

  @visibleForTesting
  static void Function(List<Map<String, dynamic>>)? onFlushForTesting;

  void attachMap(ml.MapLibreMapController controller, [GlobalKey? mapKey]) {
    _mapController = controller;
    _mapKey = mapKey;
    flushSurfaces();
  }

  void detachMap() {
    _mapController = null;
    _mapKey = null;
  }

  Offset get mapGlobalOrigin {
    if (_mockMapOrigin != null) return _mockMapOrigin!;
    if (_mapKey?.currentContext != null) {
      final box = _mapKey!.currentContext!.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        return box.localToGlobal(Offset.zero);
      }
    }
    return Offset.zero;
  }

  void setOverlayMode(MapOverlayMode mode) {
    if (_overlayMode == mode) return;
    _overlayMode = mode;
    notifyListeners();
    flushSurfaces();
  }

  void registerSurface(GlassSurfaceData surface) {
    final existing = _surfaces[surface.id];
    if (existing != null && existing == surface) {
      return;
    }
    _surfaces[surface.id] = surface;
    _scheduleFlush();
  }

  void updateSurface(GlassSurfaceData surface) {
    registerSurface(surface);
  }

  void unregisterSurface(String id) {
    if (_surfaces.remove(id) != null) {
      _scheduleFlush();
    }
  }

  void _scheduleFlush() {
    if (_flushScheduled) return;
    _flushScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _flushScheduled = false;
      flushSurfaces();
    });
  }

  void flushSurfaces() {
    final origin = mapGlobalOrigin;
    final payload = _surfaces.values.map((s) {
      final localRect = s.rect.shift(-origin);
      return {
        'id': s.id,
        'x': localRect.left,
        'y': localRect.top,
        'w': localRect.width,
        'h': localRect.height,
        'radius': s.radius,
        'variant': s.variant,
        'isSelected': s.isSelected,
        if (s.tint != null) 'tint': s.tint,
        if (s.groupId != null) 'groupId': s.groupId,
        'visible': !isOverlayActive,
      };
    }).toList();

    onFlushForTesting?.call(payload);
    _mapController?.updateGlassSurfaces(payload);
  }

  @visibleForTesting
  void resetForTesting() {
    _overlayMode = MapOverlayMode.none;
    _surfaces.clear();
    _flushScheduled = false;
    _mapController = null;
    _mapKey = null;
    _mockMapOrigin = null;
    notifyListeners();
  }
}

/// Backwards compatibility alias for P5.8 code
typedef NativeGlassHostController = MapNativeGlassController;

/// Deprecated stub for P5.8 NativeGlassHostLayer (P5.9 Architecture).
/// Liquid Glass is now rendered directly inside MapLibre native view hierarchy.
/// This widget returns SizedBox.shrink() and mounts ZERO platform views.
@Deprecated('Liquid Glass is integrated directly into MapLibre view in P5.9. Do not mount NativeGlassHostLayer.')
class NativeGlassHostLayer extends StatelessWidget {
  const NativeGlassHostLayer({super.key});

  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}

/// Resolved runtime rendering backend for Liquid Glass (P5.7.1 & P5.8)
enum AppGlassBackendType {
  /// True Apple Liquid Glass API (iOS 26+ UIGlassEffect)
  uiGlass,

  /// Grouped Apple Liquid Glass container (iOS 26+ UIGlassContainerEffect)
  uiGlassContainer,

  /// Native iOS UIKit UIVisualEffectView material with specular highlight edge
  nativeBlurFallback,

  /// Pure Flutter BackdropFilter fallback for Android, Linux, desktop, web, or active overlays
  flutterFallback,

  /// Solid high-contrast opaque surface when Reduce Transparency is enabled
  opaqueAccessibility,

  // Backwards compatibility alias
  nativeModern,
  opaqueFallback,
}

/// Global service providing iOS UIAccessibility.isReduceTransparencyEnabled state and native glass capability (P5.7.1 & P5.7.2)
class AppAccessibilityService extends ChangeNotifier {
  static final AppAccessibilityService instance = AppAccessibilityService._internal();

  AppAccessibilityService._internal() {
    _init();
  }

  static const MethodChannel _channel = MethodChannel('com.ysiduc.esp32_nav/accessibility');
  bool _reduceTransparency = false;
  String _nativeGlassCapability = 'native-blur-fallback';

  bool get reduceTransparency => _reduceTransparency;
  String get nativeGlassCapability => _nativeGlassCapability;

  Future<void> _init() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onReduceTransparencyChanged') {
        if (call.arguments is bool) {
          _reduceTransparency = call.arguments as bool;
          notifyListeners();
        }
      }
    });

    try {
      final res = await _channel.invokeMethod<bool>('isReduceTransparencyEnabled');
      if (res != null) {
        _reduceTransparency = res;
        notifyListeners();
      }
    } catch (_) {
      // Non-iOS or test environment fallback
    }

    try {
      final cap = await _channel.invokeMethod<String>('getGlassCapability');
      if (cap != null && cap.isNotEmpty) {
        _nativeGlassCapability = cap;
        notifyListeners();
      }
    } catch (_) {
      // Non-iOS or test environment fallback
    }
  }

  @visibleForTesting
  void setReduceTransparencyForTesting(bool value) {
    _reduceTransparency = value;
    notifyListeners();
  }

  @visibleForTesting
  void setNativeGlassCapabilityForTesting(String value) {
    _nativeGlassCapability = value;
    notifyListeners();
  }
}

/// Helper and telemetry provider for Liquid Glass backend selection (P5.7.1 Part 5 & P5.7.2)
class AppGlassBackend {
  @visibleForTesting
  static AppGlassBackendType? forceBackendForTesting;

  @visibleForTesting
  static TargetPlatform? forcePlatformForTesting;

  /// Resolves the active rendering backend based on platform and accessibility settings
  static AppGlassBackendType resolve({
    required BuildContext context,
    required bool isReduceTransparency,
  }) {
    // 1. Accessibility Fallback: Reduce Transparency ALWAYS forces opaque fallback (P5.7.1 & P5.7.2)
    if (isReduceTransparency) {
      return AppGlassBackendType.opaqueAccessibility;
    }

    // 2. Synthetic backend override for unit testing specific visual branches
    if (forceBackendForTesting != null) {
      return forceBackendForTesting!;
    }

    // 3. Z-Order Composition Guard: When a modal, drawer, or dialog is active,
    // fallback to pure Flutter compositing so no native platform view occludes the overlay! (P5.8)
    if (NativeGlassHostController.instance.isOverlayActive) {
      return AppGlassBackendType.flutterFallback;
    }

    // 4. Platform & native capability detection
    final platform = forcePlatformForTesting ?? defaultTargetPlatform;
    if (kIsWeb) {
      return AppGlassBackendType.flutterFallback;
    }
    if (platform == TargetPlatform.iOS) {
      final cap = AppAccessibilityService.instance.nativeGlassCapability;
      if (cap == 'uiglass' || cap == 'native-modern') {
        return AppGlassBackendType.uiGlass;
      }
      if (cap == 'uiglass-container') {
        return AppGlassBackendType.uiGlassContainer;
      }
      return AppGlassBackendType.nativeBlurFallback;
    }
    return AppGlassBackendType.flutterFallback;
  }

  /// Returns a human-readable telemetry string for debug overlay and field verification (P5.8)
  static String currentName(BuildContext context, [bool? isReduceTransparency]) {
    final effectiveReduceTransparency = isReduceTransparency ??
        AppAccessibilityService.instance.reduceTransparency;
    final type = resolve(context: context, isReduceTransparency: effectiveReduceTransparency);
    switch (type) {
      case AppGlassBackendType.uiGlass:
      case AppGlassBackendType.nativeModern:
        return 'uiglass';
      case AppGlassBackendType.uiGlassContainer:
        return 'uiglass-container';
      case AppGlassBackendType.nativeBlurFallback:
        return 'native-blur-fallback';
      case AppGlassBackendType.flutterFallback:
        return 'flutter-fallback';
      case AppGlassBackendType.opaqueAccessibility:
      case AppGlassBackendType.opaqueFallback:
        return 'opaque-accessibility';
    }
  }
}

/// Base adaptive Liquid Glass material container (P5.7 & P5.7.1)
/// Features real native iOS platform view backend (UiKitView) with Flutter content on top,
/// and automatic Flutter BackdropFilter fallback for other platforms.
class AppGlassSurface extends StatefulWidget {
  final Widget child;
  final AppGlassVariant variant;
  final double radius;
  final double? blur;
  final Color? tint;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double? width;
  final double? height;
  final BoxBorder? border;
  final List<BoxShadow>? customShadow;
  final bool isSelected;
  final Color? selectedBorderColor;
  final bool? reduceTransparency;
  final String? groupId;
  final String? surfaceId;

  const AppGlassSurface({
    super.key,
    required this.child,
    this.variant = AppGlassVariant.regular,
    this.radius = 24.0,
    this.blur,
    this.tint,
    this.padding,
    this.margin,
    this.width,
    this.height,
    this.border,
    this.customShadow,
    this.isSelected = false,
    this.selectedBorderColor,
    this.reduceTransparency,
    this.groupId,
    this.surfaceId,
  });

  @override
  State<AppGlassSurface> createState() => _AppGlassSurfaceState();
}

class _AppGlassSurfaceState extends State<AppGlassSurface> {
  static int _idCounter = 0;
  late final String _id;

  @override
  void initState() {
    super.initState();
    _id = widget.surfaceId ?? 'surf_${++_idCounter}_${identityHashCode(this)}';
    _scheduleLayoutRegistration();
  }

  @override
  void didUpdateWidget(covariant AppGlassSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.radius != widget.radius ||
        oldWidget.variant != widget.variant ||
        oldWidget.isSelected != widget.isSelected ||
        oldWidget.tint != widget.tint ||
        oldWidget.groupId != widget.groupId ||
        oldWidget.width != widget.width ||
        oldWidget.height != widget.height) {
      _scheduleLayoutRegistration();
    }
  }

  @override
  void dispose() {
    NativeGlassHostController.instance.unregisterSurface(_id);
    super.dispose();
  }

  void _scheduleLayoutRegistration() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final renderBox = context.findRenderObject() as RenderBox?;
      if (renderBox != null && renderBox.hasSize) {
        final offset = renderBox.localToGlobal(Offset.zero);
        final rect = offset & renderBox.size;
        NativeGlassHostController.instance.registerSurface(
          GlassSurfaceData(
            id: _id,
            rect: rect,
            radius: widget.radius,
            variant: widget.variant.name,
            isSelected: widget.isSelected,
            tint: widget.tint?.value,
            groupId: widget.groupId,
          ),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.reduceTransparency != null) {
      return _buildSurface(context, widget.reduceTransparency!);
    }

    return ListenableBuilder(
      listenable: Listenable.merge([
        AppAccessibilityService.instance,
        NativeGlassHostController.instance,
      ]),
      builder: (context, _) => _buildSurface(
        context,
        AppAccessibilityService.instance.reduceTransparency,
      ),
    );
  }

  Widget _buildSurface(BuildContext context, bool isReduceTransparency) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final backend = AppGlassBackend.resolve(
      context: context,
      isReduceTransparency: isReduceTransparency,
    );

    // 1. Accessibility Fallback: Opaque high-contrast surface if transparency is reduced
    if (backend == AppGlassBackendType.opaqueAccessibility ||
        backend == AppGlassBackendType.opaqueFallback) {
      Color solidBg;
      Color solidBorder;

      switch (widget.variant) {
        case AppGlassVariant.prominent:
          solidBg = isDark ? const Color(0xFF0F172A) : Colors.white;
          solidBorder = isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1);
          break;
        case AppGlassVariant.danger:
          solidBg = isDark ? const Color(0xFF7F1D1D) : const Color(0xFFFEE2E2);
          solidBorder = isDark ? const Color(0xFFB91C1C) : const Color(0xFFEF4444);
          break;
        case AppGlassVariant.clear:
        case AppGlassVariant.regular:
        case AppGlassVariant.mapOverlay:
          solidBg = isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC);
          solidBorder = isDark ? const Color(0xFF475569) : const Color(0xFFE2E8F0);
          break;
      }

      if (widget.tint != null) {
        solidBg = Color.alphaBlend(widget.tint!, solidBg);
      }

      return Container(
        margin: widget.margin,
        width: widget.width,
        height: widget.height,
        padding: widget.padding,
        decoration: BoxDecoration(
          color: solidBg,
          borderRadius: BorderRadius.circular(widget.radius),
          border: widget.border ?? Border.all(
            color: widget.isSelected ? (widget.selectedBorderColor ?? const Color(0xFF007AFF)) : solidBorder,
            width: widget.isSelected ? 1.5 : 1.0,
          ),
          boxShadow: widget.customShadow ?? [
            BoxShadow(
              color: Colors.black.withOpacity(isDark ? 0.3 : 0.1),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: widget.child,
      );
    }

    // Determine default specular border color (P5.8.2: 0.5pt subtle Apple highlight)
    Color defaultBorderColor;
    switch (widget.variant) {
      case AppGlassVariant.prominent:
        defaultBorderColor = AppleGlassTokens.borderEdge;
        break;

      case AppGlassVariant.mapOverlay:
        defaultBorderColor = isDark ? Colors.white.withOpacity(0.35) : Colors.white.withOpacity(0.60);
        break;

      case AppGlassVariant.clear:
        defaultBorderColor = AppleGlassTokens.borderSubtle.withOpacity(0.45);
        break;

      case AppGlassVariant.danger:
        defaultBorderColor = const Color(0xFFEF4444).withOpacity(0.35);
        break;

      case AppGlassVariant.regular:
        defaultBorderColor = AppleGlassTokens.borderSubtle;
        break;
    }

    final defaultBorder = Border.all(
      color: widget.isSelected
          ? (widget.selectedBorderColor ?? const Color(0xFF007AFF))
          : defaultBorderColor,
      width: widget.isSelected ? 1.5 : 0.5,
    );

    final shadows = widget.customShadow ?? [
      BoxShadow(
        color: Colors.black.withOpacity(0.06),
        blurRadius: 16,
        offset: const Offset(0, 3),
      ),
      if (widget.isSelected)
        BoxShadow(
          color: (widget.selectedBorderColor ?? const Color(0xFF007AFF)).withOpacity(0.25),
          blurRadius: 12,
          spreadRadius: 1,
        ),
    ];

    // 2. REAL NATIVE LIQUID GLASS BACKEND (P5.8.1 Single Host Architecture)
    // The native glass material is rendered on the single NativeGlassHostLayer behind Flutter UI.
    // AppGlassSurface registers its layout rect with NativeGlassHostController and renders
    // foreground Flutter content with crisp borders and shadows, WITHOUT instantiating any UiKitView!
    if (backend == AppGlassBackendType.uiGlass ||
        backend == AppGlassBackendType.uiGlassContainer ||
        backend == AppGlassBackendType.nativeModern ||
        backend == AppGlassBackendType.nativeBlurFallback) {
      _scheduleLayoutRegistration();
      return Container(
        margin: widget.margin,
        width: widget.width,
        height: widget.height,
        padding: widget.padding,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.radius),
          border: widget.border ?? defaultBorder,
          boxShadow: shadows,
        ),
        child: widget.child,
      );
    }

    // 3. FLUTTER BACKDROP FILTER FALLBACK (Android / Web / Linux / Tests / Active Overlays)
    final effectiveBlur = widget.blur ?? (
      widget.variant == AppGlassVariant.prominent ? 24.0 :
      widget.variant == AppGlassVariant.clear ? 12.0 :
      widget.variant == AppGlassVariant.danger ? 16.0 : 18.0
    );

    Color fillColor;
    switch (widget.variant) {
      case AppGlassVariant.prominent:
        fillColor = AppleGlassTokens.fillProminent;
        break;

      case AppGlassVariant.mapOverlay:
        fillColor = MapOverlayGlassStyle.fill(isDark: isDark);
        break;

      case AppGlassVariant.clear:
        fillColor = AppleGlassTokens.fillLight.withOpacity(0.30);
        break;

      case AppGlassVariant.danger:
        fillColor = const Color(0xFFEF4444).withOpacity(0.20);
        break;

      case AppGlassVariant.regular:
        fillColor = AppleGlassTokens.fillRegular;
        break;
    }

    if (widget.tint != null) {
      fillColor = Color.alphaBlend(widget.tint!, fillColor);
    }

    return Container(
      margin: widget.margin,
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(widget.radius),
        boxShadow: shadows,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: effectiveBlur, sigmaY: effectiveBlur),
          child: Container(
            padding: widget.padding,
            decoration: BoxDecoration(
              color: fillColor,
              borderRadius: BorderRadius.circular(widget.radius),
              border: widget.border ?? defaultBorder,
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class AppGlassPill extends StatelessWidget {
  final Widget child;
  final AppGlassVariant variant;
  final double? width;
  final double? height;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final Color? tint;
  final VoidCallback? onTap;
  final bool isSelected;
  final Color? selectedBorderColor;

  const AppGlassPill({
    super.key,
    required this.child,
    this.variant = AppGlassVariant.regular,
    this.width,
    this.height,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    this.margin,
    this.tint,
    this.onTap,
    this.isSelected = false,
    this.selectedBorderColor,
  });

  @override
  Widget build(BuildContext context) {
    Widget pill = AppGlassSurface(
      variant: variant,
      radius: 999.0,
      width: width,
      height: height,
      padding: padding,
      margin: margin,
      tint: tint,
      isSelected: isSelected,
      selectedBorderColor: selectedBorderColor,
      child: child,
    );

    if (onTap != null) {
      pill = GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: pill,
      );
    }

    return pill;
  }
}

/// Interactive Liquid Glass Button with tactile spring compression (P5.7 Part D & P5.7.1)
class AppGlassButton extends StatefulWidget {
  final Widget icon;
  final VoidCallback? onTap;
  final String? tooltip;
  final double size;
  final AppGlassVariant variant;
  final bool isSelected;
  final Color? activeColor;
  final Color? tint;
  final EdgeInsetsGeometry? padding;
  final double? radius;

  const AppGlassButton({
    super.key,
    required this.icon,
    this.onTap,
    this.tooltip,
    this.size = 46.0,
    this.variant = AppGlassVariant.regular,
    this.isSelected = false,
    this.activeColor,
    this.tint,
    this.padding,
    this.radius,
  });

  @override
  State<AppGlassButton> createState() => _AppGlassButtonState();
}

class _AppGlassButtonState extends State<AppGlassButton> with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
      reverseDuration: const Duration(milliseconds: 220),
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.92).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic, reverseCurve: Curves.easeOutBack),
    );
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  void _handleTapDown(TapDownDetails _) {
    _animController.forward();
  }

  void _handleTapUp(TapUpDetails _) {
    _animController.reverse();
  }

  void _handleTapCancel() {
    _animController.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final r = widget.radius ?? (widget.size / 2);
    // Reduce Motion only disables scale animation, does NOT disable glass (P5.7.1 Part 6)
    final isReduceMotion = MediaQuery.disableAnimationsOf(context);

    Widget btn = GestureDetector(
      onTapDown: _handleTapDown,
      onTapUp: _handleTapUp,
      onTapCancel: _handleTapCancel,
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedBuilder(
        animation: _scaleAnimation,
        builder: (context, child) => Transform.scale(
          scale: isReduceMotion ? 1.0 : _scaleAnimation.value,
          child: child,
        ),
        child: AppGlassSurface(
          variant: widget.variant,
          radius: r,
          width: widget.size,
          height: widget.size,
          isSelected: widget.isSelected,
          selectedBorderColor: widget.activeColor,
          tint: widget.tint,
          padding: widget.padding ?? EdgeInsets.zero,
          child: Center(
            child: IconTheme(
              data: IconThemeData(
                color: widget.isSelected
                    ? (widget.activeColor ?? const Color(0xFF007AFF))
                    : (widget.variant == AppGlassVariant.danger
                        ? Colors.white
                        : (isDark ? Colors.white : const Color(0xFF1C1C1E))),
                size: 20,
              ),
              child: widget.icon,
            ),
          ),
        ),
      ),
    );

    if (widget.tooltip != null) {
      btn = Tooltip(message: widget.tooltip!, child: btn);
    }
    return btn;
  }
}

/// Unified Liquid Glass Toolbar grouping multiple controls with a single glass backdrop (P5.7 Part D & P5.7.1 Part 7)
class AppGlassToolbar extends StatelessWidget {
  final List<Widget> children;
  final Axis axis;
  final AppGlassVariant variant;
  final double radius;
  final double? width;
  final double? height;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final Color? tint;
  final String? groupId;

  const AppGlassToolbar({
    super.key,
    required this.children,
    this.axis = Axis.vertical,
    this.variant = AppGlassVariant.regular,
    this.radius = 24.0,
    this.width,
    this.height,
    this.padding = const EdgeInsets.all(4.0),
    this.margin,
    this.tint,
    this.groupId,
  });

  @override
  Widget build(BuildContext context) {
    return AppGlassSurface(
      groupId: groupId ?? 'right-toolbar',
      variant: variant,
      radius: radius,
      width: width,
      height: height,
      padding: padding,
      margin: margin,
      tint: tint,
      child: Flex(
        direction: axis,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }
}

/// Translucent subtle divider for AppGlassToolbar (P5.7 Part D)
class AppGlassToolbarDivider extends StatelessWidget {
  final Axis axis;
  const AppGlassToolbarDivider({super.key, this.axis = Axis.vertical});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: axis == Axis.vertical ? 28.0 : 0.8,
      height: axis == Axis.vertical ? 0.8 : 28.0,
      color: isDark ? Colors.white.withOpacity(0.15) : Colors.black.withOpacity(0.08),
    );
  }
}

/// Floating Liquid Glass Bottom Dock (P5.7 Part D)
class AppGlassBottomBar extends StatelessWidget {
  final Widget child;
  final AppGlassVariant variant;
  final double radius;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;

  const AppGlassBottomBar({
    super.key,
    required this.child,
    this.variant = AppGlassVariant.regular,
    this.radius = 28.0,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    this.margin,
  });

  @override
  Widget build(BuildContext context) {
    return AppGlassSurface(
      variant: variant,
      radius: radius,
      padding: padding,
      margin: margin,
      child: child,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Backwards compatibility layer for legacy components
// ─────────────────────────────────────────────────────────────────────────────

typedef NativeAdaptiveGlassSurface = AppGlassSurface;
typedef GlassSurface = AppGlassSurface;
typedef LiquidGlassContainer = AppGlassSurface;
typedef LiquidGlassCapsule = AppGlassPill;

class GlassAction extends StatefulWidget {
  final Widget icon;
  final VoidCallback? onTap;
  final String? tooltip;
  final double size;
  final bool isSelected;
  final Color? activeColor;
  final EdgeInsetsGeometry? padding;

  const GlassAction({
    super.key,
    required this.icon,
    this.onTap,
    this.tooltip,
    this.size = 44.0,
    this.isSelected = false,
    this.activeColor,
    this.padding,
  });

  @override
  State<GlassAction> createState() => _GlassActionState();
}

class _GlassActionState extends State<GlassAction> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final scale = (_isPressed && !reduceMotion) ? 0.94 : 1.0;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final selectedBg = widget.isSelected
        ? (widget.activeColor ?? const Color(0xFF007AFF)).withOpacity(0.18)
        : Colors.transparent;

    Widget btn = GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) => setState(() => _isPressed = false),
      onTapCancel: () => setState(() => _isPressed = false),
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        scale: scale,
        duration: const Duration(milliseconds: 90),
        curve: Curves.easeOutCubic,
        child: Container(
          width: widget.size,
          height: widget.size,
          padding: widget.padding ?? EdgeInsets.zero,
          decoration: BoxDecoration(
            color: selectedBg,
            shape: BoxShape.circle,
            boxShadow: widget.isSelected
                ? [
                    BoxShadow(
                      color: (widget.activeColor ?? const Color(0xFF007AFF)).withOpacity(0.30),
                      blurRadius: 8,
                      spreadRadius: 1,
                    )
                  ]
                : null,
          ),
          child: Center(
            child: IconTheme(
              data: IconThemeData(
                color: widget.isSelected
                    ? (widget.activeColor ?? const Color(0xFF007AFF))
                    : (isDark ? Colors.white : const Color(0xFF1C1C1E)),
                size: 20,
              ),
              child: widget.icon,
            ),
          ),
        ),
      ),
    );

    if (widget.tooltip != null) {
      btn = Tooltip(message: widget.tooltip!, child: btn);
    }
    return btn;
  }
}

class LiquidGlassButton extends StatelessWidget {
  final Widget icon;
  final VoidCallback? onTap;
  final String? tooltip;
  final double size;
  final double radius;
  final bool isSelected;
  final Color? activeGlowColor;
  final EdgeInsetsGeometry? padding;

  const LiquidGlassButton({
    super.key,
    required this.icon,
    this.onTap,
    this.tooltip,
    this.size = 46.0,
    this.radius = 23.0,
    this.isSelected = false,
    this.activeGlowColor,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    return AppGlassButton(
      icon: icon,
      onTap: onTap,
      tooltip: tooltip,
      size: size,
      radius: radius,
      isSelected: isSelected,
      activeColor: activeGlowColor,
      padding: padding,
    );
  }
}
