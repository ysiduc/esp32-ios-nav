# P5.7 — Field Maneuver Direction Fix, Hard Route Clear Barrier & Adaptive iOS Liquid Glass UI

**Branch:** `main`  
**Execution Context:** Production Flutter App Only (`ESP32Nav-Flutter-PRODUCTION.ipa`)  
**Commit 1 (Navigation Correctness):** `1d3e1a7b45fa6747209930f3f221469e38d3862b` (`fix(nav): correct start maneuver direction and guarantee final route clear`)  
**Commit 2 (Liquid Glass UI):** `d87b088db04d2ebd2a9172e721c430a59fd7f93c` (`feat(ui): introduce native adaptive Liquid Glass map interface`)  
**CI Run ID:** `35748819204`  
**Flutter Test Count:** 157 passed (increased from 143 in baseline)  
**Field Test Status:** `MANUAL FIELD PENDING` (iPhone field validation required)

---

## 1. Executive Summary

Phase P5.7 solves two high-severity navigation field anomalies and delivers an adaptive, high-performance **Liquid Glass** user interface for the production Flutter iOS app (`ESP32Nav-Flutter-PRODUCTION.ipa`):
1. **Maneuver Direction Correctness (Part A):** Fixed critical semantic bug where Valhalla departure maneuvers with directional modifiers (such as `kStartRight` / `kStartLeft` or start followed by slight/sharp turns) were unconditionally converted to straight departure arrows (`Icons.navigation_rounded`), ignoring the user's upcoming turn direction.
2. **Hard Route Clear Barrier (Part B):** Fixed race condition where cancelling active navigation left the polyline on MapLibre because in-flight render transactions completed after UI teardown. Built `RouteRenderController.clearAndInvalidate()` epoch-generation barrier guaranteeing empty map state.
3. **Adaptive iOS Liquid Glass Design System (Parts C – I):** Implemented Apple-inspired Liquid Glass material hierarchy (`AppGlassSurface`, `AppGlassPill`, `AppGlassButton`, `AppGlassToolbar`, `AppGlassBottomBar`), native iOS `PlatformView` UIKit bridge (`NativeGlassPlatformView` via `UIVisualEffectView`), and zero-overhead Flutter BackdropFilter fallback with accessibility adaptations.

---

## 2. Part A — Maneuver Icon Direction Root Cause & Fix

### 2.1 Field Evidence & Root Cause
* **Symptom:** Driving geometry clearly shows an impending left turn, banner reads "Trong 209 m ...", but the icon displays a straight/start arrow (`Icons.navigation_rounded`).
* **Root Cause In `NavStep.maneuverType`:**
  Previously, `NavStep.maneuverType` contained an early-return check:
  ```dart
  if (maneuverTypeStr == 'depart') return ManeuverType.depart;
  ```
  In Valhalla:
  * Type 1: `kStart`
  * Type 2: `kStartRight`
  * Type 3: `kStartLeft`
  All three were mapped by `_mapValhallaTypeToString()` to `depart`.
  Consequently, `kStartRight` and `kStartLeft` had modifier `'slight right'` / `'slight left'`, but the early-return swallowed the modifier completely and returned `ManeuverType.depart`. This caused `NavigationManager.bannerTurnIcon` to return `Icons.navigation_rounded` (straight arrow) rather than a right or left turn icon.

