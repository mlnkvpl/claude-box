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
