#!/usr/bin/env bash

# =============================================================================
#   ____ ___  ____  _____ ____       _                    _   _         _   ___
#  / ___/ _ \|  _ \| ____|  _ \     / \   __ _  ___ _ __ | |_(_) ___   / \ |_ _|
# | |  | | | | | | |  _| | | | |   / _ \ / _` |/ _ \ '_ \| __| |/ __| / _ \ | |
# | |__| |_| | |_| | |___| |_| |  / ___ \ (_| |  __/ | | | |_| | (__ / ___ \| |
#  \____\___/|____/|_____|____/  /_/   \_\__, |\___|_| |_|\__|_|\___/_/   \_\___|
#                                        |___/                                  
#   Agentic AI Bootcamp — Automated VPS Setup Script
#   Covers: Phase 1 to 6 from the VPS Setup Guide
#   Author: Eng. Abdullah Alenezi | Version: 2.0.0
# =============================================================================

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

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
print_banner() {
    clear
    echo -e "${CYAN}"
    echo "  +====================================================================+"
    echo "  |      >>> Agentic AI Bootcamp - VPS Setup Wizard <<<               |"
    echo "  |           Automated by CODED Bootcamp Instructor                  |"
    echo "  +====================================================================+"
    echo -e "${RESET}"
}

print_phase() {
    echo ""
    echo -e "${MAGENTA}${BOLD}==================================================================${RESET}"
    echo -e "${MAGENTA}${BOLD}  >> $1${RESET}"
    echo -e "${MAGENTA}${BOLD}==================================================================${RESET}"
    echo ""
}

print_step() { echo -e "  ${BLUE}>${RESET} $1"; }
print_ok()   { echo -e "  ${GREEN}[OK]${RESET}  $1"; }
print_warn() { echo -e "  ${YELLOW}[WARN]${RESET} ${YELLOW}$1${RESET}"; }
print_error(){ echo -e "  ${RED}[ERR]${RESET}  ${RED}$1${RESET}"; }
print_info() { echo -e "  ${DIM}[INFO] $1${RESET}"; }
separator()  { echo -e "${DIM}  ----------------------------------------------------------------${RESET}"; }

ask() {
    local var_name="$1"
    local prompt="$2"
    local default="${3:-}"
    local value=""
    if [ -n "$default" ]; then
        read -rp "  [?] $prompt [$default]: " value
        value="${value:-$default}"
    else
        while [ -z "$value" ]; do
            read -rp "  [?] $prompt: " value
            [ -z "$value" ] && print_warn "This field cannot be empty. Please try again."
        done
    fi
    printf -v "$var_name" '%s' "$value"
}

ask_secret() {
    local var_name="$1"
    local prompt="$2"
    local value=""
    while [ -z "$value" ]; do
        read -rsp "  [?] $prompt: " value
        echo ""
        [ -z "$value" ] && print_warn "This field cannot be empty. Please try again."
    done
    printf -v "$var_name" '%s' "$value"
}

confirm() {
    local prompt="$1"
    local answer=""
    read -rp "  [?] $prompt [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run as root (or with sudo)."
        print_info  "Re-run: sudo bash vps_setup.sh"
        exit 1
    fi
}

command_exists() { command -v "$1" &>/dev/null; }

# --- Spinner -----------------------------------------------------------------
spinner_pid=""
start_spinner() {
    local msg="$1"
    local chars='|/-\\'
    (
        i=0
        while true; do
            printf "\r  [%s]  %s  " "${chars:$((i % 4)):1}" "$msg"
            sleep 0.15
            ((i++)) || true
        done
    ) &
    spinner_pid=$!
    disown "$spinner_pid" 2>/dev/null || true
}

stop_spinner() {
    local msg="$1"
    if [ -n "$spinner_pid" ]; then
        kill "$spinner_pid" 2>/dev/null || true
        wait "$spinner_pid" 2>/dev/null || true
        spinner_pid=""
    fi
    printf "\r  [OK]  %-60s\n" "$msg"
}

run_quietly() {
    local msg="$1"
    shift
    start_spinner "$msg"
    if "$@" >/tmp/setup_last_output.log 2>&1; then
        stop_spinner "$msg -- Done"
    else
        stop_spinner "$msg -- FAILED"
        print_error "Command failed: $*"
        print_info  "Check /tmp/setup_last_output.log for details"
        cat /tmp/setup_last_output.log
        exit 1
    fi
}

