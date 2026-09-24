# P6.7 — CLEAR-CORE LIQUID GLASS, FRONTEND ONLY

## 1. Executive Summary & Root Cause Analysis
- **Problem Diagnosis**:
  In P6.6, dark map mode rendered surfaces as a dark smoky/navy slab, and details under the glass (roads, buildings, rivers, labels) were smudged out.
- **Root Causes**:
  1. **Dark Navy Tint on Dark Map**: Dark surfaces used `#1E2638 @ 24%` (`Color(0xFF1E2638).withOpacity(0.24)`). Because the map background in dark mode is already dark, adding a 24% navy paint layer turned the glass into an opaque dark slab.
  2. **Automatic Body Gradient Stacking**: `TrueLiquidGlass` automatically generated and layered a full-body `fillGradient` across the center of the surface even when a `fillColor` was passed.
  3. **Full-Body Highlight Gradient**: The specular highlight covered the entire surface rather than concentrating at the edges.
  4. **Excessive Blur (28.0)**: Optical blur of 28.0 merged fine road lines, building footprints, and map typography into an unrecognizable blur.
- **Core Principle ("Clear Core")**:
  - **Center (~70%)**: Almost clear, ultra-low neutral tint (`0.04 ~ 0.10`), no navy tint, gentle blur (`13.0 ~ 15.0`), allowing building contours, road directions, and river colors to be clearly visible through the glass.
  - **Edges**: Clearly defined glass refraction with a crisp specular border (`white 0.32 ~ 0.45, 0.7pt`), corner glints, and a subtle inner meniscus rim (`0.08 ~ 0.12, 0.5pt`).
- **Scope Boundary**:
  **Strict Frontend-Only**. Zero modifications to `NavigationManager`, Valhalla/OSRM routing, BLE/ESP32 firmware, or navigation state machines.

---

## 2. Quantitative Formula Changes

| Surface / Parameter | P6.6 (Flawed) | P6.7 Clear-Core (Corrected) | Rationale |
| :--- | :--- | :--- | :--- |
| **Dark Toolbar Fill** | `#1E2638 @ 24%` | `Colors.white.withOpacity(0.055)` | Eliminates dark navy slab; dark map already dark |
| **Light Toolbar Fill** | `Colors.white @ 14%` | `Colors.white.withOpacity(0.09)` | Clear translucent core |
| **Dark Bottom Search** | `#1E2638 @ 24%` | `Colors.white.withOpacity(0.06)` | Clear neutral floating pill |
| **Light Bottom Search** | `Colors.white @ 15%` | `Colors.white.withOpacity(0.10)` | Clear neutral floating pill |
| **Dark Drawer Fill** | `#1E2638 @ 24%` | `Colors.white.withOpacity(0.04)` | Ultra-light large surface sheet |
| **Light Drawer Fill** | `Colors.white @ 16%` | `Colors.white.withOpacity(0.08)` | Ultra-light large surface sheet |
| **Dark Search Sheet** | `#1E2638 @ 24%` | `Colors.white.withOpacity(0.045)` | Transparent sheet over map |
| **Light Search Sheet** | `Colors.white @ 16%` | `Colors.white.withOpacity(0.085)` | Transparent sheet over map |
| **Dark Route Sheet** | `#1E2638 @ 24%` | `Colors.white.withOpacity(0.05)` | Transparent route comparison sheet |
| **Light Route Sheet** | `Colors.white @ 16%` | `Colors.white.withOpacity(0.09)` | Transparent route comparison sheet |
| **Toolbar Blur** | `28.0` | `15.0` (`toolbarBlur`) | Preserves road shapes & buildings |
| **Large Surface Blur** | `28.0` | `13.0` (`largeSurfaceBlur`) | Prevents grey fog over large sheets |
| **Body Gradient** | Auto-stacked | `null` by default | No unwanted whole-body gradient overlay |
| **Highlight Gradient** | Full-body | Edge-only (`stops: [0.0, 0.12, 0.82, 1.0]`) | Center ~70% surface is completely clear |
| **Outer Border** | `0.38 / 0.9pt` | Dark `0.32`, Light `0.45` / `0.7pt` | Thinner, crisper edge definition |
| **Inner Meniscus Rim** | `0.18 / 0.6pt` | Dark `0.08`, Light `0.12` / `0.5pt` | Subtle droplet refraction rim |
| **Dark Shadow** | `black 0.20 / blur 22` | `black 0.08 / blur 16 / y=4` | Soft floating shadow, no heavy black halo |

