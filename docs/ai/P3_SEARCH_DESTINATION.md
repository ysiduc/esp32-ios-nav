# P3 — Search & Destination Pipeline

## 1. Objective

Make the search pipeline reliable under rapid user input, network variability, and concurrent requests by introducing:

- An authoritative `searchQuery` state owned by `NavigationViewModel`
- A correct Goong session token lifecycle (one token per autocomplete session + detail)
- Generation-based stale-result protection for both autocomplete and Place Detail
- A `GoongPlacesClientProtocol` enabling deterministic unit testing without a live Goong API key
- A pure `SearchRanking` helper with Vietnamese-aware normalization
- Removal of the hardcoded API key from committed source

## 2. Baseline

- P0/P1/P2 ACCEPTED  
- Baseline commit: `dced5f1c2076a9600fa2be505b9c14509dc02222`
- P2.1 verified implementation: `ec7ed1b008c3c125d52e64dd54231034305b1496`

## 3. Files Added

| File | Role |
|------|------|
| `Sources/Services/GoongConfiguration.swift` | Reads `GOONG_API_KEY` from `Info.plist` at runtime |
| `Sources/Services/GoongPlacesClient.swift` | `GoongPlacesClientProtocol` + `GoongPlacesHTTPClient` + `GoongRawPrediction` |
| `Sources/Services/SearchRanking.swift` | Pure, testable Vietnamese-aware ranking helper |
| `Tests/.../Mocks/MockGoongPlacesClient.swift` | Controllable test double recording all parameters |
| `Tests/.../GoongSearchServiceTests.swift` | ≥20 tests: generation safety, token lifecycle, parameters |
| `Tests/.../SearchRankingTests.swift` | ≥10 tests: normalization, ranking, tie-breaks |
| `Tests/.../DestinationSelectionTests.swift` | ≥9 tests: Place Detail lifecycle, generation guards |

## 4. Files Modified

| File | Change |
|------|--------|
| `Sources/Services/GoongSearchService.swift` | Full refactor: generation guard, session token lifecycle, radius/limit/more_compound, protocol injection |
| `Sources/ViewModels/NavigationViewModel.swift` | `searchQuery` published state, `destinationSelectionGeneration`, new search API |
| `Sources/Views/MainMapView.swift` | TextField binds to `viewModel.searchQuery`; clear calls `clearSearch()` |
| `Info.plist` | Added `GOONG_API_KEY = $(GOONG_API_KEY)` entry |

## 5. Files Deleted

| File | Reason |
|------|--------|
| `Sources/Views/SearchBarView.swift` | Contained `@State private var query` — second source of truth |

## 6. Bugs Fixed

| # | Bug |
|---|-----|
| 1 | `TextField` derived display text from `predictions`/`selectedPrediction` — not real query |
| 2 | `clear()` rotated session token before Place Detail fired |
| 3 | `searchRadius = 50_000` treated as metres; Goong expects km |
| 4 | No autocomplete generation guard — stale responses overwrote newer results |
| 5 | No `destinationSelectionGeneration` — stale Place Detail could set wrong destination |
| 6 | `limit` not sent to Goong autocomplete |
| 7 | `more_compound` not sent |
| 8 | `providerScore` / compound address fields not parsed |
| 9 | API key hardcoded in committed source |
| 10 | Two divergent search UI implementations |

## 7. Authoritative Query State

`NavigationViewModel` now owns `@Published public var searchQuery: String = ""`.

All views bind to `viewModel.searchQuery` exclusively. The `TextField` in `MainMapView` uses:

```swift
TextField("Tìm kiếm địa điểm…", text: Binding(
    get: { viewModel.searchQuery },
    set: { viewModel.updateSearchQuery($0) }
))
```

No view derives query from `predictions` or `selectedPrediction`.

## 8. Search API (NavigationViewModel)

| Method | Behaviour |
|--------|-----------|
| `beginSearch()` | `isSearchActive = true` |
| `updateSearchQuery(_:)` | Sets `searchQuery`, triggers `searchService.updateQuery`. If `selectedDestination != nil` and text changed, begins fresh session |
| `selectPrediction(_:)` | Increments `destinationSelectionGeneration`, sets `searchQuery`, fetches Place Detail |
| `cancelSearch()` | `isSearchActive = false`, cancels autocomplete, preserves `searchQuery` |
| `clearSearch()` | Cancels all pending tasks, `searchService.resetAll()`, clears everything |

## 9. Session Token Lifecycle

```
New search session begins
       │
       ▼
[Token T1 created]
       │
  updateQuery() ──► autocomplete(sessionToken: T1)
  updateQuery() ──► autocomplete(sessionToken: T1)  ← same token!
       │
  selectPrediction() ──► cancelAutocomplete() + clearPredictions()
       │                   (token NOT rotated)
       │
  getPlaceDetail(sessionToken: T1) ─► Goong groups for billing ✓
       │
  Place Detail succeeds
       │
  endSearchSession() ──► [Token T2 created] ✓
```

`cancelAutocomplete()` and `clearPredictions()` do NOT rotate the token.  
`endSearchSession()` and `resetAll()` rotate the token.

