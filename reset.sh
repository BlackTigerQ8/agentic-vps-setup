#!/usr/bin/env bash
# =============================================================================
#   CODED Agentic AI Bootcamp - Reset the stack
#
#   Removes everything vps_setup.sh created so you can run it again from
#   scratch (for a demo recording, or to start over after a bad run).
#
#   It is deliberately surgical. This server may host other websites, so it
#   NEVER touches:
#     - Nginx itself, or any site config it did not create
#     - Docker Engine, or any container/image/volume outside this stack
#     - UFW rules, the swap file, or anything else system-wide
#
#     curl -fsSL https://raw.githubusercontent.com/BlackTigerQ8/agentic-vps-setup/main/reset.sh -o reset.sh && sudo bash reset.sh
#
#   Version: 1.0.0
# =============================================================================

set -uo pipefail   # no -e: cleanup continues even when a step finds nothing

DEPLOY_DIR="/opt/agentic-stack"
CONF_FILE="/etc/agentic-stack.conf"
CREDS_FILE="/root/AGENTIC-CREDENTIALS.txt"
LOG_FILE="/var/log/agentic-setup.log"
WEBROOT="/var/www/acme"

REMOVE_CERTS=false
REMOVE_IMAGES=false
ASSUME_YES=false
DRY_RUN=false

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
skip() { echo "  ${DIM}[skip] $1${RESET}"; }
info() { echo "  ${DIM}$1${RESET}"; }
sect() { echo ""; echo "${MAGENTA}${BOLD}-- $1${RESET}"; echo ""; }

usage() {
cat <<EOF

  ${BOLD}reset.sh${RESET} - undo vps_setup.sh so you can run it again

    --remove-certs    Also delete the SSL certificate.
                      ${YELLOW}Read the rate-limit warning below before using this.${RESET}
    --remove-images   Also delete the downloaded n8n / OpenClaw images.
                      Makes the next run re-download ~1.5 GB.
    --dry-run         Show what would be removed. Changes nothing.
    -y, --yes         Skip the confirmation prompt.
    -h, --help        This text.

  ${BOLD}Recording a demo?${RESET} Use no flags at all. Keeping the certificate and
  the images makes the next run fast and removes the biggest thing that can
  go wrong on camera.

EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --remove-certs)  REMOVE_CERTS=true ;;
        --remove-images) REMOVE_IMAGES=true ;;
        --dry-run)       DRY_RUN=true ;;
        -y|--yes)        ASSUME_YES=true ;;
        -h|--help)       usage; exit 0 ;;
        *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
    shift
done

[ "${EUID:-$(id -u)}" -ne 0 ] && { echo "Run with sudo:  sudo bash reset.sh"; exit 1; }

DOMAIN=""; N8N_HOSTNAME=""; CLAW_HOSTNAME=""
# shellcheck disable=SC1090
[ -f "$CONF_FILE" ] && . "$CONF_FILE"

run() {
    if [ "$DRY_RUN" = true ]; then
        echo "  ${DIM}would run: $*${RESET}"
        return 0
    fi
    "$@" >/dev/null 2>&1
}

# =============================================================================
clear
echo "${CYAN}${BOLD}"
cat <<'BANNER'
  +==================================================================+
  |          Agentic AI stack - reset to a clean slate               |
  +==================================================================+
BANNER
echo "${RESET}"

[ "$DRY_RUN" = true ] && echo "  ${BOLD}${CYAN}DRY RUN - nothing will actually be removed.${RESET}" && echo ""

echo "  ${BOLD}This will remove:${RESET}"
echo "    - Containers: n8n, openclaw-gateway (and any leftover CLI containers)"
echo "    - The n8n data volume ${BOLD}including all your workflows and credentials${RESET}"
echo "    - ${DEPLOY_DIR} (compose file, secrets, OpenClaw config)"
echo "    - Nginx sites for ${N8N_HOSTNAME:-n8n.*} and ${CLAW_HOSTNAME:-claw.*}"
echo "    - ${CONF_FILE}, ${CREDS_FILE}, ${LOG_FILE}"
echo "    - The 'agentic' command"
[ "$REMOVE_CERTS" = true ]  && echo "    - ${YELLOW}The SSL certificate${RESET}"
[ "$REMOVE_IMAGES" = true ] && echo "    - ${YELLOW}The downloaded container images (~1.5 GB re-download)${RESET}"
echo ""
echo "  ${BOLD}${GREEN}This will NOT touch:${RESET}"
echo "    - Nginx itself, or any other website on this server"
echo "    - Docker Engine, or any container outside this stack"
echo "    - Firewall rules, swap, or system packages"
[ "$REMOVE_CERTS" = false ] && echo "    - Your SSL certificate ${DIM}(kept on purpose - see below)${RESET}"
echo ""

