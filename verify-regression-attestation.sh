#!/bin/zsh
# Verify signed app metadata matches bundled full-regression attestation.
emulate -L zsh
set -uo pipefail
setopt extendedglob

if (( $# != 1 )); then
  print -u2 -- "usage: verify-regression-attestation.sh APP"
  exit 64
fi

APP="${1:A}"
INFO="${APP}/Contents/Info.plist"
ATTESTATION="${APP}/Contents/Resources/regression-gates-attestation.json"
fail() { print -u2 -- "FAIL: $1"; exit 1; }
json_value() { /usr/bin/plutil -extract "$1" raw -o - "$ATTESTATION" 2>/dev/null; }

[[ -f "$INFO" ]] || fail "app metadata missing"
[[ -f "$ATTESTATION" ]] || fail "regression attestation missing"

SCHEMA="$(json_value schemaVersion)" || fail "regression attestation is unreadable"
RESULT="$(json_value result)" || fail "regression attestation result missing"
SUITE="$(json_value suite)" || fail "regression attestation suite missing"
COMMIT="$(json_value commit)" || fail "regression attestation commit missing"
BRANCH="$(json_value branch)" || fail "regression attestation branch missing"
VERSION="$(json_value version)" || fail "regression attestation version missing"
GENERATED_AT="$(json_value generatedAt)" || fail "regression attestation timestamp missing"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO" 2>/dev/null)"
BUILD_MARKER="$(/usr/libexec/PlistBuddy -c 'Print :ClaudeCommandGitBranch' "$INFO" 2>/dev/null)"

[[ "$SCHEMA" == "1" ]] || fail "regression attestation schema is unsupported"
[[ "$RESULT" == "passed" && "$SUITE" == "command-full-regression-v1" ]] \
  || fail "build did not pass required regression gates"
[[ ${#COMMIT} -eq 40 && "$COMMIT" == [0-9a-f]## ]] \
  || fail "regression attestation commit is invalid"
[[ -n "$BRANCH" && -n "$VERSION" ]] || fail "regression attestation identity is incomplete"
[[ "$VERSION" == "$APP_VERSION" ]] || fail "regression attestation version does not match app metadata"
[[ "${BRANCH}@${COMMIT[1,7]}" == "$BUILD_MARKER" ]] \
  || fail "regression attestation commit does not match app metadata"
[[ "$GENERATED_AT" == <->-<->-<->T* ]] || fail "regression attestation timestamp is invalid"

typeset -a GATE_VALUES
typeset -A SEEN_GATES
GATE_INDEX=0
while GATE_VALUE="$(json_value "requiredGates.${GATE_INDEX}")"; do
  [[ -n "$GATE_VALUE" ]] || fail "regression attestation contains empty gate"
  [[ -z "${SEEN_GATES[$GATE_VALUE]-}" ]] || fail "regression attestation contains duplicate gate: ${GATE_VALUE}"
  GATE_VALUES+=("$GATE_VALUE")
  SEEN_GATES[$GATE_VALUE]=1
  GATE_INDEX=$((GATE_INDEX + 1))
done
(( ${#GATE_VALUES} > 0 )) || fail "regression attestation gates are unreadable"
for gate in \
  regression-impact regression-contracts swift dictation-delivery dictation-insert dictation-watchdog clipboard-watcher node assistant-contract shell \
  build-transaction release-transaction install-state state-preservation uninstall updater-swap restart release-policy \
  qualification-orchestration qualification-report regression-attestation static-analysis docs pages \
  string-review dictation-model; do
  [[ -n "${SEEN_GATES[$gate]-}" ]] || fail "regression attestation missing gate: ${gate}"
done

print -- "regression attestation passed"
print -- "  commit: ${COMMIT}"
print -- "  version: ${VERSION}"
print -- "  gates: 25"
