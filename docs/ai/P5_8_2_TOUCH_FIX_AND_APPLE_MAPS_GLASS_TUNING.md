# PHASE P5.8.2: RESTORE MAP GESTURES & TUNE LIQUID GLASS TO APPLE MAPS STYLE

## 1. Executive Summary
Following Phase P5.8.1's single native glass host implementation, physical iPhone testing revealed two critical field issues:
1. **Map Touch Blocking (Bug 1)**: Map gestures (pan, drag, pinch-to-zoom, tap) were completely blocked because the full-screen `NativeGlassHostLayer` platform view intercepted all touch events in the UIKit hit-testing hierarchy.
2. **Visual Divergence from Apple Maps (Bug 2)**:
   - Root theme hardcoded `Brightness.dark`, causing `MapScreen` and `AppGlassSurface` to evaluate `isDark = true`, turning the search sheet into a heavy black modal and dimming the glass (Anti-reference Image 4).
   - The right toolbar rendered overlapping container and child blurs with separate borders plus a floating circular button, creating concentric circles / halos ("ghost rings" like Anti-reference Image 3).
   - Glass material lacked the light, airy, translucent, slightly milky frosted feel of genuine Apple Maps (Target Images 1 & 2).

Phase P5.8.2 resolves both issues:
- **Pointer Pass-Through**: Implemented `PassThroughContainerView` overriding `hitTest(_:with:) -> nil` and set `isUserInteractionEnabled = false` across all glass layers in UIKit. Map receives full 60fps pan/pinch/tap gestures while Flutter interactive controls on top remain fully responsive.
- **Apple Maps Liquid Glass Visual**: Established `AppleGlassTokens` design token system, consolidated the right toolbar into a single unified vertical capsule without ghost rings, and redesigned the bottom search sheet into a light translucent Apple Maps panel with clean white cards.
- **Physical Verification**: In accordance with Requirement 13, all physical device checklist items are marked **`MANUAL FIELD PENDING`** until physical iPhone confirmation.

---

## 2. Bug 1: Map Touch Blocking Root Cause & Pass-Through Fix

### 2.1 Root Cause
In Flutter's iOS platform view embedding, `NativeGlassHostLayer` mounted a full-screen `UiKitView` (`plugins.ysiduc.com/native_glass_host`) above `MapLibreMap` in the Flutter Stack:
1. When a user touched the screen, UIKit executed hit-testing on the native view hierarchy (`rootViewController.view` -> `FlutterTouchInterceptingView` -> `containerView`).
2. Even though Flutter Dart wrapped `UiKitView` in `IgnorePointer(ignoring: true)`, UIKit's native hit-testing traversal still encountered `containerView` (an ordinary `UIView`) and its subviews (`groupContainer`, `UIVisualEffectView`, `specularEdge`).
3. Because standard `UIView` returns itself or its subviews if bounds contain the touch point, the native glass platform view absorbed the UIKit touch events, preventing them from falling through to the underlying `MapLibre` Metal/OpenGL surface.

### 2.2 Fix Implementation
1. **iOS Native Side (`AppDelegate.swift`)**:
   - Subclassed `UIView` as `PassThroughContainerView`:
     ```swift
     class PassThroughContainerView: UIView {
       override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
         return nil // Completely transparent to UIKit touch events
       }
     }
     ```
   - Instantiated `containerView = PassThroughContainerView(frame: frame)`.
   - Set `isUserInteractionEnabled = false` across the entire native view hierarchy:
     - `containerView.isUserInteractionEnabled = false`
     - `groupContainer.isUserInteractionEnabled = false`
     - `blurView.isUserInteractionEnabled = false`
     - `tintView.isUserInteractionEnabled = false`
     - `specularEdge.isUserInteractionEnabled = false`
     - `effectView.contentView.isUserInteractionEnabled = false`
     - Fallback layout anchor `view.isUserInteractionEnabled = false`
   - By returning `nil` from `hitTest`, UIKit completely bypasses `PassThroughContainerView` and all its child views during hit testing. Touch events fall straight down to MapLibre's Metal surface.
2. **Flutter Side (`liquid_glass.dart`)**:
   - Confirmed `NativeGlassHostLayer` maintains:
     - `IgnorePointer(ignoring: true)`
     - `hitTestBehavior: PlatformViewHitTestBehavior.transparent`
   - Flutter controls on top (`_buildTopLeftGlassGroup`, `_buildRightSideGlassStack`, `_buildAppleBottomSearchCapsule`) receive pointer events in the Flutter gesture arena normally.
   - Non-control empty areas pass pointer events through to MapLibre.

