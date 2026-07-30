#!/bin/zsh
emulate -L zsh
set -uo pipefail

DIR="${0:A:h:h}"
INSTALLER="${DIR}/install-agent.sh"
TMP_ROOT="$(mktemp -d)"
FAKE_HOME="${TMP_ROOT}/home"
FAKE_BIN="${TMP_ROOT}/bin"
SOURCE_APP="${TMP_ROOT}/source/Command.app"
DEFAULTS_LOG="${TMP_ROOT}/defaults.log"
LIFECYCLE_LOG="${TMP_ROOT}/lifecycle.log"
RSYNC_STATE="${TMP_ROOT}/rsync-state"
PASS=0
FAIL=0
trap 'rm -rf "$TMP_ROOT"' EXIT

ok() { print -- "ok - $1"; PASS=$((PASS + 1)); }
not_ok() { print -- "not ok - $1: $2"; FAIL=$((FAIL + 1)); }

assert_true() {
  local name="$1"
  shift
  if "$@"; then ok "$name"; else not_ok "$name" "condition failed"; fi
}

assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    ok "$name"
  else
    not_ok "$name" "missing '$needle'; output: ${haystack}"
  fi
}

assert_not_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then ok "$name"; else not_ok "$name" "unexpected '$needle'"; fi
}

mkdir -p "$FAKE_BIN" "$SOURCE_APP/Contents/MacOS"
cat > "$SOURCE_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Command</string>
  <key>CFBundleIdentifier</key><string>com.claudecommand</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>9.9.9-test</string>
</dict></plist>
PLIST
print '#!/bin/sh\nexit 0' > "$SOURCE_APP/Contents/MacOS/Command"
chmod +x "$SOURCE_APP/Contents/MacOS/Command"
codesign --force --sign - --identifier com.claudecommand "$SOURCE_APP" >/dev/null 2>&1

cat > "$FAKE_BIN/launchctl" <<'SH'
#!/bin/sh
printf 'launchctl %s\n' "$*" >> "$COMMAND_TEST_LIFECYCLE_LOG"
exit 0
SH
cat > "$FAKE_BIN/pkill" <<'SH'
#!/bin/sh
printf 'pkill %s\n' "$*" >> "$COMMAND_TEST_LIFECYCLE_LOG"
exit 0
SH
cat > "$FAKE_BIN/pgrep" <<'SH'
#!/bin/sh
printf 'pgrep %s\n' "$*" >> "$COMMAND_TEST_LIFECYCLE_LOG"
[ "${COMMAND_TEST_PGREP_RUNNING:-0}" = "1" ] && exit 0
exit 1
SH
cat > "$FAKE_BIN/rsync" <<'SH'
#!/bin/sh
printf 'rsync %s\n' "$*" >> "$COMMAND_TEST_LIFECYCLE_LOG"
/usr/bin/rsync "$@"
rc=$?
if [ "$rc" -eq 0 ] && [ "${COMMAND_TEST_RSYNC_FAIL:-0}" = "1" ] && [ ! -e "$COMMAND_TEST_RSYNC_STATE" ]; then
  : > "$COMMAND_TEST_RSYNC_STATE"
  exit 1
fi
exit "$rc"
SH
cat > "$FAKE_BIN/defaults" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$COMMAND_TEST_DEFAULTS_LOG"
if [ "$1" = "read" ]; then
  [ "${COMMAND_TEST_DEFAULTS_EXIST:-0}" = "1" ] && exit 0
  exit 1
fi
exit 0
SH
chmod +x "$FAKE_BIN/launchctl" "$FAKE_BIN/pkill" "$FAKE_BIN/pgrep" "$FAKE_BIN/rsync" "$FAKE_BIN/defaults"

run_install() {
  HOME="$FAKE_HOME" \
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  COMMAND_SOURCE_APP="$SOURCE_APP" \
  COMMAND_SKIP_LSREGISTER=1 \
  COMMAND_TEST_DEFAULTS_LOG="$DEFAULTS_LOG" \
  COMMAND_TEST_LIFECYCLE_LOG="$LIFECYCLE_LOG" \
  COMMAND_TEST_PGREP_RUNNING="${2:-0}" \
  COMMAND_TEST_RSYNC_FAIL="${3:-0}" \
  COMMAND_TEST_RSYNC_STATE="$RSYNC_STATE" \
  COMMAND_STOP_WAIT_ATTEMPTS=0 \
  COMMAND_SOCKET_WAIT_ATTEMPTS="${6:-0}" \
  COMMAND_ALLOW_TCC_IDENTITY_CHANGE="${4:-0}" \
  COMMAND_CLEAN_INSTALL="${5:-0}" \
  COMMAND_TEST_DEFAULTS_EXIST="${1:-0}" \
  zsh "$INSTALLER" 2>&1
}

