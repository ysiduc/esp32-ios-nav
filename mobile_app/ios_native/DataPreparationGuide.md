# Data Preparation & Xcode Setup Guide
## MapLibre + Apple MapKit Search + Valhalla iOS Navigation App

---

## Part 1: Build Valhalla Tiles for Vietnam

Valhalla tiles contain the routable graph of Vietnam's road network (~150-250MB compressed).
You build them once from OpenStreetMap data, then bundle or host them for the app.

### Prerequisites
- Docker installed on Mac/Linux (https://docs.docker.com/get-docker/)
- ~10GB free disk space
- 4+ GB RAM for tile building (~30-60 min depending on CPU)

### Step 1: Download Vietnam OSM Data

```bash
mkdir -p ~/valhalla_build/custom_files
cd ~/valhalla_build

# Download Vietnam-latest.osm.pbf from Geofabrik (~100MB)
wget -O custom_files/vietnam-latest.osm.pbf \
  https://download.geofabrik.de/asia/vietnam-latest.osm.pbf

# Verify the file:
ls -lh custom_files/vietnam-latest.osm.pbf
# Expected: ~80-120 MB
```

### Step 2: Generate Valhalla Tiles + Config

```bash
cd ~/valhalla_build

# Run the official gis-ops Valhalla Docker image.
# It detects vietnam-latest.osm.pbf in /custom_files and builds tiles automatically.
docker run -dt --name valhalla_builder \
  -v $(pwd)/custom_files:/custom_files \
  ghcr.io/gis-ops/docker-valhalla/valhalla:latest \
  valhalla_build_config --mjolnir-tile-dir /custom_files/valhalla_tiles \
                        --mjolnir-tile-extract /custom_files/valhalla_tiles.tar \
                        --mjolnir-timezone /custom_files/timezones.sqlite \
                        --mjolnir-admin /custom_files/admins.sqlite \
  > /custom_files/valhalla.json

# Wait for config generation:
docker logs -f valhalla_builder

# Build tiles:
docker exec valhalla_builder bash -c \
  "valhalla_build_tiles -c /custom_files/valhalla.json \
     /custom_files/vietnam-latest.osm.pbf 2>&1 | tail -20"

# Package tiles into a single tar file for bundling:
docker exec valhalla_builder bash -c \
  "tar -cf /custom_files/valhalla_tiles.tar -C /custom_files/valhalla_tiles ."

docker stop valhalla_builder && docker rm valhalla_builder
```

### Step 3: Verify Output

```bash
ls -lh ~/valhalla_build/custom_files/
# valhalla.json         (~2 KB)
# valhalla_tiles.tar    (~150-250 MB)
# vietnam-latest.osm.pbf
```

### Step 4: Update valhalla.json Paths for iOS

The generated `valhalla.json` will reference `/custom_files/...` paths.
In the iOS app, tiles are loaded from the App Bundle or Application Support.
Edit the following fields:

```json
{
  "mjolnir": {
    "tile_dir": "",
    "tile_extract": "BUNDLE_PATH/valhalla_tiles.tar",
    "timezone": "BUNDLE_PATH/timezones.sqlite",
    "admin": "BUNDLE_PATH/admins.sqlite"
  }
}
```

> **Note**: `ValhallaEngine.mm` passes the actual config path at runtime.
> The app replaces `BUNDLE_PATH` with `Bundle.main.resourcePath` when loading.
> Or simpler: set `"tile_extract"` to the name only and load absolute path in Swift.

---

## Part 2: Xcode Project Setup

### A. Add MapLibre Native via Swift Package Manager

1. Open your `.xcodeproj` in Xcode
2. File → Add Package Dependencies
3. Enter: `https://github.com/maplibre/maplibre-gl-native-distribution`
4. Select version: `from: 6.7.1`
5. Choose product: **MapLibre** → Add to target **ESP32NavApp**

### B. Bundle Valhalla Data Files

#### Option 1: App Bundle (simple, but large IPA)

1. In Finder, drag these files into your Xcode project under a `Resources/` group:
   - `valhalla_tiles.tar` (~200MB)
   - `valhalla.json` (~2KB)
   - `timezones.sqlite` (~optional, for timezone-aware routing)
   - `admins.sqlite` (~optional, for country-level admin areas)
2. Make sure **Target Membership** = ESP32NavApp is checked for all files
3. **Add to Bundle** (not "Copy items if needed" for large files — let Xcode handle it)

#### Option 2: First-Launch Download (recommended for App Store — keeps IPA small)

Add this helper to `ValhallaWrapper.swift` to download tiles on first launch:

```swift
func downloadValhallaDataIfNeeded() async throws {
    let appSupport = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let valhallaDir = appSupport.appendingPathComponent("valhalla_data")
    let tilesURL = valhallaDir.appendingPathComponent("valhalla_tiles.tar")
    let configURL = valhallaDir.appendingPathComponent("valhalla.json")

    guard !FileManager.default.fileExists(atPath: tilesURL.path) else {
        return // Already downloaded
    }

    try FileManager.default.createDirectory(at: valhallaDir, withIntermediateDirectories: true)

    // Host your tiles.tar on GitHub Releases or a CDN:
    let remoteURL = URL(string: "https://github.com/ysiduc/esp32-ios-nav/releases/download/v1.0/valhalla_tiles.tar")!
    let (localURL, _) = try await URLSession.shared.download(from: remoteURL)
    try FileManager.default.moveItem(at: localURL, to: tilesURL)
    // Download valhalla.json similarly...
}
```

### C. Bridging Header Setup (for ValhallaEngine.mm)

1. In Xcode Build Settings → Swift Compiler — General → **Objective-C Bridging Header**:
   Set: `Sources/Bridge/ESP32Nav-Bridging-Header.h`

2. Or in project.yml (already set):
   ```yaml
   SWIFT_OBJC_BRIDGING_HEADER: Sources/Bridge/ESP32Nav-Bridging-Header.h
   ```

### D. C++ Build Settings

In Xcode Build Settings, configure:

| Setting | Value |
|---------|-------|
| `GCC_ENABLE_CPP_EXCEPTIONS` | YES |
| `CLANG_CXX_LANGUAGE_STANDARD` | gnu++17 |
| `CLANG_CXX_LIBRARY` | libc++ |
| `GCC_ENABLE_OBJC_EXCEPTIONS` | YES |

### E. Link libvalhalla.a (when ready)

Once you've compiled Valhalla as a static library for iOS arm64:

1. Download or build: https://github.com/valhalla/valhalla
   ```bash
   # Cross-compile for iOS arm64 (requires cmake 3.20+):
   cmake -DCMAKE_TOOLCHAIN_FILE=../ios.toolchain.cmake \
         -DPLATFORM=OS64 \
         -DCMAKE_BUILD_TYPE=Release \
         -DENABLE_PYTHON_BINDINGS=OFF \
         -DENABLE_TOOLS=OFF \
         -DENABLE_TESTS=OFF \
         ..
   cmake --build . --target valhalla -- -j8
   ```

2. In Xcode: Build Phases → Link Binary With Libraries → `+` → Add Files:
   - `libvalhalla.a`
   - `libprotobuf.a`
   - `libboost_*.a` (all required Boost static libs)
   - `libspatialite.a` (optional, for admin queries)

3. Add to Header Search Paths:
   ```
   $(SRCROOT)/vendor/valhalla/include
   $(SRCROOT)/vendor/boost/include
   $(SRCROOT)/vendor/protobuf/include
   ```

4. In `ValhallaEngine.mm`, change line 36:
   ```objc
   #define VALHALLA_AVAILABLE 1
   ```

### F. Info.plist Required Keys

Already configured in `mobile_app/ios_native/Info.plist`:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>location</string>
    <string>bluetooth-central</string>
</array>
<key>NSLocationWhenInUseUsageDescription</key>
<string>Ứng dụng cần quyền vị trí để dẫn đường trực tiếp.</string>
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>Ứng dụng cần vị trí chạy ngầm để truyền chỉ dẫn sang ESP32 khi khóa máy.</string>
```

---

## Part 3: Search Configuration

The app uses native Apple MapKit Search (`MKLocalSearchCompleter` and `MKLocalSearch`).
No external third-party API keys or credentials are required.
## Part 4: OpenFreeMap Tile Style (no API key needed)

The app uses OpenFreeMap for vector map tiles — completely free, no sign-up:
- `https://tiles.openfreemap.org/styles/bright` (used by default)
- `https://tiles.openfreemap.org/styles/liberty` (alternative)
- `https://tiles.openfreemap.org/styles/positron` (minimal, good for navigation)

Change the style in `MapViewContainer.swift`:
```swift
private enum MapStyle {
    static let defaultStyle    = "https://tiles.openfreemap.org/styles/bright"
    static let navigationStyle = "https://tiles.openfreemap.org/styles/bright"
}
```

---

## Part 5: Native Valhalla Engine Integration

Valhalla C++ Engine is now **fully integrated & enabled** (`VALHALLA_AVAILABLE=1`).

- Binary: `Frameworks/valhalla-wrapper.xcframework` (contains `libvalhalla_all.a` for iOS device `arm64` and simulator).
- Headers: Full Valhalla + Boost + Protobuf C++ API headers included.
- Tile Configuration: `Sources/Resources/valhalla.json` bundled in the app.
- Multi-tier Routing:
  1. **Primary**: Valhalla Native C++ Engine (<50ms calculation offline).
  2. **Secondary**: Apple MapKit MKDirections (online, 100% free, highly accurate in Vietnam).
  3. **Tertiary**: Straight-line maneuver guidance fallback.

---

## Part 6: Build & Run

```bash
# Generate .xcodeproj from project.yml (requires xcodegen):
brew install xcodegen
cd mobile_app/ios_native/
xcodegen generate

# Open in Xcode:
open ESP32NavApp.xcodeproj

# Connect iPhone → Product → Destination → [Your iPhone]
# Press Cmd+R to build and run
```

---

## Architecture Summary

```
User Types "Bệnh viện Bạch Mai"
  → ApplePlaceSearchService.updateQuery("Bệnh viện Bạch Mai")  [300ms debounce]
  → MKLocalSearchCompleter (native Apple MapKit)
  → Shows 5 predictions in dropdown

User Taps "Bệnh viện Bạch Mai, Hà Nội"
  → ApplePlaceSearchService.resolve(prediction)        [MKLocalSearch]
  → Returns {lat: 21.0016, lng: 105.8412}
  → NavigationViewModel.calculateRoute(to: ...)
    → ValhallaRoutingService.calculateRoute(...)       [on background queue]
      → ValhallaEngine.shared.computeRoute(...)        [ObjC++ → C++ valhalla::actor_t]
      → Returns NavRoute {coordinates[], steps[]}
  → MapViewContainer renders cyan polyline
  → Route preview sheet: "12.3 km • 23 phút"

User Presses "Bắt Đầu Điều Hướng"
  → NavigationSessionManager.startNavigation(route)
  → CLLocationManager delivers GPS every second
    → GPS accuracy filter: discard if >30m accuracy
    → snapToNearestPolylinePoint() → snapped coordinate
    → Step advancement: if within 8m of turn point, move to next step
    → Off-route: perpendicular distance >25m for 3 frames → reroute
    → Progress update → NavigationHUDView updates
    → BLEManager.sendNavigationPacket() → ESP32 screen updates
```
