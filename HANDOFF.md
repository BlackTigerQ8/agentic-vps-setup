# CODED Agentic AI Bootcamp — VPS Setup: Complete Technical Reference

This document exists so a fresh AI assistant (or a human) can pick up this project cold, on any device, without re-deriving facts that took real effort to establish — several of them by contradicting official documentation. Read this before touching anything in the repo or the VPS.

**Repo:** `github.com/BlackTigerQ8/agentic-vps-setup` (branch: `main`)
**Owner:** Eng. Abdullah Alenezi — instructor, CODED Agentic AI Bootcamp
**Purpose:** A one-command VPS setup that gives non-technical bootcamp trainees a working n8n + OpenClaw stack, for free, on their own server.

---

## 1. What this project actually is

Trainees run one script on a fresh Ubuntu VPS (typically Hostinger). It installs Docker, n8n, and OpenClaw (an AI agent gateway with WhatsApp support), puts both behind Nginx with free Let's Encrypt SSL, and installs a helper command (`agentic`) so trainees never need to remember Docker syntax. The goal stated repeatedly by the instructor: **as simple as possible for non-technical people, minimal terminal use, zero SSH tunnels, zero manual config editing.**

Two services, one VPS:
- **n8n** at `https://n8n.<domain>` — workflow automation, the trainees' main building tool
- **OpenClaw** at `https://claw.<domain>` — an AI agent gateway that runs the class WhatsApp number, can call n8n workflows, and (as of the work described in section 5) can understand and reply with voice notes

---

## 2. Architecture

- **VPS**: Ubuntu 22.04/24.04, provisioned by the trainee (usually via Hostinger)
- **Docker Compose stack** at `/opt/agentic-stack/`, services: `n8n`, `openclaw-gateway`, `openclaw-cli` (profile-gated, used for one-off CLI commands via `docker compose run --rm`)
- **Nginx** reverse-proxies both hostnames, HTTPS via Certbot/Let's Encrypt, HTTP→HTTPS redirect, `noindex` headers, bare-IP requests refused (444)
- **Secrets** live in `/opt/agentic-stack/stack.env` (mode 600), loaded into containers via `env_file`. This is the ONE place all API keys/tokens live — never hardcode secrets into `openclaw.json` when an env var + SecretRef is possible.
- **`/etc/agentic-stack.conf`**: saved answers from the setup wizard (domain, email, timezone, `DEPLOY_DIR`), sourced by every helper script
- **`agentic`**: a CLI helper installed to `/usr/local/bin/agentic` by `vps_setup.sh`, wraps Docker Compose so trainees type `agentic status` instead of raw `docker compose` commands

---

## 3. Repository structure and script inventory