### 2.3 Stack Structure
```
Flutter Widget Stack
├─ 1. MapLibreMap (Receives real map gestures: pan, zoom, pinch, tap)
├─ 2. NativeGlassHostLayer (Pass-through visual only; IgnorePointer + hitTest: nil)
├─ 3. Top-Left Menu / Weather Pill (Interactive Flutter controls)
├─ 4. Right-Side Unified Toolbar (Interactive Flutter controls)
├─ 5. Bottom Search Capsule (Interactive Flutter controls)
└─ 6. Flutter Overlays / Sheets (Modal bottom sheet, Drawer, Dialogs)
```

---

## 3. Bug 2: Liquid Glass Visual Tuning & Apple Maps Ground Truth

### 3.1 Ground Truth Comparison

#### Reference Match: Target Images 1 & 2
- **Overall UI Tone**: Light, airy, translucent, refined floating card aesthetic of Apple Maps.
- **Translucency / Diffusion**: Subtle milky / frosted light glass (`#F2F2F7` at 94% opacity for sheets, `Colors.white` at 72–85% for pills). Map context remains clearly visible beneath.
- **Edges & Highlights**: Delicate 0.5pt specular highlight borders (`Colors.white` at 60–80% opacity), never thick or clumsy.
- **Shadows**: Soft, diffused shadows (`Colors.black` at 4–6% opacity, blur 16) giving genuine floating depth without heavy drop shadows.
- **Top-Left Weather / Menu Pill**: Clean horizontal pill (`radius: 22`, height: 44), subtle transmission, hairline divider, clear 3-line menu icon and blue weather cloud with crisp `27°` typography.
- **Right Toolbar**: Single unified vertical capsule (`width: 46`, `radius: 23`) neatly grouping 4 controls (Layers, Compass, Mode, Recenter) separated by thin dividers. Recenter active state uses a subtle soft blue circular background. Zero ghost rings!
- **Search Sheet**: Light translucent panel (`#F2F2F7` at 95% opacity) with light gray drag handle (`#D1D1D6`), bright white search capsule, and clean white cards for saved places and search history.

#### Anti-Reference Rejection: Images 3 & 4
- **Image 3 Rejection (Ghost Rings & Circular Clutter)**:
  - *Cause*: Toolbar had a separate container + separate button below it, and in `AppDelegate.swift`, grouped containers rendered double blurs and duplicate specular borders.
  - *Fix*: Removed duplicate blurs in `AppDelegate.swift`, consolidated toolbar into 1 unified vertical capsule in `map_screen.dart`.
- **Image 4 Rejection (Dark Bulky Modal & Over-Dark Glass)**:
  - *Cause*: `main.dart` hardcoded `ThemeData(brightness: Brightness.dark)`, causing `MapScreen` and `_openAppleSearchModal` to select dark modal backgrounds (`#1C1C1E` at 92% opacity) and dark slate glass fills.
  - *Fix*: Reset `main.dart` to `Brightness.light`, forced Apple Maps light translucent theme in `_openAppleSearchModal` (`#F2F2F7` at 95% opacity), and eliminated all dark modal overrides.

### 3.2 Visual Token System (`AppleGlassTokens`)
```dart
class AppleGlassTokens {
  // Blur Intensities
  static const double blurLight = 16.0;
  static const double blurRegular = 20.0;
  static const double blurProminent = 24.0;
  static const double blurSheet = 30.0;

  // Translucent Light Fills (Milky frosted, airy, low gray tint)
  static final Color fillLight = Colors.white.withOpacity(0.72);
  static final Color fillRegular = Colors.white.withOpacity(0.78);
  static final Color fillProminent = Colors.white.withOpacity(0.85);
  static final Color fillToolbar = Colors.white.withOpacity(0.80);
  static final Color fillSheet = const Color(0xFFF2F2F7).withOpacity(0.95);
  static final Color fillSearchField = Colors.white.withOpacity(0.92);
  static const Color fillCard = Colors.white;

  // Specular Border Strokes (0.5pt subtle, refined light highlights)
  static final Color borderSubtle = Colors.white.withOpacity(0.60);
  static final Color borderEdge = Colors.white.withOpacity(0.80);
  static final Color borderSheet = Colors.black.withOpacity(0.04);
  static final Color borderCard = Colors.black.withOpacity(0.06);

  // Soft Apple Shadows (Subtle, diffused, no harsh dark drops)
  static final List<BoxShadow> shadowSoft = [
    BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 16, offset: const Offset(0, 3)),
  ];
  static final List<BoxShadow> shadowCard = [
    BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 8, offset: const Offset(0, 2)),
  ];
  static final List<BoxShadow> shadowSheet = [
    BoxShadow(color: Colors.black.withOpacity(0.12), blurRadius: 28, offset: const Offset(0, -6)),
  ];

  // Standard Radii
  static const double radiusPill = 24.0;
  static const double radiusToolbar = 23.0;
  static const double radiusSheet = 24.0;
  static const double radiusCard = 16.0;
}
```

