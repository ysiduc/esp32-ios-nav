# P5.6.1 — REAL-DRIVE GAP CLOSURE REPORT

## 1. Overview & Clarification
- **Production Path**: The user installs and runs **ONLY the Flutter IPA** (~12 MB): `ESP32Nav-Flutter-PRODUCTION.ipa`. The production codebase is strictly `mobile_app/lib/`, `mobile_app/ios/`, and `firmware_esp32/`. Code under `mobile_app/ios_native/` is an algorithmic reference only.
- **Phase Purpose**: Directly closes remaining real-drive gaps identified following P5.6 field evidence:
  1. Wrong-way detection on the exact route centerline ($<3\text{m}$ lateral distance).
  2. Secondary route connection from the vehicle's physical position to the old route via Valhalla rejoin path.
  3. Elimination of the `RouteRenderController` mid-channel clear/abort livelock starvation loop via atomic render transactions.
  4. Telemetry expansion and cancellation guards.
- **ESP32 Invariant**: Streaming architecture remains strictly unchanged from P5.4.1.4 (smooth JPEG/raster map stream over Wi-Fi/BLE, no vector map on ESP).
- **Routing Engine Invariant**: Routing provider remains Valhalla motorcycle routing.

---

## 2. Root Cause Analysis & Technical Solutions

### GAP A — Wrong-Way on the Same Route Centerline
- **The Gap in P5.6**: P5.6 required `isWrongWay && physicalDistance >= 3.0m` to trigger suspicion. If a motorcycle U-turns directly on the road centerline (lateral distance 0.5m, 1.0m, 2.0m) with heading delta 170–180°, the detector ignored the wrong-way evidence because lateral distance was $<3.0\text{m}$.
- **The Solution (P5.6.1)**:
  - Removed the lateral distance $>3\text{m}$ prerequisite for wrong-way detection. Wrong-way divergence is established purely by vehicle dynamics and heading alignment:
    - Speed $\ge 3.0\text{ m/s}$ ($10.8\text{ km/h}$, `minSpeedForCourseMetersPerSecond`).
    - Horizontal accuracy $\le 20.0\text{m}$.
    - Heading difference $\Delta\theta \ge 120^\circ$ (`wrongWayMismatchAngleDegrees`).
    - Suppressed in planned U-turn zones (`isPlannedUturnZone` when upcoming maneuver is U-turn and distance $\le 70\text{m}$).
  - Triggers suspicion immediately at 0.5m centerline displacement and confirms off-route within $0.8\text{s}$ dwell time.
  - Recovery to `onRoute` remains strictly blocked while wrong-way movement continues.

### GAP B — Secondary Route Missing Rejoin Path from Vehicle
- **The Gap in P5.6**: P5.6 retained only the detached remaining segment of old Route A as the secondary polyline. When the vehicle turned onto a side street, the secondary route floated detached from the vehicle's actual location.
- **The Solution (P5.6.1 Rejoin Route Design)**:
  - When off-route is confirmed:
    - **Primary Always Wins**: Direct route from current location to destination is calculated and applied immediately without waiting for secondary.
    - **Async Secondary Rejoin**: Concurrently, `_calculateSecondaryRejoin(currentLocation, oldRemaining)` picks a candidate rejoin waypoint ~80–150m ahead on old Route A (`rejoinTarget`), and requests a motorcycle route from `currentLocation` to `rejoinTarget`.
    - **Polyline Composition**: Upon success, `secondaryPolyline` is constructed as:
      $$\text{secondaryPolyline} = \text{rejoinRoute.polyline} + \text{oldRemaining.sublist(rejoinIndex)}$$
      providing a seamless visual path from the vehicle to the old route and continuing to destination.
    - **Fallback**: If the rejoin route calculation fails (e.g. one-way street preventing rejoin), secondary status becomes `'fallback'` and displays the remaining old geometry without breaking guidance.
    - **Destination Guard**: If the vehicle is already near the destination ($<80\text{m}$ remaining), a redundant network call is skipped and old remaining is kept as fallback.
    - **Generation Guard**: If navigation is canceled or a newer reroute occurs, late rejoin responses are discarded cleanly.

### GAP C — RouteRenderController Report/Code Mismatch & Livelock Starvation
- **The Gap in P5.6**: The P5.6 report stated starvation was eliminated, but the code still contained:
  ```dart
  await _drawer.clearLines();
  if (req.generation < _latestSubmittedGeneration) continue;
  ```
  If platform channel latency (80–180ms) exceeded GPS cadence, every incoming GPS location aborted the in-flight render immediately after `clearLines()`, causing an endless loop where lines were repeatedly erased but never drawn.
- **The Solution (Atomic Render Transaction)**:
  - Grouped `clearLines()` and `drawActiveRoute()` into an unbreakable, atomic transaction unit.
  - Once a transaction begins, it always executes both `clearLines()` and `drawActiveRoute()`.
  - Generation staleness is checked ONLY after the draw completes:
    - If superseded while drawing, cache commitment is skipped, and the loop immediately executes the newest coalesced request (`_pendingRequest`).
    - Eliminates blank-map intervals and livelock starvation entirely.
  - Added `altPoints` count change detection in `shouldRender()` so async secondary route arrivals trigger immediate visual redraw.

