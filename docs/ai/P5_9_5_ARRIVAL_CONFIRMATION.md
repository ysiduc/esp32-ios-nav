# P5.9.5 — Fix Premature Arrival / Single Source of Truth

**Phase**: P5.9.5  
**Component**: Core Navigation Engine, UI Presentation, BLE Telemetry  
**Status**: VERIFIED IN AUTOMATED TESTS & CI — MANUAL FIELD VERIFICATION PENDING  
**Date**: 2026-09-23  

---

## 1. Physical Field Symptom (Real iPhone Field Test)

During physical road testing on an iPhone running production build:
- **Top Banner displayed**:
  ```
  Trong 86 m
  Bạn đã tới nơi.
  ```
- **Bottom HUD displayed**:
  ```
  remaining distance = 86 m
  ```
- **Problem**: The user was clearly 86 meters away from the destination, yet the presentation declared that arrival had already taken place.

---

## 2. Root Cause Analysis

In `NavigationManager`:
```dart
NavStep? get authoritativeCurrentManeuver {
  if (_activeRoute == null || _activeRoute!.steps.isEmpty) return null;
  if (_currentStepIndex + 1 < _activeRoute!.steps.length) {
    return _activeRoute!.steps[_currentStepIndex + 1];
  }
  return _activeRoute!.steps.last;
}
```
When the vehicle reached the penultimate maneuver step:
- `authoritativeCurrentManeuver` became the final `ARRIVE` step.
- The raw instruction on this provider step (from Valhalla or OSRM) was `"Bạn đã tới nơi."` or `"Bạn đã đến điểm đến"`.
- `bannerInstruction` blindly returned `m.instruction`, announcing an upcoming arrival as if it were a completed arrival.
- In addition, `MapScreen._presentationMode` possessed duplicate, ad-hoc arrival heuristics (`remainingTotalDistance <= 10.0 && currentStepIndex >= lastStep`), creating divergent state interpretations between UI presentation, voice guidance, and ESP32 telemetry.

---

## 3. Architecture & Single Source of Truth

### A. Upcoming Maneuver vs. Arrived State
- **Upcoming Maneuver = ARRIVE**: Indicates the next turn/event ahead is the arrival point. The vehicle is still in motion. Banner shows:
  ```
  Trong 86 m
  Điểm đến ở phía trước
  ```
- **Navigation State = ARRIVED**: Indicates physical arrival has been validated and confirmed. Only in this state does the banner say:
  ```
  Bạn đã tới nơi.
  ```

### B. Explicit State in `NavigationManager`
`NavigationManager` now maintains the authoritative arrival state:
```dart
bool _hasArrived = false;
bool get hasArrived => _hasArrived;
int _arrivalCandidateSamples = 0;
int get arrivalCandidateSamples => _arrivalCandidateSamples;
```
Arrival state resets to `false` on:
- `startNavigation()`
- `startSimulation()`
- Reroute commitment (`_attemptReroute`)
- `stopNavigation()`

### C. Multi-Condition Physical Arrival Gate (`_evaluateArrival`)
Arrival is only confirmed when all of the following conditions are simultaneously met:
1. **Active navigation**: `_isNavigating == true`
2. **Frozen destination**: `_navigationDestination != null`
3. **Arrival maneuver reached or upcoming**: `_currentStepIndex >= steps.length - 1 || m.maneuverType == ManeuverType.arrive`
4. **Remaining route distance threshold**: `remainingTotalDistance <= 20.0 m`
5. **Physical GPS distance threshold**: `physicalDist <= math.max(20.0, math.min(30.0, horizontalAccuracy * 1.25))`
6. **GPS accuracy gate**: `horizontalAccuracy <= 20.0 m`
7. **Sample Stability**: $\ge 2$ consecutive qualifying GPS samples. If any sample fails, `_arrivalCandidateSamples` resets to 0 immediately.

> [!NOTE]
> Physical GPS location (`acceptedPhysicalLocation ?? rawLocation`) is required for distance calculation. Matched route projection is never used as the sole decider for arrival.

