# P5.5.2 — FIELD VALIDATION READINESS REPORT

## 1. Overview & Clarification
- **Production Path**: The user installs and runs **ONLY the Flutter IPA** (~12 MB): `ESP32Nav-Flutter-PRODUCTION.ipa`. The production codebase is strictly `mobile_app/lib/`, `mobile_app/ios/`, and `firmware_esp32/`. Code under `mobile_app/ios_native/` is an algorithmic reference only.
- **Phase Purpose**: Corrects the semantic flaw in reroute failure cooldown timestamping, guarantees deterministic single-flight behavior during high-latency network requests, audits and tests `RouteRenderController` supersede-during-draw and reset boundaries, and prepares the application for physical road testing.
- **ESP32 Invariant**: Streaming architecture remains strictly unchanged from P5.4.1.4 (smooth JPEG/raster map stream over Wi-Fi/BLE, no vector map on ESP).

---

## 2. Root Cause: Reroute Failure Cooldown Timestamp Semantics

### The Problem in P5.5.1
In P5.5.1, when Valhalla routing returned `null` or threw an exception, the failure timestamp was assigned as:
```dart
// P5.5.1 (Defective):
_lastRerouteFailureAt = requestTime;
```
`requestTime` represents the instant the **network request started** ($T_0$).
If the Valhalla API takes 7 seconds to time out or return an error (at $T_0 + 7\text{s}$), and the configured backoff cooldown is 3.0 seconds:
$$\Delta t = (T_0 + 7\text{s}) - T_0 = 7.0\text{s} \ge 3.0\text{s}$$
As a result, upon failure completion at $T_0 + 7\text{s}$, the app concluded that the 3-second cooldown had already elapsed, immediately permitting another request on the subsequent GPS tick. This effectively destroyed the exponential backoff protection under slow network conditions.

### The Fix in P5.5.2
Cooldown and backoff must strictly anchor to the **actual completion timestamp** of the failure ($T_{\text{fail}}$):
```dart
// P5.5.2 (Corrected):
_routingService.calculateSingleRoute(...).then((newRoute) {
  final completionTime = nowProvider();
  ...
  if (newRoute != null && newRoute.polylinePoints.length >= 2) {
    ...
  } else {
    _isRerouting = false;
    _rerouteStatus = 'failed';
    _rerouteRetryCount++;
    _lastRerouteFailureAt = completionTime;
    rerouteFailedAt = completionTime;
    notifyListeners();
  }
}).catchError((_) {
  if (generation == _rerouteGeneration) {
    final errorTime = nowProvider();
    _isRerouting = false;
    _rerouteStatus = 'failed';
    _rerouteRetryCount++;
    _lastRerouteFailureAt = errorTime;
    rerouteFailedAt = errorTime;
    notifyListeners();
  }
});
```
- Added injectable `nowProvider` (`DateTime Function() nowProvider = DateTime.now;`) in `NavigationManager`.
- If request begins at $T_0$ and fails at $T_0 + 7\text{s}$, cooldown begins at $T_0 + 7\text{s}$.
- The first retry is prohibited at $T_0 + 8.0\text{s}$ and $T_0 + 9.9\text{s}$, and is only permitted at $\ge T_0 + 10.0\text{s}$.

---

## 3. Concurrency & Reset Audit in RouteRenderController

### A. Supersede During Line Drawing
- Verified and tested the boundary condition where `clearLines()` has completed and `drawActiveRoute()` is in progress when a newer generation (Gen 2) arrives.
- When Gen 1 completes its drawing call, `req.generation < _latestSubmittedGeneration` triggers an immediate loop continuation without committing state.
- Gen 2 clears and draws its geometry, ensuring that the latest GPS state always wins as the authoritative committed visual state.

### B. Invalidation on Reset / Stop Navigation
- In `RouteRenderController.reset()`, `_latestSubmittedGeneration++` was added to invalidate and abort any asynchronous render job currently awaiting platform channels.
- When navigation stops, mode `none` is submitted with empty points and force redraw. If an older render job finishes late, its generation check fails and the map remains completely clear without resurrecting old route lines.

---

## 4. Field Telemetry Overlay (P5.5.2)

The live road-testing HUD overlay in `MapScreen` now displays real-time cooldown remaining and retry statistics:
- When in cooldown:
  ```text
  Reroute: cooldown (1.8s, retry 1) [in orange]
  ```
- When idle / active:
  ```text
  Reroute: idle / requesting / applied (gen N, rev M)
  Retries: K (if K > 0)
  Latency: ...ms
  ```

---

## 5. Automated Verification Evidence

### A. Static Code Analysis
```text
$ flutter analyze
Analyzing mobile_app...
No issues found! (ran in 1.1s)
```

