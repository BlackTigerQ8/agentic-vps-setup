#!/usr/bin/env bash
# connect_local_files.sh
# Mounts a host folder (/opt/agentic-stack/local-files) into the n8n container
# so trainees can upload source documents from their own machine and read them
# in n8n with the "Read/Write Files from Disk" node.
#
# Also sets N8N_RESTRICT_FILE_ACCESS_TO. As of n8n 2.0, file access for the
# Read/Write Files from Disk node defaults to ~/.n8n-files even when this
# variable is never set — so without it, the mount above exists but n8n
# refuses to read from it ("Access to the file is not allowed"), silently
# passing every existing check (mount, permissions, path) while still failing.
set -euo pipefail

DEPLOY_DIR="/opt/agentic-stack"
COMPOSE_FILE="${DEPLOY_DIR}/docker-compose.yml"
LOCAL_FILES_DIR="${DEPLOY_DIR}/local-files"

VOLUME_ANCHOR="n8n_data:/home/node/.n8n"
NEW_VOLUME_LINE="      - ./local-files:/home/node/local-files"
MOUNT_MARKER="./local-files:/home/node/local-files"

CONTAINER_ANCHOR="container_name: n8n"
NEW_ENV_LINE="      - N8N_RESTRICT_FILE_ACCESS_TO=/home/node/local-files"
ENV_MARKER="N8N_RESTRICT_FILE_ACCESS_TO=/home/node/local-files"

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

NEED_MOUNT=false
NEED_ENV=false
grep -qF "$MOUNT_MARKER" "$COMPOSE_FILE" || NEED_MOUNT=true
grep -qF "$ENV_MARKER" "$COMPOSE_FILE" || NEED_ENV=true

if [[ "$NEED_MOUNT" == false && "$NEED_ENV" == false ]]; then
  print_ok "docker-compose.yml already has the mount and the file-access setting — nothing to change."
else
  print_step "Backing up docker-compose.yml before editing it"
  BACKUP="${COMPOSE_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$COMPOSE_FILE" "$BACKUP"
  print_ok "Backup saved to $BACKUP"

  if [[ "$NEED_MOUNT" == true ]]; then
    if ! grep -qF "$VOLUME_ANCHOR" "$COMPOSE_FILE"; then
      print_err "Could not find the expected n8n volume line in docker-compose.yml."
      print_err "No changes made. Add this line yourself under the n8n service's 'volumes:' section:"
      echo "$NEW_VOLUME_LINE"
      exit 1
    fi
    print_step "Adding the local-files mount to the n8n service"
    sed -i "/${VOLUME_ANCHOR//\//\\/}/a\\${NEW_VOLUME_LINE}" "$COMPOSE_FILE"
  fi

  if [[ "$NEED_ENV" == true ]]; then
    if ! grep -qF "$CONTAINER_ANCHOR" "$COMPOSE_FILE"; then
      print_err "Could not find 'container_name: n8n' in docker-compose.yml."
      cp "$BACKUP" "$COMPOSE_FILE"
      print_err "No changes made. Add this line yourself under the n8n service's 'environment:' section:"
      echo "$NEW_ENV_LINE"
      exit 1
    fi
    print_step "Allowing n8n to read from /home/node/local-files"
    awk -v newline="$NEW_ENV_LINE" '
      /container_name: n8n$/ { in_n8n=1 }
      in_n8n && /^[[:space:]]*environment:/ && !done {
        print
        print newline
        done=1
        next
      }
      { print }
    ' "$COMPOSE_FILE" > "${COMPOSE_FILE}.tmp" && mv "${COMPOSE_FILE}.tmp" "$COMPOSE_FILE"
  fi

  MOUNT_OK=true
  ENV_OK=true
  grep -qF "$MOUNT_MARKER" "$COMPOSE_FILE" || MOUNT_OK=false
  grep -qF "$ENV_MARKER" "$COMPOSE_FILE" || ENV_OK=false

  if [[ "$MOUNT_OK" == true && "$ENV_OK" == true ]]; then
    print_ok "docker-compose.yml updated."
  else
    print_err "Automatic edit did not verify correctly — restoring the backup, no changes kept."
    cp "$BACKUP" "$COMPOSE_FILE"
    [[ "$MOUNT_OK" == false ]] && { print_err "Add this yourself under 'volumes:':"; echo "$NEW_VOLUME_LINE"; }
    [[ "$ENV_OK" == false ]] && { print_err "Add this yourself under 'environment:':"; echo "$NEW_ENV_LINE"; }
    exit 1
  fi

  print_step "Recreating the n8n container to apply the changes"
  (cd "$DEPLOY_DIR" && docker compose up -d --force-recreate n8n)
  print_ok "n8n restarted with the mount and file-access setting active."
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