### D. Single Source of Truth in UI Presentation Mode
In `MapScreen`, duplicate heuristic calculations were eliminated:
```dart
RoutePresentationMode get _presentationMode {
  final navManager = Provider.of<NavigationManager>(context, listen: false);
  if (navManager.isNavigating && navManager.activeRoute != null) {
    if (navManager.hasArrived) {
      return RoutePresentationMode.arrived;
    }
    return RoutePresentationMode.navigating;
  } else if (_routes.isNotEmpty && _selectedRouteIndex < _routes.length) {
    return RoutePresentationMode.preview;
  }
  return RoutePresentationMode.none;
}
```

### E. Transition-Guarded Voice Guidance
Arrival speech (`VoiceGuidanceService().announceArrival`) is triggered strictly once upon the `false -> true` transition of `_hasArrived`, guarded by `_hasAnnouncedArrival`. It does not spam or repeat on subsequent GPS updates.

### F. ESP32 BLE Payload Semantics
Before arrival:
- `distanceToTurn`: reflects remaining meters (e.g. 86m).
- `streetName`: carries destination-ahead semantics (`"Điểm đến ở phía trước"`).
After arrival:
- `distanceToTurn`: 0m.
- `streetName`: `"Bạn đã tới nơi."`.
- `totalDistance`: 0m.

---

## 4. Telemetry Debug HUD (P5.9.5)

Added real-time arrival telemetry to the debug overlay in `MapScreen`:
- `Arrived: YES/NO`
- `Arrival candidate samples: N`
- `Physical -> dest: XX.Xm`
- `Route remain: XX.Xm`
- `GPS accuracy: XX.Xm`
- `Upcoming maneuver: arrive/...`

---

## 5. Verification & Test Suite

### Automated Unit Tests (`test/arrival_confirmation_test.dart`)
- **Test 1 (Field Case 86m)**: Upcoming arrive maneuver at 86m -> `hasArrived == false`, banner shows `"Điểm đến ở phía trước"`, not `"Bạn đã tới nơi."`, `announceArrival` not called. **PASS**
- **Test 2 (Approaching 35m)**: Proximity speech says `"Điểm đến ở ngay phía trước."`, `hasArrived` stays false, `announceArrival` not called. **PASS**
- **Test 3 (True Arrival)**: 2 consecutive samples at 7m -> `hasArrived == true`, banner displays `"Bạn đã tới nơi."`, `announceArrival` called exactly once, subsequent ticks do not repeat announcement. **PASS**
- **Test 4 (GPS Noise Resistance)**: Sample 1 at 10m increments candidate count; sample 2 spikes to 45m -> candidate count resets to 0, arrival rejected. **PASS**
- **Test 5 (Matched Projection False-Positive Immunity)**: Physical distance at 70m rejects arrival regardless of projection. **PASS**
- **Test 6 (Reroute / Reset)**: Committing a new route or stopping navigation cleanly clears `_hasArrived` and candidate counter. **PASS**
- **Test 7 (ESP32 BLE Payload)**: Verifies distance to turn and street name before vs after arrival confirmation. **PASS**

### Test Totals
- **Flutter Unit Tests**: 209 passing tests (0 failures).
- **Analyzer**: 0 issues found (`flutter analyze --no-fatal-infos`).
- **Live Provider Smoke**: All providers HTTP 200, routing pipeline PASS.
- **PlatformIO**: Build succeeded (`esp32-s3` firmware release build).
- **Production Artifact**: `ESP32Nav-Flutter-PRODUCTION.ipa` (built via CI).

---

## 6. Verification Status

| Item | Result |
|---|---|
| Flutter Analyze | PASS (0 warnings, 0 errors) |
| Flutter Unit Tests | PASS (209/209) |
| Live Routing Smoke | PASS (Valhalla, OSRM1, OSRM2) |
| PlatformIO Firmware | PASS (0 errors, 5.82s) |
| Physical iPhone Field Verification | **MANUAL FIELD PENDING** |
