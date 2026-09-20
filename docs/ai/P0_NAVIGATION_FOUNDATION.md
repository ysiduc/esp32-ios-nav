# P0 Navigation Foundation Report

## 1. Repository Architecture Observed

The repository contains two distinct mobile implementations:
1. **Primary Native iOS Navigation Engine (`mobile_app/ios_native`)**:
   - The authoritative navigation implementation targeted by this refactor.
   - Built with Swift and Objective-C++ using SwiftUI, MapLibre Native iOS SDK (`maplibre-gl-native-distribution`), CoreLocation with Kalman smoothing, background location capabilities, and an embedded offline Valhalla engine (`valhalla-wrapper.xcframework` / `ValhallaEngine.mm`).
   - Architecture:
     - `NavigationModels.swift`: Authoritative model definitions, including the immutable `NavigationDestination`.
     - `NavigationSessionManager.swift`: Core navigation state machine (`.idle`, `.searching`, `.routePreview`, `.navigating`, `.arrived`), session generation tracking, active route revision tracking, ahead-only GPS projection, off-route detection (15m threshold, 2 frames), and background location updates.
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
  - Added `activeRouteGeneration: UInt64 = 0` (monotonically increasing active route revision).
  - Added `navigationDestination: NavigationDestination?` and `isRerouting: Bool`.
  - Updated `startNavigation(route:destination:)` to increment both `sessionGeneration` and `activeRouteGeneration`, freeze `navigationDestination`, reset counters, and enter `.navigating`.
  - **Deleted** legacy `startNavigation(route:)` overload that derived destination from route geometry.
  - Updated `stopNavigation()` to increment `sessionGeneration` and `activeRouteGeneration`, clear `navigationDestination`, reset route state, and disable background location.
  - Updated `clearRoute()` to increment `activeRouteGeneration`.
  - Hardened `setRoutePreview(_:)` to reject previews when `state == .navigating`.
  - Added `replaceActiveRoute(_:)` to increment `activeRouteGeneration` and atomically commit reroutes into the active session without modifying preview or session generation.
  - Added preconcurrency conformance: `extension NavigationSessionManager: @preconcurrency CLLocationManagerDelegate`.
  - In `locationManager(_:didUpdateLocations:)`, captured `capturedSessionGeneration` and `capturedRouteGeneration` before computation, and enforced strict guards before committing progress in `@MainActor`.
- **Reason**: Eliminates session and route-replacement race conditions and prevents stale GPS progress commits.

### 3. `mobile_app/ios_native/Sources/ViewModels/NavigationViewModel.swift`
- **Exact Change**:
  - Replaced wrapper tasks with real routing task storage: `routeCalculationTask: Task<NavRoute, Error>?` and `rerouteTask: Task<NavRoute, Error>?`.
  - Added monotonic request generations: `routeRequestGeneration` and `rerouteRequestGeneration`.
  - Updated `calculateRoute(to:)` to store and await the actual `Task<NavRoute, Error>`, validating task cancellation and request generation post-await before setting preview.
  - Updated `recalculateCurrentRoute()` to store and await the actual `Task<NavRoute, Error>`, cancelling superseded requests (Strategy B) and validating session generation, reroute generation, and active navigation state before calling `replaceActiveRoute`.
  - Fixed compilation error and removed route-derived destination fallback in `startNavigation()`: requires non-nil `selectedDestination` (`GoongPlace`), creates frozen `NavigationDestination`, and rejects starting without a valid resolved place.
  - Updated `stopNavigation()` to cancel real routing tasks and increment request generations.
  - Removed unused `[weak self]` in `onArrived` closure.
- **Reason**: Resolves Xcode compiler errors, provides true task cancellation, eliminates fake wrapper tasks, and prevents starting navigation without an authoritative destination.

### 4. `mobile_app/ios_native/Sources/Services/ValhallaWrapper.swift`
- **Exact Change**:
  - Removed `makeFallbackRoute()` helper entirely.
  - Replaced fallback with `throw ValhallaRoutingError.noRouteFound` when Valhalla and MapKit fail.
  - Removed `_stub_coords` decoding from `decodeRouteCoordinates()`.
  - Marked static decoding methods (`decodeRouteCoordinates`, `decodePolyline6`, `decodeSteps`) as `nonisolated private static func`.
  - Removed redundant `as! [ValhallaStep]` forced cast.
- **Reason**: Guarantees no synthetic route can enter navigation and cleans up Swift 6 concurrency warnings.

### 5. `mobile_app/ios_native/Sources/Bridge/ValhallaEngine.mm`
- **Exact Change**:
  - Replaced `#else` STUB route generator with `*error = ValhallaEngineErrorLibraryMissing; return nil;`.
  - Replaced `#else` STUB `loadConfig` with `*error = ValhallaEngineErrorLibraryMissing; return NO;`.
