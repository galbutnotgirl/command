#!/bin/zsh
emulate -L zsh
set -euo pipefail

ROOT="${COMMAND_SOURCE_ROOT:-${0:A:h:h}}"
APP="${COMMAND_INSTALLED_APP:-${HOME}/Applications/Command.app}"
PLIST="${APP}/Contents/Info.plist"
EXPECTED_VERSION="$(tr -d ' \t\n' < "${ROOT}/VERSION")"
EXPECTED_COMMIT="$(git -C "$ROOT" rev-parse --short=7 HEAD)"
EXPECTED_BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
EXPECTED_BUILD="${EXPECTED_BRANCH}@${EXPECTED_COMMIT}"

fail() {
  print -u2 -- "FAIL: $1"
  exit 1
}

[[ -x "${APP}/Contents/MacOS/Command" ]] || fail "installed Command executable is missing"
[[ -f "$PLIST" ]] || fail "installed Command Info.plist is missing"
/usr/bin/codesign --verify --deep --strict "$APP" >/dev/null 2>&1 \
  || fail "installed Command signature is invalid"

installed_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null)"
installed_build="$(/usr/libexec/PlistBuddy -c 'Print :ClaudeCommandGitBranch' "$PLIST" 2>/dev/null)"
installed_bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST" 2>/dev/null)"

[[ "$installed_version" == "$EXPECTED_VERSION" ]] \
  || fail "installed version ${installed_version:-missing}, expected ${EXPECTED_VERSION}"
[[ "$installed_build" == "$EXPECTED_BUILD" ]] \
  || fail "installed build ${installed_build:-missing}, expected ${EXPECTED_BUILD}"
[[ "$installed_bundle" == "com.claudecommand" ]] \
  || fail "installed bundle id ${installed_bundle:-missing}, expected com.claudecommand"

print -- "installed build identity passed"
print -- "  version: ${installed_version}"
print -- "  build: ${installed_build}"
print -- "  bundle: ${installed_bundle}"