if [ "$REMOVE_CERTS" = true ]; then
    echo "  ${RED}${BOLD}Warning about deleting the certificate${RESET}"
    echo "  ${YELLOW}Let's Encrypt allows 5 certificates per week for the same set of"
    echo "  names. If you delete and re-issue on every take, a few recordings"
    echo "  will exhaust that and the next run will fail SSL - with a wait of"
    echo "  up to a week before it works again.${RESET}"
    echo ""
    echo "  ${DIM}Keeping the certificate is invisible on camera: the setup still"
    echo "  prints \"Certificate issued\", it just reuses the valid one.${RESET}"
    echo ""
fi

if [ "$ASSUME_YES" = false ] && [ "$DRY_RUN" = false ]; then
    echo "  ${BOLD}Type${RESET} ${CYAN}reset${RESET} ${BOLD}to confirm, or anything else to cancel.${RESET}"
    read -rp "  > " answer || true
    if [ "${answer:-}" != "reset" ]; then
        echo ""
        info "Cancelled. Nothing was changed."
        exit 0
    fi
fi

# =============================================================================
sect "Containers and volumes"

if [ -f "${DEPLOY_DIR}/docker-compose.yml" ]; then
    step "Stopping the stack and removing its volumes and network ..."
    if [ "$DRY_RUN" = true ]; then
        echo "  ${DIM}would run: docker compose -f ${DEPLOY_DIR}/docker-compose.yml down -v --remove-orphans${RESET}"
    elif docker compose -f "${DEPLOY_DIR}/docker-compose.yml" down -v --remove-orphans >/dev/null 2>&1; then
        ok "Stack stopped, volumes and network removed"
    else
        warn "Compose teardown reported a problem - falling back to removing by name"
    fi
else
    skip "No compose file found at ${DEPLOY_DIR}"
fi

# Catch anything the compose teardown missed, plus the legacy v2 container.
for c in n8n openclaw-gateway openclaw; do
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$c"; then
        run docker rm -f "$c" && ok "Removed container '${c}'" || warn "Could not remove '${c}'"
    else
        skip "Container '${c}' not present"
    fi
done

# One-off `docker compose run` containers accumulate under this name pattern.
LEFTOVERS="$(docker ps -a --filter 'name=openclaw-cli-run' --format '{{.ID}}' 2>/dev/null || true)"
if [ -n "$LEFTOVERS" ]; then
    step "Removing leftover one-off CLI containers ..."
    for id in $LEFTOVERS; do run docker rm -f "$id"; done
    ok "Removed $(echo "$LEFTOVERS" | wc -w) leftover container(s)"
else
    skip "No leftover CLI containers"
fi

for v in agentic-stack_n8n_data agentic-stack_openclaw_data; do
    if docker volume inspect "$v" >/dev/null 2>&1; then
        run docker volume rm "$v" && ok "Removed volume '${v}'" || warn "Volume '${v}' still in use"
    else
        skip "Volume '${v}' not present"
    fi
done

if docker network inspect agentic-stack_agentic_net >/dev/null 2>&1; then
    run docker network rm agentic-stack_agentic_net && ok "Removed the stack network" || warn "Network still in use"
else
    skip "Stack network not present"
fi

if [ "$REMOVE_IMAGES" = true ]; then
    step "Removing downloaded images ..."
    IMGS="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
            | grep -E 'openclaw|n8n' || true)"
    if [ -n "$IMGS" ]; then
        for i in $IMGS; do run docker rmi "$i"; done
        ok "Removed $(echo "$IMGS" | wc -w) image(s) - the next run re-downloads them"
    else
        skip "No stack images found"
    fi
else
    skip "Keeping downloaded images (the next run will be much faster)"
fi

# =============================================================================
sect "Nginx"

NGINX_CHANGED=false
for s in n8n claw 000-agentic-default; do
    for p in "/etc/nginx/sites-enabled/${s}" "/etc/nginx/sites-available/${s}"; do
        if [ -e "$p" ] || [ -L "$p" ]; then
            run rm -f "$p" && NGINX_CHANGED=true
        fi
    done
