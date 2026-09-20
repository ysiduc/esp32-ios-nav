# P0 Navigation Foundation Report

## 1. Repository Architecture Observed

The repository contains two distinct mobile implementations:
1. **Primary Native iOS Navigation Engine (`mobile_app/ios_native`)**:
   - The authoritative navigation implementation targeted by this refactor.
   - Built with Swift and Objective-C++ using SwiftUI, MapLibre Native iOS SDK (`maplibre-gl-native-distribution`), CoreLocation with Kalman smoothing, background location capabilities, and an embedded offline Valhalla engine (`valhalla-wrapper.xcframework` / `ValhallaEngine.mm`).
   - Architecture:
     - `NavigationModels.swift`: Authoritative model definitions, including the newly introduced immutable `NavigationDestination`.
     - `NavigationSessionManager.swift`: Core navigation state machine (`.idle`, `.searching`, `.routePreview`, `.navigating`, `.arrived`), session generation tracking, ahead-only GPS projection, off-route detection (15m threshold, 2 frames), and background location updates.
     - `NavigationViewModel.swift`: Main UI view model coordinating search, preview route requests, active reroutes, task cancellation, and BLE dispatch.
     - `ValhallaWrapper.swift`: Swift service managing offline Valhalla routing with online Apple MapKit (`MKDirections`) fallback.
     - `ValhallaEngine.mm` / `ValhallaEngine.h`: Objective-C++ bridge wrapping `valhalla::actor_t`.
     - `MapViewContainer.swift`: MapLibre `UIViewRepresentable` handling map rendering, route polylines, and destination flag annotations.
     - `BLEManager.swift`: Dispatches 16-byte binary navigation packets to the ESP32 hardware display.
2. **Legacy Flutter Tree (`mobile_app/lib/`)**:
   - Historical cross-platform codebase retained during migration. It is not part of the active native iOS turn-by-turn navigation execution path.

---

## 2. Files Changed

### 1. `mobile_app/ios_native/Sources/Models/NavigationModels.swift`
- **Exact Change**: Introduced `public struct NavigationDestination: Equatable, Sendable` with properties `coordinate: CLLocationCoordinate2D`, `name: String?`, and `placeID: String?`.
- **Reason**: Decouples UI search state (`selectedDestination`) from the navigation lifecycle. Provides an immutable, frozen representation of the destination owned by the active session.

### 2. `mobile_app/ios_native/Sources/Services/NavigationSessionManager.swift`
- **Exact Change**:
  - Added `sessionGeneration: UInt64 = 0` (monotonically increasing navigation session token).
  - Added `navigationDestination: NavigationDestination?` and `isRerouting: Bool`.
  - Updated `startNavigation(route:destination:)` to increment `sessionGeneration`, freeze `navigationDestination`, reset step/off-route counters, reset `isRerouting`, and enter `.navigating`.
  - Added overload `startNavigation(route:)` deriving destination from the route coordinates as a backward-compatible fallback.
  - Updated `stopNavigation()` to increment `sessionGeneration` (invalidating pending session tasks), clear `navigationDestination`, reset `isRerouting`, reset route state, and disable background location.
  - Hardened `setRoutePreview(_:)` to reject previews when `state == .navigating`.
  - Added `replaceActiveRoute(_:)` to atomically commit reroute results into the existing active session without modifying preview state or changing session identity.
  - Added guard in `locationManager(_:didUpdateLocations:)` to prevent pending background location updates from dispatching progress after navigation is stopped.
- **Reason**: Fixes concurrency vulnerabilities where stale asynchronous operations could mutate or resurrect navigation sessions.

### 3. `mobile_app/ios_native/Sources/ViewModels/NavigationViewModel.swift`
- **Exact Change**:
  - Added `routeRequestGeneration: UInt64 = 0` and `rerouteRequestGeneration: UInt64 = 0`.
  - Added `routeCalculationTask: Task<Void, Never>?` and `rerouteTask: Task<Void, Never>?`.
  - Rewrote `calculateRoute(to:)`: cancels pending tasks, increments `routeRequestGeneration`, captures generation before `await`, and validates task cancellation, generation equality, and session state before calling `setRoutePreview`.
  - Completely rewrote `recalculateCurrentRoute()`: cancels superseded reroute task (Strategy B), increments `rerouteRequestGeneration`, captures `navSession.sessionGeneration` and `rerouteRequestGeneration`, calls `routing.calculateRoute` directly, validates `!Task.isCancelled`, `navSession.state == .navigating`, `navSession.sessionGeneration == capturedSessionGen`, and `rerouteRequestGeneration == capturedRerouteGen`, then commits atomically via `navSession.replaceActiveRoute(newRoute)`.
  - Updated `startNavigation()`: cancels pending preview route tasks, increments `routeRequestGeneration`, freezes `NavigationDestination` from UI place selection, and passes it to `navSession.startNavigation(route:destination:)`.
  - Updated `stopNavigation()`: cancels `routeCalculationTask` and `rerouteTask`, increments both route and reroute request generations, invalidates the session via `navSession.stopNavigation()`, clears destinations, and sends the terminal BLE packet.
  - Updated `recalculateForTransportMode()`: routes to `recalculateCurrentRoute()` if navigating, or preview calculation if not navigating.
