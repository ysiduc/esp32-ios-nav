# P4 Routing Quality & Alternatives

## 1. Executive Summary

Phase P4 upgrades the ESP32 iOS Navigation routing engine from a single-route, untyped prototype to a robust, mode-aware, multi-candidate routing architecture. 

Key achievements in P4:
- Replaced loose, scattered transport mode strings with a strongly typed enum `NavigationTransportMode` (`.motorcycle`, `.auto`, `.bicycle`, `.pedestrian`).
- Introduced a pure `RoutingProfile` model with explicit, verified Valhalla `costing_options` representing a conservative motorcycle routing profile intended for normal road navigation (with real-world Vietnam road testing planned for P5/final verification).
- Replaced dangerous manual JSON string interpolation (`stringWithFormat:@"{...}"`) with structured `JSONSerialization` in `ValhallaRequestBuilder` and `ValhallaEngine`.
- Expanded the Valhalla C++ / Objective-C bridge (`ValhallaEngine`) to request bounded alternatives (`alternates: 2`, up to 3 total candidates) and return `ValhallaRouteResult`.
- Updated the Valhalla response parser to decode the primary `trip` and each alternate in `alternates` independently, ensuring independent maneuver shape indices and polyline decodings.
- Introduced `RouteCandidate` and `RouteSet` pure models with provider metadata (`Valhalla` vs `Apple MapKit`) and deterministic deduplication.
- Fixed the MapKit fallback bug that unconditionally routed all transport modes as `.automobile`: established an explicit mode-safe fallback matrix where `.motorcycle` and `.bicycle` fallbacks are marked `isDegradedFallback = true` with warning metadata and UI badges.
- Enhanced `NavigationViewModel` preview lifecycle to allow users to switch between route alternatives without resetting destination, search state, or session identity; `startNavigation()` authoritative commitment begins on the chosen alternative route.
- Preserved single-flight, authoritative off-route rerouting in `RerouteManager` without mutating preview candidates.
- Added 26 new unit tests for Initial P4 (129 tests, 129/129 PASS, Run 35533694130), subsequently expanded to 142 tests (142/142 PASS, Run 35566129892) across P4.1 and P4.1.1 reviewer corrections.

---

## 2. Baseline

- Main baseline: `0bdf6c007a7a5ee55cb9473654f3fd5159d9c572`
- Verified P3.1 implementation: `fe61dfab19c2ee0013f682fa6548f49dd08e35b5`
- Verified GitHub Actions run ID: `35531287589`
- Pre-P4 test status: 103/103 PASS (0 failures)

---

## 3. Files Changed

### Documentation Corrections
- `docs/ai/P3_SEARCH_DESTINATION.md`: Corrected normalization description to match `SearchRanking.swift` (fixed `vi_VN` locale, lowercase, `Đ`/`đ` -> `d`, punctuation -> space, whitespace collapse).
- `docs/ai/P4_ROUTING_QUALITY.md`: This comprehensive technical report.

### Pure Models
- `mobile_app/ios_native/Sources/Models/NavigationTransportMode.swift`: Strongly typed transport mode enum.
- `mobile_app/ios_native/Sources/Models/RoutingProfile.swift`: Routing profile definitions, costing options, and fallback policy.
- `mobile_app/ios_native/Sources/Models/RouteCandidate.swift`: `RouteCandidate`, `RouteSet`, provider metadata, and deterministic deduplication.
- `mobile_app/ios_native/Sources/Models/RoutingRequest.swift`: `RoutingRequest` and structured `ValhallaRequestBuilder`.

### Bridge & Services
- `mobile_app/ios_native/Sources/Bridge/ValhallaEngine.h`: Declared `ValhallaRouteResult`, multi-route calculation methods, and JSON parser.
- `mobile_app/ios_native/Sources/Bridge/ValhallaEngine.mm`: Objective-C++ implementation with `NSJSONSerialization` request building and independent alternate trips parsing.
- `mobile_app/ios_native/Sources/Services/ValhallaWrapper.swift`: Multi-route `calculateRoutes(request:)`, mode-safe MapKit fallback, error classification, and proportional step durations.

