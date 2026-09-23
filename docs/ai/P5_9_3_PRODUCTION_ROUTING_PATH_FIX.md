# Phase P5.9.3: Fix Production Valhalla URL & Snap Both Route Endpoints

**Date**: 2026-09-23  
**Target App**: `ESP32Nav-Flutter-PRODUCTION.ipa`  
**Status**: AUTOMATED VERIFICATION PASSED / LIVE SMOKE VALIDATED / MANUAL FIELD PENDING  

---

## 1. Executive Summary & Field Evidence

Physical iPhone field testing following Phase P5.9.2 revealed that despite CI smoke tests reporting HTTP 200 on all endpoints, selecting destinations in Hanoi still failed on real devices with the banner:
```
Không có lộ trình
```
**The Critical Finding**: This failure was neither a server outage nor a UI glitch. It was caused by two concrete production bugs:
1. An un-hosted relative URI `Uri.parse('/route')` in `ValhallaService.calculateRouteDetailed()`.
2. Asymmetric destination-only coordinate snapping that failed whenever user GPS originated off-road (in parking lots, residential courtyards, or alleys).

---

## 2. Root Cause Audit

### 2.1 The `Uri.parse('/route')` Bug
In `mobile_app/lib/services/valhalla_service.dart`:
```dart
// BUGGY CODE in P5.9.2:
static const String _valhallaBaseUrl = 'https://valhalla1.openstreetmap.de';
...
final url = Uri.parse('/route'); // Relative URI lacking scheme and host!
```
When `http.post(url, ...)` executed on a real device, Dart immediately threw:
```
ArgumentError: No host specified in URI /route
```
Because the general catch-all in `ValhallaService` classified unknown exceptions as generic `network`, this crash was swallowed and silently dropped, triggering a failover to OSRM.

### 2.2 Why P5.9.2 Raw Smoke Test Failed to Catch It
The P5.9.2 smoke test script (`tool/provider_smoke_test.dart`) created raw HTTP connections with:
```dart
final uri = Uri.parse('https://valhalla1.openstreetmap.de/route');
```
It tested whether the OpenStreetMap demo server was alive, but **never executed `ValhallaService().calculateRouteDetailed()`**. The test was completely decoupled from production code paths, resulting in a false-green CI run while the production app crashed immediately upon dispatching requests.

### 2.3 Asymmetric Destination-Only Snapping
In real iPhone usage in Vietnam, user GPS frequently places the start point in apartment driveways, courtyards, or alleys 10–50m from mapped carriageways.
- P5.9.2 only snapped `destination`.
- When Valhalla crashed from the URL bug, OSRM received the raw off-road start coordinate.
- OSRM rejected the request with `NoSegment` / `NoRoute` at the start point.
- Because start snapping did not exist, the orchestrator gave up and reported *"Không có lộ trình"*.

---

## 3. Architecture & Implementation Changes

### 3.1 Production Absolute URI & Regression Guard
Refactored `ValhallaService` to compute and expose an absolute URI:
```dart
static const String _valhallaBaseUrl = 'https://valhalla1.openstreetmap.de';

static Uri routeUri() => Uri.parse('$_valhallaBaseUrl/route');
```
Both `calculateRouteDetailed()` and unit tests share this exact helper. Added pre-dispatch validation:
```dart
if (!url.hasScheme || !url.hasAuthority || url.host.isEmpty) {
  return ProviderRouteResult.failure(
    provider: 'valhalla',
    latency: Duration.zero,
    errorType: 'invalidUri',
    safeMessage: 'Cấu hình URL Valhalla không hợp lệ (thiếu host: $url)',
  );
}
```
Added catch-block classification for `invalidUri` if any URI formatting error arises.