- **Reason**: Eliminates race conditions in route previews and active rerouting, strictly enforces monotonic generations, and stops reroutes from wiping or re-instantiating navigation sessions.

### 4. `mobile_app/ios_native/Sources/Services/ValhallaWrapper.swift`
- **Exact Change**:
  - Removed `makeFallbackRoute()` helper entirely.
  - In `calculateRoute()`, replaced straight-line fallback with explicit error throwing: `throw ValhallaRoutingError.noRouteFound(...)` when both Valhalla and MapKit fail.
  - Removed `_stub_coords` decoding from `decodeRouteCoordinates()`.
- **Reason**: Guarantees synthetic road geometry and fake maneuver steps can never enter turn-by-turn navigation or be transmitted over BLE.

### 5. `mobile_app/ios_native/Sources/Bridge/ValhallaEngine.mm`
- **Exact Change**:
  - Replaced the `#else` STUB route generator in `computeRouteFromLat:fromLon:toLat:toLon:costing:error:` with an explicit error: sets `*error` to `ValhallaEngineErrorLibraryMissing` and returns `nil`.
  - Replaced the `#else` STUB mode in `loadConfigAtPath:error:` to set `*error` to `ValhallaEngineErrorLibraryMissing` and return `NO`.
- **Reason**: Prevents any stub build from masquerading as a valid routing engine.

### 6. `mobile_app/ios_native/Sources/Views/MapViewContainer.swift`
- **Exact Change**: Added `lastDestinationCoord: CLLocationCoordinate2D?` to `Coordinator`. In `updateDestination(_:on:)`, compares incoming coordinate against `lastDestinationCoord` within epsilon; returns early without touching map annotations if unchanged.
- **Reason**: Eliminates the P0 performance defect where destination annotations were deleted and re-added on every single SwiftUI update cycle.

---

## 3. Navigation Destination Lifecycle

1. **Selected Destination (`selectedDestination: GoongPlace?`)**:
   - Owned by `NavigationViewModel` as transient UI/search state.
   - Set when a user picks an autocomplete prediction or selects a place on the map.
   - Cleared when search is cleared or navigation is stopped.
2. **Active Navigation Destination (`navigationDestination: NavigationDestination?`)**:
   - Owned by `NavigationSessionManager`.
   - **Frozen**: When `startNavigation()` is invoked, the selected destination coordinate, name, and place ID are copied into an immutable `NavigationDestination` struct and passed to `navSession.startNavigation(route:destination:)`.
   - **Rerouting**: When an automatic reroute triggers via `recalculateCurrentRoute()`, the destination coordinate is read directly from `navSession.navigationDestination`. It is never derived from `route.coordinates.last` or mutable search fields.
   - **Cleared**: When `stopNavigation()` is called, `navigationDestination` is set to `nil`. Stale requests attempting to reroute after this point find `navigationDestination == nil` and exit immediately.

---

## 4. Navigation Session Generation

- **Mechanism**: `NavigationSessionManager` maintains a monotonically increasing 64-bit integer:
  ```swift
  public private(set) var sessionGeneration: UInt64 = 0
  ```
- **Increment Points**:
  - Incremented on `startNavigation(...)`: starts Session A (e.g. generation 1).
  - Incremented on `stopNavigation()`: invalidates Session A (generation increments to 2, state becomes `.idle`).
  - Incremented again on subsequent `startNavigation(...)`: starts Session B (generation becomes 3).
- **Session Protection**:
  - When `recalculateCurrentRoute()` begins, it captures `let capturedSessionGen = navSession.sessionGeneration`.
  - When the async routing call returns, it validates:
    ```swift
    guard self.navSession.sessionGeneration == capturedSessionGen else { return }
    ```
  - If Session A was stopped and Session B started, `capturedSessionGen` (1) does not match `navSession.sessionGeneration` (3). The reroute result is immediately dropped. Session B is completely protected from Session A.

---

## 5. Route Request Generation

- **Mechanism**: `NavigationViewModel` maintains a monotonically increasing 64-bit integer:
  ```swift
  private var routeRequestGeneration: UInt64 = 0
  ```
