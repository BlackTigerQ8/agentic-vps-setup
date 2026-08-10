#!/usr/bin/env bash
# =============================================================================
#   CODED Agentic AI Bootcamp - Connect ElevenLabs voice to OpenClaw
#
#   Turns on two things:
#     1. Voice replies - OpenClaw speaks its WhatsApp replies using ElevenLabs
#        instead of (or as well as) typing them.
#     2. Voice notes in - lets OpenClaw understand a voice note you send it,
#        using its own built-in audio understanding (no ElevenLabs needed for
#        this half - it already exists, this just switches it on).
#
#   Run this on a server already built by vps_setup.sh - it does not touch
#   vps_setup.sh, connect_n8n.sh, or anything else. Safe to run again if you
#   want to change the voice ID or API key later.
#
#     curl -fsSL https://raw.githubusercontent.com/BlackTigerQ8/agentic-vps-setup/main/connect_elevenlabs.sh -o connect_elevenlabs.sh && sudo bash connect_elevenlabs.sh
#
#   Version: 1.0.0
# =============================================================================

set -Eeuo pipefail

DEPLOY_DIR="/opt/agentic-stack"
CONF_FILE="/etc/agentic-stack.conf"
DEFAULT_MODEL="eleven_multilingual_v2"

if [ -t 1 ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; MAGENTA=$'\033[0;35m'
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; MAGENTA=""
    BOLD=""; DIM=""; RESET=""
fi

step() { echo "  ${BLUE}>${RESET} $1"; }
ok()   { echo "  ${GREEN}[ OK ]${RESET} $1"; }
warn() { echo "  ${YELLOW}[WARN]${RESET} $1"; }
bad()  { echo "  ${RED}[FAIL]${RESET} $1"; }
info() { echo "  ${DIM}$1${RESET}"; }
sect() { echo ""; echo "${MAGENTA}${BOLD}-- $1${RESET}"; echo ""; }

die() {
    echo ""
    bad "$1"
    exit 1
}

# =============================================================================
clear 2>/dev/null || true
echo "${CYAN}${BOLD}"
cat <<'BANNER'
  +==================================================================+
  |     Connect ElevenLabs voice to OpenClaw - CODED Bootcamp         |
  +==================================================================+
BANNER
echo "${RESET}"

[ "${EUID:-$(id -u)}" -ne 0 ] && { bad "Run with sudo:  sudo bash connect_elevenlabs.sh"; exit 1; }

[ -f "$CONF_FILE" ] || die "No ${CONF_FILE} found. Run vps_setup.sh first - this server hasn't been set up yet."
# shellcheck disable=SC1090
. "$CONF_FILE"

[ -f "${DEPLOY_DIR}/docker-compose.yml" ] || die "No stack found at ${DEPLOY_DIR}. Run vps_setup.sh first."
[ -f "${DEPLOY_DIR}/stack.env" ] || die "No ${DEPLOY_DIR}/stack.env found. Run vps_setup.sh first."

if ! docker inspect -f '{{.State.Running}}' openclaw-gateway 2>/dev/null | grep -q true; then
    die "OpenClaw isn't running. Check:  sudo agentic status"
fi

dc() { docker compose -f "${DEPLOY_DIR}/docker-compose.yml" "$@"; }
oc() { dc run --rm openclaw-cli "$@"; }
oc_q() { dc run --rm -T openclaw-cli "$@"; }

# =============================================================================
sect "What this does"

echo "  Right now OpenClaw replies on WhatsApp with text. This adds a real voice:"
echo "  when someone sends a voice note, OpenClaw can understand it, and it can"
echo "  reply back with a spoken voice note instead of just typed text."
echo ""
echo "  Have your ${BOLD}ElevenLabs API key${RESET} ready - from elevenlabs.io -> Profile ->"
echo "  API Keys. A voice ID is optional; leave it blank to use your account's"
echo "  default voice."
echo ""

# =============================================================================
sect "A few questions"

key=""
while [ -z "$key" ]; do
    read -rsp "  ${CYAN}?${RESET} ElevenLabs API key (hidden): " key || true
    echo ""
done

voice_id=""
read -rp "  ${CYAN}?${RESET} Voice ID (optional - press Enter for your account default): " voice_id || true

echo ""
echo "  Voice notes are transcribed to text before OpenClaw reads them. Seeing"
echo "  that transcript in the chat helps trainees understand what happened -"
echo "  useful for a bootcamp, easy to turn off later if it gets noisy."
read -rp "  ${CYAN}?${RESET} Show the transcript in chat too? [Y/n]: " echo_ans || true
echo_transcript=true
[[ "$echo_ans" =~ ^[Nn] ]] && echo_transcript=false

echo ""
echo "  ${BOLD}Review:${RESET}"
echo "    API key:    ${DIM}hidden (${#key} characters)${RESET}"
echo "    Voice ID:   ${CYAN}${voice_id:-<account default>}${RESET}"
echo "    Model:      ${CYAN}${DEFAULT_MODEL}${RESET}"
echo "    Show transcript: ${CYAN}${echo_transcript}${RESET}"
echo ""
read -rp "  ${CYAN}?${RESET} Connect this now? [y/N]: " confirm || true
[[ "$confirm" =~ ^[Yy] ]] || { info "Cancelled. Nothing was changed."; exit 0; }

# =============================================================================
sect "Saving the API key"

# Stored as an env var and referenced from openclaw.json via a SecretRef,
# rather than written into openclaw.json in plain text - same pattern the
# stack already uses for every other secret (stack.env is root-only, 600).
if grep -q '^ELEVENLABS_API_KEY=' "${DEPLOY_DIR}/stack.env" 2>/dev/null; then
    sed -i "s#^ELEVENLABS_API_KEY=.*#ELEVENLABS_API_KEY=${key}#" "${DEPLOY_DIR}/stack.env"
else
    echo "ELEVENLABS_API_KEY=${key}" >> "${DEPLOY_DIR}/stack.env"
fi
chmod 600 "${DEPLOY_DIR}/stack.env"
ok "Saved to ${DEPLOY_DIR}/stack.env"

# =============================================================================
sect "Configuring OpenClaw"

cfg_set() {
    # cfg_set <path> <value...>  - stops the script if a single set fails,
    # since a half-applied config is worse than none.
    local path="$1"; shift
    if oc_q config set "$path" "$@" >/tmp/connect_11labs_last.log 2>&1; then
        ok "Set ${path}"
    else
        bad "Failed to set ${path}"
        echo ""
        tail -n 20 /tmp/connect_11labs_last.log
        echo ""
        die "Stopped before finishing - your existing OpenClaw config is untouched."
    fi
}

step "Turning on voice replies (ElevenLabs) ..."
cfg_set tts.provider elevenlabs
cfg_set tts.auto always
cfg_set tts.providers.elevenlabs.apiKey --ref-provider default --ref-source env --ref-id ELEVENLABS_API_KEY
cfg_set tts.providers.elevenlabs.model "$DEFAULT_MODEL"
if [ -n "$voice_id" ]; then
    cfg_set tts.providers.elevenlabs.speakerVoiceId "$voice_id"
else
    info "No voice ID given - ElevenLabs will use your account's default voice."
fi

step "Turning on voice notes in ..."
cfg_set tools.media.audio.enabled true
if [ "$echo_transcript" = true ]; then
    cfg_set tools.media.audio.echoTranscript true
fi

# =============================================================================
sect "Checking the config is valid"

if oc_q config validate >/tmp/connect_11labs_last.log 2>&1; then
    ok "Config is valid"
else
    bad "Config validation failed"
    echo ""
    tail -n 30 /tmp/connect_11labs_last.log
    echo ""
    die "Something above isn't right. The values are saved, but OpenClaw may not start cleanly until this is fixed."
fi

# =============================================================================
sect "Restarting OpenClaw"

step "Restarting so the new API key and settings take effect ..."
dc restart openclaw-gateway >/tmp/connect_11labs_last.log 2>&1 || {
    bad "Restart failed"
    tail -n 20 /tmp/connect_11labs_last.log
    die "Check:  sudo agentic logs claw"
}

t0=$SECONDS
up=false
while [ $((SECONDS - t0)) -lt 60 ]; do
    if curl -fsS --max-time 3 "http://127.0.0.1:18789/healthz" >/dev/null 2>&1; then
        up=true; break
    fi
    sleep 2
done

if [ "$up" = true ]; then
    ok "OpenClaw is back up"
else
    warn "OpenClaw is slow to come back. Check:  sudo agentic status"
fi

# =============================================================================
sect "Done"

echo "  ${GREEN}${BOLD}Voice is connected.${RESET}"
echo ""
echo "  Try it on WhatsApp:"
echo "    - Send OpenClaw a normal voice note and see if it understands it"
echo "    - Ask it something and see if the reply comes back as a voice note"
echo ""
info "Changed your mind about the voice? Run this script again with a new"
info "voice ID - it safely overwrites what's here now."
echo ""
info "Turn voice replies off again any time with:"
info "  sudo docker exec openclaw-gateway openclaw config set tts.auto never"
echo ""
