# P4 Routing Quality & Alternatives

## 1. Executive Summary

Phase P4 upgrades the ESP32 iOS Navigation routing engine from a single-route, untyped prototype to a robust, mode-aware, multi-candidate routing architecture. 

Key achievements in P4:
- Replaced loose, scattered transport mode strings with a strongly typed enum `NavigationTransportMode` (`.motorcycle`, `.auto`, `.bicycle`, `.pedestrian`).
- Introduced a pure `RoutingProfile` model with explicit, verified Valhalla `costing_options` specifically configured for Vietnamese road conditions.
- Replaced dangerous manual JSON string interpolation (`stringWithFormat:@"{...}"`) with structured `JSONSerialization` in `ValhallaRequestBuilder` and `ValhallaEngine`.
- Expanded the Valhalla C++ / Objective-C bridge (`ValhallaEngine`) to request bounded alternatives (`alternates: 2`, up to 3 total candidates) and return `ValhallaRouteResult`.
- Updated the Valhalla response parser to decode the primary `trip` and each alternate in `alternates` independently, ensuring independent maneuver shape indices and polyline decodings.
- Introduced `RouteCandidate` and `RouteSet` pure models with provider metadata (`Valhalla` vs `Apple MapKit`) and deterministic deduplication.
- Fixed the MapKit fallback bug that unconditionally routed all transport modes as `.automobile`: established an explicit mode-safe fallback matrix where `.motorcycle` and `.bicycle` fallbacks are marked `isDegradedFallback = true` with warning metadata and UI badges.
- Enhanced `NavigationViewModel` preview lifecycle to allow users to switch between route alternatives without resetting destination, search state, or session identity; `startNavigation()` authoritative commitment begins on the chosen alternative route.
- Preserved single-flight, authoritative off-route rerouting in `RerouteManager` without mutating preview candidates.
- Added 26 new unit tests, expanding the test suite to 129 tests (129/129 PASS).

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
- `mobile_app/ios_native/Tests/ESP32NavAppTests/RoutingProfileTests.swift`: Profile options and structured JSON request serialization tests (8 tests).
- `mobile_app/ios_native/Tests/ESP32NavAppTests/ValhallaRouteSetParserTests.swift`: Multi-route parsing and candidate deduplication tests (5 tests).
- `mobile_app/ios_native/Tests/ESP32NavAppTests/RoutingFallbackTests.swift`: MapKit mode mapping and fallback capability tests (7 tests).
- `mobile_app/ios_native/Tests/ESP32NavAppTests/RouteCandidateSelectionTests.swift`: Preview candidate selection, race safety, and startNavigation tests (6 tests).

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

## 13. Valhalla Response Parsing

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
1. Filters out routes with identical coordinate sequences.
2. Filters out near-duplicate routes (distance within 20m, duration within 5s, identical origin and destination).
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
Total tests: 129 (103 pre-P4 + 26 new P4)

| Test Suite | Pre-P4 | P4 New | Total | Status |
| :--- | :---: | :---: | :---: | :---: |
| `RouteGeometryTests` | 12 | 0 | 12 | PASS |
| `OffRouteDetectorTests` | 10 | 0 | 10 | PASS |
| `RerouteManagerTests` | 15 | 0 | 15 | PASS |
| `GoongSearchServiceTests` | 22 | 0 | 22 | PASS |
| `SearchRankingTests` | 31 | 0 | 31 | PASS |
| `DestinationSelectionTests` | 13 | 0 | 13 | PASS |
| `RoutingProfileTests` | 0 | 8 | 8 | PASS |
| `ValhallaRouteSetParserTests` | 0 | 5 | 5 | PASS |
| `RoutingFallbackTests` | 0 | 7 | 7 | PASS |
| `RouteCandidateSelectionTests` | 0 | 6 | 6 | PASS |
| **Total** | **103** | **26** | **129** | **ALL PASS** |

---

## 20. GitHub Actions Evidence

- **Workflow Run ID**: `35533694130`
- **Commit SHA**: `6af4b63c0ea07ea51e58da571081196437d4e64e`
- **Workflow Run URL**: https://github.com/ysiduc/esp32-ios-nav/actions/runs/35533694130

### CI Verification Results

```text
Job: Compile Native iOS Swift/SwiftUI (ID 106138800589)
Duration: 3m 16s
Status: SUCCESS

Test Results:
Test Suite 'DestinationSelectionTests' passed (13 tests, 0 failures)
Test Suite 'GoongSearchServiceTests' passed (22 tests, 0 failures)
Test Suite 'OffRouteDetectorTests' passed (10 tests, 0 failures)
Test Suite 'RerouteManagerTests' passed (15 tests, 0 failures)
Test Suite 'RouteCandidateSelectionTests' passed (6 tests, 0 failures)
Test Suite 'RouteGeometryTests' passed (12 tests, 0 failures)
Test Suite 'RoutingFallbackTests' passed (7 tests, 0 failures)
Test Suite 'RoutingProfileTests' passed (8 tests, 0 failures)
Test Suite 'SearchRankingTests' passed (31 tests, 0 failures)
Test Suite 'ValhallaRouteSetParserTests' passed (5 tests, 0 failures)

Total: 129 tests executed, 0 failures (0 unexpected)
Result: 129/129 PASS

Native Release App Build: SUCCESS
Native IPA Package: SUCCESS
Native IPA Artifact Upload: SUCCESS (esp32_nav_native_ios_ipa)

Job: Compile Flutter iOS IPA (ID 106138800515)
Duration: 4m 2s
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
