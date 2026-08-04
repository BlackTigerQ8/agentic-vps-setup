#!/usr/bin/env bash

# =============================================================================
#   ____ ___  ____  _____ ____       _                    _   _         _   ___
#  / ___/ _ \|  _ \| ____|  _ \     / \   __ _  ___ _ __ | |_(_) ___   / \ |_ _|
# | |  | | | | | | |  _| | | | |   / _ \ / _` |/ _ \ '_ \| __| |/ __| / _ \ | |
# | |__| |_| | |_| | |___| |_| |  / ___ \ (_| |  __/ | | | |_| | (__ / ___ \| |
#  \____\___/|____/|_____|____/  /_/   \_\__, |\___|_| |_|\__|_|\___/_/   \_\___|
#                                        |___/                                  
#   Agentic AI Bootcamp — OpenClaw WhatsApp Fix Script
#   Fixes the dashboard QR code and enables WhatsApp channel
#   Author: Eng. Abdullah Alenezi | Version: 1.0.0
# =============================================================================

set -euo pipefail

# --- Color Palette -----------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# --- Utility Functions -------------------------------------------------------
print_step() { echo -e "  ${BLUE}>${RESET} $1"; }
print_ok()   { echo -e "  ${GREEN}[OK]${RESET}  $1"; }
print_warn() { echo -e "  ${YELLOW}[WARN]${RESET} ${YELLOW}$1${RESET}"; }
print_error(){ echo -e "  ${RED}[ERR]${RESET}  ${RED}$1${RESET}"; }
print_info() { echo -e "  ${DIM}[INFO] $1${RESET}"; }
separator()  { echo -e "${DIM}  ----------------------------------------------------------------${RESET}"; }

# --- Banner ------------------------------------------------------------------
clear
echo -e "${CYAN}"
echo "  +====================================================================+"
echo "  |      >>> OpenClaw WhatsApp Fix — Agentic AI Bootcamp <<<          |"
echo "  |           Automated by CODED Bootcamp Instructor                  |"
echo "  +====================================================================+"
echo -e "${RESET}"
echo ""

# --- Root Check --------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root (or with sudo)."
    print_info  "Re-run: sudo bash fix_openclaw.sh"
    exit 1
fi

# =============================================================================
#   STEP 1: Detect OpenClaw Container
# =============================================================================
print_step "Detecting OpenClaw container ..."

CONTAINER_NAME=""
for name in openclaw openclaw-gateway; do
    if docker ps --format '{{.Names}}' | grep -qx "$name"; then
        CONTAINER_NAME="$name"
        break
    fi
done

if [ -z "$CONTAINER_NAME" ]; then
    print_error "No running OpenClaw container found!"
    print_info  "Checked for container names: 'openclaw' and 'openclaw-gateway'."
    print_info  "Make sure your stack is running: docker compose up -d"
    exit 1
fi

print_ok "Found running container: ${BOLD}${CONTAINER_NAME}${RESET}"

# =============================================================================
#   STEP 2: Detect Docker Compose Directory
# =============================================================================
print_step "Locating docker-compose.yml ..."

COMPOSE_DIR=""
for dir in /opt/agentic-stack /root/n8n-automation; do
    if [ -f "${dir}/docker-compose.yml" ]; then
        COMPOSE_DIR="$dir"
        break
    fi
done

if [ -z "$COMPOSE_DIR" ]; then
    print_warn "Could not auto-detect compose directory."
    print_info "Falling back to container-level restart."
else
    print_ok "Found compose file at: ${BOLD}${COMPOSE_DIR}/docker-compose.yml${RESET}"
fi

separator
echo ""

# =============================================================================
#   STEP 3: Run OpenClaw Doctor to Fix State
# =============================================================================
echo -e "${MAGENTA}${BOLD}  >> Phase 1: Repairing OpenClaw Gateway${RESET}"
echo ""

print_step "Running 'openclaw doctor --fix' to clear restart-loop breaker and repair state ..."

if docker exec "$CONTAINER_NAME" openclaw doctor --fix 2>&1; then
    print_ok "Doctor completed successfully — restart-loop breaker cleared."
else
    print_warn "Doctor returned warnings (this is usually fine). Continuing ..."
fi

echo ""
separator
echo ""

# =============================================================================
#   STEP 4: Restart the Container Cleanly
# =============================================================================
echo -e "${MAGENTA}${BOLD}  >> Phase 2: Restarting OpenClaw Container${RESET}"
echo ""

print_step "Restarting OpenClaw for a clean boot ..."

if [ -n "$COMPOSE_DIR" ]; then
    # Use docker compose for a clean restart
    cd "$COMPOSE_DIR"
    docker compose restart openclaw 2>&1
    print_ok "Container restarted via docker compose."
else
    # Fallback: restart the container directly
    docker restart "$CONTAINER_NAME" 2>&1
    print_ok "Container restarted directly."
fi

# Wait for the gateway to fully boot
print_step "Waiting for gateway to initialize (10 seconds) ..."
sleep 10
print_ok "Gateway boot window complete."

echo ""
separator
echo ""

# =============================================================================
#   STEP 5: Verify Channel Health
# =============================================================================
echo -e "${MAGENTA}${BOLD}  >> Phase 3: Verifying Channel Status${RESET}"
echo ""

print_step "Checking channel health with 'openclaw channels status --probe' ..."

if docker exec "$CONTAINER_NAME" openclaw channels status --probe 2>&1; then
    print_ok "Channel status check complete."
else
    print_warn "Channel probe returned warnings. This is normal if WhatsApp is not yet paired."
fi

echo ""
separator
echo ""

# =============================================================================
#   DONE
# =============================================================================
echo -e "${GREEN}${BOLD}"
echo "  +====================================================================+"
echo "  |                     ✅  FIX COMPLETE!                              |"
echo "  +====================================================================+"
echo -e "${RESET}"
echo ""
echo -e "  ${BOLD}What to do next:${RESET}"
echo ""
echo -e "  1. Open your SSH tunnel (if not already open):"
echo -e "     ${CYAN}ssh -L 8080:127.0.0.1:8080 root@YOUR_VPS_IP${RESET}"
echo ""
echo -e "  2. Open the OpenClaw dashboard in your browser:"
echo -e "     ${CYAN}http://localhost:8080${RESET}"
echo ""
echo -e "  3. Go to ${BOLD}Channels > WhatsApp${RESET} and click ${BOLD}Show QR${RESET}."
echo ""
echo -e "  4. Scan the QR code with your phone:"
echo -e "     WhatsApp > Settings > Linked Devices > Link a Device"
echo ""
echo -e "  ${DIM}If 'Show QR' still fails, run this command to pair via terminal:${RESET}"
echo -e "  ${CYAN}docker exec -it ${CONTAINER_NAME} openclaw channels login --channel whatsapp${RESET}"
echo ""
print_ok "Script finished. Happy building! 🚀"
echo ""
