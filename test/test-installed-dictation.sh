#!/bin/zsh
emulate -L zsh
set -euo pipefail

RUNS="${COMMAND_DICTATION_PROBE_RUNS:-3}"
RECOVERY_RUNS="${COMMAND_DICTATION_RECOVERY_RUNS:-3}"
SOCKET="${HOME}/.claude/state/command-agent.sock"
HISTORY="${HOME}/Library/Application Support/DictationLab/history.json"
DOMAIN="gui/$(id -u)/com.claudecommand"

if [[ ! "$RUNS" == <-> ]] || (( RUNS < 1 || RUNS > 20 )); then
  print -u2 -- "COMMAND_DICTATION_PROBE_RUNS must be between 1 and 20"
  exit 2
fi
if [[ ! "$RECOVERY_RUNS" == <-> ]] || (( RECOVERY_RUNS < 1 || RECOVERY_RUNS > 10 )); then
  print -u2 -- "COMMAND_DICTATION_RECOVERY_RUNS must be between 1 and 10"
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
  reply=""
  for (( readiness_attempt = 1; readiness_attempt <= 50; readiness_attempt++ )); do
    reply="$(printf 'dictationprobe\n' | nc -U -w 7 "$SOCKET" 2>/dev/null || true)"
    loading_phase="$(python3 -c '
import json, sys
try:
    result = json.loads(sys.argv[1])
except Exception:
    print("no")
else:
    print("yes" if result.get("status") == "recorderBusy" and result.get("capturePhase") == "loading" else "no")
' "$reply")"
    [[ "$loading_phase" == "yes" ]] || break
    sleep 0.1
  done
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

lifecycle_reply=""
for (( readiness_attempt = 1; readiness_attempt <= 100; readiness_attempt++ )); do
  lifecycle_reply="$(printf 'dictationlifecycleprobe\n' | nc -U -w 35 "$SOCKET" 2>/dev/null || true)"
  loading_phase="$(python3 -c '
import json, sys
try:
    result = json.loads(sys.argv[1])
except Exception:
    print("no")
else:
    waiting = result.get("status") == "modelUnavailable" and result.get("capturePhase") == "loading"
    print("yes" if waiting else "no")
' "$lifecycle_reply")"
  [[ "$loading_phase" == "yes" ]] || break
  sleep 0.1
done
if [[ -z "$lifecycle_reply" ]]; then
  print -u2 -- "FAIL: production dictation lifecycle probe returned no response"
  exit 1
fi
lifecycle_summary="$(python3 -c '
import json, sys
result = json.loads(sys.argv[1])
required = {
    "ok", "status", "sessionID", "modelStatus", "capturePhase", "terminalStage",
    "capturedBuffers", "transcriptionUpdates", "finalCharacters", "inputDevice",
    "durationMilliseconds",
}
missing = required.difference(result)
if missing:
    raise SystemExit("missing fields: " + ", ".join(sorted(missing)))
if result["ok"] is not True or result["status"] != "passed":
    raise SystemExit(result.get("failure") or f"lifecycle probe failed: {result}")
if result["modelStatus"] != "ready":
    raise SystemExit("production lifecycle passed without ready model")
if result["capturePhase"] != "idle":
    raise SystemExit("production lifecycle left recorder non-idle")
if result["terminalStage"] not in {"completed", "empty"}:
    raise SystemExit("production lifecycle has nonterminal session health")
if not isinstance(result["capturedBuffers"], int) or result["capturedBuffers"] < 4:
    raise SystemExit("production lifecycle passed without four audio buffers")
if not isinstance(result["durationMilliseconds"], int) or result["durationMilliseconds"] < 1:
    raise SystemExit("production lifecycle has invalid duration")
print("{}\t{}\t{}\t{}\t{}".format(
    result["sessionID"],
    result["capturedBuffers"],
    result["transcriptionUpdates"],
    result["terminalStage"],
    result["durationMilliseconds"],
))
' "$lifecycle_reply")" || {
  print -u2 -- "FAIL: production dictation lifecycle probe: ${lifecycle_summary:-invalid response}"
  print -u2 -- "$lifecycle_reply"
  exit 1
}
lifecycle_session="${lifecycle_summary%%$'\t'*}"
lifecycle_remainder="${lifecycle_summary#*$'\t'}"
lifecycle_buffers="${lifecycle_remainder%%$'\t'*}"
lifecycle_remainder="${lifecycle_remainder#*$'\t'}"
lifecycle_updates="${lifecycle_remainder%%$'\t'*}"
lifecycle_remainder="${lifecycle_remainder#*$'\t'}"
lifecycle_stage="${lifecycle_remainder%%$'\t'*}"
lifecycle_duration="${lifecycle_remainder##*$'\t'}"