---

## 3. Component Architecture Updates in `liquid_glass.dart`

```dart
class TrueLiquidGlass extends StatelessWidget {
  ...
  @override
  Widget build(BuildContext context) {
    ...
    return Container(
      decoration: BoxDecoration(
        borderRadius: effectiveRadius,
        boxShadow: effectiveShadow, // dark 0.08 blur 16; light 0.05 blur 14
      ),
      child: ClipRRect(
        borderRadius: effectiveRadius,
        child: Stack(
          children: [
            // 1. Gentle optical blur (13 ~ 15)
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
                child: Container(color: Colors.transparent),
              ),
            ),
            // 2. Clear-core neutral fill (0.04 ~ 0.10) with NO automatic body gradient
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: effectiveFill,
                  gradient: bodyGradient, // null by default
                ),
              ),
            ),
            // 3. Edge-only highlight (center ~70% completely transparent)
            if (showHighlight)
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          white.withOpacity(isDark ? 0.14 : 0.18),
                          Colors.transparent,
                          Colors.transparent,
                          white.withOpacity(isDark ? 0.04 : 0.05),
                        ],
                        stops: const [0.0, 0.12, 0.82, 1.0],
                      ),
                    ),
                  ),
                ),
              ),
            // 4. Subtle inner rim (0.08 ~ 0.12, 0.5pt)
            ...
            // 5. Crisp outer border (0.32 ~ 0.45, 0.7pt)
            ...
            // 6. Child content
          ],
        ),
      ),
    );
  }
}
```

---

## 4. Surfaces Migrated to Clear-Core
1. **Right Vertical Toolbar (`_buildRightSideGlassStack`)**:
   - `blurSigma: MapOverlayGlassStyle.toolbarBlur` (`15.0`).
   - `fillColor: MapOverlayGlassStyle.toolbarFill` (`dark 0.055, light 0.09`).
   - `bodyGradient: null`.
   - Result: Roads, building contours, and rivers are directly identifiable beneath the toolbar.
2. **Bottom Search Bar (`_buildAppleBottomSearchCapsule`)**:
   - `blurSigma: MapOverlayGlassStyle.bottomSearchBlur` (`15.0`).
   - `fillColor: MapOverlayGlassStyle.bottomSearchFill` (`dark 0.06, light 0.10`).
   - Text/icon contrast remains sharp and clear.
3. **Drawer (`_buildAppDrawer` in `home_screen.dart`)**:
   - `blurSigma: MapOverlayGlassStyle.largeSurfaceBlur` (`13.0`).
   - `fillColor: MapOverlayGlassStyle.drawerFill` (`dark 0.04, light 0.08`).
4. **Search Sheet (`_openAppleSearchModal`)**:
   - `blurSigma: MapOverlayGlassStyle.largeSurfaceBlur` (`13.0`).
   - `fillColor: MapOverlayGlassStyle.sheetFill` (`dark 0.045, light 0.085`).
   - Search field: `0.12 ~ 0.16` for input legibility.
5. **Route Directions Sheet (`_buildAppleRouteDirectionsSheet`)**:
   - `blurSigma: MapOverlayGlassStyle.largeSurfaceBlur` (`13.0`).
   - `fillColor: MapOverlayGlassStyle.routeSheetFill` (`dark 0.05, light 0.09`).
   - Action button "ĐI" preserved with vibrant Apple Maps green (`#34C759`).

---

## 5. Automated Verification Evidence
- **Dedicated Test Suite**: `mobile_app/test/liquid_glass_p67_test.dart` (7 of 7 passed):
  - `✓` dark toolbar does NOT use navy fill
  - `✓` dark toolbar body opacity <= 0.07 (`0.055`)
  - `✓` toolbar blur <= 16 (`15.0`)
  - `✓` large surface blur <= 14 (`13.0`)
  - `✓` dark shadow opacity <= 0.10 (`0.08`)
  - `✓` `TrueLiquidGlass` does not auto-apply body gradient when none supplied
  - `✓` Right toolbar and bottom search render clear-core glass
  - `✓` Drawer and Search Modal use `largeSurfaceBlur` (<= 14)
- **Full Test Suite Regression**: **250 of 250 tests PASS** (100% pass rate).
- **Dart Analyzer**: **0 issues** found (`flutter analyze` clean).
- **ESP32 Firmware**: PlatformIO build succeeds (RAM: 41.3%, Flash: 35.9%).
