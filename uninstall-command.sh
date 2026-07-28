#!/bin/zsh
# uninstall-command.sh - remove Command runtime, app, approvals, and optional local data.
emulate -L zsh
set -uo pipefail

MODE="keep-data"
RESET_PERMISSIONS=true
APP_PATH=""
while (( $# > 0 )); do
  case "$1" in
    --keep-data) MODE="keep-data" ;;
    --remove-data) MODE="remove-data" ;;
    --keep-permissions) RESET_PERMISSIONS=false ;;
    --app-path)
      shift
      (( $# > 0 )) || { print -u2 -- "[uninstall] --app-path requires a value"; exit 2; }
      APP_PATH="$1"
      ;;
    *) print -u2 -- "[uninstall] unknown option: $1"; exit 2 ;;
  esac
  shift
done

LABEL="com.claudecommand"
UID_NUM="$(id -u)"
LAUNCHCTL="${COMMAND_UNINSTALL_LAUNCHCTL:-/bin/launchctl}"
PKILL="${COMMAND_UNINSTALL_PKILL:-/usr/bin/pkill}"
TCCUTIL="${COMMAND_UNINSTALL_TCCUTIL:-/usr/bin/tccutil}"
DEFAULTS="${COMMAND_UNINSTALL_DEFAULTS:-/usr/bin/defaults}"
LOG="${COMMAND_UNINSTALL_LOG:-/tmp/command-uninstall.log}"

log() { print -r -- "[uninstall] $*" | tee -a "$LOG"; }
safe_remove() {
  local target_path="$1"
  [ -e "$target_path" ] || [ -L "$target_path" ] || return 0
  rm -rf -- "$target_path"
  log "removed $target_path"
}

: > "$LOG"
log "stopping Command"
"$LAUNCHCTL" bootout "gui/${UID_NUM}/${LABEL}" >/dev/null 2>&1 || true
"$LAUNCHCTL" bootout "gui/${UID_NUM}/${LABEL}.clipwatch" >/dev/null 2>&1 || true
"$PKILL" -x Command >/dev/null 2>&1 || true
"$PKILL" -x ClaudeCommand >/dev/null 2>&1 || true
"$PKILL" -x CommandClipboardWatcher >/dev/null 2>&1 || true

safe_remove "${HOME}/Library/LaunchAgents/${LABEL}.plist"
safe_remove "${HOME}/Library/LaunchAgents/${LABEL}.clipwatch.plist"

SERVICE_NAMES=(
  "Claude - New" "Claude - Go" "Claude - Add" "Claude - Reformat" "Claude - To-Do"
  "Claude - Screenshot New" "Claude - Screenshot Go" "Claude - Screenshot Full"
  "Claude - Screenshot Add" "Claude - Clipboard History" "Claude - Comment"
  "Claude - Screenshot Comment" "Send to Claude — Comment" "Send to Claude — Go"
  "Fix Format (Claude)" "Send to Claude Code"
)
removed_service=false
for name in "${SERVICE_NAMES[@]}"; do
  service_path="${HOME}/Library/Services/${name}.workflow"
  if [ -e "$service_path" ]; then safe_remove "$service_path"; removed_service=true; fi
done
if $removed_service; then
  /System/Library/CoreServices/pbs -flush >/dev/null 2>&1 || true
  /System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true
fi

if $RESET_PERMISSIONS; then
  for service in Accessibility ScreenCapture Microphone; do
    "$TCCUTIL" reset "$service" "$LABEL" >>"$LOG" 2>&1 \
      && log "reset $service approval" \
      || log "could not reset $service approval"
  done
fi

if [ "$MODE" = "remove-data" ]; then
  "$DEFAULTS" delete "$LABEL" >/dev/null 2>&1 || true
  COMMAND_STATE_PATHS=(
    "${HOME}/.claude/state/command-hotkeys.json"
    "${HOME}/.claude/state/custom-actions.json"
    "${HOME}/.claude/state/built-in-compose.json"
    "${HOME}/.claude/state/command-templates.json"
    "${HOME}/.claude/state/enrichment-rules.json"
    "${HOME}/.claude/state/command-config.json"
    "${HOME}/.claude/state/clipboard.json"
    "${HOME}/.claude/state/last_copy.json"
    "${HOME}/.claude/state/command-agent.sock"
    "${HOME}/.claude/state/cliphistory"
  )
  for state_path in "${COMMAND_STATE_PATHS[@]}"; do safe_remove "$state_path"; done
  safe_remove "${HOME}/Library/Application Support/claude-command"
  safe_remove "${HOME}/Library/Application Support/DictationLab"
  safe_remove "${HOME}/Library/Caches/${LABEL}"
  safe_remove "${HOME}/Library/Saved Application State/${LABEL}.savedState"
  safe_remove "${HOME}/Library/Preferences/${LABEL}.plist"
  safe_remove "${HOME}/Library/Logs/claude-command.log"
  safe_remove "${HOME}/.claude/logs/command-agent.err"
  safe_remove "${HOME}/.claude/logs/command-agent.out"
  safe_remove "${HOME}/.claude/logs/clipwatch.err"
  safe_remove "${HOME}/.claude/logs/clipwatch.out"
  safe_remove "${HOME}/Command-clean-install-backups"
  log "removed Command settings and history; unrelated Claude data preserved"
else
  log "kept Command settings and history"
fi

APP_PATHS=("${HOME}/Applications/Command.app" "${HOME}/Applications/ClaudeCommand.app")
[ -n "$APP_PATH" ] && APP_PATHS=("$APP_PATH" "${APP_PATHS[@]}")
for app_path in "${APP_PATHS[@]}"; do
  case "${app_path:t}" in
    Command.app|ClaudeCommand.app) safe_remove "$app_path" ;;
    *) log "refused unexpected app path: $app_path" ;;
  esac
done

log "complete"
