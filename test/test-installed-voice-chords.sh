#!/bin/zsh
# Exercise both Control+Fn release orders through installed event tap and recorder.
# Diagnostic capture never pastes text or adds history.
emulate -L zsh
set -euo pipefail
socket="$HOME/.claude/state/command-agent.sock"
for order in control-first fn-first; do
  reply="$(printf 'voicedispatchprobe %s\n' "$order" | nc -U -w 40 "$socket")"
  python3 - "$order" "$reply" <<'PY'
import json
import sys
order, raw = sys.argv[1:]
result = json.loads(raw)
assert result['ok'] is True and result['status'] == 'passed', result
assert result['eventTapDeliveredEvents'] == 2, result
assert result['capturedBuffers'] >= 4, result
assert result['capturePhase'] == 'idle', result
assert result['terminalStage'] in ('completed', 'empty'), result
assert result['resourcesReleased'] is True, result
print(f"PASS: Control+Fn {order}: {result['capturedBuffers']} buffers; released, idle, resources cleaned; {result['durationMilliseconds']}ms")
PY
done
