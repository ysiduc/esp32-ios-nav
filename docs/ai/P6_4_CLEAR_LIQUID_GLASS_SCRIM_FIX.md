# P6.4 Engineering Report: Remove Opaque Scrims & Make Drawer/Search True Clear Liquid Glass

**Date**: 2026-09-24  
**Author**: Antigravity AI Engineering Assistant  
**Repository**: `ysiduc/esp32-ios-nav`  
**Scope**: Presentation & Frontend UI Layer Only (**STRICTLY ZERO** backend, routing, BLE, or state machine changes)

---

## 1. Problem Statement & Root Cause Analysis

### The Visual Defect
Field testing following P6.3 revealed that while the right-side vertical toolbar achieved watery liquid glass refraction, the Drawer panel and Search modal sheet still exhibited a "frosted grey slab" / "milky panel" visual.

### Root Causes Identified Directly in Code:
1. **Unset `drawerScrimColor` in `HomeScreen`**: Flutter defaults `Scaffold.drawerScrimColor` to `Colors.black54`. When opening the drawer, the entire map surface was darkened, destroying the watery light bleed-through.
2. **Unset `barrierColor` in `showModalBottomSheet`**: Flutter defaults modal bottom sheet barrier to `Colors.black54`, dimming the map whenever search opened.
3. **Heavy `sheetFill` Opacity**: Drawer and search sheet root containers used `sheetFill` (`0.24 - 0.28`), creating a thick milky blanket.
4. **Opaque `secondaryFill` in Cards**: Inner drawer tiles and search cards used `secondaryFill` (`0.50` in light mode), making them look like solid white/grey blocks.
5. **Excessive Blur on Large Surfaces**: A single global blur of `sigma 26.0` on large surfaces (drawer and search sheet) dissolved all high-frequency street lines and textures into uniform grey mud.

---

## 2. Technical Architecture & Visual Solutions

### A. Total Elimination of Dimming Scrims
- **HomeScreen Scaffold**:
  ```dart
  Scaffold(
    drawerScrimColor: Colors.transparent,
    ...
  )
  ```
- **Search Modal**:
  ```dart
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.transparent,
    ...
  )
  ```
  Neither the drawer nor the search sheet applies dark scrims over the map. The map behind remains at full daylight / dark luminance.

### B. Differentiated Optical Blur Tokens
Rather than applying blur 26 everywhere, surface area dictates optical diffusion:
- **`MapOverlayGlassStyle.largeSurfaceBlur = 16.0`**: Used for large expanses (Drawer and Search Sheet). Softens map roads and labels without erasing their geometric forms.
- **`MapOverlayGlassStyle.capsuleBlur = 22.0`**: Used for compact controls (Right vertical toolbar and bottom search capsule). Delivers concentrated optical refraction.

### C. Ultra-Clear Watery Large Surface Gradient
For Drawer and Search Sheet backgrounds, `wateryLargeSurfaceGradient` provides an ultra-low opacity body:
- **Light Mode**:
  - Top: `Colors.white.withOpacity(0.10)`
  - Center: `Colors.white.withOpacity(0.055)` (94.5% transparent core!)
  - Bottom: `Colors.white.withOpacity(0.09)`
- **Dark Mode**:
  - Top: `0.15`
  - Center: `0.10`
  - Bottom: `0.14`

### D. Meniscus Curved Rim Gradient for Drawer
The drawer uses an outer refractive container with `drawerRimGradient` and 0.8pt padding:
- Specular highlight concentrated along top/right and bottom/right corners.
- Center right edge remains delicately subtle, producing a convex watery edge.

### E. Dedicated Clear Glass Card Tokens
- **`drawerCardFill`**: `0.12` (light) / `0.08` (dark) for unselected cards; `0.12` Apple blue tint for selected.
- **`drawerCardBorder`**: `0.25` stroke for unselected; `0.50` Apple blue for selected.
- **`searchSheetFieldFill`**: `0.16` (light) / `0.12` (dark) for search input header, paste link card, and recent searches card.

