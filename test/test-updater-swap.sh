#!/bin/zsh
emulate -L zsh
set -uo pipefail

DIR="${0:A:h:h}"
SWAPPER="${DIR}/update-swap.sh"
PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

ok() { print -- "ok - $1"; PASS=$((PASS + 1)); }
not_ok() { print -- "not ok - $1: $2"; FAIL=$((FAIL + 1)); }

assert_eq() {
  local name="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then ok "$name"; else not_ok "$name" "got '$actual', expected '$expected'"; fi
}

assert_status() {
  local name="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then ok "$name"; else not_ok "$name" "status $actual, expected $expected"; fi
}

assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then ok "$name"; else not_ok "$name" "missing '$needle'"; fi
}

assert_not_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then ok "$name"; else not_ok "$name" "unexpected '$needle'"; fi
}

make_app() {
  local app_path="$1" version="$2" bundle_id="${3:-com.claudecommand}"
  mkdir -p "$app_path/Contents/MacOS"
  cat > "$app_path/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Command</string>
  <key>CFBundleIdentifier</key><string>${bundle_id}</string>
  <key>CFBundleName</key><string>Command</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
</dict></plist>
PLIST
  print '#!/bin/sh\nexit 0' > "$app_path/Contents/MacOS/Command"
  chmod +x "$app_path/Contents/MacOS/Command"
  codesign --force --sign - --identifier "$bundle_id" "$app_path" >/dev/null 2>&1
}

version_of() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null
}

chmod +x "$SWAPPER"
TEST_REQUIREMENT='identifier "com.claudecommand"'

# Paths intentionally contain spaces and a quote. Swapper receives argv rather
# than interpolating values into generated shell source.
SUCCESS_ROOT="${TMP_ROOT}/path with spaces and 'quote"
SUCCESS_DEST="${SUCCESS_ROOT}/Applications/Command.app"
SUCCESS_NEW="${SUCCESS_ROOT}/download/Command.app"
make_app "$SUCCESS_DEST" "1.0.0"
make_app "$SUCCESS_NEW" "2.0.0"
HOME="${TMP_ROOT}/home" zsh "$SWAPPER" 999999 "$SUCCESS_NEW" "$SUCCESS_DEST" \
  com.claudecommand 2.0.0 "$TEST_REQUIREMENT" 0 >/dev/null 2>&1
assert_status "valid update installs" "$?" 0
assert_eq "valid update replaces version" "$(version_of "$SUCCESS_DEST")" "2.0.0"
assert_eq "valid update removes backup" "$([[ -e "${SUCCESS_DEST}.old" ]] && print yes || print no)" "no"

ROLLBACK_ROOT="${TMP_ROOT}/version rollback"
ROLLBACK_DEST="${ROLLBACK_ROOT}/Applications/Command.app"
ROLLBACK_NEW="${ROLLBACK_ROOT}/download/Command.app"
make_app "$ROLLBACK_DEST" "1.0.0"
make_app "$ROLLBACK_NEW" "9.9.9"
set +e
HOME="${TMP_ROOT}/home" zsh "$SWAPPER" 999999 "$ROLLBACK_NEW" "$ROLLBACK_DEST" \
  com.claudecommand 2.0.0 "$TEST_REQUIREMENT" 0 >/dev/null 2>&1
ROLLBACK_STATUS="$?"
set -e
assert_status "version mismatch fails" "$ROLLBACK_STATUS" 1
assert_eq "version mismatch restores prior app" "$(version_of "$ROLLBACK_DEST")" "1.0.0"
assert_eq "version rollback removes backup" "$([[ -e "${ROLLBACK_DEST}.old" ]] && print yes || print no)" "no"

