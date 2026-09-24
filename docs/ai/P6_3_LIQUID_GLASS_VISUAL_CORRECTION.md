# P6.3 Engineering Report: Frontend-Only Liquid Glass Visual Correction

**Date**: 2026-09-24  
**Author**: Antigravity AI Engineering Assistant  
**Repository**: `ysiduc/esp32-ios-nav`  
**Scope**: Presentation & Frontend UI Only (**STRICTLY ZERO** backend, routing, BLE, or state machine changes)

---

## 1. Problem Statement & Reference Realignment

### The Visual Defect (Reject Visual)
In previous iterations, the right vertical toolbar and bottom pill presented as:
- An opaque, milky-white / light-grey blocky card
- Opacity too high (`0.38 - 0.80`), completely obscuring streets, rivers, and terrain behind the glass
- Harsh flat border strokes rather than optical liquid reflections
- No sense of watery curvature or meniscus refraction

### The Authoritative Reference (Target Visual: Image 4)
The reference screenshot (Image 4) demonstrates true Apple Maps Liquid Glass:
1. **Translucent Watery Body**: The map features (orange highways, blue lakes, road grids) remain distinctly visible through the glass capsule.
2. **Refractive Edge / Meniscus Gradient**: Specular light catches the curved edges (0.8pt outer highlight), mimicking a curved droplet of water.
3. **Deep Optical Blur**: High backdrop diffusion (`sigma: 26.0`) softens underlying high-frequency map text and lines without creating a solid milk panel.
4. **Single Continuous Capsule**: All controls in the right-side vertical toolbar reside within **exactly one** uninterrupted capsule surface; button dividers are ultra-faint hairlines (`0.05` opacity).
5. **Soft Ambient Shadow**: Minimal diffuse shadow (`blurRadius: 20`, opacity `0.06 - 0.20`) giving subtle elevation off the map plane without harsh drop artifacts.

---

## 2. Technical Architecture & Visual Specifications

### A. Multi-Layer Optical Surface Tokens (`liquid_glass.dart`)
All glass surfaces are consolidated under `MapOverlayGlassStyle`:

- **Backdrop Blur**: `sigma = 26.0` (smooth optical background dispersion).
- **Watery Fill Opacity Range**:
  - Right vertical toolbar: `0.14` (light) / `0.18` (dark) (core watery translucency).
  - Bottom search capsule: `0.18` (light) / `0.22` (dark) (wider, soft pill).
  - Full search sheet & Drawer: `0.24` (light) / `0.28` (dark) (readable background).
- **Specular Rim Gradient (`specularRimGradient`)**:
  - Light mode: `[white 85%, white 35%, white 20%, white 60%]` along diagonal `[0.0, 0.35, 0.70, 1.0]`.
  - Dark mode: `[white 42%, white 12%, white 6%, white 22%]`.
  - Replaces flat single-stroke borders with natural refractive rim lighting.
- **Watery Body Convex Gradient (`wateryBodyGradient`)**:
  - Vertical 3-stop gradient simulating convex lens curvature: `[white 22%, white 11%, white 18%]`.
- **Soft Ambient Diffuse Shadow (`softShadow`)**:
  - Offset `(0, 4)`, blur `20.0`, opacity `0.06` (light) / `0.20` (dark).

### B. `WateryLiquidGlassCapsule` Component
A dedicated widget encapsulates the complete optical stack:
```dart
Container(
  decoration: BoxDecoration(
    borderRadius: BorderRadius.circular(radius),
    gradient: MapOverlayGlassStyle.specularRimGradient(isDark: isDark),
    boxShadow: MapOverlayGlassStyle.softShadow(isDark: isDark),
  ),
  padding: const EdgeInsets.all(0.8), // 0.8pt refractive edge rim
  child: ClipRRect(
    borderRadius: BorderRadius.circular(radius - 0.8),
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 26.0, sigmaY: 26.0),
      child: Container(
        decoration: BoxDecoration(
          gradient: MapOverlayGlassStyle.wateryBodyGradient(isDark: isDark),
          borderRadius: BorderRadius.circular(radius - 0.8),
        ),
        child: child,
      ),
    ),
  ),
)
```