current_pid="$(job_pid)"
if [[ "$current_pid" != "$initial_pid" ]] || ! kill -0 "$initial_pid" 2>/dev/null; then
  print -u2 -- "FAIL: Command restarted during production dictation lifecycle probe"
  exit 1
fi

voice_reply="$(printf 'voicedispatchprobe\n' | nc -U -w 40 "$SOCKET" 2>/dev/null || true)"
if [[ -z "$voice_reply" ]]; then
  print -u2 -- "FAIL: event-tap voice dispatch probe returned no response"
  exit 1
fi
voice_summary="$(python3 -c '
import json, sys
result = json.loads(sys.argv[1])
required = {
    "ok", "status", "eventTapDeliveredEvents", "configuredVoiceAliases",
    "sessionID", "capturedBuffers", "terminalStage", "capturePhase",
    "resourcesReleased", "durationMilliseconds",
}
missing = required.difference(result)
if missing:
    raise SystemExit("missing fields: " + ", ".join(sorted(missing)))
if result["ok"] is not True or result["status"] != "passed":
    raise SystemExit(result.get("failure") or f"voice dispatch probe failed: {result}")
if result["eventTapDeliveredEvents"] != 2:
    raise SystemExit("event-tap voice dispatch did not deliver key-down and key-up")
if result["capturePhase"] != "idle" or result["terminalStage"] not in {"completed", "empty"}:
    raise SystemExit("event-tap voice dispatch did not finish cleanly")
if result["resourcesReleased"] is not True:
    raise SystemExit("event-tap voice dispatch left capture resources active")
for field in ("sessionID", "capturedBuffers", "configuredVoiceAliases", "durationMilliseconds"):
    if not isinstance(result[field], int) or result[field] < 0:
        raise SystemExit(f"invalid voice dispatch metric: {field}")
if result["sessionID"] < 1 or result["capturedBuffers"] < 4 or result["durationMilliseconds"] < 1:
    raise SystemExit("event-tap voice dispatch lacks live capture evidence")
print("{}\t{}\t{}\t{}\t{}".format(
    result["sessionID"],
    result["capturedBuffers"],
    result["terminalStage"],
    result["configuredVoiceAliases"],
    result["durationMilliseconds"],
))
' "$voice_reply")" || {
  print -u2 -- "FAIL: event-tap voice dispatch probe: ${voice_summary:-invalid response}"
  print -u2 -- "$voice_reply"
  exit 1
}
voice_session="${voice_summary%%$'\t'*}"
voice_remainder="${voice_summary#*$'\t'}"
voice_buffers="${voice_remainder%%$'\t'*}"
voice_remainder="${voice_remainder#*$'\t'}"
voice_stage="${voice_remainder%%$'\t'*}"
voice_remainder="${voice_remainder#*$'\t'}"
voice_aliases="${voice_remainder%%$'\t'*}"
voice_duration="${voice_remainder##*$'\t'}"

current_pid="$(job_pid)"
if [[ "$current_pid" != "$initial_pid" ]] || ! kill -0 "$initial_pid" 2>/dev/null; then
  print -u2 -- "FAIL: Command restarted during event-tap voice dispatch probe"
  exit 1
fi

insert_reply="$(printf 'dictationinsertprobe\n' | nc -U -w 15 "$SOCKET" 2>/dev/null || true)"
if [[ -z "$insert_reply" ]]; then
  print -u2 -- "FAIL: installed dictation insert probe returned no response"
  exit 1
fi
insert_summary="$(python3 -c '
import json, sys
result = json.loads(sys.argv[1])
required = {
    "ok", "status", "pipelineStatus", "rawCharacters", "processedCharacters",
    "clipboardWritten", "targetActive", "pasteEventPosted", "receiverMatched",
    "clipboardRestored", "previousAppRestored", "durationMilliseconds",
}
missing = required.difference(result)
if missing:
    raise SystemExit("missing fields: " + ", ".join(sorted(missing)))
