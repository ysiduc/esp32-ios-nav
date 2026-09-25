# Phase P6.10 Engineering Report: Liquid Glass Refinement & Right Toolbar Simplification

**Date**: 2026-09-25  
**Commit**: `feat(ui): refine liquid glass overlays and simplify right toolbar`  
**Repository**: `ysiduc/esp32-ios-nav`  
**Scope**: Frontend / UI presentation layer only. Zero backend or core navigation changes.  
**Test Suite Status**: 271/271 PASS (0 failures, 0 analyzer issues)

---

## 1. Executive Summary & Strict Constraints Compliance

In Phase P6.10, the application's floating UI presentation was refined to eliminate the opaque "white frosted slab" regression on large overlay sheets (search modal, side drawer, action sheets), harmonizing all surfaces with the successful clear Liquid Glass treatment achieved on the right toolbar and bottom search capsule in Image 1.

Additionally, the floating right-hand vertical toolbar was simplified from 4 controls down to exactly **2 buttons** (`Bản đồ` and `Điều hướng`), with the Map button launching a native-clear Apple Maps-inspired `Chế độ bản đồ` bottom sheet offering 4 card styles (`Khám phá`, `Lái xe`, `PT công cộng`, `Vệ tinh`).

### HARD RULES Compliance: Zero Core / Backend Modifications
- **Routing & Navigation Engines**: Valhalla primary, OSRM primary/secondary race, and fallback mechanisms remain 100% untouched.
- **BLE / WiFi / ESP32 Protocol**: Binary and JPEG streaming packets, telemetry framing, and ESP32 display commands remain untouched.
- **Saved Places & Geocoding**: Data models, SQLite / shared preferences persistence, and geocoding queries remain untouched.
- **Arrival Detection & Reroute Logic**: Two-stage state machine (suspected -> confirmed), 25m off-route threshold, and single source of truth arrival confirmation (distance <= 35m) remain untouched.
- **Map Camera Core**: Recenter logic (`_recenterToVehicle`, `_recenterToUser`), panning, and gesture recognizers remain identical.

---

## 2. Updated UI Surfaces & Visual Liquid Glass Treatment

### Root Cause of Image 2 & Image 3 Regressions
During earlier phases, base fills and card fills were configured with heavy opacities (e.g. `sheetFill: 0.80`, `drawerFill: 0.85`, `cardFill: 0.60`, and `searchSheetFieldFill: 0.85`). These opaque white fills occluded the background map and caused the drawer (Image 3) and search sheet (Image 2) to resemble flat, milky-white chalk slabs rather than real transparent Liquid Glass.

### P6.10 Visual Corrections (`MapOverlayGlassStyle` in `liquid_glass.dart`)
1. **Ultra-Low Body Tint (`0.05` dark / `0.08` light)**:
   - `toolbarFill`, `bottomSearchFill`, `drawerFill`, `sheetFill`, and `routeSheetFill` are unified under `clearGlassFill(isDark:)` (`0.08` light, `0.05` dark).
   - Eliminates all opaque white and dirty gray slabs, allowing the underlying vector map and terrain texture to bleed softly through all glass panels.
2. **Subtle Specular Edge Highlight (`0.5pt`, `0.35 - 0.40` white alpha)**:
   - Specular borders define the outer perimeter of the glass droplets without harsh or artificial multiple-gradient stacking.
3. **Internal Card & Field Refinement**:
   - `searchSheetFieldFill`: Reduced from `0.85` opaque slab to `0.18` light / `0.10` dark translucent glass with `0.5pt` white border.
   - `cardFill` / `drawerCardFill`: Reduced from `0.60` opaque white to `0.16` light / `0.08` dark subtle contrast fill with `0.5pt` highlight edge.
   - Quick place circle actions in search sheet updated to translucent blue glass (`Color(0xFF007AFF)` at `0.12 - 0.20` opacity).
   - Preserves high text contrast and legibility while ensuring the map behind remains visually present.
4. **Universal `AppGlassSurface` Clear Glass Foundation**:
   - Drawer, search modal sheet, incident report sheet, recent place action sheet, and saved place dialog sheet all adopt `AppGlassSurface(variant: AppGlassVariant.clear, overlayOwned: true)` with transparent modal barrier and background.

---

## 3. Right Toolbar Simplification (2 Buttons)

The floating right-hand vertical toolbar was redesigned into a compact, elegant capsule (`AppGlassToolbar`, width 48, radius 24) containing strictly **2 buttons**:

| Button | Key | Icon | Inactive State | Active State | Action |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **1. Bản đồ (Map)** | `toolbar_btn_map` | `Icons.map_rounded` | Dark neutral (`#1C1C1E`) | Apple Blue (`#007AFF`) | Opens `Chế độ bản đồ` bottom sheet |
| **Divider** | N/A | Thin line (`0.5pt`) | `#000000` (8% opacity) | `#000000` (8% opacity) | Subtle glass visual separator |
| **2. Điều hướng (Nav)** | `toolbar_btn_navigation` | `Icons.navigation_rounded` | Dark neutral (`#1C1C1E`) | Apple Blue (`#007AFF`) + tint | Recenters to vehicle (driving) or user |

**Removed Elements**:
- Compass heading button (`Icons.explore_rounded`) removed from floating toolbar.
- Vehicle transport mode switcher (`Icons.directions_car_rounded` / `Icons.two_wheeler_rounded`) removed from floating toolbar.

---

## 4. Map Style Chooser Bottom Sheet (`Chế độ bản đồ`)

Tapping `Bản đồ` opens an Apple Maps-inspired bottom sheet matching Image 5:
- **Header**:
  - Title: `Chế độ bản đồ` (bold, San Francisco typography, `#1C1C1E` / `#FFFFFF`).
  - Close button: Top-right circular capsule `(X)` with `0.5pt` specular border and tap dismissal.
- **Glass Base**:
  - Built with `AppGlassSurface(variant: AppGlassVariant.clear, overlayOwned: true)`.
  - Transparent barrier and background (`Colors.transparent`) so the vector map softly shows through behind the chooser.
- **4 Style Cards (Horizontal Row)**:
  1. `Khám phá` (`MapThemeMode.streets`): MapTiler streets-v2 vector style with pastel green/street thumbnail painter and `Icons.map_rounded`.
  2. `Lái xe` (`MapThemeMode.driving`): High-contrast night navigation vector style (`streets-v2-dark`) with dark road/blue route thumbnail painter and `Icons.directions_car_rounded`.
  3. `PT công cộng` (`MapThemeMode.transit`): Outdoor & public transit vector style (`outdoor-v2`) with orange/red transit track thumbnail painter and `Icons.directions_transit_rounded`.
  4. `Vệ tinh` (`MapThemeMode.satellite`): MapTiler hybrid satellite imagery style with aerial earth thumbnail painter and `Icons.satellite_alt_rounded`.
- **Selection State**:
  - Selected card receives a `2.5px` Apple Blue border (`#007AFF`), soft blue glow shadow, top-right blue checkmark badge, and bold blue label.
  - Tapping a card immediately switches the map style and updates ESP32 stream settings (`streamMapStyle`), while keeping the sheet responsive.

---

## 5. Automated Verification Results

- **Flutter Analyze**: `flutter analyze --no-fatal-infos` -> **0 issues found**.
- **Automated Test Suite**:
  - All 265 existing baseline tests passed.
  - 6 new automated tests in `test/liquid_glass_p610_test.dart` passed.
  - **Total**: **271 passed, 0 failed**.
- **Target App**: `ESP32Nav-Flutter-PRODUCTION.ipa`
