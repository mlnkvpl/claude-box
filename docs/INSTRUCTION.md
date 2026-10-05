# Claude-Box: Setup & Reproduction Instructions

Full from-scratch setup steps for claude-box — prerequisites, the exact file contents to
place at `~/claude/` (the actual deployment directory; see root README.md's Directory
Structure section), firewall config, and the build/install commands. For what this is and
day-to-day usage, see [`../README.md`](../README.md).

---

## 1. Prerequisites

* Docker and Docker Compose v2 (`docker compose`) installed on Ubuntu / WSL2.
* `socat` and Google Chrome installed on your host system:
```bash
sudo apt update && sudo apt install -y socat google-chrome-stable
```

* Either an Anthropic Console API key **or** a Claude Pro/Max/Team/Enterprise subscription — see [Authentication](../README.md#authentication--pick-one) below.
* Workspace directory:
```bash
mkdir -p ~/workdir
```

---
## 2. File Configurations

Create the setup directory:

```bash
mkdir -p ~/claude/.config/claude ~/claude/scripts
cd ~/claude
chmod 700 .config
```

`cli.sh` calls `ensure_config` (see `scripts/config.sh` below) on every invocation, which
creates `.config/claude/` and `.config/claude.json` automatically if either is missing —
so the only thing you still need to do by hand is the `chmod 700 .config` above, before
anything gets mounted into the container. (If you want to pre-create the file anyway:
`echo '{}' > .config/claude.json`.)

### `Dockerfile`

```dockerfile
FROM node:20-slim

# Install system utilities commonly needed by agent tools.
# jq/ripgrep/shellcheck/python3+python3-yaml: diagnostic/verification tools.
# libnss3-tools: mkcert needs it to cover Firefox's own trust store too.
# gnupg: needed for the PHP apt repo signing key below.
RUN apt-get update && apt-get install -y --no-install-recommends \
        git curl ca-certificates procps \
        jq ripgrep shellcheck python3 python3-yaml libnss3-tools gnupg \
    && rm -rf /var/lib/apt/lists/*

# PHP 8.3 CLI + Composer — matches this workspace's actual runtime version,
# so `php -l`, `composer validate`, etc. run against the same PHP the real
# app deploys on, not whatever Debian's default happens to ship.
RUN curl -sSL https://packages.sury.org/php/apt.gpg -o /etc/apt/trusted.gpg.d/php.gpg \
    && . /etc/os-release \
    && echo "deb https://packages.sury.org/php/ ${VERSION_CODENAME} main" > /etc/apt/sources.list.d/php.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        php8.3-cli php8.3-mbstring php8.3-xml php8.3-curl php8.3-sqlite3 php8.3-pgsql \
    && rm -rf /var/lib/apt/lists/* \
    && curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# mkcert — for exercising any locally-trusted-TLS setup in the workspace
# instead of just reading the script and trusting it.
RUN curl -sSL "https://dl.filippo.io/mkcert/latest?for=linux/amd64" -o /usr/local/bin/mkcert \
    && chmod +x /usr/local/bin/mkcert

# --- Docker CLI (client only — Docker-outside-of-Docker) ---
# No daemon runs in this container. `docker`/`docker compose` here talk to
# docker-socket-proxy (see docker-compose.yml) over DOCKER_HOST, not to a raw
# mounted socket and not to a nested dockerd. The proxy holds the real
# /var/run/docker.sock and exposes only a scoped subset of the Docker API —
# see docker-compose.yml for the exact grants.
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && . /etc/os-release \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# Install Claude Code and the official Chrome DevTools MCP server globally
RUN npm install -g @anthropic-ai/claude-code chrome-devtools-mcp

# Fix: the auto-updater runs as the `node` user at runtime but this global
# install happens as root at build time, so self-update fails with a
# permissions error. Hand the install tree to `node` so it can update itself.
RUN chown -R node:node /usr/local/lib/node_modules /usr/local/bin

# Fallback only — docker-compose.yml's `working_dir:` overrides this at
# runtime to the host-mirrored path (see that file for why).
WORKDIR /workspace

ENTRYPOINT ["claude"]
```

### `docker-compose.yml`

```yaml
services:
  # Docker-outside-of-Docker access, scoped. Holds the real host socket
  # itself; `claude` never sees it directly — it only talks to this proxy
  # over DOCKER_HOST. Grants write access to containers/images/networks/
  # volumes/build/exec; everything else (swarm, secrets, plugins, system,
  # nodes, services, tasks, configs) stays at the proxy's default-deny.
  docker-socket-proxy:
    image: tecnativa/docker-socket-proxy:latest
    container_name: claude-box-docker-proxy
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      - CONTAINERS=1
      - IMAGES=1
      - NETWORKS=1
      - VOLUMES=1
      - BUILD=1
      - EXEC=1
      - POST=1

  claude:
    build: .
    user: "${UID:-1000}:${GID:-1000}"
    # Must match the host-side volume path exactly — see the note in
    # "Architecture & Security Boundary" above (Host-mirrored workspace path).
    # cli.sh exports HOST_WORKDIR="$HOME/workdir[/<project>]" before every
    # invocation — the optional project suffix comes from `switch`.
    working_dir: ${HOST_WORKDIR}
    stdin_open: true
    tty: true
    depends_on:
      - docker-socket-proxy
    extra_hosts:
      - "host.docker.internal:172.17.0.1"
    volumes:
      - ${HOST_WORKDIR}:${HOST_WORKDIR}
      - ./.config/claude:/home/node/.claude
      - ./.config/claude.json:/home/node/.claude.json
      - ./.mcp.json:${HOST_WORKDIR}/.mcp.json:ro
    environment:
      - ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
      - CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN}
      - DOCKER_HOST=tcp://docker-socket-proxy:2375
```

Note that the `.config/claude` and `.config/claude.json` mounts above are fixed paths —
they are **not** scoped by `WORKDIR_PROJECT`. Switching projects (see `scripts/switch.sh`
below) only changes `HOST_WORKDIR`; auth and Claude Code's global settings stay shared
across every project you switch to. See README.md's "Multiple Projects" section for what
that implies.

### `.mcp.json`

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

### `.env`

Fill in **one** of the two auth variables (leave the other blank — see [Authentication](../README.md#authentication--pick-one)). Leave `WORKDIR_PROJECT` blank initially; it's written by `claude-box switch`, not by hand:

```ini
ANTHROPIC_API_KEY=""
CLAUDE_CODE_OAUTH_TOKEN=""
CLI_NAME="claude-box"
# Subdirectory of ~/workdir to mount as the sandbox root, e.g. "project-a".
# Empty mounts ~/workdir itself. Set via `claude-box switch <project>`,
# not by hand.
WORKDIR_PROJECT=
```

### `cli.sh`

```bash
#!/usr/bin/env bash

CLAUDE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$CLAUDE_DIR/.env" ]; then
  CUSTOM_CLI=$(grep -E '^CLI_NAME=' "$CLAUDE_DIR/.env" | cut -d '=' -f2- | tr -d '"'\'' ')
  WORKDIR_PROJECT=$(grep -E '^WORKDIR_PROJECT=' "$CLAUDE_DIR/.env" | cut -d '=' -f2- | tr -d '"'\'' ')
fi
CMD="${CUSTOM_CLI:-claude-box}"

# Which ~/workdir subdirectory to mount as the sandbox root — empty mounts
# ~/workdir itself. Selected via `switch`, persisted in .env, read above.
export HOST_WORKDIR="$HOME/workdir${WORKDIR_PROJECT:+/$WORKDIR_PROJECT}"

source "$CLAUDE_DIR/scripts/config.sh"
source "$CLAUDE_DIR/scripts/help.sh"
source "$CLAUDE_DIR/scripts/switch.sh"

ensure_config "$CLAUDE_DIR"

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

  # Show status of this compose file's services. Note docker-socket-proxy is
  # normally the only thing "up" here — `claude` only exists for the
  # duration of a `run --rm` invocation (see the default case below), so it
  # won't show as running between sessions even though the proxy does.
  ps)
    GID=$(id -g) docker compose -f "$CLAUDE_DIR/docker-compose.yml" ps
    ;;

  # Stop running services without removing them (mainly docker-socket-proxy).
  stop)
    GID=$(id -g) docker compose -f "$CLAUDE_DIR/docker-compose.yml" stop
    ;;

  # Stop AND remove everything this compose file owns (docker-socket-proxy +
  # its network). docker-socket-proxy uses `restart: unless-stopped` and is
  # only ever *started* via `depends_on` on the `claude` service — `run --rm`
  # removes the `claude` container on exit but never touches its
  # dependencies, so the proxy otherwise keeps running indefinitely in the
  # background even with no claude session active. This is the only way to
  # actually shut it down.
  down)
    GID=$(id -g) docker compose -f "$CLAUDE_DIR/docker-compose.yml" down
    ;;

  logs)
    GID=$(id -g) docker compose -f "$CLAUDE_DIR/docker-compose.yml" logs -f "${@:2}"
    ;;

  # Select which ~/workdir subdirectory gets mounted as the sandbox root.
  # Persisted in .env as WORKDIR_PROJECT, read at the top of this script —
  # each project gets its own absolute mount path, so Claude Code's
  # session transcripts/memory (keyed by cwd under ~/.claude/projects/)
  # stay separate per project instead of blending together. Logic lives in
  # scripts/switch.sh, sourced above.
  switch)
    switch_workdir "$2"
    ;;

  help|--help|-h)
    show_help
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
        ps)
          \"$CLAUDE_DIR/cli.sh\" ps
          ;;
        stop)
          \"$CLAUDE_DIR/cli.sh\" stop
          ;;
        down)
          \"$CLAUDE_DIR/cli.sh\" down
          ;;
        logs)
          \"$CLAUDE_DIR/cli.sh\" logs \"\${@:2}\"
          ;;
        help|--help|-h)
          \"$CLAUDE_DIR/cli.sh\" help
          ;;
        switch)
          \"$CLAUDE_DIR/cli.sh\" switch \"\${@:2}\"
          ;;
        *)
          \"$CLAUDE_DIR/cli.sh\" \"\$@\"
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

### `scripts/config.sh`

Sourced by `cli.sh`; provides `ensure_config`, called once at the top of every `cli.sh`
invocation to auto-create `.config/claude/` and `.config/claude.json` if either is
missing, and to fail loudly instead of silently misbehaving if Docker ever created
`claude.json` as a directory (which happens if it's referenced in a bind mount before
the file exists on the host):

```bash
#!/usr/bin/env bash

ensure_config() {
  local base="$1/.config"
  mkdir -p "$base/claude"
  if [ -d "$base/claude.json" ]; then
    echo "error: $base/claude.json is a directory (created by Docker). Fix: sudo rm -rf $base && rerun" >&2
    exit 1
  fi
  [ -f "$base/claude.json" ] || echo '{}' > "$base/claude.json"
}
```

### `scripts/switch.sh`

Sourced by `cli.sh`; provides `switch_workdir`, backing the `switch` subcommand. Relies
on `$CLAUDE_DIR`, `$CMD`, and `$WORKDIR_PROJECT`, all set earlier in `cli.sh`:

```bash
#!/usr/bin/env bash
#
# `switch` subcommand logic. Sourced by cli.sh; relies on $CLAUDE_DIR, $CMD,
# and $WORKDIR_PROJECT (read from .env at the top of cli.sh).
#

switch_workdir()
{
  local PROJECT="$1"

  if [ -z "$PROJECT" ]; then
    local CURRENT="${WORKDIR_PROJECT:-<none — mounting $HOME/workdir root>}"
    echo "Current project: $CURRENT"
    echo "Available: $(find "$HOME/workdir" -mindepth 1 -maxdepth 1 -type d -printf '%f ' 2>/dev/null)"
    return 0
  fi

  if [ ! -d "$HOME/workdir/$PROJECT" ]; then
    echo "[✗] $HOME/workdir/$PROJECT does not exist." >&2
    return 1
  fi

  if [ -n "$(GID=$(id -g) docker compose -f "$CLAUDE_DIR/docker-compose.yml" ps --status running -q claude 2>/dev/null)" ]; then
    echo "[✗] A claude container is running — stop it first: ${CMD} down" >&2
    return 1
  fi

  [ -f "$CLAUDE_DIR/.env" ] || cp "$CLAUDE_DIR/.env.tpl" "$CLAUDE_DIR/.env"
  if grep -qE '^WORKDIR_PROJECT=' "$CLAUDE_DIR/.env"; then
    sed -i "s|^WORKDIR_PROJECT=.*|WORKDIR_PROJECT=$PROJECT|" "$CLAUDE_DIR/.env"
  else
    # A pre-existing .env not ending in a newline would otherwise merge
    # this onto the previous line (e.g. CLI_NAME="x"WORKDIR_PROJECT=y).
    [ -n "$(tail -c1 "$CLAUDE_DIR/.env" 2>/dev/null)" ] && echo >> "$CLAUDE_DIR/.env"
    echo "WORKDIR_PROJECT=$PROJECT" >> "$CLAUDE_DIR/.env"
  fi
  echo "[✓] Switched to '$PROJECT' — mounting $HOME/workdir/$PROJECT"
}
```

### `scripts/help.sh`

Sourced by `cli.sh` for the `help`/`--help`/`-h` command:

```bash
#!/usr/bin/env bash
#
# Help text for the claude-box CLI. Sourced by cli.sh; relies on $CMD
# (resolved there from CLI_NAME in .env, default "claude-box").
#

show_help()
{
  printf '\n%s — sandboxed Claude Code CLI\n\n' "${CMD}"
  printf 'Usage: %s [args...]   Launch Claude Code — interactive with no args, or pass\n' "${CMD}"
  printf '                          flags/prompts straight through, e.g.\n'
  printf '                          %s -p "..." --dangerously-skip-permissions\n\n' "${CMD}"

  printf 'Container lifecycle:\n'
  printf '  %-12s %s\n' "ps" "Show status (mainly docker-socket-proxy — claude itself"
  printf '  %-12s %s\n' ""   "only exists for the duration of a run)"
  printf '  %-12s %s\n' "stop" "Stop running containers without removing them"
  printf '  %-12s %s\n' "down" "Stop AND remove everything (docker-socket-proxy + its"
  printf '  %-12s %s\n' ""     "network) — the proxy otherwise keeps running in the"
  printf '  %-12s %s\n' ""     "background between sessions"
  printf '  %-12s %s\n\n' "logs [service]" "Follow logs"

  printf 'Workdir:\n'
  printf '  %-12s %s\n' "switch" "Show current project + available subdirectories of ~/workdir"
  printf '  %-12s %s\n' "switch <name>" "Mount ~/workdir/<name> as the sandbox root instead of"
  printf '  %-12s %s\n\n' ""   "~/workdir itself (container must be down first)"

  printf 'Setup:\n'
  printf '  %-12s %s\n' "build" "Build/rebuild the Docker image"
  printf '  %-12s %s\n' "login" "One-time interactive OAuth login (subscription auth)"
  printf '  %-12s %s\n' "chrome" "Launch host Chrome + socat bridge for browser automation"
  printf '  %-12s %s\n' "install" "Install the global \"${CMD}\" command + ~/.bashrc hook"
  printf '  %-12s %s\n' "uninstall" "Remove that hook"
  printf '  %-12s %s\n\n' "help" "Show this help"

  printf 'See README.md for the full setup/troubleshooting guide.\n\n'
}
```

Make the script executable:

```bash
chmod +x ~/claude/cli.sh
```

---

## 3. Firewall Configuration (Ubuntu UFW)

Allow the Docker bridge subnet to access the forwarder port:

```bash
sudo ufw allow in on docker0 to any port 9223 proto tcp
```

---

## 4. Build & Install Hook

1. Build the Docker container image:
```bash
~/claude/cli.sh build
```

2. Register the terminal alias into `~/.bashrc`:
```bash
~/claude/cli.sh install
source ~/.bashrc
```
