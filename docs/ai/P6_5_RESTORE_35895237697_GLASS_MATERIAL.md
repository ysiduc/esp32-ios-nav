# P6.5 — RESTORE EXACT LIQUID GLASS MATERIAL FROM RUN 35895237697

## 1. Executive Summary & Authoritative Reference
- **Authoritative Reference Run**: GitHub Actions CI Workflow Run `35895237697` (Flutter IPA build).
- **Authoritative Reference Commit**: `52cee9d3dc7e9b58a98f1060c0cc9b9d1a2954b6`.
- **Reference Component Pattern**: In commit `52cee9d3...`, `_buildRightSideGlassStack(...)` implemented the golden visual language:
  ```dart
  Container(
    width: 48,
    decoration: BoxDecoration(
      color: Colors.white.withOpacity(0.85),
      borderRadius: BorderRadius.circular(24),
      border: Border.all(
        color: Colors.white.withOpacity(0.70),
        width: 0.8,
      ),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(0.08),
          blurRadius: 16,
          offset: const Offset(0, 4),
        ),
      ],
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: ...
      ),
    ),
  )
  ```
- **Scope Boundary**: Strict frontend-only. Zero modifications to backend services, routing engines (Valhalla / OSRM), BLE communication protocol, firmware C++ codebase, or navigation lifecycle state machine.

---

## 2. Why P6.3 and P6.4 Diverged
1. **P6.3 Divergence**: Attempted simulated refractive optics using multiple nested watery gradients (`WateryLiquidGlassCapsule`, `wateryBodyGradient`, `specularRimGradient`) with ultra-low opacities (0.05–0.18). This created an unnatural dark grey or milky cast against real-world map tiles rather than the clean, crisp Apple Maps liquid glass feeling.
2. **P6.4 Divergence**: While correctly identifying and removing Flutter's dark modal/drawer scrims, P6.4 introduced large-surface low-opacity gradients (`wateryLargeSurfaceGradient` 0.055–0.10) and weakened blur to 16.0. This diluted the glass presence, making large surfaces feel like washed-out frosted panels rather than true physical liquid glass slabs.
3. **P6.5 Correction**: Completely discarded speculative watery gradient hacks for all key UI surfaces. Re-anchored the visual foundation to the proven, authoritative golden reference material from run `35895237697` with `fill: white 0.85`, `border: white 0.70 / 0.8pt`, `blur: 20`, and `shadow: black 0.08 / blur 16 / y=4`.

---

## 3. Shared Reference Component: `ReferenceGlassSurface`
Created `ReferenceGlassSurface` (`typedef AppleMapsReferenceGlass = ReferenceGlassSurface;`) in `mobile_app/lib/widgets/liquid_glass.dart`:
```dart
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
  ...
}
```
### Material Defaults:
- **Fill**: Light mode: `Colors.white.withOpacity(0.85)` / Dark mode: `Color(0xFF1E2638).withOpacity(0.85)`.
- **Border**: Light mode: `Border.all(color: Colors.white.withOpacity(0.70), width: 0.8)` / Dark mode: `Border.all(color: Colors.white.withOpacity(0.35), width: 0.8)`.
- **Backdrop Blur**: `sigmaX: 20.0, sigmaY: 20.0`.
- **Shadow**: `BoxShadow(color: Colors.black.withOpacity(isDark ? 0.20 : 0.08), blurRadius: 16, offset: Offset(0, 4))`.

---

## 4. Surfaces Migrated to Reference Language

### 1. Right-side Toolbar (`_buildRightSideGlassStack`)
- **Widget**: Replaced `WateryLiquidGlassCapsule` with `ReferenceGlassSurface`.
- **Geometry**: `width: 48, radius: 24, padding: EdgeInsets.symmetric(vertical: 4)`.
- **Material**: `fillColor: MapOverlayGlassStyle.toolbarFill` (`white 0.85`), `border: white 0.70 / 0.8pt`, `blur: 20.0`, `shadow: black 0.08 / blur 16`.
- **Dividers**: Restored run `35895237697` divider spec (`width: 26, height: 0.5, color: isDark ? Colors.white24 : Colors.black.withOpacity(0.08)`).
- **Icons & Logic**: 100% preserved.

### 2. Bottom Search Pill (`_buildAppleBottomSearchCapsule`)
- **Widget**: Replaced `WateryLiquidGlassCapsule` with `ReferenceGlassSurface`.
- **Geometry**: `height: 50, radius: 25, padding: EdgeInsets.symmetric(horizontal: 16)`.
- **Material**: `fillColor: MapOverlayGlassStyle.bottomSearchFill` (`white 0.88`), `border: white 0.70 / 0.8pt`, `blur: 20.0`, `shadow: black 0.08 / blur 16`.
- **Tap handler**: `onTap: _openAppleSearchModal` preserved.

