#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# SCRIPT 3: Termux:Boot auto-start script
# 
# Cai dat:
#   1. Cai app "Termux:Boot" tu F-Droid
#   2. Copy script nay vao: ~/.termux/boot/start_nav.sh
#   mkdir -p ~/.termux/boot
#   cp ~/navserver/3_termux_boot.sh ~/.termux/boot/start_nav.sh
#   3. Mo Termux:Boot 1 lan de cap quyen
# =============================================================================

# Wait for system to stabilize after boot
sleep 10

# Start navigation servers
bash "$HOME/navserver/2_start_servers.sh"