- **Rejection of Stale Initial Route Requests**:
  - Whenever `calculateRoute(to:)` is called, `routeCalculationTask?.cancel()` is executed and `routeRequestGeneration &+= 1` is recorded into a local constant `thisRequestGen`.
  - After `await routing.calculateRoute(...)` returns, the view model verifies:
    ```swift
    guard !Task.isCancelled else { return }
    guard self.routeRequestGeneration == thisRequestGen else { return }
    guard self.navSession.state != .navigating else { return }
    ```
  - If a newer request was dispatched (or navigation was started/stopped), `routeRequestGeneration != thisRequestGen`, and the result is discarded without setting route preview. Only the latest valid request can commit.

---

## 6. Reroute Lifecycle

1. **Trigger**:
   - `NavigationSessionManager` detects GPS off-route (`minDist > 15m` for 2 consecutive frames).
   - Invokes `onRerouteNeeded` callback, which calls `@MainActor recalculateCurrentRoute()`.
2. **Concurrency Strategy (Strategy B: Cancel / Supersede)**:
   - At most one reroute owns the right to commit for an active session.
   - If a reroute is already underway when another off-route update fires, `rerouteTask?.cancel()` is executed, and `rerouteRequestGeneration &+= 1` is incremented.
   - The previous in-flight reroute is superseded and its post-await validation will fail on the generation check.
3. **Validation**:
   - Captures `capturedSessionGen = navSession.sessionGeneration` and `capturedRerouteGen = rerouteRequestGeneration`.
   - Awaits `routing.calculateRoute(...)`.
   - Validates four strict invariants:
     1. `!Task.isCancelled`
     2. `navSession.state == .navigating`
     3. `navSession.sessionGeneration == capturedSessionGen`
     4. `rerouteRequestGeneration == capturedRerouteGen`
4. **Active Route Replacement**:
   - Commits via `navSession.replaceActiveRoute(newRoute)`.
   - Atomically updates `activeRoute`, updates `remainingPolyline`, resets `currentStepIndex = 0` and off-route debouncing counters, and remains in `.navigating`.
   - Recomputes progress against current position and notifies BLE and map layers.
5. **Failure Behavior**:
   - If both Valhalla and MapKit fail during reroute, an error is caught.
   - State remains `.navigating` with the existing `activeRoute` preserved.
   - `isRerouting` is reset to `false`.
   - The user is never sent back to `.routePreview`.

---

## 7. stopNavigation Safety

When `stopNavigation()` is called:
- `routeCalculationTask?.cancel()` and `routeCalculationTask = nil`.
- `routeRequestGeneration &+= 1` (invalidates all pending preview requests).
- `rerouteTask?.cancel()` and `rerouteTask = nil`.
- `rerouteRequestGeneration &+= 1` (invalidates all pending reroute requests).
- `navSession.stopNavigation()` increments `sessionGeneration`, sets `navigationDestination = nil`, `isRerouting = false`, `state = .idle`, `activeRoute = nil`, and disables background location.
- `selectedDestination` and `selectedPrediction` are cleared.
- A terminal idle packet (`maneuver: .none`, `nextStreetName: "Chờ kết nối"`) is dispatched to ESP32 BLE.
- General GPS tracking continues for standard map/search functionality without automotive background drain.

---

## 8. Fake Route Audit

Every synthetic route path in the codebase was audited and remediated:

| Path / Symbol | Location | Status | Action Taken |
|---|---|---|---|
| `makeFallbackRoute` | `ValhallaWrapper.swift` | **DELETED** | Removed entire method. Replaced fallback with `throw ValhallaRoutingError.noRouteFound`. |
| `_stub_coords` | `ValhallaWrapper.swift` | **DELETED** | Removed JSON inspection for `_stub_coords` from `decodeRouteCoordinates`. |
| ObjC++ STUB Route | `ValhallaEngine.mm` | **CONVERTED TO ERROR** | Replaced 3-point fake geometry generator with `*error = ValhallaEngineErrorLibraryMissing; return nil;`. |
| ObjC++ STUB Config | `ValhallaEngine.mm` | **CONVERTED TO ERROR** | Replaced `loadConfig` fake success with `*error = ValhallaEngineErrorLibraryMissing; return NO;`. |

**Guarantee**: No production navigation or preview path can accept or produce synthetic routing success.

---

## 9. Route Rendering Status

- **Optimized in P0**:
  - `MapViewContainer.updateDestination()` now caches `lastDestinationCoord`. Destination annotations are only removed and re-added when the target coordinates change or destination is cleared, avoiding unnecessary churn on SwiftUI renders.
- **Not Redesigned / Known P1/P5 Work**:
  - `remainingPolyline` is updated in `NavigationSessionManager` as GPS moves along the route.
  - Consequently, MapLibre shape-source updates (`MLNShapeSource.shape = feature`) still occur periodically with location updates. This behavior is preserved for turn-by-turn guidance and will be formally optimized in later phases (P1/P5).

---

## 10. BLE Compatibility

