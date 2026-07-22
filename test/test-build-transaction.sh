#!/bin/zsh
# Exercise build-agent.sh's real staging/swap flow without compiling Command or
# accessing Keychain. Fake swift/codesign binaries make both signer outcomes
# deterministic inside an isolated fixture.
emulate -L zsh
set -uo pipefail

ROOT="${0:A:h:h}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/command-build-transaction.XXXXXX")"
FIXTURE="${TMP_ROOT}/repo"
FAKE_BIN="${TMP_ROOT}/bin"
trap 'rm -rf "$TMP_ROOT"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { print -u2 -- "not ok - $1"; fail=$((fail + 1)); }
check() {
  local label="$1"
  shift
  if "$@"; then ok; else bad "$label"; fi
}

mkdir -p "$FIXTURE/agent" "$FIXTURE/docs" "$FIXTURE/vendor/claude-command-capture/src" \
  "$FIXTURE/vendor/claude-command-capture/bin" "$FAKE_BIN"
cp "$ROOT/build-agent.sh" "$FIXTURE/build-agent.sh"
cp -R "$ROOT/docs/." "$FIXTURE/docs/"
cp "$ROOT/vendor/claude-command-capture/src/"*.js "$FIXTURE/vendor/claude-command-capture/src/"
cp "$ROOT/vendor/claude-command-capture/bin/"*.js "$FIXTURE/vendor/claude-command-capture/bin/"
for resource in send-to-claude.sh send-to-claude-lib.sh match-enrich-rule.py clipwatch.py \
  update-swap.sh restart-app.sh capture-handoff.sh README.md VERSION; do
  cp "$ROOT/$resource" "$FIXTURE/$resource"
done
print -r -- '// fixture' > "$FIXTURE/agent/main.swift"

cat > "$FAKE_BIN/swift" <<'SWIFT'
#!/bin/zsh
mkdir -p .build/release
print -r -- "${FAKE_BUILD_MARKER:-new-build}" > .build/release/ClaudeCommand
chmod +x .build/release/ClaudeCommand
SWIFT
chmod +x "$FAKE_BIN/swift"

cat > "$FAKE_BIN/codesign" <<'CODESIGN'
#!/bin/zsh
if [[ " $* " == *" -dr "* ]]; then
  print -u2 -- 'designated => identifier "com.claudecommand" and certificate leaf = H"fixture"'
  exit 0
fi
if [[ "${FAKE_CODESIGN_FAIL:-0}" == "1" ]]; then
  exit 1
fi
app="${@: -1}"
mkdir -p "$app/Contents/_CodeSignature"
print -r -- signed > "$app/Contents/_CodeSignature/CodeResources"
CODESIGN
chmod +x "$FAKE_BIN/codesign"

cat > "$FAKE_BIN/mv" <<'MOVE'
#!/bin/zsh
if [[ "${FAKE_MV_SIGNAL:-0}" == "1" && "$1" == */.command-build.*/Command.app && "$2" == */Command.app ]]; then
  kill -TERM "$PPID"
  sleep 0.1
  exit 1
fi
exec /bin/mv "$@"
MOVE
chmod +x "$FAKE_BIN/mv"

mkdir -p "$FIXTURE/Command.app/Contents/MacOS"
print -r -- old-build > "$FIXTURE/Command.app/Contents/MacOS/Command"
print -r -- keep > "$FIXTURE/Command.app/Contents/previous-marker"

set +e
PATH="$FAKE_BIN:$PATH" SIGN_ID=Fixture FAKE_CODESIGN_FAIL=1 \
  zsh "$FIXTURE/build-agent.sh" >/dev/null 2>&1
failure_status=$?
set -e

check "failed signing returns nonzero" test "$failure_status" -ne 0
check "failed signing preserves previous marker" test -f "$FIXTURE/Command.app/Contents/previous-marker"
check "failed signing preserves previous executable" grep -qx old-build "$FIXTURE/Command.app/Contents/MacOS/Command"
check "failed signing removes staging directory" zsh -c \
  '[[ -z "$(find "$1" -maxdepth 1 -name ".command-build.*" -print -quit)" ]]' _ "$FIXTURE"

set +e
PATH="$FAKE_BIN:$PATH" SIGN_ID=Fixture FAKE_MV_SIGNAL=1 \
  zsh "$FIXTURE/build-agent.sh" >/dev/null 2>&1
signal_status=$?
set -e
check "interrupted app swap returns nonzero" test "$signal_status" -ne 0
check "interrupted app swap restores previous marker" test -f "$FIXTURE/Command.app/Contents/previous-marker"
check "interrupted app swap restores previous executable" grep -qx old-build "$FIXTURE/Command.app/Contents/MacOS/Command"
check "interrupted app swap removes staging directory" zsh -c \
  '[[ -z "$(find "$1" -maxdepth 1 -name ".command-build.*" -print -quit)" ]]' _ "$FIXTURE"
check "interrupted app swap removes backup directory" zsh -c \
  '[[ -z "$(find "$1" -maxdepth 1 -name ".Command.app.previous.*" -print -quit)" ]]' _ "$FIXTURE"

PATH="$FAKE_BIN:$PATH" SIGN_ID=Fixture FAKE_BUILD_MARKER=committed-build \
  zsh "$FIXTURE/build-agent.sh" >/dev/null 2>&1
success_status=$?

check "successful signing returns zero" test "$success_status" -eq 0
check "successful signing installs staged executable" grep -qx committed-build "$FIXTURE/Command.app/Contents/MacOS/Command"
check "successful signing removes previous marker" test ! -e "$FIXTURE/Command.app/Contents/previous-marker"
check "successful signing installs signature marker" test -f "$FIXTURE/Command.app/Contents/_CodeSignature/CodeResources"
check "successful signing removes staging directory" zsh -c \
  '[[ -z "$(find "$1" -maxdepth 1 -name ".command-build.*" -print -quit)" ]]' _ "$FIXTURE"
check "successful signing removes backup directory" zsh -c \
  '[[ -z "$(find "$1" -maxdepth 1 -name ".Command.app.previous.*" -print -quit)" ]]' _ "$FIXTURE"

print -- "build transaction tests: ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]
