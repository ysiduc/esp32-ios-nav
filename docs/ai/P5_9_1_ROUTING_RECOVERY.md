# Phase P5.9.1: Fix Route Calculation Stall & Unify Motorcycle Routing

**Date**: 2026-09-23  
**Target App**: `ESP32Nav-Flutter-PRODUCTION.ipa`  
**Status**: AUTOMATED VERIFICATION PASSED / MANUAL FIELD PENDING  

---

## 1. Executive Summary & Field Evidence

Physical iPhone field testing on P5.9 revealed a critical routing production blocker:
- **Field Symptom**: User selected a destination successfully from search; the Apple Maps-styled "Chỉ đường" (Directions) bottom sheet opened properly with origin "Vị trí của tôi" and destination place displayed; motorcycle mode was selected.
- **The Failure**:
  - ETA and distance remained indefinitely stuck at `--`.
  - No route polyline rendered on the native MapLibre map canvas.
  - The green "ĐI" button was rendered active, but tapping it did nothing because `_routes` was empty.
  - The user could not start real navigation.

---

## 2. Root Cause Audit

### 2.1 Sequential Multi-Tier Fallback Latency (~26 Seconds Worst Case)
Previously, `_calculateRoutesForPlace()` called `MapboxDirectionsService.calculateMultipleRoutes()`, which sequentially dispatched requests:
```
Start Request
 ├── 1. Primary OSRM (8s timeout)
 └── 2. Secondary OSRM (8s timeout)
      └── 3. Valhalla (10s timeout)
           └── 4. Emergency Fallback
```
Worst-case sequential wait was **~26 seconds**. Under cellular network latency or public API delays, users experienced an apparent infinite stall.

### 2.2 Missing Try/Catch/Finally & Generation Safety in MapScreen
In `MapScreen._calculateRoutesForPlace()`:
- There was no `try / catch / finally` block wrapping `_directionsService.calculateMultipleRoutes()`.
- Any unhandled exception or network cancellation left `_isLoadingRoutes == true` indefinitely.
- No generation counter (`_routeRequestGeneration`) existed. Rapidly tapping destination A then B caused race conditions where A could overwrite B.

### 2.3 Semantic Inconsistency Between Preview and Navigation
- Preview routing queried OSRM car profile first.
- Active navigation and rerouting in `NavigationManager` used Valhalla `costing: 'motorcycle'`.
- Result: Route geometry and maneuvers in preview were calculated with car rules (e.g. avoiding one-way motorcycle paths or highway restrictions) while live turn-by-turn navigation ran motorcycle routing.

---

## 3. Architectural Solutions & Implementation

### 3.1 Motorcycle Unification & Provider Hierarchy
Routing semantics between preview and live navigation are unified:

| Transport Mode | Primary Provider (T0) | Secondary Fallback (T0 + 1.5s) |
|---|---|---|
| **Bike / Motorcycle** (`mode == 'bike'`) | **Valhalla `costing = 'motorcycle'`** | **OSRM driving** (with Vietnam motorbike speed model) |
| **Driving** (`mode == 'driving'`) | **OSRM driving** | **Valhalla `costing = 'auto'`** |
| **Foot** (`mode == 'foot'`) | **Valhalla `costing = 'pedestrian'`** | **OSRM foot** |

### 3.2 Hedged Racing & Strict 8-Second Hard Deadline
To eliminate the 26s latency stall without spamming public servers:
1. **T0**: Launch Primary Provider (Valhalla motorcycle for bike).
2. **T0 + 1.5s**: If Primary has not yet completed, launch Secondary Fallback in parallel.
3. **Fast Winner Selection**: Whichever returns first with a valid route wins and cancels remaining timers.
4. **Fast Failover**: If Primary fails fast (e.g. within 200ms), Secondary Fallback is triggered immediately without waiting for the 1.5s timer.
5. **Hard Deadline (8.0s)**: If neither provider returns a valid route within 8 seconds, request immediately terminates with `RouteFailureReason.timeout` and renders the error/retry UI.

### 3.3 Synthetic Route Strict Safety
Emergency offline straight-line routes (`MapboxDirectionsService.generateEmergencyRoute`) are strictly tagged:
- `isFallbackSynthetic: true`
- `provider: 'synthetic'`

