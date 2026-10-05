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

source "$CLAUDE_DIR/scripts/help.sh"
source "$CLAUDE_DIR/scripts/switch.sh"

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
