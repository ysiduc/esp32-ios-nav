# P5.4 Search Precision & Google Maps Links

## 1. Field/User Symptoms
During actual field navigation and daily use, two major issues were observed by users:
1. **Manual typed search failed to locate intended destinations**:
   - Searching for specific addresses such as `96 Định Công` resulted in confusing fake house destinations or unrelated places outranking the actual location.
   - Searching for landmarks with slight typos (e.g., `benh vien bach maii`, `nguyen traii`) failed completely or yielded distant irrelevant items.
   - Searching for places in other provinces (e.g. `Sân bay Cát Bi Hải Phòng` while the user was in Hanoi) was suppressed by aggressive proximity penalties that favored weak nearby POIs.
   - Pressing search submit automatically chose the first result (`results.first`), forcing navigation to an unintended location before the user could review candidates.
2. **Google Maps shared links resolved to incorrect positions**:
   - Links containing a camera center `@lat,lon` (e.g., `/place/SomePlace/@21.0169,105.7836`) resolved to the camera center rather than the actual POI or pin coordinate.
   - Directions links (`/dir/origin/destination`) sometimes resolved to the route origin rather than the intended destination.
   - Shortlinks (`maps.app.goo.gl`) could not be tested deterministically in CI without hitting Google servers.
   - Exact pin coordinates were occasionally replaced by reverse-geocoded coordinates, drifting the destination pin.

## 2. Existing Search Pipeline Problems
Prior to P5.4, the search pipeline suffered from structural design flaws:
- **Synthetic House-Number Fabrication**: When an exact house number was not found, the app picked a street segment, synthesized a fake title (e.g., `96 Định Công`), and placed it at an arbitrary interpolated position along the street centerline (`_estimateStreetPosition`). This misled users into believing an exact building coordinate was found.
- **Blind Merging & Uncalibrated Scoring**: Providers were queried and blindly merged into a single list with hardcoded landmark lists immediately injected at the top. Distance penalty overwhelmed text relevance, suppressing cross-city queries.
- **Race Hazards**: Fast keystrokes or multiple pasted links lacked generation counters (`queryGeneration`), allowing slow out-of-order network responses to overwrite the latest results.
- **Single Coordinate Fallback**: Google Maps parser treated the first latitude/longitude found in the URL (frequently the `@` camera viewport) as the final destination.

## 3. Search Query Intent
A dedicated query classifier (`SearchQueryIntent`) was created:
```dart
enum SearchQueryIntentType {
  coordinate,
  houseAddress,
  street,
  poi,
  districtOrCity,
  general,
}
```
- **`coordinate`**: Detects raw decimal latitude/longitude strings (e.g., `21.0285, 105.8542`).
- **`houseAddress`**: Extracts the house number and street name (e.g., `96 Định Công`, `Số 157 Nguyễn Cảnh Dị`).
- **`street`**: Identifies street queries starting with or containing `phố`, `đường`, `đ.`, `ngõ`, `ngách`.
- **`poi`**: Identifies landmarks, hospitals, universities, stations, malls, and distinctive names (`Bạch Mai`, `Bách khoa`, `Keangnam`, `Kim Đồng`, `Giáp Bát`).
- **`districtOrCity`**: Identifies administrative regions (`Hoàng Mai`, `Hà Nội`, `Hải Phòng`).

## 4. MapKit Flutter Bridge
For iOS, Apple MapKit is leveraged as the primary search and completer engine via a native bridge:
- **Native Implementation**: `MapKitSearchBridge.swift` embedded directly in `mobile_app/ios/Runner/AppDelegate.swift`.
- **Method Channel**: `com.ysiduc.esp32_nav/mapkit_search`.
- **Supported Methods**:
  - `autocomplete(query, userLat?, userLon?)`: Uses `MKLocalSearchCompleter` with region bias.
  - `resolve(completionID)`: Resolves a completion item into a coordinate and placemark using `MKLocalSearch`.
  - `search(query, userLat?, userLon?)`: Direct search with `MKLocalSearch`.
- **Provider-Neutral JSON**: Returns dictionary containing `id`, `title`, `subtitle`, `latitude`, `longitude`, and `precision`.
- **Dart Client**: `MapKitSearchService` wraps the channel with support for mock injection in test environments.

## 5. Provider Ranking
The pure ranking engine `SearchRanker` was created to separate scoring logic from network orchestration:
1. **Text / Identity Match (Primary - up to 100 pts)**:
   - Full string match, prefix match, and token overlap.
2. **Administrative Match (Secondary - up to 25 pts)**:
   - District and city overlap.
3. **Precision Bonus**:
   - `exactAddress`: +25 pts
   - `poi` / `building`: +20 pts
   - `street`: +10 pts
   - `approximate`: 0 pts
