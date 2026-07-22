#!/bin/zsh
# Exercise release.sh's real zip/checksum transaction in an isolated fixture.
# Covers archive failure, pair-commit failure/rollback, and successful commit.
emulate -L zsh
set -uo pipefail

ROOT="${0:A:h:h}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/command-release-transaction.XXXXXX")"
TMP_ROOT="${TMP_ROOT:A}"
FIXTURE="${TMP_ROOT}/repo"
ARCHIVE_FAIL_BIN="${TMP_ROOT}/archive-fail-bin"
MOVE_FAIL_BIN="${TMP_ROOT}/move-fail-bin"
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
digest() { shasum -a 256 "$1" | awk '{ print $1 }'; }
no_staging() { [[ -z "$(find "$FIXTURE/dist" -maxdepth 1 -name '.command-release.*' -print -quit)" ]]; }

mkdir -p "$FIXTURE/Command.app/Contents/MacOS" "$FIXTURE/Command.app/Contents/Resources/docs" \
  "$FIXTURE/docs" "$FIXTURE/dist" "$ARCHIVE_FAIL_BIN" "$MOVE_FAIL_BIN"
cp "$ROOT/release.sh" "$FIXTURE/release.sh"
cp "$ROOT/VERSION" "$FIXTURE/VERSION"
VERSION="$(tr -d ' \t\n' < "$FIXTURE/VERSION")"
cp "$ROOT/README.md" "$FIXTURE/README.md"
cp "$ROOT/README.md" "$FIXTURE/Command.app/Contents/Resources/README.md"

DOC_ASSETS="$(sed -n 's/^[[:space:]]*for doc_asset in \(.*\); do$/\1/p' "$ROOT/build-agent.sh" | head -1)"
for asset in ${(z)DOC_ASSETS}; do
  cp "$ROOT/docs/$asset" "$FIXTURE/docs/$asset"
  cp "$ROOT/docs/$asset" "$FIXTURE/Command.app/Contents/Resources/docs/$asset"
done
for resource in send-to-claude.sh send-to-claude-lib.sh match-enrich-rule.py clipwatch.py \
  update-swap.sh restart-app.sh capture-handoff.sh \
  claude-command-capture/bin/submit-cli.js claude-command-capture/src/submit.js \
  claude-command-capture/src/runner.js claude-command-capture/src/submissions.js; do
  mkdir -p "$FIXTURE/Command.app/Contents/Resources/${resource:h}"
  print -r -- fixture > "$FIXTURE/Command.app/Contents/Resources/$resource"
done
print -r -- '#!/bin/zsh' > "$FIXTURE/Command.app/Contents/MacOS/Command"
chmod +x "$FIXTURE/Command.app/Contents/MacOS/Command"

cat > "$FIXTURE/Command.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>${VERSION}</string>
<key>CFBundleIdentifier</key><string>com.claudecommand</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST

cat > "$FIXTURE/build-agent.sh" <<'BUILD'
#!/bin/zsh
exit 0
BUILD
chmod +x "$FIXTURE/build-agent.sh"
ln -s /usr/bin/false "$ARCHIVE_FAIL_BIN/ditto"

cat > "$MOVE_FAIL_BIN/mv" <<'MOVE'
#!/bin/zsh
if [[ "$2" == "${FAIL_SHA_TARGET:-}" && ! -e "${FAIL_ONCE_MARKER:-}" ]]; then
  : > "$FAIL_ONCE_MARKER"
  exit 1
fi
exec /bin/mv "$@"
MOVE
chmod +x "$MOVE_FAIL_BIN/mv"

FINAL_ZIP="$FIXTURE/dist/Command-${VERSION}.zip"
FINAL_SHA="$FINAL_ZIP.sha256"
reset_old_assets() {
  print -r -- old-zip > "$FINAL_ZIP"
  print -r -- old-checksum > "$FINAL_SHA"
}

reset_old_assets
old_zip_digest="$(digest "$FINAL_ZIP")"
old_sha_digest="$(digest "$FINAL_SHA")"
set +e
PATH="$ARCHIVE_FAIL_BIN:$PATH" zsh "$FIXTURE/release.sh" --skip-checks >/dev/null 2>&1
archive_status=$?
set -e
check "archive failure returns nonzero" test "$archive_status" -ne 0
check "archive failure preserves previous zip" test "$(digest "$FINAL_ZIP")" = "$old_zip_digest"
check "archive failure preserves previous checksum" test "$(digest "$FINAL_SHA")" = "$old_sha_digest"
check "archive failure removes package staging" no_staging

reset_old_assets
old_zip_digest="$(digest "$FINAL_ZIP")"
old_sha_digest="$(digest "$FINAL_SHA")"
set +e
PATH="$MOVE_FAIL_BIN:$PATH" FAIL_SHA_TARGET="$FINAL_SHA" FAIL_ONCE_MARKER="$TMP_ROOT/mv-failed-once" \
  zsh "$FIXTURE/release.sh" --skip-checks >/dev/null 2>&1
move_status=$?
set -e
check "pair commit failure returns nonzero" test "$move_status" -ne 0
check "pair commit failure restores previous zip" test "$(digest "$FINAL_ZIP")" = "$old_zip_digest"
check "pair commit failure restores previous checksum" test "$(digest "$FINAL_SHA")" = "$old_sha_digest"
check "pair commit failure removes package staging" no_staging

reset_old_assets
old_zip_digest="$(digest "$FINAL_ZIP")"
zsh "$FIXTURE/release.sh" --skip-checks >/dev/null 2>&1
success_status=$?
check "successful package returns zero" test "$success_status" -eq 0
check "successful package replaces previous zip" test "$(digest "$FINAL_ZIP")" != "$old_zip_digest"
check "successful package writes valid checksum" zsh -c \
  'cd "$1" && shasum -a 256 -c "${2:t}" >/dev/null' _ "$FIXTURE/dist" "$FINAL_SHA"
check "successful package contains top-level app" zsh -c \
  '[[ "$(unzip -Z1 "$1" | head -1)" == Command.app/* ]]' _ "$FINAL_ZIP"
check "successful package removes package staging" no_staging

print -- "release transaction tests: ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]
