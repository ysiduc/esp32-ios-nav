# PHASE P5.8.1: SINGLE NATIVE GLASS HOST & UIGLASS CONTAINER INTEGRATION

## 1. Executive Summary
Phase P5.8 established overlay coordination signals and detected UIKit Liquid Glass capability, but an audit revealed an architecture mismatch: `plugins.ysiduc.com/native_glass_host` was registered on iOS, but Flutter never instantiated it or called `updateSurfaces`. Instead, every `AppGlassSurface` was still instantiating its own individual `UiKitView(viewType: 'plugins.ysiduc.com/native_glass')`.

Phase P5.8.1 completes the true single-host architecture:
- `MapScreen` mounts at most **ONE** `UiKitView` (`plugins.ysiduc.com/native_glass_host`) in normal map mode.
- `AppGlassSurface` stops creating `UiKitView` entirely and becomes a geometry reporter registering its bounding rect with `NativeGlassHostController`.
- Multiple grouped buttons (such as the right-side toolbar) share `groupId: 'right-toolbar'`, allowing the native host to organize them inside a unified `UIGlassContainerEffect`.
- All physical device manual checklist items are explicitly marked **`MANUAL FIELD PENDING`** until physical iPhone field verification.

---

## 2. Exact P5.8 Architecture Mismatch & Resolution

| Dimension | P5.8 Flawed Reality | P5.8.1 Resolved Reality |
|---|---|---|
| **Native Platform Views in Map** | 5 to 10 separate `UiKitView`s (`native_glass`) | Exactly **1** `UiKitView` (`native_glass_host`) |
| **`plugins.ysiduc.com/native_glass_host`** | Registered in Swift but dead code (never mounted) | Mounted once in `MapScreen` via `NativeGlassHostLayer` |
| **`AppGlassSurface` implementation** | Instantiated an isolated `UiKitView` per surface | Renders Flutter content, registers rect to controller (0 UiKitViews) |
| **Surface Geometry Synchronization** | Never sent | Coalesced batch updates via `com.ysiduc.esp32_nav/glass_host` (`updateSurfaces`) |
| **Toolbar Grouping** | Independent glass surfaces | Unified `UIGlassContainerEffect` grouping with `groupId: 'right-toolbar'` |

---

## 3. Flutter View & Layer Hierarchy

### Before P5.8.1 (Excessive Platform Views)
```
Scaffold
  └─ Stack
      ├─ MapLibreMap
      ├─ Search Capsule -> UiKitView (native_glass #1)
      ├─ Right Toolbar -> UiKitView (native_glass #2)
      ├─ Recenter Button -> UiKitView (native_glass #3)
      ├─ Active Driving Banner -> UiKitView (native_glass #4)
      └─ Active Driving HUD -> UiKitView (native_glass #5)
```

### After P5.8.1 (Single Host Architecture)
```
Scaffold (key: _scaffoldKey, onDrawerChanged: coordinator)
  └─ Stack
      ├─ 1. MapLibreMap (60fps GPU Vector Map)
      ├─ 2. NativeGlassHostLayer [EXACTLY ONE UiKitView: native_glass_host]
      │       └─ Native Host renders all registered glass surfaces & grouped containers
      ├─ 3. Flutter UI Foreground Elements
      │       ├─ Search Capsule (AppGlassSurface: registers rect, 0 UiKitViews)
      │       ├─ Right Toolbar (AppGlassToolbar with groupId: 'right-toolbar', 0 UiKitViews)
      │       ├─ Recenter Button (AppGlassSurface: registers rect, 0 UiKitViews)
      │       ├─ Active Driving Banner (AppGlassSurface, 0 UiKitViews)
      │       └─ Active Driving Bottom HUD (AppGlassSurface, 0 UiKitViews)
      └─ 4. Flutter Navigator / Overlays (Drawer, Apple Search Sheet, Dialogs)
```

---

## 4. Native iOS Host Implementation (`AppDelegate.swift`)