### ViewModels & UI
- `mobile_app/ios_native/Sources/ViewModels/NavigationViewModel.swift`: Preview candidates state machine, `selectRouteCandidate(id:)`, alternative route commit in `startNavigation()`.
- `mobile_app/ios_native/Sources/Views/MainMapView.swift`: Compact alternative route picker chips, degraded fallback banner, and dynamic preview polyline switching.

### Test Suites
Initial P4 added 26 tests (129 total); P4.1 and P4.1.1 added 13 additional tests, reaching 142 total tests (142/142 PASS):
- `mobile_app/ios_native/Tests/ESP32NavAppTests/RoutingProfileTests.swift`: Profile options and structured JSON request serialization tests (8 initial, 9 final).
- `mobile_app/ios_native/Tests/ESP32NavAppTests/ValhallaRouteSetParserTests.swift`: Multi-route parsing and candidate deduplication tests (5 initial, 6 final).
- `mobile_app/ios_native/Tests/ESP32NavAppTests/RoutingFallbackTests.swift`: MapKit mode mapping and fallback capability tests (7 tests).
- `mobile_app/ios_native/Tests/ESP32NavAppTests/RouteCandidateSelectionTests.swift`: Preview candidate selection, race safety, and startNavigation tests (6 initial, 17 final).

---

## 4. Previous Routing Architecture

Prior to P4:
1. `RoutingServiceProtocol` exposed only a single method:
   ```swift
   func calculateRoute(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, costing: String) async throws -> NavRoute
   ```
2. Valhalla requests were built by manual string concatenation:
   ```objc
   NSString *requestJSON = [NSString stringWithFormat:
       @"{\"locations\":[{\"lon\":%.7f,\"lat\":%.7f},{\"lon\":%.7f,\"lat\":%.7f}],"
       @"\"costing\":\"%@\","
       @"\"directions_options\":{\"language\":\"vi\",\"units\":\"kilometers\","
       @"\"narrative\":true},\"format\":\"json\"}",
       fromLon, fromLat, toLon, toLat, costing];
   ```
3. No `costing_options` were sent; Valhalla used undocumented internal defaults.
4. No `alternates` parameter was sent; only a single route could be returned.
5. The JSON parser only examined `root[@"trip"][@"legs"][0]`, completely ignoring `root[@"alternates"]`.
6. MapKit fallback unconditionally set `req.transportType = .automobile` for all transport modes (motorcycle, bicycle, pedestrian, auto).

---

## 5. Confirmed Routing Defects

1. **Incorrect Mode Fallback**: When offline tiles were unavailable, motorbikes, bicycles, and pedestrians were silently routed via Apple MapKit automobile directions.
2. **Missing Alternative Routes**: Users had no choice of route in preview mode.
3. **Unspecified Motorcycle Costing**: The native Valhalla engine used generic car-like costing, allowing potential diversion onto unsuitable pathways or missing arterial road preference.
4. **Fragile Request Serialization**: Manual string formatting risked producing invalid JSON if floating-point formatting or character escaping issues arose.

---

## 6. Transport Mode Type

`NavigationTransportMode` (`mobile_app/ios_native/Sources/Models/NavigationTransportMode.swift`) provides a strongly typed representation across all routing boundaries:

```swift
public enum NavigationTransportMode: String, Sendable, CaseIterable, Equatable, Hashable {
    case motorcycle
    case auto
    case bicycle
    case pedestrian

    public var displayName: String { ... }
    public var iconName: String { ... }
    public init(costingValue: String) { ... }
}
```

Loose string values from legacy UI or configurations are parsed at the system boundary via `init(costingValue:)`.

---

## 7. Routing Profile Model

`RoutingProfile` encapsulates the parameters for route computation:

```swift
public struct RoutingProfile: Sendable, Equatable {
    public let id: String
    public let transportMode: NavigationTransportMode
    public let valhallaCosting: String
    public let costingOptions: ProfileCostingOptions
    public let maxAlternatives: Int
    public let fallbackPolicy: FallbackPolicy
}
```

`ProfileCostingOptions` provides typed numeric costing options (`[String: Double]`) that serialize cleanly into Valhalla JSON requests without untyped `[String: Any]` dictionary proliferation.

---

## 8. Motorcycle Profile

### Costing Model: `motorcycle`

