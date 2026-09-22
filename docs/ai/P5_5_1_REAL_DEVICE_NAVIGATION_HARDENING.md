# P5.5.1 — REAL DEVICE NAVIGATION HARDENING & REROUTE LIFECYCLE REPORT

## 1. Overview & Clarification
- **Production Path**: The user installs and runs **ONLY the Flutter IPA** (~12 MB). `mobile_app/lib/`, `mobile_app/ios/`, and `firmware_esp32/` form the authoritative **PRODUCTION PATH**. Code under `mobile_app/ios_native/` is an algorithmic reference only.
- **Scope & Phase Objective**: Following the P5.5 navigation engine overhaul, P5.5.1 hardens the real-device field behavior of the production Flutter application. It eliminates asynchronous race conditions in map rendering, prevents false forward progress locking on loops and overpasses, implements deterministic exponential backoff for reroute failures, and enforces immediate visual map refresh upon Route B atomic replacement.
- **ESP32 Streaming Invariant**: All ESP32 streaming behaviors restored in P5.4.1.4 remain untouched (pure JPEG/raster map stream over Wi-Fi/BLE, no custom vector map or fake road renderer on ESP).

---

## 2. Root-Cause Analysis & Concurrency Audit

### A. Route Rendering Concurrency Race
- **Identified Failure**: In `MapScreen._updateRouteOnMap()`, route clearing and line rendering were performed via asynchronous Platform Channel invocations (`await ctrl.clearLines(); await ctrl.addLine(...);`). When rapid GPS updates occurred (~1–2 Hz), multiple asynchronous rendering routines ran concurrently without synchronization.
- **Consequence**: An earlier render update (e.g., Update N) delayed by MapLibre channel latency could resume after a subsequent render update (Update N+1) had already cleared and drawn its lines. This caused stale or previously passed polyline geometry to be redrawn behind the vehicle, creating visual flicker, duplicate line layers, or resurrecting passed route segments.

### B. Cache False-Positive on Reroute Replacement
- **Identified Failure**: The map rendering cache evaluated `points.length != _lastRenderedPointsCount` or distance between starting coordinates $\ge 2.5\text{m}$.
- **Consequence**: When Valhalla calculated a new Route B whose point count matched Route A (e.g., 120 vertices) and whose start coordinate was within 2.5m of the current vehicle position, `_updateRouteOnMap()` concluded that no update was necessary and silently dropped Route B. Furthermore, `MapScreen` lacked a listener for route replacement events, leaving Route B unrendered until a future GPS tick.

