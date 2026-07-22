#!/bin/zsh
# Fast policy checks for release signing/notarization flags. No build or network.
emulate -L zsh
set -uo pipefail

DIR="${0:A:h:h}"
RELEASE="${DIR}/release.sh"
PASS=0
FAIL=0

expect_ok() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    print -- "ok - $name"
    PASS=$((PASS + 1))
  else
    print -- "not ok - $name"
    FAIL=$((FAIL + 1))
  fi
}

expect_fail_with() {
  local name="$1" expected="$2"; shift 2
  local output
  output="$("$@" 2>&1)"
  if [ "$?" -ne 0 ] && [[ "$output" == *"$expected"* ]]; then
    print -- "ok - $name"
    PASS=$((PASS + 1))
  else
    print -- "not ok - $name"
    print -- "  expected failure containing: $expected"
    print -- "  output: $output"
    FAIL=$((FAIL + 1))
  fi
}

expect_ok "local package config does not require notarization" \
  "$RELEASE" --validate-config
expect_fail_with "publish requires notarization" "--publish requires --notarize" \
  "$RELEASE" --publish --validate-config
expect_ok "alpha publish allows explicit unnotarized override" \
  "$RELEASE" --publish --allow-unnotarized --validate-config
expect_fail_with "notarization requires keychain profile" "--notarize needs COMMAND_NOTARY_PROFILE" \
  env -u COMMAND_NOTARY_PROFILE "$RELEASE" --notarize --validate-config
expect_ok "notarization accepts explicit keychain profile" \
  "$RELEASE" --notarize --notary-profile=command-notary --validate-config
expect_fail_with "notarized and unnotarized modes conflict" "not both" \
  "$RELEASE" --notarize --allow-unnotarized --notary-profile=command-notary --validate-config
expect_fail_with "unknown release option is rejected" "unknown option" \
  "$RELEASE" --definitely-not-valid

print -- "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
