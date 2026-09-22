# P5.6.2 — IMMEDIATE SECONDARY RENDER INTEGRATION FIX

## 1. Overview & Clarification
- **Production Path**: The user installs and runs **ONLY the Flutter IPA** (~12 MB): `ESP32Nav-Flutter-PRODUCTION.ipa`. The production codebase is strictly `mobile_app/lib/`, `mobile_app/ios/`, and `firmware_esp32/`. Code under `mobile_app/ios_native/` is an algorithmic reference only.
- **Phase Purpose**: Resolves the immediate visual rendering integration gap for asynchronous secondary rejoin routes:
  1. `MapScreen` observation logic replaced to track `navManager.renderRevision` instead of `routeRevision`.
  2. Ensures that when the secondary rejoin Future completes, `renderRevision` changes and triggers an immediate map redraw, even if the vehicle is stationary and zero GPS updates have arrived.
  3. Secondary fallback also redraws immediately on route failure or exception.
  4. Cancelling navigation immediately clears all route polylines.
  5. Corrected secondary failure semantics: if a rejoin request fails or throws an exception but old remaining geometry exists, the status remains `'fallback'` (only marked `'failed'` if no secondary geometry can be displayed).
- **ESP32 Invariant**: Streaming architecture remains strictly unchanged from P5.4.1.4 (smooth JPEG/raster map stream over Wi-Fi/BLE, no vector map on ESP).
- **Routing Engine Invariant**: Routing provider remains Valhalla motorcycle routing.

---

## 2. Root Cause Analysis & Technical Solutions

### GAP A — Observation Mismatch in MapScreen
- **The Issue in P5.6.1**:
  - In P5.6.1, `NavigationManager` synthesized `renderRevision` as `_routeRevision + _secondaryRouteRevision`.
  - When the primary Route B committed, `_routeRevision` was incremented.
  - When the asynchronous secondary rejoin Future resolved in the background, only `_secondaryRouteRevision` was incremented.
  - However, `MapScreen._onNavigationManagerChanged()` was still checking:
    ```dart
    final rev = navManager.routeRevision;
    if (rev != _lastObservedRouteRevision || isNav != _lastObservedNavigating) { ... }
    ```
  - Because `routeRevision` was unchanged when secondary arrived, `MapScreen` ignored the notification!
  - If the vehicle was stationary (e.g. stopped at a red light after turning onto Route B) and no new GPS updates arrived, the secondary route was never rendered on screen until the vehicle moved and generated a GPS update.
- **The Solution (P5.6.2)**:
  - Replaced `_lastObservedRouteRevision` with `_lastObservedRenderRevision = -1;`.
  - Initialized in `initState()` post frame callback:
    ```dart
    _lastObservedRenderRevision = navManager.renderRevision;
    _lastObservedNavigating = navManager.isNavigating;
    ```
  - Updated `_onNavigationManagerChanged()`:
    ```dart
    final rev = navManager.renderRevision;
    final isNav = navManager.isNavigating;

    if (rev != _lastObservedRenderRevision || isNav != _lastObservedNavigating) {
      _lastObservedRenderRevision = rev;
      _lastObservedNavigating = isNav;
      if (!isNav) {
        _routes = [];
        _routeRenderController.reset();
      }
      _throttledUpdateRouteOnMap(forceRedraw: true);
    }
    ```
  - Removed any lingering listener using `routeRevision`.

---

### GAP B — Secondary Rejoin Failure Semantics
- **The Issue in P5.6.1**:
  - In `_calculateSecondaryRejoin()`, the `.catchError` block unconditionally set `_secondaryRerouteStatus = 'failed'`, even if `_secondaryRoute` had already been populated with the old remaining route snapshot (`frozenOldRemaining`).