# --- DNS Check ---------------------------------------------------------------
check_dns() {
    local subdomain="$1"
    local expected_ip="$2"
    local resolved_ip
    resolved_ip=$(dig +short "$subdomain" 2>/dev/null | tail -n1 || true)
    [ "$resolved_ip" = "$expected_ip" ]
}

# =============================================================================
#   PHASE 0: Root Guard & Banner
# =============================================================================
print_banner
check_root

# =============================================================================
#   PHASE 0: Welcome & Pre-flight Checklist
# =============================================================================
print_phase "PHASE 0 -- Welcome & Pre-flight Checklist"

echo -e "  Welcome, Trainee! This script will fully automate your VPS environment"
echo -e "  setup for the ${BOLD}Agentic AI Bootcamp${RESET}. Please read the following carefully:"
echo ""
echo -e "  ${BOLD}What this script will install and configure:${RESET}"
echo -e "  ${DIM}  [1] System update & UFW firewall hardening"
echo -e "      [2] Docker & Docker Compose (via official get.docker.com)"
echo -e "      [3] n8n workflow automation (via Docker)"
echo -e "      [4] OpenClaw AI integration (your chosen model + API key)"
echo -e "      [5] Nginx as a reverse proxy for n8n"
echo -e "      [6] Free SSL/TLS certificate via Let's Encrypt (Certbot)${RESET}"
echo ""

print_warn "BEFORE you continue, confirm ALL of the following are done:"
separator
echo ""
echo -e "  [ ] 1. VPS is freshly provisioned with Ubuntu 22.04 or 24.04"
echo -e "  [ ] 2. A domain name has been purchased"
echo -e "  [ ] 3. DNS A Record configured:"
echo -e "         Type: A  |  Name: n8n  |  Content: [Your VPS IP]"
echo -e "         (This creates n8n.yourdomain.com)"
echo -e "  [ ] 4. DNS propagation has been waited for (5-30 minutes)"
echo -e "  [ ] 5. API Key is ready for your chosen AI model (Gemini, OpenAI, or Claude)"
echo ""
separator
echo ""

if ! confirm "I have completed all the items above and I'm ready to proceed"; then
    echo ""
    print_info "Setup cancelled. Complete the pre-flight checklist and re-run the script."
    exit 0
fi

# =============================================================================
#   PHASE 1: Configuration Wizard — Gather All Inputs
# =============================================================================
print_phase "PHASE 1 -- Configuration Wizard"

echo -e "  ${BOLD}Let's collect your setup details before installing anything.${RESET}"
echo -e "  ${DIM}You can review everything before installation begins.${RESET}"
echo ""

# 1.1 VPS IP
ask VPS_IP "Enter your VPS Public IP Address (e.g., 1.2.3.4)"

# 1.2 Domain
ask DOMAIN "Enter your root domain name (e.g., my-agent-platform.com)"
N8N_SUBDOMAIN="n8n.${DOMAIN}"
echo ""
print_info "Your n8n instance will be at: https://${N8N_SUBDOMAIN}"

# 1.3 Email for Certbot
ask CERTBOT_EMAIL "Enter your email address (for Let's Encrypt SSL alerts)"

# 1.4 n8n Admin Credentials
echo ""
separator
echo ""
echo -e "  ${BOLD}n8n Admin Account${RESET}"
print_info "These credentials will be used to log into your n8n dashboard."
ask    N8N_USER "n8n admin username" "admin"
ask_secret N8N_PASS "n8n admin password (min 8 characters)"
while [ "${#N8N_PASS}" -lt 8 ]; do
    print_warn "Password must be at least 8 characters. Try again."
    ask_secret N8N_PASS "n8n admin password (min 8 characters)"
done

# 1.5 AI Model Selection
echo ""
separator
echo ""
echo -e "  ${BOLD}OpenClaw AI Model Selection${RESET}"
echo ""
echo "  Select the AI provider for OpenClaw:"
echo ""
echo "  [1] Google Gemini  (recommended - Free tier available)"
echo "  [2] OpenAI (GPT-4o, GPT-4.1, etc.)"
echo "  [3] Anthropic Claude (Claude Sonnet 4, Opus, etc.)"
echo ""