---

## 3. Surface Harmonization Across 3 Key Zones

| Zone | Component | Fill Opacity | Border / Rim | Shadow | Blur Sigma |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Zone 1: Right Toolbar** | `_buildRightSideGlassStack` | `0.14` light / `0.18` dark | 0.8pt Specular Rim Gradient | Ambient `blur: 20` | `26.0` |
| **Zone 2: Bottom Search** | `_buildAppleBottomSearchCapsule` | `0.18` light / `0.22` dark | 0.8pt Specular Rim Gradient | Ambient `blur: 20` | `26.0` |
| **Zone 3: Search Sheet / Drawer** | `_openAppleSearchModal` / `Drawer` | `0.24` light / `0.28` dark | 0.8pt Top/Side Specular Stroke | Sheet `blur: 28` | `26.0` |

---

## 4. Modified Frontend Files List

1. **`mobile_app/lib/widgets/liquid_glass.dart`**:
   - Added `blurSigma = 26.0`.
   - Refined `fill`, `searchBarFill`, `sheetFill`, `secondaryFill` for watery translucency (`0.10–0.28`).
   - Introduced `specularRimGradient`, `wateryBodyGradient`, `softShadow`.
   - Created `WateryLiquidGlassCapsule` continuous widget.
   - Updated `AppleGlassTokens` (`fillToolbar = 0.14`, `fillSheet = 0.24`, `fillSearchField = 0.50`).

2. **`mobile_app/lib/screens/map_screen.dart`**:
   - Updated `_buildRightSideGlassStack` to render inside single `WateryLiquidGlassCapsule` with `0.05` opacity hairline dividers.
   - Updated `_buildAppleBottomSearchCapsule` to use `WateryLiquidGlassCapsule(height: 50, radius: 25)`.
   - Updated `_openAppleSearchModal` sheet background to `MapOverlayGlassStyle.sheetFill(isDark: isDark)` with top specular border.

3. **`mobile_app/lib/screens/home_screen.dart`**:
   - Updated drawer panel background to `MapOverlayGlassStyle.sheetFill(isDark: isDark)` with right specular border and diffuse shadow.

4. **`mobile_app/test/liquid_glass_p62_test.dart`**:
   - Updated test assertions to check P6.3 watery thresholds (`blurSigma = 26.0`, `lightFill = 0.14`, `darkFill = 0.18`).

5. **`mobile_app/test/liquid_glass_test.dart`**:
   - Updated test assertions to check P6.3 token specifications (`fillToolbar = 0.14`, `fillSheet = 0.24`).

---

## 5. Strict Confirmation of Zero Backend / Core Modifications

- **Zero changes** to Valhalla, OSRM, or routing pipeline (`routing_pipeline.dart`).
- **Zero changes** to BLE protocol, MTU, or packet framing (`ble_service.dart`, `esp_stream_service.dart`).
- **Zero changes** to navigation state machine or reroute logic (`navigation_session_manager.dart`, `off_route_detector.dart`, `reroute_manager.dart`).
- **Zero changes** to ESP32 firmware C++ code (`main.cpp`, `ancs_service.h`, `ams_service.h`).

---

## 6. Verification Results

- **Flutter Analyzer**: `0 issues found` (`flutter analyze`).
- **Unit & Widget Test Suite**: `227 / 227 PASS` in 8s (`flutter test`).
- **Routing Smoke Test**: `PASS` (Valhalla HTTP 200 774ms, OSRM HTTP 200 633ms).
- **Firmware Compilation**: `[SUCCESS] Took 4.68 seconds` (`pio run`).

---

## 7. Visual Artifacts Checklist

- [x] **Right Vertical Toolbar**: Refractive 4-button capsule with translucent core and 0.8pt rim highlight (`p63_toolbar_preview.png`).
- [x] **Map + Bottom Search Pill**: Translucent pill with underlying highway and roads visibly passing through (`p63_map_and_capsules.png`).
- [x] **Full Search Sheet**: Watery background with top specular highlight, translucent search field, and pastel quick-place icons (`p63_search_sheet_preview.png`).