- **The Solution (P5.6.2)**:
  - In both the `.then` error branch and the `.catchError` block:
    ```dart
    if (_secondaryRoute != null && _secondaryRoute!.polylinePoints.isNotEmpty) {
      _secondaryRerouteStatus = 'fallback';
    } else if (oldRemaining.isNotEmpty) {
      _secondaryRoute = NavRoute(
        totalDistanceMeters: 0,
        totalDurationSeconds: 0,
        polylinePoints: oldRemaining,
        steps: const [],
        summary: 'Lộ trình cũ',
      );
      _secondaryRerouteStatus = 'fallback';
    } else {
      _secondaryRerouteStatus = 'failed';
    }
    _secondaryRouteRevision++;
    notifyListeners();
    ```
  - Only when no secondary geometry exists to display is the status set to `'failed'`.

---

## 3. Summary of Files Changed

| File | Changes Made |
|---|---|
| `mobile_app/lib/screens/map_screen.dart` | Replaced `_lastObservedRouteRevision` with `_lastObservedRenderRevision`; `_onNavigationManagerChanged` now observes `navManager.renderRevision`; triggers immediate redraw on secondary arrival |
| `mobile_app/lib/services/navigation_manager.dart` | Updated secondary failure semantic in `.catchError` and `.then` fallback: retains old remaining route as `'fallback'` if geometry exists; bumps `_secondaryRouteRevision++` |
| `mobile_app/test/navigation_reroute_test.dart` | Added regression test for zero-GPS async secondary arrival triggering immediate map-render callback; added test for secondary exception fallback with preserved geometry |

---

## 4. Verification Results

### 4.1 Flutter Analyze
```text
$ flutter analyze --no-fatal-infos
Analyzing mobile_app...
No issues found! (ran in 1.5s)
```

### 4.2 Flutter Test Suite
```text
$ flutter test
00:12 +143: All tests passed!
```
Total Flutter tests: **143 passed** (+2 regression tests added in P5.6.2, baseline was 141).

### 4.3 PlatformIO Firmware Build
```text
$ pio run -d firmware_esp32
PLATFORM: Espressif 32 (7.1.2) > Espressif ESP32-S3-DevKitC-1-N8
RAM:   [====      ]  41.3% (used 135416 bytes from 327680 bytes)
Flash: [====      ]  35.9% (used 1200069 bytes from 3342336 bytes)
========================= [SUCCESS] Took 4.43 seconds =========================
```

---


### 4.4 GitHub Actions CI Verification
- **CI Run ID**: `35743275232` (Workflow: *Build iOS IPA Packages*)
- **Code Commit SHA**: `8cc4a3ad66579463acd4c00ded9b8c68198af2a4`
- **Jobs Status**:
  - `Compile Flutter iOS IPA`: **SUCCESS** (3m43s)
  - `Compile ESP32-S3 Firmware`: **SUCCESS** (1m38s)
  - `Compile Native iOS Swift/SwiftUI`: **SUCCESS** (5m10s)
- **Produced Production Artifact**: `ESP32Nav-Flutter-PRODUCTION-ipa` (~12 MB)
- **Reference Artifacts**: `esp32_firmware_bin`, `ESP32Nav-Native-REFERENCE-ipa`

## 5. Verification Status Matrix

| Requirement | Automated Status | Manual Field Status | Notes |
|---|---|---|---|
| **MapScreen renderRevision Observation** | **AUTOMATED VERIFIED** | **MANUAL FIELD PENDING** | MapScreen now tracks `renderRevision`; triggers immediate redraw on secondary rejoin without GPS updates. |
| **Zero GPS Update Secondary Redraw** | **AUTOMATED VERIFIED** | **MANUAL FIELD PENDING** | Verified in `navigation_reroute_test.dart`: Route B commits, 0 GPS updates sent, secondary arrives -> immediate map drawer trigger. |
| **Secondary Exception Fallback** | **AUTOMATED VERIFIED** | **MANUAL FIELD PENDING** | Secondary network timeout preserves old remaining geometry; status is `'fallback'`, `secondaryPolyline.isNotEmpty == true`. |
| **Primary Route & Guidance Invariance** | **AUTOMATED VERIFIED** | **MANUAL FIELD PENDING** | Secondary async resolution does not alter active Route B, maneuver step, ETA, or banner instruction. |
| **Navigation Cancellation Cleanliness** | **AUTOMATED VERIFIED** | **MANUAL FIELD PENDING** | Stopping navigation resets controller and clears polylines immediately. |