AI_CHOICE=""
while [[ ! "$AI_CHOICE" =~ ^[1-3]$ ]]; do
    read -rp "  [?] Enter your choice [1, 2, or 3]: " AI_CHOICE
    [[ ! "$AI_CHOICE" =~ ^[1-3]$ ]] && print_warn "Invalid choice. Please enter 1, 2, or 3."
done

if [ "$AI_CHOICE" = "1" ]; then
    AI_PROVIDER="gemini"
    AI_LABEL="Google Gemini"
    echo ""
    echo -e "  ${BOLD}Available Gemini Models:${RESET}"
    echo "  [1] gemini-2.0-flash           (fast, efficient - RECOMMENDED)"
    echo "  [2] gemini-2.0-flash-thinking  (reasoning tasks)"
    echo "  [3] gemini-1.5-pro             (1M token context window)"
    echo "  [4] gemini-1.5-flash           (fast and cost-effective)"
    echo ""
    MODEL_CHOICE=""
    while [[ ! "$MODEL_CHOICE" =~ ^[1-4]$ ]]; do
        read -rp "  [?] Select Gemini model [1-4]: " MODEL_CHOICE
        [[ ! "$MODEL_CHOICE" =~ ^[1-4]$ ]] && print_warn "Please enter 1, 2, 3, or 4."
    done
    case "$MODEL_CHOICE" in
        1) AI_MODEL="gemini-2.0-flash" ;;
        2) AI_MODEL="gemini-2.0-flash-thinking-exp" ;;
        3) AI_MODEL="gemini-1.5-pro" ;;
        4) AI_MODEL="gemini-1.5-flash" ;;
    esac
    API_KEY_LABEL="Gemini API Key (get it from: https://aistudio.google.com/app/apikey)"
    API_KEY_ENV="GEMINI_API_KEY"
elif [ "$AI_CHOICE" = "2" ]; then
    AI_PROVIDER="openai"
    AI_LABEL="OpenAI"
    echo ""
    echo -e "  ${BOLD}Available OpenAI Models:${RESET}"
    echo "  [1] gpt-4o-mini  (fast, affordable - RECOMMENDED for Bootcamp)"
    echo "  [2] gpt-4o       (most capable multimodal model)"
    echo "  [3] gpt-4.1      (long context, great for agents)"
    echo "  [4] gpt-4.1-mini (efficient, cost-optimized)"
    echo "  [5] o4-mini      (reasoning model, complex tasks)"
    echo ""
    MODEL_CHOICE=""
    while [[ ! "$MODEL_CHOICE" =~ ^[1-5]$ ]]; do
        read -rp "  [?] Select OpenAI model [1-5]: " MODEL_CHOICE
        [[ ! "$MODEL_CHOICE" =~ ^[1-5]$ ]] && print_warn "Please enter a number between 1 and 5."
    done
    case "$MODEL_CHOICE" in
        1) AI_MODEL="gpt-4o-mini" ;;
        2) AI_MODEL="gpt-4o" ;;
        3) AI_MODEL="gpt-4.1" ;;
        4) AI_MODEL="gpt-4.1-mini" ;;
        5) AI_MODEL="o4-mini" ;;
    esac
    API_KEY_LABEL="OpenAI API Key (get it from: https://platform.openai.com/api-keys)"
    API_KEY_ENV="OPENAI_API_KEY"
else
    AI_PROVIDER="anthropic"
    AI_LABEL="Anthropic Claude"
    echo ""
    echo -e "  ${BOLD}Available Claude Models:${RESET}"
    echo "  [1] claude-sonnet-4-20250514   (balanced power + speed - RECOMMENDED)"
    echo "  [2] claude-4-opus-20250514     (highest capability, complex tasks)"
    echo "  [3] claude-3.5-haiku           (fast, cost-effective)"
    echo "  [4] claude-3.5-sonnet          (strong all-rounder)"
    echo ""
    MODEL_CHOICE=""
    while [[ ! "$MODEL_CHOICE" =~ ^[1-4]$ ]]; do
        read -rp "  [?] Select Claude model [1-4]: " MODEL_CHOICE
        [[ ! "$MODEL_CHOICE" =~ ^[1-4]$ ]] && print_warn "Please enter 1, 2, 3, or 4."
    done
    case "$MODEL_CHOICE" in
        1) AI_MODEL="claude-sonnet-4-20250514" ;;
        2) AI_MODEL="claude-4-opus-20250514" ;;
        3) AI_MODEL="claude-3-5-haiku-20241022" ;;
        4) AI_MODEL="claude-3-5-sonnet-20241022" ;;
    esac
    API_KEY_LABEL="Anthropic API Key (get it from: https://console.anthropic.com/settings/keys)"
    API_KEY_ENV="ANTHROPIC_API_KEY"
