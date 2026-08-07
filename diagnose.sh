#!/usr/bin/env bash
# =============================================================================
#   CODED Agentic AI Bootcamp - Read-only health report
#
#   Changes nothing. Run it, screenshot the output, send it to your instructor.
#
#     curl -fsSL https://raw.githubusercontent.com/BlackTigerQ8/agentic-vps-setup/main/diagnose.sh | sudo bash
#
#   Version: 1.0.0
# =============================================================================

set -uo pipefail   # deliberately no -e: we want every check to run

CONF_FILE="/etc/agentic-stack.conf"
DEPLOY_DIR="/opt/agentic-stack"
N8N_PORT=5678
OPENCLAW_PORT=18789

DOMAIN=""; N8N_HOSTNAME=""; CLAW_HOSTNAME=""; VPS_IP=""
# shellcheck disable=SC1090
[ -f "$CONF_FILE" ] && . "$CONF_FILE"

if [ -t 1 ]; then
    G=$'\033[0;32m'; R=$'\033[0;31m'; Y=$'\033[1;33m'; C=$'\033[0;36m'
    B=$'\033[1m'; D=$'\033[2m'; N=$'\033[0m'
else
    G=""; R=""; Y=""; C=""; B=""; D=""; N=""
fi

PASS=0; FAIL=0; WARN=0
ok()   { echo "  ${G}PASS${N}  $1"; PASS=$((PASS+1)); }
bad()  { echo "  ${R}FAIL${N}  $1"; FAIL=$((FAIL+1)); [ $# -gt 1 ] && echo "        ${D}fix: $2${N}"; }
warn() { echo "  ${Y}WARN${N}  $1"; WARN=$((WARN+1)); [ $# -gt 1 ] && echo "        ${D}fix: $2${N}"; }
info() { echo "  ${D}      $1${N}"; }
sect() { echo ""; echo "${B}-- $1 ${N}"; echo ""; }

[ "${EUID:-$(id -u)}" -ne 0 ] && { echo "Run with sudo:  sudo bash diagnose.sh"; exit 1; }

echo ""
echo "${C}${B}  Agentic AI stack - health report${N}"
echo "  ${D}$(date)   host: $(hostname)${N}"
echo ""

# --- 1. Did setup ever complete? ---------------------------------------------
sect "Installation"
if [ -f "$CONF_FILE" ]; then
    ok "Setup configuration found"
    info "domain=${DOMAIN:-?}  n8n=${N8N_HOSTNAME:-?}  claw=${CLAW_HOSTNAME:-?}"
else
    bad "No configuration at ${CONF_FILE}" "the setup script never finished - re-run vps_setup.sh"
fi
[ -f "${DEPLOY_DIR}/docker-compose.yml" ] \
    && ok "Compose file present" \
    || bad "No compose file at ${DEPLOY_DIR}" "re-run vps_setup.sh"

if [ -f /usr/local/bin/agentic ]; then
    ok "'agentic' helper installed"
else
    warn "'agentic' helper missing" "re-run vps_setup.sh"
fi

# --- 2. Resources -------------------------------------------------------------
sect "Resources"
RAM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
SWAP_MB=$(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo)
AVAIL_MB=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
DISK_PCT=$(df --output=pcent / | tail -n1 | tr -dc '0-9')

info "RAM ${RAM_MB} MB total, ${AVAIL_MB} MB available   |   swap ${SWAP_MB} MB   |   disk ${DISK_PCT}% used   |   $(nproc) vCPU"
[ "$RAM_MB" -ge 3500 ] && ok "RAM is adequate" || warn "Only ${RAM_MB} MB RAM - expect slowness"
[ "$SWAP_MB" -ge 1024 ] && ok "Swap configured (${SWAP_MB} MB)" \
    || warn "No swap - this is the usual cause of a 'laggy' server" "re-run vps_setup.sh to add swap"
[ "$AVAIL_MB" -ge 300 ] && ok "Free memory is healthy" || bad "Only ${AVAIL_MB} MB free - the server is thrashing"
[ "$DISK_PCT" -lt 85 ] && ok "Disk has room" || bad "Disk ${DISK_PCT}% full" "sudo docker system prune -a"

# --- 3. Services --------------------------------------------------------------
sect "Services"
for svc in docker nginx; do
    systemctl is-active --quiet "$svc" \
        && ok "${svc} is running" \
        || bad "${svc} is NOT running" "systemctl status ${svc}"
done

if command -v docker >/dev/null 2>&1; then
    for c in n8n openclaw-gateway; do
        state="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo missing)"
        restarts="$(docker inspect -f '{{.RestartCount}}' "$c" 2>/dev/null || echo 0)"
        case "$state" in
            running)
                if [ "${restarts:-0}" -gt 3 ]; then
                    warn "container '${c}' running but restarted ${restarts} times" "sudo agentic logs ${c}"
                else
                    ok "container '${c}' running"
                fi ;;
            missing) bad "container '${c}' does not exist" "cd ${DEPLOY_DIR} && sudo docker compose up -d" ;;
            *)       bad "container '${c}' is '${state}'" "sudo agentic logs ${c}" ;;
        esac
    done
fi

# --- 4. Local ports -----------------------------------------------------------
sect "Application health (inside the server)"
if curl -fsS --max-time 5 "http://127.0.0.1:${N8N_PORT}/healthz" >/dev/null 2>&1; then
    ok "n8n answers on 127.0.0.1:${N8N_PORT}"
else
    bad "n8n does not answer on port ${N8N_PORT}" "sudo agentic logs n8n"
fi

if curl -fsS --max-time 5 "http://127.0.0.1:${OPENCLAW_PORT}/healthz" >/dev/null 2>&1; then
    ok "OpenClaw answers on 127.0.0.1:${OPENCLAW_PORT}"
else
    bad "OpenClaw does not answer on port ${OPENCLAW_PORT}" "sudo agentic logs claw"
    if ss -tlnp 2>/dev/null | grep -q ':8080'; then
        info "Something is listening on 8080. OpenClaw's real port is ${OPENCLAW_PORT}, not 8080."
    fi
fi

if [ -f "${DEPLOY_DIR}/stack.env" ]; then
    tok="$(grep -m1 '^OPENCLAW_GATEWAY_TOKEN=' "${DEPLOY_DIR}/stack.env" | cut -d= -f2-)"
    if [ -z "$tok" ]; then
        bad "No dashboard password set - OpenClaw login will fail" "re-run vps_setup.sh"
    elif [ "${#tok}" -lt 12 ]; then
        warn "Dashboard password is only ${#tok} characters" "re-run vps_setup.sh and choose a longer one"
    else
        ok "OpenClaw dashboard password is set (${#tok} characters)"
        info "forgotten it? run: sudo agentic token"
    fi
    perm="$(stat -c '%a' "${DEPLOY_DIR}/stack.env")"
    [ "$perm" = "600" ] && ok "Secrets file permissions are correct (600)" \
        || warn "stack.env is mode ${perm}" "sudo chmod 600 ${DEPLOY_DIR}/stack.env"
fi

# --- 5. DNS -------------------------------------------------------------------
sect "DNS"
MYIP="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || echo "${VPS_IP:-}")"
info "This server's public IP: ${MYIP:-unknown}"
if command -v dig >/dev/null 2>&1; then
    for h in "$N8N_HOSTNAME" "$CLAW_HOSTNAME"; do
        [ -z "$h" ] && continue
        a="$(dig +short A "$h" @1.1.1.1 2>/dev/null | grep -Eo '^[0-9]+(\.[0-9]+){3}$' | tail -n1)"
        v6="$(dig +short AAAA "$h" @1.1.1.1 2>/dev/null | grep ':' | tail -n1)"
        if [ -z "$a" ]; then
            bad "${h} has no A record" "add: Type A, Name ${h%%.*}, Value ${MYIP}"
        elif [ "$a" = "$MYIP" ]; then
            ok "${h} -> ${a}"
        else
            bad "${h} -> ${a} (should be ${MYIP})" "correct the A record at your domain provider"
        fi
        [ -n "$v6" ] && warn "${h} also has an IPv6 record ${v6}" "delete the AAAA record - it breaks Let's Encrypt on IPv4-only servers"
    done
else
    warn "'dig' not installed, skipping DNS checks" "apt install -y dnsutils"
fi

# --- 6. TLS -------------------------------------------------------------------
sect "SSL certificate"
CERT="/etc/letsencrypt/live/${N8N_HOSTNAME}/fullchain.pem"
if [ -n "$N8N_HOSTNAME" ] && [ -f "$CERT" ]; then
    end="$(openssl x509 -enddate -noout -in "$CERT" 2>/dev/null | cut -d= -f2)"
    end_epoch="$(date -d "$end" +%s 2>/dev/null || echo 0)"
    days=$(( (end_epoch - $(date +%s)) / 86400 ))
    issuer="$(openssl x509 -issuer -noout -in "$CERT" 2>/dev/null | sed 's/.*CN *= *//')"
    sans="$(openssl x509 -noout -text -in "$CERT" 2>/dev/null | grep -A1 'Subject Alternative Name' | tail -n1 | tr -d ' ')"

    if [ "$days" -gt 0 ]; then ok "Certificate valid for ${days} more days"; else bad "Certificate EXPIRED" "sudo agentic ssl"; fi
    info "issued by: ${issuer}"
    case "$issuer" in
        *"Let's Encrypt"*|*R1*|*R3*|*E1*|*E5*|*E6*|*R10*|*R11*) ok "Issued by a trusted authority" ;;
        *) warn "Issuer '${issuer}' may not be trusted by browsers" "sudo agentic ssl" ;;
    esac
    for h in "$N8N_HOSTNAME" "$CLAW_HOSTNAME"; do
        [ -z "$h" ] && continue
        case "$sans" in
            *"DNS:${h}"*) ok "${h} is covered by the certificate" ;;
            *)            bad "${h} is NOT on the certificate" "sudo agentic ssl" ;;
        esac
    done