### 3. Drawer (`_buildAppDrawer` in `home_screen.dart`)
- **Widget**: Root wrapped in `ReferenceGlassSurface`.
- **Geometry**: `borderRadius: BorderRadius.horizontal(right: Radius.circular(28))`.
- **Material**: `fillColor: MapOverlayGlassStyle.drawerFill` (`white 0.78`), `border: white 0.70 / 0.8pt`, `blur: 20.0`.
- **Drawer Cards**: Converted to secondary reference glass: `color: MapOverlayGlassStyle.drawerCardFill` (`white 0.60`), `border: white 0.55 / 0.8pt`. Selected: Apple blue tint (`Color(0xFF007AFF).withOpacity(0.14)`).
- **Scrim**: `Scaffold.drawerScrimColor: Colors.transparent` maintained.

### 4. Search Sheet (`_openAppleSearchModal`)
- **Widget**: Root of `DraggableScrollableSheet` builder uses `ReferenceGlassSurface`.
- **Geometry**: `borderRadius: BorderRadius.vertical(top: Radius.circular(26))`.
- **Material**: `fillColor: MapOverlayGlassStyle.sheetFill` (`white 0.80`), `border: white 0.70 / 0.8pt`, `blur: 20.0`, `shadow: black 0.10 / blur 26`.
- **Search Input Header**: `color: MapOverlayGlassStyle.searchSheetFieldFill` (`white 0.85`), `border: white 0.65 / 0.8pt`.
- **Close Button**: `color: MapOverlayGlassStyle.searchSheetFieldFill` (`white 0.85`), `border: white 0.65 / 0.8pt`.
- **Inner Cards** (Paste Card, Recent Searches Container, Guides Card): `color: MapOverlayGlassStyle.cardFill` (`white 0.60`), `border: white 0.55 / 0.8pt`.
- **Modal Barrier**: `barrierColor: Colors.transparent` maintained.

### 5. Route Directions Sheet (`_buildAppleRouteDirectionsSheet`)
- **Root Sheet**: Replaced solid white slab `Colors.white.withOpacity(0.96)` with `ReferenceGlassSurface`.
- **Geometry**: `width: double.infinity, borderRadius: BorderRadius.vertical(top: Radius.circular(26))`.
- **Material**: `fillColor: MapOverlayGlassStyle.routeSheetFill` (`white 0.80`), `border: white 0.70 / 0.8pt`, `blur: 20.0`, `shadow: black 0.10 / blur 28`.
- **Transport Selector Container**: `color: MapOverlayGlassStyle.cardFill` (`white 0.60`), `border: white 0.55 / 0.8pt`.
- **Transport Button Selected**: `Colors.white.withOpacity(0.85)` with subtle shadow.
- **Waypoints List Card**: `color: MapOverlayGlassStyle.cardFill` (`white 0.60`), `border: white 0.55 / 0.8pt`.
- **Multi-route Choice Chips**: `color: MapOverlayGlassStyle.cardFill` (`white 0.60`), `border: white 0.55 / 0.8pt` (selected: `Color(0xFF007AFF)`).
- **Bottom Route Action Card**: `color: MapOverlayGlassStyle.cardFill` (`white 0.60`), `border: white 0.55 / 0.8pt`.

---

## 5. Verification & Test Evidence

### 1. Dedicated Test Suite: `mobile_app/test/liquid_glass_p65_test.dart`
All 5 comprehensive test groups pass:
- Reference blur == 20.0
- Reference toolbar fill opacity == 0.85
- Border opacity == 0.70 and width == 0.8
- Bottom search fill opacity == 0.88
- Drawer fill opacity == 0.78
- Search sheet fill opacity == 0.80
- Route sheet no longer uses white 0.96 (uses `routeSheetFill` 0.80)
- Right toolbar and bottom search capsule use `ReferenceGlassSurface`, NOT `WateryLiquidGlassCapsule`
- Drawer uses `ReferenceGlassSurface`
- Search sheet uses `ReferenceGlassSurface`

### 2. Full Suite Regression Test
- `flutter analyze`: **0 issues** found.
- `flutter test`: **237 of 237 tests pass** (100% pass rate).
- PlatformIO ESP32 firmware build: **SUCCESS** (RAM: 41.3%, Flash: 35.9%).

---

## 6. Visual Field Verification Status
- **Automated**: Code decoration, widget trees, opacities, and blur sigmas verified via automated unit and widget tests.
- **Manual Verification**: Field comparison with physical IPA screenshots from workflow run `35895237697` is pending user visual review.
