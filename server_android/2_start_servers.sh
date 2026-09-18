#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# SCRIPT 2: Start all navigation servers
# Chay script nay moi khi khoi dong Termux
# Tip: Cai termux-boot de tu dong chay khi Android bat may
# =============================================================================

SERVER_DIR="$HOME/navserver"
LOG_DIR="$SERVER_DIR/logs"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[--]${NC} $1"; }
head_() { echo -e "${CYAN}$1${NC}"; }

kill_port() {
    local port=$1
    local pid=$(lsof -ti :$port 2>/dev/null || true)
    if [ -n "$pid" ]; then
        kill -9 $pid 2>/dev/null || true
        sleep 1
    fi
}

head_ "======================================================"
head_ "  Navigation Server Stack — Starting..."
head_ "======================================================"

# ---- 1. Martin (Map Tiles) ---- port 3000
head_ "\n[1/3] Starting Martin tile server..."
kill_port 3000
cd "$SERVER_DIR"
nohup ./martin \
    --config martin_config.yaml \
    > "$LOG_DIR/martin.log" 2>&1 &
MARTIN_PID=$!
sleep 2
if kill -0 $MARTIN_PID 2>/dev/null; then
    info "Martin running (PID $MARTIN_PID) → http://0.0.0.0:3000"
else
    warn "Martin failed! Check: $LOG_DIR/martin.log"
fi

# ---- 2. GraphHopper (Routing) ---- port 8989
head_ "\n[2/3] Starting GraphHopper routing engine..."
kill_port 8989
cd "$SERVER_DIR/routing"
nohup java -Xmx1g \
    -jar graphhopper.jar \
    --config graphhopper_config.yaml \
    server \
    > "$LOG_DIR/graphhopper.log" 2>&1 &
GH_PID=$!
sleep 3
if kill -0 $GH_PID 2>/dev/null; then
    info "GraphHopper running (PID $GH_PID) → http://0.0.0.0:8989"
else
    warn "GraphHopper failed! Check: $LOG_DIR/graphhopper.log"
fi

# ---- 3. Photon (Geocoding/Search) ---- port 2322
head_ "\n[3/3] Starting Photon geocoding server..."
kill_port 2322
cd "$SERVER_DIR/geocoding"
nohup java -Xmx1g \
    -jar photon.jar \
    -listen-port 2322 \
    -listen-ip 0.0.0.0 \
    > "$LOG_DIR/photon.log" 2>&1 &
PHOTON_PID=$!
sleep 2
if kill -0 $PHOTON_PID 2>/dev/null; then
    info "Photon running (PID $PHOTON_PID) → http://0.0.0.0:2322"
else
    warn "Photon failed! Check: $LOG_DIR/photon.log"
fi

# ---- Status summary ----
head_ "\n======================================================"
head_ "  Server Status"
head_ "======================================================"
MY_IP=$(ip route get 1 2>/dev/null | awk '{print $7}' | head -1 || hostname -I | awk '{print $1}')
echo ""
echo "  Map Tiles:  http://${MY_IP}:3000"
echo "  Routing:    http://${MY_IP}:8989"
echo "  Search:     http://${MY_IP}:2322"
echo ""
echo "  Test Tiles:   curl http://${MY_IP}:3000/catalog"
echo "  Test Route:   curl 'http://${MY_IP}:8989/route?point=21.028,105.852&point=21.035,105.860&vehicle=car&type=json'"
echo "  Test Search:  curl 'http://${MY_IP}:2322/api?q=Ho+Hoan+Kiem&limit=5'"
echo ""
info "All servers started! Logs in: $LOG_DIR/"
