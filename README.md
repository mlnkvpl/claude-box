# Claude-Box: Sandboxed Claude Code + Browser Automation

A secure, isolated Docker container setup for running Anthropic's official Claude Code CLI (`@anthropic-ai/claude-code`) paired with live host browser automation via the Chrome DevTools Model Context Protocol (`chrome-devtools-mcp`).

It isolates the agent strictly inside your `~/workdir` projects, shields your host home directory (SSH keys, shell dotfiles, personal credentials), prevents root file-permission issues, and bridges safely to your host's Google Chrome instance for autonomous web tasks.

---

## Architecture & Security Boundary

* **Host Filesystem Isolation:** The agent only accesses `~/workdir` (mounted to `/workspace`). It cannot read host paths such as `~/.ssh`, `~/.aws`, or `~/.bashrc`.
* **Clean User Permissions:** Runs mapped to your host's non-root `UID:GID`, ensuring files created or modified by the agent remain editable on your host.
* **Persistent Configuration:** Claude Code splits its persistent state across two locations, both of which must be mounted:
  * `~/claude/.config/claude/` → `/home/node/.claude` — session transcripts, project memory.
  * `~/claude/.config/claude.json` → `/home/node/.claude.json` — global settings, onboarding state, auth. This is a **file**, not a folder; mounting only the directory leaves this absent and the onboarding wizard re-runs (and resets preferences) on every container start.
* **Safe Host Browser Bridge:** Controls your host Chrome instance over the Chrome DevTools Protocol (CDP). A lightweight `socat` bridge forwards container traffic (`172.17.0.1:9223`) to Chrome's local loopback listener (`127.0.0.1:9222`), bypassing Chrome's DNS-rebinding security checks while keeping the container sandboxed.

---

## Directory Structure

```text
~/claude/
├── .config/
│   ├── claude/           # session transcripts, project memory (mounted to /home/node/.claude)
│   └── claude.json       # global settings, auth state (mounted to /home/node/.claude.json)
├── .mcp.json             # project-scoped MCP server config (chrome-devtools-mcp)
├── .env                  # auth credentials + CLI shortcut name
├── cli.sh                # Shell installer, Chrome launcher, builder, and runner
├── docker-compose.yml    # Bridge network, user mapping, volume mounts, extra_hosts
├── Dockerfile             # Node 20-slim + Claude Code + chrome-devtools-mcp
└── README.md             # Documentation
```

---

## Setup & Reproduction Steps

### 1. Prerequisites

* Docker and Docker Compose v2 (`docker compose`) installed on Ubuntu / WSL2.
* `socat` and Google Chrome installed on your host system:
```bash
sudo apt update && sudo apt install -y socat google-chrome-stable
```

