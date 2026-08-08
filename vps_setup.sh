#!/usr/bin/env bash
# =============================================================================
#   CODED Agentic AI Bootcamp - Automated VPS Setup
#
#   Deploys: n8n  -> https://n8n.<domain>
#            OpenClaw dashboard -> https://claw.<domain>
#   Behind:  Nginx + Let's Encrypt, Docker Compose, UFW
#
#   Author: Eng. Abdullah Alenezi
#   Version: 3.0.2
#
#   Safe to re-run. Every phase is idempotent.
# =============================================================================

set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

SCRIPT_VERSION="3.0.2"
DEPLOY_DIR="/opt/agentic-stack"
CONF_FILE="/etc/agentic-stack.conf"
CREDS_FILE="/root/AGENTIC-CREDENTIALS.txt"
LOG_FILE="/var/log/agentic-setup.log"
WEBROOT="/var/www/acme"
OPENCLAW_PORT=18789
N8N_PORT=5678
DOCKER_SUBNET="172.28.0.0/16"
DOCKER_GW="172.28.0.1"

# --- Colors ------------------------------------------------------------------
if [ -t 1 ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; MAGENTA=$'\033[0;35m'
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; MAGENTA=""
    BOLD=""; DIM=""; RESET=""
fi

# --- Output helpers ----------------------------------------------------------
_log() { printf '%s %s\n' "$(date '+%F %T')" "$1" >>"$LOG_FILE" 2>/dev/null || true; }

print_phase() {
    echo ""
    echo "${MAGENTA}${BOLD}================================================================${RESET}"
    echo "${MAGENTA}${BOLD}  $1${RESET}"
    echo "${MAGENTA}${BOLD}================================================================${RESET}"
    echo ""
    _log "PHASE: $1"
}
print_step() { echo "  ${BLUE}>${RESET} $1"; _log "STEP: $1"; }
print_ok()   { echo "  ${GREEN}[ OK ]${RESET} $1"; _log "OK: $1"; }
print_warn() { echo "  ${YELLOW}[WARN]${RESET} ${YELLOW}$1${RESET}"; _log "WARN: $1"; }
print_error(){ echo "  ${RED}[FAIL]${RESET} ${RED}$1${RESET}"; _log "FAIL: $1"; }
print_info() { echo "  ${DIM}[info] $1${RESET}"; _log "INFO: $1"; }
separator()  { echo "${DIM}  ----------------------------------------------------------------${RESET}"; }

die() {
    echo ""
    print_error "$1"
    echo ""
    print_info "Full setup log: ${LOG_FILE}"
    print_info "Last command output: /tmp/agentic_last.log"
    exit 1
}

on_error() {
    local exit_code=$?
    local line=${1:-?}
    echo ""
    print_error "Setup stopped unexpectedly (exit ${exit_code}, line ${line})."
    if [ -s /tmp/agentic_last.log ]; then
        echo ""
        print_info "Last command output:"
        tail -n 40 /tmp/agentic_last.log
    fi
    echo ""
    print_info "Nothing is broken - you can safely re-run this script after fixing the cause."
    print_info "Full log: ${LOG_FILE}"
    exit "$exit_code"
}
trap 'on_error $LINENO' ERR

# --- Input helpers -----------------------------------------------------------
ask() {
    local __var="$1" prompt="$2" default="${3:-}" value=""
    while :; do
        if [ -n "$default" ]; then
            read -rp "  ${CYAN}?${RESET} ${prompt} ${DIM}[${default}]${RESET}: " value || true
            value="${value:-$default}"
        else
            read -rp "  ${CYAN}?${RESET} ${prompt}: " value || true
        fi
        value="$(echo "$value" | tr -d '[:space:]')"
        [ -n "$value" ] && break
        print_warn "This cannot be empty."
    done
    printf -v "$__var" '%s' "$value"
}

ask_secret() {
    # Trims surrounding whitespace only. Stripping inner characters would
    # silently change what the user thinks they typed - the worst possible
    # outcome for a password they must retype in a browser later.
    local __var="$1" prompt="$2" minlen="${3:-1}" value=""
    while :; do
        read -rsp "  ${CYAN}?${RESET} ${prompt}: " value || true
        echo ""
        value="${value#"${value%%[![:space:]]*}"}"   # trim leading
        value="${value%"${value##*[![:space:]]}"}"   # trim trailing
        if [ "${#value}" -lt "$minlen" ]; then
            print_warn "Must be at least ${minlen} characters. You entered ${#value}."
            continue
        fi
        break
    done
    printf -v "$__var" '%s' "$value"
}

confirm() {
    local answer=""
    read -rp "  ${CYAN}?${RESET} $1 ${DIM}[y/N]${RESET}: " answer || true
    [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

choose() {
    # choose VAR "Prompt" "opt1" "opt2" ...
    local __var="$1" prompt="$2"; shift 2
    local opts=("$@") i choice
    echo ""
    for i in "${!opts[@]}"; do
        printf "     ${BOLD}%d${RESET}) %s\n" "$((i + 1))" "${opts[$i]}"
    done
    echo ""
    while :; do
        read -rp "  ${CYAN}?${RESET} ${prompt} [1-${#opts[@]}]: " choice || true
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#opts[@]}" ]; then
            printf -v "$__var" '%s' "$choice"
            return
        fi
        print_warn "Enter a number between 1 and ${#opts[@]}."
    done
}

# --- Command runner with spinner --------------------------------------------
_spin_pid=""
_spin_stop() {
    if [ -n "$_spin_pid" ]; then
        kill "$_spin_pid" 2>/dev/null || true
        wait "$_spin_pid" 2>/dev/null || true
        _spin_pid=""
    fi
}
trap '_spin_stop' EXIT

run_step() {
    # run_step "Message" cmd args...
    local msg="$1"; shift
    if [ -t 1 ]; then
        (
            local chars='|/-\' i=0
            while :; do
                printf "\r  ${BLUE}%s${RESET} %s " "${chars:$((i % 4)):1}" "$msg"
                sleep 0.15
                i=$(( (i + 1) % 4 ))
            done
        ) &
        _spin_pid=$!
    else
        printf "  > %s\n" "$msg"
    fi

    local rc=0
    "$@" >/tmp/agentic_last.log 2>&1 || rc=$?
    _spin_stop
    [ -t 1 ] && printf "\r\033[K"

    if [ "$rc" -eq 0 ]; then
        print_ok "$msg"
        _log "CMD OK: $*"
        return 0
    fi
    print_error "$msg"
    _log "CMD FAIL ($rc): $*"
    echo ""
    tail -n 30 /tmp/agentic_last.log
    echo ""
    die "Step failed: ${msg}"
}

run_soft() {
    # Same as run_step but never aborts the script.
    local msg="$1"; shift
    local rc=0
    "$@" >/tmp/agentic_last.log 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then print_ok "$msg"; return 0; fi
    print_warn "${msg} - skipped (non-fatal)"
    _log "SOFT FAIL ($rc): $*"
    return 1
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

# =============================================================================
#   PRE-FLIGHT
# =============================================================================
clear
echo "${CYAN}${BOLD}"
cat <<'BANNER'
  +==================================================================+
  |            CODED - Agentic AI Bootcamp VPS Setup                 |
  |          n8n  +  OpenClaw  +  Nginx  +  Free SSL                 |
  +==================================================================+
BANNER
echo "${RESET}"
echo "  ${DIM}version ${SCRIPT_VERSION}${RESET}"
echo ""

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    print_error "This script must run as root."
    print_info  "Run:  sudo bash $0"
    exit 1
fi

touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/agentic-setup.log"
chmod 600 "$LOG_FILE" 2>/dev/null || true
_log "=== Setup started (v${SCRIPT_VERSION}) ==="

# OS sanity check
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [ "${ID:-}" != "ubuntu" ] && [[ "${ID_LIKE:-}" != *debian* ]]; then
        print_warn "This script targets Ubuntu. Detected: ${PRETTY_NAME:-unknown}"
        confirm "Continue anyway?" || exit 0
    else
        print_ok "Operating system: ${PRETTY_NAME:-Ubuntu}"
    fi
fi

# Architecture check
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64|aarch64|arm64) print_ok "Architecture: ${ARCH}" ;;
    *) print_warn "Unusual architecture '${ARCH}'. Docker images may not be available." ;;
esac

# Resource check
TOTAL_RAM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
CPU_CORES=$(nproc)
DISK_FREE_GB=$(df -BG --output=avail / | tail -n1 | tr -dc '0-9')
print_ok "Resources: ${CPU_CORES} vCPU, ${TOTAL_RAM_MB} MB RAM, ${DISK_FREE_GB} GB free disk"

if [ "$TOTAL_RAM_MB" -lt 3500 ]; then
    print_warn "Less than 4 GB RAM detected. n8n + OpenClaw will be slow."
    print_info "A swap file will be created to keep the stack stable."
fi
if [ "$DISK_FREE_GB" -lt 10 ]; then
    print_warn "Less than 10 GB free disk. Docker images need roughly 5 GB."
fi

# =============================================================================
#   PHASE 1 - Configuration
# =============================================================================
print_phase "PHASE 1 / 9  --  Configuration"

# Reload previous answers when re-running.
REUSE_CONFIG=false
if [ -f "$CONF_FILE" ]; then
    print_info "A previous setup was found on this server."
    if confirm "Re-use the previous answers (domain, email, timezone)?"; then
        # shellcheck disable=SC1090
        . "$CONF_FILE"
        REUSE_CONFIG=true
        print_ok "Loaded previous configuration from ${CONF_FILE}"
    fi
fi

# --- Public IP ---
DETECTED_IP="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
[ -z "$DETECTED_IP" ] && DETECTED_IP="$(curl -4 -fsS --max-time 8 https://ifconfig.me 2>/dev/null || true)"
[ -z "$DETECTED_IP" ] && DETECTED_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

if [ -n "$DETECTED_IP" ]; then
    print_ok "Detected public IP: ${BOLD}${DETECTED_IP}${RESET}"
    VPS_IP="$DETECTED_IP"
else
    ask VPS_IP "Enter your VPS public IP address"
fi

# --- Domain ---
if [ "$REUSE_CONFIG" = false ] || [ -z "${DOMAIN:-}" ]; then
    while :; do
        ask DOMAIN "Enter your root domain (example: my-agent.com)"
        DOMAIN="${DOMAIN#http://}"; DOMAIN="${DOMAIN#https://}"; DOMAIN="${DOMAIN%%/*}"
        DOMAIN="$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]')"
        if [[ "$DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
            break
        fi
        print_warn "That does not look like a domain. Enter it without http:// and without a subdomain."
    done
fi

N8N_HOSTNAME="n8n.${DOMAIN}"
CLAW_HOSTNAME="claw.${DOMAIN}"

echo ""
print_info "n8n will live at             https://${N8N_HOSTNAME}"
print_info "OpenClaw dashboard will be   https://${CLAW_HOSTNAME}"
echo ""
echo "  ${BOLD}${YELLOW}You need TWO DNS 'A' records at your domain provider:${RESET}"
echo ""
echo "     Type: A   Name: ${BOLD}n8n${RESET}    Value: ${BOLD}${VPS_IP}${RESET}   TTL: lowest available"
echo "     Type: A   Name: ${BOLD}claw${RESET}   Value: ${BOLD}${VPS_IP}${RESET}   TTL: lowest available"
echo ""
print_info "If you already added only 'n8n', add 'claw' now - the script will wait for it."
print_info "Also delete any AAAA (IPv6) records on those names - they break SSL here."
echo ""

# --- Email ---
if [ "$REUSE_CONFIG" = false ] || [ -z "${CERTBOT_EMAIL:-}" ]; then
    while :; do
        ask CERTBOT_EMAIL "Your email address (Let's Encrypt expiry alerts)"
        [[ "$CERTBOT_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[a-zA-Z]{2,}$ ]] && break
        print_warn "That does not look like a valid email address."
    done
fi

# --- Timezone ---
if [ "$REUSE_CONFIG" = false ] || [ -z "${TIMEZONE:-}" ]; then
    ask TIMEZONE "Your timezone (used by n8n schedules)" "Asia/Kuwait"
    if [ ! -f "/usr/share/zoneinfo/${TIMEZONE}" ]; then
        print_warn "Unknown timezone '${TIMEZONE}'. Falling back to UTC."
        TIMEZONE="UTC"
    fi
fi

# --- OpenClaw dashboard password (the gateway token) -------------------------
# The trainee chooses this so they can remember it. It guards a dashboard that
# is reachable from the public internet, so it is checked like a password:
# 12 characters minimum, typed twice, obvious choices rejected.
echo ""
separator
echo ""
echo "  ${BOLD}OpenClaw dashboard password${RESET}"
print_info "You will type this into https://${CLAW_HOSTNAME} to open your dashboard."
print_info "OpenClaw calls it the 'gateway token'. Choose something you will remember."
print_warn "This dashboard is reachable from the internet - do not use a short or obvious password."
echo ""

EXISTING_TOKEN=""
if [ -f "${DEPLOY_DIR}/stack.env" ]; then
    EXISTING_TOKEN="$(grep -m1 '^OPENCLAW_GATEWAY_TOKEN=' "${DEPLOY_DIR}/stack.env" 2>/dev/null | cut -d= -f2- || true)"
fi

KEEP_TOKEN=false
if [ -n "$EXISTING_TOKEN" ]; then
    print_info "This server already has a dashboard password set."
    confirm "Keep the existing password?" && KEEP_TOKEN=true
fi

if [ "$KEEP_TOKEN" = true ]; then
    OPENCLAW_GATEWAY_TOKEN="$EXISTING_TOKEN"
    print_ok "Keeping your existing dashboard password"
else
    print_info "Allowed: letters, numbers and symbols such as ! @ # - _ . +"
    print_info "Not allowed: spaces, \$, quotes and backslashes (they break config files)."
    echo ""
    # Held in a variable: an inline regex containing ';' breaks [[ ]] parsing.
    TOKEN_RE='^[A-Za-z0-9@#%^*()_+=~,.?!:/-]+$'
    while :; do
        ask_secret OPENCLAW_GATEWAY_TOKEN "Choose your dashboard password (12+ characters)" 12

        if [[ ! "$OPENCLAW_GATEWAY_TOKEN" =~ $TOKEN_RE ]]; then
            print_warn "That contains a character we cannot use safely. Avoid spaces, \$, quotes and backslashes."
            continue
        fi
        case "${OPENCLAW_GATEWAY_TOKEN,,}" in
            password*|12345678*|qwerty*|openclaw*|changeme*|admin*|letmein*)
                print_warn "That password is too easy to guess. Pick another one."
                continue ;;
        esac

        ask_secret TOKEN_CONFIRM "Type it once more to confirm" 12
        if [ "$OPENCLAW_GATEWAY_TOKEN" = "$TOKEN_CONFIRM" ]; then
            unset TOKEN_CONFIRM
            print_ok "Dashboard password set (${#OPENCLAW_GATEWAY_TOKEN} characters)"
            break
        fi
        print_warn "The two entries do not match. Try again."
    done
fi

# --- AI provider ---
echo ""
separator
echo ""
echo "  ${BOLD}Which AI provider should OpenClaw use?${RESET}"
choose AI_CHOICE "Select provider" \
    "Anthropic Claude   (recommended for this bootcamp)" \
    "OpenAI             (GPT models)" \
    "Google Gemini      (has a free tier)"

case "$AI_CHOICE" in
    1) AI_PROVIDER="anthropic"
       AI_LABEL="Anthropic Claude"
       API_KEY_ENV="ANTHROPIC_API_KEY"
       AI_MODEL_DEFAULT="anthropic/claude-sonnet-4-6"
       KEY_URL="https://console.anthropic.com/settings/keys" ;;
    2) AI_PROVIDER="openai"
       AI_LABEL="OpenAI"
       API_KEY_ENV="OPENAI_API_KEY"
       AI_MODEL_DEFAULT="openai/gpt-5.6"
       KEY_URL="https://platform.openai.com/api-keys" ;;
    3) AI_PROVIDER="google"
       AI_LABEL="Google Gemini"
       API_KEY_ENV="GEMINI_API_KEY"
       AI_MODEL_DEFAULT=""
       KEY_URL="https://aistudio.google.com/app/apikey" ;;
esac

echo ""
print_info "Get your key here: ${KEY_URL}"
print_info "The key is hidden while you type or paste it. Paste, then press Enter."
ask_secret AI_API_KEY "${AI_LABEL} API key" 8

# The exact model is chosen later from the live list OpenClaw reports,
# so this script never hard-codes model names that go stale.

# --- Summary ---
echo ""
print_phase "Review your settings"
printf "  %-22s %s\n" "VPS IP:"        "${CYAN}${VPS_IP}${RESET}"
printf "  %-22s %s\n" "Root domain:"   "${CYAN}${DOMAIN}${RESET}"
printf "  %-22s %s\n" "n8n URL:"       "${CYAN}https://${N8N_HOSTNAME}${RESET}"
printf "  %-22s %s\n" "OpenClaw URL:"  "${CYAN}https://${CLAW_HOSTNAME}${RESET}"
printf "  %-22s %s\n" "SSL email:"     "${CYAN}${CERTBOT_EMAIL}${RESET}"
printf "  %-22s %s\n" "Timezone:"      "${CYAN}${TIMEZONE}${RESET}"
printf "  %-22s %s\n" "AI provider:"   "${CYAN}${AI_LABEL}${RESET}"
printf "  %-22s %s\n" "API key:"       "${DIM}hidden (${#AI_API_KEY} characters)${RESET}"
printf "  %-22s %s\n" "Dashboard pass:" "${DIM}hidden (${#OPENCLAW_GATEWAY_TOKEN} characters) - the one you chose${RESET}"
echo ""
print_info "You will create your n8n account in the browser after setup - n8n handles that itself now."
echo ""
confirm "Start the installation?" || { print_info "Cancelled. Nothing was changed."; exit 0; }

# Persist non-secret answers for re-runs.
umask 077
cat >"$CONF_FILE" <<EOF
# Written by vps_setup.sh v${SCRIPT_VERSION} on $(date -Is)
DOMAIN="${DOMAIN}"
N8N_HOSTNAME="${N8N_HOSTNAME}"
CLAW_HOSTNAME="${CLAW_HOSTNAME}"
CERTBOT_EMAIL="${CERTBOT_EMAIL}"
TIMEZONE="${TIMEZONE}"
VPS_IP="${VPS_IP}"
DEPLOY_DIR="${DEPLOY_DIR}"
EOF
chmod 600 "$CONF_FILE"
umask 022   # restore: later steps create directories Nginx and Docker must read

# =============================================================================
#   PHASE 2 - Base system, swap, firewall
# =============================================================================
print_phase "PHASE 2 / 9  --  System, swap and firewall"

APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

run_step "Refreshing package lists"        apt-get update
run_step "Installing base tools"           apt-get install "${APT_OPTS[@]}" \
    curl wget ca-certificates gnupg lsb-release ufw dnsutils jq openssl \
    apt-transport-https software-properties-common

# Upgrade is slow and rarely required for a fresh VPS; make it opt-in but default yes.
if confirm "Install pending security updates now? (recommended, adds 1-3 minutes)"; then
    run_step "Upgrading installed packages" apt-get upgrade "${APT_OPTS[@]}"
fi

# --- Timezone ---
run_soft "Setting system timezone to ${TIMEZONE}" timedatectl set-timezone "$TIMEZONE" || true

# --- Swap: the single biggest cause of a "laggy" 4 GB VPS ---
print_step "Checking swap space ..."
CURRENT_SWAP_MB=$(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo)
if [ "$CURRENT_SWAP_MB" -ge 1024 ]; then
    print_ok "Swap already configured (${CURRENT_SWAP_MB} MB)"
elif [ "$DISK_FREE_GB" -lt 8 ]; then
    print_warn "Not enough free disk to create swap safely. Skipping."
else
    SWAP_GB=2
    [ "$TOTAL_RAM_MB" -lt 2500 ] && SWAP_GB=4
    SWAP_MADE=true
    if [ ! -f /swapfile ]; then
        # fallocate is instant but unsupported on some filesystems; dd always works.
        if ! run_soft "Creating ${SWAP_GB} GB swap file" fallocate -l "${SWAP_GB}G" /swapfile; then
            run_soft "Creating ${SWAP_GB} GB swap file (slow method)" \
                dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_GB * 1024)) status=none || SWAP_MADE=false
        fi
        if [ "$SWAP_MADE" = true ]; then
            chmod 600 /swapfile
            run_soft "Formatting swap file" mkswap /swapfile || SWAP_MADE=false
        fi
    fi
    if [ "$SWAP_MADE" = true ] && run_soft "Activating swap" swapon /swapfile; then
        grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
        sysctl -qw vm.swappiness=10 >/dev/null 2>&1 || true
        grep -q '^vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >>/etc/sysctl.conf
        print_ok "Swap active (${SWAP_GB} GB, swappiness=10)"
    else
        rm -f /swapfile
        print_warn "Could not create swap. The stack will still run but may be slower."
    fi
fi

# --- Firewall (detect the real SSH port so nobody gets locked out) ---
print_step "Configuring UFW firewall ..."
SSH_PORTS="$(sshd -T 2>/dev/null | awk '/^port /{print $2}' | sort -u || true)"
[ -z "$SSH_PORTS" ] && SSH_PORTS="$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/{print $2}' /etc/ssh/sshd_config 2>/dev/null | sort -u || true)"
[ -z "$SSH_PORTS" ] && SSH_PORTS="22"

# If UFW is already configured, this server probably runs other things too.
# Resetting would silently close ports someone else's service depends on, so
# only add what the stack needs and leave existing rules untouched.
if ufw status 2>/dev/null | grep -q 'Status: active'; then
    print_info "UFW is already active - adding our rules without touching your existing ones."
else
    ufw --force reset          >/dev/null 2>&1
    ufw default deny incoming  >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1
fi

for p in $SSH_PORTS; do
    ufw allow "${p}/tcp" >/dev/null 2>&1
    print_info "Allowed SSH on port ${p}"
done
ufw allow 80/tcp   >/dev/null 2>&1
ufw allow 443/tcp  >/dev/null 2>&1
ufw --force enable >/dev/null 2>&1
print_ok "Firewall active: SSH (${SSH_PORTS// /, }), HTTP 80, HTTPS 443"
print_info "Ports ${N8N_PORT} and ${OPENCLAW_PORT} stay closed - both apps are reachable only through Nginx."

# =============================================================================
#   PHASE 3 - DNS verification (waits instead of failing)
# =============================================================================
print_phase "PHASE 3 / 9  --  DNS verification"

# Note the trailing '|| true': under `set -o pipefail` a non-matching grep
# would otherwise make the whole assignment fail and abort the script.
resolve_a()    { dig +short A    "$1" @1.1.1.1 2>/dev/null | grep -Eo '^[0-9]+(\.[0-9]+){3}$' | tail -n1 || true; }
resolve_aaaa() { dig +short AAAA "$1" @1.1.1.1 2>/dev/null | grep -E ':'                      | tail -n1 || true; }

dns_ready() {
    local host="$1" got=""
    got="$(resolve_a "$host")" || true
    [ -n "$got" ] && [ "$got" = "$VPS_IP" ]
}

HOST_HAS_IPV6=false
if [ -f /proc/net/if_inet6 ] && ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'; then
    HOST_HAS_IPV6=true
fi

wait_for_dns() {
    local host="$1" tries=0 max=40 got=""
    while [ "$tries" -lt "$max" ]; do
        if dns_ready "$host"; then
            print_ok "${host} -> ${VPS_IP}"
            return 0
        fi
        got="$(resolve_a "$host")" || true
        if [ "$tries" -eq 0 ]; then
            print_warn "${host} resolves to '${got:-nothing}' but should be ${VPS_IP}"
            print_info "Waiting for DNS to propagate. This takes 1-30 minutes."
            print_info "Press Ctrl+C to abort, fix the DNS record, and re-run this script."
        fi
        printf "\r  ${DIM}waiting for %s ... %d/%d${RESET}   " "$host" "$((tries + 1))" "$max"
        sleep 15
        tries=$((tries + 1))
    done
    printf "\r\033[K"
    return 1
}

DNS_ALL_OK=true
for host in "$N8N_HOSTNAME" "$CLAW_HOSTNAME"; do
    if ! wait_for_dns "$host"; then
        print_error "${host} still does not point to ${VPS_IP}"
        DNS_ALL_OK=false
    fi
    # An AAAA record on a server without working IPv6 makes Let's Encrypt fail:
    # the CA prefers IPv6 and never falls back to IPv4.
    v6="$(resolve_aaaa "$host")" || true
    if [ -n "$v6" ] && [ "$HOST_HAS_IPV6" = false ]; then
        print_error "${host} has an AAAA (IPv6) record: ${v6}"
        print_warn  "This server has no IPv6, so Let's Encrypt will try IPv6 first and fail."
        print_warn  "DELETE the AAAA record for '${host%%.*}' at your domain provider, then re-run."
        DNS_ALL_OK=false
    fi
done

if [ "$DNS_ALL_OK" = false ]; then
    echo ""
    print_warn "DNS is not fully ready. SSL certificates will fail."
    print_info "The rest of the setup will still run; you can issue SSL later with:  agentic ssl"
    echo ""
    confirm "Continue without valid DNS?" || { print_info "Fix the DNS records and re-run this script."; exit 0; }
fi

# =============================================================================
#   PHASE 4 - Docker
# =============================================================================
print_phase "PHASE 4 / 9  --  Docker Engine"

if command_exists docker && docker compose version >/dev/null 2>&1; then
    print_ok "Docker already installed: $(docker --version | cut -d, -f1)"
else
    run_step "Downloading Docker installer" curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    run_step "Installing Docker Engine (takes 1-2 minutes)" sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh
fi

run_step "Enabling Docker at boot" systemctl enable --now docker

if ! docker compose version >/dev/null 2>&1; then
    run_step "Installing Docker Compose plugin" apt-get install "${APT_OPTS[@]}" docker-compose-plugin
fi
print_ok "Docker Compose: $(docker compose version --short 2>/dev/null || echo installed)"

# Cap container log growth - unbounded JSON logs fill small VPS disks.
if [ ! -f /etc/docker/daemon.json ]; then
    mkdir -p /etc/docker
    cat >/etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
    run_soft "Applying Docker log rotation" systemctl restart docker || true
fi

# =============================================================================
#   PHASE 5 - Stack files
# =============================================================================
print_phase "PHASE 5 / 9  --  Writing the stack configuration"

# --- Migration from setup v2 -------------------------------------------------
# v2 ran OpenClaw in a container called "openclaw" published on port 8080,
# which was never the port the gateway listens on. It is not in the new compose
# file, so Compose would leave it running as an orphan - wasting memory on a
# small VPS and confusing anyone reading `docker ps`. Its named volume is left
# alone; only the dead container goes.
if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'openclaw'; then
    print_warn "Found the old 'openclaw' container from the previous setup."
    print_info "It was bound to port 8080, which the gateway never listened on."
    run_soft "Removing the old OpenClaw container" docker rm -f openclaw || true
fi

mkdir -p "$DEPLOY_DIR"/{openclaw,openclaw-workspace,openclaw-secrets}
chmod 700 "$DEPLOY_DIR"

# The OpenClaw container runs as uid/gid 1000 (user "node").
chown -R 1000:1000 "$DEPLOY_DIR"/openclaw "$DEPLOY_DIR"/openclaw-workspace "$DEPLOY_DIR"/openclaw-secrets

# --- Secrets: generated once, reused on every re-run -------------------------
load_or_create_secret() {
    # load_or_create_secret VAR_NAME <generator>
    local key="$1" gen="$2" existing=""
    if [ -f "${DEPLOY_DIR}/stack.env" ]; then
        existing="$(grep -m1 "^${key}=" "${DEPLOY_DIR}/stack.env" 2>/dev/null | cut -d= -f2- || true)"
    fi
    if [ -n "$existing" ]; then
        printf '%s' "$existing"
    else
        eval "$gen"
    fi
}

# OPENCLAW_GATEWAY_TOKEN is the password the trainee chose in Phase 1.
#
# The n8n encryption key is internal and never shown, but it is the one value
# that must never change: n8n encrypts saved credentials with it. On its very
# first start n8n generates one and writes it to config inside its volume. If we
# then hand it a DIFFERENT key through the environment, n8n refuses to boot with
# "Mismatching encryption keys". So: if a volume already exists, its key wins.
print_step "Checking for existing n8n data ..."
EXISTING_N8N_KEY=""
N8N_VOLUME=""
for v in "$(basename "$DEPLOY_DIR")_n8n_data" "agentic-stack_n8n_data"; do
    if docker volume inspect "$v" >/dev/null 2>&1; then N8N_VOLUME="$v"; break; fi
done
if [ -n "$N8N_VOLUME" ]; then
    VOL_PATH="$(docker volume inspect -f '{{.Mountpoint}}' "$N8N_VOLUME" 2>/dev/null || true)"
    if [ -n "$VOL_PATH" ] && [ -f "${VOL_PATH}/config" ]; then
        EXISTING_N8N_KEY="$(jq -r '.encryptionKey // empty' "${VOL_PATH}/config" 2>/dev/null || true)"
        # Fall back to plain text extraction if jq is missing or the file is
        # not clean JSON. Getting this wrong bricks the trainee's n8n, so it
        # is worth a second attempt rather than silently generating a new key.
        if [ -z "$EXISTING_N8N_KEY" ]; then
            EXISTING_N8N_KEY="$(grep -o '"encryptionKey"[[:space:]]*:[[:space:]]*"[^"]*"' "${VOL_PATH}/config" 2>/dev/null \
                | head -n1 | sed 's/.*:[[:space:]]*"\(.*\)"$/\1/' || true)"
        fi
    fi
fi

# Safety net: an existing volume whose key we could not read must not be handed
# a new one. Leaving N8N_ENCRYPTION_KEY unset lets n8n keep using its own.
if [ -n "$N8N_VOLUME" ] && [ -z "$EXISTING_N8N_KEY" ] && [ ! -f "${DEPLOY_DIR}/stack.env" ]; then
    print_warn "An n8n volume exists but its encryption key could not be read."
    print_info "Letting n8n manage its own key so your saved credentials keep working."
    SKIP_N8N_KEY=true
else
    SKIP_N8N_KEY=false
fi

N8N_ENCRYPTION_KEY=""
if [ "$SKIP_N8N_KEY" = true ]; then
    :
elif [ -n "$EXISTING_N8N_KEY" ]; then
    N8N_ENCRYPTION_KEY="$EXISTING_N8N_KEY"
    print_ok "Found your existing n8n data - keeping its encryption key"
    print_info "Your workflows, credentials and n8n account all survive this upgrade."
else
    N8N_ENCRYPTION_KEY="$(load_or_create_secret N8N_ENCRYPTION_KEY "openssl rand -hex 24")"
    print_ok "$([ -n "$N8N_VOLUME" ] && echo "Re-using the stored n8n encryption key" || echo "New n8n instance - generated a fresh encryption key")"
fi

# Image tags: override before running, e.g. AGENTIC_N8N_TAG=1.130.0 bash vps_setup.sh
N8N_TAG="${AGENTIC_N8N_TAG:-latest}"
OPENCLAW_TAG="${AGENTIC_OPENCLAW_TAG:-latest}"

# --- stack.env : read literally by Docker Compose, so no escaping traps ------
print_step "Writing ${DEPLOY_DIR}/stack.env ..."
cat >"${DEPLOY_DIR}/stack.env" <<EOF
# Secrets for the Agentic AI stack. Keep this file private (chmod 600).
# Values are read literally - do not add quotes.
OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN}
${API_KEY_ENV}=${AI_API_KEY}
EOF
# Omitted entirely when n8n already owns a key we could not read - an empty or
# wrong N8N_ENCRYPTION_KEY stops n8n from starting.
if [ -n "$N8N_ENCRYPTION_KEY" ]; then
    echo "N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}" >>"${DEPLOY_DIR}/stack.env"
fi
chmod 600 "${DEPLOY_DIR}/stack.env"
print_ok "Secrets written (file is readable by root only)"

# --- openclaw.json ----------------------------------------------------------
print_step "Writing OpenClaw gateway configuration ..."
OC_CONFIG="${DEPLOY_DIR}/openclaw/openclaw.json"
if [ -f "$OC_CONFIG" ]; then
    cp "$OC_CONFIG" "${OC_CONFIG}.bak.$(date +%s)"
    print_info "Existing openclaw.json backed up"
fi
cat >"$OC_CONFIG" <<EOF
{
  "gateway": {
    "mode": "local",
    "port": ${OPENCLAW_PORT},
    "bind": "lan",
    "auth": {
      "mode": "token"
    },
    "trustedProxies": ["${DOCKER_GW}", "127.0.0.1"],
    "controlUi": {
      "enabled": true,
      "allowedOrigins": ["https://${CLAW_HOSTNAME}"]
    }
  }
}
EOF
chown 1000:1000 "$OC_CONFIG"
chmod 600 "$OC_CONFIG"
print_ok "OpenClaw bound to LAN inside the container, token auth on, origin locked to https://${CLAW_HOSTNAME}"

# --- docker-compose.yml -----------------------------------------------------
print_step "Writing ${DEPLOY_DIR}/docker-compose.yml ..."

# Give each service a heap ceiling so one runaway process cannot freeze the VPS.
if   [ "$TOTAL_RAM_MB" -ge 7500 ]; then N8N_MEM=2048; OC_MEM=3072
elif [ "$TOTAL_RAM_MB" -ge 3500 ]; then N8N_MEM=1024; OC_MEM=1536
else                                    N8N_MEM=768;  OC_MEM=1024
fi

cat >"${DEPLOY_DIR}/docker-compose.yml" <<EOF
# Generated by vps_setup.sh v${SCRIPT_VERSION} - safe to regenerate.
# Both services listen on 127.0.0.1 only. Nginx is the only public entrance.

services:

  n8n:
    image: docker.n8n.io/n8nio/n8n:${N8N_TAG}
    container_name: n8n
    restart: unless-stopped
    ports:
      - "127.0.0.1:${N8N_PORT}:5678"
    env_file:
      - stack.env
    environment:
      N8N_HOST: ${N8N_HOSTNAME}
      N8N_PORT: "5678"
      N8N_PROTOCOL: https
      N8N_EDITOR_BASE_URL: https://${N8N_HOSTNAME}
      WEBHOOK_URL: https://${N8N_HOSTNAME}/
      N8N_PROXY_HOPS: "1"
      N8N_SECURE_COOKIE: "true"
      N8N_RUNNERS_ENABLED: "true"
      N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS: "true"
      N8N_DIAGNOSTICS_ENABLED: "false"
      N8N_HIRING_BANNER_ENABLED: "false"
      EXECUTIONS_DATA_PRUNE: "true"
      EXECUTIONS_DATA_MAX_AGE: "336"
      DB_SQLITE_POOL_SIZE: "5"
      GENERIC_TIMEZONE: ${TIMEZONE}
      TZ: ${TIMEZONE}
      NODE_OPTIONS: --max-old-space-size=${N8N_MEM}
    volumes:
      - n8n_data:/home/node/.n8n
    networks:
      - agentic_net
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:5678/healthz >/dev/null 2>&1 || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s

  openclaw-gateway:
    image: ghcr.io/openclaw/openclaw:${OPENCLAW_TAG}
    container_name: openclaw-gateway
    restart: unless-stopped
    init: true
    ports:
      - "127.0.0.1:${OPENCLAW_PORT}:${OPENCLAW_PORT}"
    env_file:
      - stack.env
    environment:
      HOME: /home/node
      OPENCLAW_HOME: /home/node
      OPENCLAW_STATE_DIR: /home/node/.openclaw
      OPENCLAW_CONFIG_DIR: /home/node/.openclaw
      OPENCLAW_CONFIG_PATH: /home/node/.openclaw/openclaw.json
      OPENCLAW_WORKSPACE_DIR: /home/node/.openclaw/workspace
      OPENCLAW_GATEWAY_BIND: lan
      OPENCLAW_GATEWAY_PORT: "${OPENCLAW_PORT}"
      OPENCLAW_GATEWAY_AUTH_MODE: token
      OPENCLAW_GATEWAY_CONTROLUI_ALLOWEDORIGINS: https://${CLAW_HOSTNAME}
      NODE_OPTIONS: --max-old-space-size=${OC_MEM}
      TERM: xterm-256color
      TZ: ${TIMEZONE}
    volumes:
      - ./openclaw:/home/node/.openclaw
      - ./openclaw-workspace:/home/node/.openclaw/workspace
      - ./openclaw-secrets:/home/node/.config/openclaw
    cap_drop:
      - NET_RAW
      - NET_ADMIN
    security_opt:
      - no-new-privileges:true
    extra_hosts:
      - "host.docker.internal:host-gateway"
    networks:
      - agentic_net
    command: ["node", "dist/index.js", "gateway", "--bind", "lan", "--port", "${OPENCLAW_PORT}"]

  # Used only for one-off commands: docker compose run --rm openclaw-cli <args>
  openclaw-cli:
    image: ghcr.io/openclaw/openclaw:${OPENCLAW_TAG}
    network_mode: "service:openclaw-gateway"
    profiles: ["cli"]
    init: true
    stdin_open: true
    tty: true
    env_file:
      - stack.env
    environment:
      HOME: /home/node
      OPENCLAW_HOME: /home/node
      OPENCLAW_STATE_DIR: /home/node/.openclaw
      OPENCLAW_CONFIG_DIR: /home/node/.openclaw
      OPENCLAW_CONFIG_PATH: /home/node/.openclaw/openclaw.json
      OPENCLAW_WORKSPACE_DIR: /home/node/.openclaw/workspace
      BROWSER: echo
      TERM: xterm-256color
      TZ: ${TIMEZONE}
    volumes:
      - ./openclaw:/home/node/.openclaw
      - ./openclaw-workspace:/home/node/.openclaw/workspace
      - ./openclaw-secrets:/home/node/.config/openclaw
    cap_drop:
      - NET_RAW
      - NET_ADMIN
    security_opt:
      - no-new-privileges:true
    entrypoint: ["node", "dist/index.js"]
    depends_on:
      - openclaw-gateway

volumes:
  n8n_data:

networks:
  agentic_net:
    driver: bridge
    ipam:
      config:
        - subnet: ${DOCKER_SUBNET}
          gateway: ${DOCKER_GW}
EOF
chmod 600 "${DEPLOY_DIR}/docker-compose.yml"
print_ok "Compose file written"

# =============================================================================
#   PHASE 6 - Nginx (HTTP first, so Certbot can validate)
# =============================================================================
print_phase "PHASE 6 / 9  --  Nginx reverse proxy"

run_step "Installing Nginx" apt-get install "${APT_OPTS[@]}" nginx

# The ACME challenge directory must be traversable by the Nginx worker.
mkdir -p "$WEBROOT/.well-known/acme-challenge"
chmod -R 755 "$WEBROOT"
chown -R www-data:www-data "$WEBROOT"

# --- Portability: the "http2 on;" directive only exists from Nginx 1.25.1.
# Ubuntu 22.04 ships 1.18 and 24.04 ships 1.24, so pick the right syntax.
NGINX_VER="$(nginx -v 2>&1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' || echo 0.0.0)"
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }
if ver_ge "$NGINX_VER" "1.25.1"; then
    SSL_LISTEN_4="listen 443 ssl;"
    SSL_LISTEN_6="listen [::]:443 ssl;"
    HTTP2_LINE="    http2 on;"