FRESH_OUTPUT="$(run_install 0)"
FRESH_DEFAULTS="$(cat "$DEFAULTS_LOG")"
assert_true "fresh install copies app" test -x "$FAKE_HOME/Applications/Command.app/Contents/MacOS/Command"
assert_true "fresh install writes LaunchAgent" test -f "$FAKE_HOME/Library/LaunchAgents/com.claudecommand.plist"
assert_contains "fresh install defaults Clipboard History off" "write com.claudecommand cliphistoryEnabled -bool false" "$FRESH_DEFAULTS"
assert_contains "fresh install clears onboarding completion" "delete com.claudecommand onboardingCompleted" "$FRESH_DEFAULTS"
assert_contains "fresh install reports onboarding" "fresh install — onboarding will run on first launch" "$FRESH_OUTPUT"

mkdir -p \
  "$FAKE_HOME/.claude/state/cliphistory" \
  "$FAKE_HOME/Library/Application Support/DictationLab" \
  "$FAKE_HOME/Library/Application Support/claude-command/command-history"
print 'custom-actions-sentinel' > "$FAKE_HOME/.claude/state/custom-actions.json"
print 'hotkeys-sentinel' > "$FAKE_HOME/.claude/state/command-hotkeys.json"
print 'vocabulary-sentinel' > "$FAKE_HOME/Library/Application Support/DictationLab/vocabulary.json"
print 'background-settings-sentinel' > "$FAKE_HOME/Library/Application Support/claude-command/settings.json"
print 'command-history-sentinel' > "$FAKE_HOME/Library/Application Support/claude-command/command-history/item.json"
print 'clipboard-history-sentinel' > "$FAKE_HOME/.claude/state/cliphistory/index.json"

: > "$DEFAULTS_LOG"
: > "$LIFECYCLE_LOG"
INCREMENTAL_OUTPUT="$(run_install 1)"
INCREMENTAL_DEFAULTS="$(cat "$DEFAULTS_LOG")"
INCREMENTAL_LIFECYCLE="$(cat "$LIFECYCLE_LOG")"
assert_contains "incremental install updates in place" "updated in-place" "$INCREMENTAL_OUTPUT"
assert_not_contains "incremental install preserves onboarding" "delete com.claudecommand onboardingCompleted" "$INCREMENTAL_DEFAULTS"
assert_not_contains "incremental install preserves Clipboard History preference" "write com.claudecommand cliphistoryEnabled" "$INCREMENTAL_DEFAULTS"
assert_contains "incremental install preserves custom actions" "custom-actions-sentinel" "$(cat "$FAKE_HOME/.claude/state/custom-actions.json")"
assert_contains "incremental install preserves hotkeys" "hotkeys-sentinel" "$(cat "$FAKE_HOME/.claude/state/command-hotkeys.json")"
assert_contains "incremental install preserves vocabulary" "vocabulary-sentinel" "$(cat "$FAKE_HOME/Library/Application Support/DictationLab/vocabulary.json")"
assert_contains "incremental install preserves background settings" "background-settings-sentinel" "$(cat "$FAKE_HOME/Library/Application Support/claude-command/settings.json")"
assert_contains "incremental install preserves command history" "command-history-sentinel" "$(cat "$FAKE_HOME/Library/Application Support/claude-command/command-history/item.json")"
assert_contains "incremental install preserves Clipboard History data" "clipboard-history-sentinel" "$(cat "$FAKE_HOME/.claude/state/cliphistory/index.json")"
assert_contains "incremental install stops legacy Command clipwatch" \
  "pkill -f /Command\\.app/Contents/Resources/clipwatch\\.py$" "$INCREMENTAL_LIFECYCLE"
assert_contains "incremental install stops legacy ClaudeCommand clipwatch" \
  "pkill -f /ClaudeCommand\\.app/Contents/Resources/clipwatch\\.py$" "$INCREMENTAL_LIFECYCLE"
LIFECYCLE_ORDER="$(print -r -- "$INCREMENTAL_LIFECYCLE" | awk '
  /^launchctl bootout / && !bootout { bootout=NR }
  /^pkill -x Command$/ && !pkill { pkill=NR }
  /^rsync / && !rsync { rsync=NR }
  END { print bootout ":" pkill ":" rsync }
')"
assert_true "incremental install stops launchd and Command before bundle sync" \
  zsh -c 'IFS=: read -r bootout pkill rsync <<< "$1"; (( bootout > 0 && pkill > bootout && rsync > pkill ))' _ "$LIFECYCLE_ORDER"

