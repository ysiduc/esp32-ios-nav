# P6.6 — CONVERT UI FROM OPAQUE WHITE PANELS TO TRUE FROSTED LIQUID GLASS

## 1. Executive Summary & Root Cause Analysis
- **Problem Statement**:
  Previous iterations mistakenly treated liquid glass as opaque rounded white panels (`white.withOpacity(0.80 ~ 0.88)` and solid `0.96`), creating the visual sensation of a solid white plastic box placed over the map. The map beneath was blocked out, and true optical glass translucency was lost.
- **Reference Target**:
  User reference Image 1 (vertical toolbar over map):
  - True translucent frosted glass through which the map underneath (roads, rivers, terrain labels) is clearly visible.
  - Authentic optical background blur via GPU `BackdropFilter`.
  - Soft light specular border (`white.withOpacity(0.30 ~ 0.45)`).
  - Subtle highlight glint and curved inner meniscus rim ("giọt nước" droplet curved edge effect).
- **Scope Boundary**:
  **Strict Frontend-Only**. Zero modifications to routing engines (Valhalla / OSRM), navigation state machine, BLE / ESP32 firmware, or backend search services.

---

## 2. Universal Reusable Architecture: `TrueLiquidGlass`
Created `TrueLiquidGlass` (with aliases `AppleStyleLiquidGlass`, `AppleMapsReferenceGlass`, `ReferenceGlassSurface`) in `mobile_app/lib/widgets/liquid_glass.dart` following the strict multi-layer composition:

```dart
ClipRRect(
  borderRadius: effectiveRadius,
  child: Stack(
    children: [
      // Layer 1: True BackdropFilter optical blur of the real map underneath
      Positioned.fill(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
          child: Container(color: Colors.transparent),
        ),
      ),
      // Layer 2: Translucent Liquid Glass Base Tint (0.10 ~ 0.18) + subtle angled sheen gradient
      Positioned.fill(
        child: Container(
          decoration: BoxDecoration(
            color: effectiveFill,
            gradient: effectiveFillGradient,
          ),
        ),
      ),
      // Layer 3: Specular Highlight Glint Layer (top-left to bottom-right sheen)
      if (showHighlight)
        Positioned.fill(
          child: IgnorePointer(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.white.withOpacity(0.20),
                    Colors.transparent,
                    Colors.white.withOpacity(0.06),
                  ],
                  stops: const [0.0, 0.4, 1.0],
                ),
              ),
            ),
          ),
        ),
      // Layer 4: Inner Meniscus Rim / Curved Refractive Edge ("giọt nước" droplet look)
      if (showInnerRim)
        Positioned.fill(
          child: IgnorePointer(
            child: Container(
              margin: const EdgeInsets.all(0.8),
              decoration: BoxDecoration(
                borderRadius: effectiveRadius,
                border: Border.all(
                  color: isDark ? Colors.white.withOpacity(0.10) : Colors.white.withOpacity(0.18),
                  width: 0.6,
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
)
```

---

## 3. Physical Parameters & Design Tokens

| Property | P6.6 Specification | Value in Code |
| :--- | :--- | :--- |
| **Base Fill (Toolbar)** | Translucent white `0.10 ~ 0.18` | `Colors.white.withOpacity(0.14)` (Light) / `0.24` (Dark) |
| **Base Fill (Search Pill)** | Translucent white `0.10 ~ 0.18` | `Colors.white.withOpacity(0.15)` (Light) / `0.24` (Dark) |
| **Base Fill (Drawer & Sheets)** | Translucent white `0.10 ~ 0.18` | `Colors.white.withOpacity(0.16)` (Light) / `0.24` (Dark) |
| **Backdrop Blur** | `sigmaX: 24 ~ 32, sigmaY: 24 ~ 32` | `sigma: 28.0` |
| **Outer Border** | Soft specular `white 0.30 ~ 0.45` | `Border.all(color: white 0.38, width: 0.9)` |
| **Floating Shadow** | Very soft `black 0.06 ~ 0.10`, blur `18 ~ 26` | `BoxShadow(color: black 0.08, blurRadius: 22, offset: (0, 6))` |
| **Highlight Sheen** | Angled linear gradient | `white 0.22` (top-left) to `white 0.08` (bottom-right) |
| **Inner Rim** | Meniscus droplet contour | `Border.all(color: white 0.18, width: 0.6)` |
| **Card Fill** | Soft glass card | `Colors.white.withOpacity(0.12)` / `Color(0xFF007AFF).withOpacity(0.16)` (selected) |