fi

echo ""
ask_secret AI_API_KEY "$API_KEY_LABEL"

# 1.6 Confirm Summary
echo ""
print_phase "Configuration Summary -- Please Review Before Starting"

echo -e "  ${BOLD}VPS Public IP:   ${RESET} ${CYAN}${VPS_IP}${RESET}"
echo -e "  ${BOLD}Root Domain:     ${RESET} ${CYAN}${DOMAIN}${RESET}"
echo -e "  ${BOLD}n8n URL:         ${RESET} ${CYAN}https://${N8N_SUBDOMAIN}${RESET}"
echo -e "  ${BOLD}Certbot Email:   ${RESET} ${CYAN}${CERTBOT_EMAIL}${RESET}"
echo -e "  ${BOLD}n8n Username:    ${RESET} ${CYAN}${N8N_USER}${RESET}"
echo -e "  ${BOLD}n8n Password:    ${RESET} ${DIM}[hidden]${RESET}"
echo -e "  ${BOLD}AI Provider:     ${RESET} ${CYAN}${AI_LABEL}${RESET}"
echo -e "  ${BOLD}AI Model:        ${RESET} ${CYAN}${AI_MODEL}${RESET}"
echo -e "  ${BOLD}API Key:         ${RESET} ${DIM}[hidden -- ${#AI_API_KEY} characters]${RESET}"
echo ""

if ! confirm "Everything looks correct. Start the automated setup now?"; then
    print_info "Setup cancelled. Re-run the script to start over."
    exit 0
fi

# =============================================================================
#   DNS Propagation Check
# =============================================================================
print_phase "DNS Verification"

print_step "Checking if ${N8N_SUBDOMAIN} resolves to ${VPS_IP} ..."

if command_exists dig; then
    if check_dns "$N8N_SUBDOMAIN" "$VPS_IP"; then
        print_ok "DNS is correctly pointing ${N8N_SUBDOMAIN} -> ${VPS_IP}"
    else
        RESOLVED=$(dig +short "$N8N_SUBDOMAIN" 2>/dev/null | tail -n1 || echo "not resolved")
        print_warn "DNS resolved to: ${RESOLVED}"
        print_warn "Expected:        ${VPS_IP}"
        echo ""
        print_info "DNS propagation can take 5-30 minutes."
        print_info "SSL certificate issuance will FAIL if DNS is not propagated."
        echo ""
        if ! confirm "Continue anyway? (SSL cert may fail if DNS is not ready)"; then
            print_info "Good call. Wait for DNS propagation and re-run the script."
            exit 0
        fi
    fi
else
    print_warn "'dig' not installed. Skipping DNS check."
    print_warn "Make sure your A record is configured before running this script."
fi

# =============================================================================
#   PHASE 2: System Update & Firewall Hardening
# =============================================================================
print_phase "PHASE 2 -- System Update & Firewall Hardening"

run_quietly "Updating package lists" apt-get update
run_quietly "Upgrading installed packages" apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
run_quietly "Installing essential tools" apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" curl wget gnupg2 ca-certificates lsb-release ufw dnsutils

print_step "Configuring UFW firewall ..."
ufw --force reset        >/dev/null 2>&1
ufw default deny incoming  >/dev/null 2>&1
ufw default allow outgoing >/dev/null 2>&1
ufw allow OpenSSH          >/dev/null 2>&1
ufw allow 80/tcp           >/dev/null 2>&1
ufw allow 443/tcp          >/dev/null 2>&1
ufw --force enable         >/dev/null 2>&1
print_ok "Firewall configured: SSH and Nginx (80/443) are allowed"

# =============================================================================
#   PHASE 3: Docker & Docker Compose
# =============================================================================
print_phase "PHASE 3 -- Docker & Docker Compose Installation"

if command_exists docker; then
    DOCKER_VER=$(docker --version)
    print_ok "Docker already installed: ${DOCKER_VER}"