4. **Provider Confidence (Tertiary)**:
   - `apple_mapkit`: +30 pts
   - `google_link_exact`: +35 pts
   - `maptiler`: +20 pts
   - `photon`: +15 pts
   - `local` (offline fallback): +10 pts
   - `nominatim`: +8 pts
5. **Distance Weight (Tie-breaker only - up to 15 pts)**:
   - Decays smoothly over 150 km. High text relevance for distant locations (e.g. `Sân bay Cát Bi Hải Phòng`) comfortably outranks weak nearby POIs.

## 6. House-Number Precision
- **Synthetic coordinate fabrication is completely removed**: `_estimateStreetPosition` and the synthetic house insertion logic have been deleted.
- When query intent is `houseAddress`, candidates must contain explicit evidence of the house number (`cand.precision == PlacePrecision.exactAddress` or title/address contains the house number token).
- If no provider returns the exact house number:
  - The app returns the street feature as `PlacePrecision.street` (e.g., `Phố Định Công, Hoàng Mai, Hà Nội`), **never** `96 Định Công` at fake street-center coordinates.

## 7. Fuzzy Vietnamese Search
Bounded fuzzy matching is implemented in `SearchRanker`:
- **Diacritics & Token Normalization**: Preserves `đ` / `Đ` conversion to `d`, strips accents, normalizes abbreviations (`bv` -> `benh vien`, `dh`/`đh` -> `dai hoc`, `bx` -> `ben xe`, `p.` -> `phuong`, `q.` -> `quan`, `đ.` -> `duong`).
- **Bounded Levenshtein & Length Guard**:
  - Tokens with length < 3 require exact match (prevents false positive noise).
  - Tokens with length $\ge 3$ support 1-character typo edit distance (e.g., `maii` -> `mai`, `traii` -> `trai`, `khoaa` -> `khoa`).
  - Longer tokens ($\ge 7$) support up to 2 edit distances.
  - Prefix matching supported for tokens $\ge 4$ characters.

## 8. Search Race Safety
- **Search Query Generation (`_queryGeneration`)**: Every search incremented a monotonic counter. When asynchronous responses return from MapKit, Photon, or MapTiler, the generation is checked against `_queryGeneration`. Stale responses from earlier keystrokes are discarded.
- **Link Resolution Generation (`_linkResolutionGeneration`)**: Paste-link handling tracks resolution generations. If Link A resolves after Link B was pasted, Link A is discarded.

## 9. Google Maps URL Semantics
`GoogleMapsParser` respects an authoritative extraction hierarchy:
1. **Explicit Protobuf POI Coordinates**: `!3dLAT!4dLON` or `!4dLON!3dLAT` -> `GoogleMapsResolutionConfidence.exactPin`.
2. **Explicit Query Parameters**: `?q=LAT,LON`, `?destination=LAT,LON`, `?daddr=LAT,LON` -> `GoogleMapsResolutionConfidence.exactPin` / `exactDestination`.
3. **Explicit Dropped Pin Path**: `/place/LAT,LON` -> `GoogleMapsResolutionConfidence.exactPin`.
4. **Explicit Search Coordinate Path**: `/search/LAT,LON` -> `GoogleMapsResolutionConfidence.exactPin`.
5. **Directions Destination Path**: `/dir/origin/destination/...` -> Destination coordinate only (never origin).
6. **High-Confidence Marker Pin**: Staticmap `markers=LAT,LON`.
7. **Place Name Resolution**: High-quality search resolution via `_searchService.searchPlaces`.
8. **Camera Viewport `@`**: Fallback ONLY for pure coordinate/viewport links or when named place search fails, marked as `GoogleMapsResolutionConfidence.approximate`.

## 10. Camera Center vs Destination
- Google Maps URLs commonly format URLs as `/place/PlaceName/@21.000000,105.800000,17z/data=...!3d21.001234!4d105.803456`.
- The `@21.000000,105.800000` is the camera viewport center, while `!3d21.001234!4d105.803456` is the actual POI coordinate.
- The parser strictly isolates `cameraCoord` from `exactCoord`. The `@` coordinates are **never** treated as the exact POI coordinate.

## 11. Shortlink Resolution
- `GoogleMapsRedirectResolver` interface created with default `HttpGoogleMapsRedirectResolver` and testable `MockGoogleMapsRedirectResolver`.
- Deterministic unit tests verify shortlink resolution (`maps.app.goo.gl`, `goo.gl/maps`) without making live network requests in CI.

## 12. Confidence Model
```dart
enum GoogleMapsResolutionConfidence {
  exactPin,
  exactDestination,
  resolvedPlace,
  approximate,
  unresolved,
}
```
Exposed via `GoogleMapsResolvedLink` to ensure caller knows the provenance and reliability of the resolved coordinate.

