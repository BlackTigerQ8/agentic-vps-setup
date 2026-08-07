#!/usr/bin/env bash
# =============================================================================
#   DEPRECATED - kept only so old links keep working.
#
#   This script was written for setup v2, which put OpenClaw on port 8080 in a
#   container named "openclaw". Neither is correct: the OpenClaw gateway
#   listens on 18789, and v3 names the container "openclaw-gateway".
#
#   Everything this script used to do is now in the setup script or the
#   'agentic' helper command that it installs.
# =============================================================================

set -uo pipefail

if [ -t 1 ]; then
    C=$'\033[0;36m'; Y=$'\033[1;33m'; B=$'\033[1m'; D=$'\033[2m'; N=$'\033[0m'
else
    C=""; Y=""; B=""; D=""; N=""
fi

cat <<EOF

  ${Y}${B}This script is no longer needed.${N}

  ${B}If OpenClaw is misbehaving:${N}

      ${C}sudo agentic doctor${N}       repair the gateway and restart it
      ${C}sudo agentic status${N}       see what is and is not working
      ${C}sudo agentic whatsapp${N}     pair WhatsApp (shows the QR code)
      ${C}sudo agentic open${N}         one-click dashboard login link

  ${B}If the 'agentic' command is not found${N}, your server was built with the
  old setup script. Re-run the current one - it is safe to run over an
  existing install and will migrate you:

      ${C}curl -fsSL https://raw.githubusercontent.com/BlackTigerQ8/agentic-vps-setup/main/vps_setup.sh -o vps_setup.sh && sudo bash vps_setup.sh${N}

  ${B}Not sure what is wrong?${N} Run the read-only health report and send the
  output to your instructor:

      ${C}curl -fsSL https://raw.githubusercontent.com/BlackTigerQ8/agentic-vps-setup/main/diagnose.sh -o diagnose.sh && sudo bash diagnose.sh${N}

  ${D}Note: the OpenClaw dashboard no longer needs an SSH tunnel. It is served
  at https://claw.<your-domain> with a real SSL certificate.${N}

EOF