if result["ok"] is not True or result["status"] != "passed":
    raise SystemExit(result.get("failure") or f"dictation insert probe failed: {result}")
if result["pipelineStatus"] != "delivered":
    raise SystemExit("dictation insert probe did not use delivered production pipeline result")
for field in ("rawCharacters", "processedCharacters", "durationMilliseconds"):
    if not isinstance(result[field], int) or result[field] < 1:
        raise SystemExit(f"invalid dictation insert metric: {field}")
for field in (
    "clipboardWritten", "targetActive", "pasteEventPosted", "receiverMatched",
    "clipboardRestored", "previousAppRestored",
):
    if result[field] is not True:
        raise SystemExit(f"dictation insert proof missing: {field}")
print("{}\t{}\t{}".format(
    result["rawCharacters"],
    result["processedCharacters"],
    result["durationMilliseconds"],
))
' "$insert_reply")" || {
  print -u2 -- "FAIL: installed dictation insert probe: ${insert_summary:-invalid response}"
  print -u2 -- "$insert_reply"
  exit 1
}
insert_raw_chars="${insert_summary%%$'\t'*}"
insert_remainder="${insert_summary#*$'\t'}"
insert_processed_chars="${insert_remainder%%$'\t'*}"
insert_duration="${insert_remainder##*$'\t'}"

current_pid="$(job_pid)"
if [[ "$current_pid" != "$initial_pid" ]] || ! kill -0 "$initial_pid" 2>/dev/null; then
  print -u2 -- "FAIL: Command restarted during dictation insert probe"
  exit 1
fi

watchdog_reply="$(printf 'dictationwatchdogprobe\n' | nc -U -w 50 "$SOCKET" 2>/dev/null || true)"
if [[ -z "$watchdog_reply" ]]; then
  print -u2 -- "FAIL: dictation startup-watchdog probe returned no response"
  exit 1
fi
watchdog_summary="$(python3 -c '
import json, sys
result = json.loads(sys.argv[1])
required = {
    "ok", "status", "scenario", "stalledSessionID", "stalledCapturedBuffers", "stalledTerminalStage",
    "warningCount", "resetCount", "releasedDuringStartup", "cleanup",
    "recovery", "durationMilliseconds",
}
missing = required.difference(result)
if missing:
    raise SystemExit("missing fields: " + ", ".join(sorted(missing)))
if result["ok"] is not True or result["status"] != "passed":
    raise SystemExit(result.get("failure") or f"watchdog probe failed: {result}")
if result["scenario"] != "startup" or result["stalledCapturedBuffers"] != 0:
    raise SystemExit("startup watchdog probe did not exercise a zero-buffer stall")
if result["stalledTerminalStage"] != "cancelled":
    raise SystemExit("startup watchdog did not cancel stalled session")
if result["warningCount"] != 1 or result["resetCount"] != 1:
    raise SystemExit("startup watchdog did not issue exactly one warning and one reset")
if result["releasedDuringStartup"] is not True:
    raise SystemExit("probe did not release shortcut during stalled startup")
cleanup = result["cleanup"]
if cleanup.get("capturePhase") != "idle" or cleanup.get("fullyReleased") is not True:
    raise SystemExit("startup watchdog left capture resources active")
for field in (
    "overlayVisible", "captureStartupBegan", "audioEngineActive", "audioTapActive",
    "streamTaskActive", "audioContinuationActive", "bufferFeederActive",
    "managerActive", "silenceTimerActive",
):
    if cleanup.get(field) is not False:
        raise SystemExit(f"startup watchdog cleanup field stayed active: {field}")
retry = result["recovery"]
if not isinstance(retry, dict) or retry.get("ok") is not True or retry.get("status") != "passed":
    raise SystemExit("immediate production retry did not pass after startup watchdog reset")
if retry.get("capturePhase") != "idle" or retry.get("terminalStage") not in {"completed", "empty"}:
    raise SystemExit("startup watchdog retry did not finish cleanly")
if not isinstance(retry.get("capturedBuffers"), int) or retry["capturedBuffers"] < 4:
    raise SystemExit("startup watchdog retry captured fewer than four buffers")
