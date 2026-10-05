# Claude-Box: Sandboxed Claude Code + Browser Automation

A secure, isolated Docker container setup for running Anthropic's official Claude Code CLI (`@anthropic-ai/claude-code`) paired with live host browser automation via the Chrome DevTools Model Context Protocol (`chrome-devtools-mcp`).

It isolates the agent strictly inside your `~/workdir` projects, shields your host home directory (SSH keys, shell dotfiles, personal credentials), prevents root file-permission issues, and bridges safely to your host's Google Chrome instance for autonomous web tasks.

---

## Architecture & Security Boundary

* **Host Filesystem Isolation:** The agent only accesses `~/workdir`. It cannot read host paths such as `~/.ssh`, `~/.aws`, or `~/.bashrc`.
* **Clean User Permissions:** Runs mapped to your host's non-root `UID:GID`, ensuring files created or modified by the agent remain editable on your host.
* **Persistent Configuration:** Claude Code splits its persistent state across two locations, both of which must be mounted:
  * `~/claude/.config/claude/` → `/home/node/.claude` — session transcripts, project memory.
  * `~/claude/.config/claude.json` → `/home/node/.claude.json` — global settings, onboarding state, auth. This is a **file**, not a folder; mounting only the directory leaves this absent and the onboarding wizard re-runs (and resets preferences) on every container start.