else
    run_quietly "Downloading official Docker install script" \
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    run_quietly "Installing Docker (this may take a minute)" \
        sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh
    print_ok "Docker installed successfully"
fi

run_quietly "Enabling Docker service on boot" systemctl enable --now docker
print_ok "Docker service is active"

DOCKER_COMPOSE_VER=$(docker compose version 2>/dev/null || echo "")
if [ -n "$DOCKER_COMPOSE_VER" ]; then
    print_ok "Docker Compose plugin: ${DOCKER_COMPOSE_VER}"
else
    run_quietly "Installing docker-compose-plugin" apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" docker-compose-plugin
    print_ok "Docker Compose plugin installed"
fi

# =============================================================================
#   PHASE 4: Deploy n8n & OpenClaw via Docker Compose
# =============================================================================
print_phase "PHASE 4 -- Deploying n8n & OpenClaw with Docker Compose"

DEPLOY_DIR="/opt/agentic-stack"
run_quietly "Creating deployment directory at ${DEPLOY_DIR}" mkdir -p "$DEPLOY_DIR"

print_step "Generating docker-compose.yml ..."

# Escape dollar signs for docker-compose (uses $$ for a literal $)
SAFE_N8N_PASS="${N8N_PASS//\$/\$\$}"
SAFE_AI_API_KEY="${AI_API_KEY//\$/\$\$}"

cat > "${DEPLOY_DIR}/docker-compose.yml" << ENDOFCOMPOSE

services:

  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    ports:
      - "127.0.0.1:5678:5678"
    environment:
      - N8N_HOST=${N8N_SUBDOMAIN}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - WEBHOOK_URL=https://${N8N_SUBDOMAIN}/
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=${N8N_USER}
      - N8N_BASIC_AUTH_PASSWORD=${SAFE_N8N_PASS}
      - N8N_EDITOR_BASE_URL=https://${N8N_SUBDOMAIN}/
      - GENERIC_TIMEZONE=UTC
      - N8N_METRICS=false
    volumes:
      - n8n_data:/home/node/.n8n
    networks:
      - agentic_net

  openclaw:
    image: openclaw/openclaw:latest
    container_name: openclaw
    restart: unless-stopped
    ports:
      - "127.0.0.1:8080:8080"
    environment:
      - AI_PROVIDER=${AI_PROVIDER}
      - AI_MODEL=${AI_MODEL}
      - ${API_KEY_ENV}=${SAFE_AI_API_KEY}
      - NODE_ENV=production
    volumes:
      - openclaw_data:/app/data
    networks:
      - agentic_net
    depends_on:
      - n8n

volumes:
  n8n_data:
  openclaw_data:

networks:
  agentic_net:
    driver: bridge
ENDOFCOMPOSE

print_ok "docker-compose.yml written to ${DEPLOY_DIR}/docker-compose.yml"

cd "$DEPLOY_DIR"

print_step "Pulling Docker images ..."
docker compose pull >/tmp/setup_last_output.log 2>&1 || print_warn "Some images may not have pulled cleanly. Continuing ..."

run_quietly "Starting all containers" docker compose up -d

sleep 4
print_ok "Containers started:"
docker compose ps

# =============================================================================
#   PHASE 4b: OpenClaw Post-Boot Stabilization
# =============================================================================
echo ""
separator
echo ""
echo -e "  ${BOLD}OpenClaw Gateway Stabilization${RESET}"
print_info "Waiting for OpenClaw gateway to fully initialize ..."

# Wait for the OpenClaw container to report healthy/running
OPENCLAW_READY=false
for i in $(seq 1 15); do
    if docker exec openclaw openclaw status --quiet >/dev/null 2>&1; then
        OPENCLAW_READY=true
        break
    fi
    sleep 2
done

if [ "$OPENCLAW_READY" = true ]; then
    print_ok "OpenClaw gateway is running"
else
    print_warn "OpenClaw may still be starting. Continuing with stabilization ..."
fi

# Step 4b.1: Run doctor to clear any restart-loop breaker state
print_step "Running 'openclaw doctor --fix' to clear restart-loop breaker ..."
if docker exec openclaw openclaw doctor --fix >/tmp/setup_last_output.log 2>&1; then
    print_ok "Doctor fix completed — gateway state is clean"