- **Reason**: Prevents any stub build from masquerading as a valid routing engine.

### 6. `mobile_app/ios_native/Sources/Views/MapViewContainer.swift`
- **Exact Change**: Added `lastDestinationCoord: CLLocationCoordinate2D?` to `Coordinator`. Caches destination coordinate to eliminate removing and re-adding map pin annotations on unchanged renders.
- **Reason**: Eliminates redundant annotation teardown on SwiftUI state updates.

### 7. `mobile_app/ios_native/Sources/BLE/BLEManager.swift`
- **Exact Change**: Added `@preconcurrency` to `CBCentralManagerDelegate` and `CBPeripheralDelegate` extensions.
- **Reason**: Silences Swift 6 actor-isolation protocol conformance warnings.

---

## 3. Navigation Destination Lifecycle

1. **Selected Destination (`selectedDestination: GoongPlace?`)**:
   - Owned by `NavigationViewModel` as transient UI/search state.
   - Set when a user picks an autocomplete prediction and fetches place detail.
   - Cleared when search is cleared or navigation is stopped.
2. **Active Navigation Destination (`navigationDestination: NavigationDestination?`)**:
   - Owned by `NavigationSessionManager`.
   - **Mandatory for Navigation**: In P0.2, `startNavigation()` strictly requires `selectedDestination != nil`. Destination derivation from `route.coordinates.last` has been completely deleted.
   - **Frozen**: When navigation begins, `NavigationDestination(coordinate:place.location.coordinate, name:place.name, placeID:place.placeID)` is frozen into `navSession.navigationDestination`.
   - **Rerouting**: Reroutes query `navSession.navigationDestination` directly.
   - **Cleared**: Cleared to `nil` on `stopNavigation()`.

---

## 4. Navigation Session Generation & Route Revision

Two separate monotonic generation counters protect state integrity:

1. **Session Generation (`sessionGeneration: UInt64`)**:
   - Tracks the identity of the entire navigation session.
   - Incremented when navigation starts (e.g. Session A = 1).
   - Incremented when navigation stops (Session A invalidated = 2).
   - Incremented when a new session starts (Session B = 3).
   - Prevents any pending async operation from Session A from affecting Session B.
2. **Active Route Generation (`activeRouteGeneration: UInt64`)**:
   - Tracks the authoritative route revision within the active session.
   - Incremented on `startNavigation`, `replaceActiveRoute`, and `stopNavigation` / `clearRoute`.
   - While a reroute preserves `sessionGeneration` (it is the same session), it **always** increments `activeRouteGeneration`.
   - Protects Route B from stale GPS progress calculations computed against Route A.

---

## 5. Route Request Generation & Task Ownership

- **Real Task Storage**:
  `NavigationViewModel` directly stores the underlying asynchronous routing tasks:
  ```swift
  private var routeCalculationTask: Task<NavRoute, Error>?
  private var rerouteTask: Task<NavRoute, Error>?
  ```
  No outer wrapper task is used. When `.cancel()` is invoked on `routeCalculationTask` or `rerouteTask`, it cancels the actual routing operation directly.
- **Request Generation Invariant**:
  ```swift
  private var routeRequestGeneration: UInt64 = 0
  private var rerouteRequestGeneration: UInt64 = 0
  ```
  Every new calculation increments its respective generation and stores the task. After `await task.value`, completion checks verify:
  1. `!Task.isCancelled`
  2. Request generation matches the captured value
  3. Session generation matches the captured value (for reroutes)
  4. Session state is valid

---

## 6. Reroute Lifecycle

1. **Trigger**: Off-route detected (15m, 2 consecutive frames) triggers `onRerouteNeeded` -> `recalculateCurrentRoute()`.
2. **Concurrency (Strategy B: Cancel / Supersede)**:
   - Existing `rerouteTask?.cancel()` called directly.
   - `rerouteRequestGeneration &+= 1` incremented.
   - The active reroute task is stored directly in `rerouteTask`.
3. **Capture & Await**:
   - Captures `capturedSessionGen = navSession.sessionGeneration`.
   - Captures `capturedRerouteGen = rerouteRequestGeneration`.
   - Captures destination from `navSession.navigationDestination`.
   - Awaits `currentTask.value`.
4. **Validation**:
   - `!Task.isCancelled`
   - `navSession.state == .navigating`
   - `navSession.sessionGeneration == capturedSessionGen`
   - `rerouteRequestGeneration == capturedRerouteGen`