### 3.2 Dual-Endpoint Independent Snap Recovery
In `MapboxDirectionsService.calculateRoutesDetailed()`:
When primary & secondary providers fail with `noRoute` or `noSegment`:
1. **Start Coordinate**: Snapped via `/nearest/v1/driving/{lon},{lat}` up to **150 m** threshold (stricter because GPS is near the user's active road).
2. **Destination Coordinate**: Snapped up to **300 m** threshold.
3. **Independent Movement**: Neither is required to move.
   - If start is already on-road ($\le 3\text{ m}$), start remains unchanged.
   - If destination needs 70m adjustment, destination is updated and route retried.
   - If both require snapping, both are updated.
4. **Budget Guard**: Retry only dispatches if remaining time before the 8.0s hard deadline exceeds 2.0s (`hardDeadline - stopwatch.elapsed`).
5. **Distance Violation**: If start $> 150\text{ m}$ or dest $> 300\text{ m}$, reports explicit, descriptive message:
   - *"Vị trí bắt đầu nằm quá xa đường giao thông (cách Xm, tối đa 150m)"*
   - *"Điểm đến nằm quá xa đường giao thông (cách Xm, tối đa 300m)"*

### 3.3 OSRM Diagnostic Preservation
`OsrmService.fetchOsrmRoutesDetailed()` now takes an `onDiagnostic` callback. Both `osrm1` (primary) and `osrm2` (secondary) attempts are preserved and forwarded to `RouteCalculationResult.providerDiagnostics` and the MapScreen Debug HUD.

### 3.4 Telemetry HUD Enhancements
The Field Debug HUD now displays:
- `Start orig`: Latitude, Longitude (rounded to 4 decimals)
- `Snap start`: Distance in meters (if snapped)
- `Snap dest`: Distance in meters (if snapped)
- `VAL`: Host, HTTP status, and latency ms
- `OSRM1` / `OSRM2`: Status and latency ms
- `Winner`: Winning provider and total elapsed ms

---

## 4. Live Production-Service Smoke Test Evidence

The smoke test runner (`tool/provider_smoke_test.dart`) now tests the **actual production classes**:
1. Raw HTTP probes (Valhalla, OSRM primary, OSRM secondary).
2. `ValhallaService().calculateRouteDetailed(...)` production call.
3. `MapboxDirectionsService().calculateRoutesDetailed(...)` full routing pipeline call.
4. Field-like Hanoi route: **Định Công / Đại Kim** (`20.9785, 105.8340`) $\to$ **Tân Tiến, Chương Mỹ** (`20.8950, 105.6550`).

### Execution Output:
```text
===============================================================
P5.9.3 LIVE ROUTING PROVIDER SMOKE TEST (VIETNAM / HANOI)
===============================================================
[SMOKE] Valhalla raw: HTTP 200, 832ms
[SMOKE] OSRM primary raw: HTTP 200, 615ms
[SMOKE] OSRM secondary raw: HTTP 200, 608ms
[PROD-SMOKE] ValhallaService: PASS (HTTP 200, 2373ms, dist=4.1 km)
[Routing] Start calculation: start=(21.0285, 105.8542) dest=(21.0478, 105.8368) mode=bike primary=valhalla
[PROD-SMOKE] RoutingPipeline bike: PASS (valhalla, 1035ms, routes=1)
[Routing] Start calculation: start=(20.9785, 105.8340) dest=(20.8950, 105.6550) mode=bike primary=valhalla
[PROD-SMOKE] Field Route Dinh Cong -> Tan Tien: PASS (valhalla, 996ms, dist=27.3 km)
===============================================================
00:06 +1: All tests passed!
```

CI workflow step `4c. Run Live Routing Provider Smoke Test` now runs `dart run tool/provider_smoke_test.dart` directly without `|| echo warning`. Any real failure in the production routing pipeline will cleanly fail the CI job.

---

## 5. Verification Results

### 5.1 Flutter Static Analysis
```bash
flutter analyze --no-fatal-infos
# Output: No issues found! (ran in 1.1s)
```

### 5.2 Flutter Automated Tests (198 / 198 PASS)
- Baseline in P5.9.1: 188 tests
- Baseline in P5.9.2: 192 tests
- Total in P5.9.3: **198 tests (100% PASS)**
New tests added in `test/fixture_parser_test.dart`:
- `Valhalla routeUri() returns absolute https URI with host and /route path`
- `Valhalla diagnostic catches no-host / relative URI error as invalidUri`
- `Field-like case: Dinh Cong to Tan Tien (Chuong My) Valhalla fixture parsing` (~27.3 km, >100 polyline points, >15 steps)
- `Field-like case: Dinh Cong to Tan Tien (Chuong My) OSRM fixture parsing` (~28.2 km, >100 polyline points, >15 steps)
- `Destination > 300m away from road is flagged unroutable`
- `Start position > 150m away from road is flagged unroutable with start error`
- `Dual snap: Both start (35m) and destination (65m) off-road snap and route recovers`
- `Single snap: Start already on road (2m), only destination (70m) snaps`

### 5.3 ESP32 Firmware Build
```bash
pio run
# Output: [SUCCESS] Took 5.46 seconds (RAM: 41.3%, Flash: 35.9%)
```

---

## 6. Verification Status

| Component | Status | Notes |
| :--- | :--- | :--- |
| **Absolute URI Regression** | **VERIFIED** | `routeUri()` checked by unit test & production code |
| **Dual Endpoint Snapping** | **VERIFIED** | Independent start (150m) & dest (300m) snapping |
| **Logic Unit Tests** | **PASSED (198/198)** | Offline fixture parsing and snap logic |
| **Live Smoke Test** | **PASSED** | Raw probes + ValhallaService + Full Pipeline + Dinh Cong -> Tan Tien |
| **Flutter Analyzer** | **PASSED** | 0 issues found |
| **ESP32 Firmware** | **PASSED** | PlatformIO build successful |
| **CI Workflow** | **ACTIVE** | Target: `ESP32Nav-Flutter-PRODUCTION.ipa` |
| **Physical iPhone Field Test** | **MANUAL FIELD PENDING** | Pending field test on physical device |