Configured in `RoutingProfile.profile(for: .motorcycle)`:
- `valhallaCosting`: `"motorcycle"`
- `maxAlternatives`: `2`

### Costing Options Rationale:

| Costing Option | Value | Default | Rationale |
| :--- | :---: | :---: | :--- |
| `use_highways` | `0.5` | `0.5` | Balances arterial road usage with local roads; graph access tags govern motorway access. |
| `use_tolls` | `0.5` | `0.5` | Permits toll roads when they provide substantial time savings. |
| `use_trails` | `0.0` | `0.0` | Strongly discourages routing onto unpaved dirt footpaths or off-road trails. |
| `use_tracks` | `0.0` | `0.0` | Strongly discourages agricultural tracks and unclassified dirt paths. |
| `use_ferry` | `0.5` | `0.5` | Allows river crossings and vehicle ferries commonly utilized in Vietnam. |
| `use_living_streets` | `0.5` | `0.5` | Allows residential street access where necessary for destination reachability. |

No unsupported legal speed assumptions or arbitrary vehicle class bans are hard-coded into the client; graph access restrictions in OSM/Valhalla tiles remain authoritative.

> [!NOTE]
> This is a conservative motorcycle routing profile intended for normal road navigation, avoiding unpaved trails or tracks without imposing unsupported legal exclusions. Real-world route validation on Vietnamese roadways remains necessary during P5 on-device field testing. No claim of parity with Google Maps or Waze real-time traffic intelligence is made.

---

## 9. Other Mode Profiles

### Auto Profile (`.auto`):
- `valhallaCosting`: `"auto"`
- `use_highways`: `1.0` (favors higher classification roadways)
- `use_tolls`: `1.0` (allows toll highways)
- `use_trails`: `0.0`, `use_tracks`: `0.0`
- `use_ferry`: `0.5`, `use_living_streets`: `0.5`

### Bicycle Profile (`.bicycle`):
- `valhallaCosting`: `"bicycle"`
- `use_roads`: `0.5`
- `use_hills`: `0.2` (moderately discourages steep inclines)

### Pedestrian Profile (`.pedestrian`):
- `valhallaCosting`: `"pedestrian"`
- `use_lit`: `0.5` (mildly prefers lit walkways where attributed)

---

## 10. Valhalla Request Builder

`ValhallaRequestBuilder` constructs routing requests via `JSONSerialization` with `.sortedKeys` for deterministic output:

```json
{
  "alternates": 2,
  "costing": "motorcycle",
  "costing_options": {
    "motorcycle": {
      "use_ferry": 0.5,
      "use_highways": 0.5,
      "use_living_streets": 0.5,
      "use_tolls": 0.5,
      "use_tracks": 0.0,
      "use_trails": 0.0
    }
  },
  "directions_options": {
    "language": "vi",
    "narrative": true,
    "units": "kilometers"
  },
  "format": "json",
  "locations": [
    { "lat": 21.0285, "lon": 105.8542 },
    { "lat": 21.0368, "lon": 105.8346 }
  ]
}
```

---

## 11. Costing Options Support

Verified directly against `valhalla/proto/options.pb.h` in `valhalla-wrapper.xcframework`:
- `use_highways`, `use_tolls`, `use_trails`, `use_tracks`, `use_ferry`, `use_living_streets` are confirmed supported fields of `Costing_Options` in the embedded Valhalla build.

---

## 12. Alternative Route Support

- `alternates` parameter is set to `2` for preview requests, requesting up to 3 routes (1 primary + up to 2 alternates).
- Configured in accordance with `valhalla.json` service limit `max_alternates = 2`.
- Off-route reroute requests set `alternates: 0` to ensure minimal latency and avoid preview disruption.

---

## 13. Valhalla 3.6.3 Verification & Response Parsing

### Embedded Valhalla Version
Verified from embedded header `valhalla/valhalla.h`:
- `VALHALLA_VERSION_MAJOR`: `3`
- `VALHALLA_VERSION_MINOR`: `6`
- `VALHALLA_VERSION_PATCH`: `3`

Verified costing options supported in this embedded build (`options.pb.h`):
- `alternates`
- `use_highways`
- `use_tolls`
- `use_trails`
- `use_tracks`
- `use_living_streets`
- `use_lit`

