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

## 24. P5.4.1 Verified CI Evidence
- **GitHub Actions Run ID**: `35624583595` (Branch `main`, Commit `d332dc6`)
- **Verified Jobs**:
  1. **Flutter iOS Job** (Job ID `106415680583`): **SUCCESS**
     - Step `4b. Run Flutter Unit Tests`: **47 / 47 PASS** (`00:29 +47: All tests passed!`)
     - Step `6. Build iOS Release (No CodeSign)`: **SUCCESS**
     - Step `7. Package Flutter IPA`: **SUCCESS**
     - Step `8. Upload Flutter IPA artifact`: **SUCCESS** (`esp32_nav_flutter_ios_ipa`)
  2. **Native iOS Swift/SwiftUI Job** (Job ID `106415680137`): **SUCCESS**
     - Step `6. Run Native Unit Tests`: **241 / 241 PASS** (0 failures across all 24 test suites)
     - Step `7. Build Native iOS App`: **SUCCESS**
     - Step `8. Package Native IPA`: **SUCCESS**
     - Step `9. Upload Native IPA artifact`: **SUCCESS** (`esp32_nav_native_ios_ipa`)
- **Zero Goong references** across entire codebase.
- **Zero paid Google Places API keys required**.
- **No infinite spinner guarantee**: Generation ownership, try/catch/finally, strict timeouts, and user cancel actions.

---

# P5.4.1.1 — Google Shortlink Exact-Pin Fidelity

## 25. Real-Device Failure & Root Cause
- **Real-Device Failure**: Pasting `https://maps.app.goo.gl/Ph7FpKY9xDfo7CBF8?g_st=ic` resolved to `Phố Nguyễn Siêu (21.03655, 105.85165)`, which was merely a camera/street coordinate rather than the true destination pin.
- **Root Cause**: The redirected browser URL contained the place name and camera center (`/@21.03655,105.85165,17z`), but no coordinates in the path or query. The parser immediately defaulted to independent text search (`SearchService.searchPlaces("Phố Nguyễn Siêu")`), returned the street coordinate, and marked it as `exactPin`.

## 26. Resolution Authority Order
The resolution pipeline now strictly adheres to the following hierarchy:
1. **Original Full URL Coordinates**: Direct `!3d/!4d`, `?q=`, `/place/lat,lon`, `/dir/.../lat,lon`.
2. **Redirected Final URL Coordinates**: Same extraction on redirected URL.
3. **Canonical Link from HTML**: Parses `<link rel="canonical" href="...">` supporting either attribute order (`rel` before `href` or `href` before `rel`) and HTML entity unescaping (`&amp;` -> `&`).
4. **OG:URL from HTML**: Parses `<meta property="og:url" content="...">` supporting attribute-order variations.
5. **Identity-Bound Destination Metadata**: Target pin metadata in HTML (not generic or random numbers).
6. **Named Fallback Candidate**: Proposes candidate via independent search with `requiresConfirmation = true` (NEVER marked as exact).
7. **Camera Viewport Center**: Marked as `approximate` with `requiresConfirmation = true`.
8. **Unresolved**: Prompts retry or manual search; never falls back to raw URL search.

## 27. Coordinate Distinction & Confirmation Behavior
- **Explicit Separation**:
  - `exactDestinationCoordinate`: Populated ONLY when true Google pin coordinate is identified.
  - `cameraCoordinate`: Viewport `@lat,lon` (never promoted to exact).
  - `independentSearchCandidateCoordinate`: Geocoder proposal when only title is available.
- **`targetCoordinate` Safety**: Returns only `exactDestinationCoordinate`. Unverified search candidates are never automatically committed.
- **Confirmation Dialog**: When an unverified candidate is returned, the app displays:
  - Title: *"Có thể là địa điểm này"*
  - Subtitle: *"Không thể xác nhận chính xác ghim từ liên kết Google Maps. Hãy kiểm tra vị trí trước khi chỉ đường."*
  - Actions: *"Dùng vị trí này"* (commits only upon tap) and *"Hủy"*.
- **Debug Diagnostics**: In `kDebugMode`, a sanitized diagnostic string (recording host, hops, canonical presence, ogUrl presence, identity presence, resolution source, confidence) can be copied to the clipboard via *"Sao chép chẩn đoán"*.