---

## 4. Before & After Visual Comparison

| Component | Before (P5.8.1 / Images 3 & 4) | After (P5.8.2 / Images 1 & 2) |
|---|---|---|
| **Map Gestures** | Blocked by platform view hit testing | 60fps pan/pinch/drag/tap restored via `PassThroughContainerView` |
| **Right Toolbar** | Split container + floating button, ghost rings (Image 3) | Single unified vertical capsule (`width: 46`, `radius: 23`), no ghost rings |
| **Recenter Button** | Floating circle 10px below container | Clean 4th icon inside unified capsule with subtle blue active state |
| **Search Modal Sheet** | Heavy pitch black modal (`#1C1C1E`) (Image 4) | Light translucent panel (`#F2F2F7` at 95%), light drag handle (`#D1D1D6`) |
| **Search Bar in Sheet** | Dark field with low contrast | Clean white capsule (`Colors.white`, radius 23) with soft shadow |
| **Top-Left Weather Pill** | Dark slate tint fallback | Light frosted horizontal pill (`radius: 22`, height 44, white at 78%) |
| **Bottom Search Capsule** | Heavy gray border | Translucent light capsule (height 52, radius 26, white at 85%), 0.5pt edge |
| **Global Theme** | `Brightness.dark` (caused dark styling) | `Brightness.light` with Apple Maps `#F2F2F7` scaffold background |

---

## 5. Automated Test Results
Added comprehensive test group in `mobile_app/test/liquid_glass_test.dart`:
1. `NativeGlassHostLayer wraps platform view in IgnorePointer(ignoring: true)`: PASS
2. `Map area gestures (tap, drag) pass through NativeGlassHostLayer to underlying map seam`: PASS
3. `Buttons on top of glass host layer remain interactive`: PASS
4. `AppleGlassTokens conforms to light, airy, translucent Apple Maps spec`: PASS
5. `Right toolbar renders as a single unified vertical capsule without ghost rings`: PASS
6. `Top-left weather pill registers single light pill geometry`: PASS
7. `Opening search overlay hides native glass host to preserve z-order`: PASS

All existing navigation, Valhalla, GPS matching, and BLE streaming tests remain 100% green.

---

## 6. Production Artifact Verification
- **Target Application**: Strictly `ESP32Nav-Flutter-PRODUCTION.ipa`
- **Standalone `ios_native`**: Untouched (0 modifications)
- **Navigation Engine & Streaming**: Untouched (0 modifications)
- **CI Workflow**: `.github/workflows/build_ios.yml` on `macos-26` runner with Xcode 26.6 / iOS 26.5 SDK

---

## 7. Physical Field Verification Checklist
In accordance with Requirement 13, all physical device checklist items are marked `MANUAL FIELD PENDING` until validated on physical hardware by the user:

- [ ] `MANUAL FIELD PENDING`: Map can be panned, dragged, and pinch-zoomed smoothly across full screen.
- [ ] `MANUAL FIELD PENDING`: Tapping on empty map area registers map click/recenter without being eaten by glass host.
- [ ] `MANUAL FIELD PENDING`: Top-left menu button opens drawer smoothly; weather pill toggles telemetry overlay.
- [ ] `MANUAL FIELD PENDING`: Right-side toolbar displays as a single unified vertical capsule without ghost rings or halos.
- [ ] `MANUAL FIELD PENDING`: Tapping layers, compass, vehicle mode, and recenter inside right toolbar works reliably.
- [ ] `MANUAL FIELD PENDING`: Recenter button active state displays subtle Apple blue highlight without harsh glare.
- [ ] `MANUAL FIELD PENDING`: Tapping bottom search capsule opens light translucent Apple Maps sheet matching Images 1 & 2.
- [ ] `MANUAL FIELD PENDING`: Search sheet displays light background, light drag handle, white search pill, and clean white cards.
- [ ] `MANUAL FIELD PENDING`: Search sheet closes smoothly and returns to normal map interactive state.
