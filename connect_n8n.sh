#!/usr/bin/env bash
# =============================================================================
#   CODED Agentic AI Bootcamp - Connect WhatsApp to an n8n workflow
#
#   Teaches OpenClaw when to hand a WhatsApp message to one of your n8n
#   workflows. Run this on a server already built by vps_setup.sh - it does
#   not touch vps_setup.sh, the agentic helper, or anything else.
#
#   Safe to run again: pass a different n8n workflow's details and it cleanly
#   replaces the old configuration. Nothing to remove first.
#
#     curl -fsSL https://raw.githubusercontent.com/BlackTigerQ8/agentic-vps-setup/main/connect_n8n.sh -o connect_n8n.sh && sudo bash connect_n8n.sh
#
#   Version: 1.0.0
# =============================================================================

set -Eeuo pipefail

DEPLOY_DIR="/opt/agentic-stack"
CONF_FILE="/etc/agentic-stack.conf"
SKILL_SLUG="n8n-automation"

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
  |     Connect WhatsApp to an n8n workflow - CODED Bootcamp          |
  +==================================================================+
BANNER
echo "${RESET}"

[ "${EUID:-$(id -u)}" -ne 0 ] && { bad "Run with sudo:  sudo bash connect_n8n.sh"; exit 1; }

[ -f "$CONF_FILE" ] || die "No ${CONF_FILE} found. Run vps_setup.sh first - this server hasn't been set up yet."
# shellcheck disable=SC1090
. "$CONF_FILE"

[ -f "${DEPLOY_DIR}/docker-compose.yml" ] || die "No stack found at ${DEPLOY_DIR}. Run vps_setup.sh first."

if ! docker inspect -f '{{.State.Running}}' openclaw-gateway 2>/dev/null | grep -q true; then
    die "OpenClaw isn't running. Check:  sudo agentic status"
fi

dc() { docker compose -f "${DEPLOY_DIR}/docker-compose.yml" "$@"; }
oc() { dc run --rm openclaw-cli "$@"; }
oc_q() { dc run --rm -T openclaw-cli "$@"; }

# =============================================================================
sect "What this does"

echo "  OpenClaw already runs the WhatsApp side - you're chatting with it there."
echo "  This teaches it ${BOLD}when${RESET} to hand a message to an n8n workflow instead of"
echo "  answering it directly. n8n does the actual work and reports back; this"
echo "  server just relays the reply onto WhatsApp."
echo ""
echo "  Have two things ready from your n8n workflow's ${BOLD}Webhook${RESET} node:"
echo "    - its ${BOLD}production${RESET} URL (the one under /webhook/, not /webhook-test/)"
echo "    - its Header Auth key"
echo ""

# =============================================================================
sect "A few questions"

url=""
while [ -z "$url" ]; do
    read -rp "  ${CYAN}?${RESET} n8n webhook URL: " url || true
done
case "$url" in
    */webhook-test/*)
        warn "That's the TEST url - it only works once, right after clicking 'Execute workflow'."
        warn "For this to work every time, activate the workflow and use the /webhook/ url instead."
        read -rp "  ${CYAN}?${RESET} Use it anyway? [y/N]: " ans || true
        [[ "$ans" =~ ^[Yy] ]] || die "Cancelled. Get the production URL and run this again."
        ;;
esac

key=""
while [ -z "$key" ]; do
    read -rsp "  ${CYAN}?${RESET} Header Auth key (hidden): " key || true
    echo ""
done

default_desc="Search the web and save results as a Google Doc, Sheet, or Calendar event"
read -rp "  ${CYAN}?${RESET} In one sentence, what does this workflow do? [${default_desc}]: " desc || true
desc="${desc:-$default_desc}"

echo ""
echo "  ${BOLD}Review:${RESET}"
echo "    URL:         ${CYAN}${url}${RESET}"
echo "    Key:         ${DIM}hidden (${#key} characters)${RESET}"
echo "    Description: ${CYAN}${desc}${RESET}"
echo ""
read -rp "  ${CYAN}?${RESET} Connect this now? [y/N]: " confirm || true
[[ "$confirm" =~ ^[Yy] ]] || { info "Cancelled. Nothing was changed."; exit 0; }

# =============================================================================
sect "Writing the skill"

skill_dir="${DEPLOY_DIR}/openclaw-workspace/${SKILL_SLUG}"
mkdir -p "$skill_dir"

cat >"${skill_dir}/SKILL.md" <<SKILLEOF
---
name: ${SKILL_SLUG}
description: ${desc}
---

When a WhatsApp message matches what this skill is for, do not try to handle it yourself. Hand it to the n8n automation instead - it does the real work and reports back.

Run this with your shell tool, filling in the sender's phone number and their exact message:

curl -s -X POST ${url} \\
  -H "Content-Type: application/json" \\
  -H "X-Agent-Key: ${key}" \\
  -d '{"from": "SENDER_PHONE_NUMBER", "text": "THE_USER_MESSAGE"}'

It returns JSON. Reply on WhatsApp confirming completion in your own words. Do not show the raw JSON or the webhook URL to the user.

Only use this skill when the request matches: ${desc}
For everything else, respond normally without using this skill.
SKILLEOF

chown -R 1000:1000 "$skill_dir" 2>/dev/null || true
chmod 600 "${skill_dir}/SKILL.md" 2>/dev/null || true
ok "Skill written to ${skill_dir}/SKILL.md"

# =============================================================================
sect "Installing it into OpenClaw"

step "Running openclaw skills install ..."
if oc_q skills install "/home/node/.openclaw/workspace/${SKILL_SLUG}" --as "$SKILL_SLUG" --force \
        >/tmp/connect_n8n_last.log 2>&1; then
    ok "Skill installed"
else
    bad "Install failed"
    echo ""
    tail -n 25 /tmp/connect_n8n_last.log
    echo ""
    die "The skill file is saved at ${skill_dir}/SKILL.md if you want to inspect or retry manually."
fi

step "Checking it's ready ..."
oc skills check || warn "Check reported a problem - see above. The skill may still work; read what it says."

# =============================================================================
sect "Done"

echo "  ${GREEN}${BOLD}WhatsApp is now connected to this n8n workflow.${RESET}"
echo ""
echo "  Send a WhatsApp message that clearly matches:"
echo "    ${CYAN}${desc}${RESET}"
echo ""
echo "  This depends on OpenClaw's model recognizing the request, not a hard"
echo "  trigger - so test with something unambiguous first."
echo ""
info "Built a different workflow, or changed this one's URL? Just run this"
info "script again with the new details - it safely replaces this skill."
echo ""
