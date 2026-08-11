#!/usr/bin/env bash
# =============================================================================
#   CODED Agentic AI Bootcamp - Diagnostic: dump OpenClaw hook event shapes
#
#   ONE-OFF RESEARCH TOOL, not a bootcamp deliverable. Installs a minimal
#   OpenClaw plugin that does nothing except log the full event object it
#   receives for before_prompt_build and before_model_resolve, so we can see
#   with real evidence whether either hook carries attachment/media-type
#   metadata for the current turn - the docs are unclear on this.
#
#   Does not touch vps_setup.sh or connect_elevenlabs.sh. Safe to run again
#   (overwrites its own plugin files, re-registers itself idempotently).
#
#   Usage:
#     sudo bash diag_hooks_plugin.sh          # install + restart
#     sudo bash diag_hooks_plugin.sh remove   # uninstall, restore config
#
#   Version: 0.1.0
# =============================================================================

set -Eeuo pipefail

DEPLOY_DIR="/opt/agentic-stack"
CONF_FILE="/etc/agentic-stack.conf"
PLUGIN_ID="diag-hooks"

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

die() { echo ""; bad "$1"; exit 1; }

echo "${CYAN}${BOLD}"
cat <<'BANNER'
  +==================================================================+
  |   Diagnostic: dump OpenClaw hook event shapes - research only     |
  +==================================================================+
BANNER
echo "${RESET}"

[ "${EUID:-$(id -u)}" -ne 0 ] && { bad "Run with sudo:  sudo bash diag_hooks_plugin.sh"; exit 1; }
[ -f "$CONF_FILE" ] || die "No ${CONF_FILE} found. Run vps_setup.sh first."
# shellcheck disable=SC1090
. "$CONF_FILE"
[ -f "${DEPLOY_DIR}/docker-compose.yml" ] || die "No stack found at ${DEPLOY_DIR}."

if ! docker inspect -f '{{.State.Running}}' openclaw-gateway 2>/dev/null | grep -q true; then
    die "OpenClaw isn't running. Check:  sudo agentic status"
fi

dc() { docker compose -f "${DEPLOY_DIR}/docker-compose.yml" "$@"; }
oc() { dc run --rm openclaw-cli "$@"; }
oc_q() { dc run --rm -T openclaw-cli "$@"; }

MODE="${1:-install}"

plugin_dir="${DEPLOY_DIR}/openclaw-workspace/${PLUGIN_ID}-plugin"
container_path="/home/node/.openclaw/workspace/${PLUGIN_ID}-plugin"

# =============================================================================
if [ "$MODE" = "remove" ]; then
    sect "Removing diagnostic plugin"

    step "Reading current plugins.allow ..."
    current_allow="$(oc_q config get plugins.allow 2>/dev/null || echo '[]')"
    new_allow="$(node -e "
        let cur; try { cur = JSON.parse(process.argv[1]); } catch(e) { cur = []; }
        if (!Array.isArray(cur)) cur = [];
        cur = cur.filter(x => x !== '${PLUGIN_ID}');
        process.stdout.write(JSON.stringify(cur));
    " "$current_allow" 2>/dev/null || echo '[]')"

    oc_q config set "plugins.allow" "$new_allow" --strict-json >/dev/null 2>&1 || warn "Could not update plugins.allow"
    oc_q config set "plugins.entries.${PLUGIN_ID}.enabled" false >/dev/null 2>&1 || true

    rm -rf "$plugin_dir"
    ok "Plugin files removed and disabled in config"

    step "Restarting gateway ..."
    dc restart openclaw-gateway >/dev/null 2>&1 || true
    ok "Done. Diagnostic plugin removed."
    exit 0
fi

# =============================================================================
sect "What this does"

echo "  Installs a plugin that ONLY logs the full event object for two OpenClaw"
echo "  hooks (${BOLD}before_prompt_build${RESET} and ${BOLD}before_model_resolve${RESET}) to the gateway's"
echo "  own stdout - nothing else. It never mutates the prompt or the model."
echo ""
echo "  Goal: find out, from real evidence, whether either hook actually sees"
echo "  attachment/media-type metadata for the current WhatsApp message. That"
echo "  fact decides whether a hook-based fix for voice-note auto-reply is"
echo "  even possible."
echo ""
read -rp "  ${CYAN}?${RESET} Install this now? [y/N]: " confirm || true
[[ "$confirm" =~ ^[Yy] ]] || { info "Cancelled. Nothing was changed."; exit 0; }

# =============================================================================
sect "Writing the plugin"

mkdir -p "$plugin_dir"

cat >"${plugin_dir}/plugin.json" <<EOF
{
  "id": "${PLUGIN_ID}",
  "name": "Diagnostic Hooks Logger",
  "version": "0.1.0",
  "description": "Logs before_prompt_build and before_model_resolve event shapes for research. Read-only, no mutation.",
  "contracts": {}
}
EOF

cat >"${plugin_dir}/package.json" <<'EOF'
{
  "name": "diag-hooks-plugin",
  "version": "0.1.0",
  "type": "module",
  "exports": "./index.ts"
}
EOF

