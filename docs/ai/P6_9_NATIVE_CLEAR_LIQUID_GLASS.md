# Phase P6.9: Restore Real Native Clear Liquid Glass Pipeline

**Date**: 2026-09-24  
**Commit**: `feat(ui): P6.9 restore native clear Liquid Glass rendering`  
**Status**: AUTOMATED VERIFICATION PASSED (265/265 tests PASS, 0 analyzer issues)  
**Target App**: `ESP32Nav-Flutter-PRODUCTION.ipa`  

---

## 1. Architectural Correction: Reversion of P6.6–P6.8 Deviations

During phases P6.6–P6.8, UI map overlays deviated from the repository's authoritative architecture by attempting to simulate glass entirely inside Flutter through painted multi-layer widgets (`TrueLiquidGlass`, fake body gradients, clear-core opacity tweaks, and fake inner specular rims). This caused several visual regressions:
- Overlays appeared as frosted or milky white/grey slabs occluding the vector map.
- The GPU-rendered vector map beneath the controls was masked by painted Flutter colors rather than sampled optically.
- Unnecessary paint passes were added to Flutter's raster thread.

**Phase P6.9 stops modifying `TrueLiquidGlass` opacity hacks and returns directly to the repository's native glass source of truth established in P5.9 and run `35895237697`**:
```
Flutter Layer (Composited Directly Above MLNMapView)
├── Foreground UI: Icons, dividers, typography, selected states
└── Container color: Colors.transparent (ZERO painted white/grey slabs)
         │
         ▼ (Registers layout rect via MapNativeGlassController)
MapLibre Native View (MLNMapView)
├── glassBackdropContainer (UIView, isUserInteractionEnabled = false)
│   ├── Individual Surfaces: UIGlassEffect / UIBlurEffect(.systemUltraThinMaterialLight)
│   │   ├── body tint = UIColor.white.withAlphaComponent(0.08)
│   │   └── specular edge = 0.5pt, white alpha 0.40
│   └── Group Containers: UIGlassContainerEffect / UIBlurEffect
│       └── Right Toolbar: Unified capsule backdrop
└── Vector Map OpenGL/Metal Engine (Visibly diffusing through clear glass)
```

---

## 2. Liquid Glass Presentation Specification

The authoritative visual target for Apple Maps Liquid Glass requires:
1. **Transparent / See-Through Center**: Roads, terrain, and building footprints are clearly recognizable through the center of the glass body.
2. **True Optical Diffusion**: The native Metal/OpenGL vector map texture is softly diffused by UIKit's native shader pipeline rather than occluded by Flutter paint colors.
3. **Specularity Ratio (Body ≈ 0.08, Edge ≈ 0.40)**:
   - Body tint: `UIColor.white.withAlphaComponent(0.08)` (ultra-clear)
   - Specular highlight edge: `borderWidth = 0.5`, `borderColor = UIColor.white.withAlphaComponent(0.40)`
   - Edge is noticeably brighter than the glass center, imparting a natural refractive droplet/meniscus feel without milky or dark smoked body fills.
4. **Touch Safety**: `isUserInteractionEnabled = false` is maintained on all native glass backdrops and containers. Map touch pass-through is 100% direct to `MLNMapView` recognizers.

---

## 3. Implementation Details

### A. iOS Native Pipeline (`MapLibreMapController.swift`)
1. **Corner Masking for Large Surfaces**:
   - `applyCorners` automatically applies `layer.maskedCorners`:
     - Drawer surfaces (`x <= 0`): `[.layerMaxXMinYCorner, .layerMaxXMaxYCorner]` (rounded right edge only, flush with left screen boundary).
     - Bottom sheets: `[.layerMinXMinYCorner, .layerMaxXMinYCorner]` (rounded top edge only).
2. **Clear Variant Container Support**:
   - `createGlassContainerView(cornerRadius:variant:)` defaults to `variant: "clear"`, using `UIBlurEffect(style: .systemUltraThinMaterialLight)` with `tintColor = UIColor.white.withAlphaComponent(0.08)` and `0.5pt` specular edge when `UIGlassContainerEffect` is unavailable.
   - When iOS 26 `UIGlassContainerEffect` is available, UIKit hardware glass shaders are used directly.

