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
| `connect_elevenlabs.sh` | Adds ElevenLabs voice replies + voice-note understanding to OpenClaw | **Actively broken, see §5 — this is the live investigation** |
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

- **`tts.provider` / `tts.auto` / `tts.providers.elevenlabs.*` do not exist as config keys.** Official doc pages (`docs.openclaw.ai/tools/tts`, `/providers/elevenlabs`) show a working-looking JSON5 example using this exact shape. It is wrong for this version. Attempting `config set tts.provider elevenlabs` fails with `Unrecognized key: "tts"`.
- There is no single "speak every reply" deterministic switch anywhere in the schema.

### 5.5 The real mechanism for ElevenLabs voice replies: the `sag` skill

`sag` is a **bundled, disabled-by-default skill** (not a config feature). Its own `SKILL.md` (read directly from `/app/skills/sag/SKILL.md` inside the container) is the authoritative source:

```
sag -v Clawd -o /tmp/voice-reply.mp3 "text"
# then include this exact line in the reply:
MEDIA:/tmp/voice-reply.mp3
```

Voice selection env vars: `ELEVENLABS_VOICE_ID` or `SAG_VOICE_ID`. Default voice is `Clawd` (`lj2rcrvANS3gaWWnczSX`) per the skill's own instructions.

**`sag` requires a real Linux binary that is not in the stock OpenClaw image.** Its own install hint (`Install sag (brew)`) is macOS-only. Real Linux install: prebuilt binaries at `https://github.com/steipete/sag/releases/download/v0.4.1/sag_0.4.1_linux_amd64.tar.gz`, requires the `libasound2` (ALSA) runtime library. Both are baked into a custom Docker image built by `connect_elevenlabs.sh` (see `Dockerfile.openclaw` it generates) — **anything installed via `docker exec` into a running container does not survive a restart**, which is why a real image rebuild was necessary, not a one-off `apt-get install`.

Known side effect: once `docker-compose.yml` points at a locally-built image tag instead of `ghcr.io/openclaw/openclaw`, `agentic update`'s pull step has nothing to pull from. Documented in the script's own output; the fix is re-running `connect_elevenlabs.sh`, which always rebuilds from the real upstream tag (tracked in a marker file `.openclaw-base-image` written on first run, specifically so re-runs don't try to build the image FROM itself).

### 5.6 The bundled `sag` skill's own trigger is too weak — confirmed via live logs

`sag`'s own `SKILL.md` only instructs the model to use it "when the user asks for a voice reply." **Confirmed via raw gateway log inspection that this never fires**, even for maximally explicit requests in the same conversation ("reply in voice, don't write text" — Arabic: `"رد طي بصوت، لا تكتب"`). Across four separate test messages, `sag` never once appeared in the logs.

Fix attempted: a second, custom skill (`voice-note-auto-reply`, installed via `openclaw skills install <path> --as <name> --force`, same pattern as `n8n-automation`) with unconditional, forceful wording ("you MUST", "not optional"). **This also did not fire.**

### 5.7 Root cause found: the model has no signal that a message was a voice note

Direct proof, from the raw JSON log file at `/tmp/openclaw/openclaw-<date>.log` inside the container (NOT `docker logs`, which is a filtered subset):

```json
"body":"[WhatsApp +9665... GMT+3] +9665...: <transcribed text>","mediaType":"audio/ogg; codecs=opus","mediaPath":"..."
```

**The `body` field — exactly what the model receives — is indistinguishable from a typed text message.** `mediaType`/`mediaPath` exist only in OpenClaw's own internal log entry, never reaching the model. No amount of skill wording can make the model detect something it structurally cannot see.

### 5.8 Fix attempted: inject a detectable marker via the transcription wrapper

Since `audio.transcription.command`'s own output becomes the `body` text verbatim, the wrapper script (`elevenlabs-transcribe.sh`, generated by `connect_elevenlabs.sh` into the persistent `openclaw-workspace/bin/` volume) was changed to prepend a literal marker:

```
[VOICE_NOTE_INPUT] <transcript text>
```

The `voice-note-auto-reply` skill was rewritten to check for this literal string instead of the unobservable "did this arrive as audio" fact.

**Verified in isolation**: piping a realistic ElevenLabs API response through the wrapper's actual `node -e` logic correctly produces `[VOICE_NOTE_INPUT] <text>`, UTF-8/Arabic intact.

**Verified on the real server: this marker STILL never appears in `body`, in any log entry, ever** (`grep -c "VOICE_NOTE_INPUT" ... ` returns `0`, and `grep -c "elevenlabs-transcribe"` — the wrapper's own filename — has not yet been checked, see §5.9). Meanwhile `config get audio.transcription.command` confirms the config correctly points at the wrapper.

### 5.9 CONFIRMED: `audio.transcription.command` never executes for this model

Both diagnostics came back conclusively:
```bash
sudo docker exec openclaw-gateway grep -c "elevenlabs-transcribe" /tmp/openclaw/openclaw-<date>.log
# -> 0, in every log file checked
sudo cat /opt/agentic-stack/openclaw-workspace/bin/elevenlabs-transcribe.sh
# -> file on disk is correct, not corrupted, matches what the script wrote
```

**Confirmed, not hypothesized: `gemini-2.5-flash` receives the raw audio file directly (native multimodal input) and OpenClaw never invokes `audio.transcription.command` in this pipeline.** That config path is very likely a fallback for non-multimodal models only. This means the §5.8 marker approach could never have worked — not a wording problem, not a marker-format problem, the wrapper that would inject the marker is simply never called.

### 5.9b Fix attempt #3: trust the model's own native audio awareness

If the model perceives audio as a distinct input modality (which native multimodal handling implies), it should inherently know whether a given turn included one — it doesn't need external help detecting that, only instructions on what to do about it. The `voice-note-auto-reply` skill was rewritten a third time around this premise: instead of checking for a marker or an abstract "did this arrive as audio" fact, it now asks the model to introspect on its own perception — *"did you yourself listen to and understand an audio file this turn?"*

**As of this document, this fix has been written and deployed but not yet confirmed working on a real test.** This is a genuinely different premise from attempts #1 (unobservable fact) and #2 (marker that never reaches the model) — it may still fail, but for a different reason if it does.

**If this also fails**, the conclusion is: no skill-based approach can work while native multimodal audio handling is active, because there is no reliable hook for a skill to condition on. The only remaining paths would be either (a) finding a way to force text-only transcription so the §5.8 marker approach becomes viable (unconfirmed whether such a toggle exists — would need schema investigation for something like a per-model or per-tool capability restriction), or (b) accepting that "voice note in, auto voice+text reply out" cannot be made deterministic on this platform as currently understood, and falling back to the bundled `sag` skill's judgment-based behavior (works for explicit requests like "reply in voice" typed as text, just not automatically for every voice note).

**Do not attempt a fourth skill-wording rewrite without new evidence.** Three different premises have now been tried. If #3 fails, the next step must be a new diagnostic (e.g., checking whether the model's own tool-call trace, via `openclaw audit`, shows anything indicating audio-modality awareness) — not another rephrasing.

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
