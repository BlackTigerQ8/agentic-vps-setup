# 🚀 CODED Agentic AI VPS Setup Wizard

An automated, interactive Bash script to provision, secure, and deploy a complete **Agentic AI Stack** (`n8n` workflow automation + `OpenClaw` LLM engine gateway) behind an `Nginx` reverse proxy with automatic `Let's Encrypt` SSL certificates on a fresh Ubuntu VPS.

Developed specifically for trainees of the **CODED Agentic AI Bootcamp**.

---

## 🛠️ The Stack

The script automates the installation, configuration, and orchestration of:
*   **Security:** System updates and `UFW` firewall configuration (restricting access to standard SSH and HTTP/HTTPS).
*   **Containerization:** Official `Docker Engine` & `Docker Compose` plugin setup.
*   **n8n Workflow Automation:** Containerized instance running on a custom bridge network, mapped locally to loopback, secured via basic auth, and using persisted volumes.
*   **OpenClaw Gateway:** Integrates with the trainee's preferred AI model provider (Google Gemini or OpenAI) dynamically.
*   **Nginx Reverse Proxy:** Routes public domain requests to containerized services, supports WebSocket updates, and implements a meta GET verification bypass for WhatsApp/Meta Webhooks.
*   **Certbot (Let's Encrypt):** Automates HTTPS encryption with redirects and sets up daily cron timers for renewal.

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

## 🧭 Interactive Wizard Parameters

The wizard will prompt you for the following inputs:
*   **VPS Public IP:** Used to double-check DNS settings via `dig` before issuing certificates.
*   **Root Domain:** Used to generate your subdomains.
*   **Certbot Email:** Required by Let's Encrypt to send SSL expiry alerts.
*   **n8n Credentials:** Admin username and password (enforced minimum of 8 characters) to secure your n8n workspace.
*   **AI Provider Selection:** Choose between Google Gemini or OpenAI.
*   **Model Selection:** Choose the exact engine deployment (e.g., `gemini-2.0-flash`, `gpt-4o-mini`, etc.).
*   **API Key:** Paste your secure token (e.g., Gemini API key or OpenAI key).

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
*   **Restart the stack:** `docker compose restart`
*   **Stop the stack:** `docker compose down`

### Web Server & SSL Management
*   **Test Nginx Configuration:** `nginx -t`
*   **Reload Nginx settings:** `systemctl reload nginx`
*   **Force SSL Renewal Check:** `certbot renew --dry-run`

---

## ✍️ Author & Maintenance

*   **Author:** Eng. Abdullah Alenezi
*   **Organization:** CODED Agentic AI Bootcamp
*   **Version:** 1.0.0