SIGNATURE_ROOT="${TMP_ROOT}/signature rollback"
SIGNATURE_DEST="${SIGNATURE_ROOT}/Applications/Command.app"
SIGNATURE_NEW="${SIGNATURE_ROOT}/download/Command.app"
make_app "$SIGNATURE_DEST" "1.0.0"
make_app "$SIGNATURE_NEW" "2.0.0"
print '# invalidates signature' >> "$SIGNATURE_NEW/Contents/MacOS/Command"
set +e
HOME="${TMP_ROOT}/home" zsh "$SWAPPER" 999999 "$SIGNATURE_NEW" "$SIGNATURE_DEST" \
  com.claudecommand 2.0.0 "$TEST_REQUIREMENT" 0 >/dev/null 2>&1
SIGNATURE_STATUS="$?"
set -e
assert_status "signature mismatch fails" "$SIGNATURE_STATUS" 1
assert_eq "signature mismatch restores prior app" "$(version_of "$SIGNATURE_DEST")" "1.0.0"

RESTART_ROOT="${TMP_ROOT}/launchd restart"
RESTART_DEST="${RESTART_ROOT}/Applications/Command.app"
RESTART_NEW="${RESTART_ROOT}/download/Command.app"
RESTART_LOG="${RESTART_ROOT}/restart.log"
FAKE_LAUNCHCTL="${RESTART_ROOT}/launchctl"
FAKE_OPEN="${RESTART_ROOT}/open"
mkdir -p "$RESTART_ROOT"
make_app "$RESTART_DEST" "1.0.0"
make_app "$RESTART_NEW" "2.0.0"
cat > "$FAKE_LAUNCHCTL" <<'SH'
#!/bin/sh
printf 'launchctl %s\n' "$*" >> "$COMMAND_TEST_RESTART_LOG"
exit "${COMMAND_TEST_LAUNCHCTL_EXIT:-0}"
SH
cat > "$FAKE_OPEN" <<'SH'
#!/bin/sh
printf 'open %s\n' "$*" >> "$COMMAND_TEST_RESTART_LOG"
exit 0
SH
chmod +x "$FAKE_LAUNCHCTL" "$FAKE_OPEN"
COMMAND_LAUNCHCTL_BIN="$FAKE_LAUNCHCTL" COMMAND_OPEN_BIN="$FAKE_OPEN" \
  COMMAND_TEST_RESTART_LOG="$RESTART_LOG" HOME="${TMP_ROOT}/home" \
  zsh "$SWAPPER" 999999 "$RESTART_NEW" "$RESTART_DEST" \
  com.claudecommand 2.0.0 "$TEST_REQUIREMENT" 1 >/dev/null 2>&1
RESTART_OUTPUT="$(cat "$RESTART_LOG")"
assert_contains "successful update restarts loaded launchd job" "launchctl kickstart gui/$(id -u)/com.claudecommand" "$RESTART_OUTPUT"
assert_not_contains "successful launchd restart avoids detached open" "open " "$RESTART_OUTPUT"

FALLBACK_ROOT="${TMP_ROOT}/open fallback"
FALLBACK_DEST="${FALLBACK_ROOT}/Applications/Command.app"
FALLBACK_NEW="${FALLBACK_ROOT}/download/Command.app"
: > "$RESTART_LOG"
make_app "$FALLBACK_DEST" "1.0.0"
make_app "$FALLBACK_NEW" "2.0.0"
COMMAND_LAUNCHCTL_BIN="$FAKE_LAUNCHCTL" COMMAND_OPEN_BIN="$FAKE_OPEN" \
  COMMAND_TEST_LAUNCHCTL_EXIT=1 COMMAND_TEST_RESTART_LOG="$RESTART_LOG" HOME="${TMP_ROOT}/home" \
  zsh "$SWAPPER" 999999 "$FALLBACK_NEW" "$FALLBACK_DEST" \
  com.claudecommand 2.0.0 "$TEST_REQUIREMENT" 1 >/dev/null 2>&1
assert_contains "update falls back to open without loaded launchd job" "open $FALLBACK_DEST" "$(cat "$RESTART_LOG")"

print -- ""
print -- "updater swap tests: ${PASS} passed, ${FAIL} failed"
(( FAIL == 0 ))