else
    bad "No certificate found" "sudo agentic ssl"
fi

# --- 7. End-to-end from the public internet -----------------------------------
sect "Public access (what your browser sees)"
for h in "$N8N_HOSTNAME" "$CLAW_HOSTNAME"; do
    [ -z "$h" ] && continue
    code="$(curl -o /dev/null -sS -w '%{http_code}' --max-time 12 "https://${h}" 2>/dev/null || echo 000)"
    case "$code" in
        200|302|401|403) ok "https://${h} responds with HTTP ${code}" ;;
        000)             bad "https://${h} is unreachable" "check DNS, SSL and the firewall" ;;
        502|503|504)     bad "https://${h} returns ${code} - Nginx is up but the app behind it is not" "sudo agentic status" ;;
        *)               warn "https://${h} returns HTTP ${code}" ;;
    esac
    # TLS chain check exactly as a browser would do it
    if ! echo | timeout 12 openssl s_client -connect "${h}:443" -servername "$h" -verify_return_error >/dev/null 2>&1; then
        bad "TLS handshake for ${h} fails browser-grade verification" "sudo agentic ssl"
    else
        ok "TLS chain for ${h} verifies cleanly"
        info "if Chrome still shows a red page, it is Google Safe Browsing, not SSL - see below"
    fi
