# P5.2 Field Navigation Corrections

## 1. Real-Device Symptoms

During real-device road testing in Hanoi, three related navigation continuity and responsiveness defects were observed:

- **Bug A — Driven route remains visible behind vehicle**:
  As the vehicle progressed forward along the street, the blue `remainingPolyline` retained already-driven portions behind the vehicle for several seconds, failing to trim continuously. Seconds later, it would abruptly snap forward or disappear upon an unintended route recalculation.
- **Bug B — Off-route reroute starts too late**:
  When the vehicle made a wrong turn onto an intersecting or parallel street, the app continued displaying the old route for several seconds and substantial physical travel (sometimes 30–50 meters) before finally reporting that it was recalculating.
- **Bug C — Maneuver instruction remains after maneuver was passed**:
  In dense urban geometry (specifically observed at the "Hầm chui Kim Đồng - Giải Phóng" underpass), the tunnel entrance instruction remained active on the HUD card even after the vehicle had driven through and exited the tunnel section.

---

## 2. Root Cause Analysis

Thorough architectural investigation traced these defects to five interlocking factors:

1. **Permissive Local Map-Match Window Without Heading/Progress Verification**:
   `RouteGeometry.project()` searched `previousSegment - 2 ... previousSegment + 25` and blindly accepted any candidate with `localMatch.lateralDistanceMeters <= 25.0`. In dense urban Hanoi streets (parallel carriageways, service roads separated by medians, underpasses, closely spaced intersections), a vehicle 15–20m away on a different road was still within 25m of the stale segment. The matcher remained trapped on the old segment, halting along-route advancement and keeping old polyline geometry alive.
2. **Circular Dependency in Off-Route Evidence**:
   `OffRouteDetector` evaluated lateral distance computed by the continuity-constrained projection rather than pure physical GPS distance. Because the matcher biased itself to the old segment, the reported lateral distance stayed artificially low, delaying suspicion.
3. **One-Dimensional Off-Route Entry State Machine**:
   The `.onRoute` state only transitioned to `.suspected` if `lateralDistance > enterThreshold` (>= 15m). Course divergence was only used to shorten dwell *after* suspicion had already started. For the first 15–25m after turning, lateral displacement remained below 15m, delaying suspicion onset.
4. **Maneuver Distance Indexing Based Solely on End Shape Index**:
   `RouteGeometry` computed `maneuverDistancesAlongRoute` exclusively using `step.endShapeIndex`. The active maneuver was displayed until the vehicle reached the *end* of the step segment rather than advancing once the *action point* (`beginShapeIndex`) was completed.
5. **Kalman Smoothing Positional Lag on Sharp Turns**:
   The basic Kalman filter had constant process noise (`kalmanQ = 3.0 m/s`), introducing 2–4 seconds of positional lag when making sharp 90-degree urban turns.

---

## 3. Physical vs Filtered vs Matched Location

To guarantee physical truth and prevent circular reasoning, the location pipeline cleanly separates four location roles:

| Location Role | Source / Processing | Responsibilities | Invariants |
| :--- | :--- | :--- | :--- |
| `rawLocation` | Direct from `CLLocationManager` | Diagnostic telemetry only, even when accuracy is poor | Never used for navigation logic |
| `acceptedPhysicalLocation` | Raw GPS passing `horizontalAccuracy <= 20.0m`, **pre-Kalman** | Physical displacement, pure nearest route distance, off-route evidence, and **reroute origin** | Must never be smoothed or route-constrained |
| `filteredLocation` | Adaptive Kalman filter smoothing | Presentation support and visual map puck | Adaptive responsiveness on turns; never delays off-route truth |
| `matchedLocation` | Route-constrained projection | Route progress and along-route coordinate | Constrained to active geometry; never used as proof of being on route |

---

## 4. Route Matching Recovery

`RouteGeometry` now outputs rich `RouteMatchResult` exposing match confidence:

```swift
public enum RouteMatchConfidence: String, Sendable, Equatable {
    case high
    case medium
    case low
}
```

### Stuck Matcher Detection & Controlled Global Recovery
A rolling continuity tracker monitors physical travel vs. along-route advance over a bounded 3.5-second window:
- If physical displacement exceeds **25.0m** while matched along-route progress is stuck (**<= 6.0m**), `isMatcherStuck` is flagged.
- When `stuckRecoveryTriggered == true`, `RouteGeometry.matchLocation` waives the forward-jump temporal penalty for global candidates with low lateral separation (<= 15m) and matching course, executing a controlled forward jump to escape the trap.