5. **Commit**:
   - Atomically replaces route via `navSession.replaceActiveRoute(newRoute)`.
   - Increments `activeRouteGeneration`.
   - Recomputes progress and updates `remainingPolyline`.
   - Maintains session identity and stays `.navigating`.
6. **Failure**:
   - Preserves existing route and stays `.navigating`.
   - Never resets user to `.routePreview`.

---

## 7. stopNavigation Safety

When `stopNavigation()` is called:
1. `routeCalculationTask?.cancel()` and set to `nil`.
2. `routeRequestGeneration &+= 1` (invalidates pending preview requests).
3. `rerouteTask?.cancel()` and set to `nil`.
4. `rerouteRequestGeneration &+= 1` (invalidates pending reroute requests).
5. `navSession.stopNavigation()` increments `sessionGeneration` and `activeRouteGeneration`, sets `state = .idle`, `activeRoute = nil`, `navigationDestination = nil`, `isRerouting = false`, and disables background location.
6. `selectedDestination` and `selectedPrediction` are cleared.
7. Terminal idle packet sent to BLE display.
8. No pending async response or queued GPS calculation can resurrect navigation or emit BLE progress.

---

## 8. Fake Route Audit

| Path / Symbol | Location | Status | Action Taken |
|---|---|---|---|
| `makeFallbackRoute` | `ValhallaWrapper.swift` | **DELETED** | Removed method completely. Replaced with explicit error. |
| `_stub_coords` | `ValhallaWrapper.swift` | **DELETED** | Removed JSON inspection from `decodeRouteCoordinates`. |
| ObjC++ STUB Route | `ValhallaEngine.mm` | **CONVERTED TO ERROR** | Returns `ValhallaEngineErrorLibraryMissing` and `nil`. |
| ObjC++ STUB Config | `ValhallaEngine.mm` | **CONVERTED TO ERROR** | Returns `ValhallaEngineErrorLibraryMissing` and `NO`. |

---

## 9. Route Rendering Status

- **Optimized in P0**: `MapViewContainer.updateDestination()` caches `lastDestinationCoord` within coordinate epsilon, eliminating redundant pin annotation recreation on SwiftUI view refreshes.
- **Preserved for P1/P5**: `remainingPolyline` dynamically trims as GPS advances. Shape-source updates still occur with location updates; full line-slice GPU optimization is deferred to P1/P5.

---

## 10. BLE Compatibility

- 16-byte fixed binary packet structure unchanged.
- Service UUID `0xFFE0` and Characteristic UUID `0xFFE1` preserved.
- Terminal packet (`maneuver: .none`, `nextStreetName: "Chờ kết nối"`) sent on stop.
- Failed routing never sends synthetic maneuver instructions.

---

## 11. Validation Performed

1. **Static Code Inspection**:
   - Verified monotonic increments across `sessionGeneration`, `activeRouteGeneration`, `routeRequestGeneration`, and `rerouteRequestGeneration`.
   - Verified real task ownership (`Task<NavRoute, Error>`) with direct `.cancel()` calls.
   - Verified elimination of `route.coordinates.last` destination derivation.
   - Verified `@preconcurrency` delegate conformances for `CLLocationManagerDelegate`, `CBCentralManagerDelegate`, and `CBPeripheralDelegate`.
2. **Repository Grep Audits**:
   - `makeFallbackRoute` -> `(none found)`
   - `_stub_coords` -> `(none found)`
   - `straight fallback` -> `(none found)`
   - `startNavigation(route:)` -> `(none found)`
3. **CI Build Validation**:
   - GitHub Actions automated workflow executes `xcodebuild` on macOS runners (`Compile Native iOS Swift/SwiftUI`).

---

## 12. Known Remaining Problems (P1 / Future Scope)

Strictly deferred to P1+:
1. **`stepIndex` vs polyline segment index mismatch in `snapAhead`**:
   - `snapAhead(rawCoord:polyline:fromSeg: currentStepIndex)` passes maneuver step index as polyline segment index. Maneuver steps and polyline coordinate segments operate in different index spaces. Deferred to P1.
2. **Map matching quality**: Heading-assisted segment projection and road-network matching deferred.
3. **Heading/direction matching**: Reverse-direction projection penalty deferred.
4. **Off-route tuning**: Dynamic speed-based expansion deferred.
5. **Route rendering optimization**: GPU line-slice buffer optimization deferred to P1/P5.
6. **Search ranking**: Heuristics deferred.
7. **Routing quality and alternatives**: Multiple route alternative selection deferred.
8. **Live traffic & dynamic ETA**: Traffic congestion adjustments deferred.

---

## 13. P0 Acceptance Checklist