## 10. Autocomplete Generation Safety

```swift
private var autocompleteGeneration: UInt64 = 0
```

Every `updateQuery()` call:
1. Increments `autocompleteGeneration`
2. Cancels the debounce task
3. Captures `let myGen = autocompleteGeneration` before sleeping

After debounce + network round-trip:
- `guard autocompleteGeneration == myGen else { return }` — stale response discarded

## 11. Destination Selection Generation Safety

```swift
private var destinationSelectionGeneration: UInt64 = 0
private var placeDetailTask: Task<Void, Never>?
```

Every `selectPrediction()` call:
1. Cancels prior `placeDetailTask`
2. Increments `destinationSelectionGeneration`, captures `mySelGen`
3. After Place Detail: `guard !Task.isCancelled && destinationSelectionGeneration == mySelGen && selectedPrediction?.placeID == prediction.placeID`

## 12. Request Parameters

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| `radius` | `2000` km | Vietnam-wide — allows cross-province searches |
| `limit` | `10` | Returns enough candidates for re-ranking |
| `more_compound` | `true` | Provides district/commune/province sub-fields |

## 13. SearchRanking Formula

```
score = exactNormalizedMainText   × 100
      + prefixNormalizedMainText  ×  50
      + tokenCoverage             ×  10  (per query token in description)
      + (providerScore ?? 0)      ×   0.1

Tie-breaks (ascending priority):
  1. score DESC
  2. providerScore DESC
  3. providerIndex ASC  (original Goong response position)
  4. placeID ASC        (fully deterministic)
```

### Normalization

```swift
String.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
```

Followed by whitespace collapse. Example: `"Đường Trần Hưng Đạo"` → `"duong tran hung dao"`.

## 14. Deduplication

Predictions with duplicate `placeID` are removed, keeping the first occurrence (highest-ranked by provider).

## 15. API Key Security

The hardcoded API key has been removed from all Swift source files.

`Info.plist` now contains:
```xml
<key>GOONG_API_KEY</key>
<string>$(GOONG_API_KEY)</string>
```

The build setting `GOONG_API_KEY` must be set via `.xcconfig` or CI secret injection.

`GoongConfiguration.apiKey()` throws `GoongConfigError.missingAPIKey` if the value is absent or unexpanded — a controlled error, not a crash.

CI unit tests never instantiate `GoongPlacesHTTPClient`; all tests inject `MockGoongPlacesClient`.

> ⚠️ The previously committed key `LyG3pKyU88XZHKpKudhyUoG9jsB5i8twzm8vXfIq` is considered exposed and must be rotated at https://account.goong.io/keys.

## 16. GoongPlacesClientProtocol

```swift
@MainActor
public protocol GoongPlacesClientProtocol: AnyObject {
    func autocomplete(query:location:radius:limit:sessionToken:) async throws -> [GoongRawPrediction]
    func placeDetail(placeID:sessionToken:) async throws -> GoongPlace
}
```

Production: `GoongPlacesHTTPClient` (reads API key via `GoongConfiguration`).  
Tests: `MockGoongPlacesClient` (records all call parameters, controllable delays/results).

## 17. SearchBarView Removal

`SearchBarView.swift` was deleted. It contained a private `@State private var query` that would have created a second source of truth for the search query. `MainMapView` inline search is the single canonical implementation.

## 18. Empty Results & Error States

When `searchQuery.count >= 2 && !isLoading && predictions.isEmpty && errorMessage == nil`:
→ "Không tìm thấy địa điểm phù hợp" displayed

When `errorMessage != nil`:
→ Orange error text displayed in search layer

## 19. P0/P1/P2 Invariants Preserved

- `routeRequestGeneration` guards unchanged
- `NavigationSessionManager` state machine unchanged
- `RerouteManager` policy and backoff unchanged
- BLE 16-byte packet protocol unchanged
- Kalman/GPS filtering unchanged
- `RouteGeometry` / `RouteProjection` unchanged

## 20. Test Count Summary

| Suite | Tests | New in P3 |
|-------|-------|-----------|
| RouteGeometryTests | 12 | 0 |
| OffRouteDetectorTests | 0 | 0 |
| RerouteManagerTests | 37 | 0 |
| GoongSearchServiceTests | 20 | +20 |
| SearchRankingTests | 10 | +10 |
| DestinationSelectionTests | 9 | +9 |
| **Total** | **88** | **+39** |

## 21. GitHub Actions Evidence

- **Baseline Commit**: `dced5f1c2076a9600fa2be505b9c14509dc02222`
- **P2.1 Verified Implementation Commit**: `ec7ed1b008c3c125d52e64dd54231034305b1496`
- **P3 Implementation Commit**: _TBD after CI run_
- **P3 Verified GitHub Actions Run ID**: _TBD_

### Expected Build Matrix:
| Job / Suite | Expected |
| :--- | :--- |
| Compile Native iOS Swift/SwiftUI | SUCCESS |
| Native Unit Tests | ≥74 PASS, 0 failures |
| Native Release Build | SUCCESS |
| Native IPA | SUCCESS |
| Flutter iOS IPA | SUCCESS |
