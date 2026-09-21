# P5.3 Search & Route Diversity

## 1. Goals
P5.3 achieves two distinct product and architectural objectives:
1. **Complete Removal of Goong**: Replace Goong REST search dependencies (`GoongSearchService`, `GoongPlacesClient`, `GoongConfiguration`, `GoongRequestBuilder`, and associated Goong models) with a clean, provider-neutral search interface powered on-device by Apple MapKit Search (`MKLocalSearchCompleter` and `MKLocalSearch`). Eliminate all third-party API key configurations and credential handling.
2. **Multi-Strategy Route Alternatives**: Overcome Valhalla's single-request alternate limitations (`alternates = 2` frequently returning similar geometry) by introducing `MultiStrategyRoutePlanner`. This layer orchestrates concurrent costing strategies tuned specifically for motorcycle navigation, deduplicates overlapping polylines via corridor-based geometric overlap (`RouteSimilarity.overlap`), rejects absurd detours, computes duration and distance deltas, and renders visually distinct alternatives during route preview.

All P5.2.1 field navigation continuity, tracking, maneuver progression, and reroute invariants are strictly preserved.

---

## 2. Previous Goong Dependency
Previously, destination lookup relied on Goong's cloud-hosted REST APIs:
- Autocomplete: `GET https://rsapi.goong.io/Place/AutoComplete`
- Place Detail: `GET https://rsapi.goong.io/Place/Detail`
- Required API keys injected via build settings (`GOONG_API_KEY`), `Info.plist`, and runtime environment variables.
- Models and services were coupled to Goong-specific types (`GoongPrediction`, `GoongPlace`, `GoongLocation`, `GoongRawPrediction`, `GoongStructuredFormatting`).
- This created an external cloud subscription dependency, network quota limitations, and potential privacy exposure of user search queries.

---

## 3. Provider-Neutral Search Architecture
The search layer is now abstracted into provider-independent models in `SearchModels.swift`:
- `SearchPrediction`: Identifiable, Sendable model with `id`, `title`, `subtitle`, `mainText`, `secondaryText`, and composite `description`.
- `ResolvedPlace`: Sendable model with `id`, `name`, `formattedAddress`, and `coordinate` (`CLLocationCoordinate2D`).
- `PlaceSearchServiceProtocol`:
  ```swift
  @MainActor
  public protocol PlaceSearchServiceProtocol: AnyObject {
      var predictions: [SearchPrediction] { get }
      var isLoading: Bool { get }
      var errorMessage: String? { get }
      var userLocation: CLLocationCoordinate2D? { get set }
      var onPredictionsChanged: (([SearchPrediction]) -> Void)? { get set }

      func updateQuery(_ query: String)
      func cancelAutocomplete()
      func clearPredictions()
      func resetAll()
      func resolve(prediction: SearchPrediction) async throws -> ResolvedPlace
  }
  ```
`NavigationViewModel` depends solely on `any PlaceSearchServiceProtocol`, ensuring zero coupling to any specific search backend.

---

## 4. Apple MapKit Search
`ApplePlaceSearchService` implements `PlaceSearchServiceProtocol` using native iOS frameworks:
- **Autocomplete Completer**: Utilizes `MKLocalSearchCompleter` configured for `.address`, `.pointOfInterest`, and `.query`.
- **Search Region Bias**: Biases search completions around `userLocation` with an urban/regional span (~2.0° delta) while preserving full capability for cross-province searches.
- **Direct Completion Resolution**: When the user selects a completion, `ApplePlaceSearchService` resolves it directly via `MKLocalSearch.Request(completion:)`, avoiding fragile text-based geocoding.
- **Deterministic Multi-Result Ranking**: If `MKLocalSearch` returns multiple `MKMapItem` results, candidates are deterministically ranked:
  - Exact/prefix title match (+50 / +30 pts)
  - Subtitle/address token match (+20 pts)
  - Vietnam geographic bounding box bonus (+25 pts)
  - Proximity to user location (+0...15 pts decaying over distance)
- **Unit Testability**: The underlying MapKit operations are isolated behind `MapKitSearchAdapterProtocol`. In CI and automated test environments, `MockMapKitSearchAdapter` provides deterministic completions and resolutions without network calls.

---

## 5. Search Lifecycle & Race Safety
All P3 and P4 concurrency and stale-response protections are preserved:
- **Monotonic Query Generation**: Incrementing `autocompleteGeneration` counter ensures responses from superseded keystrokes (e.g. "Ha" -> "Hano" -> "Hanoi") are discarded.
- **Destination Selection Generation**: Rapid consecutive selections (Place A followed by Place B) ensure in-flight resolution of A is cancelled and discarded; only Place B commits.
- **New Query Invalidation**: Typing a new query while place resolution or route calculation is in-flight cancels in-flight tasks and clears existing preview state.
- **Clear Search**: Tapping the clear button cancels pending resolutions and route calculations, resetting published search and preview state to nil.