else
    SSL_LISTEN_4="listen 443 ssl http2;"
    SSL_LISTEN_6="listen [::]:443 ssl http2;"
    HTTP2_LINE=""
fi
print_info "Nginx ${NGINX_VER} detected"

# --- Portability: "listen [::]" fails outright when IPv6 is off in the kernel.
if [ "$HOST_HAS_IPV6" = true ] || [ -f /proc/net/if_inet6 ]; then
    L6_80="    listen [::]:80;"
    L6_80_DEF="    listen [::]:80 default_server;"
    L6_443="    ${SSL_LISTEN_6}"
else
    L6_80=""; L6_80_DEF=""; L6_443=""
    print_info "IPv6 is disabled on this server - Nginx will listen on IPv4 only"
fi

# WebSocket upgrade map (http context, needed by both sites).
cat >/etc/nginx/conf.d/agentic-upgrade.conf <<'EOF'
# Only send "Connection: upgrade" for real WebSocket requests.
map $http_upgrade $agentic_connection_upgrade {
    default upgrade;
    ''      close;
}
EOF

# Catch-all: anything hitting the bare IP or an unknown hostname is dropped.
# Without this, the n8n login page is served on http://<VPS_IP> to every
# internet scanner, which is both a leak and a reputation problem.
#
# But Nginx allows exactly ONE default_server per address:port. On a VPS that
# already hosts a website, that slot is taken, and adding a second one is a
# fatal config error that takes the whole web server down. So: only claim it
# if nobody else has. If another site owns it, unknown hostnames already land
# there rather than on n8n, which is the outcome we wanted anyway.
rm -f /etc/nginx/sites-enabled/000-agentic-default

