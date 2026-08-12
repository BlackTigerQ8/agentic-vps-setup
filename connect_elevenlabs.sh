#!/usr/bin/env bash
# =============================================================================
#   CODED Agentic AI Bootcamp - Connect ElevenLabs voice to OpenClaw
#
#   Turns on two things:
#     1. Voice replies - OpenClaw automatically replies with a spoken WhatsApp
#        voice note whenever the message it's replying to was ITSELF a voice
#        note (typed messages still get typed replies). This uses OpenClaw's
#        own built-in messages.tts mechanism with ElevenLabs as the speech
#        provider - not a skill, not a hand-rolled binary. The gateway itself
#        knows whether the inbound message was audio, so this doesn't depend
#        on the model noticing or deciding anything.
#     2. Voice notes in - lets OpenClaw understand a voice note you send it,
#        transcribing it via ElevenLabs speech-to-text.
#
#   WhatsApp voice notes are OGG/Opus, so this also bakes ffmpeg into a small
#   custom image (the stock OpenClaw image doesn't have it) - required to
#   transcode ElevenLabs' MP3 output into a real, playable voice note.
#
#   Run this on a server already built by vps_setup.sh - it does not touch
#   vps_setup.sh, connect_n8n.sh, or anything else. Safe to run again if you
#   want to change the voice ID or API key later.
#
#     curl -fsSL https://raw.githubusercontent.com/BlackTigerQ8/agentic-vps-setup/main/connect_elevenlabs.sh -o connect_elevenlabs.sh && sudo bash connect_elevenlabs.sh
#
#   Version: 3.0.0
# =============================================================================

set -Eeuo pipefail

DEPLOY_DIR="/opt/agentic-stack"
CONF_FILE="/etc/agentic-stack.conf"
LOCAL_IMAGE_TAG="agentic-openclaw-voice:latest"
OLD_LOCAL_IMAGE_TAG="agentic-openclaw-sag:latest"
DEFAULT_VOICE_ID="21m00Tcm4TlvDq8ikWAm"   # ElevenLabs premade voice "Rachel" - a safe default that exists on every account
TTS_MODEL="eleven_multilingual_v2"        # handles Arabic + English

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
  |     Connect ElevenLabs voice to OpenClaw - CODED Bootcamp         |
  +==================================================================+
BANNER
echo "${RESET}"

[ "${EUID:-$(id -u)}" -ne 0 ] && { bad "Run with sudo:  sudo bash connect_elevenlabs.sh"; exit 1; }

[ -f "$CONF_FILE" ] || die "No ${CONF_FILE} found. Run vps_setup.sh first - this server hasn't been set up yet."
# shellcheck disable=SC1090
. "$CONF_FILE"
BASE_IMAGE_MARKER="${DEPLOY_DIR}/.openclaw-base-image"

[ -f "${DEPLOY_DIR}/docker-compose.yml" ] || die "No stack found at ${DEPLOY_DIR}. Run vps_setup.sh first."
[ -f "${DEPLOY_DIR}/stack.env" ] || die "No ${DEPLOY_DIR}/stack.env found. Run vps_setup.sh first."

if ! docker inspect -f '{{.State.Running}}' openclaw-gateway 2>/dev/null | grep -q true; then
    die "OpenClaw isn't running. Check:  sudo agentic status"
fi

dc() { docker compose -f "${DEPLOY_DIR}/docker-compose.yml" "$@"; }
oc() { dc run --rm openclaw-cli "$@"; }
oc_q() { dc run --rm -T openclaw-cli "$@"; }

# =============================================================================
sect "What this does"

echo "  Right now OpenClaw replies on WhatsApp with text. This adds a real voice:"
echo "  when someone sends a voice note, OpenClaw understands it, and it will"
echo "  automatically reply with a spoken voice note back - only when the"
echo "  incoming message was itself a voice note. A typed message still gets"
echo "  a typed reply."
echo ""
echo "  Have your ${BOLD}ElevenLabs API key${RESET} ready - from elevenlabs.io -> Profile ->"
echo "  API Keys. A voice ID is optional; leave it blank to use a standard"
echo "  ElevenLabs default voice, or paste one from your own ElevenLabs account."
echo ""
echo "  ${YELLOW}This step builds a small custom container image, so it takes a few"
echo "  minutes - longer than the other connect scripts.${RESET}"
echo ""

# =============================================================================
sect "A few questions"

key=""
while [ -z "$key" ]; do
    read -rsp "  ${CYAN}?${RESET} ElevenLabs API key (hidden): " key || true
    echo ""
done

voice_id=""
read -rp "  ${CYAN}?${RESET} Preferred voice ID (optional - press Enter for a default voice): " voice_id || true
[ -z "$voice_id" ] && voice_id="$DEFAULT_VOICE_ID"

