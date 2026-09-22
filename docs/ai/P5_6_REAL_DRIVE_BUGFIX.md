# P5.6 — REAL DRIVE BUGFIX FROM FIELD EVIDENCE REPORT

## 1. Overview & Clarification
- **Production Path**: The user installs and runs **ONLY the Flutter IPA** (~12 MB): `ESP32Nav-Flutter-PRODUCTION.ipa`. The production codebase is strictly `mobile_app/lib/`, `mobile_app/ios/`, and `firmware_esp32/`. Code under `mobile_app/ios_native/` is an algorithmic reference only.
- **Phase Purpose**: Directly resolves 6 critical navigation bugs confirmed during physical driving tests on an iPhone following P5.5 / P5.5.1 / P5.5.2 field trials.
- **ESP32 Invariant**: Streaming architecture remains strictly unchanged from P5.4.1.4 (smooth JPEG/raster map stream over Wi-Fi/BLE, no vector map on ESP).
- **Routing Engine Invariant**: Routing provider remains Valhalla motorcycle routing.

---

## 2. Executive Summary of the 6 Field Bugs & Root Causes

### BUG A — Going Off-Route / Opposite Direction Without Prompt Rerouting
- **Observed Behavior**: Vehicle deviates from the route or makes a U-turn / drives opposite to the route bearing, but the blue route line and guidance persist behind the vehicle; the app fails to recalculate the shortest route to the destination.
- **Root Cause**: `OffRouteDetector` primarily checked cross-track lateral deviation (>15m enter threshold). When a vehicle travels backwards along the same road corridor, the lateral distance remains small (<4–8m), staying well below both the cross-track and moderate lateral thresholds. Furthermore, false recovery was possible because `onRoute` recovery checks did not verify whether the vehicle was driving in the opposite direction.
- **Fix (Section 3)**:
  1. Added `OffRouteReason.wrongWayDivergence` in `OffRouteDetector`.
  2. If the physical movement bearing differs from the local route segment bearing by $\ge 120^\circ$ (`wrongWayMismatchAngleDegrees`), with speed $\ge 3.0\text{ m/s}$ ($10.8\text{ km/h}$) and horizontal accuracy $\le 20.0\text{m}$, the detector escalates to `suspected` at $\ge 3.0\text{m}$ lateral deviation.
  3. Dwell time for wrong-way divergence is reduced from $2.0\text{s}$ to $0.8\text{s}$ (`wrongWayDwellSeconds`), confirming off-route and triggering Valhalla rerouting in less than a second.
  4. Recovery to `onRoute` is strictly blocked while wrong-way divergence persists.

### BUG B & BUG E — Route Trimming Delay (3–5s Lag) & Stale Route Behind Vehicle
- **Observed Behavior**: Route line refresh on the map felt delayed by 3–5 seconds; route segments already passed by the vehicle persisted behind the vehicle for seconds instead of disappearing in near real-time.
- **Root Cause**: In `RouteRenderController._drainQueue()`, after completing `await _drawer.clearLines()`, the controller checked `if (req.generation < _latestSubmittedGeneration) continue;`. With GPS updates arriving at 1–2 Hz and MapLibre iOS platform channels taking 80–180ms per clear+draw, rapid arrivals caused subsequent requests to abort the in-flight render before `drawActiveRoute` was invoked. This created a livelock starvation loop where `clearLines()` was repeatedly called but `drawActiveRoute()` was skipped until the car stopped or GPS paused.
- **Fix (Section 5)**:
  1. Updated `RouteRenderController` to allow the active drawing call to proceed without mid-channel abort, checking generation only upon full completion.
  2. Implemented `_throttledUpdateRouteOnMap()` in `MapScreen` using a dedicated coalescing timer (~250ms cadence) decoupled from camera animation throttles, guaranteeing high-responsiveness (~4 Hz) without platform channel starvation.
  3. Continuous route trimming monotonically removes passed coordinates on each valid GPS update.

### BUG C — Canceling Navigation Left Route Lines on Map
- **Observed Behavior**: When user pressed Cancel / Stop navigation, route lines remained visible on the map.
- **Root Cause**: In `MapScreen._presentationMode`, the logic was:
  ```dart
  if (isNavigating) return RoutePresentationMode.navigating;
  if (_routes.isNotEmpty) return RoutePresentationMode.preview;
  ```
  When `stopNavigation()` set `isNavigating = false` and fired `notifyListeners()`, `_routes` still held the initial search route list, causing `_presentationMode` to fall back to `preview` mode and redraw the route line instead of clearing it.