EXISTING_DEFAULT=""
for _f in /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf; do
    [ -e "$_f" ] || continue
    if grep -qE '^[[:space:]]*listen[^;#]*[[:space:]]default_server' "$_f" 2>/dev/null; then
        EXISTING_DEFAULT="$_f"
        break
    fi
done

if [ -n "$EXISTING_DEFAULT" ]; then
    OWN_DEFAULT_SERVER=false
    rm -f /etc/nginx/sites-available/000-agentic-default
    print_info "Another site already handles unknown hostnames: $(basename "$EXISTING_DEFAULT")"
    print_info "Leaving it alone - this server hosts more than just the bootcamp stack."
else
    OWN_DEFAULT_SERVER=true
    cat >/etc/nginx/sites-available/000-agentic-default <<EOF
server {
    listen 80 default_server;
${L6_80_DEF}
    server_name _;
    location /.well-known/acme-challenge/ { root ${WEBROOT}; }
    location / { return 444; }
}
EOF
fi

write_site_http() {
    local name="$1" host="$2"
    cat >"/etc/nginx/sites-available/${name}" <<EOF
server {
    listen 80;
${L6_80}
    server_name ${host};

    location /.well-known/acme-challenge/ { root ${WEBROOT}; }
    location / { return 200 'Setup in progress. SSL certificate pending.\n'; add_header Content-Type text/plain; }
}
EOF
}