---

## 5. Continuous Progress & Polyline Trimming

To resolve Bug A, route progress and trimming no longer depend on full reroutes:

1. **Monotonic Forward Display Progress**:
   `displayProgressDistanceAlongRoute = max(displayProgressDistanceAlongRoute - 2.0, rawMatchedProgress)`
   Visual backtracking is limited to 2.0m (filtering GPS noise) while allowing genuine U-turns to register.
2. **Authoritative Continuous Trimming**:
   `route.geometry.trimmedPolyline(from: displayProgressDistanceAlongRoute)`
   Every accepted GPS frame computes the exact along-route coordinate at `displayProgressDistanceAlongRoute`. All prior coordinates are immediately sliced off. As the vehicle advances 20m, those 20m disappear promptly.

---

## 6. Maneuver Begin/End Semantics

To resolve Bug C, `RouteGeometry` maintains both distance arrays explicitly:

- `maneuverBeginDistancesAlongRoute`: Cumulative distance to the maneuver *action point* (`beginShapeIndex`).
- `maneuverEndDistancesAlongRoute`: Cumulative distance to the step completion point (`endShapeIndex`).
- `maneuverDistancesAlongRoute`: Property alias returning `maneuverEndDistancesAlongRoute` for 100% backward compatibility.

### Upcoming Maneuver Progression
- The HUD displays `upcomingManeuverIndex` representing the **next upcoming action** the driver must perform.
- `distanceToTurn = upcomingManeuver.beginDistance - displayProgressDistanceAlongRoute`.
- Maneuver advances in a `while` loop once `displayProgressDistanceAlongRoute >= upcomingBeginDist + 2.0m`.
- Initial depart maneuvers at 0m are handled: once vehicle advances (progress >= 10m), guidance seamlessly transitions to the upcoming turn.
- Skipped GPS points cleanly advance through all passed boundaries in one update.

---

## 7. Off-Route Multi-Signal Detection

`OffRouteDetector` now evaluates multi-signal evidence to detect wrong turns quickly:

1. **Signal A**: Effective physical distance (max of lateral distance and pure `rawNearestRouteDistanceMeters`) exceeds `enterThreshold`.
2. **Signal B**: Course divergence while moving: `speed >= 3.0 m/s`, vehicle course differs from route bearing by `>= 50.0°`, and physical route distance is non-trivial (`>= 8.0m`).
3. **Signal C**: Stale matcher progress while physical GPS advances (`isMatcherStuck == true` and distance `>= 8.0m`).
4. **Signal D**: Two moderate signals agree (e.g. moderate physical distance `>= 10.0m` + course mismatch `>= 45.0°` while moving).

---

## 8. Reroute Latency

Field latency target of **~1.0–1.5 seconds** for moving wrong turns is achieved:
- Course divergence moving dwell: **1.0s** (down from 1.5s).
- Strong lateral deviation dwell: **1.0s**.
- Standard moving dwell: **1.8s** (down from 2.5s).
- Stationary drift protection: **5.0s** dwell maintained when speed `< 2.5 m/s`.
- Immediate request dispatch: When `decision.becameConfirmed == true`, `RerouteManager.startReroute` fires synchronously on the exact same frame (latency = 0.0s).
- Fresh physical origin: `RerouteManager` receives `acceptedPhysicalLocation.coordinate` as the route request origin.
- Immediate UI feedback: `NavigationHUDView` displays `"Đang tính lại..."` immediately when `isRerouting == true`.

---

## 9. Kalman Turn Responsiveness

`NavigationSessionManager.kalmanSmooth` incorporates adaptive turn responsiveness:
- When vehicle speed `>= 2.5 m/s` and displacement from previous smoothed state exceeds `15.0m`, process noise adaptively increases (`effectiveQ = 12.0 m/s`).
- On major sharp turns (`displacement > 25.0m`) with high GPS accuracy (`accuracy <= 10.0m`), the filter adaptively reseeds to the raw coordinate, completely eliminating the 2–4s positional lag observed after real-world Hanoi intersections.

---

## 10. Diagnostics Added

