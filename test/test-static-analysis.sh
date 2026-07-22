#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

pass=0
fail=0

ok() {
  pass=$((pass + 1))
}

bad() {
  printf 'not ok - %s\n' "$1" >&2
  fail=$((fail + 1))
}

while IFS= read -r file; do
  [ -n "$file" ] || continue
  shebang="$(head -n 1 "$file" 2>/dev/null || true)"
  case "$shebang" in
    *zsh*) interpreter=/bin/zsh ;;
    *bash*) interpreter=/bin/bash ;;
    *) interpreter=/bin/sh ;;
  esac
  if "$interpreter" -n "$file"; then ok; else bad "shell syntax: $file"; fi
done < <(git ls-files '*.sh')

while IFS= read -r file; do
  [ -n "$file" ] || continue
  if python3 -c 'import pathlib, sys; compile(pathlib.Path(sys.argv[1]).read_bytes(), sys.argv[1], "exec")' "$file"; then
    ok
  else
    bad "Python syntax: $file"
  fi
done < <(git ls-files '*.py')

while IFS= read -r file; do
  [ -n "$file" ] || continue
  if node --check "$file" >/dev/null; then ok; else bad "JavaScript syntax: $file"; fi
done < <(git ls-files '*.js')

while IFS= read -r file; do
  [ -n "$file" ] || continue
  if python3 -c 'import json, sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$file"; then
    ok
  else
    bad "JSON syntax: $file"
  fi
done < <(git ls-files '*.json')

while IFS= read -r file; do
  [ -n "$file" ] || continue
  if plutil -lint "$file" >/dev/null; then ok; else bad "property list syntax: $file"; fi
done < <(git ls-files '*.plist')

if command -v ruby >/dev/null 2>&1; then
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    if ruby -rpsych -e 'Psych.parse_file(ARGV.fetch(0))' "$file"; then ok; else bad "YAML syntax: $file"; fi
  done < <(git ls-files '*.yml' '*.yaml')
else
  bad "ruby unavailable; cannot parse tracked YAML"
fi

if git grep -n -Ei 'osascript|NSAppleScript|Script Editor|com\.apple\.scripteditor|ScriptingBridge|NSAppleEventDescriptor|AEDeterminePermissionToAutomateTarget|com\.apple\.security\.automation\.apple-events' \
    -- . ':!test/test-static-analysis.sh' >/dev/null \
    || git ls-files | grep -Ei '\.(applescript|scpt)$' >/dev/null; then
  bad "AppleScript or Script Editor dependency found"
else
  ok
fi

if git grep -n -E '(Picker|Toggle)\("",' -- agent >/dev/null; then
  bad "SwiftUI Picker or Toggle has an empty accessibility label"
else
  ok
fi

printf '\nstatic analysis: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
