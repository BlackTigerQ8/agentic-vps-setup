#!/usr/bin/env bash
# connect_local_files.sh
# Mounts a host folder (/opt/agentic-stack/local-files) into the n8n container
# so trainees can upload source documents from their own machine and read them
# in n8n with the "Read/Write Files from Disk" node.
set -euo pipefail

DEPLOY_DIR="/opt/agentic-stack"
COMPOSE_FILE="${DEPLOY_DIR}/docker-compose.yml"
LOCAL_FILES_DIR="${DEPLOY_DIR}/local-files"
ANCHOR_LINE="n8n_data:/home/node/.n8n"
NEW_VOLUME_LINE="      - ./local-files:/home/node/local-files"
MOUNT_MARKER="./local-files:/home/node/local-files"

print_step() { echo -e "\n\033[1;34m==>\033[0m $1"; }
print_ok()   { echo -e "\033[1;32m\xE2\x9C\x93\033[0m $1"; }
print_warn() { echo -e "\033[1;33m!\033[0m $1"; }
print_err()  { echo -e "\033[1;31m\xE2\x9C\x97\033[0m $1"; }

if [[ $EUID -ne 0 ]]; then
  print_err "Run this with sudo: sudo bash connect_local_files.sh"
  exit 1
fi

if [[ ! -f "$COMPOSE_FILE" ]]; then
  print_err "Could not find $COMPOSE_FILE"
  print_err "Is this the right VPS, and was vps_setup.sh run here already?"
  exit 1
fi

print_step "Creating the local files directory"
mkdir -p "$LOCAL_FILES_DIR"
chown -R 1000:1000 "$LOCAL_FILES_DIR" 2>/dev/null || true
print_ok "Ready at $LOCAL_FILES_DIR"

if grep -qF "$MOUNT_MARKER" "$COMPOSE_FILE"; then
  print_ok "docker-compose.yml already has the local-files mount — nothing to change."
else
  print_step "Backing up docker-compose.yml before editing it"
  BACKUP="${COMPOSE_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$COMPOSE_FILE" "$BACKUP"
  print_ok "Backup saved to $BACKUP"

  if ! grep -qF "$ANCHOR_LINE" "$COMPOSE_FILE"; then
    print_err "Could not find the expected n8n volume line in docker-compose.yml."
    print_err "No changes made. Add this line yourself under the n8n service's 'volumes:' section:"
    echo "      - ./local-files:/home/node/local-files"
    exit 1
  fi

  print_step "Adding the local-files mount to the n8n service"
  sed -i "/${ANCHOR_LINE//\//\\/}/a\\${NEW_VOLUME_LINE}" "$COMPOSE_FILE"

  if grep -qF "$MOUNT_MARKER" "$COMPOSE_FILE"; then
    print_ok "docker-compose.yml updated."
  else
    print_err "Automatic edit did not verify correctly — restoring the backup, no changes kept."
    cp "$BACKUP" "$COMPOSE_FILE"
    print_err "Add this line yourself under the n8n service's 'volumes:' section instead:"
    echo "      - ./local-files:/home/node/local-files"
    exit 1
  fi

  print_step "Recreating the n8n container to apply the new mount"
  (cd "$DEPLOY_DIR" && docker compose up -d --force-recreate n8n)
  print_ok "n8n restarted with the new mount active."
fi

echo
print_ok "Setup complete."
echo
echo "Upload files from your own machine like this:"
echo "    scp yourfile.pdf root@<your-vps-ip>:${LOCAL_FILES_DIR}/"
echo
echo "Subfolders work too, e.g.:"
echo "    scp yourfile.pdf root@<your-vps-ip>:${LOCAL_FILES_DIR}/capstone-project/"
echo
echo "In n8n, read a file with the 'Read/Write Files from Disk' node, pointed at:"
echo "    /home/node/local-files/yourfile.pdf"
echo "    /home/node/local-files/capstone-project/yourfile.pdf   (if using a subfolder)"