write_site_https() {
    local name="$1" host="$2" port="$3" body_limit="$4"
    local ssl_extra=""
    [ -f /etc/letsencrypt/options-ssl-nginx.conf ] && ssl_extra="    include /etc/letsencrypt/options-ssl-nginx.conf;"
    [ -f /etc/letsencrypt/ssl-dhparams.pem ] && ssl_extra="${ssl_extra}
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;"

    cat >"/etc/nginx/sites-available/${name}" <<EOF
server {
    listen 80;
${L6_80}
    server_name ${host};

    location /.well-known/acme-challenge/ { root ${WEBROOT}; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    ${SSL_LISTEN_4}
${L6_443}
${HTTP2_LINE}
    server_name ${host};

    ssl_certificate     /etc/letsencrypt/live/${N8N_HOSTNAME}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${N8N_HOSTNAME}/privkey.pem;
${ssl_extra}

    # Keep this instance out of search engines and crawler databases.
    add_header X-Robots-Tag "noindex, nofollow, noarchive" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    client_max_body_size ${body_limit};

    location = /robots.txt {
        add_header Content-Type text/plain;
        return 200 "User-agent: *\nDisallow: /\n";
    }

    location / {
        proxy_pass http://127.0.0.1:${port};
        proxy_http_version 1.1;

        proxy_set_header Upgrade           \$http_upgrade;
        proxy_set_header Connection        \$agentic_connection_upgrade;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host  \$host;
        proxy_set_header Origin            \$http_origin;

        proxy_buffering off;
        proxy_cache off;
        proxy_request_buffering off;
        chunked_transfer_encoding off;

        # Long-running workflows, streaming responses and websockets.
        proxy_connect_timeout 60s;
        proxy_send_timeout    3600s;
        proxy_read_timeout    3600s;
    }
}
EOF
}

print_step "Writing Nginx sites ..."
write_site_http n8n  "$N8N_HOSTNAME"
write_site_http claw "$CLAW_HOSTNAME"

# Only remove the stock Debian site if we are taking over the default slot.
# On a server hosting other websites it may be load-bearing.
if [ "$OWN_DEFAULT_SERVER" = true ]; then
    rm -f /etc/nginx/sites-enabled/default
    ln -sf /etc/nginx/sites-available/000-agentic-default /etc/nginx/sites-enabled/000-agentic-default
fi
ln -sf /etc/nginx/sites-available/n8n  /etc/nginx/sites-enabled/n8n
ln -sf /etc/nginx/sites-available/claw /etc/nginx/sites-enabled/claw

# Never leave Nginx unable to start. If our sites break the config, unlink them
# and confirm the server is healthy again before reporting the failure.
nginx_validate_or_rollback() {
    local stage="$1"
    if nginx -t >/tmp/agentic_last.log 2>&1; then
        print_ok "Nginx configuration is valid (${stage})"
        return 0
    fi
    print_error "Nginx rejected the configuration (${stage})"
    echo ""
    tail -n 15 /tmp/agentic_last.log
    echo ""
    print_step "Undoing our changes so your web server keeps working ..."
    rm -f /etc/nginx/sites-enabled/n8n \
          /etc/nginx/sites-enabled/claw \
          /etc/nginx/sites-enabled/000-agentic-default
    if nginx -t >/dev/null 2>&1; then
        print_ok "Rolled back - Nginx is valid again and your other sites are safe"
    else
        print_warn "Nginx is still invalid after rollback - the problem predates this script."
        print_info "Inspect it with:  nginx -t"
    fi
    die "Nginx configuration failed (${stage}). Nothing was left broken."
}

nginx_validate_or_rollback "HTTP"
run_step "Starting Nginx"        systemctl restart nginx
run_step "Enabling Nginx at boot" systemctl enable nginx
print_ok "Nginx is serving HTTP for both hostnames"

# =============================================================================
#   PHASE 7 - SSL certificate (webroot mode: never rewrites our config)
# =============================================================================
print_phase "PHASE 7 / 9  --  Free SSL certificate"

run_step "Installing Certbot" apt-get install "${APT_OPTS[@]}" certbot python3-certbot-nginx

SSL_OK=false
issue_certificate() {
    print_step "Requesting a certificate for ${N8N_HOSTNAME} and ${CLAW_HOSTNAME} ..."
    if certbot certonly --webroot -w "$WEBROOT" \
            --non-interactive --agree-tos --no-eff-email \
            --email "$CERTBOT_EMAIL" \
            --cert-name "$N8N_HOSTNAME" \
            --keep-until-expiring --expand \
            -d "$N8N_HOSTNAME" -d "$CLAW_HOSTNAME" \
            >/tmp/agentic_certbot.log 2>&1; then
        return 0
    fi
    return 1
}

if issue_certificate; then
    SSL_OK=true
    print_ok "Certificate issued for both hostnames"
else
    print_warn "Could not get a certificate covering both hostnames."
    print_info "Trying ${N8N_HOSTNAME} on its own ..."
    if certbot certonly --webroot -w "$WEBROOT" \
            --non-interactive --agree-tos --no-eff-email \
            --email "$CERTBOT_EMAIL" --cert-name "$N8N_HOSTNAME" \
            --keep-until-expiring -d "$N8N_HOSTNAME" \
            >>/tmp/agentic_certbot.log 2>&1; then
        SSL_OK=partial
        print_ok "Certificate issued for ${N8N_HOSTNAME} only"
        print_warn "${CLAW_HOSTNAME} has no certificate yet - check its DNS record, then run: agentic ssl"
    else
        print_error "Certbot could not issue any certificate."
        echo ""
        tail -n 25 /tmp/agentic_certbot.log
        echo ""
        print_info "Most common causes:"
        print_info "  1. The A record does not point to ${VPS_IP} yet."
        print_info "  2. An AAAA (IPv6) record exists but this server has no IPv6."
        print_info "  3. Port 80 is blocked by the provider firewall (check the Hostinger panel)."
        print_info "After fixing, run:  agentic ssl"
    fi
fi

if [ "$SSL_OK" != "false" ]; then
    print_step "Switching Nginx to HTTPS ..."
    write_site_https n8n "$N8N_HOSTNAME" "$N8N_PORT" "100m"
    if [ "$SSL_OK" = true ]; then
        write_site_https claw "$CLAW_HOSTNAME" "$OPENCLAW_PORT" "50m"
    fi
    nginx_validate_or_rollback "HTTPS"
    run_step "Reloading Nginx" systemctl reload nginx
    print_ok "HTTPS is live, HTTP redirects automatically"
fi

# Renewal: reload nginx after each successful renewal.
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat >/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/bin/sh
systemctl reload nginx
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

if systemctl list-timers 2>/dev/null | grep -q certbot; then
    print_ok "Automatic renewal is handled by the certbot systemd timer"
else
    (crontab -l 2>/dev/null | grep -v 'certbot renew' || true; \
     echo "17 3 * * * certbot renew --quiet") | crontab -
    print_ok "Automatic renewal cron job installed (daily 03:17)"
fi

# =============================================================================
#   PHASE 8 - Start the stack
# =============================================================================
print_phase "PHASE 8 / 9  --  Starting n8n and OpenClaw"

cd "$DEPLOY_DIR"

print_step "Downloading container images (this is the slowest step, 2-5 minutes) ..."
if ! docker compose pull n8n openclaw-gateway >/tmp/agentic_last.log 2>&1; then
    print_warn "ghcr.io pull failed. Falling back to the Docker Hub mirror for OpenClaw."
    sed -i "s|ghcr.io/openclaw/openclaw:|openclaw/openclaw:|g" docker-compose.yml
    run_step "Downloading images (mirror)" docker compose pull n8n openclaw-gateway
else
    print_ok "Images downloaded"
fi

run_step "Starting containers" docker compose up -d n8n openclaw-gateway

# --- Wait for n8n ---
print_step "Waiting for n8n to become ready ..."
n8n_up=false
for _ in $(seq 1 60); do
    if curl -fsS --max-time 3 "http://127.0.0.1:${N8N_PORT}/healthz" >/dev/null 2>&1; then
        n8n_up=true; break
    fi
    sleep 3
done
if [ "$n8n_up" = true ]; then
    print_ok "n8n is responding on port ${N8N_PORT}"
else
    print_warn "n8n did not answer within 3 minutes. Check:  agentic logs n8n"
fi

# --- Wait for OpenClaw ---
print_step "Waiting for the OpenClaw gateway to become ready ..."
oc_up=false
for _ in $(seq 1 60); do
    if curl -fsS --max-time 3 "http://127.0.0.1:${OPENCLAW_PORT}/healthz" >/dev/null 2>&1; then
        oc_up=true; break
    fi
    sleep 3
done
if [ "$oc_up" = true ]; then
    print_ok "OpenClaw gateway is responding on port ${OPENCLAW_PORT}"
else
    print_warn "OpenClaw did not answer within 3 minutes. Check:  agentic logs claw"
fi

# =============================================================================
#   PHASE 9 - OpenClaw bootstrap + helper command
# =============================================================================
print_phase "PHASE 9 / 9  --  OpenClaw setup and the 'agentic' helper"

oc_cli() { docker compose -f "${DEPLOY_DIR}/docker-compose.yml" run --rm -T openclaw-cli "$@"; }

# --- Pick a model from the list OpenClaw actually reports --------------------
AI_MODEL=""
if [ "$oc_up" = true ]; then
    print_step "Asking OpenClaw which ${AI_LABEL} models your key can use ..."
    MODEL_RAW="$(oc_cli models list --provider "$AI_PROVIDER" 2>/dev/null || true)"
    MODEL_LIST=()
    mapfile -t MODEL_LIST < <(printf '%s\n' "$MODEL_RAW" \
        | grep -Eo "${AI_PROVIDER}/[A-Za-z0-9._-]+" | sort -u | head -n 12 || true)

    if [ "${#MODEL_LIST[@]}" -gt 0 ]; then
        echo ""
        echo "  ${BOLD}Models available to your account:${RESET}"
        choose MODEL_CHOICE "Choose the model OpenClaw should use" "${MODEL_LIST[@]}"
        AI_MODEL="${MODEL_LIST[$((MODEL_CHOICE - 1))]}"
    else
        AI_MODEL="$AI_MODEL_DEFAULT"
        [ -n "$AI_MODEL" ] && print_info "Could not list models; using the default ${AI_MODEL}"
    fi

    if [ -n "$AI_MODEL" ]; then
        run_soft "Setting default model to ${AI_MODEL}" \
            oc_cli config set agents.defaults.model.primary "$AI_MODEL" || true
    else
        print_info "No model was set. Pick one later with:  agentic model"
    fi

    # --- Channel plugins (WhatsApp is external, Telegram ships built in) -----
    run_soft "Installing the WhatsApp channel plugin" \
        oc_cli plugins install clawhub:@openclaw/whatsapp || \
        print_info "WhatsApp plugin can be installed later with:  agentic whatsapp"

    run_soft "Running OpenClaw self-check" oc_cli doctor --fix || true

    run_step "Restarting OpenClaw so plugins and settings load" \
        docker compose -f "${DEPLOY_DIR}/docker-compose.yml" restart openclaw-gateway

    for _ in $(seq 1 40); do
        curl -fsS --max-time 3 "http://127.0.0.1:${OPENCLAW_PORT}/healthz" >/dev/null 2>&1 && break
        sleep 3
    done
    print_ok "OpenClaw restarted"
else
    print_warn "Skipping OpenClaw configuration because the gateway is not responding yet."
    print_info "Once it is up, run:  agentic doctor"
fi

# --- Install the 'agentic' helper command -----------------------------------
print_step "Installing the 'agentic' helper command ..."
cat >/usr/local/bin/agentic <<'AGENTIC_EOF'
#!/usr/bin/env bash
# Agentic AI Bootcamp - one command for everything.
set -uo pipefail

DEPLOY_DIR="/opt/agentic-stack"
CONF_FILE="/etc/agentic-stack.conf"
CREDS_FILE="/root/AGENTIC-CREDENTIALS.txt"
WEBROOT="/var/www/acme"
OPENCLAW_PORT=18789
N8N_PORT=5678

[ -f "$CONF_FILE" ] && . "$CONF_FILE"

C=$'\033[0;36m'; G=$'\033[0;32m'; Y=$'\033[1;33m'; R=$'\033[0;31m'; B=$'\033[1m'; D=$'\033[2m'; N=$'\033[0m'
ok()   { echo "  ${G}[ OK ]${N} $1"; }
warn() { echo "  ${Y}[WARN]${N} $1"; }
bad()  { echo "  ${R}[FAIL]${N} $1"; }
info() { echo "  ${D}$1${N}"; }
head_() { echo ""; echo "${B}== $1 ==${N}"; echo ""; }

if [ "${EUID:-$(id -u)}" -ne 0 ]; then echo "Run with sudo:  sudo agentic $*"; exit 1; fi

dc()     { docker compose -f "${DEPLOY_DIR}/docker-compose.yml" "$@"; }
oc()     { dc run --rm openclaw-cli "$@"; }
oc_q()   { dc run --rm -T openclaw-cli "$@"; }
token()  { grep -m1 '^OPENCLAW_GATEWAY_TOKEN=' "${DEPLOY_DIR}/stack.env" 2>/dev/null | cut -d= -f2-; }

usage() {
cat <<EOF

  ${B}agentic${N} - manage your Agentic AI stack

  ${B}Everyday${N}
    agentic status            Show what is running and whether it is healthy
    agentic urls              Print your n8n and OpenClaw links
    agentic open              Print the one-click OpenClaw dashboard login link
    agentic token             Show your OpenClaw dashboard password
    agentic logs [n8n|claw]   Follow live logs (Ctrl+C to stop)
    agentic restart [n8n|claw]
    agentic safebrowsing      Fix Chrome's red "Deceptive site ahead" page

  ${B}OpenClaw${N}
    agentic whatsapp          Pair WhatsApp (shows the QR code)
    agentic approve           Approve a device waiting to log in
    agentic model [ref]       List or change the AI model
    agentic doctor            Run OpenClaw self-repair
    agentic claw <args...>    Run any raw OpenClaw CLI command

  ${B}Maintenance${N}
    agentic ssl               Issue or renew the SSL certificate
    agentic dns               Check that DNS points here
    agentic update            Pull the newest images and restart
    agentic backup            Save n8n data + OpenClaw config to /root/backups
    agentic creds             Show the saved credentials file

EOF
}

cmd_urls() {
    head_ "Your links"
    echo "  n8n              ${C}https://${N8N_HOSTNAME:-n8n.example.com}${N}"
    echo "  OpenClaw         ${C}https://${CLAW_HOSTNAME:-claw.example.com}${N}"
    echo ""
}

cmd_token() {
    local t; t="$(token)"
    head_ "Your OpenClaw dashboard password"
    if [ -z "$t" ]; then bad "No password found in ${DEPLOY_DIR}/stack.env"; return 1; fi
    echo "  ${B}${t}${N}"
    echo ""
    info "This is the password you chose during setup."
    info "OpenClaw's dashboard calls it the 'gateway token'."
    info "Dashboard: https://${CLAW_HOSTNAME:-claw.example.com}"
    echo ""
}

cmd_safebrowsing() {
    head_ "Red \"Deceptive site ahead\" page in Chrome"
    echo "  This is ${B}not${N} an SSL problem - your certificate is valid."
    echo "  Google Safe Browsing sometimes false-flags self-hosted n8n."
    echo ""
    echo "  ${B}To keep working right now${N}"
    echo "    Click ${B}Details${N} on the red page, then ${B}visit this unsafe site${N}."
    echo ""
    echo "  ${B}To clear it permanently${N}"
    echo "    1. Open ${C}https://search.google.com/search-console${N}"
    echo "    2. Add a ${B}Domain${N} property for ${B}${DOMAIN:-your-domain.com}${N}"
    echo "       Verify with the TXT record it gives you."
    echo "       A Domain property covers ${N8N_HOSTNAME:-n8n.*} and ${CLAW_HOSTNAME:-claw.*} at once."
    echo "    3. Go to ${B}Security & Manual Actions${N} -> ${B}Security Issues${N}"
    echo "    4. Click ${B}Request Review${N}. Describe it as a private automation"
    echo "       tool for your own use, not a public website."
    echo ""
    echo "  ${B}Check your current status${N}"
    echo "    ${C}https://transparencyreport.google.com/safe-browsing/search?url=${N8N_HOSTNAME:-}${N}"
    echo ""
    echo "  ${B}Already done by this server to reduce the risk${N}"
    for f in \
        "noindex/nofollow headers and a blocking robots.txt on both sites" \
        "requests to the bare IP address are refused, not served the login page" \
        "HTTPS enforced, HTTP redirects"; do
        ok "$f"
    done
    echo ""
    info "Reviews usually clear within 1-3 days."
    echo ""
}

cmd_open() {
    head_ "One-click dashboard login"
    local out url
    out="$(oc_q dashboard --no-open 2>&1 || true)"
    url="$(printf '%s' "$out" | grep -Eo 'https?://[^[:space:]]+' | head -n1)"
    if [ -n "$url" ] && [ -n "${CLAW_HOSTNAME:-}" ]; then
        url="$(printf '%s' "$url" | sed -E "s#https?://(127\.0\.0\.1|localhost|0\.0\.0\.0)(:[0-9]+)?#https://${CLAW_HOSTNAME}#")"
        echo "  Open this link in your browser (valid once, expires quickly):"
        echo ""
        echo "  ${C}${url}${N}"
        echo ""
    else
        warn "Could not generate a one-time link."
        info "Use the token instead:  sudo agentic token"
        [ -n "$out" ] && { echo ""; echo "$out"; }
    fi
}

cmd_status() {
    head_ "Containers"
    dc ps
    head_ "Services"
    systemctl is-active --quiet nginx && ok "Nginx running" || bad "Nginx not running"
    systemctl is-active --quiet docker && ok "Docker running" || bad "Docker not running"

    if curl -fsS --max-time 4 "http://127.0.0.1:${N8N_PORT}/healthz" >/dev/null 2>&1; then
        ok "n8n responding on ${N8N_PORT}"
    else bad "n8n not responding on ${N8N_PORT}"; fi

    if curl -fsS --max-time 4 "http://127.0.0.1:${OPENCLAW_PORT}/healthz" >/dev/null 2>&1; then
        ok "OpenClaw responding on ${OPENCLAW_PORT}"
    else bad "OpenClaw not responding on ${OPENCLAW_PORT}"; fi

    head_ "Public reachability"
    for h in "${N8N_HOSTNAME:-}" "${CLAW_HOSTNAME:-}"; do
        [ -z "$h" ] && continue
        code="$(curl -o /dev/null -sS -w '%{http_code}' --max-time 8 "https://${h}" 2>/dev/null || echo 000)"
        if [ "$code" = "000" ]; then bad "https://${h} unreachable"
        else ok "https://${h} -> HTTP ${code}"; fi
    done

    head_ "SSL certificate"
    if [ -n "${N8N_HOSTNAME:-}" ] && [ -f "/etc/letsencrypt/live/${N8N_HOSTNAME}/fullchain.pem" ]; then
        local exp names
        exp="$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/${N8N_HOSTNAME}/fullchain.pem" | cut -d= -f2)"
        names="$(openssl x509 -noout -text -in "/etc/letsencrypt/live/${N8N_HOSTNAME}/fullchain.pem" \
                 | grep -A1 'Subject Alternative Name' | tail -n1 | tr -d ' ' )"
        ok "Expires: ${exp}"
        info "Covers: ${names//DNS:/}"
        for h in "${N8N_HOSTNAME:-}" "${CLAW_HOSTNAME:-}"; do
            case "$names" in *"DNS:${h}"*) ok "${h} is covered" ;; *) warn "${h} is NOT covered - run: sudo agentic ssl" ;; esac
        done
    else
        bad "No certificate found. Run: sudo agentic ssl"
    fi

    head_ "Resources"
    free -h | head -n3
    echo ""
    df -h / | tail -n1
    echo ""
}