## 28. Fidelity Regression Tests
- **`mobile_app/test/google_link_resolution_test.dart`** (expanded to 12 tests):
  - Section 21 & 22 Failure Model: Final URL has no pin, camera `@21.03655,105.85165`, HTML canonical has true target pin `!3d21.03698!4d105.85234` -> resolves to `canonical_url` exact pin; `SearchService` call count is 0.
  - Section 23: `og:url` target pin extraction.
  - Section 24: Title-only link without exact pin sets `confidence = resolvedByIndependentSearch`, `exactCoordinate = null`, `requiresConfirmation = true`.
  - Section 25: Independent search candidate disagreeing with camera requires confirmation and leaves `exactDestinationCoordinate = null`.
  - Section 26: Exact pin completely ignores independent search.
  - Section 27: Camera viewport `@lat,lon` never becomes exact pin.
  - HTML entity decoding and attribute-order resilience.
- **Flutter Test Suite**: **54 / 54 PASS** (0 failures).

## 29. P5.4.1.1 Verified CI Evidence
- **GitHub Actions Run ID**: `35627551826` (Branch `main`, Commit `439a080`)
- **Verified Jobs**:
  1. **Flutter iOS Job** (Job ID `106425528078`): **SUCCESS**
     - Step `4b. Run Flutter Unit Tests`: **54 / 54 PASS** (`00:38 +54: All tests passed!`)
     - Step `6. Build iOS Release (No CodeSign)`: **SUCCESS**
     - Step `7. Package Flutter IPA`: **SUCCESS**
     - Step `8. Upload Flutter IPA artifact`: **SUCCESS** (`esp32_nav_flutter_ios_ipa`)
  2. **Native iOS Swift/SwiftUI Job** (Job ID `106425528242`): **SUCCESS**
     - Step `6. Run Native Unit Tests`: **241 / 241 PASS** (0 failures across all 24 test suites)
     - Step `7. Build Native iOS App`: **SUCCESS**
     - Step `8. Package Native IPA`: **SUCCESS**
     - Step `9. Upload Native IPA artifact`: **SUCCESS** (`esp32_nav_native_ios_ipa`)
- **Zero Goong references** across entire codebase.
- **Zero paid Google Places API keys required**.
- **Exact Shortlink Fidelity**: Verified canonical and og:url extraction priority over camera `@` coordinates or unverified independent search candidates.

---

# PART IX — P5.4.1.2: GOOGLE SHORTLINK PAYLOAD FIDELITY & IPHONE THERMAL REDUCTION

## 30. Google Maps Shortlink Payload Fidelity (`GoogleMapsTargetMetadataParser`)
- **Real-Device Finding**: Shortlinks such as `maps.app.goo.gl/22CQo4AbHWY1MQcJA` embed target place coordinates within embedded application state / structured JSON-like script payloads rather than in URL query parameters, canonical tags, or og:url.
- **Identity-Bound Extraction Principle**:
  - Coordinate extraction from HTML is strictly bound to place identity (never guess the first coordinate in HTML).
  - Target place identity is discovered using strict priority:
    1. `ChIJ...` (Google Place ID)
    2. `CID` (Customer ID e.g. `cid=...`, `data-cid=...`)
    3. `0x...:0x...` (Hex place ID pair)
    4. Canonical target URL identity / slug
  - The parser isolates the enclosing structured data block (JSON object, array, script, or element tag) containing the identity token and extracts coordinates closest to that token.
  - If no identity can be bound, the parser returns `null`, falling back safely to camera approximate or unresolved with explicit confirmation required.
- **Updated Resolution Authority Hierarchy**:
  1. `original_url`: Explicit target coordinate in original URL
  2. `redirected_url`: Explicit target coordinate in redirected URL
  3. `canonical_url`: Explicit target coordinate in canonical URL tag
  4. `og_url`: Explicit target coordinate in og:url meta tag
  5. `identity_bound_payload`: Identity-bound structured target metadata from HTML
  6. `verified_place_identity`: Verified place-identity match
  7. `independent_search`: Independent search candidate (requires user confirmation)
  8. `camera_approximate`: Viewport camera center (approximate, requires confirmation)
  9. `unresolved`: Link cannot be verified
