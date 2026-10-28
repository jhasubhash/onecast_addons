#!/usr/bin/env bash
# Send "hi" to each Claude Code instance (one per config dir).
set -u

MESSAGE="${1:-hi}"
CONFIG_DIRS=("$HOME/.claude" "$HOME/.claude1")

for dir in "${CONFIG_DIRS[@]}"; do
  echo "=== $dir ==="
  if [[ ! -d "$dir" ]]; then
    echo "skipped: directory not found"
    continue
  fi
  # ~/.claude is the default instance (config at ~/.claude.json), so leave CLAUDE_CONFIG_DIR unset for it.
  if [[ "$dir" == "$HOME/.claude" ]]; then
    env -u CLAUDE_CONFIG_DIR claude -p "$MESSAGE" < /dev/null || echo "failed (exit $?)"
  else
    CLAUDE_CONFIG_DIR="$dir" claude -p "$MESSAGE" < /dev/null || echo "failed (exit $?)"
  fi
  echo
done