/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 9.9.10-test' "$SOURCE_APP/Contents/Info.plist"
mkdir -p "$SOURCE_APP/Contents/Resources"
print -- "new-build-only" > "$SOURCE_APP/Contents/Resources/new-build-only.txt"
codesign --force --sign - --identifier com.claudecommand "$SOURCE_APP" >/dev/null 2>&1
mkdir -p "$FAKE_HOME/.claude/state"
print -- "stale socket marker" > "$FAKE_HOME/.claude/state/command-agent.sock"
READINESS_APP_INODE="$(stat -f %i "$FAKE_HOME/Applications/Command.app")"
: > "$LIFECYCLE_LOG"
# Ad-hoc fixture signatures include content hash, so permit identity change only
# inside this isolated test. Real qualification forbids this override.
READINESS_OUTPUT="$(run_install 1 0 0 1 1 1)"
READINESS_STATUS=$?
assert_true "startup readiness failure returns nonzero" test "$READINESS_STATUS" -ne 0
assert_contains "startup readiness failure restores previous app" \
  "new Command process did not answer ping; previous app restored" "$READINESS_OUTPUT"
READINESS_RESTORED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$FAKE_HOME/Applications/Command.app/Contents/Info.plist")"
assert_true "startup readiness rollback restores previous version" test "$READINESS_RESTORED_VERSION" = "9.9.9-test"
assert_true "startup readiness rollback preserves app directory identity" \
  test "$(stat -f %i "$FAKE_HOME/Applications/Command.app")" = "$READINESS_APP_INODE"
assert_true "startup readiness rollback removes new-only files" \
  test ! -e "$FAKE_HOME/Applications/Command.app/Contents/Resources/new-build-only.txt"
assert_true "installer removes stale socket before launch" test ! -e "$FAKE_HOME/.claude/state/command-agent.sock"
rm -rf "$SOURCE_APP"
/usr/bin/ditto "$FAKE_HOME/Applications/Command.app" "$SOURCE_APP"

: > "$LIFECYCLE_LOG"
STUCK_OUTPUT="$(run_install 1 1)"
STUCK_STATUS=$?
assert_true "incremental install cancels when Command does not stop" test "$STUCK_STATUS" -ne 0
assert_contains "stuck-process failure is actionable" "did not stop; install canceled" "$STUCK_OUTPUT"
assert_not_contains "stuck process prevents bundle sync" "rsync " "$(cat "$LIFECYCLE_LOG")"

/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 9.9.10-test' "$SOURCE_APP/Contents/Info.plist"
codesign --force --sign - --identifier com.claudecommand "$SOURCE_APP" >/dev/null 2>&1
: > "$LIFECYCLE_LOG"
rm -f "$RSYNC_STATE"
COPY_FAILURE_OUTPUT="$(run_install 1 0 1 1 1)"
COPY_FAILURE_STATUS=$?
assert_true "incremental install reports partial copy failure" test "$COPY_FAILURE_STATUS" -ne 0
assert_contains "partial copy failure restores previous app" "previous app restored" "$COPY_FAILURE_OUTPUT"
RESTORED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$FAKE_HOME/Applications/Command.app/Contents/Info.plist")"
assert_true "rollback keeps previous installed version" test "$RESTORED_VERSION" = "9.9.9-test"
assert_true "rollback restores valid previous signature" /usr/bin/codesign --verify --deep --strict "$FAKE_HOME/Applications/Command.app"

codesign --force --sign - --identifier com.example.different "$FAKE_HOME/Applications/Command.app" >/dev/null 2>&1
: > "$LIFECYCLE_LOG"
MISMATCH_OUTPUT="$(run_install 1)"
MISMATCH_STATUS=$?
assert_true "incremental install rejects signing identity change" test "$MISMATCH_STATUS" -ne 0
assert_contains "identity rejection explains permission protection" "install stopped to preserve macOS permissions" "$MISMATCH_OUTPUT"
assert_not_contains "identity rejection leaves running app untouched" "launchctl bootout" "$(cat "$LIFECYCLE_LOG")"

: > "$LIFECYCLE_LOG"
OVERRIDE_ONLY_OUTPUT="$(run_install 1 0 0 1)"
OVERRIDE_ONLY_STATUS=$?
assert_true "identity override alone cannot bypass permission protection" test "$OVERRIDE_ONLY_STATUS" -ne 0
assert_not_contains "rejected identity override leaves running app untouched" "launchctl bootout" "$(cat "$LIFECYCLE_LOG")"

: > "$LIFECYCLE_LOG"
EXPLICIT_CLEAN_OUTPUT="$(run_install 1 0 0 1 1)"
assert_contains "explicit clean install may accept identity change" "updated in-place" "$EXPLICIT_CLEAN_OUTPUT"

print -- ""
print -- "install state tests: ${PASS} passed, ${FAIL} failed"
(( FAIL == 0 ))