cmd_dns() {
    head_ "DNS check"
    local myip; myip="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || echo "${VPS_IP:-unknown}")"
    info "This server: ${myip}"
    echo ""
    for h in "${N8N_HOSTNAME:-}" "${CLAW_HOSTNAME:-}"; do
        [ -z "$h" ] && continue
        local a aaaa
        a="$(dig +short A "$h" @1.1.1.1 2>/dev/null | grep -Eo '^[0-9]+(\.[0-9]+){3}$' | tail -n1)"
        aaaa="$(dig +short AAAA "$h" @1.1.1.1 2>/dev/null | grep ':' | tail -n1)"
        if [ "$a" = "$myip" ]; then ok "${h} -> ${a}"
        else bad "${h} -> ${a:-nothing} (should be ${myip})"; fi
        [ -n "$aaaa" ] && warn "${h} has an IPv6 (AAAA) record: ${aaaa} - delete it if SSL fails"
    done
    echo ""
}

cmd_ssl() {
    head_ "Issuing / renewing SSL"
    [ -z "${N8N_HOSTNAME:-}" ] && { bad "No configuration found at ${CONF_FILE}"; return 1; }
    mkdir -p "$WEBROOT/.well-known/acme-challenge"
    certbot certonly --webroot -w "$WEBROOT" --non-interactive --agree-tos --no-eff-email \
        --email "${CERTBOT_EMAIL}" --cert-name "${N8N_HOSTNAME}" --keep-until-expiring --expand \
        -d "${N8N_HOSTNAME}" -d "${CLAW_HOSTNAME}"
    local rc=$?
    if [ $rc -eq 0 ]; then
        nginx -t && systemctl reload nginx && ok "Certificate in place, Nginx reloaded"
    else
        bad "Certbot failed. Run 'sudo agentic dns' first - DNS is the usual cause."
    fi
}

