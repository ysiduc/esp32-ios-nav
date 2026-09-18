#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# SCRIPT 1: Termux Setup — Self-Hosted Navigation Server
# Chay script nay 1 lan duy nhat de cai dat moi truong
#
# Stack:
#   - Martin      (binary ARM64) -> vector map tiles   port 3000
#   - GraphHopper (Java JAR)     -> routing engine     port 8989
#   - Photon      (Java JAR)     -> geocoding/search   port 2322
#
# Du lieu: OpenStreetMap Vietnam (Geofabrik) — mien phi
# =============================================================================

set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }

SERVER_DIR="$HOME/navserver"
mkdir -p "$SERVER_DIR"/{tiles,routing,geocoding,logs}
cd "$SERVER_DIR"

# ==========================================================================
# 0. Update Termux packages
# ==========================================================================
info "Updating Termux packages..."
pkg update -y && pkg upgrade -y
pkg install -y wget curl git openjdk-17 python3 unzip tar

# ==========================================================================
# 1. Download MARTIN tile server (pre-built ARM64 binary)
# ==========================================================================
info "Downloading Martin tile server (ARM64 binary)..."
MARTIN_VERSION="0.14.4"
wget -q --show-progress --continue \
    -O /tmp/martin.tar.gz \
    "https://github.com/maplibre/martin/releases/download/v${MARTIN_VERSION}/martin-aarch64-linux-musl.tar.gz" || \
wget -q --show-progress --continue \
    -O /tmp/martin.tar.gz \
    "https://github.com/maplibre/martin/releases/download/v${MARTIN_VERSION}/martin-aarch64-unknown-linux-gnu.tar.gz"

tar -xzf /tmp/martin.tar.gz -C "$SERVER_DIR/"
chmod +x "$SERVER_DIR/martin"
info "Martin: $($SERVER_DIR/martin --version 2>&1 | head -1)"

# ==========================================================================
# 2. Download Vietnam PMTiles (vector map tiles, ~300-600MB)
# Geofabrik does not provide PMTiles directly, use protomaps or maptiler
# We use a Vietnam-cropped PMTiles from protomaps.com
# ==========================================================================
info "Downloading Vietnam PMTiles..."
# Option: Download full planet, then crop (nho hon va chinh xac hon)
# Hoac download truc tiep Vietnam extract tu community mirrors
wget -q --show-progress --continue \
    -O "$SERVER_DIR/tiles/vietnam.pmtiles" \
    "https://r2-public.protomaps.com/protomaps-sample-datasets/protomaps-basemap-opensource-20230408.pmtiles" || {
    warn "Could not download PMTiles. You will need to generate manually."
    warn "See: https://github.com/protomaps/go-pmtiles"
    touch "$SERVER_DIR/tiles/vietnam.pmtiles"
}
info "Tiles: $(du -sh $SERVER_DIR/tiles/vietnam.pmtiles 2>/dev/null)"

# ==========================================================================
# 3. Download GraphHopper (Java JAR — routing engine)
# ==========================================================================
info "Downloading GraphHopper routing engine..."
GH_VERSION="10.0"
wget -q --show-progress --continue \
    -O "$SERVER_DIR/routing/graphhopper.jar" \
    "https://github.com/graphhopper/graphhopper/releases/download/${GH_VERSION}/graphhopper-web-${GH_VERSION}.jar"
info "GraphHopper: $(du -sh $SERVER_DIR/routing/graphhopper.jar)"

# ==========================================================================
# 4. Download Vietnam OSM PBF (cho GraphHopper va Photon)
# ==========================================================================
info "Downloading Vietnam OSM extract from Geofabrik (~150MB)..."
wget -q --show-progress --continue \
    -O "$SERVER_DIR/routing/vietnam-latest.osm.pbf" \
    "https://download.geofabrik.de/asia/vietnam-latest.osm.pbf"
info "OSM PBF: $(du -sh $SERVER_DIR/routing/vietnam-latest.osm.pbf)"

# ==========================================================================
# 5. Download Photon geocoding server
# ==========================================================================
info "Downloading Photon geocoder..."
PHOTON_VERSION="0.5.0"
wget -q --show-progress --continue \
    -O "$SERVER_DIR/geocoding/photon.jar" \
    "https://github.com/komoot/photon/releases/download/${PHOTON_VERSION}/photon-${PHOTON_VERSION}.jar"

# Symlink OSM data for Photon import
ln -sf "$SERVER_DIR/routing/vietnam-latest.osm.pbf" \
       "$SERVER_DIR/geocoding/vietnam-latest.osm.pbf" 2>/dev/null || true

# ==========================================================================
# 6. Create Martin config.yaml
# ==========================================================================
info "Creating Martin config..."
cat > "$SERVER_DIR/martin_config.yaml" << 'YAML'
listen_addresses:
  - "0.0.0.0:3000"
worker_processes: 2
pmtiles:
  vietnam:
    path: tiles/vietnam.pmtiles
    tilejson:
      name: "Vietnam OSM"
      description: "OpenStreetMap Vietnam - Protomaps"
YAML

# ==========================================================================
# 7. Create GraphHopper config.yaml
# ==========================================================================
info "Creating GraphHopper config..."
cat > "$SERVER_DIR/routing/graphhopper_config.yaml" << 'YAML'
graphhopper:
  datareader.file: vietnam-latest.osm.pbf
  graph.location: vietnam-gh
  profiles:
    - name: car
      vehicle: car
      weighting: fastest
    - name: bike
      vehicle: motorcycle
      weighting: fastest
  server:
    application_connectors:
      - type: http
        port: 8989
        bind_host: 0.0.0.0
  cors:
    allowed_origins: "*"
    allowed_methods: [GET, POST]
    allowed_headers: ["*"]
YAML

# ==========================================================================
# 8. Pre-process GraphHopper routing graph (1 lan, ~15-20 phut)
# ==========================================================================
info "====================================================================="
info "Pre-processing GraphHopper graph for Vietnam..."
info "Buoc nay mat ~15-20 phut, chi chay 1 lan!"
info "====================================================================="
cd "$SERVER_DIR/routing"
java -Xmx3g -jar graphhopper.jar \
    --config graphhopper_config.yaml \
    import 2>&1 | tee "$SERVER_DIR/logs/gh_import.log"
info "GraphHopper graph ready!"

# ==========================================================================
# 9. Build Photon index tu Vietnam PBF (1 lan, ~20 phut)
# ==========================================================================
info "====================================================================="
info "Building Photon geocoding index from Vietnam OSM..."
info "Buoc nay mat ~20 phut, chi chay 1 lan!"
info "====================================================================="
cd "$SERVER_DIR/geocoding"
# Photon import tu nominatim hoac truc tiep tu PBF (phu thuoc version)
java -Xmx2g -jar photon.jar \
    -nominatim-import \
    -languages vi,en \
    -country-codes VN 2>&1 | tee "$SERVER_DIR/logs/photon_import.log" || {
    warn "Photon import failed. Try: java -jar photon.jar -nominatim-import"
    warn "Xem: https://github.com/komoot/photon#import-data"
}

info "====================================================================="
info "SETUP HOAN TAT!"
info "Chay: bash ~/navserver/2_start_servers.sh"
info "====================================================================="