### 2.2 Semantic Fix
In `mobile_app/lib/models/route_model.dart`:
```dart
if (maneuverTypeStr == 'depart') {
  final mod = (maneuverModifier ?? '').toLowerCase();
  if (mod.contains('sharp right')) return ManeuverType.turnSharpRight;
  if (mod.contains('slight right')) return ManeuverType.turnSlightRight;
  if (mod.contains('right')) return ManeuverType.turnRight;
  if (mod.contains('sharp left')) return ManeuverType.turnSharpLeft;
  if (mod.contains('slight left')) return ManeuverType.turnSlightLeft;
  if (mod.contains('left')) return ManeuverType.turnLeft;
  if (mod.contains('uturn') || mod.contains('u-turn')) return ManeuverType.uturn;
  return ManeuverType.depart;
}
```
* **Raw Valhalla Mapping:** `valhallaType` is now preserved on every `NavStep`.
* **Telemetry Exposure:** Added telemetry properties on `NavigationManager`:
  * `authoritativeStepIndex`
  * `authoritativeValhallaType`
  * `authoritativeManeuverTypeStr`
  * `authoritativeManeuverModifier`
  * `authoritativeBeginShapeIndex`
  * `distanceToManeuver`

---

## 3. Part B — Hard Route Clear Barrier Architecture

### 3.1 Race Condition Analysis
* **Symptom:** Tapping the End Route button ('X') closed the navigation HUD and returned to the search screen, but the blue polyline remained on the MapLibre canvas.
* **Root Cause:**
  When `RouteRenderController.reset()` was called, it reset controller state (`_lastMode = RenderMode.none`, `_pendingRequest = null`). However, if an asynchronous transaction `await _drawer.drawActiveRoute(...)` was already actively executing in MapLibre's render queue, it would finish *after* `reset()` and leave the polyline drawn. Direct calls to `_mapController.clearLines()` in the UI ran *before* that in-flight transaction finished, creating an irrecoverable stale route race.

### 3.2 Solution: `RouteRenderController.clearAndInvalidate()`
We engineered a unified final-barrier method:
```dart
Future<void> clearAndInvalidate() async {
  _latestSubmittedGeneration++;
  _pendingRequest = null;
  _lastMode = RenderMode.none;
  _lastDrawnGeometryKey = null;

  // Wait for any in-flight transaction to finish
  final activeDrain = _activeDrainCompleter;
  if (activeDrain != null) {
    try {
      await activeDrain.future;
    } catch (_) {}
  }

  // Final barrier: perform absolute clearLines
  await _drawer.clearLines();
}
```
* Increments generation counter to invalidate all stale requests.
* Waits for in-flight drawer tasks to complete cleanly.
* Issues an unconditional, atomic `clearLines()` barrier.
* Guarantees map lines count = 0 upon Future completion.
* UI lifecycle hook in `MapScreen._onNavigationManagerChanged` and End Route button centralizes teardown through `clearAndInvalidate()`.

---

## 4. Parts C – I — Adaptive iOS Liquid Glass UI System

### 4.1 Design Principles & Restraint (Apple Liquid Glass)
* **Live Background:** Edge-to-edge MapLibre map remains the focal hero surface. Glass overlays diffuse and tint the map without obscuring navigation details.
* **Visual Hierarchy (Variants):**
  * `AppGlassVariant.prominent`: High-contrast, dark obsidian glass (`0xFF0F172A` / `0xFF1C1C1E`) with subtle diffusion, designed specifically for driving mode banners.
  * `AppGlassVariant.regular`: Translucent frosted glass with specular highlight edge (`0.5px` border with `0.20-0.45` alpha).
  * `AppGlassVariant.clear`: Maximum transparency for unobtrusive floating chips and icon circles.
  * `AppGlassVariant.danger`: Translucent ruby/crimson tinted glass with crisp white icons for destructive/cancel actions.
* **Single BackdropFilter per Group:** Grouped toolbars and docks (`AppGlassToolbar`, `AppGlassBottomBar`) encapsulate multiple controls within a single `BackdropFilter` to prevent multi-layer GPU fill-rate exhaustion.

### 4.2 Component Architecture (`mobile_app/lib/widgets/liquid_glass.dart`)
1. `AppGlassSurface`: Foundation widget featuring specular edge lighting, inner depth, dark/light adaptation, and `reduceTransparency` fallback.
2. `AppGlassPill`: Fully rounded floating capsule (used for bottom search bar, ESP32 live badge, and floating street pill).
3. `AppGlassButton`: Tactile button with spring compression physics (`scale 1.0 -> 0.92`), dark/light contrast management, and dedicated danger tinting.
4. `AppGlassToolbar` & `AppGlassToolbarDivider`: Unified vertical action dock grouping mode switch and GPS recentering.
5. `AppGlassBottomBar`: Navigation dock encapsulating ETA clock, duration, distance, and danger cancel button.