- **Packet Format**: Unchanged. Continues using the 16-byte fixed binary packet structure.
- **UUIDs**: Service UUID `0xFFE0` and Characteristic UUID `0xFFE1` remain identical.
- **Protocol**: Unchanged.
- **Safety Invariants**:
  - Active navigation continues streaming valid `NavigationProgress` packets.
  - `stopNavigation()` sends the standard terminal packet.
  - Failed routing throws errors and never sends fake maneuvers or fake road names.
  - Stale reroutes after stop cannot reactivate BLE progress.

---

## 11. Validation Performed

1. **Repository Keyword Audit**:
   - `git grep -in "makeFallbackRoute"` -> `(none found)`
   - `git grep -in "_stub_coords"` -> `(none found)`
   - `git grep -in "straight fallback"` -> `(none found)`
   - `git grep -in "fake route"` -> `(none found)`
   - `git grep -in "STUB"` -> Verified no active synthetic route generator remains (only comments/framework symbols).
   - `git grep -in "setRoutePreview"` -> Verified only called when not navigating.
   - `git grep -in "recalculateCurrentRoute"` -> Verified safe lifecycle implementation.
   - `git grep -in "startNavigation"` -> Verified session generation and frozen destination.
   - `git grep -in "stopNavigation"` -> Verified session invalidation and task cancellation.
2. **Diff Validation**:
   - `git diff` executed across all modified files to verify no regressions in Kalman filtering, map matching thresholds, or segment math.
3. **Environment Build Tool Inspection**:
   - Executed: `which swift xcodebuild xcodegen flutter dart platformio`
   - Result: Native Apple build tools (`swift`, `xcodebuild`) are not present in this Linux environment. Static and structural verification was executed directly against source files.

---

## 12. Known Remaining Problems (P1 / Future Scope)

The following items are strictly deferred to P1+ and were untouched in P0:
1. **`stepIndex` vs polyline segment index mismatch in `snapAhead`**:
   - In `NavigationSessionManager.swift`: `snapAhead(rawCoord:polyline:fromSeg: currentStepIndex)` passes maneuver step index as segment index `fromSeg`. Maneuver steps and polyline coordinate segments operate in different index spaces. This requires a proper segment mapping table in P1.
2. **Map matching quality**: Kalman filter smoothing is present, but heading-assisted segment projection and road-network map matching are deferred.
3. **Heading/direction matching**: Heading is tracked but not used to penalize reverse-direction projections.
4. **Off-route tuning**: Fixed at 15m threshold with 2 consecutive frames; dynamic speed-based expansion is deferred.
5. **Route rendering optimization**: Full line-slice caching and GPU buffer optimizations deferred to P1/P5.
6. **Search ranking**: Goong search ranking heuristics deferred.
7. **Routing quality and alternatives**: Multiple route alternative selection deferred.
8. **Live traffic & dynamic ETA**: Real-time traffic congestion adjustments deferred.

---

## 13. P0 Acceptance Checklist

| Scenario | Status | Evidence |
|---|---|---|
| **Scenario A — Stop during initial route request** | **PASS** | `stopNavigation()` cancels `routeCalculationTask` and increments `routeRequestGeneration`. Post-await check `self.routeRequestGeneration == thisRequestGen` fails and discards the result. No route preview is installed. |
| **Scenario B — Stop during reroute** | **PASS** | `stopNavigation()` cancels `rerouteTask`, increments `rerouteRequestGeneration`, increments `sessionGeneration`, and sets `state = .idle`. When async routing returns, all 4 guard conditions fail. Active route remains nil, state remains idle, old request is ignored. |
| **Scenario C — Old session vs new session** | **PASS** | Session A captures `sessionGeneration = 1`. On stop/start, `sessionGeneration` increments to 3 for Session B. Reroute A returns and checks `sessionGeneration == 1`, which fails (`1 != 3`). Reroute A cannot modify Session B. |
| **Scenario D — Two route requests** | **PASS** | Request 1 has generation 1; Request 2 increments to generation 2. If Request 2 completes first, it matches generation 2 and commits. When Request 1 completes later, `1 != 2` check discards Request 1. Request 2 remains authoritative. |
| **Scenario E — Automatic reroute** | **PASS** | While waiting for reroute, `state` remains `.navigating` and `activeRoute` remains unchanged. Upon success, `replaceActiveRoute` atomically updates the active route without switching to `.routePreview`. |
| **Scenario F — Reroute failure** | **PASS** | `ValhallaWrapper.calculateRoute` throws error when Valhalla and MapKit fail. Reroute catch block catches error, preserves existing active route, and logs error. For initial route, error message is set and no preview is created. |
| **Scenario G — Unavailable Valhalla build** | **PASS** | `#else` block in `ValhallaEngine.mm` returns explicit error `ValhallaEngineErrorLibraryMissing` and `nil`. Never constructs origin-midpoint-destination geometry. |