## 13. UI Confirmation
- **Exact Destination Autoselect Policy**:
  - In `_onSearchSubmitted()`, generic submit no longer automatically selects `results.first`. Results remain visible for the user to choose.
  - Auto-select only occurs for unambiguous inputs: single coordinate input (`PlacePrecision.coordinate`) or exact destination pin (`source == 'google_link_exact'`).
- **Approximate Link Confirmation**:
  - When a Google Maps link resolves with `confidence == GoogleMapsResolutionConfidence.approximate`, the app displays an amber warning banner:
    `"Vị trí này được ước lượng từ liên kết. Kiểm tra ghim trước khi dẫn đường."`
  - Drops the marker and opens the Place Details preview, but **never** starts navigation automatically until the user reviews and taps "Chỉ đường".
- **Visual Precision Badges**:
  - Search results display color-coded precision badges:
    - `Địa chỉ` (Blue - `exactAddress`)
    - `Địa điểm` (Green - `poi`, `building`)
    - `Đường` (Orange - `street`)
    - `Khu vực` (Purple - `district`, `city`)
    - `Ước lượng` (Amber - `approximate`)
    - `Tọa độ` (Grey - `coordinate`)

## 14. Tests
All tests run deterministically and pass locally:
1. `mobile_app/test/search_ranker_test.dart`:
   - Query intent classification (coordinate, houseAddress, street, poi, districtOrCity).
   - Exact address test: `96 Định Công` ranks exact house candidate over street and unrelated POI.
   - No exact address test: verifies `Phố Định Công` is returned as `street` precision without fabricating a fake house.
   - Typo tolerance: `benh vien bach maii` -> `Bệnh viện Bạch Mai`.
   - Far-but-exact test: `Sân bay Cát Bi Hải Phòng` outranks nearby weak Hanoi POIs.
   - Deduplication: Merges candidate places within 30m with matching normalized titles.
2. `mobile_app/test/google_maps_parser_test.dart`:
   - Section 35 Camera-center regression: verifies `!3d/!4d` wins over `@` camera center.
   - Section 36 No-exact-coord test: named POI with only `@` marks `confidence: approximate` and does not treat `@` as exact.
   - Section 37 Directions link test: verifies `/dir/origin/destination` resolves destination (never origin or camera).
   - Section 38 Mock shortlink test: deterministic resolution via `MockGoogleMapsRedirectResolver`.
   - Dropped pin, query parameter, Vietnamese DMS coordinate parsing, and reverse geocode coordinate immutability.
3. `mobile_app/test/search_service_precision_test.dart`:
   - Precision tagging across models and JSON serialization.
   - MapKitSearchService bridge mapping.
4. `mobile_app/test/search_generation_test.dart`:
   - Cancellation generation and stale network resolution rejection.

## 15. CI Evidence
- **GitHub Actions Run ID**: `35619674919` (Branch `main`, Commit `8a9cff5`)
- **Verified Jobs**:
  1. **Flutter iOS Job** (Job ID `106399293710`): **SUCCESS**
     - Step `4b. Run Flutter Unit Tests`: **38 / 38 PASS** (`00:32 +38: All tests passed!`)
     - Step `6. Build iOS Release (No CodeSign)`: **SUCCESS**
     - Step `7. Package Flutter IPA`: **SUCCESS**
     - Step `8. Upload Flutter IPA artifact`: **SUCCESS** (`esp32_nav_flutter_ios_ipa`)
  2. **Native iOS Swift/SwiftUI Job** (Job ID `106399293991`): **SUCCESS**
     - Step `6. Run Native Unit Tests`: **241 / 241 PASS** (0 failures across all 24 test suites)
     - Step `7. Build Native iOS App`: **SUCCESS**
     - Step `8. Package Native IPA`: **SUCCESS**
     - Step `9. Upload Native IPA artifact`: **SUCCESS** (`esp32_nav_native_ios_ipa`)
- **Zero Goong references** across entire codebase.
- **Zero paid Google Places API keys required**.

## 16. Known Limitations
- Without Google Places API, not every Google Maps POI identity can be reproduced exactly from place ID alone.
- Shared links containing explicit pin/destination coordinates (`!3d/!4d`, `/place/lat,lon`, `?q=lat,lon`) are matched exactly.
- Links exposing only place names require independent MapKit/OSM search and therefore can differ from Google's proprietary POI database.
- Search quality ultimately depends on available MapKit / OSM / MapTiler data.

---

# P5.4.1 — Search Latency Correction & Non-Stuck Google Maps Resolution