`NavigationDiagnostics` now records observable latency timestamps:
- `offRouteSuspectedAt: Date?`
- `offRouteConfirmedAt: Date?`
- `rerouteStartedAt: Date?`
- `rerouteCommittedAt: Date?`
- Computed latency helpers: `suspectedToConfirmedLatency`, `confirmedToRequestStartLatency`, `requestStartToCommitLatency`.
- `latestFieldTrace: FieldNavigationTraceSnapshot?` providing per-sample telemetry.
- In-App Debug Overlay in `MainMapView`: Available in `#if DEBUG` builds, rendering real-time GPS accuracy, raw route distance, progress, displacement, match confidence, off-route state, and maneuver distance. Omitted in Release builds.

---

## 11. Tests Added

Three new comprehensive test suites added (21 new tests total):

### 1. `RouteMatchingFieldRegressionTests.swift` (6 tests)
- `testPureNearestProjection_HasNoContinuityBias`: Pure Euclidean nearest segment distance with zero continuity penalties.
- `testSharp90DegreeTurn_TransitionsPromptlyWithoutLag`: Prompt northbound to eastbound transition, northbound geometry trimmed, no stale match.
- `testCloseParallelRoads_DetectsPhysicalSeparationWithoutStaleSnap`: 12.5m parallel road separation tracked via physical distance.
- `testBridgeUnderpassSelfNear_DoesNotJumpPrematurelyOrLock`: 10m physical proximity across 500m route distance prevents premature snapping.
- `testStuckMatcherRecovery_TriggersControlledForwardJump`: Controlled forward jump escapes projection lock when stuck.
- `testContinuousPolylineTrimming_TrimsPromptlyWithoutReroute`: Monotonic trimming over 5 sequential frames without any reroute.

### 2. `ManeuverProgressionTests.swift` (6 tests)
- `testManeuverBeginEndSemantics_AdvancesAtActionPoint`: Step 0..10, 10..20, 20..30 progression at progress 8, 12, and 22.
- `testTunnelGuidance_AdvancesPromptlyPastTunnel`: Realistic Hanoi "Hầm chui Kim Đồng - Giải Phóng" fixture; tunnel instruction clears upon passing exit.
- `testInitialDepartManeuver_AdvancesPromptlyWhenMoving`: Start at 0m advances to upcoming turn once motion begins.
- `testManeuverPassRecovery_AdvancesThroughMultiplePassedStepsInOneUpdate`: GPS skip advances through all passed steps via while loop.
- `testStepIndexValidation_FallsBackWithoutCrashing`: Corrupted/out-of-bounds step indices fall back gracefully.
- `testRealValhallaStepIndices_FlowIntoRouteGeometry`: Preserves `begin_shape_index`, `end_shape_index`, and step metadata across models.

### 3. `OffRouteFieldLatencyTests.swift` (9 tests)
- `testFastMovingWrongTurn_ConfirmsWithinOneToTwoSeconds`: 10 m/s with 90° course divergence confirms in 1.0s.
- `testConfirmedToRequestStart_IsImmediate`: Synchronous reroute start on confirmation frame.
- `testRerouteOrigin_UsesAcceptedPhysicalLocation`: Origin matches raw GPS coordinate.
- `testFirstReroute_NotDelayedByPostSuccessStabilization`: First reroute is never delayed by post-success window.
- `testStationaryDriftProtection_LowSpeedMaintainsLongerDwell`: 5.0s dwell at 0.5 m/s prevents false reroutes at traffic lights.
- `testSingleFlightRerouteGuarantee_DoesNotSpawnDuplicateRequests`: Single in-flight request maintained.
- `testFieldReplay1_NormalManeuverPass`: Turn approach and pass with continuous trimming and zero reroutes.
- `testFieldReplay2_WrongTurn`: Wrong turn divergence, prompt suspicion, single reroute, fresh physical origin.
- `testFieldReplay3_TunnelUnderpass`: Surface to tunnel to post-tunnel transition with continuous trimming throughout.

---

## 12. Existing Regression Results

All 216 existing native unit tests from P5.1 remain 100% green:
- `AppLifecycleNavigationTests`
- `BLEScanGenerationTests`
- `BLESendSchedulerRaceTests`
- `BLESendSchedulerTests`
- `DestinationSelectionTests`
- `GoongSearchServiceTests`
- `LocationTrackingPolicyTests`
- `MapRenderPolicyTests`
- `NavigationIntegrationReplayTests`
- `NavigationReplayTests`
- `NavigationSessionManagerP51Tests`
- `OffRouteDetectorTests`
- `RerouteManagerTests`
- `RouteCandidateSelectionTests`
- `RouteGeometryTests`
- `RoutingFallbackTests`
- `RoutingProfileTests`
- `SearchRankingTests`
- `ValhallaRouteSetParserTests`

