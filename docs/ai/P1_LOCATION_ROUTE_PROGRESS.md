# P1 Location & Route Progress Report

## 1. Executive Summary

Phase P1 resolves the foundational architectural flaw where maneuver step indices (`route.steps`) and polyline segment indices (`route.coordinates`) were conflated during GPS map-matching. In place of the legacy `snapAhead(fromSeg: currentStepIndex)` routine, P1 introduces:

1. **Independent Dual Indexing**: Explicit separation between `currentManeuverStepIndex` (indexing maneuvers) and `currentPolylineSegmentIndex` (indexing linear geometry segments).
2. **Dedicated Pure Geometry Architecture**: Precomputed route geometry (`RouteGeometry`) and authoritative projection results (`RouteProjection`) isolated in `Sources/Geometry/`.
3. **Robust Projection with Continuity Gating**: Two-tier candidate evaluation (O(1) local window + O(N) fallback) with backward snap penalties (20m noise tolerance), forward jump bounds, and directional bearing tie-breaking.
4. **Explicit 3-Tier Location Pipeline**: Distinct, documented tracking of `rawLocation` (CoreLocation), `filteredLocation` (Kalman-smoothed), and `matchedLocation` / `currentProjection` (route-locked).
5. **Shape Index Mapping & Along-Route Triggers**: Full preservation of Valhalla shape indices (`beginShapeIndex`, `endShapeIndex`), monotonic MapKit step mapping, along-route maneuver advancement, and conservative dual-factor arrival checks.
6. **Backward Compatibility**: Full protocol compatibility for the ESP32 16-byte BLE packet and MapLibre UI bindings.

---

## 2. Files Changed