### Section 11 — Navigation Cancellation Cleanup
- Calling `stopNavigation()` now:
  - Increments `_secondaryRerouteGeneration` and sets `_secondaryRerouteStatus = 'none'`.
  - Clears `_activeRoute`, `_secondaryRoute`, and resets `RouteRenderController`.
  - Clears `_routes` preview cache.
  - Discards late-arriving async primary or secondary Valhalla responses.

---

## 3. Telemetry & Debug Overlay (Section 12)
The HUD in `MapScreen` displays:
- `Heading Δ`: Heading difference vs local route segment and `WrongWay: YES/NO`.
- `Primary`: Generation and status (`idle`, `requesting`, `applied`, `cooldown`, `failed`).
- `Secondary`: Generation, status (`none`, `requesting`, `applied`, `fallback`, `failed`), and `active: YES/NO`.
- `Render`: Submitted generation, committed generation, `pending: YES/NO`, and total render count.

---

## 4. Summary of Files Changed

| File | Changes Made |
|---|---|
| `mobile_app/lib/services/off_route_detector.dart` | Removed lateral distance $\ge 3\text{m}$ constraint from wrong-way detection; added `isPlannedUturnZone` suppression |
| `mobile_app/lib/services/navigation_manager.dart` | Added `isPlannedUturnZone` detection; added async secondary rejoin engine with generation guard; added `renderRevision` |
| `mobile_app/lib/services/route_render_controller.dart` | Enforced atomic render transaction (no mid-channel abort between clear and draw); added `altPoints` change detection |
| `mobile_app/lib/screens/map_screen.dart` | Bound route rendering to `renderRevision`; expanded telemetry overlay for primary/secondary gen & render queue |
| `mobile_app/test/off_route_detector_test.dart` | Added 5 tests (A, B, C, D, E) for centerline wrong-way, speed/accuracy gating, and U-turn suppression |
| `mobile_app/test/route_render_controller_test.dart` | Added tests for atomic render transaction, 180ms/120ms platform channel latency, and secondary async redraw |
| `mobile_app/test/navigation_reroute_test.dart` | Added tests for secondary rejoin connection, fallback on routing error, and cancellation guard |

---

## 5. Verification Results

### 5.1 Flutter Analyze
```text
$ flutter analyze --no-fatal-infos
Analyzing mobile_app...
No issues found! (ran in 1.7s)
```

### 5.2 Flutter Test Suite
```text
$ flutter test
00:07 +141: All tests passed!
```
Total Flutter tests: **141 passed** (+12 tests added in P5.6.1).

### 5.3 PlatformIO Firmware Build
```text
$ pio run -d firmware_esp32
PLATFORM: Espressif 32 (7.1.2) > Espressif ESP32-S3-DevKitC-1-N8
RAM:   [====      ]  41.3% (used 135416 bytes from 327680 bytes)
Flash: [====      ]  35.9% (used 1200069 bytes from 3342336 bytes)
========================= [SUCCESS] Took 4.75 seconds =========================
```

---

## 6. Verification Status Matrix

| Requirement | Automated Status | Manual Field Status | Notes |
|---|---|---|---|
| **Centerline Wrong-Way Detection** | **AUTOMATED VERIFIED** | **MANUAL FIELD PENDING** | Tested at 0.5m and 1.5m lateral distance with 170–180° heading delta; confirms in 0.8s. |
| **U-Turn Maneuver Zone Suppression** | **AUTOMATED VERIFIED** | **MANUAL FIELD PENDING** | Legitimate U-turn maneuver suppresses false wrong-way reroute. |
| **Secondary Route Rejoin from Vehicle** | **AUTOMATED VERIFIED** | **MANUAL FIELD PENDING** | Route from vehicle to rejoin point + old route tail tested. |
| **Secondary Rejoin Fallback** | **AUTOMATED VERIFIED** | **MANUAL FIELD PENDING** | Router failure falls back to old remaining route without affecting Primary. |
| **Atomic Render Transaction** | **AUTOMATED VERIFIED** | **MANUAL FIELD PENDING** | Tested under simulated 180ms clear / 120ms draw latency; zero starvation. |
| **Secondary Route Async Redraw** | **AUTOMATED VERIFIED** | **MANUAL FIELD PENDING** | Arrival of secondary route bumps `renderRevision` and triggers redraw. |
| **Cancel Navigation Generation Guard** | **AUTOMATED VERIFIED** | **MANUAL FIELD PENDING** | Late secondary response discarded; map remains empty. |
| **Telemetry & Debug Overlay** | **AUTOMATED VERIFIED** | **MANUAL FIELD PENDING** | Primary/secondary gen, status, wrong-way delta visible in HUD. |