print("{}\t{}\t{}\t{}\t{}".format(
    result["stalledSessionID"],
    retry["sessionID"],
    retry["capturedBuffers"],
    retry["terminalStage"],
    result["durationMilliseconds"],
))
' "$watchdog_reply")" || {
  print -u2 -- "FAIL: dictation startup-watchdog probe: ${watchdog_summary:-invalid response}"
  print -u2 -- "$watchdog_reply"
  exit 1
}
watchdog_stalled_session="${watchdog_summary%%$'\t'*}"
watchdog_remainder="${watchdog_summary#*$'\t'}"
watchdog_retry_session="${watchdog_remainder%%$'\t'*}"
watchdog_remainder="${watchdog_remainder#*$'\t'}"
watchdog_retry_buffers="${watchdog_remainder%%$'\t'*}"
watchdog_remainder="${watchdog_remainder#*$'\t'}"
watchdog_retry_stage="${watchdog_remainder%%$'\t'*}"
watchdog_duration="${watchdog_remainder##*$'\t'}"

if (( watchdog_stalled_session <= voice_session || watchdog_retry_session <= watchdog_stalled_session )); then
  print -u2 -- "FAIL: startup-watchdog session IDs did not increase"
  exit 1
fi
current_pid="$(job_pid)"
if [[ "$current_pid" != "$initial_pid" ]] || ! kill -0 "$initial_pid" 2>/dev/null; then
  print -u2 -- "FAIL: Command restarted during startup-watchdog probe"
  exit 1
fi

stream_watchdog_reply="$(printf 'dictationstreamwatchdogprobe\n' | nc -U -w 50 "$SOCKET" 2>/dev/null || true)"
if [[ -z "$stream_watchdog_reply" ]]; then
  print -u2 -- "FAIL: dictation midstream-watchdog probe returned no response"
  exit 1
fi
stream_watchdog_summary="$(python3 -c '
import json, sys
result = json.loads(sys.argv[1])
required = {
    "ok", "status", "scenario", "stalledSessionID", "stalledCapturedBuffers", "stalledTerminalStage",
    "warningCount", "resetCount", "releasedDuringStartup", "cleanup",
    "recovery", "durationMilliseconds",
}
missing = required.difference(result)
if missing:
    raise SystemExit("missing fields: " + ", ".join(sorted(missing)))
if result["ok"] is not True or result["status"] != "passed":
    raise SystemExit(result.get("failure") or f"midstream watchdog probe failed: {result}")
if result["scenario"] != "midstream":
    raise SystemExit("midstream watchdog probe reported wrong scenario")
if result["stalledTerminalStage"] != "cancelled" or result["stalledCapturedBuffers"] < 3:
    raise SystemExit("midstream watchdog did not cancel after live microphone buffers")
if result["warningCount"] != 1 or result["resetCount"] != 1:
    raise SystemExit("midstream watchdog did not issue exactly one warning and one reset")
if result["releasedDuringStartup"] is not False:
    raise SystemExit("midstream stall was incorrectly reported as a released startup")
cleanup = result["cleanup"]
if cleanup.get("capturePhase") != "idle" or cleanup.get("fullyReleased") is not True:
    raise SystemExit("midstream watchdog left capture resources active")
for field in (
    "overlayVisible", "captureStartupBegan", "audioEngineActive", "audioTapActive",
    "streamTaskActive", "audioContinuationActive", "bufferFeederActive",
    "managerActive", "silenceTimerActive",
):
    if cleanup.get(field) is not False:
        raise SystemExit(f"midstream watchdog cleanup field stayed active: {field}")
retry = result["recovery"]
if not isinstance(retry, dict) or retry.get("ok") is not True or retry.get("status") != "passed":
    raise SystemExit("immediate production retry did not pass after midstream watchdog reset")
if retry.get("capturePhase") != "idle" or retry.get("terminalStage") not in {"completed", "empty"}:
    raise SystemExit("midstream watchdog retry did not finish cleanly")
if not isinstance(retry.get("capturedBuffers"), int) or retry["capturedBuffers"] < 4:
    raise SystemExit("midstream watchdog retry captured fewer than four buffers")
