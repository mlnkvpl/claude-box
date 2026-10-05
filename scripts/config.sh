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