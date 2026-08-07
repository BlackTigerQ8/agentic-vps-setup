# CODED Agentic AI — VPS Setup Wizard

One command turns a blank Ubuntu VPS into a working agentic-AI workstation:

| Service | Address | What it is |
| :-- | :-- | :-- |
| **n8n** | `https://n8n.yourdomain.com` | Workflow automation |
| **OpenClaw** | `https://claw.yourdomain.com` | AI gateway + dashboard |

Both sit behind Nginx with a free Let's Encrypt certificate. Neither application port is exposed to the internet. **No SSH tunnel is needed for anything.**

Built for trainees of the CODED Agentic AI Bootcamp. Version **3.0.0**.

---

## Before you run it

You need three things. Do these in order.

**1. A VPS** — Ubuntu 22.04 or 24.04, minimum 4 GB RAM. A fresh server is best.

**2. A domain** — any registrar.

**3. Two DNS records.** This is the step people get wrong, so read it twice.

In your domain provider's DNS panel, add **two A records**:

| Type | Name | Value | TTL |
| :-- | :-- | :-- | :-- |
| A | `n8n` | your VPS IP address | lowest offered |
| A | `claw` | your VPS IP address | lowest offered |

Then check for **AAAA records** on those two names. If your provider created any, **delete them**. An AAAA record on a server without IPv6 makes the SSL certificate fail every time, and the error message does not tell you that.

DNS takes 1–30 minutes to spread. The setup script waits for it, so you can start right away.

---

## Run it

Connect to your server:

```bash
ssh root@YOUR_VPS_IP
```

Then run:

```bash
curl -fsSL https://raw.githubusercontent.com/BlackTigerQ8/agentic-vps-setup/main/vps_setup.sh -o vps_setup.sh && sudo bash vps_setup.sh
```

It asks for your domain, email, timezone, AI provider, API key, and **a password for your OpenClaw dashboard** — pick one you'll remember, 12 characters minimum. Everything else is automatic. Expect 5–12 minutes, mostly downloading.

**The script is safe to run again.** If something fails, fix the cause and re-run it — it skips whatever is already done and never issues a duplicate certificate.

---

## After it finishes

### n8n

Open `https://n8n.yourdomain.com` and create your account on the first screen. n8n manages its own users; there is no separate server password.

### OpenClaw dashboard

Open `https://claw.yourdomain.com` and enter **the dashboard password you chose during setup**. OpenClaw's screen calls it a *gateway token* — it's the same thing.

Forgotten it?

```bash
sudo agentic token
```

Or skip typing entirely — this prints a one-time link that logs you straight in:

```bash
sudo agentic open
```

If the browser says **"pairing required"**, approve the device:

```bash
sudo agentic approve
```

### WhatsApp

```bash
sudo agentic whatsapp
```

A QR code appears in your terminal. On your phone: **WhatsApp → Settings → Linked devices → Link a device**, then scan.

---

## The `agentic` command

The setup script installs a helper so nobody has to remember Docker commands.

```bash
sudo agentic help
```

| Command | What it does |
| :-- | :-- |
| `agentic status` | Full health check — containers, SSL, DNS, memory |
| `agentic open` | One-click OpenClaw dashboard login link |
| `agentic token` | Show your OpenClaw dashboard password |
| `agentic safebrowsing` | Steps to clear Chrome's red "Deceptive site" page |
| `agentic urls` | Print your two links |
| `agentic logs n8n` | Follow n8n logs live |
| `agentic logs claw` | Follow OpenClaw logs live |
| `agentic restart` | Restart everything |
| `agentic whatsapp` | Pair WhatsApp |
| `agentic approve` | Approve a device waiting to log in |
| `agentic model` | List or change the AI model |
| `agentic doctor` | OpenClaw self-repair |
| `agentic ssl` | Issue or renew the certificate |
| `agentic dns` | Check that DNS points here |
| `agentic update` | Pull the newest images |
| `agentic backup` | Save n8n + OpenClaw data to `/root/backups` |
| `agentic creds` | Show your saved credentials |

---

## Something is wrong

Run the health report and send the output to your instructor. It changes nothing:

```bash
curl -fsSL https://raw.githubusercontent.com/BlackTigerQ8/agentic-vps-setup/main/diagnose.sh -o diagnose.sh && sudo bash diagnose.sh
```

Every failing line comes with the command that fixes it.

### Common problems

**"Your connection is not private" / certificate error**
The certificate did not cover the address you opened. Run `sudo agentic status` — it prints exactly which names the certificate covers. Then `sudo agentic ssl`.

**"Deceptive site ahead" / "Dangerous site" (a red Google page)**

This is **not** an SSL problem — your certificate is valid. It's a Google Safe Browsing false positive that self-hosted n8n gets hit with periodically.

