# P6.0 — UI/UX Refresh to Apple-Maps-Inspired Design (Zero Core Logic Changes)

## 1. Executive Summary & Strict Constraints Compliance

Phase P6.0 delivers a comprehensive UI/UX overhaul of the application, adopting a modern, clean, bright, and polished design language inspired by Apple Maps.

### HARD RULE Compliance: Zero Core Logic Changes
- **Routing Engine & Providers**: Valhalla primary, OSRM primary/secondary race, and fallback handling remain 100% untouched.
- **Route Preview Lifecycle**: Route revision tracking, render synchronization, and multi-route alternatives retention remain identical.
- **Off-Route & Reroute Logic**: Two-stage state machine (suspected -> confirmed), 25m threshold, hysteresis counter, and background rejoin unchanged.
- **Arrival Confirmation**: Strict single source of truth (`hasArrived` / distance <= 35m) from P5.9.5 preserved.
- **Trimming & Navigation Progress**: Projection onto polylines, segment slicing, and distance progression intact.
- **BLE Protocol & Stream Protocol**: Binary and JSON telemetry formats, packet framing, and display commands unchanged.
- **Regression Suite**: All 209 baseline tests + 13 new P6.0 tests = **222 tests PASS** with 0 failures.

---

## 2. Global Design System Foundations (`lib/theme/`)

A centralized design system foundation was established to guarantee unified styling across all screens and components:

1. **Color Palette (`lib/theme/app_colors.dart`)**:
   - `primary`: Apple Maps Blue (`#007AFF`)
   - `canvas`: Soft iOS background grey (`#F2F2F7`)
   - `surface`: Pure white card surface (`#FFFFFF`)
   - `surfaceSecondary`: Slightly off-white surface (`#F9F9FB`)
   - `border`: Delicate 8% black border (`#14000000`)
   - `textPrimary`: Deep rich charcoal (`#1C1C1E`)
   - `textSecondary`: Medium legible grey (`#8E8E93`)
   - `success`: Soft iOS green (`#34C759`)
   - `warning`: Amber orange (`#FF9500`)
   - `danger`: Subtle red (`#FF3B30`)

2. **Corner Radii (`lib/theme/app_radius.dart`)**:
   - `pill`: 999.0 (capsules, control chips)
   - `sheet`: 24.0 (modal bottom sheets)
   - `card`: 18.0 (content cards)
   - `button`: 14.0 (action buttons)
   - `chip`: 10.0 (badges and tags)

3. **Spatial Spacing System (`lib/theme/app_spacing.dart`)**:
   - Consistent 4pt grid system: `xs` (4), `sm` (8), `md` (12), `lg` (16), `xl` (20), `xxl` (24).

4. **Shadow System (`lib/theme/app_shadows.dart`)**:
   - Shallow, soft, diffuse shadows (`card`, `floating`, `sheet`, `button`) eliminating harsh legacy drop shadows.

5. **Typography (`lib/theme/app_typography.dart`)**:
   - San Francisco / system typographic scale with balanced weights: `largeTitle`, `title2`, `headline`, `subheadline`, `body`, `caption`, `pillLabel`.

6. **Application Theme (`lib/theme/app_theme.dart`)**:
   - Global `ThemeData` setup with `CardThemeData`, `AppBarTheme`, and cohesive button themes.

---

## 3. Shared Component System (`lib/widgets/common/`)

Reusable, presentational, touch-safe widgets:
- `MapCard`: Clean rounded card with subtle border and diffuse shadow.
- `MapFloatingButton`: Circular floating button with subtle border, soft shadow, and active state highlight.
- `MapPillButton`: Horizontal capsule button for quick actions and filters.
- `PrimaryActionButton`: Full-width prominent CTA button with smooth touch feedback.
- `SectionHeader`: Elegant capitalized section header with optional trailing action.
- `StatusBadge`: Pill badge with optional pulsing status indicator dot or icon.
- `EmptyStateCard`: Apple-style empty state card with icon, title, and descriptive message.
- `SavedPlaceDialog`: Modal bottom sheet allowing users to input/edit custom location names with validation.
- `SavedPlaceTile`: Comprehensive bookmark tile supporting tap to inspect, route icon, edit/rename icon, and delete icon.
- `RouteOptionCard`: Multi-route choice card with duration, distance, delta, and recommended tag.

---

## 4. Key UX Refinements Implemented

### 4.1. Startup Location — Current Location First (Fixes Hoan Kiem Snap)
- **Previous UX Defect**: Map automatically initialized and animated camera to Hoan Kiem lake (`21.0285, 105.8542`) before GPS lock, leaving the user far away from their actual physical position.
- **P6.0 Refined Flow**:
  1. App initializes location check upon startup.
  2. If physical GPS coordinate is available immediately, camera centers directly on the user with zoom 16.5.
  3. If GPS fix requires acquisition time, map displays a floating Apple Maps status capsule: `"Đang định vị..."`.
  4. As soon as the first physical GPS coordinate arrives, camera smoothly animates to the user's real position and the locating capsule automatically dismisses.
  5. If location permission is denied or times out, a gentle status badge `"Chạm để tìm vị trí"` is shown, allowing one-tap retry without breaking the map.