### Serialized Response Contract
- Primary route: `root[@"trip"]`
- Alternatives: `root[@"alternates"]`, an array of objects structured as `{ "trip": { ... } }`

`ValhallaEngine.mm` decodes both primary and alternate routes:
1. `root[@"trip"]` is parsed as the primary route (`primaryRoute`).
2. `root[@"alternates"]` is iterated; each alternate trip is decoded into an independent `ValhallaRoute` (`alternativeRoutes`).
3. Each route preserves its own polyline6 shape and maneuver shape indices (`begin_shape_index`, `end_shape_index`).
4. Exposed via `ValhallaRouteResult.allRoutes` (with `primaryRoute` at index 0).

---

## 14. RouteCandidate / RouteSet Model

```swift
public struct RouteCandidate: Sendable, Identifiable, Equatable {
    public let id: String
    public let route: NavRoute
    public let provider: RoutingProvider
    public let requestedMode: NavigationTransportMode
    public let profileID: String
    public let isPrimary: Bool
    public let isDegradedFallback: Bool
    public let degradedReason: String?
    public let label: String
    public let relativeDurationSeconds: Double
    public let relativeDistanceMeters: Double
}
```

### Deterministic Deduplication:
`RouteSet.deduplicate(candidates:)`:
1. Filters out routes with identical coordinate sequences (microdegree precision ~1.1m).
2. Distinct alternative routes taking different road corridors (e.g. east vs. west arterials) are preserved even if they share identical endpoints, distance, or duration.
3. Assigns deterministic labels: `"Đề xuất"`, `"Tuyến 2"`, `"Tuyến 3"`.
4. Calculates duration and distance deltas relative to primary.

---

## 15. Provider Metadata

Candidates record provider origin:
- `.valhalla`: Offline native vector graph.
- `.mapKit`: Apple MapKit fallback service.
- If MapKit is used for an unsupported mode (e.g. motorcycle), `isDegradedFallback` is set to `true` and `degradedReason` is populated.

---

## 16. MapKit Fallback Policy

### Mode Fallback Matrix:

| Requested Mode | Primary Provider | Fallback Provider | MapKit Transport Type | Degraded? | Notes |
| :--- | :--- | :--- | :--- | :---: | :--- |
| `auto` | Valhalla | MapKit | `.automobile` | **No** | Full native support |
| `pedestrian` | Valhalla | MapKit | `.walking` | **No** | Full native support |
| `motorcycle` | Valhalla | MapKit | `.automobile` | **Yes** | Approximated; marked degraded with banner |
| `bicycle` | Valhalla | MapKit | `.walking` | **Yes** | Approximated; marked degraded with banner |

Proportional step duration calculation:

```text
stepDuration = (stepDistance / totalDistance) * expectedTravelTime
```

Preserves total route duration exactly as returned by Apple MapKit.

---

## 17. Preview Selection Lifecycle

1. When routes arrive, candidate 0 (`"Đề xuất"`) is selected by default; `navSession.setRoutePreview(primary.route)` is called.
2. Tapping alternative candidate B calls `viewModel.selectRouteCandidate(id: B.id)`:
   - Updates `selectedRouteCandidateID`.
   - Updates `navSession.setRoutePreview(B.route)` (updating the displayed map polyline).
   - Preserves `selectedDestination`, search query, and `sessionGeneration`.
3. `startNavigation()` commits `selectedCandidate.route` to active navigation.
4. `clearSearch()` and `stopNavigation()` clear candidate state completely.

---

## 18. Reroute Integration

- `RerouteManager` continues to request a single authoritative replacement route via `calculateRoute(...)` or `calculateRoutes(request:)` with `requestedAlternatives = 0`.
- Reroute execution atomically invokes `navSession.replaceActiveRoute(newRoute)` without opening or mutating route preview candidate lists.
- Generation safety, single-flight locks, and exponential backoff retry progression remain completely intact.

---

## 19. Tests

Total test suites: 10
Total tests: 142 (103 pre-P4 + 26 P4 initial + 13 P4.1/P4.1.1 corrections)