*To keep working right now:* click **Details** on the red page, then **visit this unsafe site**.

*To clear it properly:*

1. Open [Google Search Console](https://search.google.com/search-console)
2. Add a **Domain** property for `yourdomain.com` (not a URL-prefix property — a Domain property covers both subdomains at once). Verify it with the TXT record it gives you.
3. Go to **Security & Manual Actions → Security Issues**
4. Click **Request Review**. Describe it as a private automation tool for your own use, not a public website.

Reviews usually clear in 1–3 days. Check the current verdict any time at [Google's Transparency Report](https://transparencyreport.google.com/safe-browsing/search).

Run `sudo agentic safebrowsing` on the server for these steps.

The setup already does what it can to avoid a repeat flag: `noindex` headers and a blocking `robots.txt` on both sites, HTTPS enforced, and requests to the bare IP refused instead of being served the n8n login page.

> **Instructors:** have trainees add the Search Console TXT record at the same time as the two A records, the day before class. Then a review request is a single click instead of a ten-minute detour.

**The SSL certificate will not issue**
Nearly always DNS. Run `sudo agentic dns`. Look for a leftover **AAAA record** — delete it and retry.

**Everything is slow**
Check `sudo agentic status`. If swap shows 0 MB, re-run the setup script; it adds a swap file, which is the usual fix on a 4 GB VPS.

**The OpenClaw dashboard will not load**
It is on port **18789**, not 8080. You do not need an SSH tunnel — use `https://claw.yourdomain.com`.

---

## Where things live

| Path | Contents |
| :-- | :-- |
| `/opt/agentic-stack/docker-compose.yml` | The stack definition |
| `/opt/agentic-stack/stack.env` | Secrets — mode 600, root only |
| `/opt/agentic-stack/openclaw/openclaw.json` | OpenClaw gateway config |
| `/etc/nginx/sites-available/n8n`, `.../claw` | Reverse proxy configs |
| `/root/AGENTIC-CREDENTIALS.txt` | Your links and tokens |
| `/var/log/agentic-setup.log` | Full setup transcript |
| `/etc/agentic-stack.conf` | Saved answers, reused on re-runs |

---

## Already running the old setup?

Re-run the same one-liner. It upgrades in place — you do not need a fresh server.

**First, add the missing DNS record:**

| Type | Name | Value |
| :-- | :-- | :-- |
| A | `claw` | your VPS IP address |

Then re-run the installer. It detects the old install and migrates it:

```bash
curl -fsSL https://raw.githubusercontent.com/BlackTigerQ8/agentic-vps-setup/main/vps_setup.sh -o vps_setup.sh && sudo bash vps_setup.sh
```

**What you keep:** your n8n workflows, saved credentials and n8n login. The installer finds your existing n8n data, reads its encryption key and reuses it, so nothing is re-encrypted or lost.

**What changes:** the old OpenClaw container (the broken one on port 8080) is removed and replaced. OpenClaw had never successfully saved any state, so there is nothing to migrate there — you will set it up fresh, which takes about a minute.

**You will be asked again** for your domain, email, timezone, AI provider and API key, plus a new dashboard password. The old install saved none of these anywhere the script could read.

> Your API key was previously stored in a world-readable file. If that bothers you, rotate it at your provider before re-running and enter the new one.

---

## Instructor notes

**Pin image versions before class** so every trainee runs an identical build:

```bash
AGENTIC_N8N_TAG=1.130.0 AGENTIC_OPENCLAW_TAG=2026.7.1 sudo -E bash vps_setup.sh
```

Run the script yourself first, note the versions it pulled with `sudo agentic status`, and give trainees that command. This removes a whole class of "it worked for her but not for me" problems.

**What changed in 3.0.0**

- OpenClaw moved to its own HTTPS subdomain — the SSH tunnel is gone
- Fixed the OpenClaw port (18789, not 8080) and container name
- The trainee chooses their own OpenClaw dashboard password during setup, so dashboard login works and they remember it
- OpenClaw config and credentials persist across restarts (the old volume path was wrong, so nothing was saved)
- Dropped the `N8N_BASIC_AUTH_*` variables — n8n removed them in v1.0, so they had no effect
- Certbot runs in `--webroot` mode and never rewrites the Nginx config
- Requests to the bare IP are refused instead of serving the n8n login page
- Adds swap, container memory ceilings and log rotation
- Waits for DNS instead of failing; detects the AAAA-record trap
- Ships the `agentic` helper and `diagnose.sh`

**3.0.1** — upgrading in place from the old setup now preserves n8n's encryption key instead of injecting a new one (which stopped n8n from starting), and removes the dead port-8080 OpenClaw container instead of leaving it running as an orphan.

---

**Author:** Eng. Abdullah Alenezi — CODED Agentic AI Bootcamp