### 4.3 Native iOS UIKit Material Integration
* Added native platform view factory `NativeGlassPlatformView` in `mobile_app/ios/Runner/AppDelegate.swift`.
* Uses `UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))` on iOS with specular highlight edge layer.
* Seamlessly complements Flutter rendering with native iOS compositor efficiency.

### 4.4 Accessibility & Fallbacks
* **Reduce Transparency:** When enabled via `MediaQuery.accessibleNavigation` or explicit configuration, disables all `BackdropFilter` effects and switches to high-contrast opaque solid fills.
* **Reduce Motion:** When enabled via `MediaQuery.disableAnimations`, disables button scale animations.

---

## 5. Test Verification Matrix

| Area | Tests Added / Updated | Result |
| :--- | :--- | :--- |
| **Maneuver Valhalla Pipeline** | Start generic (type 1) → straight/depart icon | **PASS** |
| | StartRight (type 2) → right icon | **PASS** |
| | StartLeft (type 3) → left icon | **PASS** |
| | 209 m before normal left (type 10) → left turn icon | **PASS** |
| | Sharp / slight right & left (types 11, 14, 15) → directional icons | **PASS** |
| | U-turn (type 12) → U-turn icon | **PASS** |
| | Text, icon, distance synchronized with authoritative step | **PASS** |
| **Clear Barrier Race** | Old draw in-flight → cancel → map empty | **PASS** |
| | Clear phase in-flight → cancel → map empty | **PASS** |
| | Rapid cancel / start / cancel cycle | **PASS** |
| | Primary reroute pending → cancel → late Route B dropped | **PASS** |
| **Liquid Glass UI** | `AppGlassSurface` variants (`regular`, `clear`, `prominent`, `danger`) | **PASS** |
| | Reduce Transparency opaque fallback (0 `BackdropFilter`) | **PASS** |
| | `AppGlassPill` child rendering & onTap callback | **PASS** |
| | `AppGlassButton` danger variant styling & white icon contrast | **PASS** |
| | `AppGlassToolbar` & divider single `BackdropFilter` architecture | **PASS** |
| | Active driving banner layout & maneuver icon glass circle | **PASS** |
| | Bottom HUD ETA, Duration, Distance & Danger End Button | **PASS** |
| | ESP32 Live green tint vs ESP32 Off badge state | **PASS** |
| **Firmware Build** | PlatformIO ESP32-S3 firmware release compilation | **PASS** |
| **Total Test Count** | **157 unit & widget tests** (Baseline: 143) | **ALL PASS** |

---

## 6. Field Validation Items (`MANUAL FIELD PENDING`)

The following real-world tests remain **PENDING** until verified during a live drive on an iPhone running `ESP32Nav-Flutter-PRODUCTION.ipa`:
1. [ ] **Start Maneuver Field Check:** Depart from intersection requiring immediate left/right turn; verify top banner shows turn arrow immediately upon departure.
2. [ ] **209 m Maneuver Check:** Drive toward a 90-degree left turn; verify distance decrements monotonically and turn icon matches road geometry.
3. [ ] **Hard Cancel Test:** While actively driving and moving, tap the Red Glass Cancel Button ('X'); verify polyline vanishes immediately from MapLibre and never reappears.
4. [ ] **Glass Readability Under Direct Sunlight:** Verify prominent dark glass banner retains crisp contrast against bright map tiles.
5. [ ] **ESP32 BLE HUD Frame Rate:** Verify ESP32 HUD stream maintains 10-15 FPS during continuous map panning and Liquid Glass overlay transitions.
