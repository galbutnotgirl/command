#!/bin/zsh
emulate -L zsh
set -euo pipefail

EVENTS="${COMMAND_HOTKEY_PROBE_EVENTS:-100}"
LABEL="com.claudecommand"
SOCKET="${HOME}/.claude/state/command-agent.sock"
DOMAIN="gui/$(id -u)/${LABEL}"

if [[ ! "$EVENTS" == <-> ]] || (( EVENTS < 2 || EVENTS > 200 )); then
  print -u2 -- "COMMAND_HOTKEY_PROBE_EVENTS must be between 2 and 200"
  exit 2
fi

job_pid() {
  launchctl print "$DOMAIN" 2>/dev/null | awk '/^[[:space:]]*pid = / { print $3; exit }'
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

reply="$(printf 'hotkeyhealthprobe %s\n' "$EVENTS" | nc -U -w 8 "$SOCKET" 2>/dev/null || true)"
if [[ -z "$reply" ]]; then
  print -u2 -- "FAIL: installed hotkey health probe returned no response"
  exit 1
fi

summary="$(python3 -c '
import json, sys
result = json.loads(sys.argv[1])
required = {
    "ok", "status", "accessibilityTrusted", "eventTapInstalled", "eventTapEnabled",
    "expectedCarbonRegistrations", "actualCarbonRegistrations", "registrationFailures",
    "expectedEventTapAliases", "configuredVoiceAliases", "expectedCarbonVoiceAliases",
    "expectedEventTapVoiceAliases", "validatedCarbonVoiceAliases",
    "validatedEventTapVoiceAliases", "requestedEvents",
    "deliveredEvents", "durationMilliseconds",
}
missing = required.difference(result)
if missing:
    raise SystemExit("missing fields: " + ", ".join(sorted(missing)))
if result["ok"] is not True or result["status"] != "passed":
    raise SystemExit(result.get("failure") or f"hotkey health probe failed: {result}")
for field in ("accessibilityTrusted", "eventTapInstalled", "eventTapEnabled"):
    if result[field] is not True:
        raise SystemExit(f"{field} is not true")
integer_fields = (
    "expectedCarbonRegistrations", "actualCarbonRegistrations", "registrationFailures",
    "expectedEventTapAliases", "configuredVoiceAliases", "expectedCarbonVoiceAliases",
    "expectedEventTapVoiceAliases", "validatedCarbonVoiceAliases",
    "validatedEventTapVoiceAliases", "requestedEvents",
    "deliveredEvents", "durationMilliseconds",
)
for field in integer_fields:
    if type(result[field]) is not int or result[field] < 0:
        raise SystemExit(f"{field} is not a nonnegative integer")
if result["registrationFailures"] != 0:
    raise SystemExit("hotkey registration failures were recorded")
if result["actualCarbonRegistrations"] != result["expectedCarbonRegistrations"]:
    raise SystemExit("Carbon registration count mismatch")
if result["expectedCarbonVoiceAliases"] + result["expectedEventTapVoiceAliases"] != result["configuredVoiceAliases"]:
    raise SystemExit("voice alias ownership count mismatch")
if result["validatedCarbonVoiceAliases"] != result["expectedCarbonVoiceAliases"]:
    raise SystemExit("Carbon voice alias route count mismatch")
if result["validatedEventTapVoiceAliases"] != result["expectedEventTapVoiceAliases"]:
    raise SystemExit("event-tap voice alias route count mismatch")
if result["requestedEvents"] != int(sys.argv[2]):
    raise SystemExit("probe did not use requested event count")
if result["deliveredEvents"] != result["requestedEvents"]:
    raise SystemExit("tagged event delivery count mismatch")
print("{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}".format(
    result["deliveredEvents"],
    result["expectedCarbonRegistrations"],
    result["actualCarbonRegistrations"],
    result["expectedEventTapAliases"],
    result["configuredVoiceAliases"],
    result["expectedCarbonVoiceAliases"],
    result["expectedEventTapVoiceAliases"],
    result["validatedCarbonVoiceAliases"],
    result["validatedEventTapVoiceAliases"],
    result["durationMilliseconds"],
))
' "$reply" "$EVENTS")" || {
  print -u2 -- "FAIL: installed hotkey health probe: ${summary:-invalid response}"
  print -u2 -- "$reply"
  exit 1
}

current_pid="$(job_pid)"
if [[ "$current_pid" != "$initial_pid" ]] || ! kill -0 "$initial_pid" 2>/dev/null; then
  print -u2 -- "FAIL: Command restarted during installed hotkey health probe"
  exit 1
fi

IFS=$'\t' read -r delivered expected_carbon actual_carbon event_tap_aliases voice_aliases carbon_voice_aliases event_tap_voice_aliases validated_carbon_voice_aliases validated_event_tap_voice_aliases duration <<< "$summary"
print -- "installed hotkey health passed"
print -- "  pid: ${initial_pid} (stable)"
print -- "  tagged HID events: ${delivered}/${EVENTS}"
print -- "  Carbon registrations: ${actual_carbon}/${expected_carbon}"
print -- "  event-tap aliases: ${event_tap_aliases}"
print -- "  configured voice aliases: ${voice_aliases}"
print -- "  Carbon voice routes: ${validated_carbon_voice_aliases}/${carbon_voice_aliases}"
print -- "  event-tap voice routes: ${validated_event_tap_voice_aliases}/${event_tap_voice_aliases}"
print -- "  duration: ${duration} ms"
