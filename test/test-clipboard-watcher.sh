#!/bin/zsh
# Smoke-test native Clipboard History helper with isolated local state.
emulate -L zsh
set -uo pipefail

ROOT="${0:A:h:h}"
BIN="${1:-${ROOT}/agent/.build/debug/CommandClipboardWatcher}"
TMP_HOME="$(mktemp -d "${TMPDIR:-/tmp}/command-clipboard-watcher.XXXXXX")"
ERR="${TMP_HOME}/stderr.log"
PID=""

cleanup() {
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_HOME"
}
trap cleanup EXIT

[ -x "$BIN" ] || { print -u2 -- "FAIL: missing executable helper: $BIN"; exit 1; }

HOME="$TMP_HOME" "$BIN" 2>"$ERR" &
PID=$!

metadata="$TMP_HOME/.claude/state/clipboard.json"
for _ in {1..80}; do
  [ -f "$metadata" ] && break
  if ! kill -0 "$PID" 2>/dev/null; then
    print -u2 -- "FAIL: helper exited before startup metadata was written"
    cat "$ERR" >&2
    exit 1
  fi
  sleep 0.05
done

[ -f "$metadata" ] || { print -u2 -- "FAIL: helper did not write clipboard metadata"; exit 1; }
[ -d "$TMP_HOME/.claude/state/cliphistory" ] || { print -u2 -- "FAIL: helper did not create history directory"; exit 1; }
[ -f "$TMP_HOME/.claude/logs/attribution.log" ] || { print -u2 -- "FAIL: helper did not write startup log"; exit 1; }

python3 - "$metadata" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
assert isinstance(data.get("epoch"), int)
assert isinstance(data.get("bundle"), str)
assert data.get("blocked") is False
PY

print -- "Clipboard watcher smoke test passed"