| Test Suite | Baseline | P4 New | P4.1/P4.1.1 New | Total | Status |
| :--- | :---: | :---: | :---: | :---: | :---: |
| `RouteGeometryTests` | 12 | 0 | 0 | 12 | PASS |
| `OffRouteDetectorTests` | 10 | 0 | 0 | 10 | PASS |
| `RerouteManagerTests` | 15 | 0 | 0 | 15 | PASS |
| `GoongSearchServiceTests` | 22 | 0 | 0 | 22 | PASS |
| `SearchRankingTests` | 31 | 0 | 0 | 31 | PASS |
| `DestinationSelectionTests` | 13 | 0 | 0 | 13 | PASS |
| `RoutingProfileTests` | 0 | 8 | 1 | 9 | PASS |
| `ValhallaRouteSetParserTests` | 0 | 5 | 1 | 6 | PASS |
| `RoutingFallbackTests` | 0 | 7 | 0 | 7 | PASS |
| `RouteCandidateSelectionTests` | 0 | 6 | 11 | 17 | PASS |
| **Total** | **103** | **26** | **13** | **142** | **ALL PASS** |

---

## 20. GitHub Actions Evidence

### Historical Run 1: Initial P4 Implementation
- **Workflow Run ID**: `35533694130`
- **Commit SHA**: `6af4b63c0ea07ea51e58da571081196437d4e64e`
- **Workflow Run URL**: https://github.com/ysiduc/esp32-ios-nav/actions/runs/35533694130
- **Total Tests**: 129 executed, 0 failures (129/129 PASS)
- **Native Release & IPA**: SUCCESS
- **Flutter iOS IPA**: SUCCESS

### Historical Run 2: Interim P4.1 Reviewer Corrections
- **Workflow Run ID**: `35564593760`
- **Commit SHA**: `0cd569ba05fe910df78bbd8e857f56155a17305d`
- **Workflow Run URL**: https://github.com/ysiduc/esp32-ios-nav/actions/runs/35564593760
- **Total Tests**: 141 executed, 0 failures (141/141 PASS)
- **Native Release & IPA**: SUCCESS
- **Flutter iOS IPA**: SUCCESS

### Final Run 3: P4.1.1 Production Encapsulation & Reroute Commit Proof
- **Workflow Run ID**: `35566129892`
- **Commit SHA**: `33216d261179da2486fb3320e4ac09d9247b1b07`
- **Workflow Run URL**: https://github.com/ysiduc/esp32-ios-nav/actions/runs/35566129892

#### CI Verification Results

```text
Job: Compile Native iOS Swift/SwiftUI (ID 106228199706)
Duration: 5m 4s
Status: SUCCESS

Test Suite Execution Breakdown:
- DestinationSelectionTests:    13 executed, 0 failures (2.008s)
- GoongSearchServiceTests:      22 executed, 0 failures (1.493s)
- OffRouteDetectorTests:        10 executed, 0 failures (0.058s)
- RerouteManagerTests:          15 executed, 0 failures (1.906s)
- RouteCandidateSelectionTests: 17 executed, 0 failures (0.898s)
- RouteGeometryTests:           12 executed, 0 failures (0.013s)
- RoutingFallbackTests:          7 executed, 0 failures (0.078s)
- RoutingProfileTests:           9 executed, 0 failures (0.017s)
- SearchRankingTests:           31 executed, 0 failures (0.118s)
- ValhallaRouteSetParserTests:   6 executed, 0 failures (0.009s)

Total: 142 tests executed, 0 failures (0 unexpected) in 6.600s
Result: 142/142 PASS

Native Release App Build: SUCCESS
Native IPA Package: SUCCESS
Native IPA Artifact Upload: SUCCESS (esp32_nav_native_ios_ipa)

Job: Compile Flutter iOS IPA (ID 106228199882)
Duration: 5m 25s
Status: SUCCESS
Flutter Release App Build: SUCCESS
Flutter IPA Package: SUCCESS
Flutter IPA Artifact Upload: SUCCESS (esp32_nav_flutter_ios_ipa)
```

---

## 21. Known Remaining Problems

1. **Lack of Real-time Traffic Intelligence**: Embedded Valhalla operates on offline OpenStreetMap tiles without dynamic congestion data.
2. **OSM Attribute Completeness**: Motorcycle legal access relies on OpenStreetMap road classifications and access tags; unverified local restrictions may exist.
3. **MapKit Motorbike Limitations**: MapKit has no native motorcycle routing in Vietnam; fallback routes represent automobile geometry.