cmd_backup() {
    head_ "Backup"
    local dest="/root/backups"; mkdir -p "$dest"
    local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
    docker run --rm -v agentic-stack_n8n_data:/data -v "${dest}:/backup" alpine \
        tar czf "/backup/n8n-${stamp}.tar.gz" -C /data . 2>/dev/null \
        && ok "n8n data -> ${dest}/n8n-${stamp}.tar.gz" || warn "n8n volume backup failed"
    tar czf "${dest}/openclaw-${stamp}.tar.gz" -C "$DEPLOY_DIR" openclaw openclaw-secrets stack.env 2>/dev/null \
        && ok "OpenClaw config -> ${dest}/openclaw-${stamp}.tar.gz" || warn "OpenClaw backup failed"
    echo ""
}

cmd_model() {
    if [ -n "${1:-}" ]; then
        oc_q config set agents.defaults.model.primary "$1" && ok "Model set to $1"
        dc restart openclaw-gateway >/dev/null 2>&1 && ok "Gateway restarted"
    else
        head_ "Available models"
        oc models list
        echo ""
        info "Change it with:  sudo agentic model <provider/model>"
    fi
}

case "${1:-help}" in
    status)   cmd_status ;;
    urls)     cmd_urls ;;
    token|password) cmd_token ;;
    open|link|pair) cmd_open ;;
    safebrowsing|deceptive|redpage) cmd_safebrowsing ;;
    dns)      cmd_dns ;;
    ssl)      cmd_ssl ;;
    backup)   cmd_backup ;;
    creds)    [ -f "$CREDS_FILE" ] && cat "$CREDS_FILE" || bad "No credentials file at ${CREDS_FILE}" ;;
    model)    shift; cmd_model "${1:-}" ;;
    doctor)   head_ "OpenClaw self-repair"; oc doctor --fix; dc restart openclaw-gateway ;;
    whatsapp) head_ "WhatsApp pairing"
              info "A QR code will appear. Scan it with: WhatsApp > Settings > Linked devices > Link a device"
              echo ""
              oc channels login --channel whatsapp ;;
    approve)  head_ "Devices waiting for approval"
              oc devices list
              echo ""
              read -rp "  Request ID to approve (Enter to skip): " rid
              [ -n "${rid:-}" ] && oc devices approve "$rid" ;;
    claw)     shift; oc "$@" ;;
    logs)     case "${2:-all}" in
                  n8n)  dc logs -f --tail=100 n8n ;;
                  claw|openclaw) dc logs -f --tail=100 openclaw-gateway ;;
                  *)    dc logs -f --tail=50 ;;
              esac ;;
    restart)  case "${2:-all}" in
                  n8n)  dc restart n8n ;;
                  claw|openclaw) dc restart openclaw-gateway ;;
                  *)    dc restart; systemctl reload nginx ;;
              esac; ok "Restarted" ;;
    update)   head_ "Updating"
              dc pull n8n openclaw-gateway && dc up -d n8n openclaw-gateway && ok "Updated"
              docker image prune -f >/dev/null 2>&1 || true ;;
    stop)     dc down && ok "Stack stopped" ;;
    start)    dc up -d n8n openclaw-gateway && ok "Stack started" ;;
    help|-h|--help) usage ;;
    *)        bad "Unknown command: $1"; usage; exit 1 ;;