---

## 3. Modified Frontend Files List

1. **`mobile_app/lib/widgets/liquid_glass.dart`**:
   - Added `largeSurfaceBlur = 16.0` and `capsuleBlur = 22.0`.
   - Added `wateryLargeSurfaceGradient` (0.055 - 0.10 light).
   - Added `drawerRimGradient` (convex specular rim for drawer).
   - Added `drawerCardFill` and `drawerCardBorder` tokens (eliminating `secondaryFill 0.50`).
   - Added `searchSheetFieldFill` token (0.16 light / 0.12 dark).
   - Updated `WateryLiquidGlassCapsule` to use `capsuleBlur`.

2. **`mobile_app/lib/screens/home_screen.dart`**:
   - Set `Scaffold.drawerScrimColor: Colors.transparent`.
   - Replaced drawer root body with `drawerRimGradient` + `ClipRRect` + `largeSurfaceBlur` + `wateryLargeSurfaceGradient`.
   - Replaced connection card, footer card, and drawer tiles with `drawerCardFill` and `drawerCardBorder`.

3. **`mobile_app/lib/screens/map_screen.dart`**:
   - Set `showModalBottomSheet.barrierColor: Colors.transparent`.
   - Replaced search sheet root container with `specularRimGradient` + `ClipRRect` + `largeSurfaceBlur` + `wateryLargeSurfaceGradient`.
   - Replaced search header, close button, paste link card, and recent search cards with `searchSheetFieldFill`.
   - Wrapped `ListTile` in `Material(color: Colors.transparent)` to satisfy debug ink-splash assertions.

4. **`mobile_app/test/liquid_glass_p64_test.dart`** (New):
   - Verified `Scaffold.drawerScrimColor == Colors.transparent`.
   - Verified `showModalBottomSheet` `barrierColor == Colors.transparent` (ModalBarrier does not dim map).
   - Verified `drawer does not use sheetFill for root body`.
   - Verified `drawer cards do not use secondaryFill 0.50`.
   - Verified `largeSurfaceBlur < capsuleBlur`.

5. **`mobile_app/test/liquid_glass_p62_test.dart`**:
   - Updated blur expectation to `capsuleBlur = 22.0`.

---

## 4. Strict Confirmation of Zero Backend / Core Modifications

- **Zero changes** to Valhalla, OSRM, or routing engines.
- **Zero changes** to BLE services, MTU framing, or streaming services.
- **Zero changes** to navigation session manager, rerouting, or off-route detectors.
- **Zero changes** to ESP32 firmware C++ code.

---

## 5. Verification Results

- **Flutter Analyzer**: `0 issues found` (`flutter analyze`).
- **All Unit & Widget Tests**: `232 / 232 PASS` in 8s (`flutter test`).
- **P6.4 Dedicated Test Suite**: `5 / 5 PASS` (`liquid_glass_p64_test.dart`).
- **Live Routing Provider Smoke Test**: `PASS` (Valhalla HTTP 200 765ms, OSRM HTTP 200 625ms).
- **ESP32 Firmware Build**: `[SUCCESS] Took 5.59 seconds` (`pio run`).

---

## 6. Visual Acceptance Criteria Checklist

- [x] **No Scrim Dimming**: Background map is not dimmed when opening Drawer or Search Modal.
- [x] **Watery Drawer Body**: Map streets, parks, and rivers remain clearly identifiable behind the drawer.
- [x] **Differentiated Blur**: Large surfaces use `sigma 16.0`, compact capsules use `sigma 22.0`.
- [x] **Clear Glass Cards**: Cards inside drawer and sheet use `0.12 - 0.16` glass fills instead of `0.50` white slabs.
- [x] **Meniscus Rim Highlight**: Curved right edge of drawer and top edge of search sheet feature watery specular rim lighting.
