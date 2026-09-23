# Phase P5.9.2: Real Routing Provider Diagnostics & Vietnam Route Recovery

**Date**: 2026-09-23  
**Target App**: `ESP32Nav-Flutter-PRODUCTION.ipa`  
**Status**: AUTOMATED VERIFICATION PASSED / LIVE SMOKE VALIDATED / MANUAL FIELD PENDING  

---

## 1. Executive Summary & Field Evidence

Physical iPhone field testing of the P5.9.1 production IPA installed on a real device revealed that even after fixing the loading state bug, routing continued to fail:
- **Field Symptom**: Selecting destinations repeatedly displayed the banner *"Không có lộ trình"* ("No route").
- **No polyline** appeared on the MapLibre glass view.
- **ETA / distance** remained stuck at `--`.
- **GO** button remained disabled.
- **Root Cause**: This was **not** a loading UX bug. It was a real provider and runtime routing connectivity failure in the field.

---

## 2. Limitation of P5.9.1 Mocked-Provider Tests

In Phase P5.9.1, 188 automated tests passed, but all provider integration tests utilized injected fake providers (`mockOsrmRoutes`, `mockValhallaRoutes`).
- **What Mock Tests Proved**: Racing logic, timeout handling, generation protection, UI loading transitions, synthetic fallback guards.
- **What Mock Tests Failed to Prove**:
  1. Whether `valhalla1.openstreetmap.de` actually returns valid routes in production.
  2. Whether `router.project-osrm.org` or `routing.openstreetmap.de` accept queries and respond without HTTP 429/400.
  3. Whether the production JSON schemas match the parser models.
  4. Whether real coordinates in Hanoi/Vietnam route correctly on public graphs.
  5. How POI search centroids (coordinates off-road) behave on real routing graphs.

**P5.9.2 Architecture Rule**: Distinguish strictly between **LOGIC UNIT TESTS** (offline, deterministic, fixture-based) and **LIVE PROVIDER SMOKE TESTS** (separate, real HTTP, CI telemetry).

---

## 3. Real Provider Failure Audit & Diagnostics

### 3.1 Silent Error Swallowing Eliminated
Previously, both `ValhallaService` and `OsrmService` silenced failures:
```dart
// OLD CODE - Blindly returned null / empty list
if (response.statusCode != 200) return null;
} catch (_) {
  return null;
}
```
This masked HTTP 400 (unsupported locale/parameters), HTTP 429 (rate limits), `NoSegment`/`NoRoute` (unroutable POI centroids), and DNS/socket errors.

### 3.2 Granular Diagnostic Model: `ProviderRouteResult`
Introduced `ProviderRouteResult` to capture deep diagnostics without leaking large HTML bodies to the user:
```dart
class ProviderRouteResult {
  final String provider;
  final bool success;
  final List<NavRoute> routes;
  final int? httpStatus;
  final String? apiCode;
  final String? errorType; // timeout, dns, network, tls, http, noSegment, noRoute, rateLimited, invalidRequest, parseError, emptyResponse
  final String? safeMessage;
  final Duration latency;
  final double? snapDistanceMeters;
  final LatLng? snappedCoordinate;
}
```

---

## 4. Provider Request Audits

### 4.1 Valhalla Request Audit
- **Endpoint**: `https://valhalla1.openstreetmap.de/route`
- **Mandatory Headers**:
  ```http
  Content-Type: application/json
  User-Agent: ESP32Nav/2.0 (contact@esp32nav.app)
  X-Client-Id: esp32-ios-nav
  ```
  *(Identifying client ID required by public demo server guidelines; no fake API keys used).*
- **Routability Parameter**: Added `"search_cutoff": 500` in location objects to expand the graph search radius for road edges up to 500m.
- **Narrative Language Fallback**: If the server rejects `language: "vi-VN"` with HTTP 400 indicating an invalid locale, the request automatically retries **once** without the custom language parameter.

### 4.2 OSRM Request Audit
- **Primary Endpoint**: `https://router.project-osrm.org`
- **Secondary Endpoint**: `https://routing.openstreetmap.de/routed-car`
- **Compatibility Fix**: Replaced `alternatives=3` with `alternatives=true`. Public demo instances often reject numeric alternatives with 400.
- **Query Format**: `/route/v1/driving/{lon},{lat};{lon},{lat}?overview=full&geometries=geojson&steps=true&alternatives=true`
- **Error Capture**: Parses JSON response `code` and `message` on non-200 or `NoRoute` responses into `ProviderRouteResult`.

---

## 5. Parallel Provider Racing & Fallback Strategy

Sequential fallback (4s primary + 4s secondary = 8s) was replaced with **hedged racing**:
```
T0:        Dispatches OSRM Primary (3.5s timeout)
T0 + 800ms: If Primary has not returned, dispatches OSRM Secondary (3.5s timeout)
           OR immediately dispatches Secondary if Primary returns HTTP error / network exception
First valid route wins!
```
Total routing budget remains bounded under the global 8s deadline while avoiding serial latency.

---

## 6. Routable Point / Snap Recovery

In Vietnam, geocoding/POI searches frequently return coordinates situated inside buildings, parks, or off-road locations. When routers receive these, they return `NoSegment` or `noRoute`.

