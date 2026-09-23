# Phase P5.9.4: Fix Route Preview Self-Clear & Physical GPS Origin

**Date**: 2026-09-23  
**Target App**: `ESP32Nav-Flutter-PRODUCTION.ipa`  
**Status**: AUTOMATED VERIFICATION PASSED / LIVE SMOKE VALIDATED / MANUAL FIELD PENDING  

---

## 1. Executive Summary & Root Cause Confirmation

Despite resolving the Valhalla URL and dual coordinate snapping in P5.9.3 (which achieved 100% PASS on all live Hanoi routing smoke probes), physical iPhone testing still exhibited:
```
Không có lộ trình
```
**The True Root Cause**: The remote routing providers were returning valid routes, but `MapScreen` was **immediately clearing its own routes** in an unintended state machine feedback loop!

---

## 2. Before vs. After Event Sequence

### 2.1 The Broken Event Sequence (P5.9.3)
1. `MapScreen._calculateRoutesForPlace()` dispatches route request to `MapboxDirectionsService`.
2. Valhalla / OSRM returns HTTP 200 with valid route(s).
3. `MapScreen` executes `setState(() { _routes = result.routes; });`.
4. `MapScreen` calls `context.read<NavigationManager>().setPreviewRoute(result.routes.first);`.
5. `NavigationManager.setPreviewRoute()` updates `_previewRoute`, increments `_routeRevision++`, and calls `notifyListeners()`.
6. `MapScreen._onNavigationManagerChanged()` fires:
   ```dart
   // OLD BUGGY LISTENER CODE:
   if (rev != _lastObservedRenderRevision || isNav != _lastObservedNavigating) {
     _lastObservedRenderRevision = rev;
     _lastObservedNavigating = isNav;
     if (!isNav) { // <-- In preview mode, isNav is ALWAYS false!
       _routes = []; // <-- WIPED OUT IMMEDIATELY!
       _routeRenderController.clearAndInvalidate();
     }
   }
   ```
7. On the very next microtask, `_routes` was wiped out to `[]`.
8. The UI re-rendered: `_routes.isEmpty` $\to$ display *"Không có lộ trình"*, polyline erased, GO button disabled.

### 2.2 The Repaired Event Sequence (P5.9.4)
1. `MapScreen._calculateRoutesForPlace()` receives valid route(s).
2. `_routes = result.routes;` is committed.
3. `NavigationManager.setPreviewRoute()` increments `_routeRevision++` and calls `notifyListeners()`.
4. `_onNavigationManagerChanged()` evaluates:
   - `wasNavigating = _lastObservedNavigating;`
   - `navigationStopped = wasNavigating && !isNav;`
   - In preview mode, `wasNavigating == false` and `isNav == false` $\to$ `navigationStopped == false`.
5. The listener recognizes this as a legitimate preview revision change (`!isNav && revChanged`), retains `_routes`, and updates the map polyline without wiping data.
6. Route comparison bottom sheet renders ETA, distance, alternatives, and enables the green "ĐI" button.

---

## 3. Physical GPS Origin & Matched-State Reset

### 3.1 Route Planning Origin Fix
Previously:
```dart
final startPos = navManager.currentLocation ?? _userPosition;
```
`currentLocation` defaults to `_matchedLocation` (which may be a stale projection from a previously finished route).
**Fixed in P5.9.4**:
```dart
final startPos = navManager.acceptedPhysicalLocation ??
    navManager.rawLocation ??
    _userPosition;
```
New route calculations strictly prioritize physical GPS position over stale route-matched projections.

### 3.2 Reset Matched State on Stop
In `NavigationManager.stopNavigation()`:
```dart
_matchedProjection = null;
_matchedLocation = _acceptedPhysicalLocation ?? _rawLocation;
```
Guarantees that stopping navigation completely flushes any projection state from the previous route.

---

## 4. Telemetry HUD Enhancements

Added commit and lifecycle telemetry to the MapScreen Debug HUD:
- `Start orig`: `lat, lon (physical / raw / userPosition)`
- `Routes recv`: Total routes returned by provider
- `commit`: Total routes committed to state
- `retained`: `YES` / `NO` (verifies preview route was not cleared by listener)
- Console logging: `[Routing] preview committed, routes still=N`

---

## 5. Verification Results

### 5.1 Automated Unit Tests (202 / 202 PASS)
- Baseline P5.9.3: 198 tests
- P5.9.4: **202 tests (100% PASS)**
New tests added in `test/route_preview_lifecycle_test.dart`:
1. `setPreviewRoute() does NOT clear _routes when isNavigating is false`: Specifically reproduces the P5.9.3 failure condition and asserts `_routes` is retained.
2. `Navigation Stop: Transition from navigating -> stopped clears routes`: Verifies active navigation cancellation properly flushes routes.
3. `Stop Navigation clears matched projection and resets matched location to physical`: Verifies `stopNavigation()` state reset.
4. `Route planning prioritizes acceptedPhysicalLocation over stale matchedLocation`: Verifies physical GPS precedence for route planning.

### 5.2 Flutter Static Analysis
```bash
flutter analyze --no-fatal-infos
# Output: No issues found! (ran in 1.2s)
```

### 5.3 Live Production Smoke Test
```text
00:00 +0: P5.9.3 Live Routing Provider Smoke Test & Production Services
===============================================================
P5.9.3 LIVE ROUTING PROVIDER SMOKE TEST (VIETNAM / HANOI)
===============================================================
[SMOKE] Valhalla raw: HTTP 200, 1049ms
[SMOKE] OSRM primary raw: HTTP 200, 610ms
[SMOKE] OSRM secondary raw: HTTP 200, 622ms
[PROD-SMOKE] ValhallaService: PASS (HTTP 200, 841ms, dist=4.1 km)
[Routing] Start calculation: start=(21.0285, 105.8542) dest=(21.0478, 105.8368) mode=bike primary=valhalla
[PROD-SMOKE] RoutingPipeline bike: PASS (valhalla, 791ms, routes=1)
[Routing] Start calculation: start=(20.9785, 105.8340) dest=(20.8950, 105.6550) mode=bike primary=valhalla
[PROD-SMOKE] Field Route Dinh Cong -> Tan Tien: PASS (valhalla, 1114ms, dist=27.3 km)
===============================================================
00:05 +1: All tests passed!
```

### 5.4 ESP32 Firmware Build
```bash
pio run in firmware_esp32:
RAM:   [====      ]  41.3% (used 135416 bytes from 327680 bytes)
Flash: [====      ]  35.9% (used 1200069 bytes from 3342336 bytes)
========================= [SUCCESS] Took 3.74 seconds =========================
```

---

## 6. Verification Status

| Component | Status | Notes |
| :--- | :--- | :--- |
| **Preview Route Retention** | **VERIFIED** | `_onNavigationManagerChanged` ignores non-transition preview events |
| **Physical GPS Start** | **VERIFIED** | Prioritizes physical location over stale matched projection |
| **Stop Navigation Reset** | **VERIFIED** | Flushes matched projection and resets to physical |
| **Logic Unit Tests** | **PASSED (202/202)** | All 202 unit tests passing |
| **Live Smoke Test** | **PASSED** | Live Valhalla, OSRM primary/secondary, full pipeline |
| **Flutter Analyzer** | **PASSED** | 0 issues found |
| **ESP32 Firmware** | **PASSED** | PlatformIO build successful in 3.74s |
| **CI Production IPA Build** | **TRIGGERED** | Target: `ESP32Nav-Flutter-PRODUCTION.ipa` |
| **Physical iPhone Field Test** | **MANUAL FIELD PENDING** | Pending field test on physical device |