### 4.2. Saved Locations — Custom Name Input & Renaming Support
- **Previous UX Defect**: Bookmarking a place immediately saved it using raw reverse-geocoded text without allowing user customization.
- **P6.0 Refined Flow**:
  1. When tapping the bookmark button on any place inspector sheet, `SavedPlaceDialog` opens as a modal bottom sheet.
  2. User can enter custom memorable names (e.g. "Nhà", "Cơ quan", "Quán quen").
  3. The saved places list in the search sheet uses `SavedPlaceTile`, displaying custom names prominently above the address subtitle.
  4. Each saved place item provides an edit pencil button allowing inline renaming via `SearchService.updateSavedPlace`.
  5. If already saved, tapping the bookmark button presents options to edit the name or remove the place.

### 4.3. Touch & Gesture Safety
- All overlay panels, floating toolbars, and sheets have strictly bounded hitboxes (`Align` or `Positioned` wrapping compact children).
- Panning, dragging, pinching, rotating, and tapping map markers remain 100% interactive across all viewport regions not occupied by controls.

---

## 5. Screen-by-Screen Redesign Details

| Screen / Area | Previous State | P6.0 Apple-Maps-Inspired Redesign |
| :--- | :--- | :--- |
| **Main Map Controls** | Ad-hoc glass widgets, mixed spacing | Unified `AppGlassToolbar`, `MapFloatingButton`, clean weather pill, consistent right-side action stack. |
| **Search Bar & Sheet** | Raw text list, basic list tiles | Floating search capsule, modern draggable modal sheet, sectioned history and saved places with `SavedPlaceTile`. |
| **Hamburger Menu Drawer** | Generic Material list drawer | Apple-style segmented drawer with hero header, grouped category sections, chevron badges, and clean spacing. |
| **ESP32 Connection Screen** | Monolithic text-heavy list | iOS segmented tabs (Bluetooth / WiFi Hotspot), hero connection state card, clean RSSI badges, and modern credentials form. |
| **ESP32 Simulation Screen** | Raw debug dump feel | Clean Apple Developer Tools aesthetics, LCD display bezel, segmented telemetry cards, and distinct control pills. |
| **Route Preview Sheet** | Inconsistent button sizing | Elegant waypoints list, multi-route choice pills, large ETA display, and prominent green "ĐI" CTA button. |
| **Active Navigation HUD** | Mixed banner themes | Prominent translucent top maneuver banner, floating street bubble, and bottom HUD with clean ETA, remaining time, and distance. |

---

## 6. Verification & Automated Test Results

### 6.1. Static Analysis
```bash
flutter analyze --no-fatal-infos
# Result: No issues found! (ran in 1.4s)
```

### 6.2. Unit & Widget Tests
```bash
flutter test
# Result: All 222 tests passed! (209 baseline + 13 P6.0 design system & UX tests)
```

### 6.3. Live Routing Smoke Test
```bash
dart run tool/provider_smoke_test.dart
# [SMOKE] Valhalla raw: HTTP 200, 834ms
# [SMOKE] OSRM primary raw: HTTP 200, 612ms
# [SMOKE] OSRM secondary raw: HTTP 200, 613ms
# [PROD-SMOKE] ValhallaService: PASS (HTTP 200, 768ms, dist=4.1 km)
# [PROD-SMOKE] RoutingPipeline bike: PASS (valhalla, 783ms, routes=1)
# Result: All tests passed!
```

### 6.4. PlatformIO Firmware Build
```bash
pio run
# RAM:   41.3% (used 135416 bytes from 327680 bytes)
# Flash: 35.9% (used 1200069 bytes from 3342336 bytes)
# Result: [SUCCESS] Took 4.36 seconds
```

---

## 7. Artifact Summary

- **Theme Files**: `lib/theme/app_colors.dart`, `app_radius.dart`, `app_spacing.dart`, `app_shadows.dart`, `app_typography.dart`, `app_theme.dart`
- **Shared Components**: `lib/widgets/common/map_card.dart`, `map_floating_button.dart`, `map_pill_button.dart`, `primary_action_button.dart`, `section_header.dart`, `status_badge.dart`, `empty_state_card.dart`, `saved_place_dialog.dart`, `saved_place_tile.dart`, `route_option_card.dart`
- **Updated Screens**: `lib/screens/map_screen.dart`, `lib/screens/home_screen.dart`, `lib/screens/ble_screen.dart`, `lib/screens/esp_preview_screen.dart`
- **Updated Services**: `lib/services/search_service.dart` (`updateSavedPlace`)
- **Unit Tests**: `test/ui_refresh_components_test.dart`