cat >"${plugin_dir}/index.ts" <<'EOF'
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";

function safeLog(api: any, tag: string, event: unknown) {
  let payload: string;
  try {
    payload = JSON.stringify(event, null, 2);
  } catch (e) {
    payload = "[unserializable event: " + String(e) + "]";
  }
  const line = "[diag-hooks] " + tag + " => " + payload;
  try {
    if (api && api.logger && typeof api.logger.info === "function") {
      api.logger.info(line);
    }
  } catch (e) {
    // ignore
  }
  try {
    console.log(line);
  } catch (e) {
    // ignore
  }
}

export default definePluginEntry({
  async register(api: any) {
    try {
      api.on("before_prompt_build", async (event: unknown) => {
        safeLog(api, "before_prompt_build", event);
        return undefined;
      });
    } catch (e) {
      console.log("[diag-hooks] failed to register before_prompt_build: " + String(e));
    }

    try {
      api.on("before_model_resolve", async (event: unknown) => {
        safeLog(api, "before_model_resolve", event);
        return undefined;
      });
    } catch (e) {
      console.log("[diag-hooks] failed to register before_model_resolve: " + String(e));
    }

    console.log("[diag-hooks] plugin registered");
  }
});
EOF

chown -R 1000:1000 "$plugin_dir" 2>/dev/null || true
ok "Plugin written to ${plugin_dir}"

# =============================================================================
sect "Wiring it into config"

step "Reading current plugins.allow ..."
current_allow="$(oc_q config get plugins.allow 2>/dev/null || echo '[]')"
new_allow="$(node -e "
    let cur; try { cur = JSON.parse(process.argv[1]); } catch(e) { cur = []; }
    if (!Array.isArray(cur)) cur = [];
    if (!cur.includes('${PLUGIN_ID}')) cur.push('${PLUGIN_ID}');
    process.stdout.write(JSON.stringify(cur));
" "$current_allow" 2>/dev/null || echo "[\"${PLUGIN_ID}\"]")"

step "Setting plugins.allow -> ${new_allow}"
oc_q config set "plugins.allow" "$new_allow" --strict-json >/tmp/diag_hooks_last.log 2>&1 \
    || { bad "Failed to set plugins.allow"; tail -n 25 /tmp/diag_hooks_last.log; die "Aborting."; }
ok "plugins.allow updated"

step "Setting plugins.entries.${PLUGIN_ID}.source ..."
oc_q config set "plugins.entries.${PLUGIN_ID}.source" "$container_path" >/tmp/diag_hooks_last.log 2>&1 \
    || { bad "Failed to set plugin source"; tail -n 25 /tmp/diag_hooks_last.log; die "Aborting."; }
ok "source set"

step "Setting plugins.entries.${PLUGIN_ID}.enabled true ..."
oc_q config set "plugins.entries.${PLUGIN_ID}.enabled" true >/tmp/diag_hooks_last.log 2>&1 \
    || { bad "Failed to enable plugin"; tail -n 25 /tmp/diag_hooks_last.log; die "Aborting."; }
ok "enabled"

step "Validating config ..."
if oc_q config validate >/tmp/diag_hooks_last.log 2>&1; then
    ok "Config valid"
else
    bad "Config validation failed"
    tail -n 40 /tmp/diag_hooks_last.log
    warn "Config was still written. Fix manually or run: sudo bash diag_hooks_plugin.sh remove"
fi

# =============================================================================
sect "Restarting the gateway"

step "Restarting openclaw-gateway ..."
dc restart openclaw-gateway >/dev/null 2>&1 || die "Restart failed. Check: docker logs openclaw-gateway"

step "Waiting for it to come back up ..."
for i in $(seq 1 30); do
    if docker inspect -f '{{.State.Running}}' openclaw-gateway 2>/dev/null | grep -q true; then
        ok "Gateway is running"
        break
    fi
    sleep 2
    [ "$i" -eq 30 ] && warn "Still not confirmed running after 60s - check docker logs openclaw-gateway"
done

sleep 3
step "Checking startup logs for plugin registration ..."
if docker logs openclaw-gateway 2>&1 | tail -n 200 | grep -q "\[diag-hooks\] plugin registered"; then
    ok "Plugin loaded and registered successfully"
else
    warn "Didn't see the registration line yet in the last 200 log lines - it may still be starting, or loading failed."
    info "Check manually:  docker logs openclaw-gateway 2>&1 | grep diag-hooks"
fi

# =============================================================================
sect "Done - now go get the evidence"

echo "  1. Send a WhatsApp ${BOLD}voice note${RESET} to the bot (the exact case we're diagnosing)."
echo "  2. Then run:"
echo ""
echo "       ${CYAN}docker logs openclaw-gateway 2>&1 | grep -A 50 'diag-hooks' | tail -n 150${RESET}"
echo ""
echo "  Look for two lines: 'before_prompt_build =>' and 'before_model_resolve =>'."
echo "  Paste that output back - it tells us whether either event object contains"
echo "  something like an attachment list, mediaType, or content-type field."
echo ""
info "When done experimenting, remove this diagnostic with:"
info "  sudo bash diag_hooks_plugin.sh remove"
echo ""