### 6.1 OSRM Nearest Endpoint Snap
When routing fails with `noRoute` or `noSegment`:
1. The app invokes `/nearest/v1/driving/{lon},{lat}?number=1`.
2. Extracts the nearest routable street coordinate and calculates the snap distance in meters.
3. **Threshold Guard**:
   - If distance $\le 300\text{ m}$: Route is recalculated using the snapped coordinate.
   - If distance $> 300\text{ m}$: Route request is aborted with clear user notification: *"Điểm đến nằm quá xa đường có thể dẫn (cách đường >300m)."*

---

## 7. Mapbox Fallback Audit

- **Audit Target**: `MapboxConfig.accessToken`
- **Audit Result**: `MapboxConfig.accessToken = ''` (**NOT CONFIGURED**).
- **Declaration**: Mapbox is **not configured** and is not used as a fallback in production. All routing relies on Valhalla (motorcycle primary) and OSRM (hedged secondary) with OpenStreetMap data.

---

## 8. Live Provider Smoke Test Evidence

A standalone test script `mobile_app/tool/provider_smoke_test.dart` was executed with fixed public Hanoi coordinates:
- **Origin**: Hoàn Kiếm Lake (`21.0285, 105.8542`)
- **Destination**: West Lake / Quảng Khánh (`21.0478, 105.8368`)

### Live Results:
```text
===============================================================
P5.9.2 LIVE ROUTING PROVIDER SMOKE TEST (VIETNAM / HANOI)
Fixed Public Coordinates: Hoan Kiem (21.0285, 105.8542) -> West Lake (21.0478, 105.8368)
===============================================================
[SMOKE] Valhalla: HTTP 200, route OK (4.107km), 846ms
[SMOKE] OSRM primary: HTTP 200, code=Ok, routes=2 (3.8km), 614ms
[SMOKE] OSRM secondary: HTTP 200, code=Ok, routes=2 (3.8km), 595ms
[SMOKE] OSRM nearest snap: HTTP 200, snapped dist=25.1m (Ngõ 59 Phố Quảng Khánh), 197ms
===============================================================
SMOKE SUMMARY: 4 / 4 endpoints responsive and validated
===============================================================
```

All 4 endpoints are live, responsive, and properly return routes for Hanoi, Vietnam.

---

## 9. Real Fixture Parsing Tests

Sanitized response payloads from live requests were saved as test fixtures:
- `test/fixtures/osrm_hanoi_route_fixture.json` (117 KB)
- `test/fixtures/valhalla_hanoi_route_fixture.json` (9 KB)

Unit tests in `test/fixture_parser_test.dart` verify:
1. Real OSRM Hanoi fixture parses: distance > 0, duration > 0, polyline points > 2, non-empty maneuvers, valid bounding coordinates.
2. Real Valhalla Hanoi fixture parses: motorcycle costing, valid steps, geometry shape, distance > 0.
3. Snap recovery pipeline correctly intercepts `noRoute` / `noSegment`, finds nearest routable road, and recovers a valid route.
4. Distances exceeding 300m are safely rejected with descriptive diagnostics.

---

## 10. App Debug HUD & User-Facing Error Messages

### 10.1 Field Debug HUD
In debug mode, the top overlay displays real-time provider diagnostics:
```text
VAL: HTTP 200 / noRoute / 846ms
OSRM1: Ok / 614ms
OSRM2: Ok / 595ms
Snap dest: 25.1m
Winner: valhalla
```
If routing fails in the field, a single screenshot immediately reveals the exact provider status code and failure point.

### 10.2 User-Facing Messages
Replaced generic *"Không có lộ trình"* with contextual guidance:
- Network error: *"Không kết nối được dịch vụ định tuyến. Vui lòng kiểm tra mạng."*
- Rate limit: *"Dịch vụ định tuyến đang quá tải (429). Hãy thử lại sau giây lát."*
- Unroutable point: *"Điểm đến nằm quá xa đường có thể dẫn (cách đường >300m)."*
- General no route: *"Không tìm thấy đường đi khả dụng cho xe máy giữa hai điểm này."*

---

## 11. Verification Results

### 11.1 Flutter Analyzer
```bash
flutter analyze --no-fatal-infos
# Output: No issues found! (ran in 1.4s)
```

### 11.2 Flutter Automated Tests
```bash
flutter test
# Output: 00:07 +192: All tests passed!
```
- Baseline: 188 tests
- P5.9.2: **192 tests** (4 new fixture & snap recovery tests added, 0 failures).

### 11.3 ESP32 Firmware Build
```bash
pio run
# Output: [SUCCESS] Took 3.90 seconds (esp32-s3)
```

### 11.4 CI Workflow Integration
Added Step `4c. Run Live Routing Provider Smoke Test` to `.github/workflows/build_ios.yml` to emit safe provider health logs during automated IPA generation.

---

## 12. Verification Status

| Component | Status | Notes |
| :--- | :--- | :--- |
| **Logic Unit Tests** | **PASSED (192/192)** | Offline fixture parsing and snap logic |
| **Live Smoke Test** | **PASSED (4/4)** | Live Valhalla, OSRM primary/secondary, OSRM nearest |
| **Flutter Analyzer** | **PASSED** | 0 issues found |
| **ESP32 Firmware** | **PASSED** | PlatformIO build successful |
| **Production IPA Build** | **IN CI** | Target: `ESP32Nav-Flutter-PRODUCTION.ipa` |
| **Physical iPhone Field Test** | **MANUAL FIELD PENDING** | Pending field test on physical device |

