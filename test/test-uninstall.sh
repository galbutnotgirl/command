#!/bin/zsh
set -euo pipefail

DIR="${0:A:h:h}"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
HOME_DIR="${ROOT}/home"
CALLS="${ROOT}/calls.log"
mkdir -p "${HOME_DIR}/.claude/state/cliphistory" \
         "${HOME_DIR}/.claude/logs" \
         "${HOME_DIR}/Applications/Command.app" \
         "${HOME_DIR}/Library/LaunchAgents" \
         "${HOME_DIR}/Library/Application Support/claude-command" \
         "${HOME_DIR}/Library/Application Support/DictationLab" \
         "${HOME_DIR}/Library/Services/Claude - Add.workflow"
touch "${HOME_DIR}/.claude/state/command-hotkeys.json" \
      "${HOME_DIR}/.claude/state/custom-actions.json" \
      "${HOME_DIR}/.claude/state/unrelated-claude-state.json" \
      "${HOME_DIR}/.claude/logs/command-agent.err" \
      "${HOME_DIR}/.claude/logs/unrelated.log" \
      "${HOME_DIR}/Library/LaunchAgents/com.claudecommand.plist"

for tool in launchctl pkill tccutil defaults; do
  cat > "${ROOT}/${tool}" <<'STUB'
#!/bin/zsh
print -r -- "${0:t} $*" >> "$COMMAND_TEST_CALLS"
STUB
  chmod +x "${ROOT}/${tool}"
done

HOME="$HOME_DIR" COMMAND_TEST_CALLS="$CALLS" \
COMMAND_UNINSTALL_LAUNCHCTL="${ROOT}/launchctl" \
COMMAND_UNINSTALL_PKILL="${ROOT}/pkill" \
COMMAND_UNINSTALL_TCCUTIL="${ROOT}/tccutil" \
COMMAND_UNINSTALL_DEFAULTS="${ROOT}/defaults" \
COMMAND_UNINSTALL_LOG="${ROOT}/uninstall.log" \
zsh "${DIR}/uninstall-command.sh" --remove-data \
  --app-path "${HOME_DIR}/Applications/Command.app" >/dev/null

fail() { print -u2 -- "FAIL: $1"; exit 1; }
[ ! -e "${HOME_DIR}/Applications/Command.app" ] || fail "app remains"
[ ! -e "${HOME_DIR}/Library/LaunchAgents/com.claudecommand.plist" ] || fail "LaunchAgent remains"
[ ! -e "${HOME_DIR}/.claude/state/command-hotkeys.json" ] || fail "Command settings remain"
[ ! -e "${HOME_DIR}/.claude/state/cliphistory" ] || fail "Clipboard History remains"
[ ! -e "${HOME_DIR}/Library/Application Support/DictationLab" ] || fail "dictation data remains"
[ -e "${HOME_DIR}/.claude/state/unrelated-claude-state.json" ] || fail "unrelated Claude state removed"
[ -e "${HOME_DIR}/.claude/logs/unrelated.log" ] || fail "unrelated Claude log removed"
grep -q 'tccutil reset Accessibility com.claudecommand' "$CALLS" || fail "Accessibility reset missing"
grep -q 'tccutil reset ScreenCapture com.claudecommand' "$CALLS" || fail "Screen Recording reset missing"
grep -q 'tccutil reset Microphone com.claudecommand' "$CALLS" || fail "Microphone reset missing"
grep -q 'defaults delete com.claudecommand' "$CALLS" || fail "preferences reset missing"

mkdir -p "${HOME_DIR}/Applications/Command.app" "${HOME_DIR}/.claude/state/cliphistory"
touch "${HOME_DIR}/.claude/state/command-hotkeys.json"
HOME="$HOME_DIR" COMMAND_TEST_CALLS="$CALLS" \
COMMAND_UNINSTALL_LAUNCHCTL="${ROOT}/launchctl" \
COMMAND_UNINSTALL_PKILL="${ROOT}/pkill" \
COMMAND_UNINSTALL_TCCUTIL="${ROOT}/tccutil" \
COMMAND_UNINSTALL_DEFAULTS="${ROOT}/defaults" \
COMMAND_UNINSTALL_LOG="${ROOT}/uninstall-keep.log" \
zsh "${DIR}/uninstall-command.sh" --keep-data \
  --app-path "${HOME_DIR}/Applications/Command.app" >/dev/null
[ ! -e "${HOME_DIR}/Applications/Command.app" ] || fail "keep-data app remains"
[ -e "${HOME_DIR}/.claude/state/command-hotkeys.json" ] || fail "keep-data removed settings"
[ -e "${HOME_DIR}/.claude/state/cliphistory" ] || fail "keep-data removed Clipboard History"
grep -q 'kept Command settings and history' "${ROOT}/uninstall-keep.log" || fail "keep-data result missing"

print -- "uninstall tests: passed (full removal and keep-data modes)"