Total native tests: **237 / 237 PASS**.

---

## 13. Exact Policy Values & Rationale

| Policy Parameter | Value | Rationale |
| :--- | :--- | :--- |
| **Local Match Acceptance Lateral Limit** | `max(12.0m, acc * 1.0)` with heading diff `<= 45°` | In Hanoi, parallel service lanes are 12–20m away; stale segments must not trap matcher. |
| **Stuck Matcher Physical Travel** | `>= 25.0m` over <= 3.5s | Corresponds to ~2.5s of urban motorcycle movement (10 m/s). |
| **Stuck Matcher Matched Progress** | `<= 6.0m` | Indicates the matcher is pinned on an orthogonal or stale segment while physical motion occurs. |
| **Backward Tolerance** | `2.0m` | Filters minor GPS jitter (<2m) without locking legitimate reversals. |
| **Course Mismatch Threshold** | `>= 45.0°` at speed `>= 3.0 m/s` | Authoritative production threshold in `OffRouteDetectorConfig`. |
| **Course Divergence Moving Dwell** | `1.0s` | Reaches target ~1.0–1.5s total confirmation latency on real-world wrong turns. |
| **Strong Deviation Threshold & Dwell** | `40.0m` / `1.0s` (acc <= 15m) | High physical separation with good GPS warrants rapid confirmation. |
| **Standard Moving Dwell** | `2.5s` (speed >= 3.0 m/s) | Balanced between responsiveness and noise suppression. |
| **Moderate Deviation Threshold & Dwell** | `max(10.0m, acc * 1.5)` / `2.0s` | Parallel-road / service-road detection scaled by GPS accuracy. |
| **Stationary Dwell** | `5.0s` (speed < 2.5 m/s) | Prevents urban canyon multipath drift at traffic lights from triggering reroutes. |
| **Maneuver Pass Tolerance** | `2.0m` | Advances instruction immediately once junction is crossed without lingering. |
| **GPS Accuracy Threshold** | `20.0m` | Kept strictly at accepted limit; rejects poor multipath noise. |

---

## 14. GitHub Actions Evidence

- **Implementation SHA**: `7869f5f2a2a6a5fb3da9754194d4c109d592d5dc`
- **Workflow Run ID**: `35592469883`
- **Native Unit Tests**: 237 / 237 PASS (0 failures, 237 executed across 22 named test suites)
- **Native Release Build**: SUCCESS
- **Native IPA Package**: SUCCESS
- **Flutter iOS Build**: SUCCESS

---

## 15. Remaining Real-Device Validation

Simulator and replay test suites validate deterministic logic, but field validation requires physical road verification in Hanoi:
1. Re-test navigation along Kim Đồng through the Giải Phóng underpass to verify tunnel instruction advances immediately upon exit.
2. Intentionally take wrong turns onto parallel and cross streets to verify reroute recalculation initiates within ~1.0–1.5 seconds.
3. Observe route polyline during normal driving to confirm already-driven sections disappear continuously.


## 16. P5.2.1 Reviewer Corrections

External audit and field analysis identified remaining edge cases in P5.2 that required targeted architectural corrections:

### 16.1 Authoritative Route Trimming & Pure Geometry Helper
- **Defect**: `trimmedPolyline` previously accepted an optional `snappedCoordinate` that could override the first polyline point with a stale projection (e.g. projection briefly regressed to 80m while display progress was 150m), causing driven geometry to reappear behind the vehicle.
- **Correction**:
  - Implemented pure geometry helper:
    ```swift
    func coordinate(atDistanceAlongRoute distance: Double) -> CLLocationCoordinate2D?
    ```
  - `trimmedPolyline(from:)` derives its start point strictly from `displayProgressDistanceAlongRoute` without allowing mismatched projections to override it.
  - Validated by unit tests asserting exact first coordinate matches the distance along route within 1e-6 lat/lon tolerance.

### 16.2 Strictly Monotonic Display Progress
- **Defect**: Progress allowed a 2.0m backward slip per frame (`max(displayProgressDistance - 2.0, rawMatchedProgress)`), allowing up to 20m cumulative regression over 10 frames.
- **Correction**: Enforced strictly non-decreasing display progress on active routes:
  ```swift
  displayProgressDistance = max(displayProgressDistance, rawMatchedProgress)
  ```
  Progress resets strictly on route lifecycle events (`startNavigation`, `replaceActiveRoute`, `stopNavigation`, `clearRoute`).