### B. Controller & Surface Registry (`liquid_glass.dart`)
1. **`overlayOwned` Surface Property**:
   Added `final bool overlayOwned;` (default `false`) to `GlassSurfaceData`, `AppGlassSurface`, and `AppGlassToolbar`.
   In `MapNativeGlassController.flushSurfaces()`:
   ```dart
   final isVisible = s.overlayOwned ? true : !isOverlayActive;
   ```
   - Normal map controls (`overlayOwned == false`) automatically hide when an overlay opens.
   - Overlay-owned components (`overlayOwned == true`, e.g., navigation drawer, search sheet, place details sheet, route directions sheet) remain visible on the native glass pipeline.
2. **Z-Order Resolution**:
   `AppGlassBackend.resolve` checks `isOverlayActive && !overlayOwned`: only non-overlay map controls fall back during active overlays; `overlayOwned` surfaces continue using native Liquid Glass.
3. **Clear Variant Fallback Alignment**:
   In `AppGlassSurface._buildSurface`, the `clear` fallback branch uses `Colors.white.withOpacity(0.08)` fill and `Colors.white.withOpacity(0.40)` specular edge, matching the native UIKit 0.08:0.40 ratio.

### C. Active UI Surfaces Restored
All 6 primary application roots have been converted from `TrueLiquidGlass` to native-backed `AppGlassToolbar` / `AppGlassSurface`:
1. **Right Action Toolbar**: `AppGlassToolbar(groupId: 'right-toolbar', variant: AppGlassVariant.clear, width: 48, radius: 24)`
2. **Bottom Search Capsule**: `AppGlassSurface(surfaceId: 'bottom-search', variant: AppGlassVariant.clear, radius: 25, height: 50)`
3. **Navigation Drawer**: `AppGlassSurface(surfaceId: 'drawer', variant: AppGlassVariant.clear, radius: 28, overlayOwned: true)`
4. **Search Modal Sheet**: `AppGlassSurface(surfaceId: 'search-sheet', variant: AppGlassVariant.clear, radius: 26, overlayOwned: true)`
5. **Place Details Inspector Sheet**: `AppGlassSurface(surfaceId: 'place-sheet', variant: AppGlassVariant.clear, radius: 26, overlayOwned: true)`
6. **Route Directions Sheet**: `AppGlassSurface(surfaceId: 'route-sheet', variant: AppGlassVariant.clear, radius: 26, overlayOwned: true)`

### D. Debug Telemetry (`_buildDebugOverlay`)
The telemetry overlay dynamically inspects active glass backends and reports individual surface bindings per Requirement 17:
- `Glass backend`: `UIGlassEffect` / `UIGlassContainerEffect` / `native-blur-clear` / `flutter-fallback`
- `• right-toolbar`: `UIGlassContainerEffect` / `native-blur-clear`
- `• bottom-search`: `UIGlassEffect` / `native-blur-clear`
- `• drawer`: `UIGlassEffect` / `native-blur-clear` (overlayOwned)
- `• search-sheet`: `UIGlassEffect` / `native-blur-clear` (overlayOwned)
- `• route-sheet`: `UIGlassEffect` / `native-blur-clear` (overlayOwned)

---

## 4. Verification & Regression Testing

### Regression Suite (`mobile_app/test/liquid_glass_p69_test.dart`)
All 8 explicit P6.9 requirement checks pass:
1. `Right toolbar uses AppGlassVariant.clear with width 48, radius 24` — **PASS**
2. `Bottom search uses AppGlassVariant.clear with radius 25, height 50` — **PASS**
3. `No TrueLiquidGlass on right toolbar, bottom search, drawer, or search sheet roots` — **PASS**
4. `Clear fallback tint == 0.08 and edge highlight == 0.40 (0.08:0.40 ratio)` — **PASS**
5. `Native glass views userInteractionEnabled == false (guaranteed by MLNMapView integration)` — **PASS**
6. `overlayOwned drawer remains visible in drawer mode, unrelated map glass hides` — **PASS**
7. `No full-screen UiKitView introduced (single MLNMapView count = 1)` — **PASS**
8. `Debug telemetry reports expected backend names for key surfaces` — **PASS**

### Full Repository Verification
- **Flutter Analyzer**: `flutter analyze --no-fatal-infos` -> **0 issues**
- **Test Suite**: `flutter test` -> **265 tests passed, 0 failures**
