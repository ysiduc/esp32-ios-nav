#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# SCRIPT 2: Start all navigation servers
# Chay script nay moi khi khoi dong Android/Termux
#
# Yeu cau:
#   - Da chay 1_setup_termux.sh
#   - Da cai Tailscale tren Android va dang nhap (tu Play Store)
# =============================================================================

SERVER_DIR="$HOME/navserver"
LOG_DIR="$SERVER_DIR/logs"
mkdir -p "$LOG_DIR"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[--]${NC} $1"; }
hd()   { echo -e "${CYAN}$1${NC}"; }

kill_port() {
    local port=$1
    local pid=$(lsof -ti :"$port" 2>/dev/null | head -1 || true)
    [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null && sleep 1 || true
}

hd "=================================================="
hd "  Navigation Server Stack — Khoi dong..."
hd "=================================================="

# ================================================================
# 1. Martin (Map Tiles) — port 3000
# ================================================================
hd "\n[1/3] Starting Martin tile server..."
kill_port 3000
cd "$SERVER_DIR"
nohup ./martin \
    --config martin_config.yaml \
    > "$LOG_DIR/martin.log" 2>&1 &
MARTIN_PID=$!
sleep 2
if kill -0 $MARTIN_PID 2>/dev/null; then
    ok "Martin running (PID $MARTIN_PID) :3000"
else
    warn "Martin failed! Log: tail $LOG_DIR/martin.log"
fi

# ================================================================
# 2. GraphHopper (Routing) — port 8989
# ================================================================
hd "\n[2/3] Starting GraphHopper routing engine..."
kill_port 8989
cd "$SERVER_DIR/routing"
nohup java -Xmx1g \
    -jar graphhopper.jar \
    --config graphhopper_config.yaml \
    server \
    > "$LOG_DIR/graphhopper.log" 2>&1 &
GH_PID=$!
sleep 4
if kill -0 $GH_PID 2>/dev/null; then
    ok "GraphHopper running (PID $GH_PID) :8989"
else
    warn "GraphHopper failed! Log: tail $LOG_DIR/graphhopper.log"
fi

# ================================================================
# 3. Photon (Geocoding/Search) — port 2322
# ================================================================
hd "\n[3/3] Starting Photon geocoding server..."
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
    ok "Photon running (PID $PHOTON_PID) :2322"
else
    warn "Photon failed! Log: tail $LOG_DIR/photon.log"
fi

# ================================================================
# 4. Lay Tailscale IP (iPhone ket noi bang IP nay)
# ================================================================
hd "\n[INFO] Getting Tailscale IP..."
TAILSCALE_IP=""

# Thu lay IP Tailscale (100.x.x.x)
if command -v tailscale &>/dev/null; then
    TAILSCALE_IP=$(tailscale ip -4 2>/dev/null | head -1 || true)
fi

# Fallback: lay tu interface utun/tun
if [ -z "$TAILSCALE_IP" ]; then
    TAILSCALE_IP=$(ip addr show 2>/dev/null | grep '100\.' | awk '{print $2}' | cut -d/ -f1 | head -1 || true)
fi

LOCAL_IP=$(ip route get 1 2>/dev/null | awk '{print $7}' | head -1 \
           || hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")

# ================================================================
# 5. Status summary
# ================================================================
hd "\n=================================================="
hd "  Server Status"
hd "=================================================="
echo ""

if [ -n "$TAILSCALE_IP" ]; then
    echo -e "${GREEN}Tailscale IP: $TAILSCALE_IP${NC}"
    echo ""
    echo "  Trong iOS app, set:"
    echo -e "  ${YELLOW}NavServerConfig.serverBase = \"http://$TAILSCALE_IP\"${NC}"
    echo ""
    echo "  Map Tiles:  http://$TAILSCALE_IP:3000/catalog"
    echo "  Routing:    http://$TAILSCALE_IP:8989/health"
    echo "  Search:     http://$TAILSCALE_IP:2322/api?q=hanoi"
else
    echo -e "${YELLOW}Tailscale chua bat! Hay mo app Tailscale tren Android.${NC}"
    echo "Local IP: $LOCAL_IP (chi dung cung WiFi)"
    echo ""
    echo "  Map Tiles:  http://$LOCAL_IP:3000/catalog"
    echo "  Routing:    http://$LOCAL_IP:8989/health"
    echo "  Search:     http://$LOCAL_IP:2322/api?q=hanoi"
fi

echo ""
echo "  Logs: $LOG_DIR/"
echo "  Stop: pkill -f 'martin\|graphhopper\|photon'"
echo ""
ok "Done! Servers started."
