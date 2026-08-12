#!/usr/bin/env bash
# =============================================================================
#   CODED Agentic AI Bootcamp - Connect Gmail to OpenClaw (via Himalaya)
#
#   The bundled "gog" skill for Gmail/Workspace does not work on Linux
#   (confirmed: openclaw/openclaw#9420, closed as not planned upstream - no
#   Linux binary, source build fails). This script uses Himalaya instead - a
#   real cross-platform IMAP/SMTP CLI with actual Linux release binaries -
#   wired up as a bundled OpenClaw skill the same way. Same end result
#   (read, search, summarize, reply to real Gmail), different tool underneath.
#
#   Needs a Gmail App Password (not your real Google password):
#     Google Account -> Security -> 2-Step Verification (enable if needed)
#     -> App passwords -> create one -> copy the 16-character code.
#
#   Run this on a server already built by vps_setup.sh - it does not touch
#   vps_setup.sh or any other connect_*.sh script. If connect_elevenlabs.sh
#   already built a custom image (for ffmpeg), this ADDS to that same image
#   instead of replacing it - voice keeps working.
#
#     curl -fsSL https://raw.githubusercontent.com/BlackTigerQ8/agentic-vps-setup/main/connect_gmail.sh -o connect_gmail.sh && sudo bash connect_gmail.sh
#
#   Version: 1.0.0
# =============================================================================

set -Eeuo pipefail

DEPLOY_DIR="/opt/agentic-stack"
CONF_FILE="/etc/agentic-stack.conf"
LOCAL_IMAGE_TAG="agentic-openclaw-voice:latest"   # shared custom-image tag with connect_elevenlabs.sh - deliberately reused, not renamed, so both scripts converge on ONE image
HIMALAYA_VERSION="2.0.0"
HIMALAYA_URL="https://github.com/pimalaya/himalaya/releases/download/v${HIMALAYA_VERSION}/himalaya.x86_64-linux.tgz"

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
  |       Connect Gmail to OpenClaw (Himalaya) - CODED Bootcamp       |
  +==================================================================+
BANNER
echo "${RESET}"

[ "${EUID:-$(id -u)}" -ne 0 ] && { bad "Run with sudo:  sudo bash connect_gmail.sh"; exit 1; }

[ -f "$CONF_FILE" ] || die "No ${CONF_FILE} found. Run vps_setup.sh first - this server hasn't been set up yet."
# shellcheck disable=SC1090
. "$CONF_FILE"
BASE_IMAGE_MARKER="${DEPLOY_DIR}/.openclaw-base-image"

[ -f "${DEPLOY_DIR}/docker-compose.yml" ] || die "No stack found at ${DEPLOY_DIR}. Run vps_setup.sh first."

if ! docker inspect -f '{{.State.Running}}' openclaw-gateway 2>/dev/null | grep -q true; then
    die "OpenClaw isn't running. Check:  sudo agentic status"
fi

dc() { docker compose -f "${DEPLOY_DIR}/docker-compose.yml" "$@"; }
oc() { dc run --rm openclaw-cli "$@"; }
oc_q() { dc run --rm -T openclaw-cli "$@"; }

# =============================================================================
sect "What this does"

echo "  Lets OpenClaw read, search, and summarize your real Gmail on request -"
echo "  e.g. ${BOLD}\"Summarize my last 3 unread emails\"${RESET} on WhatsApp."
echo ""
echo "  ${BOLD}You need a Gmail App Password${RESET} (not your real Google password):"
echo "    1. myaccount.google.com -> Security -> 2-Step Verification (enable if off)"
echo "    2. myaccount.google.com/apppasswords -> create one -> copy the 16-char code"
echo ""
echo "  ${YELLOW}This step builds a small custom container image, so it takes a few"
echo "  minutes - longer than a plain config change.${RESET}"
echo ""

# =============================================================================
sect "A few questions"

email=""
while [ -z "$email" ]; do
    read -rp "  ${CYAN}?${RESET} Gmail address: " email || true
done

display_name=""
read -rp "  ${CYAN}?${RESET} Display name [OpenClaw Assistant]: " display_name || true
display_name="${display_name:-OpenClaw Assistant}"