### Grouped `UIGlassContainerEffect`
- Surfaces sharing a `groupId` (e.g. `'right-toolbar'`) are grouped into a union bounding box.
- A container view is created using `NativeGlassPlatformView.createGlassContainerView(cornerRadius: 22.0)`.
- When `isGlassContainerAvailable` (`#available(iOS 26.0, *)` with `NSClassFromString("UIGlassContainerEffect")`), a `UIVisualEffectView(effect: containerEffect)` is created.
- Child `UIGlassEffect` views are positioned relative to the group container and added into its `contentView`.
- Stale surfaces and stale group views are pruned immediately upon `applySurfaces`.

### Availability & Fallback
- iOS 26+ runtime: `UIGlassEffect` and `UIGlassContainerEffect`.
- Pre-iOS 26 fallback: Standard `UIBlurEffect` (`.systemUltraThinMaterial`, `.systemMaterial`).
- Active modal/drawer overlay: Native host view is unmounted/hidden (`isOverlayActive`), controls smoothly composite with Flutter `BackdropFilter`.

---

## 5. Automated Verification Results

### Unit & Widget Tests
- **Total Tests Passed**: **173 / 173 tests** (0 failures).
- **New P5.8.1 Suite (`liquid_glass_test.dart`)**:
  1. `Strict platform view count`: Verifies that with 4+ glass controls on screen, `native_glass_host` count == 1, `native_glass` count == 0, and total UiKitViews == 1. When an overlay opens, UiKitView count drops to 0.
  2. `Surface registry lifecycle`: Verifies registration of A, B, C, geometry update of B, and removal of C without zombie surfaces.
  3. `Grouped toolbar`: Verifies that `AppGlassToolbar` registers surfaces with `groupId: 'right-toolbar'`.

### Firmware Verification
- PlatformIO build for `esp32-s3`: **SUCCESS in 4.28s** (RAM: 41.3%, Flash: 35.9%). Zero regressions to ESP32 BLE streaming.

---

## 6. Performance Analysis (P5.8 vs P5.8.1)

| Metric | P5.8 (Multiple UiKitViews) | P5.8.1 (Single Native Glass Host) |
|---|---|---|
| **Native Platform Views** | 5 to 10 | **1** |
| **iOS UIKit Subviews** | 10 to 20 separate view hierarchies | 1 unified host view hierarchy |
| **CoreAnimation Surface Commits** | Multi-surface CA synchronizations | 1 coordinated frame layer |
| **Modal Transition Cost** | Risk of z-order occlusion and hitching | Immediate unmount/mount of 1 view |
| **GPU Raster Overhead** | High platform view composition tax | Low overhead, MapLibre stays responsive |

---

## 7. Toolchain & CI Verification

- Runner: `runs-on: macos-26`.
- Xcode: `Xcode 26.6 (Build 17F113)`.
- SDK: `iPhoneOS 26.5`.
- Production Artifact: `ESP32Nav-Flutter-PRODUCTION.ipa`.

---

## 8. Physical Device Verification Status

> [!IMPORTANT]
> All manual field tests are explicitly marked **`MANUAL FIELD PENDING`**. Prior P5.8 checklist markings were automated lab assertions and have been corrected.

- [ ] Hamburger menu opens and visibly appears above all map content (MANUAL FIELD PENDING)
- [ ] Search panel opens as an Apple Maps-style large rounded sheet and visibly appears (MANUAL FIELD PENDING)
- [ ] Report incident sheet opens and visibly appears (MANUAL FIELD PENDING)
- [ ] Location confirmation dialogs open above glass controls (MANUAL FIELD PENDING)
- [ ] No native glass layer covers any Flutter overlay (MANUAL FIELD PENDING)
- [ ] Glass visually reacts to map background transmission (MANUAL FIELD PENDING)
- [ ] Right toolbar feels like one cohesive glass container (MANUAL FIELD PENDING)
- [ ] Dark Mode demonstrates proper adaptive tone (MANUAL FIELD PENDING)
- [ ] Reduce Transparency displays crisp high-contrast opaque surfaces (MANUAL FIELD PENDING)
- [ ] Turn navigation line and ESP32 BLE streaming remain fully functional (MANUAL FIELD PENDING)
