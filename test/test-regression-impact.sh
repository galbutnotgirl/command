#!/bin/zsh
emulate -L zsh
set -uo pipefail

DIR="${0:A:h:h}"
CHECKER="${DIR}/test/test-regression-impact.py"
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

expect_ok "all runtime files have regression ownership" \
  python3 "$CHECKER" --audit-only
expect_fail_with "general app runtime change requires app evidence" "app-runtime:" \
  python3 "$CHECKER" --paths agent/MenuBar.swift
expect_ok "general app runtime change accepts Swift evidence" \
  python3 "$CHECKER" --paths agent/MenuBar.swift agent/Tests/ClaudeCommandCoreTests/ActionModelsTests.swift
expect_fail_with "dictation runtime change requires dictation evidence" "dictation:" \
  python3 "$CHECKER" --paths agent/Recorder.swift
expect_ok "dictation runtime change accepts focused Swift evidence" \
  python3 "$CHECKER" --paths agent/Recorder.swift agent/Tests/ClaudeCommandCoreTests/VoiceSettingsTests.swift
expect_fail_with "shortcut runtime change requires shortcut evidence" "shortcuts-and-input:" \
  python3 "$CHECKER" --paths agent/Sources/ClaudeCommandCore/KeyCodes.swift
expect_ok "shortcut runtime change accepts keycode tests" \
  python3 "$CHECKER" --paths agent/Sources/ClaudeCommandCore/KeyCodes.swift agent/Tests/ClaudeCommandCoreTests/KeyCodesTests.swift
expect_fail_with "shared input runtime requires every impacted area" "clipboard-history:" \
  python3 "$CHECKER" --paths agent/main.swift agent/Tests/ClaudeCommandCoreTests/KeyCodesTests.swift
expect_ok "shared input runtime accepts integration evidence for every impacted area" \
  python3 "$CHECKER" --paths agent/main.swift test/test-shell.sh
expect_fail_with "assistant routing change requires routing evidence" "assistant-routing:" \
  python3 "$CHECKER" --paths send-to-claude.sh
expect_ok "assistant routing change accepts contract test" \
  python3 "$CHECKER" --paths send-to-claude.sh test/test-assistant-contract.sh
expect_fail_with "background runtime change requires background evidence" "background-actions:" \
  python3 "$CHECKER" --paths vendor/claude-command-capture/src/submit.js
expect_ok "background runtime accepts direct Node test evidence" \
  python3 "$CHECKER" --paths vendor/claude-command-capture/src/submit.js vendor/claude-command-capture/test/submit.test.js
expect_fail_with "installer change requires install evidence" "install-update-release:" \
  python3 "$CHECKER" --paths install-agent.sh
expect_ok "installer change accepts install-state test" \
  python3 "$CHECKER" --paths install-agent.sh test/test-install-state.sh
expect_ok "documentation-only change needs no runtime evidence" \
  python3 "$CHECKER" --paths README.md docs/index.html

print -- ""
print -- "regression impact tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
