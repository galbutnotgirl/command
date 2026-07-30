#!/bin/zsh
emulate -L zsh
set -uo pipefail

ROOT="${0:A:h:h}"
VERIFIER="${ROOT}/verify-regression-attestation.sh"
TMP_ROOT="$(mktemp -d)"
APP="${TMP_ROOT}/Command.app"
INFO="${APP}/Contents/Info.plist"
ATTESTATION="${APP}/Contents/Resources/regression-gates-attestation.json"
PASS=0
FAIL=0
trap 'rm -rf "$TMP_ROOT"' EXIT

ok() { print -- "ok - $1"; PASS=$((PASS + 1)); }
not_ok() { print -- "not ok - $1: $2"; FAIL=$((FAIL + 1)); }
expect_pass() {
  local name="$1" output
  if output="$("$VERIFIER" "$APP" 2>&1)"; then ok "$name"; else not_ok "$name" "$output"; fi
}
expect_fail() {
  local name="$1" expected="$2" output rc
  set +e
  output="$("$VERIFIER" "$APP" 2>&1)"
  rc="$?"
  set -e
  if (( rc != 0 )) && [[ "$output" == *"$expected"* ]]; then
    ok "$name"
  else
    not_ok "$name" "status=$rc output=$output"
  fi
}

mkdir -p "${APP}/Contents/Resources"
cat > "$INFO" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleShortVersionString</key><string>1.2.3-test</string>
  <key>ClaudeCommandGitBranch</key><string>main@aaaaaaa</string>
</dict></plist>
PLIST

write_attestation() {
  local result="${1:-passed}" version="${2:-1.2.3-test}" commit="${3:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
  python3 - "$ATTESTATION" "$result" "$version" "$commit" <<'PY'
import json, pathlib, sys
gates = "regression-impact regression-contracts swift dictation-delivery dictation-insert dictation-watchdog clipboard-watcher node assistant-contract shell build-transaction release-transaction install-state state-preservation uninstall updater-swap restart release-policy qualification-orchestration qualification-report regression-attestation static-analysis docs pages string-review dictation-model".split()
pathlib.Path(sys.argv[1]).write_text(json.dumps({
    "schemaVersion": 1,
    "result": sys.argv[2],
    "suite": "command-full-regression-v1",
    "commit": sys.argv[4],
    "branch": "main",
    "version": sys.argv[3],
    "generatedAt": "2026-07-30T10:00:00Z",
    "requiredGates": gates,
}), encoding="utf-8")
PY
}

write_attestation
expect_pass "valid commit-bound regression attestation passes"

rm "$ATTESTATION"
expect_fail "missing attestation fails closed" "attestation missing"
write_attestation unqualified
expect_fail "unqualified result is rejected" "did not pass required regression gates"
write_attestation passed 9.9.9
expect_fail "version mismatch is rejected" "version does not match"
write_attestation passed 1.2.3-test bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
expect_fail "commit marker mismatch is rejected" "commit does not match"
write_attestation
python3 - "$ATTESTATION" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
data["requiredGates"].remove("dictation-model")
path.write_text(json.dumps(data))
PY
expect_fail "missing final-word gate is rejected" "missing gate: dictation-model"
write_attestation
python3 - "$ATTESTATION" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
data["requiredGates"].remove("state-preservation")
path.write_text(json.dumps(data))
PY
expect_fail "missing user-state gate is rejected" "missing gate: state-preservation"
write_attestation
python3 - "$ATTESTATION" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
data["requiredGates"].remove("dictation-watchdog")
path.write_text(json.dumps(data))
PY
expect_fail "missing dictation watchdog gate is rejected" "missing gate: dictation-watchdog"
write_attestation
python3 - "$ATTESTATION" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
data["requiredGates"].remove("dictation-insert")
path.write_text(json.dumps(data))
PY
expect_fail "missing dictation insert gate is rejected" "missing gate: dictation-insert"
write_attestation
python3 - "$ATTESTATION" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
data["requiredGates"].append(data["requiredGates"][0])
path.write_text(json.dumps(data))
PY
expect_fail "duplicate gate is rejected" "duplicate gate: regression-impact"
print '{broken' > "$ATTESTATION"
expect_fail "malformed attestation is rejected" "unreadable"

print -- ""
print -- "regression attestation verifier tests: ${PASS} passed, ${FAIL} failed"
(( FAIL == 0 ))
