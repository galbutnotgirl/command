#!/bin/zsh
emulate -L zsh
set -euo pipefail

ROOT="${0:A:h:h}"
QUALIFIER="${ROOT}/qualify-installed-build.sh"
TMP_ROOT="$(mktemp -d)"
FIXTURE="${TMP_ROOT}/repo"
FAKE_BIN="${TMP_ROOT}/steps"
LOG="${TMP_ROOT}/steps.log"
REPORT="${TMP_ROOT}/qualification.json"
PASS=0
FAIL=0
trap 'rm -rf "$TMP_ROOT"' EXIT

ok() { print -- "ok - $1"; PASS=$((PASS + 1)); }
not_ok() { print -u2 -- "not ok - $1: $2"; FAIL=$((FAIL + 1)); }
assert_true() {
  local name="$1"
  shift
  if "$@"; then ok "$name"; else not_ok "$name" "condition failed"; fi
}
assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then ok "$name"; else not_ok "$name" "missing ${needle}"; fi
}
assert_not_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then ok "$name"; else not_ok "$name" "unexpected ${needle}"; fi
}

mkdir -p "$FIXTURE" "$FAKE_BIN"
cp "$QUALIFIER" "$FIXTURE/qualify-installed-build.sh"
print -- "9.9.9-test" > "$FIXTURE/VERSION"
git -C "$FIXTURE" init -q
git -C "$FIXTURE" config user.email test@example.com
git -C "$FIXTURE" config user.name "Command Tests"
git -C "$FIXTURE" add VERSION qualify-installed-build.sh
git -C "$FIXTURE" commit -qm "fixture"

cat > "$FAKE_BIN/fake-step" <<'SH'
#!/bin/zsh
name="${0:t}"
print -- "${name} argc=$# clean=${COMMAND_CLEAN_INSTALL:-unset}" >> "$COMMAND_TEST_STEP_LOG"
[[ "${COMMAND_TEST_FAIL_STEP:-}" == "$name" ]] && exit 42
exit 0
SH
chmod +x "$FAKE_BIN/fake-step"
for name in release install identity hotkey dictation restart runtime model; do
  ln -s fake-step "$FAKE_BIN/$name"
done

IDENTITY_APP="${TMP_ROOT}/Command.app"
IDENTITY_COMMIT="$(git -C "$FIXTURE" rev-parse --short=7 HEAD)"
IDENTITY_BRANCH="$(git -C "$FIXTURE" rev-parse --abbrev-ref HEAD)"
mkdir -p "$IDENTITY_APP/Contents/MacOS"
cat > "$IDENTITY_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Command</string>
  <key>CFBundleIdentifier</key><string>com.claudecommand</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>9.9.9-test</string>
  <key>ClaudeCommandGitBranch</key><string>${IDENTITY_BRANCH}@${IDENTITY_COMMIT}</string>
</dict></plist>
PLIST
print '#!/bin/sh\nexit 0' > "$IDENTITY_APP/Contents/MacOS/Command"
chmod +x "$IDENTITY_APP/Contents/MacOS/Command"
codesign --force --sign - --identifier com.claudecommand "$IDENTITY_APP" >/dev/null 2>&1
IDENTITY_OUTPUT="$(COMMAND_SOURCE_ROOT="$FIXTURE" COMMAND_INSTALLED_APP="$IDENTITY_APP" \
  zsh "$ROOT/test/test-installed-build-identity.sh")"
assert_contains "installed identity accepts exact commit and version" "installed build identity passed" "$IDENTITY_OUTPUT"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 9.9.8-stale' "$IDENTITY_APP/Contents/Info.plist"
codesign --force --sign - --identifier com.claudecommand "$IDENTITY_APP" >/dev/null 2>&1
set +e
STALE_IDENTITY_OUTPUT="$(COMMAND_SOURCE_ROOT="$FIXTURE" COMMAND_INSTALLED_APP="$IDENTITY_APP" \
  zsh "$ROOT/test/test-installed-build-identity.sh" 2>&1)"
STALE_IDENTITY_STATUS=$?
set -e
assert_true "installed identity rejects stale build" test "$STALE_IDENTITY_STATUS" -ne 0
assert_contains "stale identity failure names expected version" "expected 9.9.9-test" "$STALE_IDENTITY_OUTPUT"