## 17. Search Latency Correction
- **Debounce Optimization**: Reduced autocomplete debounce timer from 450ms to **220ms**.
- **Prefix Reuse & Cache**: In-memory query cache (`Map<SearchCacheKey, CachedSearchResults>`) with 3-minute TTL. Prefix matching (`findPrefixMatches`) returns instant candidates (<30ms) while background network requests run.
- **Non-Blocking Suggestions**: Typing keeps previously visible suggestions on screen rather than blanking the list. A subtle inline progress indicator (`_isAutocompleteRefreshing`) informs the user without replacing content with a blocking modal spinner.
- **Search Generation**: `_searchGeneration` counter increments on every keystroke. Stale async network responses from earlier keystrokes are automatically discarded (`generation != _searchGeneration`).
- **Two Search Execution Modes**:
  - `SearchExecutionMode.autocomplete`: Single normalized query per provider, short bounded timeout (~1.2s), no query fan-out during typing.
  - `SearchExecutionMode.submitted`: Bounded query variant expansion on explicit submit.

## 18. Progressive Provider Aggregation
- **Eliminated `Future.wait` All-Or-Nothing Architecture**: Provider tasks now stream updates progressively via `onUpdate(results, isFinal)` instead of holding fast providers hostage until the slowest finishes.
- **Primary Provider First**: MapKit (on iOS) or MapTiler is queried as primary. When primary returns (<350ms), results are ranked and published to UI immediately.
- **Secondary Provider Enrichment**: Photon runs in parallel. If/when secondary results arrive, they are merged, deduplicated, and published only if the search generation is still current.
- **Fast Reverse Geocode Policy**: MapTiler (1.5s) with Photon (1.5s fallback). Public Nominatim is completely removed from the interactive critical path.

## 19. Google Link Timeout & Cancellation
- **Dedicated Controller**: `GoogleLinkResolutionController` encapsulates link lifecycle, generation ownership, and timeout budgets.
- **Global 5s Budget**: Link resolution is bounded by a strict 5-second timeout (`.timeout(const Duration(seconds: 5))`).
- **Explicit Cancellation**: Provides a user-facing "Hủy" (Cancel) button on both the main map banner and search sheet, incrementing generation and discarding in-flight tasks.
- **No Cascading URL Search**: If link parsing fails or times out, the app shows a non-blocking notification with a "Thử lại" button. It **never** feeds the raw unparsed URL into normal search.

## 20. Loading-State Lifecycle
- **Strict `finally` Guarantees**: All resolution paths execute within a `try ... catch ... finally` block ensuring `_isResolvingGoogleLink` is unconditionally reset to `false` when finished, cancelled, or timed out.
- **Distinct State Variables**: Separated `_isAutocompleteRefreshing` (subtle autocomplete progress) from `_isResolvingGoogleLink` (Google Maps link resolution).

## 21. Redirect Resolver Bounds
- **Bounded Hops**: `HttpGoogleMapsRedirectResolver` strictly limits redirects to a maximum of 5 hops.
- **Per-Hop Timeout**: Explicit 1.5s timeout on connect and response for every hop.
- **Redirect Loop Protection**: Visited URL set (`visited.add(url)`) aborts immediately if cycles occur (`A -> B -> A`).
- **Guaranteed Cleanup**: `HttpClient.close(force: true)` executes in a `finally` block preventing socket leaks.
- **Fast Abort on Coordinate Headers**: Inspects `location` headers during redirects; if canonical coordinates are present, redirects terminate immediately without downloading the full HTML body.

## 22. Exact Pin Fast Path
- **Zero-Network Local Parse**: Full Google Maps URLs with `!3d/!4d`, `/place/lat,lon`, `?q=lat,lon`, or `/dir/.../lat,lon` are parsed locally in <1ms without any network requests.
- **Non-Blocking Exact Return**: Exact coordinates are packaged into a `MapPlace` with `PlacePrecision.coordinate` and returned immediately without blocking on reverse-geocoding.

## 23. Latency Regression Tests
- **`mobile_app/test/search_latency_test.dart`** (4 tests):
  - Primary result SLA: verifies primary provider returns fast and publishes before secondary completes.
  - Slow secondary provider: verifies Photon timeout does not block MapKit/MapTiler suggestions or cause global search failure.
  - Stale query race: verifies late slow responses from earlier queries are discarded when newer queries complete.
  - In-memory cache & prefix reuse: verifies instant cache retrieval (<5ms) and prefix candidate filtering (<30ms).
- **`mobile_app/test/google_link_resolution_test.dart`** (5 tests):
  - Local fast path: verifies full URL with `!3d/!4d` executes 0 HTTP redirect requests.
  - Shortlink success: verifies redirect resolves to exact coordinate without reverse geocoding dependency.
  - Authoritative coordinate detection: verifies pattern matching for exact coordinate markers.
  - Generation superseding: verifies rapid second paste supersedes slow initial link.
  - Lifecycle & invariant safety: verifies `isLoading == false` across success, failure, timeout, and cancellation.
- **Overall Flutter Test Suite**: **47 / 47 PASS** (0 failures).