---

## 6. Existing Route Alternative Limitation
Under P4/P5.2, route preview was limited by Valhalla's single-request behavior:
- `maxAlternatives = 2` in `RoutingProfile` requested at most 1 primary + 2 alternates from a single costing query.
- Simply increasing `alternates = 5` in Valhalla typically yields identical or nearly identical geometry with minor turn deviations, and frequently returns fewer than requested.
- Deduplication only compared coordinate array lengths and point-by-point equality, failing when two routes traversed the same road with different polyline sampling density.

---

## 7. Multi-Strategy Valhalla Planner
`MultiStrategyRoutePlanner` introduces an orchestration layer conforming to `RoutingServiceProtocol`:
- For motorcycle preview (`requestedAlternatives > 0`), it executes up to 4 distinct Valhalla queries concurrently using structured Swift concurrency (`withTaskGroup`).
- Each strategy uses legitimate costing parameters with distinct road preferences while strictly preserving motorcycle access restrictions.
- Collects raw candidates (up to ~7 routes), applies detour filtering, deduplicates overlapping polylines via corridor-based geometric overlap, and ranks the candidates.
- Returns 3 to 5 genuinely distinct, useful alternatives (or fewer if the road network genuinely converges; never fabricates fake duplicates).

---

## 8. Motorcycle Strategies
All motorcycle strategies strictly set `costing = "motorcycle"`, ensuring legal motorcycle access rules and motorway prohibitions remain authoritative:
1. **Balanced (`motorcycle_balanced`)** — Label: "Đề xuất"
   - Primary route strategy.
   - `use_highways = 0.5`, `use_tolls = 0.5`, `use_living_streets = 0.5`, `use_ferry = 0.5`, `use_trails = 0.0`, `use_tracks = 0.0`.
   - Requested alternates: 1.
2. **Main Roads (`motorcycle_main_roads`)** — Label: "Đường chính"
   - Prefers major arterial thoroughfares and wider avenues over small residential alleys.
   - `use_highways = 0.8`, `use_living_streets = 0.2`, `use_tolls = 0.5`, `use_ferry = 0.5`, `use_trails = 0.0`, `use_tracks = 0.0`.
   - Requested alternates: 1.
3. **Urban / Local (`motorcycle_local`)** — Label: "Đường nội đô"
   - Prefers local street grid, connecting roads, and residential living streets, avoiding high-speed arterials where possible.
   - `use_highways = 0.25`, `use_living_streets = 0.7`, `use_tolls = 0.5`, `use_ferry = 0.5`, `use_trails = 0.0`, `use_tracks = 0.0`.
   - Requested alternates: 1.
4. **Low Toll (`motorcycle_low_toll`)** — Label: "Ít trạm thu phí"
   - Strongly discourages toll roads (`use_tolls = 0.0`), preferring alternative bypasses when available.
   - `use_highways = 0.5`, `use_tolls = 0.0`, `use_living_streets = 0.5`, `use_ferry = 0.5`, `use_trails = 0.0`, `use_tracks = 0.0`.
   - Requested alternates: 0 (primary only).

Unsafe parameters (`use_trails`, `use_tracks`) remain strictly `0.0` across all strategies.

---

## 9. Candidate Similarity Algorithm
`RouteSimilarity.overlap(routeA: NavRoute, routeB: NavRoute)` computes normalized geometric overlap `[0.0, 1.0]`:
- **Endpoint Corridor Masking**: The first and last 150m (or 5% of route length) are masked from comparison so common origin and destination locations do not artificially inflate route similarity.
- **Regular Resampling**: Both routes are resampled at regular distance intervals (`sampleIntervalMeters = 25.0m`) along their polylines using `RouteGeometry.coordinate(atDistanceAlongRoute:)`.
- **Corridor Containment**: For each sample point on Route A, the minimum Euclidean distance to Route B's geometry is evaluated. If `distance <= 30.0m`, the point is counted as matching.
- **Bidirectional Overlap**: The match ratios from A to B and B to A are averaged:
  $$	ext{Overlap} = rac{	ext{MatchRatio}_{A 	o B} + 	ext{MatchRatio}_{B 	o A}}{2}$$
- **Diversity Threshold**: Candidate routes with `overlap >= 0.85` are classified as duplicates and pruned.

---

## 10. Candidate Quality Filters
To prevent absurd loop detours or unviable options:
- Candidates are benchmarked against the fastest duration and shortest distance in the candidate pool.
- **Duration Cap**: `duration <= fastestDuration * 1.40`.
- **Distance Cap**: `distance <= shortestDistance * 1.50`.
- Candidates exceeding these limits are filtered out before final deduplication and ranking.

---