run_qualifier() {
  COMMAND_QUALIFY_REPORT_PATH="$REPORT" \
  COMMAND_QUALIFY_PROBE_RUNS=2 \
  COMMAND_QUALIFY_SOAK_SECONDS=3 \
  COMMAND_QUALIFY_RELEASE_SCRIPT="$FAKE_BIN/release" \
  COMMAND_QUALIFY_INSTALL_SCRIPT="$FAKE_BIN/install" \
  COMMAND_QUALIFY_IDENTITY_SCRIPT="$FAKE_BIN/identity" \
  COMMAND_QUALIFY_HOTKEY_SCRIPT="$FAKE_BIN/hotkey" \
  COMMAND_QUALIFY_DICTATION_SCRIPT="$FAKE_BIN/dictation" \
  COMMAND_QUALIFY_RESTART_SCRIPT="$FAKE_BIN/restart" \
  COMMAND_QUALIFY_RUNTIME_SCRIPT="$FAKE_BIN/runtime" \
  COMMAND_QUALIFY_MODEL_SCRIPT="$FAKE_BIN/model" \
  COMMAND_TEST_STEP_LOG="$LOG" \
  COMMAND_TEST_FAIL_STEP="${1:-}" \
  zsh "$FIXTURE/qualify-installed-build.sh" 2>&1
}

: > "$LOG"
SUCCESS_OUTPUT="$(run_qualifier)"
EXPECTED_ORDER=$'release argc=0 clean=unset\ninstall argc=0 clean=unset\nidentity argc=0 clean=unset\nhotkey argc=0 clean=unset\ndictation argc=0 clean=unset\nrestart argc=0 clean=unset\nhotkey argc=0 clean=unset\ndictation argc=0 clean=unset\nruntime argc=0 clean=unset\nmodel argc=0 clean=unset'
assert_true "qualification executes every step in fixed order" test "$(cat "$LOG")" = "$EXPECTED_ORDER"
assert_contains "qualification reports success" "[qualify] PASSED" "$SUCCESS_OUTPUT"
assert_true "success report binds exact fixture commit and ten passed steps" python3 - "$REPORT" "$FIXTURE" <<'PY'
import json, subprocess, sys
document = json.load(open(sys.argv[1], encoding="utf-8"))
commit = subprocess.check_output(["git", "-C", sys.argv[2], "rev-parse", "HEAD"], text=True).strip()
assert document["result"] == "passed"
assert document["commit"] == commit
assert document["installMode"] == "incremental"
assert document["publicReleasePublished"] is False
assert len(document["steps"]) == 10
assert all(step["status"] == "passed" for step in document["steps"])
PY

: > "$LOG"
set +e
FAILURE_OUTPUT="$(run_qualifier restart)"
FAILURE_STATUS=$?
set -e
assert_true "qualification propagates failing step status" test "$FAILURE_STATUS" -eq 42
assert_contains "qualification names failed restart step" "FAILED at Restart installed app" "$FAILURE_OUTPUT"
assert_not_contains "qualification stops before post-restart input probes" $'restart argc=0 clean=unset\nhotkey' "$(cat "$LOG")"
assert_true "failure report identifies failed step" python3 - "$REPORT" <<'PY'
import json, sys
document = json.load(open(sys.argv[1], encoding="utf-8"))
assert document["result"] == "failed"
assert document["failedStep"] == "Restart installed app"
assert document["exitCode"] == 42
assert document["steps"][-1]["status"] == "failed"
PY

: > "$LOG"
set +e
CLEAN_OUTPUT="$(COMMAND_CLEAN_INSTALL=1 run_qualifier)"
CLEAN_STATUS=$?
set -e
assert_true "qualification rejects clean install mode" test "$CLEAN_STATUS" -ne 0
assert_contains "clean install rejection is actionable" "clean install is forbidden" "$CLEAN_OUTPUT"
assert_true "clean install rejection occurs before any command" test ! -s "$LOG"

: > "$LOG"
set +e
UNQUALIFIED_OUTPUT="$(COMMAND_ALLOW_UNQUALIFIED_INSTALL=1 run_qualifier)"
UNQUALIFIED_STATUS=$?
set -e
assert_true "qualification rejects unqualified install override" test "$UNQUALIFIED_STATUS" -ne 0
assert_contains "unqualified override rejection is actionable" \
  "unqualified install override is forbidden" "$UNQUALIFIED_OUTPUT"
assert_true "unqualified override rejection occurs before any command" test ! -s "$LOG"

print -- "dirty" >> "$FIXTURE/VERSION"
: > "$LOG"
set +e
DIRTY_OUTPUT="$(run_qualifier)"
DIRTY_STATUS=$?
set -e
assert_true "qualification rejects uncommitted source" test "$DIRTY_STATUS" -ne 0
assert_contains "dirty source rejection explains commit binding" "working tree must be clean" "$DIRTY_OUTPUT"
assert_true "dirty source rejection occurs before any command" test ! -s "$LOG"

print -- ""
print -- "qualification orchestration tests: ${PASS} passed, ${FAIL} failed"
(( FAIL == 0 ))