### B. Complete Test Suite
Total tests: **120 / 120 PASS**
```text
$ flutter test
00:07 +120: All tests passed!
```
New P5.5.2 unit & integration tests added:
1. `mobile_app/test/navigation_reroute_test.dart`:
   - `P5.5.2 Section 4 & 5: Slow network failure anchors backoff cooldown to actual completion time`: Simulates a 7.0-second Valhalla request; verifies single-flight constraint during delay (callCount = 1 across multiple GPS updates), verifies `rerouteFailedAt == T0 + 7s`, verifies cooldown active at $T_0 + 8\text{s}$ and $T_0 + 9.9\text{s}$, and verifies retry 2 dispatched at $T_0 + 10.1\text{s}$.
   - `P5.5.2 Section 4: Slow network Exception/Timeout anchors backoff cooldown to actual completion time`: Simulates Valhalla throwing `TimeoutException` after 7.0 seconds; verifies identical backoff anchor at actual completion time.
2. `mobile_app/test/route_render_controller_test.dart`:
   - `P5.5.2 Section 6: Stale render race: Gen 1 in drawActiveRoute, Gen 2 requested -> Gen 1 commit aborted, Gen 2 commits`: Verifies stale rejection during active line drawing.
   - `P5.5.2 Section 7: Reset invalidates in-flight render and prevents stale geometry commit`: Verifies `reset()` bumps generation and blocks late commits.
   - `P5.5.2 Section 7: Stop navigation mode none supersedes pending render leaving map empty`: Verifies stop navigation reliably leaves the map empty.

### C. ESP32 Firmware Build
```text
$ pio run
Building in release mode
RAM:   [====      ]  41.3% (used 135416 bytes from 327680 bytes)
Flash: [====      ]  35.9% (used 1200069 bytes from 3342336 bytes)
========================= [SUCCESS] Took 5.88 seconds =========================
```

### D. GitHub Actions CI Evidence
- **Repository**: `ysiduc/esp32-ios-nav`
- **Code Commit SHA**: `2e924d45193ec03b0c04b71811183dbc08716a6a`
- **Workflow Run ID**: `35716648360`
- **Production Artifact**: `ESP32Nav-Flutter-PRODUCTION-ipa` (~12 MB)
- **Reference Artifact**: `ESP32Nav-Native-REFERENCE-ipa` (~6 MB)

---

## 6. Verification Status & Real-Device Test Matrix

| Verification Item | Status | Verification Details |
| :--- | :--- | :--- |
| **Actual Failure Time Anchor** | **AUTOMATED VERIFIED** | Tested via `navigation_reroute_test.dart` (7s delay, retry earliest at T0+10s). |
| **Single-Flight During Slow Request** | **AUTOMATED VERIFIED** | Tested via `navigation_reroute_test.dart` (callCount stays 1 during 7s request). |
| **Slow Exception / Timeout Backoff** | **AUTOMATED VERIFIED** | Tested via `navigation_reroute_test.dart` (`TimeoutException` backoff anchor). |
| **Supersede During Draw** | **AUTOMATED VERIFIED** | Tested via `route_render_controller_test.dart` (Gen 1 aborted after draw, Gen 2 commits). |
| **Reset / Stop Invalidation** | **AUTOMATED VERIFIED** | Tested via `route_render_controller_test.dart` (map guaranteed empty after stop). |
| **Flutter Analyzer & Tests** | **AUTOMATED VERIFIED** | 0 analyze errors, 120 / 120 tests passed. |
| **ESP32 Firmware Compatibility** | **AUTOMATED VERIFIED** | PlatformIO release build clean (35.9% flash, 41.3% RAM). |
| **TEST A: On-Road Route Trimming** | **MANUAL PENDING** | Drive straight 20m, 50m, 100m -> route behind vehicle disappears continuously without reroute. |
| **TEST B: Wrong Turn Reroute** | **MANUAL PENDING** | Turn off planned road -> verify timeline (suspected -> confirmed -> requesting -> route B applied ~1.0–1.5s). |
| **TEST C: Parallel Road Detection** | **MANUAL PENDING** | Drive on road 10–20m parallel to route -> verify off-route confirmation without waiting for >45m. |
| **TEST D: Return Before Confirm** | **MANUAL PENDING** | Veer off slightly, then steer back onto route -> verify recovery to `onRoute` without rerouting. |
| **TEST E: Network Failure Cooldown** | **MANUAL PENDING** | Turn off cellular data off-route -> verify Route A remains active, telemetry displays `cooldown (Xs, retry N)`. |
| **TEST F: Immediate Route B Render** | **MANUAL PENDING** | Verify Route B appears on map immediately when reroute succeeds, without waiting for next GPS sample. |