esac
AGENTIC_EOF
chmod 755 /usr/local/bin/agentic
print_ok "Type 'sudo agentic' any time to manage the stack"

# =============================================================================
#   Credentials file
# =============================================================================
umask 077
cat >"$CREDS_FILE" <<EOF
================================================================
  AGENTIC AI BOOTCAMP - YOUR SERVER DETAILS
  Generated: $(date)
  KEEP THIS FILE PRIVATE.
================================================================

n8n
  URL          https://${N8N_HOSTNAME}
  Account      You create it yourself on first visit (email + password).
               n8n manages its own accounts - there is no separate
               server password.

OpenClaw dashboard
  URL          https://${CLAW_HOSTNAME}
  Password     the one YOU chose during setup (OpenClaw calls it a
               "gateway token"). Forgotten it?  sudo agentic token
  Easiest login:  sudo agentic open      (one-click, no typing)

AI provider     ${AI_LABEL}
AI model        ${AI_MODEL:-not set yet - run: sudo agentic model}

Files
  Stack         ${DEPLOY_DIR}/docker-compose.yml
  Secrets       ${DEPLOY_DIR}/stack.env
  OpenClaw cfg  ${DEPLOY_DIR}/openclaw/openclaw.json
  Nginx         /etc/nginx/sites-available/n8n , /etc/nginx/sites-available/claw
  Setup log     ${LOG_FILE}

