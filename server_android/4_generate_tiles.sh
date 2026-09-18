#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# SCRIPT 4: Generate Vietnam PMTiles from OSM PBF
# Chay neu khong download duoc PMTiles truc tiep
#
# Can: go-pmtiles va tilemaker
# =============================================================================

SERVER_DIR="$HOME/navserver"

# Option A: Dung tilemaker (C++) de tao tiles tu PBF
# Cai tilemaker
pkg install -y cmake lua54 sqlite boost-headers boost-filesystem \
    boost-system boost-program-options shapelib rapidjson 2>/dev/null || true

git clone https://github.com/systemed/tilemaker.git /tmp/tilemaker 2>/dev/null || true
cd /tmp/tilemaker
mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release 2>&1 | tail -5
make -j4 2>&1 | tail -20
cp tilemaker "$SERVER_DIR/"

# Download OpenMapTiles profile for tilemaker
wget -q -O /tmp/openmaptiles.zip \
    "https://github.com/systemed/tilemaker/archive/master.zip"
unzip -q /tmp/openmaptiles.zip -d /tmp/

# Run tilemaker on Vietnam PBF
echo "Generating Vietnam tiles (may take 30-60 minutes)..."
"$SERVER_DIR/tilemaker" \
    --input "$SERVER_DIR/routing/vietnam-latest.osm.pbf" \
    --output "$SERVER_DIR/tiles/vietnam.pmtiles" \
    --config /tmp/tilemaker-master/resources/config-openmaptiles.json \
    --process /tmp/tilemaker-master/resources/process-openmaptiles.lua \
    2>&1 | tee "$SERVER_DIR/logs/tilemaker.log"

echo "Done! Tiles: $(du -sh $SERVER_DIR/tiles/vietnam.pmtiles)"
