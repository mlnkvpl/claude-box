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
    HOST_WORKDIR="$HOME/workdir" GID=$(id -g) docker compose -f "$CLAUDE_DIR/docker-compose.yml" build
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
    HOST_WORKDIR="$HOME/workdir" GID=$(id -g) docker compose -f "$CLAUDE_DIR/docker-compose.yml" run --rm --entrypoint claude claude /login
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
          HOST_WORKDIR=\"\$HOME/workdir\" GID=\$(id -g) docker compose -f \"$CLAUDE_DIR/docker-compose.yml\" run --rm claude \"\$@\"
          ;;
      esac
    }
    "
    ;;

  *)
    HOST_WORKDIR="$HOME/workdir" GID=$(id -g) docker compose -f "$CLAUDE_DIR/docker-compose.yml" run --rm claude "$@"
    ;;
esac