app_password=""
while [ -z "$app_password" ]; do
    read -rsp "  ${CYAN}?${RESET} Gmail App Password (hidden, 16 characters): " app_password || true
    echo ""
done

echo ""
echo "  ${BOLD}Review:${RESET}"
echo "    Email:        ${CYAN}${email}${RESET}"
echo "    Display name: ${CYAN}${display_name}${RESET}"
echo "    App password: ${DIM}hidden (${#app_password} characters)${RESET}"
echo ""
read -rp "  ${CYAN}?${RESET} Connect this now? [y/N]: " confirm || true
[[ "$confirm" =~ ^[Yy] ]] || { info "Cancelled. Nothing was changed."; exit 0; }

# =============================================================================
sect "Writing the Himalaya config"

himalaya_dir="${DEPLOY_DIR}/openclaw/himalaya"
mkdir -p "$himalaya_dir"

cat > "${himalaya_dir}/config.toml" <<TOMLEOF
[accounts.gmail]
email = "${email}"
display-name = "${display_name}"
default = true

backend.type = "imap"
backend.host = "imap.gmail.com"
backend.port = 993
backend.encryption.type = "tls"
backend.login = "${email}"
backend.auth.type = "password"
backend.auth.raw = "${app_password}"

message.send.backend.type = "smtp"
message.send.backend.host = "smtp.gmail.com"
message.send.backend.port = 587
message.send.backend.encryption.type = "start-tls"
message.send.backend.login = "${email}"
message.send.backend.auth.type = "password"
message.send.backend.auth.raw = "${app_password}"
TOMLEOF

chmod 600 "${himalaya_dir}/config.toml"
chown -R 1000:1000 "$himalaya_dir" 2>/dev/null || true
ok "Config written to ${himalaya_dir}/config.toml"

# =============================================================================
sect "Building the Gmail-enabled image"

if [ ! -f "$BASE_IMAGE_MARKER" ]; then
    detected="$(grep -m1 -oE 'image:[[:space:]]*ghcr\.io/openclaw/openclaw:[^[:space:]]+' "${DEPLOY_DIR}/docker-compose.yml" \
        | awk '{print $2}' || true)"
    [ -z "$detected" ] && detected="ghcr.io/openclaw/openclaw:latest"
    echo "$detected" > "$BASE_IMAGE_MARKER"
fi
BASE_IMAGE="$(cat "$BASE_IMAGE_MARKER")"

HIMALAYA_BLOCK_FILE="$(mktemp)"
cat > "$HIMALAYA_BLOCK_FILE" <<EOF
USER root
RUN curl -fsSL ${HIMALAYA_URL} -o /tmp/himalaya.tgz && \\
    tar -xzf /tmp/himalaya.tgz -C /tmp && \\
    install -m 0755 /tmp/himalaya /usr/local/bin/himalaya && \\
    rm -f /tmp/himalaya.tgz /tmp/himalaya && \\
    mkdir -p /home/node/.config/himalaya && \\
    ln -sf /home/node/.openclaw/himalaya/config.toml /home/node/.config/himalaya/config.toml && \\
    chown -R node:node /home/node/.config
EOF

if [ -f "${DEPLOY_DIR}/Dockerfile.openclaw" ] && grep -q "himalaya" "${DEPLOY_DIR}/Dockerfile.openclaw"; then
    info "Dockerfile.openclaw already installs himalaya - leaving the image build as-is"
elif [ -f "${DEPLOY_DIR}/Dockerfile.openclaw" ]; then
    step "Adding himalaya to the existing custom image (keeping whatever else is already baked in) ..."
    last_line="$(grep -n '^USER node$' "${DEPLOY_DIR}/Dockerfile.openclaw" | tail -1 | cut -d: -f1)"
    [ -z "$last_line" ] && die "Dockerfile.openclaw exists but doesn't end with 'USER node' as expected - inspect it manually: ${DEPLOY_DIR}/Dockerfile.openclaw"
    {
        head -n $((last_line - 1)) "${DEPLOY_DIR}/Dockerfile.openclaw"
        cat "$HIMALAYA_BLOCK_FILE"
        tail -n +"${last_line}" "${DEPLOY_DIR}/Dockerfile.openclaw"
    } > "${DEPLOY_DIR}/Dockerfile.openclaw.tmp"
    mv "${DEPLOY_DIR}/Dockerfile.openclaw.tmp" "${DEPLOY_DIR}/Dockerfile.openclaw"
    ok "Dockerfile.openclaw updated"
