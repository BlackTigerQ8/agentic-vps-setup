# 🚀 CODED Agentic AI VPS Setup Wizard

An automated, interactive Bash script to provision, secure, and deploy a complete **Agentic AI Stack** (`n8n` workflow automation + `OpenClaw` LLM engine gateway) behind an `Nginx` reverse proxy with automatic `Let's Encrypt` SSL certificates on a fresh Ubuntu VPS.

Developed specifically for trainees of the **CODED Agentic AI Bootcamp**.

---

## 🛠️ The Stack

The script automates the installation, configuration, and orchestration of:
*   **Security:** System updates and `UFW` firewall configuration (restricting access to standard SSH and HTTP/HTTPS).
*   **Containerization:** Official `Docker Engine` & `Docker Compose` plugin setup.
*   **n8n Workflow Automation:** Containerized instance running on a custom bridge network, mapped locally to loopback, secured via basic auth, and using persisted volumes.
*   **OpenClaw Gateway:** Integrates with the trainee's preferred AI model provider (Google Gemini, OpenAI, or Anthropic Claude) dynamically.
*   **Nginx Reverse Proxy:** Routes public domain requests to containerized services, supports WebSocket updates, and implements a meta GET verification bypass for WhatsApp/Meta Webhooks.
*   **Certbot (Let's Encrypt):** Automates HTTPS encryption with redirects and sets up daily cron timers for renewal.
*   **WhatsApp Fix Script (`fix_openclaw.sh`):** A companion one-liner script that repairs the OpenClaw dashboard's WhatsApp QR code rendering by clearing the restart-loop breaker, restarting the gateway, and verifying channel health.

---

## 📋 Pre-flight Checklist (Required Before Running)

Before executing the setup wizard, ensure you have completed the following steps:

1.  **A Fresh VPS:** Standard Ubuntu 22.04 LTS or 24.04 LTS server (from providers like Hostinger).
2.  **A Domain Name:** A registered domain (e.g., `my-agent-platform.com`).
3.  **DNS A-Record Configuration:**
    *   In your domain registrar settings, add a new **A Record**.
    *   **Host/Name:** `n8n` (which creates the subdomain `n8n.yourdomain.com`).
    *   **Value/Content:** Your VPS Public IP address.
    *   *Note: Wait 5–15 minutes for propagation before running the script so SSL verification succeeds.*

---

## 🚀 Quick Start (One-Line Execution)

You can run the installer using either of these two methods on your VPS terminal:

### Option A: Direct Download & Run (Recommended - No Git Required)
This method uses `curl` (pre-installed on almost all VPS images) to pull the script directly from GitHub without needing to configure Git or clone the whole repository:

```bash
curl -fsSL https://raw.githubusercontent.com/BlackTigerQ8/agentic-vps-setup/main/vps_setup.sh -o vps_setup.sh && sudo bash vps_setup.sh
```

### Option B: Clone Repository (Requires Git)
If you want to clone the entire repository to view or modify files locally on your server:

```bash
# 1. Update packages and install git
sudo apt update && sudo apt install -y git

# 2. Clone the repository
git clone https://github.com/BlackTigerQ8/agentic-vps-setup.git

# 3. Navigate and execute
cd agentic-vps-setup
sudo bash vps_setup.sh
```

---

## 🩺 WhatsApp Dashboard Fix (Day 3+)

After the initial VPS setup, the OpenClaw dashboard may not render the WhatsApp QR code due to a restart-loop breaker that suppresses channel auto-start. A companion fix script resolves this automatically.

### One-Line Fix Command

Run this on your VPS terminal **before** attempting to pair WhatsApp:

```bash
curl -fsSL https://raw.githubusercontent.com/BlackTigerQ8/agentic-vps-setup/main/fix_openclaw.sh -o fix_openclaw.sh && sudo bash fix_openclaw.sh
```

### What It Does

| Phase | Action |
| :--- | :--- |
| **1. Auto-Detect** | Finds the running OpenClaw container (`openclaw` or `openclaw-gateway`) and the compose directory (`/opt/agentic-stack` or `/root/n8n-automation`). |
| **2. Doctor Fix** | Runs `openclaw doctor --fix` to clear the restart-loop breaker, validate config, and clean stale tokens. |
| **3. Clean Restart** | Restarts the container via `docker compose restart` so the gateway boots fresh with all channel providers enabled. |
| **4. Health Check** | Runs `openclaw channels status --probe` to verify the WhatsApp provider is active. |

After the script finishes, open the OpenClaw dashboard in your browser and click **Show QR** under Channels → WhatsApp.

> **Fallback:** If the dashboard QR still fails, pair via terminal:
> ```bash
> docker exec -it openclaw openclaw channels login --channel whatsapp
> ```

---

## 🧭 Interactive Wizard Parameters

The wizard will prompt you for the following inputs:
*   **VPS Public IP:** Used to double-check DNS settings via `dig` before issuing certificates.
*   **Root Domain:** Used to generate your subdomains.
*   **Certbot Email:** Required by Let's Encrypt to send SSL expiry alerts.
*   **n8n Credentials:** Admin username and password (enforced minimum of 8 characters) to secure your n8n workspace.
*   **AI Provider Selection:** Choose between Google Gemini, OpenAI, or Anthropic Claude.
*   **Model Selection:** Choose the exact engine deployment (e.g., `gemini-2.0-flash`, `gpt-4o-mini`, `claude-sonnet-4`, etc.).
*   **API Key:** Paste your secure token (e.g., Gemini API key, OpenAI key, or Anthropic key).

---

## 📂 Directories & Paths Created

Once finished, the stack components will be located at:
*   **Docker Workspace:** `/opt/agentic-stack/` (contains `docker-compose.yml` and persisted volume mappings).
*   **Nginx Site Config:** `/etc/nginx/sites-available/n8n` (symlinked to `/etc/nginx/sites-enabled/n8n`).
*   **System Logs:** `/tmp/setup_last_output.log` (useful for inspecting installation issues if a step fails).

---

## 🔧 Useful Administration Commands

### Docker Compose Management
Navigate to the stack directory:
```bash
cd /opt/agentic-stack
```

*   **View container status:** `docker compose ps`
*   **Inspect n8n container logs:** `docker compose logs -f n8n`
*   **Inspect OpenClaw logs:** `docker compose logs -f openclaw`
*   **Restart the stack:** `docker compose restart`
*   **Stop the stack:** `docker compose down`

### OpenClaw Channel Management
*   **Fix dashboard & WhatsApp QR:** `curl -fsSL https://raw.githubusercontent.com/BlackTigerQ8/agentic-vps-setup/main/fix_openclaw.sh -o fix_openclaw.sh && sudo bash fix_openclaw.sh`
*   **Pair WhatsApp via terminal:** `docker exec -it openclaw openclaw channels login --channel whatsapp`
*   **Check channel health:** `docker exec -it openclaw openclaw channels status --probe`
*   **Run diagnostics:** `docker exec -it openclaw openclaw doctor --fix`
*   **Logout WhatsApp session:** `docker exec -it openclaw openclaw channels logout`

### Web Server & SSL Management
*   **Test Nginx Configuration:** `nginx -t`
*   **Reload Nginx settings:** `systemctl reload nginx`
*   **Force SSL Renewal Check:** `certbot renew --dry-run`

---

## ✍️ Author & Maintenance

*   **Author:** Eng. Abdullah Alenezi
*   **Organization:** CODED Agentic AI Bootcamp
*   **Version:** 1.0.0
