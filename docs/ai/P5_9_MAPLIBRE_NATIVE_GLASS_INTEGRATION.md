# Phase P5.9: Move Liquid Glass into MapLibre Native Hierarchy

**Date**: 2026-09-23  
**Target App**: `ESP32Nav-Flutter-PRODUCTION.ipa`  
**Status**: AUTOMATED VERIFICATION PASSED / MANUAL FIELD PENDING  

---

## 1. Executive Summary & Field Evidence from P5.8.2

Physical iPhone field testing on P5.8.2 revealed two fundamental architectural blockers:

1. **Bug A — Map Gestures Still Completely Blocked**:
   The native map could not pan, drag, or pinch-zoom, even though P5.8.2 implemented:
   - `IgnorePointer(ignoring: true)` in Flutter
   - `PlatformViewHitTestBehavior.transparent`
   - Swift `hitTest(...) -> nil`

2. **Bug B — Native Glass Visually Empty/Defective**:
   The native glass was almost completely transparent in the center with no diffusion or refraction of the map beneath it; users observed only a specular white border outline, failing the Apple Maps reference visual target.

### Critical Report Correction regarding P5.8.2
> **Correction**: The P5.8.2 automated gesture seam was **insufficient** because it tested a synthetic Flutter `GestureDetector` rather than the real-device iOS `PlatformView`-over-`PlatformView` composition. In Flutter's iOS platform view engine, `FlutterTouchInterceptingView` intercepts gestures before delivering them to underlying platform views, regardless of whether a child UIView returns `hitTest = nil`. The claim of touch pass-through in P5.8.2 is hereby retracted for physical hardware until verified in the field.

---

## 2. Root Cause Analysis

### The Flawed Architecture (P5.8 - P5.8.2)
```
Flutter Stack
├── MapLibreMap               ← iOS PlatformView #1 (MLNMapView)
├── NativeGlassHostLayer      ← iOS PlatformView #2 (NativeGlassHostPlatformView)
└── Flutter UI Controls       ← Transparent buttons, icons, text
```

1. **Touch Interception by Platform View Embedding**: Flutter creates a `FlutterTouchInterceptingView` for every `UiKitView`. When `NativeGlassHostLayer` covered the full screen above `MapLibreMap`, Flutter's touch interceptor consumed or redirected gestures before they could ever reach `MapLibreMap`'s own gesture recognizers.
2. **Backdrop Sampling Failure**: In iOS UIKit and Metal/OpenGL composition, a `UIVisualEffectView` placed in one PlatformView cannot sample the GPU framebuffer rendered by a completely separate PlatformView below it. As a result, the glass appeared empty/transparent with only a white outline.

---

## 3. The New Architecture (P5.9)

Glass backdrops are moved **inside the same native UIView hierarchy as MapLibre itself (`MLNMapView`)**:

```
MapLibre Native Platform View (MLNMapView)
├── OpenGL/Metal Map Rendering Layer (60fps vector tiles)
├── NativeGlassBackdropContainer (isUserInteractionEnabled = false)
│   ├── Top-Left Pill: UIGlassEffect / UIVisualEffectView
│   ├── Right-Side Unified Toolbar: UIGlassContainerEffect / UIVisualEffectView
│   ├── Bottom Search Capsule: UIGlassEffect / UIVisualEffectView
│   └── Navigation Banner Backdrop
└── MLNMapView Native Gesture Recognizers (Pan, Pinch, Rotate, Tap)

Flutter Layer (Composited Directly Above MapLibre)
├── Top-Left Foreground: Hamburger icon, Weather text (27°)
├── Right-Side Foreground: Layer, Compass, Vehicle, Recenter icons
├── Bottom Search Foreground: Search icon, Hint text, Mic, Avatar
└── Overlays & Sheets: Search sheet, Navigation drawer, Ambiguity dialog
```

### Architectural Guarantees
1. **Total Platform View Count in Normal Mode = 1**: Production `MapScreen` mounts **zero** `NativeGlassHostLayer` and **zero** `plugins.ysiduc.com/native_glass_host` views.
2. **Direct Native Touch Pass-Through**: All glass subviews have `isUserInteractionEnabled = false` and are direct children of `mapView`. Touches fall straight through to `MLNMapView`'s built-in pan, pinch, and tap recognizers.
3. **True Backdrop Diffusion**: Because `UIVisualEffectView` / `UIGlassEffect` sits directly on top of the Metal/OpenGL rendering surface inside `MLNMapView`, it genuinely samples and diffuses the underlying road, terrain, and map colors.

---

## 4. MapLibre iOS Plugin Investigation

