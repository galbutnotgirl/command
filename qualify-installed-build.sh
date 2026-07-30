#!/bin/zsh
# Full local qualification for app-runtime changes. Builds and installs only
# through incremental path, then proves installed process, microphone, restart,
# final-word decoding, and runtime stability against exact committed revision.
emulate -L zsh
set -uo pipefail
zmodload zsh/datetime

DIR="${0:A:h}"
VERSION="$(tr -d ' \t\n' < "${DIR}/VERSION")"
REPORT="${COMMAND_QUALIFY_REPORT_PATH:-${DIR}/dist/installed-qualification.json}"
PROBE_RUNS="${COMMAND_QUALIFY_PROBE_RUNS:-5}"
HOTKEY_EVENTS="${COMMAND_QUALIFY_HOTKEY_EVENTS:-100}"
SOAK_SECONDS="${COMMAND_QUALIFY_SOAK_SECONDS:-15}"

RELEASE_SCRIPT="${COMMAND_QUALIFY_RELEASE_SCRIPT:-${DIR}/release.sh}"
INSTALL_SCRIPT="${COMMAND_QUALIFY_INSTALL_SCRIPT:-${DIR}/install-agent.sh}"
IDENTITY_SCRIPT="${COMMAND_QUALIFY_IDENTITY_SCRIPT:-${DIR}/test/test-installed-build-identity.sh}"
DICTATION_SCRIPT="${COMMAND_QUALIFY_DICTATION_SCRIPT:-${DIR}/test/test-installed-dictation.sh}"
HOTKEY_SCRIPT="${COMMAND_QUALIFY_HOTKEY_SCRIPT:-${DIR}/test/test-installed-hotkeys.sh}"
RESTART_SCRIPT="${COMMAND_QUALIFY_RESTART_SCRIPT:-${DIR}/test/test-installed-restart.sh}"
RUNTIME_SCRIPT="${COMMAND_QUALIFY_RUNTIME_SCRIPT:-${DIR}/test/test-installed-runtime.sh}"
MODEL_SCRIPT="${COMMAND_QUALIFY_MODEL_SCRIPT:-${DIR}/test/test-dictation-model.sh}"
STATE_SCRIPT="${COMMAND_QUALIFY_STATE_SCRIPT:-${DIR}/test/installed-state-snapshot.py}"
STATE_POLICY="${COMMAND_QUALIFY_STATE_POLICY:-${DIR}/test/installed-state-policy.json}"

COMMIT="$(git -C "$DIR" rev-parse HEAD 2>/dev/null || print unknown)"
BRANCH="$(git -C "$DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || print unknown)"
STARTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
STEPS_FILE="$(mktemp "${TMPDIR:-/tmp}/command-qualification-steps.XXXXXX")"
STATE_BEFORE="$(mktemp "${TMPDIR:-/tmp}/command-state-before.XXXXXX")"
STATE_AFTER="$(mktemp "${TMPDIR:-/tmp}/command-state-after.XXXXXX")"
CURRENT_STEP="Preflight"
QUALIFICATION_RESULT="failed"

write_report() {
  local exit_code="$1"
  local completed_at report_dir report_tmp
  completed_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  report_dir="${REPORT:h}"
  mkdir -p "$report_dir"
  report_tmp="$(mktemp "${REPORT}.tmp.XXXXXX")"
  python3 - "$COMMIT" "$BRANCH" "$VERSION" "$STARTED_AT" "$completed_at" \
    "$QUALIFICATION_RESULT" "$CURRENT_STEP" "$exit_code" "$STEPS_FILE" > "$report_tmp" <<'PY'
import json
import pathlib
import sys

commit, branch, version, started, completed, result, current, exit_code, steps_path = sys.argv[1:]
steps = []
for line in pathlib.Path(steps_path).read_text(encoding="utf-8").splitlines():
    name, status, duration = line.split("\t")
    steps.append({"name": name, "status": status, "durationSeconds": float(duration)})
document = {
    "schemaVersion": 1,
    "commit": commit,
    "branch": branch,
    "version": version,
    "startedAt": started,
    "completedAt": completed,
    "result": result,
    "failedStep": None if result == "passed" else current,
    "exitCode": int(exit_code),
    "installMode": "incremental",
    "publicReleasePublished": False,
    "steps": steps,
}
json.dump(document, sys.stdout, indent=2, sort_keys=True)
sys.stdout.write("\n")
PY
  mv "$report_tmp" "$REPORT"
}

finish() {
  local exit_code="$?"
  trap - EXIT
  write_report "$exit_code"
  rm -f "$STEPS_FILE" "$STATE_BEFORE" "$STATE_AFTER"
  if (( exit_code == 0 )); then
    print -- "[qualify] PASSED ${BRANCH}@${COMMIT[1,7]} (${VERSION})"
    print -- "[qualify] report: ${REPORT}"
  else
    print -u2 -- "[qualify] FAILED at ${CURRENT_STEP} (exit ${exit_code})"
    print -u2 -- "[qualify] report: ${REPORT}"
  fi
  exit "$exit_code"
}
trap finish EXIT

fail() {
  print -u2 -- "[qualify] $1"
  exit 1
}

