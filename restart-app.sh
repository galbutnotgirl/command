#!/bin/zsh
# Detached restart handoff. Parent exits successfully after launching this helper,
# preventing launchd KeepAlive and a manual `open` from racing two app instances.
emulate -L zsh
set -u

if (( $# != 3 )); then
  print -u2 -- "usage: restart-app.sh PID APP_PATH LAUNCH_AGENT_LABEL"
  exit 64
fi

PID="$1"
APP_PATH="$2"
LABEL="$3"
LAUNCHCTL_BIN="${COMMAND_LAUNCHCTL_BIN:-/bin/launchctl}"
OPEN_BIN="${COMMAND_OPEN_BIN:-/usr/bin/open}"
SLEEP_BIN="${COMMAND_SLEEP_BIN:-/bin/sleep}"
MAX_ATTEMPTS="${COMMAND_RESTART_WAIT_ATTEMPTS:-75}"
LOG_DIR="${HOME}/.claude/logs"
LOG_FILE="${LOG_DIR}/command-restart.log"
SERVICE="gui/$(id -u)/${LABEL}"

mkdir -p "$LOG_DIR" 2>/dev/null || true
log() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') [restart] $*" >> "$LOG_FILE" 2>/dev/null || true; }

if [[ ! "$PID" == <-> ]] || (( PID < 1 )); then
  log "invalid pid=${PID}"
  exit 64
fi
if [[ ! "$MAX_ATTEMPTS" == <-> ]] || (( MAX_ATTEMPTS < 1 )); then
  log "invalid wait attempts=${MAX_ATTEMPTS}"
  exit 64
fi

for (( attempt = 1; attempt <= MAX_ATTEMPTS; attempt++ )); do
  /bin/kill -0 "$PID" 2>/dev/null || break
  "$SLEEP_BIN" 0.2
done
if /bin/kill -0 "$PID" 2>/dev/null; then
  log "timed out waiting for pid=${PID}"
  exit 1
fi

if "$LAUNCHCTL_BIN" print "$SERVICE" >/dev/null 2>&1 \
    && "$LAUNCHCTL_BIN" kickstart -k "$SERVICE" >/dev/null 2>&1; then
  log "restarted through launchd service=${SERVICE}"
  exit 0
fi

if [[ -d "$APP_PATH" ]] && "$OPEN_BIN" "$APP_PATH" >/dev/null 2>&1; then
  log "launchd unavailable; reopened app=${APP_PATH}"
  exit 0
fi

log "failed to restart service=${SERVICE} app=${APP_PATH}"
exit 1