- **Sanitized Diagnostics**:
  - In `kDebugMode`, sanitized diagnostic telemetry captures:
    `host`, `hops`, `finalExact`, `canonical`, `canonicalExact`, `og`, `ogExact`, `chijPresent`, `cidPresent`, `hexPresent`, `identityBoundFound`, `resolutionSource`, `confidence`, `requiresConfirmation`.
  - Full private URLs are never logged in Release builds.

## 31. iPhone Thermal & Battery Reduction Architecture
- **Demand-Based Map Streaming (`hasEspDisplayConsumer`)**:
  - `hasEspDisplayConsumer` is `true` only when a WebSocket client is connected to port 8080 or a TCP socket is active.
  - When `!hasEspDisplayConsumer`, the headless JPEG rendering loop is completely halted: **effective stream FPS is strictly 0.0**, rendering 0 frames.
  - Unconditional `startStreaming()` in `MapScreen.initState()` removed; streaming lifecycle is demand-driven.
- **Stream State Machine (`EspMapStreamState`)**:
  - `idle`: Streaming inactive.
  - `waitingForConsumer`: Stream requested but no display connected (0 FPS, 0 CPU).
  - `streamingForeground`: ESP connected while app foreground (10 FPS default, adapted to thermal state).
  - `streamingBackground`: ESP connected while screen locked / app background (1-2 FPS rate).
- **Reduced Foreground & Background Stream Rates**:
  - Foreground stream rate reduced from 14 FPS to **10 FPS** max.
  - Background map imagery reduced to **1–2 FPS** while preserving real-time navigation telemetry packets.
- **Map Frame Dirty Check**:
  - Skips re-drawing Canvas, skips `toImage`, skips raw RGBA decoding, and skips JPEG quality 65 encoding if:
    - Vehicle movement < 2.5 meters AND
    - Heading delta < 2.5° AND
    - Route polyline, theme, and zoom remain identical.
  - Reuses the previous JPEG frame directly without CPU/GPU thrashing.
- **Route Polyline Redraw Elimination on GPS Ticks**:
  - `MapScreen.navManager.onLocationChanged` no longer clears or rebuilds route polylines on MapLibre.
  - `_updateRouteOnMap()` caches `_lastRenderedRouteKey` and exits immediately if route geometry has not changed. Polyline rebuilds occur only when a new route is loaded or rerouting commits.
- **Throttled Camera Animations**:
  - Camera animations bound to an **8–10 Hz display cadence** (min 110ms interval).
  - Rapid GPS updates during active animations are coalesced; the latest coordinate wins on animation completion.
- **Demand-Driven Background Keep-Alive**:
  - Silent audio loop keep-alive is disabled in foreground.
  - Enabled only when the app enters background with an active required stream consumer or active navigation, and disabled immediately upon returning to foreground.
- **Thermal & Low-Power Adaptation**:
  - Native iOS `ProcessInfo.processInfo.thermalState` and `isLowPowerModeEnabled` exposed via `com.ysiduc.esp32_nav/location` MethodChannel.
  - Streaming adapts dynamically:
    - `nominal`: 10 FPS
    - `fair`: 7 FPS
    - `serious`: 3–5 FPS (capped at 4 FPS)
    - `critical`: 0 FPS (pauses visual map streaming; core navigation telemetry continues)
    - Low Power Mode: clamped to 5 FPS max.
- **Bounded Tile Prefetching**:
  - Tile prefetching bounded to at most 6 concurrent pending requests.

## 32. Deterministic Testing & CI Hygiene
- **Removed Live Network Test from CI**:
  - `mobile_app/test/live_search_test.dart` (which disabled TLS certificate validation and made external HTTP calls) moved to `mobile_app/tool/manual_live_search_test.dart`.
- **New Shortlink Variant Unit Tests (`test/google_link_resolution_test.dart`)**:
  - URL Style A: Canonical/og contains `!3d/!4d` -> resolves exact.
  - URL Style B: Redirect has `@camera` only, HTML has identity-bound target lat/lon -> resolves exact via `identity_bound_payload`, NOT camera.
  - Decoy Test: HTML contains camera A, target B, decoys C/D/E -> extracts B, never A/C/D/E.
  - No-Identity Test: HTML contains multiple coordinates but no target identity binding -> rejects random selection, returns approximate/unresolved requiring confirmation.
  - Diagnostics Test: Validates sanitized debug fields without leaking URLs.
