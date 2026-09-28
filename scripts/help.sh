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

  printf 'Setup:\n'
  printf '  %-12s %s\n' "build" "Build/rebuild the Docker image"
  printf '  %-12s %s\n' "login" "One-time interactive OAuth login (subscription auth)"
  printf '  %-12s %s\n' "chrome" "Launch host Chrome + socat bridge for browser automation"
  printf '  %-12s %s\n' "install" "Install the global \"${CMD}\" command + ~/.bashrc hook"
  printf '  %-12s %s\n' "uninstall" "Remove that hook"
  printf '  %-12s %s\n\n' "help" "Show this help"

  printf 'See README.md for the full setup/troubleshooting guide.\n\n'
}