### C. Unbounded Forward Search in Matcher
- **Identified Failure**: In `RouteGeometry.matchLocation()`, the fallback to `globalNearest` accepted any segment where `globalNearest.lateralDistanceMeters < bestLocalProj.lateralDistanceMeters * 0.5` provided `globalDeltaAlong > -30.0`, with no upper bound on forward distance.
- **Consequence**: On routes with loops, overpasses, or nearby future segments (common in Hanoi's road network), a segment kilometers ahead could be selected over the current local road. In `NavigationManager`, `_displayProgressMeters = max(_displayProgressMeters, matched.distanceAlongRouteMeters)` permanently locked route progress at the distant segment, immediately trimming all upcoming turns and destroying navigation guidance.

### D. Reroute Request Spamming on Network Failure
- **Identified Failure**: On Valhalla request failure or timeout, `_isRerouting` was reset to `false`, but the detector remained in `OffRouteState.confirmed`.
- **Consequence**: Because `decision.state == OffRouteState.confirmed && !_isRerouting` evaluated to `true` on the very next GPS update (<1.0s), repeated failed requests spammed the public Valhalla API every second without cooldown or backoff.

---

## 3. Architecture & Implementations

### A. Deterministic RouteRenderController (`mobile_app/lib/services/route_render_controller.dart`)
- **Single-Flight & Coalescing Queue**: Implements an atomic execution loop `_drainQueue()` that ensures at most one rendering operation runs at any time. Intermediate GPS updates while a render is in flight are coalesced into a single latest pending request (`_pendingRequest`).
- **Generation Guard**: Tracks monotonically increasing `_latestSubmittedGeneration` and `_latestCommittedGeneration`. If an update is superseded while clearing lines or drawing, stale execution is immediately aborted to pick up the latest state.
- **Route Revision Awareness**: Compares `routeRevision` from `NavigationManager`. Any change in route identity forces an immediate redraw, completely bypassing vertex count and distance thresholds.

### B. Progress Acceptance Gating (`mobile_app/lib/services/route_geometry.dart` & `navigation_manager.dart`)
- **Candidate Forward Search Bound**: In `RouteGeometry.matchLocation()`, restricted `globalNearest` fallback to `globalDeltaAlong <= searchForwardMeters` (150m) unless explicit `stuckRecovery: true` is set.
- **Plausible Forward Jump Gating**: In `NavigationManager.updateUserPositionWithAccuracy()`, calculates:
  $$\text{maxPlausibleForwardJump} = \max\left(60.0, (v_{\text{mps}} \times 1.5 + 35.0) \times \max(1.0, \Delta t)\right)$$
  Anomalous forward leaps exceeding this threshold are rejected from advancing `_displayProgressMeters`, preventing false forward progress locks while permitting legitimate gaps after app backgrounding.
- **Strict Monotonicity**: Passed vertices are trimmed strictly based on `_displayProgressMeters`, ensuring the blue line behind the vehicle never grows backward on GPS noise.

### C. Reroute Lifecycle & Exponential Backoff
- **State Progression**:
  $$\text{IDLE} \longrightarrow \text{REQUESTING} \longrightarrow \text{APPLIED} \longrightarrow \text{IDLE}$$
  $$\text{REQUESTING} \longrightarrow \text{FAILED} \longrightarrow \text{COOLDOWN} \longrightarrow \text{REQUESTING}$$
- **Exponential Backoff Curve**:
  $$\text{Cooldown} = \min\left(30.0, 3.0 \times 2^{\text{retryCount} - 1}\right)\text{ seconds}$$
  - Attempt 1 failure: 3.0s cooldown
  - Attempt 2 failure: 6.0s cooldown
  - Attempt 3 failure: 12.0s cooldown (capped at 30.0s)
- **Automatic Recovery**: Returning to `onRoute` (lateral distance $\le 10\text{m}$ for 1.0s dwell) immediately resets retry count to 0 and clears failure cooldown.
- **Atomic Route B Commit**: Updates active route, geometry, resets detector, bumps `_routeRevision`, and notifies listeners. `MapScreen` detects the revision change and immediately renders Route B.

### D. Enhanced Road-Testing Field Diagnostics
- `MapScreen` debug overlay displays live telemetry for on-road verification:
  - GPS horizontal accuracy ($m$)
  - Raw physical GPS coordinates (lat, lng)
  - Matched route coordinates (lat, lng)
  - Physical route lateral distance ($m$)
  - Matched lateral distance ($m$)
  - Display progress along route ($m$)
  - Remaining route distance ($m$ or $km$)
  - Off-route state (`onRoute`, `suspected`, `confirmed`) & reason
  - Reroute status (`idle`, `requesting`, `applied`, `failed`, `cooldown`)
  - Reroute generation & route revision
  - Last reroute latency ($ms$)

---

## 4. Verification Evidence

### A. Static Code Analysis
```text
$ flutter analyze
Analyzing mobile_app...
No issues found! (ran in 1.3s)
```

### B. Unit & Integration Tests
Total tests: **115 / 115 PASS**
```text
$ flutter test
00:07 +115: All tests passed!
```
New and updated test suites:
1. `mobile_app/test/route_render_controller_test.dart` (5 tests):
   - Sequential renders execute cleanly and commit generation in order.
   - Stale render race: Gen 1 in `clearLines`, Gen 2 requested -> Gen 1 draw aborted, Gen 2 commits.
   - Coalescing intermediate states: Updates 1, 2, 3 in rapid succession -> only latest update 3 runs.
   - Route revision change forces redraw even if point count and start coordinate match.
   - Mode transition to `arrived` or `none` clears lines and records empty geometry.
2. `mobile_app/test/route_geometry_test.dart` (8 tests):
   - `matchLocation` bounds candidate forward window, ignoring distant loops/overpasses.
3. `mobile_app/test/navigation_progress_test.dart` (5 tests):
   - Continuous line trimming across multiple points (0m -> 20m -> 40m -> 60m -> 80m).
   - GPS noise resilience (progress at 80m, noisy sample at 55m does not move progress backwards).
   - GPS accuracy gating (>20m rejected).
   - Section 8 GPS jitter sequence (30 -> 28 -> 32 -> 29 -> 40 -> strictly monotonic display progress).
   - Section 4 impossible forward jump rejection (300m jump in 1s rejected).
4. `mobile_app/test/navigation_reroute_test.dart` (11 tests):
   - Exact field regression from user screenshot (bends away, separation <45m).
   - Parallel road test (12m apart, speed 8m/s, acc 4m -> confirmed, 1 reroute).
   - Poor GPS parallel test (12m apart, accuracy 15m -> no instant reroute).
   - Cross-street 90° wrong turn test (~1.0–1.5s reroute).
   - Sharp planned 90° turn test (no false reroute).
   - Reroute atomicity test (pending route keeps trimming, Route B commits atomically).
   - Production motorcycle reroute uses Valhalla, not Mapbox.
   - Generation guard (late reroute response does not overwrite stopped navigation).
   - Reroute network failure triggers backoff cooldown and prevents spamming.
   - Reroute commit with identical point count & close start bumps `routeRevision`.
   - Recovery to `onRoute` resets reroute failure backoff.

### C. ESP32 Firmware Verification
```text
$ pio run
Building in release mode
RAM:   [====      ]  41.3% (used 135416 bytes from 327680 bytes)
Flash: [====      ]  35.9% (used 1200069 bytes from 3342336 bytes)
========================= [SUCCESS] Took 4.23 seconds =========================
```

### D. GitHub Actions CI Evidence
- **Repository**: `ysiduc/esp32-ios-nav`
- **Code Commit SHA**: `9d6e3f3222617552ddd019cf8ba5856a678208fc`
- **Workflow Run ID**: `35714477785`
- **Production Artifact**: `ESP32Nav-Flutter-PRODUCTION-ipa` (~12 MB)
- **Reference Artifact**: `ESP32Nav-Native-REFERENCE-ipa` (~6 MB)

---

## 5. Verification Status & Real-Device Test Matrix

| Verification Item | Status | Details |
| :--- | :--- | :--- |
| **Route Rendering Concurrency** | **AUTOMATED VERIFIED** | Tested via `route_render_controller_test.dart` (stale abort, queue coalescing, generation token). |
| **Monotonic Trimming & Jitter** | **AUTOMATED VERIFIED** | Tested via `navigation_progress_test.dart` (jitter sequence 30-28-32-29-40, line trimming). |
| **Impossible Forward Jump Gating** | **AUTOMATED VERIFIED** | Tested via `route_geometry_test.dart` & `navigation_progress_test.dart` (300m/1s jump rejected). |
| **Reroute Cooldown & Backoff** | **AUTOMATED VERIFIED** | Tested via `navigation_reroute_test.dart` (exponential backoff 3s->6s, no API spamming). |
| **Route B Map Refresh on Commit** | **AUTOMATED VERIFIED** | Tested via `route_render_controller_test.dart` & `navigation_reroute_test.dart` (routeRevision bump). |
| **Production Flutter Analyzer** | **AUTOMATED VERIFIED** | 0 errors, 0 warnings across all production code. |
| **ESP32 Firmware Compatibility** | **AUTOMATED VERIFIED** | PlatformIO release build clean (35.9% flash, 41.3% RAM). |
| **TEST A: On-Road Route Trimming** | **MANUAL PENDING** | Drive straight 20m, 50m, 100m -> blue line disappears continuously behind vehicle without reroute. |
| **TEST B: Wrong Turn Reroute** | **MANUAL PENDING** | Turn off planned road -> verify timeline (suspected -> confirmed -> requesting -> route B applied ~1.0–1.5s). |
| **TEST C: Parallel Road Detection** | **MANUAL PENDING** | Drive on road 10–20m parallel to route -> verify prompt off-route confirmation without waiting for >45m. |
| **TEST D: Return Before Confirm** | **MANUAL PENDING** | Veer off slightly, then steer back onto route -> verify clean recovery to `onRoute` without rerouting. |
| **TEST E: Network Failure Cooldown** | **MANUAL PENDING** | Turn off cellular data off-route -> verify Route A remains active, no crash, backoff active in telemetry. |
| **TEST F: Immediate Route B Render** | **MANUAL PENDING** | Verify Route B appears on map immediately when reroute succeeds, without waiting for next GPS sample. |
