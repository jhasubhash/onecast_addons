#!/usr/bin/env bash
# Send "hi" to each Claude Code instance (one per config dir).
# A login that reached its time limit cannot be renewed by use, so a failed sign-in raises a
# notification asking for `claude auth login` instead of failing silently.
set -u

MESSAGE="${1:-hi}"
CONFIG_DIRS=("$HOME/.claude" "$HOME/.claude1")

notify() {
  local title="$1" body="$2"
  osascript - "$title" "$body" <<'EOF' >/dev/null 2>&1
on run argv
  display notification (item 2 of argv) with title (item 1 of argv) sound name "Basso"
end run
EOF
}

for dir in "${CONFIG_DIRS[@]}"; do
  echo "=== $dir ==="
  if [[ ! -d "$dir" ]]; then
    echo "skipped: directory not found"
    continue
  fi
  # ~/.claude is the default instance (config at ~/.claude.json), so leave CLAUDE_CONFIG_DIR unset for it.
  if [[ "$dir" == "$HOME/.claude" ]]; then
    login="claude auth login"
    output=$(env -u CLAUDE_CONFIG_DIR claude -p "$MESSAGE" < /dev/null 2>&1)
  else
    login="CLAUDE_CONFIG_DIR=$dir claude auth login"
    output=$(CLAUDE_CONFIG_DIR="$dir" claude -p "$MESSAGE" < /dev/null 2>&1)
  fi
  status=$?
  echo "$output"

  # `claude -p` can print the auth error as its answer and still exit 0, so match the text too.
  if grep -qiE "failed to authenticate|reached its time limit|not logged in|/login|auth login" <<<"$output"; then
    echo "sign-in needed: run \`$login\`"
    notify "Claude Code signed out ($(basename "$dir"))" "Run: $login"
  elif [[ $status -ne 0 ]]; then
    echo "failed (exit $status)"
    notify "Say Hi to Claude failed ($(basename "$dir"))" "claude exited with status $status"
  fi
  echo
done