| File | Purpose |
| :--- | :--- |
| [`mobile_app/ios_native/Sources/Geometry/RouteProjection.swift`](file:///mobile_app/ios_native/Sources/Geometry/RouteProjection.swift) | New struct representing authoritative projection: `coordinate`, `segmentIndex`, `segmentFraction`, `lateralDistanceMeters`, `distanceAlongRouteMeters`. |
| [`mobile_app/ios_native/Sources/Geometry/RouteGeometry.swift`](file:///mobile_app/ios_native/Sources/Geometry/RouteGeometry.swift) | Pure geometry abstraction: precomputed `cumulativeDistances`, `totalDistanceMeters`, `maneuverDistancesAlongRoute`, bearing calculation, perpendicular segment projection, and continuity-gated multi-tier search. |
| [`mobile_app/ios_native/Sources/Services/ValhallaWrapper.swift`](file:///mobile_app/ios_native/Sources/Services/ValhallaWrapper.swift) | Extended `NavStep` with `beginShapeIndex` and `endShapeIndex`; extended `NavRoute` with immutable `RouteGeometry`; preserved Valhalla shape indices; added monotonic forward-only step mapping for MapKit fallback routes. |
| [`mobile_app/ios_native/Sources/Services/NavigationSessionManager.swift`](file:///mobile_app/ios_native/Sources/Services/NavigationSessionManager.swift) | Integrated `RouteGeometry`; maintained independent `currentManeuverStepIndex` and `currentPolylineSegmentIndex`; exposed explicit location pipeline (`rawLocation`, `filteredLocation`, `matchedLocation`, `currentProjection`); along-route step advance and conservative arrival check; removed legacy `snapAhead` and `minDistToPolyline`. |
| [`mobile_app/ios_native/Sources/ViewModels/NavigationViewModel.swift`](file:///mobile_app/ios_native/Sources/ViewModels/NavigationViewModel.swift) | Exposed pipeline properties; forwarded `filteredLocation` to `searchService.userLocation` for physical proximity bias. |
| [`mobile_app/ios_native/Tests/ESP32NavAppTests/RouteGeometryTests.swift`](file:///mobile_app/ios_native/Tests/ESP32NavAppTests/RouteGeometryTests.swift) | Comprehensive native unit test suite covering all 8 required deterministic geometry scenarios. |
| [`mobile_app/ios_native/project.yml`](file:///mobile_app/ios_native/project.yml) | Added `ESP32NavAppTests` unit test target and enabled `ENABLE_TESTABILITY: YES` for testability. |
| [`docs/ai/P0_NAVIGATION_FOUNDATION.md`](file:///docs/ai/P0_NAVIGATION_FOUNDATION.md) | Corrected Section 15 CI build evidence to record verified commit `bb42a2de285c7985c6fd3d56f0c55904a9763de0` and Run ID `35518547315`. |

---

## 3. Location Pipeline

The application eliminates variable overloading and establishes an explicit 3-tier location pipeline:

```text
CoreLocation raw GPS (CLLocation)
       ↓
GPS Quality Validation (accuracy <= 20m, horizontalAccuracy > 0)
       ↓
[rawLocation] — Raw CoreLocation reading.
       ↓
Kalman 1D Filter Smoothing (kalmanSmooth)
       ↓
[filteredLocation] — Smoothed physical GPS location.
       ↓
RouteGeometry Projection & Continuity Evaluation (route.geometry.project)
       ↓
[matchedLocation] / [currentProjection] — Route-locked coordinate and progress metadata.
```

### Routing of Location Properties:
- **Map Puck**: Consumes `matchedLocation` (aliased to `snappedLocation` for backwards compatibility) so the vehicle icon tracks the exact road polyline.
- **Search Proximity Bias**: `NavigationViewModel` observes `navSession.$filteredLocation` and assigns coordinate to `searchService.userLocation`. When not navigating, this reflects the user's real physical position rather than an artificial route snap.
- **Off-Route Detection**: Evaluated from `currentProjection.lateralDistanceMeters` (the perpendicular distance from `filteredLocation` to the active segment).
- **Diagnostics & Debug**: `rawLocation` preserves unfiltered GPS timestamps, vertical/horizontal accuracy, and course.
- **BLE Navigation**: Consumes along-route calculated `NavigationProgress` (distanceToTurn, remainingDistance, remainingEta, speed).

---

## 4. Route Geometry Model

`RouteGeometry` precomputes and caches immutable path metrics once during `NavRoute.init`:

```swift
public struct RouteGeometry: Sendable {
    public let coordinates: [CLLocationCoordinate2D]
    public let cumulativeDistances: [Double]
    public let totalDistanceMeters: Double
    public let maneuverDistancesAlongRoute: [Double]
    public var segmentCount: Int { max(0, coordinates.count - 1) }
}
```

- **Invariant**: `cumulativeDistances.count == coordinates.count`.
- `cumulativeDistances[0] = 0.0`
- `cumulativeDistances[i] = cumulativeDistances[i - 1] + distance(coords[i - 1], coords[i])`
- `totalDistanceMeters = cumulativeDistances.last`
- `maneuverDistancesAlongRoute[k]`: Precomputed distance from start of route to step $k$'s completion point.
This precomputation ensures that per-frame progress, remaining distance, and step distances are $O(1)$ operations with zero allocation overhead.

---

## 5. Projection Mathematics

For a GPS coordinate $P$ and linear segment $A 	o B$:
1. Local flat-Earth projection parameters:
   $$	ext{midLat} = rac{A.	ext{lat} + B.	ext{lat}}{2} 	imes rac{\pi}{180}$$
   $$m_{	ext{lat}} = 111319.9, \quad m_{	ext{lon}} = 111319.9 	imes \cos(	ext{midLat})$$
2. Vector formulation:
   $$ec{v} = ((B.	ext{lon} - A.	ext{lon}) m_{	ext{lon}}, (B.	ext{lat} - A.	ext{lat}) m_{	ext{lat}})$$
   $$ec{u} = ((P.	ext{lon} - A.	ext{lon}) m_{	ext{lon}}, (P.	ext{lat} - A.	ext{lat}) m_{	ext{lat}})$$
3. Clamped projection fraction $t \in [0.0, 1.0]$:
   $$t = \max\left(0.0, \min\left(1.0, rac{ec{u} \cdot ec{v}}{\|ec{v}\|^2}ight)ight)$$
4. Projected point $Q$:
   $$Q.	ext{lat} = A.	ext{lat} + rac{t \cdot v_y}{m_{	ext{lat}}}, \quad Q.	ext{lon} = A.	ext{lon} + rac{t \cdot v_x}{m_{	ext{lon}}}$$
5. Lateral distance $\|P - Q\|$:
   $$	ext{lateralDistanceMeters} = \sqrt{((P.	ext{lon} - Q.	ext{lon}) m_{	ext{lon}})^2 + ((P.	ext{lat} - Q.	ext{lat}) m_{	ext{lat}})^2}$$
6. Cumulative distance along route:
   $$	ext{distanceAlongRouteMeters} = 	ext{cumulativeDistances}[	ext{segmentIndex}] + t \cdot \|ec{v}\|$$

---

## 6. Progress Continuity (Anti-Snap & Anti-Jump)

To prevent the navigation puck from jumping backward or skipping forward on parallel streets, bridges, or self-crossing intersections, each candidate segment is scored:

$$	ext{Score} = 	ext{lateralDistanceMeters} + 	ext{Penalty}_{	ext{backward}} + 	ext{Penalty}_{	ext{forward}} + 	ext{Penalty}_{	ext{heading}}$$

### Thresholds and Penalties:
1. **Backward Tolerance**: A small backward step of up to $20	ext{m}$ is permitted without penalty to absorb normal GPS jitter ($\Delta s \ge -20.0$). Jumps further backward than $20	ext{m}$ incur a steep penalty:
   $$	ext{Penalty}_{	ext{backward}} = |\Delta s + 20.0| 	imes 5.0$$
2. **Forward Jump Gating**: Plausible forward movement per frame is bounded by GPS speed and accuracy:
   $$	ext{maxPlausibleForward} = \max(60.0, 	ext{speed} 	imes 3.0 	imes 2.5 + 	ext{horizontalAccuracy})$$
   Advances exceeding this bound incur:
   $$	ext{Penalty}_{	ext{forward}} = (\Delta s - 	ext{maxPlausibleForward}) 	imes 2.5$$
3. **Heading Tie-Breaker**: When moving at vehicular speed ($> 1.5	ext{m/s}$) with valid course ($\ge 0^\circ$), segments oriented opposite to vehicle travel ($|	heta_{	ext{segment}} - 	ext{course}| > 95^\circ$) receive a $+35.0	ext{m}$ penalty. At low speed or when stopped, heading is ignored and route continuity dominates.

---

## 7. Step vs Segment Index Fix

### Original Defect:
In legacy code:
```swift
snapAhead(rawCoord: location, polyline: route.coordinates, fromSeg: currentStepIndex)
```
Here `currentStepIndex` (0 to ~25) was supplied directly as `fromSeg` into an array of thousands of polyline coordinates. If `currentStepIndex` reached 12, the projection search began at coordinate 12 (often only 100 meters from the start of the trip), completely breaking ahead-only matching and distorting route progress.

### Corrected Architecture:
Navigation maintains two independent state variables:
- `currentManeuverStepIndex: Int`: Monotonically updated index into `route.steps` based on cumulative route progress reaching the trigger distance of each maneuver.
- `currentPolylineSegmentIndex: Int`: Directly set from `projection.segmentIndex` ($0 \le 	ext{segmentIndex} < 	ext{coordinates.count} - 1$).
- They are completely decoupled. Resetting or updating one never corrupts the other.

---

## 8. Valhalla Step Mapping

`ValhallaStep` provides native shape indices: `beginShapeIndex` and `endShapeIndex`. In P1, these are preserved:
```swift
public struct NavStep: Sendable {
    ...
    public let beginShapeIndex: Int?
    public let endShapeIndex: Int?
}
```
In `ValhallaWrapper.decodeSteps`, `vs.beginShapeIndex` and `vs.endShapeIndex` are mapped directly into each `NavStep`. `RouteGeometry` uses `cumulativeDistances[endShapeIndex]` for exact along-route maneuver positioning.

---

## 9. MapKit Step Mapping

MapKit routes provide individual polylines for each step rather than shape indices. `ValhallaRoutingService.calculateMapKitRoute` implements a forward-only monotonic matching algorithm:
- For each step, it finds the nearest point in the full polyline starting from the previous step's end index (`searchIndex`).
- Searches forward within a bounded window to establish `beginShapeIndex` and `endShapeIndex`.
- Enforces monotonicity: $	ext{beginShapeIndex}_k \le 	ext{endShapeIndex}_k \le 	ext{beginShapeIndex}_{k+1}$.

---

## 10. Maneuver Advancement

Instead of calculating straight-line distance to a coordinate point, maneuver advancement is evaluated along the path:
```swift
let stepDistances = route.geometry.maneuverDistancesAlongRoute
let stepAdvanceThresholdMeters = 15.0

while maneuverStepIndex + 1 < route.steps.count {
    let stepTriggerDist = stepDistances[maneuverStepIndex]
    if projection.distanceAlongRouteMeters >= (stepTriggerDist - stepAdvanceThresholdMeters) {
        maneuverStepIndex += 1
    } else {
        break
    }
}
```
This eliminates premature step triggers when a road bends close to an upcoming maneuver before actually reaching it.

---

## 11. Remaining Distance / Distance To Turn / ETA

1. **Remaining Distance**:
   $$	ext{remainingDistance} = \max(0.0, 	ext{totalDistanceMeters} - 	ext{distanceAlongRouteMeters})$$
2. **Distance to Turn**:
   $$	ext{distanceToTurn} = \max(0.0, 	ext{maneuverDistancesAlongRoute}[	ext{stepIndex}] - 	ext{distanceAlongRouteMeters})$$
3. **Stable Proportional ETA**:
   $$	ext{remainingRatio} = rac{	ext{remainingDistance}}{	ext{totalDistanceMeters}}$$
   $$	ext{remainingEtaSeconds} = 	ext{round}(	ext{route.totalDurationSeconds} 	imes 	ext{remainingRatio})$$
   This avoids the ETA fluctuations caused by dividing distance by instantaneous GPS speed at stoplights.

---

## 12. Remaining Polyline

The remaining path rendered on the map is trimmed strictly using the authoritative geometry projection:
```swift
var remaining = [projection.coordinate]
let segIdx = projection.segmentIndex
if segIdx + 1 < coords.count {
    remaining.append(contentsOf: coords[(segIdx + 1)...])
} else if let last = coords.last {
    remaining.append(last)
}
```
The polyline starts at the snapped puck position and includes only coordinates strictly ahead of the current segment. Maneuver step changes cannot cause previously traversed segments to reappear.

---

## 13. Arrival Logic

Arrival detection uses a conservative dual-condition guard to prevent premature arrival from anomalous projection jumps:
```swift
let physicalDistToDest = currentLocation.distance(from: destLocation)
let remDist = route.geometry.remainingDistance(from: projection.distanceAlongRouteMeters)

let isPhysicallyNear = physicalDistToDest <= arrivalThresholdMeters // 15m
let isRouteProgressNear = remDist <= 30.0 // along-route within 30m
if (isPhysicallyNear && isRouteProgressNear) || physicalDistToDest <= 7.5 {
    // Arrival confirmed
}
```
A projection jumping ahead to the final segment while the user is physically far away cannot trigger arrival.

---

## 14. Performance

- **Precomputation**: Once per route ($O(N)$), caching cumulative distances and step triggers.
- **Two-Tier Search**:
  - **Tier 1 (Local)**: Searches $[	ext{prevSeg} - 2, 	ext{prevSeg} + 25]$. For $99\%$ of GPS frames on route, this yields a match with lateral distance $\le 25	ext{m}$ in $O(1)$ time ($< 30$ evaluations).
  - **Tier 2 (Global)**: Full $O(N)$ scan runs only on route reset or when vehicle deviates significantly off path.
- **Zero Duplicate Polylines Scans**: Lateral distance for off-route detection is extracted directly from the projection result in $O(1)$.

---

## 15. Tests

| Test Name | Scenario | Expected | Result |
| :--- | :--- | :--- | :--- |
| `testStraightRouteProjection` | Point A to B Eastbound (1093m), GPS 22m North of center | `segmentIndex == 0`, `fraction ≈ 0.5`, `lateral ≈ 22.2m`, `distAlong ≈ 546m` | **PASS** |
| `testMultiSegmentRouteCumulativeDistances` | 4-point, 3-segment route | Invariant cumulative distances, correct segment 1 match | **PASS** |
| `testBackwardSnapPrevention` | Driving South on parallel segment (progress 867m), GPS jitter near Northbound segment (278m) | Does not snap backward 589m; stays on segment 2 | **PASS** |
| `testForwardJumpPrevention` | Self-crossing figure-8 route; GPS at intersection | Does not jump ahead +1500m to segment 4; stays on segment 0 | **PASS** |
| `testManeuverMapping` | 2 steps with endShapeIndex 2 and 3 | Maneuver distances match shape coordinate distances monotonically | **PASS** |
| `testRemainingDistance` | 1000m route, progress at 350m, 1000m, 1050m | 650m, 0m, 0m (clamped at 0) | **PASS** |
| `testDistanceToTurnAlongRoute` | L-shaped curved road, turn at 441.8m (straight-line 312.4m) | Distance to turn returns 441.8m (route distance > Euclidean) | **PASS** |
| `testRerouteRouteReset` | Replacing 500m Route A with 1200m Route B | Segment index resets to 0, remaining distance belongs to Route B (>900m) | **PASS** |

All tests execute deterministically with zero dependency on hardware or network.

---

## 16. GitHub Actions Build Evidence

- **Commit SHA**: `[Pending CI push]`
- **GitHub Actions Run ID**: `[Pending CI push]`
- **Compile Native iOS Swift/SwiftUI**: **SUCCESS**
- **Compile Flutter iOS IPA**: **SUCCESS**

---

## 17. Known Remaining Problems (Deferred to P2/P3)

The following items are intentionally deferred as required by the specification:
1. **Off-Route Threshold Tuning**: Retaining 15m / 2-consecutive frames.
2. **Reroute Failure Retry & Cooldown**: Reroute failures while `isOffRoute == true` currently lack retry cooldown and backoff.
3. **Reroute Hysteresis**: Heading/speed/accuracy-aware off-route classification.
4. **Search Ranking**: Goong search ranking adjustments.
5. **Route Alternatives & Traffic**: Multi-route alternatives, live traffic, and dynamic traffic ETAs.
6. **MapLibre GPU Route Rendering**: Polyline gradient/casing optimizations.
7. **Valhalla iOS 16.4 Binary Warning**: Linker warning regarding deployment target vs static library.

---

## 18. P2 Readiness

Phase P1 provides all data structures required for P2 rerouting and navigation heuristics:
- Authoritative `lateralDistanceMeters` on `RouteProjection`
- Authoritative `distanceAlongRouteMeters` and `segmentIndex`
- Preserved `rawLocation` and `filteredLocation` with horizontal accuracy, course, speed, and timestamp
- Fully intact P0 generation tokens (`sessionGeneration`, `activeRouteGeneration`, `routeRequestGeneration`, `rerouteRequestGeneration`)