| Script | Purpose | Status |
| :-- | :-- | :-- |
| `vps_setup.sh` | The core installer. Provisions everything from a bare VPS. | **DO NOT MODIFY without explicit permission** — see §4 |
| `diagnose.sh` | Read-only health check, changes nothing | Stable |
| `reset.sh` | Tears down the stack for a clean re-run (keeps SSL cert + images by default to avoid Let's Encrypt rate limits) | Stable |
| `connect_n8n.sh` | Wires a WhatsApp message to an n8n workflow via an OpenClaw **skill** (agent-judgment based, not a hard trigger) | Stable, working |
| `connect_elevenlabs.sh` | Adds ElevenLabs voice replies + voice-note understanding to OpenClaw | Stable, working (v3.0.0) — see §5 |
| `fix_openclaw.sh` | Deprecated shim, redirects users to `agentic` commands | Legacy, keep for old links |

All `connect_*.sh` scripts share a design pattern, established deliberately after an earlier mistake (see §4): standalone, run via `curl | bash`, idempotent (safe to re-run with new values), never touch `vps_setup.sh` or the `agentic` helper, read `/etc/agentic-stack.conf` + `/opt/agentic-stack/stack.env` directly.

---

## 4. Critical rule: `vps_setup.sh` is off-limits

Early in this project, new features (n8n webhook trigger, then ElevenLabs voice) were initially built by editing `vps_setup.sh` directly. The instructor explicitly stopped this:

> "stash all the changes you made on the vps_setup.sh script. it is working perfectly and I do not want to mess it up. Create a new script... instead of adding it to the vps_setup.sh"

**Rule going forward: new capabilities are standalone `connect_*.sh` scripts, never edits to `vps_setup.sh`.** This is not just caution — it's structurally better: standalone scripts work immediately on servers already built (no re-running setup), and iterating on them can't put the proven, working installer at risk.

If you're an AI assistant reading this and someone asks you to "add a feature," default to a new standalone script unless told otherwise.

---

## 5. OpenClaw: verified facts (hard-won — do not re-derive these)

OpenClaw's own documentation site (`docs.openclaw.ai`) was found to be **wrong or outdated in multiple specific, verified instances** during this project. The reliable method that emerged: verify everything against the actual running server, never trust a doc page alone. Below is what's been confirmed against a real OpenClaw 2026.7.1 instance.

### 5.1 CLI command surface (confirmed via `openclaw --help` on the real server)

Top-level commands include: `agent`, `agents`, `audit`, `channels`, `config`, `devices`, `doctor`, `gateway`, `hooks`, `mcp`, `models`, `plugins`, `sessions`, `skills`, `transcripts`, `webhooks`, and more.

**Commands that do NOT exist, despite being plausible and matching patterns elsewhere in the CLI:**
- `openclaw skills enable <name>` / `openclaw skills disable <name>` — **does not exist**. The real `skills` subcommands are: `check, curator, info, install, list, search, update, verify, workshop`. This was a real bug shipped once in `connect_elevenlabs.sh` — the script "succeeded" (exit 0 was never actually reached because the command doesn't exist and would error) but never enabled anything.
- `openclaw webhooks` — real, but **only handles Gmail Pub/Sub**. Not usable for generic outbound webhooks.
- `openclaw hooks` — real, but fires on **lifecycle events** (`/new`, `/reset`, gateway startup), **not on incoming messages**. Not usable for "trigger on every WhatsApp message."

### 5.2 How to actually enable a bundled-but-disabled skill

There is no CLI command for this. Skills are enabled via config, same pattern as `hooks.internal.entries.<name>.enabled`:

```bash
openclaw config set skills.entries.<skill-name>.enabled true
```

Confirmed via live schema search:
```bash
openclaw config schema | jq -c 'paths(type=="object") as $p | select(getpath($p) | has("command")?) | $p'
```
(This general technique — walking the whole schema with `jq` for any object containing a specific key — is the single most useful diagnostic discovered in this project. Use it whenever a config key's exact location is uncertain, rather than guessing.)

### 5.3 Config schema — verified real paths

| Path | Purpose | Notes |
| :-- | :-- | :-- |
| `skills.entries.<name>.enabled` | Enable a bundled or workspace skill | boolean |
| `tools.media.audio.enabled` | **Permission** to understand incoming audio | Does NOT configure *how* — see next row |
| `audio.transcription.command` | The **actual mechanism** for STT — an array, first element must be an executable path | `"required": ["command"]` — if unset, audio understanding is enabled but non-functional |
| `audio.transcription.timeoutSeconds` | Timeout for the above | integer |
| `tools.media.audio.echoTranscript` | Echo the transcript back to the chat before the agent replies | boolean, default false |
| `channels.discord.voice.realtime.speakerVoiceId` / `talk.realtime.speakerVoiceId` | Voice ID for **Discord voice channels** and **Talk realtime mode** | NOT related to WhatsApp TTS |

### 5.4 Config schema — confirmed WRONG assumptions (do not repeat these)

- **`tts.provider` / `tts.auto` / `tts.providers.elevenlabs.*` do not exist as config keys.** Official doc pages (`docs.openclaw.ai/tools/tts`, `/providers/elevenlabs`) show a working-looking JSON5 example using this exact shape. It is wrong for this version. Attempting `config set tts.provider elevenlabs` fails with `Unrecognized key: "tts"`. **The real namespace is `messages.tts.*`** — see §5.5. Both facts are simultaneously true because they're different paths; don't let a failed `tts.*` attempt rule out `messages.tts.*`.
- **There is no way to load custom/local plugin code.** `openclaw config schema | jq '.properties.plugins'` shows `plugins.entries` is a **closed catalog of ~70 pre-bundled plugin IDs** (`elevenlabs`, `whatsapp`, `google`, `codex`, `talk-voice`, `tts-local-cli`, etc.), each with a fixed `enabled` / `hooks` (policy toggles) / `subagent` / `llm` / `config` shape, `additionalProperties: false` throughout — no `source`, `path`, or any field for pointing at your own plugin file. `plugins.load.paths` also does not exist (`plugins` itself is `additionalProperties: false`). A typed-hooks Plugin SDK (`before_prompt_build`, `before_model_resolve`, etc.) is real and documented, but with no supported plugin-loading mechanism for non-bundled code, it's unusable for anything you'd write yourself on this deployed version. Don't attempt to write a custom plugin again without first re-confirming this hasn't changed in a newer OpenClaw release.
- **`messages.tts.providers.<id>.apiKey` as a secret-reference object requires a *registered* secret provider — using one that isn't registered doesn't just fail to apply, it crash-loops the gateway.** The schema accepts `apiKey: string | {"source":"env"|"file"|"exec","provider":"<id>","id":"<VAR>"}`. It's tempting to write `{"source":"env","provider":"elevenlabs","id":"ELEVENLABS_API_KEY"}`, but `provider` here means "a registered secret provider named elevenlabs," which doesn't exist by default — not "the elevenlabs plugin." Setting this causes every gateway restart to fail immediately with `SecretProviderResolutionError: Secret provider "elevenlabs" is not configured`, and after a few failed restarts a crash-loop breaker trips and suppresses channel auto-start even once the config is fixed (see §5.8 for full recovery). **Use a plain string for `apiKey` instead** — it's valid per the schema and is what actually works.

### 5.5 RESOLVED: automatic voice replies use `messages.tts`, a native gateway mechanism — not a skill

Confirmed working end-to-end (verified by both a live test on this project's own server and an independent reference build). This supersedes every skill-based attempt described below (§5.7 has the condensed history, kept only so nobody retries it).

`messages.tts.auto` is a **gateway-level switch, judged by the gateway itself from the real inbound message type — not something the model decides or has to notice.** Values: `off` | `always` | `inbound` | `tagged`. `inbound` = voice-in triggers voice-out; typed messages still get typed replies.

**The full set of fields that must ALL be set together, or TTS silently does nothing:**

```bash
openclaw config set messages.tts.enabled true
openclaw config set messages.tts.auto inbound
openclaw config set messages.tts.provider elevenlabs
openclaw config set messages.tts.providers.elevenlabs.apiKey "<plain-string-key>"
openclaw config set messages.tts.providers.elevenlabs.model eleven_multilingual_v2
openclaw config set messages.tts.providers.elevenlabs.speakerVoiceId "<voice-id>"
```

**The critical, easy-to-miss gotcha:** a provider with only `apiKey` set (no `speakerVoiceId`, no `model`) reports `"configured": true` in `capability tts status` and passes `config validate` — but produces **zero observable effect**. Not an error, not a fallback, not a log line of any kind — the turn just falls straight through to a normal text reply as if TTS were never configured at all. This is exactly what made the bug hard to find: every other diagnostic (`config get`, `config validate`, `capability tts status`) looked correct. The field name is **`speakerVoiceId`**, not `voiceId` or `voice`.

**`ffmpeg` must be baked into the image.** The stock OpenClaw image doesn't have it. ElevenLabs returns MP3; WhatsApp voice notes need OGG/Opus. OpenClaw transcodes with `ffmpeg` on the way out — without it, synthesis can succeed but no playable voice note ever arrives. `connect_elevenlabs.sh` bakes this into a custom `Dockerfile.openclaw`, the same pattern used for the now-abandoned `sag` binary below (custom image, because anything installed via `docker exec` into a running container doesn't survive a restart).

Known side effect: once `docker-compose.yml` points at a locally-built image tag instead of `ghcr.io/openclaw/openclaw`, `agentic update`'s pull step has nothing to pull from. Documented in the script's own output; the fix is re-running `connect_elevenlabs.sh`, which always rebuilds from the real upstream tag (tracked in a marker file `.openclaw-base-image` written on first run, specifically so re-runs don't try to build the image FROM itself).

### 5.6 Verification commands that actually confirm TTS works — use these, not log-grepping

These were the single biggest process improvement from finally solving this: they tell you the real state in one call, discovered from a reference build's own troubleshooting notes.

```bash
# Enabled? auto mode? provider? is each provider's config actually present?
openclaw capability tts status

# Real synthesis test — look for the target provider showing success, not a fallback
openclaw capability tts convert --text "voice note test" --channel whatsapp --output /tmp/t --json

# List real voice IDs available on the account (don't guess one)
openclaw capability tts voices --provider elevenlabs

# ffmpeg present in the running container
docker exec openclaw-gateway which ffmpeg
```

### 5.7 Dead-end history — kept only so these aren't retried

Three sequential skill-based approaches were tried before the native mechanism (§5.5) was found, all confirmed failed via real evidence, not assumption.

**The bundled `sag` skill's own trigger is too weak — confirmed via live logs**

`sag`'s own `SKILL.md` only instructs the model to use it "when the user asks for a voice reply." **Confirmed via raw gateway log inspection that this never fires**, even for maximally explicit requests in the same conversation ("reply in voice, don't write text" — Arabic: `"رد طي بصوت، لا تكتب"`). Across four separate test messages, `sag` never once appeared in the logs.

Fix attempted: a second, custom skill (`voice-note-auto-reply`, installed via `openclaw skills install <path> --as <name> --force`, same pattern as `n8n-automation`) with unconditional, forceful wording ("you MUST", "not optional"). **This also did not fire.**

**Why it failed twice more:** the raw JSON log file at `/tmp/openclaw/openclaw-<date>.log` inside the container (NOT `docker logs`, which is a filtered subset) showed the model's `body` field is indistinguishable from typed text — `mediaType`/`mediaPath` exist only in OpenClaw's own internal log entry, never reaching the model. A second attempt tried injecting a `[VOICE_NOTE_INPUT]` marker via the STT transcription wrapper so a skill could check for it textually — also never fired, because `audio.transcription.command` turned out to never execute at all for this natively multimodal model (`gemini-2.5-flash` receives the raw audio file directly; confirmed by the wrapper's own filename appearing zero times in the raw logs). A third attempt asked the model to introspect on its own audio perception directly, no marker needed — also never fired.

**Root cause for all three, in hindsight:** OpenClaw's skill routing is relevance/topic-judged by the model. A trigger condition that's a structural fact about the *current turn's modality* — not a topic — is not the kind of thing skill routing reliably surfaces, regardless of wording. This is why the fix that actually worked lives at the gateway level (§5.5), not in a skill.

A parallel investigation into using OpenClaw's typed-hooks Plugin SDK (`before_prompt_build` et al.) to inject a deterministic signal was abandoned once §5.4 established there's no supported way to load custom plugin code on this OpenClaw version at all.

### 5.8 Recovering from a bad `openclaw.json` / gateway crash-loop

This happened for real during this project — an invalid `apiKey` secret-reference (§5.4) put the gateway into a full crash-loop and took WhatsApp offline. The recovery procedure, in order:

1. **`docker compose stop openclaw-gateway`** — holds it down cleanly. A normal `unless-stopped`-style restart policy respects an explicit stop.
   - **Do NOT try to fix it via `docker compose run --rm openclaw-cli config set ...` while the gateway container is mid-restart-loop.** That command depends on attaching to the gateway container's network namespace and will fail silently with `cannot join network namespace of container: ... is restarting` — the fix never actually applies, and it's easy to not notice this and think the fix didn't work.
2. Find the host-mounted config file: `docker inspect openclaw-gateway --format '{{json .Mounts}}' | jq -r '.[] | "\(.Source) -> \(.Destination)"'` → `openclaw.json` lives on the host at `<DEPLOY_DIR>/openclaw/openclaw.json`, mounted to `/home/node/.openclaw` in the container.
3. Edit it directly on the host with `jq`. Back it up first, and preserve the original owner (`stat -c '%u:%g' "$CONF"` before editing, `chown` back after) so the container (running as non-root `node`) can still read it:
   ```bash
   CONF=/opt/agentic-stack/openclaw/openclaw.json
   cp "$CONF" "${CONF}.bak-$(date +%s)"
   OWNER=$(stat -c '%u:%g' "$CONF")
   jq '.messages.tts.providers.elevenlabs.apiKey = "<plain-key>"' "$CONF" > "${CONF}.tmp" && mv "${CONF}.tmp" "$CONF"
   chown "$OWNER" "$CONF"
   ```
4. `docker compose up -d openclaw-gateway`.
5. **Even after the config is fixed, a restart-loop breaker may still suppress channel auto-start for a boot or two** — log line: `restart-loop breaker tripped: N unclean boot(s) within 300000ms; suppressing channel/provider account auto-start`, followed by `[whatsapp] channel autostart suppressed by crash-loop breaker`. This is a 5-minute rolling window counted from the last crash. There is **no CLI command to force it immediately** — `openclaw channels start <name>` does not exist (the log's own suggestion, "Use channels.start to override," refers to an internal RPC method, not a CLI subcommand; `openclaw channels --help` confirms the real subcommands are `add, capabilities, list, login, logout, logs, remove, resolve, status`). Once genuinely 5 minutes have passed since the last bad boot, one more `docker compose restart openclaw-gateway` clears it — log line: `restart-loop breaker recovered; channel auto-start restored`.

### 5.8b This sandbox cannot SSH into the VPS

Confirmed by direct test (TCP connection to the VPS's port 22 times out — not an auth failure, no outbound route). Every fix in this project has to be applied via commands the user copy-pastes and runs themselves, then pastes the output back — there is no way for an AI assistant working from a typical sandboxed dev environment to log into the server directly, even given credentials.

### 5.10 Other confirmed OpenClaw facts, useful for future work

- **ElevenLabs free tier includes Speech-to-Text**, shared credit pool with TTS (confirmed via ElevenLabs' own pricing pages, not assumed) — so reusing the same `ELEVENLABS_API_KEY` for both directions costs trainees nothing extra, regardless of plan.
- **ElevenLabs STT API**: `POST https://api.elevenlabs.io/v1/speech-to-text`, header `xi-api-key: <key>`, multipart fields `file` + `model_id=scribe_v2`, transcript in response JSON's `.text` field.
- `curl` and `node` are both guaranteed present in the OpenClaw container already (confirmed via `openai-whisper-api` skill's own requirements check showing both ✓) — useful for any future wrapper scripts, no image rebuild needed unless a real binary (like `sag`) is required.
- `openclaw config set <path> <value>` accepts dot-path notation; JSON/JSON5 values need `--strict-json` for reliable array/object parsing; a `--ref-provider default --ref-source env --ref-id <VAR>` builder exists for referencing secrets from environment variables instead of writing them in plaintext to `openclaw.json`.
- `openclaw config validate` checks the whole config against the schema — always run after a batch of `config set` calls, before restarting.
- `openclaw transcripts list` returned "No transcripts found" even with active sessions present — this storage is not populated by default, do not rely on it for debugging; use the raw log file instead (§5.7).
- The gateway must be **restarted** (`docker compose restart openclaw-gateway`) for `config set` changes to take effect on the running agent — config hot-reload was observed to detect changes (`[reload] config change detected`) but the actual behavior only updates after a full restart in practice.

---

## 6. Debugging methodology that has actually worked here

1. **Never trust a doc page alone.** Multiple official OpenClaw doc pages were confirmed wrong (§5.4). Always cross-check against the live server: `openclaw config schema`, `openclaw skills info <name>`, or raw log files.
2. **When a config key's location is uncertain, search the whole schema with `jq`** rather than guessing a path:
   ```bash
   openclaw config schema | jq -c 'paths(type=="object") as $p | select(getpath($p) | has("<key>")?) | $p'
   ```
3. **`docker logs` is a filtered subset.** The real detail lives in the JSON log file at `/tmp/openclaw/openclaw-<date>.log` inside the container — this is what revealed the exact `body` field content that broke the voice-note investigation open.
4. **Test scripts against a mocked harness before handing them to the instructor.** Every script in this repo has been validated by: syntax-checking (`bash -n`), stubbing `docker`/`dc`/`oc`/`oc_q` calls to a log file, and running the full interactive flow with piped input to inspect exactly what commands would be issued and what files would be generated — catching real bugs (e.g., a JSON escaping mistake, a variable-ordering bug) before they reached a live server.
5. **When a fix doesn't work, get a new piece of hard evidence before proposing another fix.** This project's history includes several rounds where a plausible-sounding wording change was tried and failed; what actually made progress each time was pulling real logs and finding an exact, quotable fact (a log line, a schema path, a config value) rather than reasoning further in the abstract.
6. **Idempotency matters more than it seems.** Trainees re-run scripts. Every `connect_*.sh` script needs to be safe to run twice with different inputs — verified explicitly for each one (e.g., `connect_elevenlabs.sh`'s base-image marker file, `connect_n8n.sh`'s `--force` skill reinstall).

---

## 7. Quick reference: commands used constantly in this project

```bash
# Health / status
sudo agentic status
sudo agentic logs claw
sudo docker exec openclaw-gateway openclaw skills list
sudo docker exec openclaw-gateway openclaw skills info <name>
sudo docker exec openclaw-gateway openclaw config get <path>
sudo docker exec openclaw-gateway openclaw config schema | jq ...
sudo docker exec openclaw-gateway openclaw config validate

# Raw logs (more detail than `docker logs`)
sudo docker exec openclaw-gateway grep -i "<term>" /tmp/openclaw/openclaw-$(date +%F).log | tail -100

# Sessions
sudo docker exec openclaw-gateway openclaw sessions list

# TTS — real state, not just config values (§5.6)
sudo docker exec openclaw-gateway openclaw capability tts status
sudo docker exec openclaw-gateway openclaw capability tts convert --text "test" --channel whatsapp --output /tmp/t --json
sudo docker exec openclaw-gateway openclaw capability tts voices --provider elevenlabs

# Restart after config changes (required, not optional)
sudo docker compose -f /opt/agentic-stack/docker-compose.yml restart openclaw-gateway
```

---

## 8. What NOT to do

- Do not edit `vps_setup.sh` for new features (§4)
- Do not assume an OpenClaw doc page is current — verify against the live schema/CLI first (§5)
- Do not write skill wording to detect something the model cannot observe — check what the model actually receives (via raw logs) before assuming a wording problem (§5.7)
- Do not hand-edit `docker-compose.yml`'s image without a marker file tracking the real upstream tag, or re-runs will build FROM the local tag and break (§5.5)
- Do not use `docker exec` to install anything meant to be permanent — it will not survive a container restart; either bake it into a custom image or place it in a host-mounted volume like `openclaw-workspace/`
- Do not set `messages.tts.provider` without also setting that provider's `model` and `speakerVoiceId` — it will report as configured and pass validation while silently never synthesizing anything (§5.5)
- Do not use a `{"source":"env",...}` secret-reference object for `apiKey` unless a matching secret provider is actually registered — it crash-loops the gateway on every restart instead of just failing to apply (§5.4, §5.8)
- Do not try to fix config via `docker compose run openclaw-cli config set ...` while the gateway container is restarting/crash-looping — it fails silently because it can't attach to the gateway's network namespace; stop the container and edit the host-mounted JSON file directly instead (§5.8)
- Do not offer to SSH into the user's VPS directly — this sandbox has no outbound network route to it (§5.8b)