Helper command
  sudo agentic status        what is running
  sudo agentic open          one-click OpenClaw login
  sudo agentic token         show your dashboard password
  sudo agentic whatsapp      pair WhatsApp
  sudo agentic logs n8n      live n8n logs
  sudo agentic ssl           fix or renew SSL
  sudo agentic safebrowsing  fix Chrome's red "Deceptive site" page
  sudo agentic backup        back up your data
  sudo agentic help          full list
================================================================
EOF
chmod 600 "$CREDS_FILE"

# =============================================================================
#   Final report
# =============================================================================
print_phase "Setup finished"

FAILS=0
check() {
    if eval "$2" >/dev/null 2>&1; then print_ok "$1"; else print_error "$1"; FAILS=$((FAILS + 1)); fi
}
check "Docker running"                  "systemctl is-active --quiet docker"
check "Nginx running"                   "systemctl is-active --quiet nginx"
check "n8n container up"                "docker inspect -f '{{.State.Running}}' n8n | grep -q true"
check "OpenClaw container up"           "docker inspect -f '{{.State.Running}}' openclaw-gateway | grep -q true"
check "n8n answering locally"           "curl -fsS --max-time 5 http://127.0.0.1:${N8N_PORT}/healthz"
check "OpenClaw answering locally"      "curl -fsS --max-time 5 http://127.0.0.1:${OPENCLAW_PORT}/healthz"
check "SSL certificate present"         "test -f /etc/letsencrypt/live/${N8N_HOSTNAME}/fullchain.pem"
check "https://${N8N_HOSTNAME} reachable"  "curl -fsS --max-time 10 -o /dev/null https://${N8N_HOSTNAME}"
check "https://${CLAW_HOSTNAME} reachable" "curl -fsS --max-time 10 -o /dev/null https://${CLAW_HOSTNAME}"

echo ""
separator
echo ""

if [ "$FAILS" -eq 0 ]; then
    echo "${GREEN}${BOLD}  Everything is up and healthy.${RESET}"
else
    echo "${YELLOW}${BOLD}  Setup completed with ${FAILS} warning(s).${RESET}"
    print_info "Run  ${BOLD}sudo agentic status${RESET}  for details."
fi

echo ""
echo "  ${BOLD}Your links${RESET}"
echo "    n8n                ${CYAN}https://${N8N_HOSTNAME}${RESET}"
echo "    OpenClaw dashboard ${CYAN}https://${CLAW_HOSTNAME}${RESET}"
echo ""
echo "  ${BOLD}Step 1 - n8n  (do this now, not later)${RESET}"
echo "    Open the n8n link and create your owner account (email + password)."
echo "    ${YELLOW}Until you do, anyone who finds the address could claim it.${RESET}"
echo ""
echo "  ${BOLD}Step 2 - OpenClaw dashboard${RESET}"
echo "    Easiest:  run  ${BOLD}sudo agentic open${RESET}  and click the link it prints."
echo "    Manual:   open the OpenClaw link and enter the dashboard password"
echo "              you chose earlier in this setup."
echo ""
echo "    ${DIM}Forgot it?  sudo agentic token${RESET}"
echo "    ${DIM}Browser says 'pairing required'?  sudo agentic approve${RESET}"
echo ""
echo "  ${BOLD}Step 3 - WhatsApp (when your class reaches it)${RESET}"
echo "    ${BOLD}sudo agentic whatsapp${RESET}   then scan the QR code with your phone."
echo ""
separator
echo ""
echo "  ${BOLD}${YELLOW}If Chrome shows a red \"Deceptive site ahead\" page${RESET}"
echo ""
echo "    Your SSL certificate is fine - this is a Google Safe Browsing"
echo "    false positive that self-hosted n8n gets hit with sometimes."
echo "    ${BOLD}Click 'Details' then 'visit this unsafe site' to keep working${RESET},"
echo "    and clear it properly like this:"
echo ""
echo "      1. Go to ${CYAN}https://search.google.com/search-console${RESET}"
echo "      2. Add a ${BOLD}Domain${RESET} property for ${BOLD}${DOMAIN}${RESET}"
echo "         ${DIM}(verify with the TXT record it gives you - covers both subdomains)${RESET}"
echo "      3. Open ${BOLD}Security & Manual Actions -> Security Issues${RESET}"
echo "      4. Click ${BOLD}Request Review${RESET} and say it is a private n8n"
echo "         automation tool, not a public site"
echo ""
echo "    ${DIM}Reviews usually clear in 1-3 days. Run 'sudo agentic safebrowsing'${RESET}"
echo "    ${DIM}any time to see these steps again.${RESET}"
echo ""
separator
echo ""
echo "  Saved to ${BOLD}${CREDS_FILE}${RESET}  -  view it any time with  ${BOLD}sudo agentic creds${RESET}"
echo "  Manage everything with  ${BOLD}sudo agentic help${RESET}"
echo ""
echo "  ${GREEN}${BOLD}Happy building - CODED Agentic AI Bootcamp${RESET}"
echo ""
_log "=== Setup finished with ${FAILS} warnings ==="
