# P5.5 — FLUTTER PRODUCTION NAVIGATION ENGINE REPORT

## Overview & Clarification
The user installs and runs **ONLY the Flutter IPA** (~12 MB). `mobile_app/lib/`, `mobile_app/ios/`, and `firmware_esp32/` form the **PRODUCTION PATH**. Code under `mobile_app/ios_native/` is an algorithmic reference only.

P5.5 completely refactors the Flutter turn-by-turn navigation engine to resolve the two real-world failure modes identified in road testing:
1. **Old off-route detector failed to trigger reroute**: The previous detector evaluated raw point-to-vertex distances with a `>45m * 2 samples` threshold and invoked Mapbox bicycle routing instead of Valhalla motorcycle routing. On Hanoi's dense parallel streets (8–20m apart), it never rerouted.
2. **Passed route geometry persisted behind vehicle**: The map screen was drawing the full static `activeRoute.polylinePoints` rather than the trimmed remaining polyline, leaving the blue route behind the vehicle visible indefinitely.

---

## Technical Architecture & Implementations

### 1. RouteGeometry & Point-to-Segment Projection (`mobile_app/lib/services/route_geometry.dart`)
- **Equirectangular Projection**: Implements exact point-to-segment math with clamped parameter `t = [0.0, 1.0]`. Calculates projected coordinate, perpendicular lateral distance, cumulative distance along route, and segment bearing.
- **Continuous Polyline Trimming**: `trimmedPolyline(displayProgressMeters)` derivers the exact start coordinate at `displayProgressMeters` using linear interpolation (`coordinateAtDistance`), completely omitting all passed vertices without requiring a reroute.
- **Maneuver Begin Distances**: Step boundaries (`beginShapeIndex`, `endShapeIndex`, and `beginDistanceAlongRoute`) are precalculated monotonically during route geometry initialization.

### 2. Multi-Signal Off-Route State Machine (`mobile_app/lib/services/off_route_detector.dart`)
- **Deterministic Time**: Evaluates `OffRouteObservation` based on GPS/sample timestamps without wall-clock sleeps, enabling precise synthetic unit tests.
- **States**: `onRoute`, `suspected`, `confirmed`.
- **Quality-Aware Multi-Signals**:
  - *Signal A (Sustained Lateral Deviation)*: Physical route distance > `max(15.0, accuracy * 1.2)` for 2.5s moving dwell.
  - *Signal B (Course Divergence)*: Heading mismatch $\ge 45^\circ$ while moving $\ge 3.0\text{ m/s}$ with physical separation $\ge 10\text{m}$, confirmed in fast track ~1.0s.
  - *Signal C (Stuck Matcher)*: Physical GPS travels $\ge 30\text{m}$ while matched route progress advances $< 5\text{m}$.
  - *Signal D (Strong Deviation)*: Lateral distance $\ge 40\text{m}$ with good GPS accuracy ($\le 15\text{m}$), confirmed in ~1.0s.
  - *Signal E (Persistent Moderate Parallel Deviation)*: Lateral distance $10\text{m} \le d \le \text{enterThreshold}$ with good accuracy ($\le 20\text{m}$) and speed $\ge 3\text{m/s}$, confirmed in ~2.0s dwell.
  - *Drift Protection*: Stationary / low-speed vehicle uses 5.0s dwell to protect against traffic-light GPS drift.
  - *Immediate Abort*: Any sample returning within recovery threshold ($\le 10\text{m}$) immediately aborts suspicion and returns to `onRoute`.

### 3. Production Navigation Engine (`mobile_app/lib/services/navigation_manager.dart`)
- **Explicit Location Concepts**:
  - `rawLocation`: latest raw GPS coordinate from hardware.
  - `acceptedPhysicalLocation`: validated GPS sample (filtered to horizontal accuracy $\le 20\text{m}$).
  - `matchedProjection`: point projected onto active route geometry.
  - `matchedLocation`: coordinates of the projection on the route.
- **Monotonic Progress Guarantee**:
  - `_displayProgressMeters = math.max(_displayProgressMeters, matched.distanceAlongRouteMeters)`
  - Prevents GPS noise from causing passed route geometry to reappear backward.
- **Progress-Based Maneuver Advancement**:
  - Advances when `displayProgressMeters >= step.beginDistanceAlongRoute` using a while-loop.
  - Correctly handles GPS jumps skipping past intersections.
- **Single-Flight Valhalla Motorcycle Rerouting**:
  - Uses `ValhallaService` with `costing: 'motorcycle'`.
  - Removes Mapbox from active navigation rerouting.
  - Destination frozen as `_navigationDestination` across all reroutes.
  - Generation guard `_rerouteGeneration` ignores late responses.
  - Old Route A remains active and continues to progress and trim until Route B succeeds.
  - Atomic replacement: commits Route B, recalculates progress, and returns to `onRoute`.

### 4. Map Screen Presentation (`mobile_app/lib/screens/map_screen.dart`)
- Explicit `RoutePresentationMode`: `none`, `preview`, `navigating`, `arrived`.
- In `navigating`, exclusively renders `navManager.remainingPolyline`.
- Cadence throttling updates MapLibre lines smoothly without destructive teardown on every frame.
- Integrated DEBUG field diagnostics overlay (GPS accuracy, physical route distance, matched lateral distance, progress, remaining distance, off-route state, reason, reroute status).

---

## Verification Evidence

### Local Test Execution
- **Flutter Unit Tests**: 104 / 104 PASS (including 5 new test suites: `route_geometry_test.dart`, `off_route_detector_test.dart`, `navigation_progress_test.dart`, `navigation_reroute_test.dart`, `maneuver_progress_test.dart`).
- **Flutter Analyzer**: `flutter analyze` PASS with 0 errors and 0 warnings.
- **ESP32 Firmware**: PlatformIO build PASS in release mode (Flash: 35.9%, RAM: 41.3%).

### Remote GitHub Actions CI
- **Workflow Run**: `35712054187` on branch `main` (commit `82327dc`)
- **Jobs**:
  - `Compile Flutter iOS IPA`: **SUCCESS** (5m 46s)
  - `Compile ESP32-S3 Firmware`: **SUCCESS** (1m 27s)
  - `Compile Native iOS Swift/SwiftUI`: **SUCCESS** (6m 32s)
- **Artifacts**:
  - `ESP32Nav-Flutter-PRODUCTION-ipa` (Authoritative production app installed by user)
  - `ESP32Nav-Native-REFERENCE-ipa` (Algorithmic reference app)
  - `esp32_firmware_bin` (ESP32-S3 firmware)