run_step() {
  local name="$1"
  shift
  local started duration step_status
  CURRENT_STEP="$name"
  started="$EPOCHREALTIME"
  print -- "[qualify] ${name}"
  if "$@"; then
    step_status="passed"
  else
    local exit_code="$?"
    duration=$(( EPOCHREALTIME - started ))
    printf '%s\t%s\t%.3f\n' "$name" "failed" "$duration" >> "$STEPS_FILE"
    return "$exit_code"
  fi
  duration=$(( EPOCHREALTIME - started ))
  printf '%s\t%s\t%.3f\n' "$name" "$step_status" "$duration" >> "$STEPS_FILE"
  print -- "[qualify] passed ${name} (${duration}s)"
}

capture_durable_state() {
  "$STATE_SCRIPT" --policy "$STATE_POLICY" capture --output "$1"
}

verify_durable_state() {
  capture_durable_state "$STATE_AFTER" \
    && "$STATE_SCRIPT" --policy "$STATE_POLICY" compare \
      --before "$STATE_BEFORE" --after "$STATE_AFTER"
}

gui_session_is_locked() {
  case "${COMMAND_TEST_GUI_SESSION:-}" in
    locked) return 0 ;;
    unlocked) return 1 ;;
  esac
  ioreg -n Root -d1 2>/dev/null | grep -F '"CGSSessionScreenIsLocked"=Yes' >/dev/null
}

[[ "$COMMIT" != "unknown" ]] || fail "repository commit is unavailable"
[[ -z "$(git -C "$DIR" status --porcelain 2>/dev/null)" ]] \
  || fail "working tree must be clean so report identifies exact source"
gui_session_is_locked \
  && fail "GUI session is locked; unlock Mac and rerun qualification because focus and paste delivery cannot run behind loginwindow"
[[ "${COMMAND_CLEAN_INSTALL:-0}" == "0" ]] \
  || fail "clean install is forbidden during qualification"
[[ "${COMMAND_ALLOW_TCC_IDENTITY_CHANGE:-0}" == "0" ]] \
  || fail "signing identity override is forbidden during qualification"
[[ "${COMMAND_ALLOW_UNQUALIFIED_INSTALL:-0}" == "0" ]] \
  || fail "unqualified install override is forbidden during qualification"
[[ "$PROBE_RUNS" == <-> ]] && (( PROBE_RUNS >= 1 && PROBE_RUNS <= 20 )) \
  || fail "COMMAND_QUALIFY_PROBE_RUNS must be between 1 and 20"
[[ "$HOTKEY_EVENTS" == <-> ]] && (( HOTKEY_EVENTS >= 2 && HOTKEY_EVENTS <= 200 )) \
  || fail "COMMAND_QUALIFY_HOTKEY_EVENTS must be between 2 and 200"
[[ "$SOAK_SECONDS" == <-> ]] && (( SOAK_SECONDS >= 1 && SOAK_SECONDS <= 300 )) \
  || fail "COMMAND_QUALIFY_SOAK_SECONDS must be between 1 and 300"
for required_script in "$RELEASE_SCRIPT" "$INSTALL_SCRIPT" "$IDENTITY_SCRIPT" \
  "$DICTATION_SCRIPT" "$HOTKEY_SCRIPT" "$RESTART_SCRIPT" "$RUNTIME_SCRIPT" "$MODEL_SCRIPT" \
  "$STATE_SCRIPT"; do
  [[ -x "$required_script" ]] || fail "required executable missing: ${required_script}"
done
[[ -r "$STATE_POLICY" ]] || fail "durable-state policy missing: ${STATE_POLICY}"

run_step "Full release gates and signed build" "$RELEASE_SCRIPT" || exit $?
run_step "Capture durable state baseline" capture_durable_state "$STATE_BEFORE" || exit $?
run_step "Incremental install" "$INSTALL_SCRIPT" || exit $?
run_step "Durable state after install" verify_durable_state || exit $?
run_step "Installed build identity" "$IDENTITY_SCRIPT" || exit $?
run_step "Hotkey input before restart" env \
  COMMAND_HOTKEY_PROBE_EVENTS="$HOTKEY_EVENTS" "$HOTKEY_SCRIPT" || exit $?
run_step "Microphone capture before restart" env \
  COMMAND_DICTATION_PROBE_RUNS="$PROBE_RUNS" "$DICTATION_SCRIPT" || exit $?
run_step "Restart installed app" "$RESTART_SCRIPT" || exit $?
run_step "Hotkey input after restart" env \
  COMMAND_HOTKEY_PROBE_EVENTS="$HOTKEY_EVENTS" "$HOTKEY_SCRIPT" || exit $?
run_step "Microphone capture after restart" env \
  COMMAND_DICTATION_PROBE_RUNS="$PROBE_RUNS" "$DICTATION_SCRIPT" || exit $?
run_step "Installed runtime soak" env \
  COMMAND_SOAK_SECONDS="$SOAK_SECONDS" "$RUNTIME_SCRIPT" || exit $?
run_step "Final-word model fixtures" "$MODEL_SCRIPT" || exit $?
run_step "Durable state after qualification" verify_durable_state || exit $?

CURRENT_STEP="Complete"
QUALIFICATION_RESULT="passed"
