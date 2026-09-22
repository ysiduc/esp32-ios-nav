# P5.7.2 — Live Accessibility Rebuild, Glass Capability Detection & Honest Backend Telemetry

**Phase:** P5.7.2  
**Repository:** `ysiduc/esp32-ios-nav`  
**Branch:** `main`  
**Execution Scope:** Production Flutter App Only (`ESP32Nav-Flutter-PRODUCTION.ipa`)  
**Commit 1 (Implementation):** `49a9b004c36b7ba6c52fd7a8cad7e30036e38431` (`fix(ui): P5.7.2 rebuild glass live and report real backend capability`)  
**Commit 2 (iOS Build Fix):** `43a7c588a0019abf116e1c82a3d335f8935866f1` (`fix(ios): move reduceTransparencyObserver deinit into AppDelegate class`)  
**Commit 3 (Docs & Evidence):** `e20522ff6cf50953c3065b262a63ae84180425a7` (`docs: record P5.7.2 glass accessibility evidence`)  
**CI Run ID:** `35753795985`  
**Flutter Test Count:** 165 passed (increased from 163 in P5.7.1, 157 in P5.7)  
**Field Test Status:** `MANUAL FIELD PENDING` (physical iPhone validation required)  

---

## 1. Executive Summary & Root Cause Analysis

### A. Root Cause: `ChangeNotifier` Unobserved in `AppGlassSurface`
In Phase P5.7.1, `AppAccessibilityService` was created as a singleton extending `ChangeNotifier` to receive `UIAccessibility.reduceTransparencyStatusDidChangeNotification` over MethodChannel `com.ysiduc.esp32_nav/accessibility`.
However, `AppGlassSurface` was implemented as a simple `StatelessWidget` that only read the static value:
```dart
final isReduceTransparency = reduceTransparency ?? AppAccessibilityService.instance.reduceTransparency;
```
It did **not** subscribe to `AppAccessibilityService.instance`. Consequently, when a user toggled **Reduce Transparency** in iOS Settings (`Settings -> Accessibility -> Display & Text Size -> Reduce Transparency`) while the app was running, the MethodChannel callback fired and updated `_reduceTransparency`, but `AppGlassSurface` instances remained unchanged until the parent widget tree or the entire screen was forced to rebuild.

### B. Misleading `nativeModern` Telemetry
Prior to P5.7.2, `AppGlassBackendType.nativeModern` existed in the codebase as a theoretical option, and unit tests tested `forceBackendForTesting = AppGlassBackendType.nativeModern`. However:
1. No production detection mechanism existed to verify whether the underlying iOS SDK actually provides a modern Liquid Glass API.
2. In `AppDelegate.swift`, `setupModernLiquidGlass()` delegates directly to `setupUIKitVisualEffect()`.
3. Xcode 16 / iOS 18 SDK does not expose public Liquid Glass classes. Claiming `native-modern` would be false advertising.

---

## 2. P5.7.2 Architectural Fixes

### A. Live Dynamic Rebuild via `ListenableBuilder`
Instead of introducing global state management bloat (e.g., app-wide Provider or InheritedWidget), `AppGlassSurface` wraps its surface builder in `ListenableBuilder`:
```dart
@override
Widget build(BuildContext context) {
  if (reduceTransparency != null) {
    return _buildSurface(context, reduceTransparency!);
  }

  return ListenableBuilder(
    listenable: AppAccessibilityService.instance,
    builder: (context, _) => _buildSurface(
      context,
      AppAccessibilityService.instance.reduceTransparency,
    ),
  );
}
```
* **Live Semantics Guaranteed:**
  * **Reduce Transparency OFF:** `AppGlassSurface` mounts `UiKitView(viewType: 'plugins.ysiduc.com/native_glass')` on iOS.
  * **User turns ON in iOS Settings:** `NotificationCenter` -> `MethodChannel` -> `AppAccessibilityService.notifyListeners()` -> `ListenableBuilder` triggers rebuild -> `_buildSurface` replaces `UiKitView` with solid high-contrast container.
  * **User turns OFF in iOS Settings:** `ListenableBuilder` rebuilds immediately -> `UiKitView` returns.
  * Zero parent rebuild required.

