#!/usr/bin/env bash
# =============================================================================
#   CODED Agentic AI Bootcamp - Connect ElevenLabs voice to OpenClaw
#
#   Turns on two things:
#     1. Voice replies - OpenClaw can speak a reply as a WhatsApp voice note
#        using the bundled "sag" skill (ElevenLabs TTS).
#     2. Voice notes in - lets OpenClaw understand a voice note you send it,
#        using its own built-in audio understanding (no ElevenLabs needed for
#        this half - it already exists, this just switches it on).
#
#   The "sag" skill needs a real binary + the ALSA audio library, neither of
#   which are in the stock OpenClaw image. This script builds a small custom
#   image with both baked in and points docker-compose.yml at it. That is the
#   slow part (a couple of minutes); everything else is quick.
#
#   Run this on a server already built by vps_setup.sh - it does not touch
#   vps_setup.sh, connect_n8n.sh, or anything else. Safe to run again if you
#   want to change the voice ID or API key later.
#
#     curl -fsSL https://raw.githubusercontent.com/BlackTigerQ8/agentic-vps-setup/main/connect_elevenlabs.sh -o connect_elevenlabs.sh && sudo bash connect_elevenlabs.sh
#
#   Version: 2.0.0
# =============================================================================

set -Eeuo pipefail

DEPLOY_DIR="/opt/agentic-stack"
CONF_FILE="/etc/agentic-stack.conf"
LOCAL_IMAGE_TAG="agentic-openclaw-sag:latest"
SAG_VERSION="0.4.1"
SAG_URL="https://github.com/steipete/sag/releases/download/v${SAG_VERSION}/sag_${SAG_VERSION}_linux_amd64.tar.gz"

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
BASE_IMAGE_MARKER="${DEPLOY_DIR}/.openclaw-base-image"

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
echo "  reply back with a spoken voice note using ElevenLabs."
echo ""
echo "  Have your ${BOLD}ElevenLabs API key${RESET} ready - from elevenlabs.io -> Profile ->"
echo "  API Keys. A voice ID is optional; OpenClaw has its own default character"
echo "  voice and may use that unless a conversation asks for something else."
echo ""
echo "  ${YELLOW}This step builds a small custom container image, so it takes a few"
echo "  minutes - longer than the other connect scripts.${RESET}"
echo ""

# =============================================================================
sect "A few questions"

key=""
while [ -z "$key" ]; do
    read -rsp "  ${CYAN}?${RESET} ElevenLabs API key (hidden): " key || true
    echo ""
done

voice_id=""
read -rp "  ${CYAN}?${RESET} Preferred voice ID (optional - press Enter to skip): " voice_id || true

echo ""
echo "  Voice notes are transcribed to text before OpenClaw reads them. Seeing"
echo "  that transcript in the chat helps trainees understand what happened -"
echo "  useful for a bootcamp, easy to turn off later if it gets noisy."
read -rp "  ${CYAN}?${RESET} Show the transcript in chat too? [Y/n]: " echo_ans || true
echo_transcript=true
[[ "$echo_ans" =~ ^[Nn] ]] && echo_transcript=false

echo ""
echo "  ${BOLD}Review:${RESET}"
echo "    API key:         ${DIM}hidden (${#key} characters)${RESET}"
echo "    Voice ID:        ${CYAN}${voice_id:-<OpenClaw default>}${RESET}"
echo "    Show transcript: ${CYAN}${echo_transcript}${RESET}"
echo ""
read -rp "  ${CYAN}?${RESET} Connect this now? [y/N]: " confirm || true
[[ "$confirm" =~ ^[Yy] ]] || { info "Cancelled. Nothing was changed."; exit 0; }

# =============================================================================
sect "Saving keys"

set_env_var() {
    # set_env_var NAME VALUE - idempotent replace-or-append in stack.env
    local name="$1" value="$2"
    if grep -q "^${name}=" "${DEPLOY_DIR}/stack.env" 2>/dev/null; then
        sed -i "s#^${name}=.*#${name}=${value}#" "${DEPLOY_DIR}/stack.env"
    else
        echo "${name}=${value}" >> "${DEPLOY_DIR}/stack.env"
    fi
}

set_env_var ELEVENLABS_API_KEY "$key"
[ -n "$voice_id" ] && set_env_var ELEVENLABS_VOICE_ID "$voice_id"
chmod 600 "${DEPLOY_DIR}/stack.env"
ok "Saved to ${DEPLOY_DIR}/stack.env"

# =============================================================================
sect "Building the voice-enabled image"

# Remember the real upstream tag once, on the first run, so re-runs still know
# what to rebuild from even after docker-compose.yml points at our own local
# image. Without this, a second run would try to build "FROM" itself.
if [ ! -f "$BASE_IMAGE_MARKER" ]; then
    detected="$(grep -m1 -oE 'image:[[:space:]]*ghcr\.io/openclaw/openclaw:[^[:space:]]+' "${DEPLOY_DIR}/docker-compose.yml" \
        | awk '{print $2}' || true)"
    [ -z "$detected" ] && detected="ghcr.io/openclaw/openclaw:latest"
    echo "$detected" > "$BASE_IMAGE_MARKER"