done

# --- 8. Firewall --------------------------------------------------------------
sect "Firewall"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ok "UFW is active"
    for p in 80 443; do
        ufw status | grep -q "^${p}/tcp" && ok "port ${p} allowed" || bad "port ${p} is blocked" "sudo ufw allow ${p}/tcp"
    done
    if ufw status | grep -qE "^(${OPENCLAW_PORT}|${N8N_PORT})"; then
        warn "App ports are open to the internet" "sudo ufw delete allow ${OPENCLAW_PORT}; sudo ufw delete allow ${N8N_PORT}"
    else
        ok "App ports are not exposed directly (correct - Nginx fronts them)"
    fi
else
    warn "UFW is not active" "re-run vps_setup.sh"
fi

# --- Safe Browsing reminder ---------------------------------------------------
# Nothing here can be probed from the server: Google's Safe Browsing verdict
# lives in the browser. So this is guidance, not a check.
sect "If Chrome shows a red \"Deceptive site ahead\" page"
echo "  That is Google Safe Browsing, ${B}not${N} your SSL certificate."
echo "  Self-hosted n8n gets false-flagged from time to time."
echo ""
echo "  Keep working:  click ${B}Details${N} on the red page, then ${B}visit this unsafe site${N}."
echo "  Clear it:      ${C}https://search.google.com/search-console${N}"
echo "                 add a ${B}Domain${N} property for ${B}${DOMAIN:-your-domain}${N}, then"
echo "                 ${B}Security Issues${N} -> ${B}Request Review${N}"
echo "  Check status:  ${C}https://transparencyreport.google.com/safe-browsing/search${N}"
echo ""
echo "  ${D}On the server, run 'sudo agentic safebrowsing' for the same steps.${N}"

# --- Summary ------------------------------------------------------------------
echo ""
echo "${B}================================================================${N}"
printf "  ${G}%d passed${N}    ${Y}%d warnings${N}    ${R}%d failed${N}\n" "$PASS" "$WARN" "$FAIL"
echo "${B}================================================================${N}"
echo ""
if [ "$FAIL" -eq 0 ] && [ "$WARN" -eq 0 ]; then
    echo "  ${G}${B}Everything checks out.${N}"
elif [ "$FAIL" -eq 0 ]; then
    echo "  Nothing is broken. Review the warnings above when you have time."
else
    echo "  Work through the ${R}FAIL${N} lines top to bottom - each one shows its fix."
    echo "  Most problems are solved by re-running the setup script; it is safe to re-run."
fi
echo ""