---

## 4. Components Migrated to True Frosted Liquid Glass

1. **Right Vertical Toolbar (`_buildRightSideGlassStack`)**:
   - Converted to `TrueLiquidGlass(width: 48, radius: 24, blurSigma: 28.0)`.
   - Translucent `white 0.14` background allows real map roads, river, and labels underneath to clearly refract through.
   - Restored subtle divider lines: `Colors.black.withOpacity(0.06)` / `Colors.white.withOpacity(0.12)`.
   - All high-contrast icons (layers, north compass, transport switch, recenter) remain sharp and responsive.

2. **Bottom Search Capsule (`_buildAppleBottomSearchCapsule`)**:
   - Converted to `TrueLiquidGlass(height: 50, radius: 25, blurSigma: 28.0)`.
   - Translucent `white 0.15` glass pill floating cleanly over map tiles.
   - Text color and icon colors adjusted for maximum legibility over frosted map backgrounds.

3. **Search Sheet / Search Panel (`_openAppleSearchModal`)**:
   - Root `DraggableScrollableSheet` builder uses `TrueLiquidGlass(top radius: 26, blurSigma: 28.0)`.
   - Search input header & Close button converted to `MapOverlayGlassStyle.searchSheetFieldFill` (`white 0.16`) with crisp `0.38 / 0.9pt` borders.
   - Search query results: each item wrapped in a subtle translucent glass card (`white 0.12` with `white 0.28` border).
   - Saved custom place name priority preserved and rendered with bold, high-contrast typography.

4. **Place Inspector Sheet (`_buildApplePlaceInspectorSheet`)**:
   - Replaced solid white container (`white.withOpacity(0.96)`) with `TrueLiquidGlass(top radius: 26, blurSigma: 28.0)`.
   - Fixed place title to resolve `effectiveName` (`_getEffectivePlaceName(place)`), preventing saved custom names from being lost.

5. **Route Directions Sheet (`_buildAppleRouteDirectionsSheet`)**:
   - Replaced solid card with `TrueLiquidGlass(top radius: 26, blurSigma: 28.0)`.
   - Inner transport mode selector, waypoints card, multi-route comparison chips, and route action card converted to soft glass cards.
   - Action button "ĐI" retains high-energy green accent (`#34C759`) while surrounding panel remains translucent glass.

6. **Drawer / Side Panel (`_buildAppDrawer` in `home_screen.dart`)**:
   - Converted to `TrueLiquidGlass(right radius: 28, blurSigma: 28.0)`.
   - Preserved `Scaffold.drawerScrimColor: Colors.transparent` so map behind drawer is not darkened by default modal scrims.
   - Drawer cards and tiles use `MapOverlayGlassStyle.drawerCardFill(isDark: isDark)` with high-contrast text.

---

## 5. Automated Verification Evidence
- **Dedicated Test Suite**: `mobile_app/test/liquid_glass_p66_test.dart` (6 passed).
- **Regression Tests**: `liquid_glass_p65_test.dart`, `liquid_glass_p64_test.dart`, `liquid_glass_p62_test.dart` all pass.
- **Full Test Suite**: **243 of 243 tests PASS** (100% pass rate).
- **Dart Analyzer**: **0 issues** found (`flutter analyze` clean).
- **ESP32 Firmware**: PlatformIO build succeeds (RAM: 41.3%, Flash: 35.9%).
