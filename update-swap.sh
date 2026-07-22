#!/bin/zsh
# Atomic updater handoff. Command validates downloaded bundle before launching
# this helper; helper validates again after copy and restores prior app on error.
emulate -L zsh
set -u

if (( $# != 7 )); then
  print -u2 -- "usage: update-swap.sh PID NEW_APP DEST_APP BUNDLE_ID VERSION REQUIREMENT REOPEN"
  exit 64
fi

PID="$1"
NEW_APP="$2"
DEST_APP="$3"
EXPECTED_BUNDLE_ID="$4"
EXPECTED_VERSION="$5"
EXPECTED_REQUIREMENT="$6"
REOPEN="$7"
BACKUP_APP="${DEST_APP}.old"
LOG_DIR="${HOME}/.claude/logs"
LOG_FILE="${LOG_DIR}/command-updater.log"
LAUNCH_AGENT_LABEL="${COMMAND_LAUNCH_AGENT_LABEL:-com.claudecommand}"
LAUNCHCTL_BIN="${COMMAND_LAUNCHCTL_BIN:-/bin/launchctl}"
OPEN_BIN="${COMMAND_OPEN_BIN:-/usr/bin/open}"

mkdir -p "$LOG_DIR" 2>/dev/null || true
log() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') [updater] $*" >> "$LOG_FILE" 2>/dev/null || true; }
open_app() {
  [[ "$REOPEN" == "1" && -d "$1" ]] || return 0
  local service="gui/$(id -u)/${LAUNCH_AGENT_LABEL}"
  if "$LAUNCHCTL_BIN" print "$service" >/dev/null 2>&1 \
      && "$LAUNCHCTL_BIN" kickstart "$service" >/dev/null 2>&1; then
    log "restarted through launchd service=$service"
    return 0
  fi
  "$OPEN_BIN" "$1" >/dev/null 2>&1 || true
  log "launchd restart unavailable; reopened with open"
}

rollback() {
  local reason="$1"
  log "rollback: $reason"
  /bin/rm -rf "$DEST_APP"
  if [[ -d "$BACKUP_APP" ]]; then
    /bin/mv "$BACKUP_APP" "$DEST_APP" || log "ERROR could not restore backup"
  fi
  open_app "$DEST_APP"
  exit 1
}

[[ -d "$NEW_APP" ]] || { log "ERROR candidate missing: $NEW_APP"; exit 1; }

# Successful app exit does not trigger Command's launchd KeepAlive rule. Wait
# for current process before touching bundle, then reopen exactly once below.
for _i in {1..75}; do
  /bin/kill -0 "$PID" 2>/dev/null || break
  sleep 0.2
done
if /bin/kill -0 "$PID" 2>/dev/null; then
  log "ERROR timed out waiting for pid=$PID"
  exit 1
fi

/bin/rm -rf "$BACKUP_APP"
if [[ -d "$DEST_APP" ]]; then
  /bin/mv "$DEST_APP" "$BACKUP_APP" || { log "ERROR could not preserve current app"; exit 1; }
fi

/usr/bin/ditto "$NEW_APP" "$DEST_APP" || rollback "copy failed"

INFO_PLIST="${DEST_APP}/Contents/Info.plist"
ACTUAL_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST" 2>/dev/null || true)"
ACTUAL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null || true)"
EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST" 2>/dev/null || true)"

[[ "$ACTUAL_BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] || rollback "bundle id mismatch: ${ACTUAL_BUNDLE_ID:-missing}"
[[ "$ACTUAL_VERSION" == "$EXPECTED_VERSION" ]] || rollback "version mismatch: ${ACTUAL_VERSION:-missing}"
[[ -n "$EXECUTABLE_NAME" && -x "${DEST_APP}/Contents/MacOS/${EXECUTABLE_NAME}" ]] || rollback "executable missing"
/usr/bin/codesign --verify --deep --strict "-R=${EXPECTED_REQUIREMENT}" "$DEST_APP" >/dev/null 2>&1 \
  || rollback "signature requirement failed"

# Signature requirement matches currently installed app, so quarantine can be
# removed without weakening updater trust to arbitrary downloaded app bundles.
/usr/bin/xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true
/bin/rm -rf "$BACKUP_APP"
log "installed version=$ACTUAL_VERSION bundle=$ACTUAL_BUNDLE_ID"
open_app "$DEST_APP"
exit 0