print("{}\t{}\t{}\t{}\t{}\t{}".format(
    result["stalledSessionID"],
    result["stalledCapturedBuffers"],
    retry["sessionID"],
    retry["capturedBuffers"],
    retry["terminalStage"],
    result["durationMilliseconds"],
))
' "$stream_watchdog_reply")" || {
  print -u2 -- "FAIL: dictation midstream-watchdog probe: ${stream_watchdog_summary:-invalid response}"
  print -u2 -- "$stream_watchdog_reply"
  exit 1
}
stream_watchdog_stalled_session="${stream_watchdog_summary%%$'\t'*}"
stream_watchdog_remainder="${stream_watchdog_summary#*$'\t'}"
stream_watchdog_stalled_buffers="${stream_watchdog_remainder%%$'\t'*}"
stream_watchdog_remainder="${stream_watchdog_remainder#*$'\t'}"
stream_watchdog_retry_session="${stream_watchdog_remainder%%$'\t'*}"
stream_watchdog_remainder="${stream_watchdog_remainder#*$'\t'}"
stream_watchdog_retry_buffers="${stream_watchdog_remainder%%$'\t'*}"
stream_watchdog_remainder="${stream_watchdog_remainder#*$'\t'}"
stream_watchdog_retry_stage="${stream_watchdog_remainder%%$'\t'*}"
stream_watchdog_duration="${stream_watchdog_remainder##*$'\t'}"

if (( stream_watchdog_stalled_session <= watchdog_retry_session || stream_watchdog_retry_session <= stream_watchdog_stalled_session )); then
  print -u2 -- "FAIL: midstream-watchdog session IDs did not increase"
  exit 1
fi
current_pid="$(job_pid)"
if [[ "$current_pid" != "$initial_pid" ]] || ! kill -0 "$initial_pid" 2>/dev/null; then
  print -u2 -- "FAIL: Command restarted during midstream-watchdog probe"
  exit 1
fi

previous_recovery_session="$stream_watchdog_retry_session"
recovery_total_duration=0
for (( recovery_run = 1; recovery_run <= RECOVERY_RUNS; recovery_run++ )); do
recovery_reply="$(printf 'dictationrecoveryprobe\n' | nc -U -w 50 "$SOCKET" 2>/dev/null || true)"
if [[ -z "$recovery_reply" ]]; then
  print -u2 -- "FAIL: dictation failure-recovery probe ${recovery_run}/${RECOVERY_RUNS} returned no response"
  exit 1
fi
recovery_summary="$(python3 -c '
import json, sys
result = json.loads(sys.argv[1])
required = {
    "ok", "status", "injectedSessionID", "injectedBuffers",
    "injectedTerminalStage", "cleanup", "durationMilliseconds",
}
missing = required.difference(result)
if missing:
    raise SystemExit("missing fields: " + ", ".join(sorted(missing)))
if result["ok"] is not True or result["status"] != "passed":
    raise SystemExit(result.get("failure") or f"recovery probe failed: {result}")
if result["injectedTerminalStage"] != "failed" or result["injectedBuffers"] < 2:
    raise SystemExit("probe did not inject failure after live microphone buffers")
for field in ("injectedSessionID", "injectedBuffers", "durationMilliseconds"):
    if not isinstance(result[field], int) or result[field] < 0:
        raise SystemExit(f"invalid failure-recovery metric: {field}")
cleanup = result["cleanup"]
cleanup_fields = {
    "capturePhase", "overlayVisible", "captureStartupBegan", "audioEngineActive", "audioTapActive",
    "streamTaskActive", "audioContinuationActive", "bufferFeederActive",
    "managerActive", "silenceTimerActive", "fullyReleased",
}
missing_cleanup = cleanup_fields.difference(cleanup)
if missing_cleanup:
    raise SystemExit("missing cleanup fields: " + ", ".join(sorted(missing_cleanup)))
if cleanup["capturePhase"] != "error" or cleanup["fullyReleased"] is not True:
    raise SystemExit("capture resources were not fully released after injected failure")
for field in cleanup_fields - {"capturePhase", "fullyReleased"}:
    if cleanup[field] is not False:
        raise SystemExit(f"cleanup field stayed active: {field}")
retry = result["recovery"]
if not isinstance(retry, dict) or retry.get("ok") is not True or retry.get("status") != "passed":
    raise SystemExit("immediate production retry did not pass")
if not isinstance(retry.get("sessionID"), int) or retry["sessionID"] < 1:
    raise SystemExit("immediate production retry has invalid session ID")
if retry.get("capturePhase") != "idle" or retry.get("terminalStage") not in {"completed", "empty"}:
    raise SystemExit("immediate production retry did not finish cleanly")