else
    print_warn "Doctor returned warnings (usually harmless). Continuing ..."
fi

# Step 4b.2: Pre-install WhatsApp and Telegram plugins
print_step "Pre-installing WhatsApp and Telegram channel plugins ..."
if docker exec openclaw openclaw plugins install clawhub:@openclaw/whatsapp clawhub:@openclaw/telegram >/tmp/setup_last_output.log 2>&1; then
    print_ok "WhatsApp and Telegram plugins installed"
else
    print_warn "Plugin install returned warnings. Plugins may already be installed."
fi

# Step 4b.3: Restart OpenClaw cleanly to load plugins
print_step "Restarting OpenClaw for a clean boot with plugins loaded ..."
docker compose restart openclaw >/tmp/setup_last_output.log 2>&1
sleep 8
print_ok "OpenClaw restarted with plugins active"

# Step 4b.4: Verify channel health
print_step "Verifying channel health ..."
if docker exec openclaw openclaw channels status --probe >/tmp/setup_last_output.log 2>&1; then
    print_ok "Channel providers are active and ready for pairing"
else
    print_warn "Channel probe returned warnings. WhatsApp/Telegram can still be paired later."
fi

# =============================================================================
#   PHASE 5: Nginx Reverse Proxy
# =============================================================================
print_phase "PHASE 5 -- Nginx Reverse Proxy Configuration"

run_quietly "Installing Nginx" apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" nginx

print_step "Writing Nginx config for ${N8N_SUBDOMAIN} ..."

cat > "/etc/nginx/sites-available/n8n" << ENDOFNGINX
# Agentic AI Bootcamp - n8n Reverse Proxy
# Domain: ${N8N_SUBDOMAIN}

server {
    listen 80;
    server_name ${N8N_SUBDOMAIN};

    # WhatsApp/Meta GET verification handshake bypass
    location ~ ^/webhook(-test)?/(personal-assistant|cashflow-agent|whatsapp) {
        if (\$request_method = GET) {
            add_header Content-Type text/plain;
            return 200 \$arg_hub_challenge;
        }
        proxy_pass http://127.0.0.1:5678;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        chunked_transfer_encoding off;
        proxy_buffering off;
        proxy_cache off;
    }

    # Main n8n web interface and WebSocket support
    location / {
        proxy_pass http://127.0.0.1:5678;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        chunked_transfer_encoding off;
        proxy_buffering off;
        proxy_cache off;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$host;
    }
}
ENDOFNGINX

print_ok "Nginx config written to /etc/nginx/sites-available/n8n"

# Enable site
rm -f "/etc/nginx/sites-enabled/n8n"
ln -s /etc/nginx/sites-available/n8n /etc/nginx/sites-enabled/n8n

# Disable default site to avoid conflicts
rm -f "/etc/nginx/sites-enabled/default"
print_info "Default Nginx site disabled (port conflict prevention)"

print_step "Testing Nginx configuration ..."
if nginx -t >/tmp/setup_last_output.log 2>&1; then
    print_ok "Nginx configuration is valid"
else
    print_error "Nginx config test failed!"
    cat /tmp/setup_last_output.log
    exit 1
fi

run_quietly "Restarting Nginx" systemctl restart nginx
run_quietly "Enabling Nginx on boot" systemctl enable nginx
print_ok "Nginx is running as reverse proxy for ${N8N_SUBDOMAIN}"

# =============================================================================
#   PHASE 6: SSL Certificate via Let's Encrypt
# =============================================================================
print_phase "PHASE 6 -- SSL/TLS Certificate (Let's Encrypt / Certbot)"

run_quietly "Installing Certbot and Nginx plugin" apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" certbot python3-certbot-nginx

print_step "Requesting SSL certificate for ${N8N_SUBDOMAIN} ..."
print_info "DNS must be fully propagated for this to succeed."
echo ""

if certbot --nginx \
           --non-interactive \
           --agree-tos \
           --email "$CERTBOT_EMAIL" \
           -d "$N8N_SUBDOMAIN" \
           --redirect \
           >/tmp/certbot_output.log 2>&1; then
    print_ok "SSL certificate issued and installed!"
    print_ok "HTTP is auto-redirected to HTTPS"