- **Fix (Section 8)**:
  1. In `MapScreen`, `stopNavigation()` now explicitly calls `_routeRenderController.reset()`, clears `_routes = []`, resets `_selectedRouteIndex = 0`, and submits an immediate empty redraw request with `mode: RoutePresentationMode.none, forceRedraw: true`.
  2. `NavigationManager.stopNavigation()` clears `_activeRoute = null`, `_secondaryRoute = null`, `_secondaryPolyline = []`, `_remainingPolyline = []`, and resets all guidance states.

### BUG D & BUG B — Maneuver Direction Inversion & Step Desynchronization
- **Observed Behavior**: The route line turned right, but the banner icon and instruction pointed left; banner instruction text lagged behind the vehicle's actual segment.
- **Root Cause**:
  1. In `ValhallaService`, Valhalla Odin maneuver type integers were misaligned: type 9 (`kSlightRight`) was mapped to `'straight'`, type 10 (`kRight`) was mapped to `'slight right'`, and type 11 (`kSharpRight`) was mapped to `'right'`.
  2. In `NavStep.maneuverType`, if `maneuverModifier` was null, it only evaluated `maneuverTypeStr`, defaulting unparsed strings to straight.
  3. In `NavigationManager` and `MapScreen`, banner text, icon, and distance used independent step index calculations (+0 vs +1) rather than a single authoritative step model.
- **Fix (Section 6 & 7)**:
  1. Standardized Valhalla Odin type mapping in `ValhallaService`:
     - 9: `kSlightRight` -> `slight right`
     - 10: `kRight` -> `turn right`
     - 11: `kSharpRight` -> `sharp right`
     - 12 / 13: `kUturn` -> `u-turn`
     - 14: `kSharpLeft` -> `sharp left`
     - 15: `kLeft` -> `turn left`
     - 16: `kSlightLeft` -> `slight left`
  2. Updated `NavStep.maneuverType` to combine both `maneuverModifier` and `maneuverTypeStr`.
  3. Added `authoritativeCurrentManeuver`, `bannerInstruction`, and `bannerTurnIcon` getters in `NavigationManager`. The banner text, icon, along-step distance, and ESP32 BLE payload are now strictly derived from this single authoritative object.

### BUG F — Dual-Route Rerouting: Primary Active Route + Secondary Reference Route
- **Product Requirement**: When going off-route, the app must compute the shortest route from the current position to the destination as the **Primary Route** (vibrant blue, 100% opacity), while retaining a reference to the previous route as a **Secondary Route** (pale blue, ~45% opacity). Only the primary route drives guidance, banner, maneuver icons, ETA, and ESP32 streaming.
- **Implementation (Section 4 & 10)**:
  1. In `NavigationManager`, when a rerouted route arrives and is applied, the remaining portion of the previous active route is retained in `_secondaryRoute` and exposed via `secondaryPolyline`.
  2. In `MapScreen`, `_MapLibreLineDrawer.drawActiveRoute()` draws the secondary reference route first (color `#007AFF`, opacity 0.45, width 5.0px) underneath the primary active route (color `#007AFF`, opacity 1.0, width 7.0px).
  3. Only the primary route affects `currentStep`, `authoritativeCurrentManeuver`, `remainingDistanceMeters`, ETA, voice guidance, and ESP32 BLE navigation stream.
  4. Both routes are cleanly erased upon navigation cancellation or destination arrival.

### Section 9 — Display Current Location vs Matched Location
- **Requirement**: Vehicle indicator (blue dot/puck) should not create the illusion that the vehicle is stuck on the old route when physically deviated.
- **Implementation**: Added `displayVehicleLocation` in `NavigationManager`. When off-route is `suspected` or `confirmed`, `displayVehicleLocation` defaults to `acceptedPhysicalLocation ?? rawLocation`, ensuring the map puck and camera reflect physical reality rather than the old road corridor.

---

## 3. Telemetry & Debug Overlay (Section 12)
The HUD in `MapScreen` has been expanded to display:
- **Physical vs Matched Coordinates**: Lat/Lon of GPS input vs projected point.
- **Authoritative Step & Maneuver**: Step index, type, modifier, and banner text.
- **Directional Signals**: Heading, Route Bearing, Heading Delta ($\Delta\theta$), and Wrong-Way flag (`WW: YES/NO`).
- **Off-Route & Reroute State**: State (`onRoute`, `suspected`, `confirmed`), Reason, and Reroute Status (`idle`, `requesting`, `applied`, `cooldown`, `failed`).
- **Route Metrics**: Primary Revision, Secondary Route present (`SEC: YES/NO`), and Render Count.

