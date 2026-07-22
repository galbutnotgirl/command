#!/bin/zsh
emulate -L zsh
set -euo pipefail

DIR="${0:A:h:h}"
HELPER="${DIR}/restart-app.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/command-restart-test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

pass=0
fail=0
ok() { print -- "  PASS $1"; (( ++pass )); }
bad() { print -u2 -- "  FAIL $1"; (( ++fail )); }
assert_contains() {
  local name="$1" file="$2" expected="$3"
  if grep -Fq -- "$expected" "$file"; then ok "$name"; else bad "$name"; fi
}
assert_empty() {
  local name="$1" file="$2"
  if [[ ! -s "$file" ]]; then ok "$name"; else bad "$name"; fi
}

[[ -x "$HELPER" ]] || { print -u2 -- "restart helper is not executable"; exit 1; }

FAKE_BIN="$TMP_ROOT/bin"
FAKE_HOME="$TMP_ROOT/home"
APP="$TMP_ROOT/Command.app"
mkdir -p "$FAKE_BIN" "$FAKE_HOME" "$APP"

cat > "$FAKE_BIN/launchctl" <<'SH'
#!/bin/zsh
print -r -- "$*" >> "$COMMAND_RESTART_LAUNCHCTL_LOG"
if [[ "$1" == "print" ]]; then exit "${COMMAND_RESTART_PRINT_STATUS:-0}"; fi
if [[ "$1" == "kickstart" ]]; then exit "${COMMAND_RESTART_KICKSTART_STATUS:-0}"; fi
exit 1
SH
cat > "$FAKE_BIN/open" <<'SH'
#!/bin/zsh
print -r -- "$*" >> "$COMMAND_RESTART_OPEN_LOG"
exit "${COMMAND_RESTART_OPEN_STATUS:-0}"
SH
cat > "$FAKE_BIN/sleep" <<'SH'
#!/bin/zsh
exit 0
SH
chmod +x "$FAKE_BIN"/*

export HOME="$FAKE_HOME"
export COMMAND_LAUNCHCTL_BIN="$FAKE_BIN/launchctl"
export COMMAND_OPEN_BIN="$FAKE_BIN/open"
export COMMAND_SLEEP_BIN="$FAKE_BIN/sleep"
export COMMAND_RESTART_WAIT_ATTEMPTS=1
export COMMAND_RESTART_LAUNCHCTL_LOG="$TMP_ROOT/launchctl.log"
export COMMAND_RESTART_OPEN_LOG="$TMP_ROOT/open.log"

: > "$COMMAND_RESTART_LAUNCHCTL_LOG"
: > "$COMMAND_RESTART_OPEN_LOG"
COMMAND_RESTART_PRINT_STATUS=0 COMMAND_RESTART_KICKSTART_STATUS=0 \
  "$HELPER" 999999 "$APP" com.claudecommand
assert_contains "loaded service is checked" "$COMMAND_RESTART_LAUNCHCTL_LOG" "print gui/$(id -u)/com.claudecommand"
assert_contains "loaded service is kickstarted once" "$COMMAND_RESTART_LAUNCHCTL_LOG" "kickstart -k gui/$(id -u)/com.claudecommand"
assert_empty "successful launchd restart does not open app" "$COMMAND_RESTART_OPEN_LOG"

: > "$COMMAND_RESTART_LAUNCHCTL_LOG"
: > "$COMMAND_RESTART_OPEN_LOG"
COMMAND_RESTART_PRINT_STATUS=1 COMMAND_RESTART_OPEN_STATUS=0 \
  "$HELPER" 999999 "$APP" com.claudecommand
assert_contains "unloaded service falls back to app" "$COMMAND_RESTART_OPEN_LOG" "$APP"

: > "$COMMAND_RESTART_LAUNCHCTL_LOG"
: > "$COMMAND_RESTART_OPEN_LOG"
COMMAND_RESTART_PRINT_STATUS=0 COMMAND_RESTART_KICKSTART_STATUS=1 COMMAND_RESTART_OPEN_STATUS=0 \
  "$HELPER" 999999 "$APP" com.claudecommand
assert_contains "failed kickstart falls back to app" "$COMMAND_RESTART_OPEN_LOG" "$APP"

if "$HELPER" nope "$APP" com.claudecommand >/dev/null 2>&1; then
  bad "invalid pid is rejected"
else
  ok "invalid pid is rejected"
fi

: > "$COMMAND_RESTART_LAUNCHCTL_LOG"
: > "$COMMAND_RESTART_OPEN_LOG"
if "$HELPER" $$ "$APP" com.claudecommand >/dev/null 2>&1; then
  bad "live parent timeout is rejected"
else
  ok "live parent timeout is rejected"
fi
assert_empty "timeout does not start another instance" "$COMMAND_RESTART_LAUNCHCTL_LOG"
assert_empty "timeout does not open another instance" "$COMMAND_RESTART_OPEN_LOG"

if (( fail > 0 )); then
  print -u2 -- "restart helper: ${pass} passed, ${fail} failed"
  exit 1
fi
print -- "restart helper: ${pass} passed, 0 failed"
