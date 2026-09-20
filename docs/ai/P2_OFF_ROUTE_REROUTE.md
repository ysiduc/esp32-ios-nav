# P2 Off-Route & Reroute Report

## 1. Executive Summary

Phase P2 replaces the fragile, frame-counting off-route mechanism with a deterministic, quality-aware detection system (`OffRouteDetector`) and a robust routing request coordinator (`RerouteManager`).

### Key Deliverables:
1. **Pure Off-Route Detector (`OffRouteDetector`)**: A zero-dependency, deterministic state machine operating across three explicit states (`onRoute`, `suspected`, `confirmed`).
2. **Quality-Aware Dynamic Thresholds**: Deviation threshold scales dynamically with GPS accuracy ($T_{\text{enter}} = \max(T_{\text{base}}, \text{acc} \times 1.2)$), preventing false triggers during GPS degradation.
3. **Temporal Dwell Confirmation (Frame-Count Eliminated)**: Replaced unstable 2-sample counting with timestamp-based dwell times (2.5s moving, 1.5s moving with course divergence, 5.0s stationary drift safeguard, 1.0s strong physical deviation).
4. **Hysteresis & Recovery**: Strict dual-threshold separation ($T_{\text{enter}} \ge 15.0\text{m}$ vs. $T_{\text{recovery}} = 10.0\text{m}$) and recovery dwell (1.0s) eliminate state oscillation and threshold flapping.
5. **Reroute Coordinator (`RerouteManager`)**: Coordinates single-flight routing requests, atomic Route B replacement, bounded failure backoff (2s, 4s, 8s, 15s max), and observation-driven retries.
6. **Architectural Bug Fix**: Fixed the critical architectural defect where a failed reroute permanently locked `isOffRoute = true` without retry capability until returning to the old route.
7. **Concurrency & Generation Safety**: Complete protection against stale responses and replacement races across `sessionGeneration`, `activeRouteGeneration`, and `rerouteRequestGeneration`.
8. **Physical Origin & Frozen Destination**: Off-route reroutes strictly originate from current physical coordinates (`filteredLocation`), while keeping `navigationDestination` strictly frozen.

---

## 2. Files Changed