else
    echo ""
    print_error "Certbot failed to issue the certificate."
    print_warn "This usually means DNS has not fully propagated yet."
    echo ""
    print_info "Full Certbot log:"
    cat /tmp/certbot_output.log
    echo ""
    print_info "To retry SSL after DNS propagates, run:"
    echo "    certbot --nginx --email $CERTBOT_EMAIL -d $N8N_SUBDOMAIN"
    echo ""
    print_warn "Your n8n stack is still running over HTTP. SSL can be added later."
fi

# Certbot auto-renewal check
if systemctl is-active --quiet certbot.timer 2>/dev/null; then
    print_ok "Certbot auto-renewal timer is active"
elif ! crontab -l 2>/dev/null | grep -q certbot; then
    (crontab -l 2>/dev/null || true; echo "0 3 * * * certbot renew --quiet && systemctl reload nginx") | crontab -
    print_ok "Certbot renewal cron job added (runs daily at 3:00 AM)"
fi

# =============================================================================
#   Final Health Check
# =============================================================================
print_phase "Final Health Check"

print_step "Docker containers:"
cd "$DEPLOY_DIR"
docker compose ps
echo ""

if systemctl is-active --quiet nginx; then
    print_ok "Nginx: running"
else
    print_warn "Nginx may not be running. Check: systemctl status nginx"
fi

if ss -tlnp 2>/dev/null | grep -q ':5678'; then
    print_ok "n8n: listening on port 5678"
else
    print_warn "n8n may still be starting. Wait 30 seconds then run: docker compose ps"
fi

if ss -tlnp 2>/dev/null | grep -q ':8080'; then
    print_ok "OpenClaw: listening on port 8080"
else
    print_warn "OpenClaw may still be starting. Check: docker compose logs openclaw"
fi

# =============================================================================
#   Setup Complete!
# =============================================================================
print_phase "Setup Complete!"

echo -e "${GREEN}"
echo "  +====================================================================+"
echo "  |                    Setup Successful!                              |"
echo "  +====================================================================+"
echo -e "${RESET}"

echo -e "  ${BOLD}Your Agentic AI Stack is now live:${RESET}"
echo ""
echo -e "  n8n Dashboard:      ${CYAN}https://${N8N_SUBDOMAIN}${RESET}"
echo -e "  Username:           ${CYAN}${N8N_USER}${RESET}"
echo -e "  Password:           [the one you entered]"
echo -e "  AI Provider:        ${CYAN}${AI_LABEL} (${AI_MODEL})${RESET}"
echo -e "  OpenClaw Dashboard: ${CYAN}http://localhost:8080 (via SSH tunnel)${RESET}"
echo ""
separator
echo ""
echo -e "  ${BOLD}Useful Commands:${RESET}"
echo "  View containers:     docker compose -f ${DEPLOY_DIR}/docker-compose.yml ps"
echo "  View n8n logs:       docker compose -f ${DEPLOY_DIR}/docker-compose.yml logs -f n8n"
echo "  View OpenClaw logs:  docker compose -f ${DEPLOY_DIR}/docker-compose.yml logs -f openclaw"
echo "  Restart services:    docker compose -f ${DEPLOY_DIR}/docker-compose.yml restart"
echo "  Stop services:       docker compose -f ${DEPLOY_DIR}/docker-compose.yml down"
echo "  Retry SSL:           certbot --nginx --email $CERTBOT_EMAIL -d $N8N_SUBDOMAIN"
echo "  Nginx error log:     tail -f /var/log/nginx/error.log"
echo ""
separator
echo ""
echo -e "  ${BOLD}Channel Pairing (Day 3):${RESET}"
echo -e "  SSH Tunnel:          ${CYAN}ssh -L 8080:127.0.0.1:8080 root@${VPS_IP}${RESET}"
echo -e "  Dashboard:           ${CYAN}http://localhost:8080${RESET}"
echo -e "  Pair WhatsApp:       ${CYAN}docker exec -it openclaw openclaw channels login --channel whatsapp${RESET}"
echo -e "  Channel Status:      ${CYAN}docker exec -it openclaw openclaw channels status --probe${RESET}"
echo ""
separator
echo ""
echo "  Config:  ${DEPLOY_DIR}/docker-compose.yml"
echo "  Nginx:   /etc/nginx/sites-available/n8n"
echo ""
echo -e "  ${GREEN}${BOLD}Happy building! -- CODED Agentic AI Bootcamp${RESET}"
echo ""