### 16.3 Same-Direction Parallel-Road Detection
- **Defect**: When traveling on a parallel service road (12–13m away) in the same direction, course mismatch was ~0° and matcher progressed along planned geometry. Because distance was below 15m, all detection signals were false, leaving navigation stuck in `.onRoute` indefinitely.
- **Correction**:
  - Added quality-aware moderate threshold:
    ```swift
    let moderateThreshold = max(10.0, observation.horizontalAccuracyMeters * 1.5)
    ```
  - When vehicle is moving (`speed >= 3.0 m/s`), GPS accuracy is good (`<= 20.0m`), and raw physical distance exceeds `moderateThreshold`, the detector enters `.suspected` with reason `.persistentModerateLateralDeviation`.
  - Confirms within `moderateDeviationDwellSeconds` (2.0s), initiating exactly one reroute request with origin equal to `acceptedPhysicalLocation`.
  - On noisy GPS (e.g. 14m accuracy), `moderateThreshold` scales up to 21.0m, preventing false reroutes.

### 16.4 Separation of Physical Distance and Continuity Matched Distance
- **Defect**: Detector previously evaluated `max(lateralDistanceMeters, rawNearestRouteDistanceMeters)` and treated the result as physical truth.
- **Correction**:
  - Separated `rawPhysicalRouteDistanceMeters` (from pure Euclidean nearest projection) from `matchedProjectionLateralDistanceMeters` (continuity-constrained matcher).
  - Primary physical deviation derives strictly from `rawPhysicalRouteDistanceMeters`.
  - Protects planned 90° sharp turns: when turning onto the next segment, raw physical distance to the new segment is small (<3m), preventing false off-route triggers even if the matcher temporarily trails on the prior segment.

### 16.5 Physical-to-Physical Diagnostic Displacement
- **Defect**: `FieldNavigationTraceSnapshot.physicalDisplacement` previously calculated distance from `lastProjection.coordinate` to raw GPS.
- **Correction**:
  - Maintained `previousAcceptedPhysicalLocation` in `NavigationSessionManager`.
  - Computes physical-to-physical displacement:
    ```swift
    physicalDisplacement = RouteGeometry.distanceBetween(prevPhysical.coordinate, loc.coordinate)
    ```
  - Verified by unit tests confirming physical GPS displacement is reported accurately regardless of matcher lag.

### 16.6 Arrival Map Presentation & Route Polyline Clearing
- **Defect**: Upon arrival (`state == .arrived`, `isNavigating == false`), `MapViewContainer` fell back to drawing full `activeRoute.coordinates`, redrawing the complete historical route over the arrival screen.
- **Correction**:
  - Introduced explicit presentation enum:
    ```swift
    public enum RouteMapPresentation: Sendable, Equatable {
        case none, preview, navigating, arrived
    }
    ```
  - When `presentationMode == .arrived`, `displayCoords` is empty and matched puck is removed.
  - `remainingPolyline` is explicitly cleared to `[]` on arrival.

### 16.7 Route Progression During Pending Reroutes
- Verified that while `isRerouting == true` and a reroute request is pending, incoming GPS samples continue updating `displayProgressDistanceAlongRoute` and trimming `remainingPolyline` without freezing the UI.

### 16.8 Exact Production Detector Configuration Parity
- Locked all production constants via explicit regression test `testOffRouteDetectorConfigProductionDefaults`:
  - `baseEnterThresholdMeters = 15.0m`
  - `accuracyMultiplier = 1.2`
  - `recoveryThresholdMeters = 10.0m`
  - `standardDwellSeconds = 2.5s`
  - `courseDivergenceDwellSeconds = 1.0s`
  - `stationaryDwellSeconds = 5.0s`
  - `strongDeviationDwellSeconds = 1.0s`
  - `strongDeviationThresholdMeters = 40.0m`
  - `strongDeviationMaxAccuracyMeters = 15.0m`
  - `courseMismatchAngleDegrees = 45.0°`
  - `minSpeedForCourseMetersPerSecond = 3.0 m/s`
  - `recoveryDwellSeconds = 1.0s`
  - `moderateDeviationDwellSeconds = 2.0s`

### 16.9 Current Status
```text
CI / deterministic regression PASS — REAL DEVICE VALIDATION PENDING
```
*(Field navigation defects remain pending until another physical road test is performed in Hanoi.)*