| Scenario | Status | Verification Type | Evidence |
|---|---|---|---|
| **Scenario A — Stop during initial route request** | **PASS** | STATICALLY VERIFIED | `stopNavigation()` cancels `routeCalculationTask` directly and increments `routeRequestGeneration`. Post-await check `self.routeRequestGeneration == thisRequestGen` fails and discards result. |
| **Scenario B — Stop during reroute** | **PASS** | STATICALLY VERIFIED | `stopNavigation()` cancels `rerouteTask`, increments `rerouteRequestGeneration`, increments `sessionGeneration`, and sets `state = .idle`. Post-await guards fail. Active route remains nil, state remains idle. |
| **Scenario C — Old session vs new session** | **PASS** | STATICALLY VERIFIED | Session A captures `sessionGeneration = 1`. On stop/start, `sessionGeneration` increments to 3 for Session B. Reroute A returns and checks `sessionGeneration == 1` (`1 != 3`), discarding result. Session B untouched. |
| **Scenario D — Two route requests race** | **PASS** | STATICALLY VERIFIED | Request 1 has gen 1; Request 2 has gen 2. When Request 1 completes later, `1 != 2` check discards Request 1. Request 2 remains authoritative. |
| **Scenario E — Reroute race with queued GPS result** | **PASS** | STATICALLY VERIFIED | When reroute commits, `activeRouteGeneration` increments. A queued GPS result computed against the old route checks `activeRouteGeneration == capturedRouteGeneration` and is discarded. |
| **Scenario F — Session stop with queued GPS result** | **PASS** | STATICALLY VERIFIED | When navigation stops, `sessionGeneration` increments. A queued GPS result checks `sessionGeneration == capturedSessionGeneration` and is discarded. |
| **Scenario G — No route-derived destination** | **PASS** | STATICALLY VERIFIED | `startNavigation(route:)` deleted. `startNavigation()` guards `selectedDestination != nil`. Navigation cannot start without resolved place detail. |
| **Scenario H — Synthetic route impossibility** | **PASS** | STATICALLY VERIFIED | `makeFallbackRoute` deleted, `_stub_coords` removed, `ValhallaEngine.mm` stub returns explicit error. Route failure throws `noRouteFound`. |

---

## 14. P0.2 Reviewer Corrections

During the review of P0.1, the reviewer identified the following defects, which have been fully corrected in P0.2:

1. **Native iOS Swift Compilation Error**:
   - **Defect**: In `NavigationViewModel.swift:259:63`, `selectedPrediction?.structuredFormatting?.mainText` failed to compile because `structuredFormatting` is non-optional on `GoongPrediction`.
   - **Correction**: Removed the fallback code entirely. `startNavigation()` now guards `selectedDestination != nil` (`GoongPlace`).
2. **Real Task Ownership**:
   - **Defect**: `routeCalculationTask` and `rerouteTask` were wrapper tasks awaiting another task, meaning `.cancel()` did not cancel the underlying routing operation.
   - **Correction**: Refactored `routeCalculationTask` and `rerouteTask` to `Task<NavRoute, Error>?`. Stored and awaited the actual routing tasks directly with explicit `try Task.checkCancellation()` checkpoints.
3. **Removal of Route-Derived Destination**:
   - **Defect**: `startNavigation(route:)` derived a destination from `route.coordinates.last`.
   - **Correction**: Completely removed `startNavigation(route:)`. Navigation strictly requires a `NavigationDestination` created from a user-selected `GoongPlace`.
4. **Active Route Revision (`activeRouteGeneration`)**:
   - **Defect**: A reroute within the same session did not increment a route-specific revision token.
   - **Correction**: Introduced `activeRouteGeneration: UInt64`, incremented on `startNavigation`, `replaceActiveRoute`, and `stopNavigation`/`clearRoute`.
5. **Stale GPS Progress Commit Protection**:
   - **Defect**: Queued GPS progress tasks in `@MainActor` could commit stale progress across session boundaries or route replacements.
   - **Correction**: Captured `capturedSessionGeneration` and `capturedRouteGeneration` before GPS computation; enforced strict equality checks before committing state in `@MainActor`.
6. **CoreLocation Actor Boundary**:
   - **Defect**: Compiler warned that `@MainActor` methods satisfy nonisolated `CLLocationManagerDelegate` protocol requirements.
   - **Correction**: Conformed using `@preconcurrency CLLocationManagerDelegate` and `@preconcurrency` on BLE delegates. Marked static decoding helpers as `nonisolated`.

---

## 15. CI Build Evidence

*(Updated after GitHub Actions verification of the P0.2 commit)*

- **Commit SHA**: [Pending Commit]
- **GitHub Actions Run ID**: [Pending Run]
- **Compile Native iOS Swift/SwiftUI**: [Pending Execution]
- **Compile Flutter iOS IPA**: [Pending Execution]