if not isinstance(retry.get("capturedBuffers"), int) or retry["capturedBuffers"] < 4:
    raise SystemExit("immediate production retry captured fewer than four buffers")
print("{}\t{}\t{}\t{}\t{}\t{}\t{}".format(
    result["injectedSessionID"],
    result["injectedBuffers"],
    cleanup["capturePhase"],
    retry["sessionID"],
    retry["capturedBuffers"],
    retry["terminalStage"],
    result["durationMilliseconds"],
))
' "$recovery_reply")" || {
  print -u2 -- "FAIL: dictation failure-recovery probe ${recovery_run}/${RECOVERY_RUNS}: ${recovery_summary:-invalid response}"
  print -u2 -- "$recovery_reply"
  exit 1
}
recovery_injected_session="${recovery_summary%%$'\t'*}"
recovery_remainder="${recovery_summary#*$'\t'}"
recovery_injected_buffers="${recovery_remainder%%$'\t'*}"
recovery_remainder="${recovery_remainder#*$'\t'}"
recovery_cleanup_phase="${recovery_remainder%%$'\t'*}"
recovery_remainder="${recovery_remainder#*$'\t'}"
recovery_retry_session="${recovery_remainder%%$'\t'*}"
recovery_remainder="${recovery_remainder#*$'\t'}"
recovery_retry_buffers="${recovery_remainder%%$'\t'*}"
recovery_remainder="${recovery_remainder#*$'\t'}"
recovery_retry_stage="${recovery_remainder%%$'\t'*}"
recovery_duration="${recovery_remainder##*$'\t'}"

if (( recovery_injected_session <= previous_recovery_session || recovery_retry_session <= recovery_injected_session )); then
  print -u2 -- "FAIL: dictation recovery session IDs did not increase on cycle ${recovery_run}/${RECOVERY_RUNS}"
  exit 1
fi
previous_recovery_session="$recovery_retry_session"
(( recovery_total_duration += recovery_duration ))
print -- "  recovery ${recovery_run}/${RECOVERY_RUNS}: session ${recovery_injected_session} failed after ${recovery_injected_buffers} buffers; retry ${recovery_retry_session} captured ${recovery_retry_buffers} and finished ${recovery_retry_stage}"

current_pid="$(job_pid)"
if [[ "$current_pid" != "$initial_pid" ]] || ! kill -0 "$initial_pid" 2>/dev/null; then
  print -u2 -- "FAIL: Command restarted during dictation failure-recovery cycle ${recovery_run}/${RECOVERY_RUNS}"
  exit 1
fi
done

history_after="$(history_digest)"
if [[ "$history_after" != "$history_before" ]]; then
  print -u2 -- "FAIL: dictation probes changed dictation history"
  exit 1
fi

print -- "installed dictation probe passed"
print -- "  pid: ${initial_pid} (stable)"
print -- "  probes: ${RUNS}/${RUNS}"
print -- "  audio buffers: ${total_buffers} total"
print -- "  production lifecycle: session ${lifecycle_session}, ${lifecycle_buffers} buffers, ${lifecycle_updates} updates, ${lifecycle_stage}, ${lifecycle_duration} ms"
print -- "  event-tap voice dispatch: 2/2 tagged events, session ${voice_session}, ${voice_buffers} buffers, ${voice_stage}, ${voice_duration} ms, ${voice_aliases} configured aliases"
print -- "  insert delivery: pipeline ${insert_raw_chars}->${insert_processed_chars} chars, focused receiver matched, clipboard/focus restored in ${insert_duration} ms"
print -- "  startup watchdog: session ${watchdog_stalled_session} warned/reset after release; retry ${watchdog_retry_session} captured ${watchdog_retry_buffers} and finished ${watchdog_retry_stage} in ${watchdog_duration} ms"
print -- "  midstream watchdog: session ${stream_watchdog_stalled_session} stalled after ${stream_watchdog_stalled_buffers} buffers; retry ${stream_watchdog_retry_session} captured ${stream_watchdog_retry_buffers} and finished ${stream_watchdog_retry_stage} in ${stream_watchdog_duration} ms"
print -- "  failure recovery: ${RECOVERY_RUNS}/${RECOVERY_RUNS} cycles, final cleanup ${recovery_cleanup_phase}, ${recovery_total_duration} ms total"
print -- "  dictation history: unchanged"
