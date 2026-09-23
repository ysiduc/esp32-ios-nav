# P6.1 — Frontend-Only UI Polish Round 2

**Repository:** `ysiduc/esp32-ios-nav`  
**Phase:** P6.1 (Frontend-Only Polish)  
**Strict Scope Rule:** Zero modifications to core navigation engine, Valhalla/OSRM routing algorithms, preview lifecycle, arrival detection, reroute logic, BLE protocol, or ESP32 binary payload formats. All changes are strictly UI/UX, styling, layout, and presentation state.

---

## 1. Executive Summary

Phase P6.1 focused purely on visual and interactive refinement to achieve an authentic Apple Maps aesthetic across all primary app surfaces:
1. **Map Screen Top-Left**: Completely removed the legacy top-left pill (3-line hamburger menu + weather `27°`). The drawer is now smoothly accessible via a left-edge swipe gesture (`drawerEdgeDragWidth: 25%`), leaving the map viewport clean with zero touch-blocking hitboxes.
2. **Connection Screen (`BleScreen`)**: Removed all harsh black horizontal lines and thick dividers beneath the TabBar and between device list items. Replaced with soft Apple-style card separation and ultra-light 0.5pt dividers.
3. **ESP32 Simulation Screen (`EspPreviewScreen`)**: Full modern control-panel redesign:
   - High-contrast, legible typography (`AppColors.textPrimary` and `AppColors.textSecondary`) replacing invisible white-on-white text.
   - Clean, balanced streaming metrics card (Actual FPS, Frame Size, Target FPS).
   - Apple-style minimap zoom slider and pill presets (`x14 Xa` to `x18 Cận cảnh`).
   - Sleek mock screen bezel.
4. **Replaced Mock Call/SMS Test UI with Production Notification Settings**:
   - Completely removed the legacy developer test section (text fields and test buttons for Zalo, SIM, Messenger).
   - Replaced with an elegant "Thông báo iPhone (ANCS)" settings card featuring an iOS master toggle ("Nhận thông báo từ iPhone"), setup guide, and sub-toggles ("Thông báo cuộc gọi", "Thông báo tin nhắn").
5. **Search Full-Screen Sheet (Apple Maps Reference Match)**:
   - Redesigned to closely match Apple Maps reference:
     - Soft grey canvas background (`#F2F2F7`).
     - White search capsule with search icon, "Bản Đồ Apple" placeholder, mic, and profile avatar "Y".
     - Circular grey close button.
     - "Địa điểm >" section with circular action buttons ("Nhà", "Công ty", "Thêm").
     - "Gần đây >" card list featuring circular landmark avatars, bold titles, subtitle addresses, and three-horizontal-dots (`•••`) option sheets.
     - "Hướng dẫn của bạn >" favorite guide card with 3D gold star.
6. **Liquid Glass Alignment & Drift Resolution**:
   - Fixed upward drift/misalignment of glass overlays across safe areas and Dynamic Island by anchoring visual blurs directly within Flutter's render box coordinate hierarchy.
7. **Right-Side Vertical Control Pill**:
   - Translucent milky white frosted glass (blur 20, white specular border 0.8pt, soft shadow) with 4 balanced action buttons (Layers, Compass North, Vehicle mode, Recenter).
8. **Bottom Search Bar**:
   - Translucent floating capsule matching Image 10 (height 50, radius 25, search icon, mic, profile avatar).
9. **Search Button Tap Behavior (No Auto Keyboard)**:
   - Tapping the bottom search bar opens the search modal sheet with `autofocus: false`. The keyboard is NOT automatically presented until the user explicitly taps into the text field.

---

## 2. Detailed Adjustments by Component

### 2.1 Map Screen (`map_screen.dart`)
- **Top-Left Pill**:
  - Removed `_buildTopLeftGlassGroup` from the widget tree and deleted its helper method.
  - Configured `Scaffold`:
    ```dart
    drawer: widget.drawer,
    drawerEnableOpenDragGesture: true,
    drawerEdgeDragWidth: MediaQuery.of(context).size.width * 0.25,
    ```
- **Right Vertical Controls**:
  - Encapsulated within a 48pt wide pill with `BoxDecoration(color: Colors.white.withOpacity(0.85), borderRadius: BorderRadius.circular(24), border: Border.all(color: Colors.white.withOpacity(0.70), width: 0.8))` and `BackdropFilter(filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20))`.
- **Bottom Search Capsule**:
  - Encapsulated within a 50pt height capsule with radius 25, translucent white fill, soft shadow, mic icon, and profile avatar "Y".
- **Search Modal & Keyboard Behavior**:
  - `TextField` inside `_openAppleSearchModal` has `autofocus: false`.
  - Added "Địa điểm >" quick actions (`_buildQuickPlaceCircleAction`), "Gần đây >" with action sheet (`_showRecentPlaceActionSheet`), and "Hướng dẫn của bạn >" card.

### 2.2 Connection Screen (`ble_screen.dart`)
- Set `scrolledUnderElevation: 0`, `surfaceTintColor: Colors.transparent`, `shadowColor: Colors.transparent` on `AppBar`.
- Set `dividerColor: Colors.transparent` and `dividerHeight: 0` on `TabBar`.
- Replaced `Divider(height: 1, indent: 56)` with `Container(height: 0.5, margin: const EdgeInsets.only(left: 64, right: 16), color: AppColors.border)`.

### 2.3 ESP32 Simulation Screen (`esp_preview_screen.dart`)
- Cleaned up stream status card with `AppColors.textSecondary` and `AppColors.textPrimary`.
- Redesigned zoom slider and preset pills (`_buildZoomPresetChip`) with active `AppColors.primary` fill and inactive `AppColors.canvas` fill.
- Deleted legacy developer test section (lines 1083–1312) containing call/SMS mock triggers and text controllers.
- Added production Apple ANCS settings card with local UI toggle states (`_enableIPhoneNotifications`, `_enableCallNotifications`, `_enableMessageNotifications`).

---

## 3. Verification & Build Results

### 3.1 Flutter Unit & Widget Tests
```bash
flutter test
```
- **Result:** `All 222 tests passed!` (100% pass rate, 0 regressions).

### 3.2 Flutter Static Analysis
```bash
flutter analyze --no-fatal-infos
```
- **Result:** `No issues found!` (0 errors, 0 warnings, 0 lints).

### 3.3 Live Provider Smoke Test
```bash
dart run tool/provider_smoke_test.dart
```
- **Result:** All providers returned HTTP 200 (Valhalla, OSRM primary, OSRM secondary).

### 3.4 PlatformIO Firmware Build
```bash
pio run
```
- **Target:** ESP32-S3 (8MB Flash, 320KB RAM)
- **Result:** `SUCCESS` (Took 5.84s; RAM: 41.3%, Flash: 35.9%).

---

## 4. Summary Table of Files Changed

| File | Type | Changes |
| :--- | :--- | :--- |
| `mobile_app/lib/screens/map_screen.dart` | UI Screen | Removed top-left pill, configured left-edge drawer swipe, redesigned right vertical pill & bottom search capsule, added Apple Maps search sheet layout with `autofocus: false`. |
| `mobile_app/lib/screens/ble_screen.dart` | UI Screen | Removed black lines under TabBar and list item dividers, added soft card spacing. |
| `mobile_app/lib/screens/esp_preview_screen.dart` | UI Screen | Redesigned stream & zoom cards, updated typography to Apple light theme tokens, replaced test call/sms UI with production ANCS settings card. |
| `docs/ai/P6_1_FRONTEND_UI_POLISH_2.md` | Documentation | Complete P6.1 frontend-only UI polish report. |