- **New Thermal & Battery Tests (`test/stream_thermal_test.dart`)**:
  - Section 47: No consumer -> 0 FPS, render count == 0.
  - Section 48: Navigating without map consumer -> telemetry continues, 0 JPEG renders.
  - Section 49: Connected ESP foreground stream capped at 10 FPS, background 1-2 FPS.
  - Section 50: Serious thermal state drops FPS to 3-5, critical pauses visual stream while telemetry continues.
  - Section 51 & 52: 20 GPS samples cause 0 route rebuilds, reroute causes exactly 1 rebuild.
  - Section 53: 30 GPS callbacks in 1 second bounded <= 10 camera updates.
- **Flutter Test Suite**: **64 / 64 PASS** (0 failures).

## 33. Verified CI Evidence (P5.4.1.2)
- **Workflow Run ID**: `35632847097` (https://github.com/ysiduc/esp32-ios-nav/actions/runs/35632847097)
- **Git Commit**: `d8cbbe0d859b7201c775d7e597143997232230ef`
- **Compile Flutter iOS IPA** (Job ID: `106442980305`):
  - Unit Tests: **64 / 64 PASS** (0 failures)
  - iOS Release (No CodeSign): **SUCCESS**
  - Flutter IPA Package & Upload: **SUCCESS** (`esp32_nav_flutter_ios_ipa`)
- **Compile Native iOS Swift/SwiftUI** (Job ID: `106442980327`):
  - Native Unit Tests: **241 / 241 PASS** (0 failures, 24 test suites)
  - Native Release Build: **SUCCESS**
  - Native IPA Package & Upload: **SUCCESS** (`esp32_nav_native_ios_ipa`)
- **Final Acceptance**: P5.4.1.2 Google Maps shortlink structured payload fidelity and iPhone thermal & battery load reduction verified.

---

# PART X — P5.4.1.3: RESTORE SMOOTH ESP JPEG STREAMING, REMOVE CUSTOM VECTOR MAP RENDERER & LIQUID GLASS UI

## 34. Restored Smooth Streaming & Transport Hierarchy
- **BLE Consumer Fix**: `hasEspDisplayConsumer` previously ignored BLE-only connections, causing the stream loop to stall when Wi-Fi was unavailable. Fixed by checking `activeJpegTransport != EspJpegTransport.none`, explicitly enabling BLE JPEG streaming.
- **Explicit Transport Hierarchy (`EspJpegTransport`)**:
  - `wifiWebSocket` (IP 172.20.10.1:8080 Hotspot)
  - `wifiTcp` (Persistent TCP socket direct to SoftAP)
  - `ble` (Bluetooth Low Energy chunked transfer)
  - `none`
- **Transport-Specific Frame Rates**:
  - Wi-Fi WebSocket: **14 FPS** foreground (restoring smooth display on TFT), **6 FPS** background (nominal).
  - Wi-Fi TCP: **12–14 FPS** foreground, **5–6 FPS** background.
  - BLE: **adaptive 2–5 FPS** foreground based on measured chunk transfer latency (`lastBleTransferDurationMs`), **2–3 FPS** background.
  - Gradual thermal scaling: `fair` ~80% (11 / 5 FPS), `serious` ~50% (7 / 3 FPS), `critical` minimal/pause (1 / 0 FPS).
  - Low Power Mode: clamps to <= 8 FPS foreground / <= 4 FPS background.
- **ACK-Driven Pacing & Backpressure**:
  - Wi-Fi WebSocket pacing relies on ESP32 ACK ('K') receipt before dispatching the next frame.
  - Strict 1-in-flight backpressure check occurs *before* rendering and JPEG encoding. If the transport is busy or unacknowledged, ticks are dropped with latest-frame-wins semantics, eliminating render queues and device heat.

## 35. Removal of Custom Vector/Canvas Map Engine & Unified Raster Pipeline
- **Removed Legacy Engines**:
  - Removed manual Flutter Canvas path rendering (`_drawRealMapCanvas`).
  - Removed pure CPU software tile composer (`_renderCpuMapFrame`).
  - Removed tile caching math, synthetic grid fallback, and manual tile prefetching loops.
- **Unified Raster Architecture (`EspMapFrameRenderer`)**:
  - **Foreground source**: Live rendered map snapshot via `mapSnapshotProvider` (hooked to MapLibre's `RepaintBoundary`).
  - **Background source**: Native iOS `MKMapSnapshotter` via MethodChannel (`renderMapSnapshot`).
  - **Snapshot Caching**: Caches raster snapshot and refreshes only when vehicle moves >= 10m, heading changes >= 15°, or route/theme changes.
  - **Intermediate Frames**: Reuses cached snapshot with lightweight overlay (authoritative remaining route polyline + blue vehicle arrow puck) or translation/rotation, delivering smooth TFT motion up to configured FPS without expensive tile re-fetches.
  - **Adaptive JPEG Quality**: Quality 70 on Wi-Fi (crisp HD TFT) and Quality 45 on BLE (~2-3 KB payload for fast transfer).

## 36. Centralized Background Keep-Alive (`BackgroundNavigationCoordinator`)
- Consolidated background navigation and audio keep-alive ownership into a single coordinator.
- Eliminates duplicated or orphaned calls across `BleService`, `EspStreamService`, and `NavigationManager`.
- Keep-alive is strictly active only when `(isNavigating || isEspStreamRequired) && isBackground`.

## 37. Liquid Glass UI Visual Language
- **`LiquidGlassContainer` & `LiquidGlassButton`** (`mobile_app/lib/widgets/liquid_glass.dart`):
  - Translucent frosted glass aesthetic using `BackdropFilter` (blur sigma 20), semi-transparent gradient, thin highlight border (white 0.35 light / 0.18 dark), and soft layered shadow.
  - Accessibility: respects `MediaQuery.disableAnimations` (reduced motion bypasses GPU `BackdropFilter` filter).
  - Buttons feature spring scale feedback (0.96) and selected-state glowing blue accents.
- **Modernized Map Screen Controls** (`mobile_app/lib/screens/map_screen.dart`):
  - **Top-Left Menu & Weather Group**: Combined into a single cohesive Liquid Glass capsule `[ Menu | 27° Weather ]`.
  - **Right-Side Control Stack**: Vertical Liquid Glass stack housing Layers, Compass, and Transport Mode (Motorcycle/Car) with subtle separators, accompanied by a floating circular glass Location centering button.
  - **Bottom Search Capsule**: Sleek frosted glass capsule with magnifying glass, placeholder, voice/mic affordance, and avatar.
  - **DEBUG Stream Telemetry Overlay**: Floating glass card (toggled by tapping the weather pill) displaying live transport, output FPS, render FPS, snapshot age, JPEG size, ACK latency, and thermal state.

## 38. Deterministic Test Suite
- Unit & widget test count: **75 / 75 PASS** (0 failures, 0 socket conflicts).
- Added `test/liquid_glass_test.dart`: verifies glass container backdrop, dark mode adaptation, reduced motion bypass, button taps, and capsule layouts.
- Updated `test/stream_thermal_test.dart`: covers BLE-only activation, Wi-Fi 14 FPS restoration, background 5-6 FPS, gradual thermal reduction, BLE throughput adaptation, backpressure, and snapshot cache reuse.

## 39. Verified CI Evidence (P5.4.1.3)
- **Workflow Run ID**: `35636080190` (https://github.com/ysiduc/esp32-ios-nav/actions/runs/35636080190)
- **Git Commit**: `9b0b04506181973bfe5c2e100644a2647b461099`
- **Compile Flutter iOS IPA** (Job ID: `106453702161`):
  - Unit & Widget Tests: **75 / 75 PASS** (0 failures, 0 socket conflicts)
  - iOS Release (No CodeSign): **SUCCESS**
  - Flutter IPA Package & Upload: **SUCCESS** (`esp32_nav_flutter_ios_ipa`)
- **Compile Native iOS Swift/SwiftUI** (Job ID: `106453701721`):
  - Native Unit Tests: **241 / 241 PASS** (0 failures, 24 test suites)
  - Native Release Build: **SUCCESS**
  - Native IPA Package & Upload: **SUCCESS** (`esp32_nav_native_ios_ipa`)
- **Final Acceptance**: P5.4.1.3 smooth ESP JPEG streaming restoration across all transports, removal of custom vector map renderer in favor of the unified raster snapshot pipeline, centralized background keep-alive coordination, and modern Liquid Glass UI redesign verified.