* **Safe Host Browser Bridge:** Controls your host Chrome instance over the Chrome DevTools Protocol (CDP). A lightweight `socat` bridge forwards container traffic (`172.17.0.1:9223`) to Chrome's local loopback listener (`127.0.0.1:9222`), bypassing Chrome's DNS-rebinding security checks while keeping the container sandboxed.
* **Scoped Docker access (Docker-outside-of-Docker):** The agent can run `docker`/`docker compose` — needed to actually build/run/test the projects under `~/workdir` — without a raw mounted socket or a nested daemon. A `docker-socket-proxy` sidecar holds the real `/var/run/docker.sock` and exposes only a filtered subset of the Docker API (containers/images/networks/volumes/build/exec, read+write; swarm/secrets/plugins/system left denied) over `DOCKER_HOST`. This is still root-equivalent-*ish* access, scoped down rather than eliminated — see [Docker access](#docker-access-docker-outside-of-docker) below before relying on it as a hard security boundary.
* **Host-mirrored workspace path:** `~/workdir` is bind-mounted at the *same absolute path* inside the container (`$HOME/workdir`), not a convenience alias like `/workspace`. This isn't cosmetic — Docker-outside-of-Docker means `docker compose` run inside the agent is executed by the *host's* daemon, which resolves any relative bind mount in a compose file (e.g. `./projects/api:/var/www/html`) against its own filesystem. A mismatched path here silently mounts the wrong (or an empty) host directory instead of your real project files.

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
├── scripts/
│   └── help.sh           # `help`/`--help`/`-h` command text, sourced by cli.sh
├── docs/
│   └── INSTRUCTION.md    # Full setup/reproduction steps (see Setup below)
├── docker-compose.yml    # claude + docker-socket-proxy services, user mapping, volume mounts, extra_hosts
├── Dockerfile             # Node 20-slim + Claude Code + dev tools + docker CLI (DooD client)
└── README.md             # Documentation
```

---

## Setup

Full from-scratch setup — prerequisites, exact file contents, firewall config, and the
build/install commands — lives in [`docs/INSTRUCTION.md`](docs/INSTRUCTION.md).

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

## Docker access (Docker-outside-of-Docker)

The agent can run `docker`/`docker compose` — needed to actually build, start, and test
Dockerized projects under `~/workdir`, not just edit their config files. No manual setup
step is required; it works automatically once you `~/claude/cli.sh build` and run
normally.

**How it works:** a `docker-socket-proxy` sidecar (see `docker-compose.yml`) mounts the
real `/var/run/docker.sock` and re-exposes a *filtered* subset of the Docker API over
`DOCKER_HOST=tcp://docker-socket-proxy:2375`. The `claude` container never sees the raw
socket itself. Enabled: containers, images, networks, volumes, build, exec — read and
write. Left at the proxy's default-deny: swarm, secrets, plugins, system info, nodes,
services, tasks, configs.

**What this means in practice:**
- Because the proxy talks to the *same* host daemon your own `docker`/`docker compose`
  does, everything is shared, not duplicated — if the agent runs `docker compose up` on
  a project, you'll see those same running containers with `docker ps` on your host, and
  running `docker compose up` yourself on the same compose file converges to the same
  state rather than creating a second copy.
- **This is not a hard security boundary, just a narrower one than a raw socket mount.**
  The proxy restricts *which* Docker API categories are reachable, but doesn't inspect
  *parameters within* an allowed call — a container-create request through the enabled
  `containers`+`build` categories could still, in principle, request `--privileged` or a
  host bind mount. Closing that specific gap needs a policy/admission-control layer in
  front of the proxy, which isn't set up here. Treat this as convenience-oriented
  isolation, not a multi-tenant-grade sandbox.
- The workspace is mounted at the **same absolute path** on both sides
  (`$HOME/workdir` on the host, mirrored inside the container) instead of a friendly
  alias like `/workspace` — required so relative bind mounts inside a project's own
  `docker-compose.yml` (e.g. `./projects/api:/var/www/html`) resolve correctly against
  the *host's* filesystem, since Docker-outside-of-Docker means the host daemon — not
  this container — is what actually creates those mounts.

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

## Multiple Projects

`~/workdir` doesn't have to be one flat tree — organize it into subdirectories, one per
project (e.g. `~/workdir/ululua`, `~/workdir/english`), and switch which one gets
mounted as the sandbox root:

```bash
claude-box down            # stop first — a running container's mount won't follow the switch
claude-box switch ululua   # select the subdirectory
claude-box                 # relaunch — now mounts ~/workdir/ululua
```

Run `switch` with no argument to see the current selection and what's available:

```bash
claude-box switch
```

Each project is mounted at its own absolute path (`~/workdir/<project>` on both sides,
same path-mirroring requirement as above), rather than everything collapsing onto a
shared `~/workdir`. That matters beyond the bind mount itself: Claude Code's own
session transcripts and project memory are keyed by the absolute working-directory
path under `/home/node/.claude/projects/`, so giving each project a distinct mount
path keeps their history and memory from blending together. Project-level
`CLAUDE.md`, `.claude/skills/`, and `.claude/settings.json` are separated too, simply
because they live inside whichever subdirectory is currently mounted.

The selection persists in `.env` as `WORKDIR_PROJECT` (empty = mount `~/workdir`
itself — the original, default behavior). `switch` refuses to run while a `claude`
container is up, since the active container's bind mount is fixed to whatever it
resolved at start; switching while it's running would split-brain the running session
against any new container.

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
Run `claude mcp list` inside the container to confirm `.mcp.json` was picked up from the working directory (`$HOME/workdir` on the host, mirrored inside the container at the same path).

* **`Host header is specified and is not an IP address or localhost`:**
Ensure `.mcp.json` points directly to `http://172.17.0.1:9223` instead of domain hostnames like `host.docker.internal` to prevent Chrome's internal DNS-rebinding security rejection.

* **Claude Code is billing per-token when you expected subscription usage:**
Check for a stray `ANTHROPIC_API_KEY` — it silently overrides subscription auth. `unset ANTHROPIC_API_KEY` on the host and confirm `.env` has it blank, then re-run `claude-box login`.

* **`docker`/`docker compose` inside the agent fails with a connection error:**
Confirm the proxy sidecar is actually running: `docker compose -f ~/claude/docker-compose.yml ps docker-socket-proxy`. If it's not, `depends_on` should have started it automatically on the last `claude-box` invocation — try `~/claude/cli.sh build` again, or bring it up directly with `docker compose -f ~/claude/docker-compose.yml up -d docker-socket-proxy`.

* **A project's `docker compose up` starts containers, but a bind-mounted directory is empty/wrong inside them:**
`HOST_WORKDIR` wasn't set to the same path on both sides of a volume mount — check `cli.sh`'s invocations still export `HOST_WORKDIR="$HOME/workdir[/<project>]"` before every `docker compose` call, and that `docker-compose.yml`'s `working_dir`/volume lines still reference `${HOST_WORKDIR}`, not a hardcoded alias like `/workspace`. See [Docker access](#docker-access-docker-outside-of-docker) for why this has to match exactly.

* **`claude-box switch` succeeds but the container still seems to mount the old directory:**
A running container's bind mount is fixed to whatever it resolved at container start — it won't notice a later `.env` change. Make sure `claude-box down` ran (or the container was already stopped) before switching, then start a fresh session.
