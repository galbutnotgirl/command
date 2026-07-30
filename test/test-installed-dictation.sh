#!/bin/zsh
emulate -L zsh
set -euo pipefail

RUNS="${COMMAND_DICTATION_PROBE_RUNS:-3}"
SOCKET="${HOME}/.claude/state/command-agent.sock"
HISTORY="${HOME}/Library/Application Support/DictationLab/history.json"
DOMAIN="gui/$(id -u)/com.claudecommand"

if [[ ! "$RUNS" == <-> ]] || (( RUNS < 1 || RUNS > 20 )); then
  print -u2 -- "COMMAND_DICTATION_PROBE_RUNS must be between 1 and 20"
  exit 2
fi

job_pid() {
  launchctl print "$DOMAIN" 2>/dev/null | awk '/^[[:space:]]*pid = / { print $3; exit }'
}

history_digest() {
  if [[ -f "$HISTORY" ]]; then
    shasum -a 256 "$HISTORY" | awk '{ print $1 }'
  else
    print -- "missing"
  fi
}

initial_pid="$(job_pid)"
if [[ -z "$initial_pid" ]] || ! kill -0 "$initial_pid" 2>/dev/null; then
  print -u2 -- "FAIL: Command launchd job is not running"
  exit 1
fi
if [[ ! -S "$SOCKET" ]]; then
  print -u2 -- "FAIL: Command dispatch socket is missing"
  exit 1
fi

history_before="$(history_digest)"
total_buffers=0
for (( run = 1; run <= RUNS; run++ )); do
  reply="$(printf 'dictationprobe\n' | nc -U -w 7 "$SOCKET" 2>/dev/null || true)"
  if [[ -z "$reply" ]]; then
    print -u2 -- "FAIL: microphone probe ${run}/${RUNS} returned no response"
    exit 1
  fi
  summary="$(python3 -c '
import json, sys
result = json.loads(sys.argv[1])
required = {"ok", "status", "authorization", "capturedBuffers", "inputDevice", "durationMilliseconds"}
missing = required.difference(result)
if missing:
    raise SystemExit("missing fields: " + ", ".join(sorted(missing)))
if result["ok"] is not True or result["status"] != "passed":
    raise SystemExit(result.get("failure") or f"probe failed: {result}")
if not isinstance(result["capturedBuffers"], int) or result["capturedBuffers"] < 1:
    raise SystemExit("probe passed without audio buffers")
print("{}\t{}\t{}".format(
    result["capturedBuffers"],
    result["inputDevice"],
    result["durationMilliseconds"],
))
' "$reply")" || {
    print -u2 -- "FAIL: microphone probe ${run}/${RUNS}: ${summary:-invalid response}"
    print -u2 -- "$reply"
    exit 1
  }
  buffers="${summary%%$'\t'*}"
  remainder="${summary#*$'\t'}"
  device="${remainder%%$'\t'*}"
  duration="${remainder##*$'\t'}"
  (( total_buffers += buffers ))
  print -- "  probe ${run}/${RUNS}: ${buffers} buffers, ${duration} ms, ${device}"

  current_pid="$(job_pid)"
  if [[ "$current_pid" != "$initial_pid" ]] || ! kill -0 "$initial_pid" 2>/dev/null; then
    print -u2 -- "FAIL: Command restarted during microphone probes"
    exit 1
  fi
  sleep 0.2
done

history_after="$(history_digest)"
if [[ "$history_after" != "$history_before" ]]; then
  print -u2 -- "FAIL: microphone probe changed dictation history"
  exit 1
fi

print -- "installed dictation probe passed"
print -- "  pid: ${initial_pid} (stable)"
print -- "  probes: ${RUNS}/${RUNS}"
print -- "  audio buffers: ${total_buffers} total"
print -- "  dictation history: unchanged"