**Navigation Guards**:
- `NavigationManager.startNavigation(route)`: Rejects with log if `route.isFallbackSynthetic == true`.
- `NavigationManager.startSimulation(route)`: Rejects with log if `route.isFallbackSynthetic == true`.
- `MapScreen._startDriving()`: Blocks invocation and displays warning SnackBar.
- Bottom Directions Card: Disables the "ĐI" button and simulation button when a synthetic route is previewed.

### 3.4 Request Generation Tokens (`_routeRequestGeneration`)
Every route request increments `_routeRequestGeneration`:
```dart
final int currentGen = ++_routeRequestGeneration;
```
If a prior request completes after a newer request has started, the response is discarded immediately.

### 3.5 Atomic UI State Machine & Loading/Retry Card
- **Loading State**: Displays a Cupertino-style activity spinner and `Đang tìm lộ trình tối ưu...` status. Green "ĐI" and simulation buttons are disabled (greyed out).
- **Error State**: Displays `Không thể tính lộ trình` banner with the specific failure reason and a prominent **"Thử lại"** (Retry) button.
- **Success State**: ETA, duration, distance, route polyline, and green "ĐI" button are committed atomically.

### 3.6 Routing Telemetry in Debug HUD
Debug HUD now reports real-time routing metrics:
- `Route provider: valhalla / osrm / mapbox / synthetic`
- `Route status: requesting / success / timeout / failed`
- `Route latency: xxxx ms`
- `Request generation: #N`
- `Routes returned: N`

---

## 4. Verification & Test Evidence

### 4.1 Automated Test Suite Expansion (188 Tests)
Baseline test count was **181 tests**.  
The new deterministic test file `mobile_app/test/route_concurrency_test.dart` added **7 tests**:
1. **Test A (Valhalla fast success)**: Valhalla motorcycle route committed under 500ms, `provider == RouteProvider.valhalla`, GO enabled.
2. **Test B (Valhalla slow, OSRM fallback success)**: Valhalla pending, OSRM returns in 80ms -> OSRM route committed without waiting for 8s/10s timeout.
3. **Test C (All providers timeout)**: Hard deadline reached -> returns `RouteFailureReason.timeout`, routes empty, error displayed.
4. **Test D (Stale request race)**: Fast newer request supersedes slower older request; older response discarded.
5. **Test E (Bike mode primary)**: Verified `costing = 'motorcycle'` dispatched to Valhalla.
6. **Test F (Synthetic fallback safety)**: Synthetic emergency route cannot call `startNavigation()` or `startSimulation()`.
7. **Test G (Coordinates validation)**: Null island (0,0) and invalid coordinates rejected.

All **188 tests** passed cleanly:
```
00:07 +188: All tests passed!
```

### 4.2 Flutter Static Analysis
```
flutter analyze
Analyzing mobile_app...
No issues found! (ran in 1.2s)
```

### 4.3 ESP32 Firmware Build
```
pio run in firmware_esp32:
RAM:   [====      ]  41.3% (used 135416 bytes from 327680 bytes)
Flash: [====      ]  35.9% (used 1200069 bytes from 3342336 bytes)
[SUCCESS] Took 4.97 seconds
```

---

## 5. Physical Field Verification Checklist

- [ ] `MANUAL FIELD PENDING`: Tap destination -> "Đang tìm lộ trình tối ưu..." spinner displays cleanly without stuck `--`.
- [ ] `MANUAL FIELD PENDING`: Motorcycle route returns via Valhalla motorcycle in < 2s with route polyline, duration, and distance populated atomically.
- [ ] `MANUAL FIELD PENDING`: Green "ĐI" button becomes active and tapping starts turn-by-turn navigation immediately.
- [ ] `MANUAL FIELD PENDING`: Rapidly tapping different search results commits only the latest destination without flickering or stale overwrite.
- [ ] `MANUAL FIELD PENDING`: Network disconnect triggers error message and "Thử lại" button within 8 seconds.
- [ ] `MANUAL FIELD PENDING`: Debug HUD displays Route Provider, Status, Latency ms, Generation, and Routes Count.