fi
BASE_IMAGE="$(cat "$BASE_IMAGE_MARKER")"
info "Building from ${BASE_IMAGE}"

cat > "${DEPLOY_DIR}/Dockerfile.openclaw" <<EOF
FROM ${BASE_IMAGE}
USER root
RUN apt-get update && \\
    apt-get install -y --no-install-recommends libasound2 ca-certificates curl && \\
    rm -rf /var/lib/apt/lists/*
RUN curl -fsSL ${SAG_URL} -o /tmp/sag.tar.gz && \\
    tar -xzf /tmp/sag.tar.gz -C /usr/local/bin sag && \\
    chmod +x /usr/local/bin/sag && \\
    rm /tmp/sag.tar.gz
USER node
EOF

step "docker build (this is the slow part, 1-3 minutes) ..."
if (cd "$DEPLOY_DIR" && docker build --pull -t "$LOCAL_IMAGE_TAG" -f Dockerfile.openclaw . \
        >/tmp/connect_11labs_build.log 2>&1); then
    ok "Image built: ${LOCAL_IMAGE_TAG}"
else
    bad "Image build failed"
    echo ""
    tail -n 40 /tmp/connect_11labs_build.log
    echo ""
    die "Nothing was changed in docker-compose.yml - OpenClaw is still running as before."
fi

step "Pointing docker-compose.yml at the new image ..."
sed -i -E "s#image:[[:space:]]*(ghcr\.io/openclaw/openclaw:[^[:space:]]+|${LOCAL_IMAGE_TAG//\//\\/})#image: ${LOCAL_IMAGE_TAG}#" \
    "${DEPLOY_DIR}/docker-compose.yml"
ok "docker-compose.yml updated"

step "Recreating OpenClaw with the new image ..."
if dc up -d openclaw-gateway >/tmp/connect_11labs_last.log 2>&1; then
    ok "Container recreated"
else
    bad "Recreate failed"
    tail -n 20 /tmp/connect_11labs_last.log
    die "Check:  sudo agentic logs claw"
fi

t0=$SECONDS
up=false
while [ $((SECONDS - t0)) -lt 90 ]; do
    if curl -fsS --max-time 3 "http://127.0.0.1:18789/healthz" >/dev/null 2>&1; then
        up=true; break
    fi
    sleep 2
done
[ "$up" = true ] && ok "OpenClaw is back up" || warn "OpenClaw is slow to come back. Check:  sudo agentic status"

# =============================================================================
sect "Turning on voice notes in and the sag skill"

# There is no `openclaw skills enable` command - skills are bundled but
# disabled by default, and turned on the same way everything else is:
# a config path, confirmed against the live schema (skills.entries.<name>.enabled).
if oc_q config set tools.media.audio.enabled true >/tmp/connect_11labs_last.log 2>&1; then
    ok "Audio understanding enabled"
else
    warn "Could not enable audio understanding - continuing anyway"
    tail -n 15 /tmp/connect_11labs_last.log
fi

if [ "$echo_transcript" = true ]; then
    oc_q config set tools.media.audio.echoTranscript true >/tmp/connect_11labs_last.log 2>&1 \
        && ok "Transcript echo enabled" \
        || warn "Could not enable transcript echo - continuing anyway"
fi

if oc_q config set skills.entries.sag.enabled true >/tmp/connect_11labs_last.log 2>&1; then
    ok "sag skill enabled"
else
    bad "Could not enable the sag skill"
    tail -n 20 /tmp/connect_11labs_last.log
    die "Stopped here - the earlier steps (image, keys) are still saved, just this switch didn't flip."
fi

step "Checking the config is still valid ..."
if oc_q config validate >/tmp/connect_11labs_last.log 2>&1; then
    ok "Config is valid"
else
    bad "Config validation failed"
    tail -n 30 /tmp/connect_11labs_last.log
    die "Something above isn't right - fix it before relying on this."
fi

step "Restarting so the config changes actually take effect ..."
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
[ "$up" = true ] && ok "OpenClaw is back up" || warn "OpenClaw is slow to come back. Check:  sudo agentic status"

step "Checking sag is actually ready ..."
oc skills info sag

# =============================================================================
sect "Done"

echo "  ${GREEN}${BOLD}Voice is connected.${RESET}"
echo ""
echo "  If the check above shows the sag binary with a checkmark, try it on"
echo "  WhatsApp now:"
echo "    - Send OpenClaw a normal voice note and see if it understands it"
echo "    - Ask it to reply in voice and see if a voice note comes back"
echo ""
echo "  ${YELLOW}${BOLD}One thing to know:${RESET} 'sudo agentic update' will fail to pull"
echo "  openclaw-gateway from now on, because it points at a local image, not"
echo "  one on a registry. To get a newer OpenClaw version with voice still"
echo "  working, run this script again instead - it rebuilds from the latest"
echo "  base image automatically."
echo ""
info "Changed your mind about the voice ID or key? Run this script again -"
info "it safely overwrites what's here now."
echo ""