else
    step "No existing custom image yet - creating Dockerfile.openclaw ..."
    {
        echo "FROM ${BASE_IMAGE}"
        cat "$HIMALAYA_BLOCK_FILE"
        echo "USER node"
    } > "${DEPLOY_DIR}/Dockerfile.openclaw"
    ok "Dockerfile.openclaw written"
fi
rm -f "$HIMALAYA_BLOCK_FILE"

step "docker build (this is the slow part, 1-3 minutes) ..."
if (cd "$DEPLOY_DIR" && docker build --pull -t "$LOCAL_IMAGE_TAG" -f Dockerfile.openclaw . \
        >/tmp/connect_gmail_build.log 2>&1); then
    ok "Image built: ${LOCAL_IMAGE_TAG}"
else
    bad "Image build failed"
    echo ""
    tail -n 40 /tmp/connect_gmail_build.log
    echo ""
    die "Nothing was changed in docker-compose.yml - OpenClaw is still running as before."
fi

step "Pointing docker-compose.yml at the image ..."
sed -i -E "s#image:[[:space:]]*(ghcr\.io/openclaw/openclaw:[^[:space:]]+|${LOCAL_IMAGE_TAG//\//\\/})#image: ${LOCAL_IMAGE_TAG}#" \
    "${DEPLOY_DIR}/docker-compose.yml"
ok "docker-compose.yml updated"

step "Recreating OpenClaw with the new image ..."
if dc up -d openclaw-gateway >/tmp/connect_gmail_last.log 2>&1; then
    ok "Container recreated"
else
    bad "Recreate failed"
    tail -n 20 /tmp/connect_gmail_last.log
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
sect "Turning on the himalaya skill"

if oc_q config set skills.entries.himalaya.enabled true >/tmp/connect_gmail_last.log 2>&1; then
    ok "himalaya skill enabled"
else
    bad "Could not enable the himalaya skill"
    tail -n 20 /tmp/connect_gmail_last.log
    die "Aborting."
fi

step "Checking the config is still valid ..."
if oc_q config validate >/tmp/connect_gmail_last.log 2>&1; then
    ok "Config is valid"
else
    bad "Config validation failed"
    tail -n 30 /tmp/connect_gmail_last.log
    die "Something above isn't right - fix it before relying on this."
fi

step "Restarting so the config changes actually take effect ..."
dc restart openclaw-gateway >/tmp/connect_gmail_last.log 2>&1 || {
    bad "Restart failed"
    tail -n 20 /tmp/connect_gmail_last.log
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

# =============================================================================
sect "Verifying, before you rely on it"

step "Checking the skill is ready ..."
oc skills info himalaya || warn "Could not read skill status"

step "Checking it can actually reach your inbox ..."
if dc exec -T openclaw-gateway himalaya envelope list --account gmail >/tmp/connect_gmail_last.log 2>&1; then
    ok "Connected - real inbox data came back"
    head -n 5 /tmp/connect_gmail_last.log | sed 's/^/    /'
else
    warn "Could not list the inbox - check the output below (often means the App Password is wrong, or IMAP access needs a moment to activate on Google's side)"
    tail -n 20 /tmp/connect_gmail_last.log
fi

# =============================================================================
sect "Done"

echo "  ${GREEN}${BOLD}Gmail is connected.${RESET}"
echo ""
echo "  If both checks above look right, try it on WhatsApp now:"
echo "    ${CYAN}\"Summarize my last 3 unread emails\"${RESET}"
echo ""
echo "  ${YELLOW}${BOLD}One thing to know:${RESET} 'sudo agentic update' will fail to pull"
echo "  openclaw-gateway from now on, because it points at a local image, not"
echo "  one on a registry. Re-run this script (or connect_elevenlabs.sh) to"
echo "  rebuild from the latest base image when needed."
echo ""
info "Changed your Gmail address or password? Run this script again - it"
info "safely overwrites the config."
echo ""
