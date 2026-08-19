#!/usr/bin/env bash
# connect_local_files.sh
# Mounts a host folder (/opt/agentic-stack/local-files) into the n8n container
# so trainees can upload source documents from their own machine and read them
# in n8n with the "Read/Write Files from Disk" node.
#
# Two things are needed, not one:
#   1. The bind mount, so the files exist inside the container at all.
#   2. N8N_RESTRICT_FILE_ACCESS_TO. As of n8n 2.0 this defaults to ~/.n8n-files
#      even when never set, so without it the mount exists but n8n refuses to
#      read from it ("Access to the file is not allowed") — mount, permissions
#      and path all check out fine while the node still fails.
#
# The env var goes in stack.env, not docker-compose.yml: the compose file's
# environment: block uses mapping syntax (KEY: value), so appending a list
# item (- KEY=value) to it is invalid YAML. stack.env is already wired in via
# env_file and is plain KEY=value, so there is no YAML structure to get wrong.
set -euo pipefail

DEPLOY_DIR="/opt/agentic-stack"
COMPOSE_FILE="${DEPLOY_DIR}/docker-compose.yml"
ENV_FILE="${DEPLOY_DIR}/stack.env"
LOCAL_FILES_DIR="${DEPLOY_DIR}/local-files"

CONTAINER_PATH="/home/node/local-files"
MOUNT_MARKER="./local-files:${CONTAINER_PATH}"
ENV_KEY="N8N_RESTRICT_FILE_ACCESS_TO"

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

CHANGED=false

# ---- 1. The bind mount (docker-compose.yml) ----
if grep -qF "$MOUNT_MARKER" "$COMPOSE_FILE"; then
  print_ok "The local-files mount is already in docker-compose.yml."
else
  print_step "Adding the local-files mount to the n8n service"
  BACKUP="${COMPOSE_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$COMPOSE_FILE" "$BACKUP"
  print_ok "Backed up docker-compose.yml to $BACKUP"

  # Insert after the existing n8n_data volume line, matching its exact
  # indentation rather than assuming a width.
  awk -v newpath="$MOUNT_MARKER" '
    /container_name: n8n$/ { in_n8n=1 }
    in_n8n && /^[[:space:]]*-[[:space:]]*n8n_data:\/home\/node\/\.n8n/ && !done {
      print
      match($0, /^[[:space:]]*/)
      indent = substr($0, RSTART, RLENGTH)
      print indent "- " newpath
      done=1
      next
    }
    { print }
  ' "$COMPOSE_FILE" > "${COMPOSE_FILE}.tmp" && mv "${COMPOSE_FILE}.tmp" "$COMPOSE_FILE"

  if ! grep -qF "$MOUNT_MARKER" "$COMPOSE_FILE"; then
    print_err "Could not add the mount automatically — restoring the backup, no changes kept."
    cp "$BACKUP" "$COMPOSE_FILE"
    print_err "Add this line yourself under the n8n service's 'volumes:' section:"
    echo "      - ${MOUNT_MARKER}"
    exit 1
  fi

  # Text being present is not enough — confirm the file still parses.
  if ! (cd "$DEPLOY_DIR" && docker compose config --quiet) 2>/dev/null; then
    print_err "The edit broke the compose file's YAML — restoring the backup, no changes kept."
    cp "$BACKUP" "$COMPOSE_FILE"
    print_err "Add this line yourself under the n8n service's 'volumes:' section:"
    echo "      - ${MOUNT_MARKER}"
    exit 1
  fi

  print_ok "Mount added and the compose file still parses cleanly."
  CHANGED=true
fi

# ---- 2. The file-access permission (stack.env) ----
if [[ ! -f "$ENV_FILE" ]]; then
  print_err "Could not find $ENV_FILE"
  print_err "Add this line to the n8n service's environment in docker-compose.yml instead"
  print_err "(note the mapping syntax used there - a colon, not an equals sign):"
  echo "      ${ENV_KEY}: ${CONTAINER_PATH}"
  exit 1
fi

if ! grep -qF "stack.env" "$COMPOSE_FILE"; then
  print_warn "stack.env exists but docker-compose.yml does not reference it via env_file."
  print_warn "Add this to the n8n service's environment: block manually instead:"
  echo "      ${ENV_KEY}: ${CONTAINER_PATH}"
elif grep -q "^${ENV_KEY}=" "$ENV_FILE"; then
  CURRENT="$(grep "^${ENV_KEY}=" "$ENV_FILE" | head -n1 | cut -d= -f2-)"
  if [[ "$CURRENT" == *"$CONTAINER_PATH"* ]]; then
    print_ok "n8n is already allowed to read from ${CONTAINER_PATH}."
  else
    print_step "Extending the existing file-access setting"
    sed -i "s|^${ENV_KEY}=.*|${ENV_KEY}=${CURRENT};${CONTAINER_PATH}|" "$ENV_FILE"
    print_ok "Added ${CONTAINER_PATH} alongside the existing allowed paths."
    CHANGED=true
  fi
else
  print_step "Allowing n8n to read from ${CONTAINER_PATH}"
  echo "${ENV_KEY}=${CONTAINER_PATH}" >> "$ENV_FILE"
  print_ok "Added to stack.env."
  CHANGED=true
fi

# ---- 3. Apply ----
if [[ "$CHANGED" == true ]]; then
  print_step "Recreating the n8n container to apply the changes"
  (cd "$DEPLOY_DIR" && docker compose up -d --force-recreate n8n)

  if docker exec n8n env 2>/dev/null | grep -q "^${ENV_KEY}="; then
    print_ok "n8n restarted, and it can now read from ${CONTAINER_PATH}."
  else
    print_warn "n8n restarted, but ${ENV_KEY} is not visible inside the container."
    print_warn "Check it with: docker exec n8n env | grep ${ENV_KEY}"
  fi
else
  print_ok "Everything was already set up — nothing to restart."
fi

echo
print_ok "Setup complete."
echo
echo "Upload files from your own machine like this:"
echo "    scp yourfile.md root@<your-vps-ip>:${LOCAL_FILES_DIR}/"
echo
echo "Subfolders work too, e.g.:"
echo "    scp yourfile.md root@<your-vps-ip>:${LOCAL_FILES_DIR}/capstone-project/"
echo
echo "In n8n, read a file with the 'Read/Write Files from Disk' node, pointed at:"
echo "    ${CONTAINER_PATH}/yourfile.md"
echo "    ${CONTAINER_PATH}/capstone-project/yourfile.md   (if using a subfolder)"
