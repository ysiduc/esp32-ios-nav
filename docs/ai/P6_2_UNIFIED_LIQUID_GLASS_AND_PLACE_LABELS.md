# P6.2 Engineering Report: Unified Real Liquid Glass Material + Search Color & Place Label Fix

**Date**: 2026-09-24  
**Author**: Antigravity AI Engineering Assistant  
**Repository**: `ysiduc/esp32-ios-nav`  
**Scope**: Presentation & UI/UX Layer Only (**STRICTLY ZERO** backend, routing, BLE, or state machine changes)

---

## 1. Context & P6.1 Misunderstanding Resolution

In Phase P6.1, background fills were customized individually across different surfaces:
- Right toolbar: `fillToolbar` (`Colors.white.withOpacity(0.80)`)
- Bottom sheet: `fillSheet` (`Color(0xFFF2F2F7).withOpacity(0.95)`)
- Search field: `fillSearchField` (`Colors.white.withOpacity(0.92)`)
- Drawer panel: `AppColors.surfaceSecondary` (solid opaque white)

This fragmented approach caused the drawer to resemble a solid white slab (User Image 1) and the search sheet to look like an opaque grey panel (User Image 2), while the toolbar appeared over-saturated and disconnected.

### Authoritative Target: Reference Image 4
Reference Image 4 is established as the sole authoritative visual reference:
1. **Map visible through glass body**: Road lines, water surfaces, and topographic textures bleed naturally through the frosted material.
2. **Milky diffusion**: Balanced `blurSigma: 24.0` with delicate frosted light dispersion.
3. **No opaque white or dirty grey**: Balanced translucent base (`0.30–0.45` light milky white, `0.20–0.35` dark neutral/navy).
4. **Specular edge**: Ultra-thin `0.5pt` white highlight border (`opacity 0.60` light, `0.35` dark).
5. **Soft diffuse shadow**: Ambient blur `20.0` with `0.08–0.28` opacity, eliminating harsh solid drops.

---

## 2. Architecture: One Shared Glass Material Token

Rather than creating divergent fills per screen, Phase P6.2 unifies all map overlay surfaces into **`MapOverlayGlassStyle`** in `liquid_glass.dart`:

```dart
class MapOverlayGlassStyle {
  static const double blurSigma = 24.0;
  static double blur({bool isDark = false}) => blurSigma;

  static Color fill({required bool isDark, double opacityFactor = 1.0}) {
    if (isDark) {
      return const Color(0xFF161B26).withOpacity(0.30 * opacityFactor);
    } else {
      return Colors.white.withOpacity(0.38 * opacityFactor);
    }
  }

  static Color secondaryFill({required bool isDark}) {
    if (isDark) {
      return Colors.white.withOpacity(0.12);
    } else {
      return Colors.white.withOpacity(0.68);
    }
  }

  static Border border({required bool isDark, double width = 0.5}) {
    if (isDark) {
      return Border.all(color: Colors.white.withOpacity(0.35), width: width);
    } else {
      return Border.all(color: Colors.white.withOpacity(0.60), width: width);
    }
  }

  static List<BoxShadow> shadow({required bool isDark}) {
    return [
      BoxShadow(
        color: Colors.black.withOpacity(isDark ? 0.28 : 0.08),
        blurRadius: 20.0,
        offset: const Offset(0, 4),
      ),
    ];
  }

  static BoxDecoration decoration({...}) => ...
}
```

All 4 primary surfaces share this exact token:
- **Drawer** (`home_screen.dart`): `ClipRRect(radius: 28)` + `BackdropFilter(blur: 24)` + `MapOverlayGlassStyle.decoration`
- **Search Sheet** (`map_screen.dart`): `ClipRRect(radius: 24)` + `BackdropFilter(blur: 24)` + `MapOverlayGlassStyle.decoration`
- **Right Toolbar** (`map_screen.dart`): `ClipRRect(radius: 24)` + `BackdropFilter(blur: 24)` + `MapOverlayGlassStyle.decoration`
- **Bottom Search Capsule** (`map_screen.dart`): `ClipRRect(radius: 25)` + `BackdropFilter(blur: 24)` + `MapOverlayGlassStyle.decoration`

---

## 3. Dark & Light Map Mode Adaptation

When running on dark maps (Night mode, Minimal dark, Satellite):
- Glass base transitions to a dark neutral/navy translucent body (`Color(0xFF161B26)` at `~0.30` opacity).
- Specular edge remains crisp white (`0.35` opacity) to cleanly delineate glass bounds against dark map asphalt.
- Text, search icons, mic icon, and dividers dynamically switch to Apple system high-contrast dark palette (`Colors.white`, `Colors.white70`, `Colors.white24`).
- No harsh white glare or opaque blinding panels.

When running on light maps (Streets v2):
- Transitions to milky translucent white (`Colors.white` at `0.38` opacity), exactly reproducing Image 4.

---

## 4. Full Search View Palette Redesign (Image 5 Fix)