* Either an Anthropic Console API key **or** a Claude Pro/Max/Team/Enterprise subscription — see [Authentication](#authentication--pick-one) below.
* Workspace directory:
```bash
mkdir -p ~/workdir
```

---
### 2. File Configurations

Create the setup directory:

```bash
mkdir -p ~/claude/.config/claude
cd ~/claude
chmod 700 .config
echo '{}' > .config/claude.json
```

#### `Dockerfile`

```dockerfile
FROM node:20-slim

# Install system utilities commonly needed by agent tools
RUN apt-get update && apt-get install -y git curl ca-certificates procps && rm -rf /var/lib/apt/lists/*

# Install Claude Code and the official Chrome DevTools MCP server globally
RUN npm install -g @anthropic-ai/claude-code chrome-devtools-mcp

WORKDIR /workspace

ENTRYPOINT ["claude"]
```

#### `docker-compose.yml`

```yaml
services:
  claude:
    build: .
    user: "${UID:-1000}:${GID:-1000}"
    working_dir: /workspace
    stdin_open: true
    tty: true
    extra_hosts:
      - "host.docker.internal:172.17.0.1"
    volumes:
      - ~/workdir:/workspace
      - ./.config/claude:/home/node/.claude
      - ./.config/claude.json:/home/node/.claude.json
      - ./.mcp.json:/workspace/.mcp.json:ro
    environment:
      - ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
      - CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN}
```

#### `.mcp.json`

Project-scoped MCP config. Claude Code picks this up automatically from the working directory — no global registration step needed. Enables the slim browser toolset to minimize token consumption:

```json
{
  "mcpServers": {
    "chrome-devtools": {
      "command": "chrome-devtools-mcp",
      "args": [
        "--browser-url=http://172.17.0.1:9223",
        "--slim"
      ]
    }
  }
}
```

#### `.env`

Fill in **one** of the two auth variables (leave the other blank — see [Authentication](#authentication--pick-one)):

```ini
ANTHROPIC_API_KEY=""
CLAUDE_CODE_OAUTH_TOKEN=""
CLI_NAME="claude-box"
```

#### `cli.sh`

```bash
#!/usr/bin/env bash

CLAUDE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$CLAUDE_DIR/.env" ]; then
  CUSTOM_CLI=$(grep -E '^CLI_NAME=' "$CLAUDE_DIR/.env" | cut -d '=' -f2- | tr -d '"'\'' ')
fi
CMD="${CUSTOM_CLI:-claude-box}"

INSTALL_LINE="[ -f \"$CLAUDE_DIR/cli.sh\" ] && source \"$CLAUDE_DIR/cli.sh\" env"

case "$1" in
  install)
    if grep -Fxq "$INSTALL_LINE" "$HOME/.bashrc"; then
      echo "[✓] Hook already present in ~/.bashrc"
    else
      echo "" >> "$HOME/.bashrc"
      echo "# Claude Code sandbox hook" >> "$HOME/.bashrc"
      echo "$INSTALL_LINE" >> "$HOME/.bashrc"
      echo "[✓] Installed hook into ~/.bashrc. Run: source ~/.bashrc"
    fi
    ;;

  uninstall)
    sed -i "\|$INSTALL_LINE|d" "$HOME/.bashrc"
    echo "[✓] Removed hook from ~/.bashrc."
    ;;

  build)
    echo "Building Claude Code container..."
    GID=$(id -g) docker compose -f "$CLAUDE_DIR/docker-compose.yml" build
    ;;

  # Launch isolated Chrome instance and socat forwarder
  chrome)
    echo "Launching host Chrome with remote debugging on port 9222..."
    mkdir -p /tmp/chrome-agent-profile
    google-chrome \
      --remote-debugging-port=9222 \
      --user-data-dir=/tmp/chrome-agent-profile \
      --no-first-run \
      --no-default-browser-check > /dev/null 2>&1 &

    # Forward docker0 bridge traffic (port 9223) to host localhost (port 9222)
    pkill -f "socat.*9223" || true
    sleep 1
    socat TCP-LISTEN:9223,fork,bind=0.0.0.0 TCP:127.0.0.1:9222 > /dev/null 2>&1 &
    echo "[✓] Chrome running on 9222, bridged to Docker on 172.17.0.1:9223."
    ;;

  # One-time interactive OAuth login (subscription auth path)
  login)
    echo "Opening interactive OAuth login inside the container..."
    GID=$(id -g) docker compose -f "$CLAUDE_DIR/docker-compose.yml" run --rm --entrypoint claude claude /login
    ;;

  env)
    eval "
    ${CMD}() {
      case \"\$1\" in
        chrome)
          \"$CLAUDE_DIR/cli.sh\" chrome
          ;;
        build)
          \"$CLAUDE_DIR/cli.sh\" build
          ;;
        login)
          \"$CLAUDE_DIR/cli.sh\" login
          ;;
        *)
          GID=\$(id -g) docker compose -f \"$CLAUDE_DIR/docker-compose.yml\" run --rm claude \"\$@\"
          ;;
      esac
    }
    "
    ;;

  *)
    GID=$(id -g) docker compose -f "$CLAUDE_DIR/docker-compose.yml" run --rm claude "$@"
    ;;
esac
```

Make the script executable:

```bash
chmod +x ~/claude/cli.sh
```

---

### 3. Firewall Configuration (Ubuntu UFW)

Allow the Docker bridge subnet to access the forwarder port:

```bash
sudo ufw allow in on docker0 to any port 9223 proto tcp
```

---

### 4. Build & Install Hook

1. Build the Docker container image:
```bash
~/claude/cli.sh build
```

2. Register the terminal alias into `~/.bashrc`:
```bash
~/claude/cli.sh install
source ~/.bashrc
```

---

## Authentication — pick one

Claude Code supports two auth paths. Which one applies depends on what you already have — a Console API key is *not* required if you hold a Claude subscription.

### A. Claude subscription (Pro / Max / Team / Enterprise) — recommended if you already subscribe

Covered by your existing plan at no extra cost, sharing the same usage pool as claude.ai chat.

```bash
claude-box login
```

This opens an OAuth flow inside the container and writes credentials into the mounted `~/claude/.config/`, so it only needs to run once. Leave `ANTHROPIC_API_KEY` **blank** in `.env` — if it's set (even to an empty-looking stray value), Claude Code will use it instead of your subscription and bill per-token.

If you'd rather do this fully headless (no browser available from inside the container), run `claude setup-token` on the host instead and put the resulting value in `.env` as `CLAUDE_CODE_OAUTH_TOKEN`.

### B. Anthropic API key (pay-as-you-go via Console)

Get one from **console.anthropic.com → Settings → API Keys**. Useful if usage is bursty/irregular or you want per-token billing with no session caps.

```ini
ANTHROPIC_API_KEY="sk-ant-..."
```

> Note: subscription usage is metered by session/time-window, not unlimited. If you're running this agent hard and continuously and start hitting caps, that's the signal to switch to the API-key path for the overflow instead of accepting Claude Code's "use API credits" prompt (which silently switches you to pay-per-token).

---

## Workflow & Usage

### 1. Start the Host Browser Bridge

Before initiating browser automation, run the Chrome launcher on your host:

```bash
~/claude/cli.sh chrome
```

### 2. Launch Claude Code

Start an interactive agent session from any working directory:

```bash
claude-box
```

### 3. Autonomous / Non-Interactive Runs

Claude Code's equivalent of skipping tool-confirmation prompts — safe here specifically because the container is sandboxed:

```bash
claude-box -p --dangerously-skip-permissions "Navigate to https://news.ycombinator.com and extract the titles and URLs of the top 5 submissions."
```

### 4. Model Selection

```bash
claude-box --model claude-sonnet-4-6
```

### 5. Example Browser Prompts

* "Navigate to google.com and search for the latest news on Linux kernel releases."
* "Navigate to https://news.ycombinator.com and extract the titles and URLs of the top 5 submissions."

---

## Troubleshooting

* **Onboarding wizard re-runs every launch / settings keep resetting:**
`.config/claude.json` was mounted before it existed as a file, so Docker created it as a directory instead. Fix it:
```bash
rm -rf ~/claude/.config/claude.json
echo '{}' > ~/claude/.config/claude.json
```

* **Permission denied (`EACCES: /home/node/.claude/...`):**
If files in `.config` were created as `root`, reset ownership to your current host user:
```bash
sudo chown -R $(id -u):$(id -g) ~/claude/.config
chmod 700 ~/claude/.config
```

* **Chrome connection hangs or times out:**
Verify that both Chrome and the `socat` bridge are listening:
```bash
ss -tulpn | grep -E '9222|9223'
```

Test the endpoint directly from inside the container:
```bash
docker compose -f ~/claude/docker-compose.yml run --rm --entrypoint curl claude -m 3 -s http://172.17.0.1:9223/json/version
```

* **MCP server not showing up:**
Run `claude mcp list` inside the container to confirm `.mcp.json` was picked up from `/workspace`.

* **`Host header is specified and is not an IP address or localhost`:**
Ensure `.mcp.json` points directly to `http://172.17.0.1:9223` instead of domain hostnames like `host.docker.internal` to prevent Chrome's internal DNS-rebinding security rejection.

* **Claude Code is billing per-token when you expected subscription usage:**
Check for a stray `ANTHROPIC_API_KEY` — it silently overrides subscription auth. `unset ANTHROPIC_API_KEY` on the host and confirm `.env` has it blank, then re-run `claude-box login`.