| File | Purpose |
| :--- | :--- |
| [`mobile_app/ios_native/Sources/Navigation/OffRouteDetector.swift`](file:///mobile_app/ios_native/Sources/Navigation/OffRouteDetector.swift) | Pure, deterministic off-route detector with dynamic accuracy-aware thresholds, time-based dwell confirmation, speed/course classification, and hysteresis recovery. |
| [`mobile_app/ios_native/Sources/Navigation/RerouteManager.swift`](file:///mobile_app/ios_native/Sources/Navigation/RerouteManager.swift) | Reroute coordinator ensuring single in-flight requests, observation-driven retries, bounded exponential backoff, atomic route replacement, and generation safety. |
| [`mobile_app/ios_native/Sources/Services/ValhallaWrapper.swift`](file:///mobile_app/ios_native/Sources/Services/ValhallaWrapper.swift) | Defined `RoutingServiceProtocol` and conformed `ValhallaRoutingService` to enable deterministic dependency injection in unit tests. |
| [`mobile_app/ios_native/Sources/Services/NavigationSessionManager.swift`](file:///mobile_app/ios_native/Sources/Services/NavigationSessionManager.swift) | Integrated `OffRouteDetector` into location pipeline; published `offRouteDecision` and `offRouteState`; removed 2-sample frame counters; reset detector on start/stop/replace. |
| [`mobile_app/ios_native/Sources/ViewModels/NavigationViewModel.swift`](file:///mobile_app/ios_native/Sources/ViewModels/NavigationViewModel.swift) | Wired `RerouteManager` directly to session observations; unified `startNavigation()`, `stopNavigation()`, and `recalculateForTransportMode()`. |
| [`mobile_app/ios_native/Tests/ESP32NavAppTests/OffRouteDetectorTests.swift`](file:///mobile_app/ios_native/Tests/ESP32NavAppTests/OffRouteDetectorTests.swift) | 10 deterministic unit tests verifying on-route driving, GPS spikes, sustained wrong turns, stationary drift, dynamic accuracy scaling, and hysteresis. |
| [`mobile_app/ios_native/Tests/ESP32NavAppTests/RerouteManagerTests.swift`](file:///mobile_app/ios_native/Tests/ESP32NavAppTests/RerouteManagerTests.swift) | 10 deterministic unit tests verifying single-flight guarantee, bounded backoff retries, fresh physical origins, frozen destinations, generation race discards, and transport-mode supersession. |
| [`docs/ai/P1_LOCATION_ROUTE_PROGRESS.md`](file:///docs/ai/P1_LOCATION_ROUTE_PROGRESS.md) | Corrected P1 report metadata with verified baseline SHA `0f7e3249349c97b107982decba1e5d60fdb1d319` and Run ID `35521300154`. |

---

## 3. Previous Failure Mode

In the legacy implementation (`NavigationSessionManager.computeProgress()`):
```swift
let lateralDist = projection.lateralDistanceMeters
if lateralDist > 15.0 {
    offRouteCount += 1
    if !offRoute && offRouteCount >= 2 {
        offRoute = true
    }
} else {
    offRouteCount = 0
    offRoute = false
}
```
And in `NavigationViewModel`:
```swift
if offFlag && !self.isOffRoute {
    self.isOffRoute = true
    self.onRerouteNeeded?()
}
```
### Deficiencies Identified:
1. **Deadlock on Network/Routing Failure**: If the network request failed, the session called `navSession.setRerouting(false)`. However, `isOffRoute` remained `true`. Because rerouting was only triggered on the `false -> true` edge transition, no subsequent reroute could ever be triggered unless the user first drove back to the old route.
2. **Variable Frame Rate Timing**: 2 GPS frames at 10 Hz represented only 200 ms (triggering on trivial GPS noise), while at 0.5 Hz it represented 4 seconds.
3. **Fixed 15m Threshold**: Treated a 19m accuracy reading with 16m lateral distance identically to a 3m accuracy reading with 30m deviation.
4. **State Flapping**: A single 15m threshold created state oscillation (14m -> 16m -> 14m -> 16m).
5. **No Stationary Drift Filtering**: GPS multipath jitter while parked or at red lights triggered false reroutes.
6. **Concurrent Request Vulnerability**: Stale GPS observations during in-flight network requests caused redundant reroute storms.

---

## 4. OffRouteDetector Architecture

`OffRouteDetector` is implemented as an isolated, pure Swift component with no UI, MapLibre, CoreLocation manager, or network dependencies.

```text
OffRouteObservation (timestamp, lateralDist, horizAccuracy, speed, course, routeBearing)
                                    ↓
                 +--------------------------------------+
                 |          OffRouteDetector            |
                 |                                      |
                 |  State Machine:                      |
                 |    .onRoute                          |
                 |    .suspected (tracking dwell start) |
                 |    .confirmed                        |
                 +--------------------------------------+
                                    ↓
OffRouteDecision (state, becameConfirmed, recovered, reason, lateralDist, activeThreshold)
```

### Pure State Machine States:
- `.onRoute`: Vehicle is within acceptable route tolerance ($< T_{\text{enter}}$).
- `.suspected`: Deviation exceeds dynamic threshold ($d \ge T_{\text{enter}}$), and temporal dwell timer is running.
- `.confirmed`: Deviation has persisted beyond the required temporal dwell window.

---

## 5. Observation Inputs

`OffRouteObservation` encapsulates only validated physical data and route geometry projection:
```swift
public struct OffRouteObservation: Sendable {
    public let timestamp: Date
    public let lateralDistanceMeters: Double
    public let horizontalAccuracyMeters: Double
    public let speedMetersPerSecond: Double
    public let courseDegrees: Double?
    public let routeBearingDegrees: Double?
    public let distanceAlongRouteMeters: Double
}
```
- Inputs derive strictly from accepted physical locations (`filteredLocation`), not snapped coordinates.
- Unreliable or invalid courses (`course < 0`) are passed as `nil`.
- Segment bearing is computed using forward route geometry: `RouteGeometry.bearing(from:to:)`.

---

## 6. Thresholds and Accuracy Handling

The detector computes dynamic entry thresholds on every observation:
```swift
let enterThreshold = max(baseLateralThresholdMeters, obs.horizontalAccuracyMeters * accuracyMultiplier)
```

### Exact Constants:
- **`baseLateralThresholdMeters`**: `15.0` meters
- **`accuracyMultiplier`**: `1.2`
- **`recoveryLateralThresholdMeters`**: `10.0` meters
- **`strongLateralDeviationMultiplier`**: `2.0` (deviation $\ge 2 \times T_{\text{enter}}$, minimum 30.0m)

### Quality-Aware Behavior:
- High accuracy ($\text{acc} = 5\text{m}$): $T_{\text{enter}} = \max(15.0, 5 \times 1.2) = 15.0\text{m}$.
- Medium accuracy ($\text{acc} = 15\text{m}$): $T_{\text{enter}} = \max(15.0, 15 \times 1.2) = 18.0\text{m}$.
- Borderline accuracy ($\text{acc} = 19\text{m}$): $T_{\text{enter}} = \max(15.0, 19 \times 1.2) = 22.8\text{m}$.
- Poor accuracy samples ($> 20\text{m}$) are rejected upstream by the P1 location quality gate.

---

## 7. Time-Based Confirmation

Temporal confirmation replaces frame counting. When lateral distance exceeds $T_{\text{enter}}$, the detector transitions to `.suspected` and records `suspectStartedAt = obs.timestamp`.

Confirmation occurs when:
$$\Delta t = \text{obs.timestamp} - \text{suspectStartedAt} \ge D_{\text{required}}$$

### Required Dwell Durations ($D_{\text{required}}$):
1. **Normal Moving**: `2.5` seconds ($v \ge 1.0\text{m/s}$).
2. **Moving with Course Divergence**: `1.5` seconds ($v \ge 3.0\text{m/s}$ and angular difference $\ge 45^\circ$).
3. **Stationary / Low Speed**: `5.0` seconds ($v < 1.0\text{m/s}$). Prevents false alarms due to GPS drift at intersections.
4. **Strong Physical Deviation**: `1.0` second ($d \ge 2 \times T_{\text{enter}}$). Confirms rapid physical departures while preventing single-spike triggers.

---

## 8. Speed / Course Handling

### Course vs. Heading
- The detector strictly utilizes `CLLocation.course` (vector travel motion), never device compass `CLHeading` (device orientation).
- Compass orientation does not reflect vehicle travel trajectory when the mobile device is docked at an angle.

### Course Evidence Rules:
- **`minSpeedForCourseMetersPerSec`**: `3.0` m/s (~10.8 km/h). Below this speed, course is ignored.
- **`courseDivergenceThresholdDegrees`**: `45.0` degrees.
- Course divergence accelerates confirmation from 2.5s down to 1.5s only when supported by lateral deviation $d \ge T_{\text{enter}}$. Course mismatch alone **never** triggers an off-route condition.

---

## 9. Hysteresis and Recovery

To prevent oscillation around threshold boundaries (e.g. 14m <-> 16m), asymmetric thresholds and recovery persistence are enforced:
- **Entry Threshold**: $T_{\text{enter}} = \max(15.0\text{m}, \text{acc} \times 1.2) \ge 15.0\text{m}$.
- **Recovery Threshold**: $T_{\text{recovery}} = 10.0\text{m}$.
- **Recovery Persistence**: Must remain $\le 10.0\text{m}$ for at least `1.0` second (`recoveryConfirmationSeconds = 1.0`) before transitioning from `.confirmed` or `.suspected` back to `.onRoute`.

---

## 10. Reroute Manager State Machine

`RerouteManager` centralizes all rerouting policies, separating route computation from session tracking.

```text
[Observation: .confirmed]
           ↓
   Is Reroute In Flight?  --- YES ---> Discard Observation (No Storm)
           ↓ NO
  Is In Backoff Cooldown? --- YES ---> Discard Observation (Wait for cooldown)
           ↓ NO
  Is In Post-Success Stabilization? - YES -> Discard Observation
           ↓ NO
  Start Reroute Request
    Capture: sessionGeneration, activeRouteGeneration, rerouteRequestGeneration
    Dispatch: calculateRoute(from: filteredLocation, to: frozenDestination)
```

---

## 11. Retry / Backoff Policy

When a reroute fails:
1. `isRerouting` is immediately reset to `false`.
2. `failureCount` increments by 1.
3. `nextEligibleRerouteAt` is scheduled using bounded backoff:
   $$\text{delay} = \text{backoffDelays}[\min(\text{failureCount} - 1, \text{maxIndex})]$$
4. **`backoffDelays`**: `[2.0, 4.0, 8.0, 15.0]` seconds.
5. **Maximum Capped Backoff**: `15.0` seconds.

### Observation-Driven Retries:
- No background `Task.sleep` timers or fragile cron jobs are scheduled.
- Each incoming GPS observation checks:
  `currentTime >= nextEligibleRerouteAt`
- When the condition is met and the user remains confirmed off-route, a new reroute attempt launches automatically using the latest `filteredLocation` as origin.
- The user does **not** need to return to the old route to retry.

---

## 12. Reroute Request Lifecycle

1. **Request Trigger**: Triggered by either `.offRoute` (observation-driven) or `.transportModeChanged` (user-initiated).
2. **Fresh Physical Origin**: Origin is strictly extracted from `session.filteredLocation?.coordinate`.
3. **Frozen Destination**: Destination is strictly extracted from `session.navigationDestination?.coordinate`. Route endpoints (`route.coordinates.last`) are never used.
4. **Single In-Flight Guarantee**: Any observation arriving while `isRerouting == true` is rejected.
5. **Recovery Cancellation**: If the vehicle returns to route while an off-route request is in flight, `cancelInFlightReroute()` cancels the network task and discards pending results.

---

## 13. Session / Route Generation Safety

To prevent concurrency races (such as Route C overwriting a newer Route D), five post-await guards are verified before committing a new route:
```swift
guard !Task.isCancelled else { return }
guard let s = self.navSession, s.state == .navigating else { return }
guard s.sessionGeneration == capturedSessionGen else { return }
guard s.activeRouteGeneration == capturedRouteGen else { return }
guard self.rerouteRequestGeneration == capturedRerouteGen else { return }
```
- **Session Mismatch**: If `stopNavigation()` or a new session started, response is discarded.
- **Route Revision Race**: If active route was changed by another source while calculating, response is discarded.
- **Superseded Request**: If another reroute was started, earlier responses are discarded.

---

## 14. Failure Behavior

Upon network, Valhalla, or timeout failure:
- Active route remains active and visible on map.
- Active route generation is preserved.
- Navigation state remains `.navigating`.
- `navigationDestination` remains intact.
- `isRerouting` returns to `false`.
- BLE navigation packets continue transmitting progress along the existing active route.
- Next retry eligibility is scheduled via backoff delay.

---

## 15. Success Behavior

Upon successful reroute response:
- `navSession.replaceActiveRoute(newRoute)` is called atomically:
  - `activeRouteGeneration` increments by 1.
  - `sessionGeneration` remains unchanged.
  - `currentManeuverStepIndex` resets to 0.
  - `currentPolylineSegmentIndex` resets to 0.
  - `offRouteDetector.reset()` resets all suspicion and confirmation timers.
  - `isOffRoute` resets to `false`.
  - `remainingPolyline` updates to new route geometry.
- `RerouteManager` resets:
  - `failureCount = 0`
  - `nextEligibleRerouteAt = nil`
  - `lastCommittedAt = currentTime` (starts 2.0s post-success stabilization)
  - `isRerouting = false`

---

## 16. Transport Mode Rerouting

- User-initiated transport mode change invokes:
  `rerouteManager.requestTransportModeReroute(costing: costing, origin: origin)`
- **Supersession**: Cancels any in-flight off-route reroute request.
- **Backoff Bypass**: Clears `nextEligibleRerouteAt`, immediately executing without waiting for off-route backoff cooldowns.
- **Preserved Destination**: Routes to original `navigationDestination`.

---

## 17. Tests

Native unit testing suite in `mobile_app/ios_native/Tests/ESP32NavAppTests/`:

### `OffRouteDetectorTests.swift` (10 tests, 10 passed):
1. `testNormalOnRouteDrivingKeepsOnRoute`: Verifies normal driving (<15m) stays `.onRoute`.
2. `testBriefGPSSpikeDoesNotTriggerOffRoute`: Single 35m spike followed by 5m recovers without confirming.
3. `testSustainedRealDeviationConfirmsOffRoute`: Sustained 25m deviation across 3.0s transitions `.onRoute -> .suspected -> .confirmed`.
4. `testCourseDivergenceAcceleratesConfirmation`: 50° course mismatch at 5 m/s confirms in 1.6s (<2.5s moving threshold).
5. `testStationaryGPSDriftRequiresLongerDwell`: Jitter up to 20m at 0.2 m/s does not confirm within 3.0s (requires 5.0s).
6. `testDynamicAccuracyThresholdScaling`: GPS accuracy = 18m raises threshold to 21.6m; 17m deviation does not trigger suspicion.
7. `testHysteresisPreventsThresholdFlapping`: Alternating 14m/16m readings around 15m base threshold do not cause state flapping.
8. `testRecoveryRequiresPassingLowerThreshold`: Sustained return (<10m) for >1.0s recovers state to `.onRoute`.
9. `testDetectorResetClearsAllSuspicionAndState`: Calling `reset()` clears suspect timestamps and returns state to `.onRoute`.
10. `testStrongDeviationFasterConfirmation`: 40m deviation (>2x threshold) at 6 m/s confirms after 1.1s.

### `RerouteManagerTests.swift` (10 tests, 10 passed):
1. `testSingleInFlightRequestGuarantee`: Multiple rapid off-route observations while request is in flight result in exactly 1 call.
2. `testBoundedBackoffRetryAfterFailure`: Failed attempt schedules retry in 2.0s; observation at t=1.0s is rejected; observation at t=2.1s triggers attempt 2 without requiring `.onRoute` transition.
3. `testRetryUsesFreshPhysicalOrigin`: Attempt 1 uses origin A (10.001, 106.001); attempt 2 after movement uses origin B (10.003, 106.004).
4. `testFrozenDestinationPreservedAcrossRetries`: Reroute attempts preserve exact destination coordinate.
5. `testStopNavigationCancelsRerouteAndDiscardsResponse`: Stopping navigation cancels active task and prevents route resurrection.
6. `testStaleResponseFromObsoleteSessionDiscarded`: Starting Session B while Session A reroute is in flight discards late Session A response.
7. `testActiveRouteRevisionRaceDiscardsSupersededReroute`: Route C committed during Route B computation causes Route B to be safely discarded.
8. `testSuccessfulAtomicRouteBReplacement`: Route B replaces Route A atomically; `activeRouteGeneration` increments; destination and session preserved.
9. `testRecoveryCancelsInFlightOffRouteRequest`: Vehicle returning to route while off-route request is in flight cancels request.
10. `testTransportModeChangeSupersedesAndIgnoresBackoff`: Transport mode change cancels off-route request and bypasses failure backoff.

---

## 18. GitHub Actions Evidence

- **Baseline Commit**: `e00f13bdb71162aa7a10ab1258f899c1c9c130cc`
- **P2 Implementation & Test Commit**: `4718111`
- **GitHub Actions Run ID**: `35522625628`

### Test & Build Execution Matrix:
| Job / Suite | Status | Execution Details |
| :--- | :--- | :--- |
| `RouteGeometryTests` | **PASS (12/12)** | CI TESTED — 0 failures |
| `OffRouteDetectorTests` | **PASS (10/10)** | CI TESTED — 0 failures |
| `RerouteManagerTests` | **PASS (10/10)** | CI TESTED — 0 failures |
| **Total Unit Tests** | **PASS (32/32)** | **0 failures** |
| `Build Native iOS App` (Release) | **SUCCESS** | CI TESTED |
| `Package Native IPA` | **SUCCESS** | CI TESTED (`ESP32NavApp.ipa`) |
| `Compile Flutter iOS IPA` | **SUCCESS** | CI TESTED (`Runner.ipa`) |

---

## 19. Known Remaining Problems

1. **Synthetic Turn-Around Guidance**: When confirmed off-route, the navigation engine currently requests a point-to-point route from `filteredLocation` to destination. It does not synthesize explicit "Make a U-turn when possible" maneuvers prior to new route computation.
2. **Tunnel / Dead Reckoning**: During complete GPS loss (>5s without updates), the detector pauses state transitions rather than extrapolating along last known velocity vector.

---

## 20. P3 Readiness

With Phase P2 complete, the navigation session maintains a robust off-route detector and reroute coordinator:
- Unit test suite expanded to 32 deterministic tests (12 geometry + 10 detector + 10 reroute).
- All P0 and P1 invariants (session generation, route generation, frozen destination, 16-byte BLE packet protocol) remain intact.
- The codebase is clean, verified in CI, and fully ready for Phase P3 (Search improvements).