---

## 4. Summary of Files Changed

| File | Changes Made |
|---|---|
| `mobile_app/lib/models/route_model.dart` | Combined modifier and type string in `maneuverType`; directional mapping for icons and turnCodes |
| `mobile_app/lib/services/valhalla_service.dart` | Corrected Odin maneuver type integers (9 slight right, 10 right, 11 sharp right, 12/13 uturn, 14 sharp left, 15 left, 16 slight left) |
| `mobile_app/lib/services/off_route_detector.dart` | Added `wrongWayDivergence`, $120^\circ$ mismatch threshold, $0.8\text{s}$ dwell, blocked false recovery |
| `mobile_app/lib/services/navigation_manager.dart` | Added `authoritativeCurrentManeuver`, `bannerInstruction`, `bannerTurnIcon`, `secondaryPolyline`, `displayVehicleLocation`, BLE payload update |
| `mobile_app/lib/services/route_render_controller.dart` | Prevented platform channel draw starvation, supported dual-route draw calls |
| `mobile_app/lib/screens/map_screen.dart` | Clean cancel cleanup, secondary pale-blue route rendering, ~250ms coalesced route update, expanded debug HUD |
| `mobile_app/test/off_route_detector_test.dart` | Added tests for wrong-way off-route detection & false recovery blocking |
| `mobile_app/test/maneuver_progress_test.dart` | Added authoritative maneuver synchronization and monotonic route trimming tests |
| `mobile_app/test/route_and_search_test.dart` | Added comprehensive directional maneuver type & icon mapping test |
| `mobile_app/test/route_render_controller_test.dart` | Added dual-route rendering, cancel invalidation, and 10 Hz starvation prevention tests |
| `mobile_app/test/navigation_reroute_test.dart` | Added wrong-way fast rerouting with Route B primary + Route A secondary, and cancel route clearing tests |

---

## 5. Verification Results

### 5.1 Flutter Analyze
```text
$ flutter analyze --no-fatal-infos
Analyzing mobile_app...
No issues found! (ran in 1.3s)
```

### 5.2 Flutter Test Suite
```text
$ flutter test
00:07 +129: All tests passed!
```
Total Flutter tests: **129 passed** (including all unit, concurrency, latency, progression, and P5.6 bugfix tests).

### 5.3 PlatformIO Firmware Build
```text
$ pio run -d firmware_esp32
PLATFORM: Espressif 32 (7.1.2) > Espressif ESP32-S3-DevKitC-1-N8
RAM:   [====      ]  41.3% (used 135416 bytes from 327680 bytes)
Flash: [====      ]  35.9% (used 1200069 bytes from 3342336 bytes)
========================= [SUCCESS] Took 8.80 seconds =========================
```

---

## 6. Verification Status Matrix

| Bug / Requirement | Automated Status | Manual Field Status | Verification Notes |
|---|---|---|---|
| **BUG A: Wrong-way off-route detection** | **AUTOMATED VERIFIED** | **MANUAL FIELD PENDING** | 120° heading delta + speed triggers `wrongWayDivergence` and confirms in 0.8s. |
| **BUG B: Route trimming behind vehicle** | **AUTOMATED VERIFIED** | **MANUAL FIELD PENDING** | Route trimmed monotonically on each position update. |
| **BUG C: Cancel navigation clean clear** | **AUTOMATED VERIFIED** | **MANUAL FIELD PENDING** | Active & secondary polylines cleared; presentation mode set to none. |
| **BUG D: Maneuver icon left/right mapping** | **AUTOMATED VERIFIED** | **MANUAL FIELD PENDING** | Odin enum mappings verified; left/right turns tested comprehensively. |
| **BUG E: Route render latency (no 3-5s lag)** | **AUTOMATED VERIFIED** | **MANUAL FIELD PENDING** | Starvation eliminated; 250ms coalesced updates tested up to 10 Hz. |
| **BUG F: Dual-route primary + secondary** | **AUTOMATED VERIFIED** | **MANUAL FIELD PENDING** | Primary drives guidance; secondary rendered at 45% opacity beneath primary. |
| **Section 9: Display location vs matched** | **AUTOMATED VERIFIED** | **MANUAL FIELD PENDING** | Puck follows accepted physical location when off-route. |
| **Section 12: Expanded Debug HUD** | **AUTOMATED VERIFIED** | **MANUAL FIELD PENDING** | Physical/matched lat-lng, step index, heading delta, WW status visible in HUD. |