---

## 22. P5 Readiness

- P4 routing quality, motorcycle profile, bounded alternatives, and fallback semantics are fully implemented and tested.
- P5 (simulation, battery, performance optimizations) can commence upon external reviewer approval.


---

## 23. P4.1 Reviewer Corrections

Phase P4.1 and P4.1.1 address critical lifecycle, mode-switch safety, loading state ownership, alternative clamping, deduplication, encapsulation, and candidate selection invariants identified during external audit:

1. **Immediate Preview Invalidation on Mode Switch**:
   - Resolved the critical defect where switching transport modes (e.g. Motorcycle -> Auto) left the old preview route active while the new calculation was in flight, and allowed an old route to persist if the new request failed.
   - Introduced `invalidateRoutePreviewState(clearActivePreview:resetLoading:)` and `resetRouteCandidateState()`.
   - Switching transport mode in preview mode immediately clears previous route candidates, selected candidate ID, provider metadata, and calls `navSession.clearRoute()`.
   - If recalculation fails, no stale route is resurrected; `routeCandidates == []`, `selectedRouteCandidateID == nil`, `navSession.activeRoute == nil`, and `startNavigation()` is strictly rejected.

2. **Route Calculation Loading State Ownership**:
   - Fixed stuck spinner defect where cancelling an in-flight route calculation (e.g., via `clearSearch()` or text edit) failed to reset `isCalculatingRoute` to `false`.
   - Implemented request-generation-based loading ownership: cancelled tasks cannot reset `isCalculatingRoute` if a newer request generation owns loading state.
   - Explicit user cancellations (`clearSearch()`, `updateSearchQuery` fresh search) immediately set `isCalculatingRoute = false`.

3. **New Destination / Place Detail Invariant**:
   - `selectPrediction` and new search queries immediately invalidate prior candidate sets and route previews before Place Detail or routing begins.
   - Place Detail failure cleanly resets `isCalculatingRoute` to `false` and ensures no orphaned preview candidates remain.

4. **Authoritative Candidate Invariant in `startNavigation`**:
   - Removed the weak fallback `?? navSession.activeRoute`.
   - Enforced that `selectedRouteCandidateID` must resolve to an existing candidate in `routeCandidates`.
   - Enforced that `selectedCandidate.requestedMode == currentTransportMode`. If a mode mismatch occurs, `startNavigation()` is rejected with a controlled error message and navigation does not start.

5. **Navigation State Guard on `selectRouteCandidate(id:)`**:
   - Protected against programmatic or late UI events calling candidate selection during active navigation: rejects selection immediately when `navSession.state == .navigating`.
   - Tapping preview candidates cannot alter active navigation or switch back to preview.

6. **Alternative Count Clamping**:
   - Enforced clamping at the pure model boundary: `RoutingRequest.init` clamps `requestedAlternatives = max(0, min(requestedAlternatives, profile.maxAlternatives))`.
   - `ValhallaRequestBuilder.buildRequestJSON` independently clamps `alternates` to `profile.maxAlternatives`.
   - `NavigationViewModel` requests `profile.maxAlternatives` instead of hardcoding 2.

7. **Geometric Deduplication False-Positive Fix**:
   - Removed the length (<20m) and duration (<5s) heuristic that erroneously removed distinct alternative routes taking different corridors (e.g. east vs. west arterials) with identical endpoints and similar metrics.
   - Deduplication now strictly requires actual coordinate sequence equivalence (microdegree precision ~1.1m).

8. **Restored Production State Encapsulation (P4.1.1)**:
   - Restored `public private(set)` on all route candidate, provider, and mode properties in `NavigationViewModel`.
   - Unit tests drive state exclusively through public methods (`transportMode`, `calculateRoute`, `selectPrediction`, `startNavigation`) and injected mock services, rather than direct property mutations.

9. **Navigation Mode-Switch Commit Proof (P4.1.1)**:
   - Added end-to-end integration proof verifying that switching transport mode while navigating preserves the active route and frozen destination until the new-mode route resolves and commits atomically through `RerouteManager`, without involving preview selection UI.