done
[ "$NGINX_CHANGED" = true ] && ok "Removed the stack's Nginx sites" || skip "No stack Nginx sites found"

if [ -f /etc/nginx/conf.d/agentic-upgrade.conf ]; then
    run rm -f /etc/nginx/conf.d/agentic-upgrade.conf && NGINX_CHANGED=true
    ok "Removed the WebSocket upgrade map"
else
    skip "No WebSocket upgrade map found"
fi

if [ -d "$WEBROOT" ]; then
    run rm -rf "$WEBROOT" && ok "Removed the ACME webroot"
else
    skip "No ACME webroot found"
fi

if [ "$NGINX_CHANGED" = true ] && [ "$DRY_RUN" = false ]; then
    step "Checking Nginx is still valid for your other sites ..."
    if nginx -t >/tmp/agentic_reset_nginx.log 2>&1; then
        systemctl reload nginx >/dev/null 2>&1
        ok "Nginx configuration is valid and reloaded"
        info "Your other websites are unaffected."
    else
        warn "Nginx reports a problem AFTER removing our files:"
        echo ""
        tail -n 15 /tmp/agentic_reset_nginx.log
        echo ""
        warn "This is not caused by the removal - our files are gone."
        info "Inspect with:  nginx -t"
    fi
fi

# =============================================================================
sect "Files"

for f in "$CONF_FILE" "$CREDS_FILE" "$LOG_FILE" /usr/local/bin/agentic; do
    if [ -e "$f" ]; then
        run rm -f "$f" && ok "Removed ${f}"
    else
        skip "${f} not present"
    fi
done

if [ -d "$DEPLOY_DIR" ]; then
    run rm -rf "$DEPLOY_DIR" && ok "Removed ${DEPLOY_DIR}"
else
    skip "${DEPLOY_DIR} not present"
fi

# =============================================================================
sect "SSL certificate"

CERT_NAME="${N8N_HOSTNAME:-}"
if [ "$REMOVE_CERTS" = true ] && [ -n "$CERT_NAME" ]; then
    if [ -d "/etc/letsencrypt/live/${CERT_NAME}" ]; then
        if [ "$DRY_RUN" = true ]; then
            echo "  ${DIM}would run: certbot delete --cert-name ${CERT_NAME} --non-interactive${RESET}"
        else
            certbot delete --cert-name "$CERT_NAME" --non-interactive >/dev/null 2>&1 \
                && ok "Deleted the certificate for ${CERT_NAME}" \
                || warn "Certbot could not delete '${CERT_NAME}'"
        fi
    else
        skip "No certificate found for ${CERT_NAME}"
    fi
    run rm -f /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
elif [ -n "$CERT_NAME" ] && [ -d "/etc/letsencrypt/live/${CERT_NAME}" ]; then
    ok "Kept the certificate for ${CERT_NAME}"
    info "The next setup run will reuse it instead of asking Let's Encrypt again."
    info "Delete it with --remove-certs only if you really need to."
else
    skip "No certificate to consider"
fi

# =============================================================================
echo ""
echo "${GREEN}${BOLD}================================================================${RESET}"
if [ "$DRY_RUN" = true ]; then
    echo "  ${BOLD}Dry run finished. Nothing was changed.${RESET}"
else
    echo "  ${GREEN}${BOLD}Reset complete. This server is ready for a fresh run.${RESET}"
fi
echo "${GREEN}${BOLD}================================================================${RESET}"
echo ""
echo "  ${BOLD}Before recording, double-check:${RESET}"
echo "    - DNS for ${N8N_HOSTNAME:-n8n.<domain>} and ${CLAW_HOSTNAME:-claw.<domain>} still points here"
echo "    - Your AI API key is on the clipboard"
echo "    - You know the dashboard token you plan to type"
echo ""
echo "  ${BOLD}Then run:${RESET}"
echo ""
echo "    ${CYAN}curl -fsSL https://raw.githubusercontent.com/BlackTigerQ8/agentic-vps-setup/main/vps_setup.sh -o vps_setup.sh && sudo bash vps_setup.sh${RESET}"
echo ""
if [ "$REMOVE_IMAGES" = false ]; then
    info "Images were kept, so the download step will finish in seconds."
    info "Use --remove-images if you want to show the real download time."
    echo ""
fi