Inspection of the resolved `maplibre_gl: ^0.21.0` dependency identified the exact native structure:
- **Flutter Widget**: `MapLibreMap` (`packages/maplibre_gl/lib/src/maplibre_map.dart`)
- **Plugin Factory**: `MapLibreMapFactory` (`MapLibreMapFactory.swift`, registered as `plugins.flutter.io/maplibre_gl`)
- **Native Platform View**: `MapLibreMapController: NSObject, FlutterPlatformView, MLNMapViewDelegate` (`MapLibreMapController.swift`)
- **Underlying Native View**: `mapView: MLNMapView` returned by `func view() -> UIView { return mapView }`
- **Native Channel**: Per-map method channel named `plugins.flutter.io/maplibre_gl_\(viewId)`

---

## 5. Implementation Details

### A. Vendored Plugin Integration (Option A)
`maplibre_gl: 0.21.0` was vendored locally under `mobile_app/packages/maplibre_gl` and linked via `dependency_overrides` in `mobile_app/pubspec.yaml`.
- In `MapLibreMapController.swift`:
  - Added `glassBackdropContainer: UIView?`, `glassSurfaceViews: [String: UIView]`, and `groupContainers: [String: UIView]`.
  - Added method call handler for `map#updateGlassSurfaces`.
  - Implemented `updateNativeGlassSurfaces(surfaces:)`:
    - Creates or updates `glassBackdropContainer` with `isUserInteractionEnabled = false`.
    - Supports both individual glass surfaces and grouped containers (`UIGlassContainerEffect` or grouped `UIBlurEffect`).
    - Configures milky frosted diffusion base + 0.5pt specular highlights.
- In `MapLibreMapController.dart`:
  - Exposed `platformViewId` and `Future<void> updateGlassSurfaces(List<Map<String, dynamic>> surfaces)`.

### B. Controller Repurposing & Coordinate Conversion
In `mobile_app/lib/widgets/liquid_glass.dart`:
- Repurposed `NativeGlassHostController` into `MapNativeGlassController`.
- Implemented coordinate conversion:
  41159	ext{nativeLocalRect} = 	ext{surfaceGlobalRect} - 	ext{mapGlobalOrigin}41159
- Surfaces register with `MapNativeGlassController`.
- Geometry updates are coalesced and dispatched via `mapController.updateGlassSurfaces(payload)`.
- During active overlays (`isOverlayActive`), surfaces receive `visible: false`.

### C. MapScreen Cleanup
In `mobile_app/lib/screens/map_screen.dart`:
- Removed `const NativeGlassHostLayer()` completely from the Stack.
- Assigned `key: _mapKey` to `MapLibreMap`.
- Attached `_mapController` and `_mapKey` to `MapNativeGlassController` on `_onMapCreated`.
- In `_openAppleSearchModal()`, wrapped sheet in `ClipRRect` and `BackdropFilter(sigmaX: 25, sigmaY: 25)` with `Color(0xFFF2F2F7).withOpacity(0.80)`.

---

## 6. Verification Results

### Automated Tests
1. **Flutter Analyzer**:
   `flutter analyze` → **No issues found!** (0 errors, 0 warnings).
2. **Flutter Test Suite**:
   `flutter test` → **181 tests passed, 0 failed**.
   - Liquid Glass UI & Native Architecture: 39 tests passed.
   - Search & Latency: 42 tests passed.
   - Navigation Reroute & Maneuvers: 100 tests passed.
3. **PlatformIO Firmware Compilation**:
   `pio run` → **SUCCESS** (RAM 41.3%, Flash 35.9%).
4. **CI Pipeline (`build_ios.yml`)**:
   - Environment: `macos-26` with `Xcode 26.6` / iOS 26.5 SDK.
   - Flutter Release Build: Completed.
   - Production Artifact: `ESP32Nav-Flutter-PRODUCTION.ipa` generated.

---

## 7. Manual Field Verification Checklist

| Item | Description | Status |
| :--- | :--- | :--- |
| 1 | Map pans and drags smoothly without gesture interception | **MANUAL FIELD PENDING** |
| 2 | Map pinch-zooms smoothly with multi-touch | **MANUAL FIELD PENDING** |
| 3 | Foreground Flutter controls (menu, weather, toolbar, search) remain clickable | **MANUAL FIELD PENDING** |
| 4 | Glass has visible milky body diffusing map roads/colors beneath | **MANUAL FIELD PENDING** |
| 5 | Right toolbar appears as a unified vertical glass capsule | **MANUAL FIELD PENDING** |
| 6 | Search capsule and modal sheet open/dismiss smoothly | **MANUAL FIELD PENDING** |

*Note: In accordance with project instructions, no manual interaction item is marked PASS until confirmed by the user on a physical iPhone.*