### B. Honest Backend Capability MethodChannel & Semantics
A new native capability query `getGlassCapability` was added to `com.ysiduc.esp32_nav/accessibility` in `AppDelegate.swift`:
```swift
case "getGlassCapability":
  // In Xcode 16/iOS 18 SDK, UIKit UIVisualEffectView fallback is used.
  // When a true modern Liquid Glass API is actually exposed in future Apple SDKs,
  // this will return "native-modern".
  result("native-blur-fallback")
```
* **Honest Disclosure:**
  * Modern Apple Glass API is **NOT** used because Xcode 16 / iOS 18 does not provide public modern Liquid Glass APIs.
  * The production resolver on iOS always reports: **`native-blur-fallback`**.
  * `AppGlassBackendType.nativeModern` is strictly retained for forward-looking synthetic testing and will only be resolved if native Swift explicitly returns `"native-modern"`.

### C. Observer Lifecycle & Memory Leak Prevention
In `AppDelegate.swift`:
```swift
private var accessibilityChannel: FlutterMethodChannel?
private var reduceTransparencyObserver: NSObjectProtocol?
```
Before registering the notification observer in `setupChannels`, any existing observer is cleanly unregistered:
```swift
if let existing = reduceTransparencyObserver {
  NotificationCenter.default.removeObserver(existing)
  reduceTransparencyObserver = nil
}
reduceTransparencyObserver = NotificationCenter.default.addObserver(...)
```
And `deinit` safely releases the observer, preventing memory leaks and duplicate callbacks across Flutter engine reloads.

### D. Live Telemetry on MapScreen Debug Overlay
In `mobile_app/lib/screens/map_screen.dart`, the debug overlay telemetry string is also wrapped in `ListenableBuilder`:
```dart
ListenableBuilder(
  listenable: AppAccessibilityService.instance,
  builder: (context, _) => Text(
    'Glass backend: ${AppGlassBackend.currentName(context)}',
    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF5E5CE6)),
  ),
),
```
Toggling Reduce Transparency immediately updates the debug text on-screen between `native-blur-fallback` and `opaque-fallback`.

---

## 3. Verification & Test Evidence

### A. New Tests Added
1. **Live Rebuild Without Parent Rebuild Test:**
   * `Live Reduce Transparency switch dynamically rebuilds AppGlassSurface without parent rebuild`:
     - Renders `AppGlassSurface` with initial `reduceTransparency = false`.
     - Asserts `UiKitView` exists, `BackdropFilter` is absent.
     - Calls `AppAccessibilityService.instance.setReduceTransparencyForTesting(true)` and `await tester.pump()`.
     - Asserts `UiKitView` disappears, `BackdropFilter` is absent, solid opaque surface is rendered.
     - Calls `AppAccessibilityService.instance.setReduceTransparencyForTesting(false)` and `await tester.pump()`.
     - Asserts `UiKitView` reappears.
2. **Production Resolver Capability Test:**
   * `Production resolver on iOS with current capability=blur resolves to native-blur-fallback`:
     - Verifies production iOS resolver outputs `AppGlassBackendType.nativeBlurFallback` and telemetry string `'native-blur-fallback'`.

### B. Test Suite Execution
* **Analyzer:** `flutter analyze --no-fatal-infos` -> **0 issues found**.
* **Liquid Glass Suite:** `flutter test test/liquid_glass_test.dart` -> **23 / 23 passed**.
* **Total Flutter Suite:** `flutter test` -> **165 / 165 passed** (all navigation, reroute, cancel barrier, and parser tests passing).
* **ESP32 Firmware:** `pio run -e esp32-s3` -> **SUCCESS (3.81s)** (RAM: 41.3%, Flash: 35.9%).

---

## 4. Manual Field Validation Checklist (Pending)

1. [ ] **Live Setting Toggle:** Open app on physical iPhone, navigate to iOS Settings -> Accessibility -> Display & Text Size -> Reduce Transparency; toggle ON and switch back to app; verify all glass surfaces immediately turn solid high-contrast opaque.
2. [ ] **Live Setting Restore:** Toggle Reduce Transparency OFF; verify surfaces immediately return to native blur.
3. [ ] **Debug Overlay Telemetry:** Verify overlay displays `Glass backend: native-blur-fallback` when OFF, and `Glass backend: opaque-fallback` when ON.
4. [ ] **Gesture Responsiveness:** Confirm top driving banner, right toolbar, bottom dock, and search pill remain fully interactive during and after live rebuilds.