echo ""
echo "  Voice notes are transcribed to text before OpenClaw reads them. Seeing"
echo "  that transcript in the chat helps trainees understand what happened -"
echo "  useful for a bootcamp, easy to turn off later if it gets noisy."
read -rp "  ${CYAN}?${RESET} Show the transcript in chat too? [Y/n]: " echo_ans || true
echo_transcript=true
[[ "$echo_ans" =~ ^[Nn] ]] && echo_transcript=false

echo ""
echo "  ${BOLD}Review:${RESET}"
echo "    API key:         ${DIM}hidden (${#key} characters)${RESET}"
echo "    Voice ID:        ${CYAN}${voice_id}${RESET}"
echo "    Show transcript: ${CYAN}${echo_transcript}${RESET}"
echo ""
read -rp "  ${CYAN}?${RESET} Connect this now? [y/N]: " confirm || true
[[ "$confirm" =~ ^[Yy] ]] || { info "Cancelled. Nothing was changed."; exit 0; }

# =============================================================================
sect "Saving keys"

set_env_var() {
    # set_env_var NAME VALUE - idempotent replace-or-append in stack.env
    local name="$1" value="$2"
    if grep -q "^${name}=" "${DEPLOY_DIR}/stack.env" 2>/dev/null; then
        sed -i "s#^${name}=.*#${name}=${value}#" "${DEPLOY_DIR}/stack.env"
    else
        echo "${name}=${value}" >> "${DEPLOY_DIR}/stack.env"
    fi
}

set_env_var ELEVENLABS_API_KEY "$key"
set_env_var ELEVENLABS_VOICE_ID "$voice_id"
chmod 600 "${DEPLOY_DIR}/stack.env"
ok "Saved to ${DEPLOY_DIR}/stack.env"

# =============================================================================
sect "Building the voice-enabled image"

# Remember the real upstream tag once, on the first run, so re-runs still know
# what to rebuild from even after docker-compose.yml points at our own local
# image. Without this, a second run would try to build "FROM" itself.
if [ ! -f "$BASE_IMAGE_MARKER" ]; then
    detected="$(grep -m1 -oE 'image:[[:space:]]*ghcr\.io/openclaw/openclaw:[^[:space:]]+' "${DEPLOY_DIR}/docker-compose.yml" \
        | awk '{print $2}' || true)"
    [ -z "$detected" ] && detected="ghcr.io/openclaw/openclaw:latest"
    echo "$detected" > "$BASE_IMAGE_MARKER"
fi
BASE_IMAGE="$(cat "$BASE_IMAGE_MARKER")"
info "Building from ${BASE_IMAGE}"