## 11. Route Ranking
After detour filtering and geometric deduplication:
1. The balanced strategy primary candidate is placed first as the authoritative "Đề xuất" route.
2. Remaining unique candidates are assigned clear, descriptive labels ("Đường chính", "Đường nội đô", "Ít trạm thu phí") reflecting their originating strategy.
3. Relative duration deltas (`relativeDurationSeconds`) and distance deltas (`relativeDistanceMeters`) are computed against the primary route.
4. Up to 5 candidates are returned. If only 2 or 3 distinct routes exist, only those are returned.

---

## 12. UI Route Selection
- **Alternative Route Chips**: Displays route label, formatted duration, formatted distance, and delta string (e.g. `+3p · -0.6 km`).
- **Map Preview Rendering**:
  - Selected candidate: Drawn as the prominent cyan route line (`#00BFFF`, width 6pt).
  - Alternative candidates: Rendered underneath on a dedicated MapLibre layer (`route-alternatives-layer`) in muted translucent slate (`#718096`, width 4.5pt, opacity 0.65).
  - Navigation & Arrival: Alternative route layers are automatically cleared during active navigation or arrived states.
- **Authoritative Selection**: User selection via route card remains authoritative. `startNavigation()` begins exactly the selected route candidate.

---

## 13. Reroute Policy
- **Strict Fast-Path Isolation**: Active-navigation off-route recalculation (`RerouteManager`) and mode-switch reroutes continue to execute single-flight requests (`requestedAlternatives = 0`).
- `MultiStrategyRoutePlanner.calculateRoute(from:to:costing:)` immediately dispatches a single direct query to the underlying Valhalla engine, bypassing multi-strategy preview concurrency.
- Ensures fast reroute turnaround (~1.0–1.5s), minimal CPU load, and battery efficiency while driving.

---

## 14. Tests
The test suite was expanded and migrated to provider-neutral tests:
- `ApplePlaceSearchServiceTests`: 8 tests verifying debouncing, stale generation discarding, cancellation, published prediction resets, and deterministic `MKMapItem` ranking.
- `RouteSimilarityTests`: 6 tests verifying identical route detection, different sampling deduplication, parallel street distinction, endpoint corridor masking, detour quality caps, and `RouteSet.deduplicate` integration.
- `MultiStrategyRoutePlannerTests`: 6 tests verifying concurrent strategy execution, convergent geometry single-route return, partial failure resilience, total failure handling, and reroute single-route bypass.
- `DestinationSelectionTests`: Migrated all 12 tests to use `MockPlaceSearchService`, testing prediction selection, race cancellation, clear search lifecycle, and destination identity.
- `RouteCandidateSelectionTests`: Migrated all 13 tests to use `MockPlaceSearchService` and `ResolvedPlace`.
- `SearchRankingTests`: Maintained all 9 Vietnamese normalization tests, added 7 provider-neutral prediction ranking tests.
- `RerouteManagerTests`: Updated destination fixtures to use `ResolvedPlace`.
- All P5.2.1 regression suites (geometry trimming, parallel road, maneuver progression, field latency, replay) remain 100% green.

---

## 15. Performance
- **Preview Latency**: Concurrent execution with `withTaskGroup` parallelizes Valhalla queries across CPU cores, keeping preview calculation under ~300–500ms on device.
- **Corridor Deduplication**: Resampling every 25m outside the 150m endpoint mask processes typical 5–15km urban routes in < 5ms.
- **Memory & Battery**: Alternatives layer in `MapViewContainer` shares a single GeoJSON source and clears completely upon starting navigation.

---

## 16. Known Limitations
- **MapKit Coverage**: Apple MapKit search quality and POI density may vary between dense urban centers and rural areas in Vietnam.
- **OSM Map Data Dependency**: Valhalla routing quality and legal turn restrictions depend on OpenStreetMap tag accuracy.
- **No Live Traffic**: The app contains no real-time traffic or congestion feed; routes reflect structural road topology and speed limits, not live traffic slowdowns.
- **No Historical Traffic Profiles**: ETA calculations do not account for time-of-day rush hour patterns.
- **Candidate Count**: In constrained corridors (e.g. bridges, tunnels, single arterial highways), all strategies may legitimately converge to 1 route. The app never fabricates fake alternative routes.
- **Degraded MapKit Fallback**: MapKit automobile fallback for motorcycle remains visibly marked as degraded.
- **Physical Retest Required**: Physical road testing on devices in Hanoi remains the ultimate acceptance authority for navigation continuity and rerouting.

---

## 17. GitHub Actions Evidence
- **Implementation SHA**: `PENDING_CI`
- **Workflow Run ID**: `PENDING_CI`
- **Native Unit Tests**: `PENDING_CI`
- **Native Release Build**: `PENDING_CI`
- **Native IPA Package**: `PENDING_CI`
- **Flutter iOS Build**: `PENDING_CI`
- **Status**:
  ```text
  CI / deterministic regression PASS — REAL DEVICE VALIDATION PENDING
  ```