Image 5 previously exhibited monotonous, muddy brown circular avatars (`#B8835C`) for all recent search entries. 

### Semantic Pastel System (`_buildRecentPlaceAvatar`):
- **Home**: Soft pastel blue (`#E5F1FF` / `#007AFF 30%` dark) with `Icons.home_rounded`
- **Work / Office**: Pastel indigo (`#EEEEFF` / `#5E5CE6 30%` dark) with `Icons.work_rounded`
- **Bank / ATM**: Pastel mint green (`#E8F8EE` / `#34C759 30%` dark) with `Icons.account_balance_rounded`
- **School / Education**: Pastel azure (`#E5F7FF` / `#32ADE6 30%` dark) with `Icons.school_rounded`
- **Shopping / Mart**: Pastel warm orange (`#FFF4E5` / `#FF9500 30%` dark) with `Icons.shopping_bag_rounded`
- **Custom Saved / Favorites**: Pale blue with star badge
- **Standard History**: Refined neutral translucent grey (`#E5E5EA` / `white 12%` dark) with `Icons.pin_drop_rounded`

### Clear Separation of "Địa điểm" vs "Gần đây":
- **"Địa điểm"**: Reserved strictly for quick saved destinations (Home, Work, Custom pinned).
- **"Gần đây"**: Dedicated search history list with individual management ("Xóa tất cả", option sheets).

---

## 5. Destination Marker Name Label & Custom Name Precedence

### A. Selected Marker On Map
When `_selectedPlace != null`:
1. **GPU Vector Canvas Text**: `ctrl.addSymbol(ml.SymbolOptions(textField: effectiveName, ...))` renders the destination name natively directly on the vector map surface at 60fps.
2. **Apple Maps Floating Callout Badge**: An overlay chip is positioned above the orange destination marker:
   - Corner radius: `10`
   - Padding: horizontal `10`, vertical `5`
   - Font: `13.0 semibold`
   - Orange indicator pip (`7x7` circle)
   - Translucent adaptive glass background (`_isDarkMap ? 0xFF1E2430 88% : white 92%`)
   - `IgnorePointer`: 100% touch pass-through, preserving all map pan/pinch/zoom gestures without obstruction.

### B. Custom Saved Name Precedence
In `SearchService.findSavedPlace`, search queries check for custom saved names:
- **Priority**: `custom saved name` > `place.name` > `place.displayName` first part > `"Địa điểm đã chọn"`
- Prevents generic labels like `"Vị trí Google Maps"` from overriding user-assigned place names.

---

## 6. Verification Results & CI Triage

### CI Triage History (Run 35900369836):
- **Run 35900369836 Status**: `FAILED` at `flutter analyze`.
- **Root Cause**: `mobile_app/test/liquid_glass_p62_test.dart` contained 4 unused imports (`dart:ui`, `package:provider/provider.dart`, `package:mobile_app/services/ble_service.dart`, `package:mobile_app/services/esp_stream_service.dart`) left over from migration to `Esp32NavApp`.
- **Resolution (P6.2a)**:
  1. Removed the 4 unused imports completely without using warning suppressions.
  2. Moved place display label resolution out of service layer into pure presentation helper `effectivePlaceLabel(place, savedPlaces)` in `map_screen.dart`, reverting `search_service.dart` to zero diff.
  3. Re-ran strict `flutter analyze` (exited 0, 0 issues found) and expanded `flutter test` (227/227 tests PASS).

### Validated Automated Test Suite (P6.2a):
- **Flutter Analyzer (Strict)**: `0 issues found` (`flutter analyze`).
- **All 227 Unit & Widget Tests**: `227 / 227 PASS` (`flutter test --reporter expanded`).
- **P6.2 Dedicated Test Suite**: `5 / 5 PASS` (`test/liquid_glass_p62_test.dart`):
  - Token parameter & opacity thresholds verified.
  - Presentation `effectivePlaceLabel` custom saved name priority verified.
  - Drawer transparent background & BackdropFilter verified.
  - Search sheet 0.95 opacity elimination verified.
- **Live Routing Provider Smoke Test**: `PASS` (Valhalla HTTP 200 828ms, OSRM HTTP 200 650ms).
- **ESP32 Firmware Build**: `[SUCCESS] Took 4.30 seconds` (`pio run`).

---

## 7. Field Visual Check Checklist (Pending Device Verification)

Per requirement 20, field visual sign-off requires physical iPhone testing:
- [ ] **Screenshot A**: Drawer glass with blurred map streets visibly bleeding through drawer panel.
- [ ] **Screenshot B**: Search sheet glass with translucent bleed-through and secondary glass search field.
- [ ] **Screenshot C**: Main right vertical capsule + bottom search pill sharing identical Image 4 material.
- [ ] **Screenshot D**: Selected place marker displaying orange core, pulsing halo, and Apple Maps callout name badge.
- [ ] **Screenshot E**: Full search view with semantic pastel icon circles (no brown `#B8835C`).

*Status: Automated CI PASS. Ready for manual iPhone field visual verification.*
