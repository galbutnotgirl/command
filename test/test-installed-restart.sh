#!/bin/zsh
# Local release-machine probe. Restarts installed Command without clearing any
# user settings, then verifies launchd ownership and dispatch recovery.
emulate -L zsh
set -euo pipefail

LABEL="com.claudecommand"
DOMAIN="gui/$(id -u)/${LABEL}"
SOCKET="${HOME}/.claude/state/command-agent.sock"
MAX_ATTEMPTS="${COMMAND_RESTART_TEST_ATTEMPTS:-75}"
SENTINEL_KEY="commandRestartTestSentinel$$"
SENTINEL_VALUE="restart-$RANDOM-$(date +%s)"

if [[ ! "$MAX_ATTEMPTS" == <-> ]] || (( MAX_ATTEMPTS < 1 )); then
  print -u2 -- "COMMAND_RESTART_TEST_ATTEMPTS must be a positive integer"
  exit 2
fi

job_pid() {
  launchctl print "$DOMAIN" 2>/dev/null \
    | awk '/^[[:space:]]*pid = / { print $3; exit }'
}

ping_socket() {
  local reply
  reply="$(printf 'ping\n' | nc -U -w 2 "$SOCKET" 2>/dev/null || true)"
  [[ "$reply" == "pong" ]]
}

defaults delete "$LABEL" "$SENTINEL_KEY" >/dev/null 2>&1 || true
trap 'defaults delete "$LABEL" "$SENTINEL_KEY" >/dev/null 2>&1 || true' EXIT
defaults write "$LABEL" "$SENTINEL_KEY" -string "$SENTINEL_VALUE"

marker="$(mktemp "${TMPDIR:-/tmp}/command-restart-marker.XXXXXX")"
trap 'defaults delete "$LABEL" "$SENTINEL_KEY" >/dev/null 2>&1 || true; rm -f "$marker"' EXIT

old_pid="$(job_pid)"
if [[ -z "$old_pid" ]] || ! /bin/kill -0 "$old_pid" 2>/dev/null; then
  print -u2 -- "FAIL: installed Command launchd job is not running"
  exit 1
fi
if [[ ! -S "$SOCKET" ]] || ! ping_socket; then
  print -u2 -- "FAIL: installed Command dispatch socket is not ready"
  exit 1
fi

reply="$(printf 'restart\n' | nc -U -w 2 "$SOCKET" 2>/dev/null || true)"
if [[ "$reply" != "ok" ]]; then
  print -u2 -- "FAIL: restart command returned ${reply:-no response}"
  exit 1
fi

new_pid=""
for (( attempt = 1; attempt <= MAX_ATTEMPTS; attempt++ )); do
  sleep 0.2
  candidate="$(job_pid)"
  if [[ -n "$candidate" && "$candidate" != "$old_pid" ]] \
      && /bin/kill -0 "$candidate" 2>/dev/null \
      && [[ -S "$SOCKET" ]] && ping_socket; then
    new_pid="$candidate"
    break
  fi
done

if [[ -z "$new_pid" ]]; then
  print -u2 -- "FAIL: Command did not return with a new responsive PID"
  launchctl print "$DOMAIN" 2>/dev/null | head -n 45 >&2 || true
  exit 1
fi
if [[ "$(defaults read "$LABEL" "$SENTINEL_KEY" 2>/dev/null || true)" != "$SENTINEL_VALUE" ]]; then
  print -u2 -- "FAIL: UserDefaults did not survive restart"
  exit 1
fi

new_crashes="$(find "${HOME}/Library/Logs/DiagnosticReports" -maxdepth 1 -type f \
  \( -name 'Command*.ips' -o -name 'Command*.crash' \) -newer "$marker" -print 2>/dev/null || true)"
if [[ -n "$new_crashes" ]]; then
  print -u2 -- "FAIL: Command produced crash report during restart"
  print -u2 -- "$new_crashes"
  exit 1
fi

print -- "installed restart passed"
print -- "  launchd pid: ${old_pid} -> ${new_pid}"
print -- "  socket response: ok -> pong"
print -- "  UserDefaults sentinel: preserved"
print -- "  new crashes: 0"