cat > "${DEPLOY_DIR}/Dockerfile.openclaw" <<EOF
FROM ${BASE_IMAGE}
USER root
RUN apt-get update && \\
    apt-get install -y --no-install-recommends ffmpeg ca-certificates curl && \\
    rm -rf /var/lib/apt/lists/*
USER node
EOF

step "docker build (this is the slow part, 1-3 minutes) ..."
if (cd "$DEPLOY_DIR" && docker build --pull -t "$LOCAL_IMAGE_TAG" -f Dockerfile.openclaw . \
        >/tmp/connect_11labs_build.log 2>&1); then
    ok "Image built: ${LOCAL_IMAGE_TAG}"
else
    bad "Image build failed"
    echo ""
    tail -n 40 /tmp/connect_11labs_build.log
    echo ""
    die "Nothing was changed in docker-compose.yml - OpenClaw is still running as before."
fi

step "Pointing docker-compose.yml at the new image ..."
sed -i -E "s#image:[[:space:]]*(ghcr\.io/openclaw/openclaw:[^[:space:]]+|${OLD_LOCAL_IMAGE_TAG//\//\\/}|${LOCAL_IMAGE_TAG//\//\\/})#image: ${LOCAL_IMAGE_TAG}#" \
    "${DEPLOY_DIR}/docker-compose.yml"
ok "docker-compose.yml updated"

step "Recreating OpenClaw with the new image ..."
if dc up -d openclaw-gateway >/tmp/connect_11labs_last.log 2>&1; then
    ok "Container recreated"
else
    bad "Recreate failed"
    tail -n 20 /tmp/connect_11labs_last.log
    die "Check:  sudo agentic logs claw"
fi

t0=$SECONDS
up=false
while [ $((SECONDS - t0)) -lt 90 ]; do
    if curl -fsS --max-time 3 "http://127.0.0.1:18789/healthz" >/dev/null 2>&1; then
        up=true; break
    fi
    sleep 2
done
[ "$up" = true ] && ok "OpenClaw is back up" || warn "OpenClaw is slow to come back. Check:  sudo agentic status"

# =============================================================================
sect "Turning on voice notes in"

if oc_q config set tools.media.audio.enabled true >/tmp/connect_11labs_last.log 2>&1; then
    ok "Audio understanding enabled"
else
    warn "Could not enable audio understanding - continuing anyway"
    tail -n 15 /tmp/connect_11labs_last.log
fi

if [ "$echo_transcript" = true ]; then
    oc_q config set tools.media.audio.echoTranscript true >/tmp/connect_11labs_last.log 2>&1 \
        && ok "Transcript echo enabled" \
        || warn "Could not enable transcript echo - continuing anyway"
fi

# tools.media.audio.enabled only turns on the PERMISSION to understand audio.
# It does not say HOW - that is a separate, required field (audio.transcription
# .command). Point it at a small wrapper that calls ElevenLabs' own
# speech-to-text, reusing the key already saved above - no Whisper, no second
# subscription, works the same on free or paid ElevenLabs.
step "Wiring up voice-note transcription (ElevenLabs, not Whisper) ..."
bin_dir="${DEPLOY_DIR}/openclaw-workspace/bin"
mkdir -p "$bin_dir"
cat > "${bin_dir}/elevenlabs-transcribe.sh" <<'WRAPPEREOF'
#!/bin/sh
# Transcribes one audio file via ElevenLabs speech-to-text.
# Usage: elevenlabs-transcribe.sh /path/to/audio-file
# Reads ELEVENLABS_API_KEY from the environment (already set on this
# container via stack.env). Prints the transcript to stdout, or nothing
# if the call fails - never a fake error dressed up as a transcript.
AUDIO_FILE="$1"
curl -sS --max-time 30 -X POST https://api.elevenlabs.io/v1/speech-to-text \
    -H "xi-api-key: ${ELEVENLABS_API_KEY}" \
    -F "file=@${AUDIO_FILE}" \
    -F "model_id=scribe_v2" \
| node -e '
let d = "";
process.stdin.on("data", c => { d += c; });
process.stdin.on("end", () => {
    try { process.stdout.write((JSON.parse(d).text || "").trim()); }
    catch (e) { process.stdout.write(""); }
});
'
WRAPPEREOF
chmod +x "${bin_dir}/elevenlabs-transcribe.sh"
chown -R 1000:1000 "$bin_dir" 2>/dev/null || true
ok "Wrapper script written"

if oc_q config set audio.transcription.command \
        '["/home/node/.openclaw/workspace/bin/elevenlabs-transcribe.sh", "{{MediaPath}}"]' \
        --strict-json >/tmp/connect_11labs_last.log 2>&1; then
    ok "Transcription command set"
else
    bad "Could not set the transcription command"
    tail -n 20 /tmp/connect_11labs_last.log
    die "Voice notes in will not work until this is fixed - everything else above is still saved."
fi
oc_q config set audio.transcription.timeoutSeconds 30 >/tmp/connect_11labs_last.log 2>&1 \
    && ok "Transcription timeout set" \
    || warn "Could not set transcription timeout - continuing anyway"

# =============================================================================
sect "Turning on automatic voice replies"

# This is OpenClaw's own built-in text-to-speech auto-reply mechanism, not a
# skill. The gateway decides whether to speak based on the inbound message's
# real type - "inbound" mode means voice-in triggers voice-out, independent
# of anything the model does. All three of enabled/auto/provider AND a real
# voice (speakerVoiceId) + model must be set together - a provider with only
# an apiKey and no voice silently never synthesizes anything (no error, no
# log line, just a plain text reply every time).
oc_q config set messages.tts.enabled true >/tmp/connect_11labs_last.log 2>&1 \
    && ok "TTS enabled" \
    || { bad "Could not enable TTS"; tail -n 20 /tmp/connect_11labs_last.log; die "Aborting."; }

oc_q config set messages.tts.auto inbound >/tmp/connect_11labs_last.log 2>&1 \
    && ok "Auto-reply mode set to 'inbound' (voice-in -> voice-out only)" \
    || { bad "Could not set messages.tts.auto"; tail -n 20 /tmp/connect_11labs_last.log; die "Aborting."; }

oc_q config set messages.tts.provider elevenlabs >/tmp/connect_11labs_last.log 2>&1 \
    && ok "TTS provider set to elevenlabs" \
    || { bad "Could not set messages.tts.provider"; tail -n 20 /tmp/connect_11labs_last.log; die "Aborting."; }

# Plain string, not a secret-reference object - a {"source":"env",...} shape
# here requires a registered secret provider that doesn't exist by that name
# and makes the gateway crash-loop on every restart. A plain string is valid
# per the schema and is what actually works.
oc_q config set messages.tts.providers.elevenlabs.apiKey "$key" >/tmp/connect_11labs_last.log 2>&1 \
    && ok "ElevenLabs API key set" \
    || { bad "Could not set the ElevenLabs API key"; tail -n 20 /tmp/connect_11labs_last.log; die "Aborting."; }

oc_q config set messages.tts.providers.elevenlabs.model "$TTS_MODEL" >/tmp/connect_11labs_last.log 2>&1 \
    && ok "ElevenLabs model set (${TTS_MODEL})" \
    || { bad "Could not set the ElevenLabs model"; tail -n 20 /tmp/connect_11labs_last.log; die "Aborting."; }

oc_q config set messages.tts.providers.elevenlabs.speakerVoiceId "$voice_id" >/tmp/connect_11labs_last.log 2>&1 \
    && ok "ElevenLabs voice set (${voice_id})" \
    || { bad "Could not set the ElevenLabs voice"; tail -n 20 /tmp/connect_11labs_last.log; die "Aborting."; }

step "Checking the config is still valid ..."
if oc_q config validate >/tmp/connect_11labs_last.log 2>&1; then
    ok "Config is valid"
else
    bad "Config validation failed"
    tail -n 30 /tmp/connect_11labs_last.log
    die "Something above isn't right - fix it before restarting, or OpenClaw may fail to start."
fi

step "Restarting so the config changes actually take effect ..."
dc restart openclaw-gateway >/tmp/connect_11labs_last.log 2>&1 || {
    bad "Restart failed"
    tail -n 20 /tmp/connect_11labs_last.log
    die "Check:  sudo agentic logs claw"
}

t0=$SECONDS
up=false
while [ $((SECONDS - t0)) -lt 60 ]; do
    if curl -fsS --max-time 3 "http://127.0.0.1:18789/healthz" >/dev/null 2>&1; then
        up=true; break
    fi
    sleep 2
done
[ "$up" = true ] && ok "OpenClaw is back up" || warn "OpenClaw is slow to come back. Check:  sudo agentic status"

# =============================================================================
sect "Verifying, before you rely on it"

step "Checking ffmpeg is present ..."
if dc exec -T openclaw-gateway which ffmpeg >/dev/null 2>&1; then
    ok "ffmpeg found"
else
    warn "ffmpeg not found in the running container - voice replies will fail to send. Check the build log above."
fi

step "Checking TTS is actually wired up ..."
oc_q capability tts status || warn "Could not read TTS status"

step "Doing a real ElevenLabs synthesis test (not a fallback) ..."
if dc exec -T openclaw-gateway sh -c \
        'openclaw capability tts convert --text "voice test" --channel whatsapp --output /tmp/connect_11labs_test --json' \
        >/tmp/connect_11labs_last.log 2>&1; then
    if grep -q '"elevenlabs"[^}]*"success"' /tmp/connect_11labs_last.log 2>/dev/null; then
        ok "ElevenLabs synthesized successfully (not a fallback)"
    else
        warn "Conversion ran but didn't clearly show an elevenlabs success - check the output below"
        tail -n 20 /tmp/connect_11labs_last.log
    fi
else
    warn "tts convert test failed - check the output below (often means the ElevenLabs key has no credits, or the voice ID doesn't exist on this account)"
    tail -n 20 /tmp/connect_11labs_last.log
fi

# =============================================================================
sect "Done"

echo "  ${GREEN}${BOLD}Voice is connected.${RESET}"
echo ""
echo "  Voice notes in are transcribed by ElevenLabs. Voice replies out use"
echo "  OpenClaw's own automatic text-to-speech - it fires only when the"
echo "  message being replied to was itself a voice note."
echo ""
echo "  Try it on WhatsApp now:"
echo "    - Send OpenClaw a voice note - it should reply with an actual"
echo "      spoken voice note, not text."
echo "    - A typed text message should still get a text-only reply."
echo ""
echo "  Don't like the default voice? List real options and switch any time:"
echo "    ${CYAN}sudo docker compose -f ${DEPLOY_DIR}/docker-compose.yml run --rm openclaw-cli capability tts voices --provider elevenlabs${RESET}"
echo "    ${CYAN}sudo docker compose -f ${DEPLOY_DIR}/docker-compose.yml run --rm -T openclaw-cli config set messages.tts.providers.elevenlabs.speakerVoiceId <id>${RESET}"
echo "    ${CYAN}sudo docker compose -f ${DEPLOY_DIR}/docker-compose.yml restart openclaw-gateway${RESET}"
echo ""
echo "  ${YELLOW}${BOLD}One thing to know:${RESET} 'sudo agentic update' will fail to pull"
echo "  openclaw-gateway from now on, because it points at a local image, not"
echo "  one on a registry. To get a newer OpenClaw version with voice still"
echo "  working, run this script again instead - it rebuilds from the latest"
echo "  base image automatically."
echo ""
info "Changed your mind about the voice ID or key? Run this script again -"
info "it safely overwrites what's here now."
echo ""
