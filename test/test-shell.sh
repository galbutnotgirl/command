#!/bin/zsh
# test/test-shell.sh — plain-assertion tests for the shell-side logic that
# duplicates Swift behavior (send-to-claude-lib.sh's expand_template, and
# match-enrich-rule.py's host/bundle/app + pathPrefix matching). No framework,
# no network, no GUI/Accessibility permissions needed — just `./test/test-shell.sh`.
#
# Run from anywhere; paths are resolved relative to this file.
emulate -L zsh
set -uo pipefail

DIR="${0:A:h:h}"   # repo root (one level up from test/)
source "${DIR}/send-to-claude-lib.sh"

PASS=0
FAIL=0

assert_eq() {  # $1 = label, $2 = actual, $3 = expected
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    print -r -- "FAIL: $1"
    print -r -- "  expected: $3"
    print -r -- "  actual:   $2"
  fi
}

assert_status() {  # $1 = label, $2 = actual status, $3 = expected status
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    print -r -- "FAIL: $1"
    print -r -- "  expected status: $3"
    print -r -- "  actual status:   $2"
  fi
}

assert_contains() {  # $1 = label, $2 = actual, $3 = expected substring
  if [[ "$2" == *"$3"* ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    print -r -- "FAIL: $1"
    print -r -- "  missing: $3"
    print -r -- "  actual:  $2"
  fi
}

assert_not_contains() {  # $1 = label, $2 = actual, $3 = forbidden substring
  if [[ "$2" != *"$3"* ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    print -r -- "FAIL: $1"
    print -r -- "  unexpected: $3"
  fi
}

# ---- expand_template ---------------------------------------------------------
# expand_template reads CONTEXT_LINE / URL / SOURCE_LINE from the caller's
# scope (see send-to-claude-lib.sh's header comment) — set them per case.

CONTEXT_LINE="ctx"; URL=""; SOURCE_LINE=""
assert_eq "bare template, no placeholders → selection appended" \
  "$(expand_template 'do the thing' 'SEL')" \
  "do the thing

SEL"

CONTEXT_LINE=""; URL=""; SOURCE_LINE=""
assert_eq "empty template, no placeholders → selection alone" \
  "$(expand_template '' 'SEL')" \
  "SEL"

CONTEXT_LINE=""; URL=""; SOURCE_LINE=""
assert_eq "{selection} inline, no auto-append" \
  "$(expand_template 'before {selection} after' 'X')" \
  "before X after"

CONTEXT_LINE=""; URL=""; SOURCE_LINE=""
assert_eq "{prompt} and {text} are {selection} aliases" \
  "$(expand_template '{prompt}/{text}' 'X')" \
  "X/X"

CONTEXT_LINE="research this"; URL=""; SOURCE_LINE=""
assert_eq "{context} substitution (selection still auto-appended — no {selection} token)" \
  "$(expand_template 'go: {context}' 'SEL')" \
  "go: research this

SEL"

CONTEXT_LINE=""; URL="https://example.com"; SOURCE_LINE=""
assert_eq "{url} substitution (selection still auto-appended — no {selection} token)" \
  "$(expand_template 'see {url}' 'SEL')" \
  "see https://example.com

SEL"

CONTEXT_LINE=""; URL=""; SOURCE_LINE="[from: Slack]"
assert_eq "{source} auto-prepended when omitted" \
  "$(expand_template '{selection}' 'SEL')" \
  "[from: Slack]

SEL"

CONTEXT_LINE=""; URL=""; SOURCE_LINE="[from: Slack]"
assert_eq "{source} explicit placement is honored (not double-prepended)" \
  "$(expand_template $'header\n{source}\n{selection}' 'SEL')" \
  $'header\n[from: Slack]\nSEL'

CONTEXT_LINE=""; URL=""; SOURCE_LINE=""
assert_eq "no SOURCE_LINE, no {source} token → nothing prepended" \
  "$(expand_template '{selection}' 'SEL')" \
  "SEL"

# ---- match-enrich-rule.py -----------------------------------------------------

MATCH="${DIR}/match-enrich-rule.py"
RULES_FILE="$(mktemp)"
trap 'rm -f "$RULES_FILE"' EXIT

cat > "$RULES_FILE" <<'JSON'
[
  {"match": "bundle", "pattern": "com.mimestream.Mimestream", "text": "Mimestream hit", "displayName": "Mimestream"},
  {"match": "app", "pattern": "Slack", "text": "Slack hit", "displayName": "Slack"},
  {"match": "host", "pattern": "*.atlassian.net", "text": "Atlassian hit", "displayName": "Jira"},
  {"match": "host", "pattern": "docs.google.com", "text": "Doc hit ({url})", "displayName": "Google Docs", "pathPrefix": "/document/"},
  {"match": "host", "pattern": "docs.google.com", "text": "Sheet hit", "displayName": "Google Sheets", "pathPrefix": "/spreadsheets/"},
  {"match": "host", "pattern": "docs.google.com", "text": "Drive fallback hit", "displayName": "Google Drive"}
]
JSON

assert_eq "bundle match" \
  "$(python3 "$MATCH" "$RULES_FILE" com.mimestream.Mimestream "" "" "")" \
  $'Mimestream hit\x1eMimestream'

assert_eq "app match" \
  "$(python3 "$MATCH" "$RULES_FILE" "" "" Slack "")" \
  $'Slack hit\x1eSlack'

assert_eq "host glob match" \
  "$(python3 "$MATCH" "$RULES_FILE" "" foo.atlassian.net "" "")" \
  $'Atlassian hit\x1eJira'

assert_eq "host + pathPrefix: /document/ hits the Docs rule, not the fallback" \
  "$(python3 "$MATCH" "$RULES_FILE" "" docs.google.com "" "https://docs.google.com/document/d/1/edit")" \
  $'Doc hit (https://docs.google.com/document/d/1/edit)\x1eGoogle Docs'

assert_eq "host + pathPrefix: /spreadsheets/ hits the Sheets rule" \
  "$(python3 "$MATCH" "$RULES_FILE" "" docs.google.com "" "https://docs.google.com/spreadsheets/d/1/edit")" \
  $'Sheet hit\x1eGoogle Sheets'

assert_eq "host + pathPrefix: unmatched path falls through to the no-prefix rule" \
  "$(python3 "$MATCH" "$RULES_FILE" "" docs.google.com "" "https://docs.google.com/forms/d/1/edit")" \
  $'Drive fallback hit\x1eGoogle Drive'

assert_eq "no match → empty output" \
  "$(python3 "$MATCH" "$RULES_FILE" com.example.nope example.com "" "")" \
  ""

assert_eq "missing rules file → empty output, no crash" \
  "$(python3 "$MATCH" "/tmp/does-not-exist-$$.json" "" "" "" "")" \
  ""

# ---- send-to-claude.sh URL fallback + legacy To-Do alias --------------------
# The old Services menu uses ACTION=todo. It must keep working as a background
# handoff, and an empty text selection from a browser should capture the URL.

SEND_SCRIPT="${DIR}/send-to-claude.sh"
TODO_URL_OUTPUT="$(
  ACTION=todo \
  DRY_RUN=1 \
  SKIP_SELECTION_CAPTURE=1 \
  SOURCE_BUNDLE="com.google.Chrome" \
  SOURCE_APP_NAME="Google Chrome" \
  SOURCE_URL="https://example.com/task-source" \
  zsh "$SEND_SCRIPT" 2>/dev/null
)"
assert_eq "legacy To-Do Quick Action aliases to background handoff with URL fallback" \
  "$TODO_URL_OUTPUT" \
  "DRY_RUN handoff src=url img=0 sel_bytes=31"

CLAUDE_DRY_OUTPUT="$(ACTION=go DRY_RUN=1 CAPTURED_TEXT=x COMMAND_PROVIDER=claude zsh "$SEND_SCRIPT" 2>/dev/null)"
assert_contains "Claude foreground dry run keeps Claude provider" "$CLAUDE_DRY_OUTPUT" \
  "DRY_RUN open: provider=claude dest=code"

CODEX_DRY_OUTPUT="$(ACTION=go DRY_RUN=1 CAPTURED_TEXT=x COMMAND_PROVIDER=codex CODEX_WORKSPACE='/tmp/project space' zsh "$SEND_SCRIPT" 2>/dev/null)"
assert_contains "Codex foreground dry run preserves workspace with spaces" "$CODEX_DRY_OUTPUT" \
  "provider=codex dest=code workspace=/tmp/project space"
assert_contains "Codex new session uses explicit workspace deep link" "$CODEX_DRY_OUTPUT" \
  "route=codex://threads/new?path=/tmp/project%20space"

CHATGPT_DRY_OUTPUT="$(ACTION=go DRY_RUN=1 CAPTURED_TEXT=x COMMAND_PROVIDER=codex OPENAI_DESTINATION=chat CODEX_WORKSPACE='/tmp/project space' zsh "$SEND_SCRIPT" 2>/dev/null)"
assert_contains "ChatGPT foreground dry run selects general chat without changing provider key" "$CHATGPT_DRY_OUTPUT" \
  "provider=codex dest=chat workspace=/tmp/project space"
assert_contains "ChatGPT new session uses native app command, not Codex deep link" "$CHATGPT_DRY_OUTPUT" \
  "route=native-new-session chars="

CLAUDE_COWORK_DRY_OUTPUT="$(ACTION=comment DRY_RUN=1 CAPTURED_TEXT=x COMMAND_PROVIDER=claude CLAUDE_DESTINATION=cowork zsh "$SEND_SCRIPT" 2>/dev/null)"
assert_contains "Claude Cowork uses installed app deep link contract" "$CLAUDE_COWORK_DRY_OUTPUT" \
  "route=claude://cowork/new"

CLAUDE_CODE_DRY_OUTPUT="$(ACTION=comment DRY_RUN=1 CAPTURED_TEXT=x COMMAND_PROVIDER=claude CLAUDE_DESTINATION=code zsh "$SEND_SCRIPT" 2>/dev/null)"
assert_contains "Claude Code uses installed app deep link contract" "$CLAUDE_CODE_DRY_OUTPUT" \
  "route=claude://code/new"
assert_not_contains "Claude route variable never shadows zsh PATH array" "$(sed -n '/open_new()/,/paste_codex_pending()/p' "$SEND_SCRIPT")" \
  'local path'

SEND_SOURCE="$(cat "$SEND_SCRIPT")"
AGENT_SOURCE="$(cat "${DIR}/agent/main.swift")"
assert_contains "ChatGPT invokes unified app Quick Chat command" "$SEND_SOURCE" \
  'helper_newchat ||'
assert_contains "Quick Chat uses installed app Command-Option-N shortcut" "$AGENT_SOURCE" \
  'posted = postKey(45, cmd: true, opt: isChat, to: parts[1])'
assert_contains "Native session commands target assistant process directly" "$AGENT_SOURCE" \
  'd.postToPid(app.processIdentifier)'
assert_contains "paste targets assistant process when Electron window stays backgrounded" "$SEND_SOURCE" \
  'agent_cmd "pasteapp $TARGET_BUNDLE"'
assert_contains "submit targets assistant process when Electron window stays backgrounded" "$SEND_SOURCE" \
  'agent_cmd "returnapp $TARGET_BUNDLE"'
assert_not_contains "paste fallback no longer rejects non-settable AXValue" "$SEND_SOURCE" \
  'input field is not ready. Open a session and try again.'

INSTALL_SOURCE="$(cat "${DIR}/install-agent.sh")"
assert_contains "fresh install keeps Clipboard History opt-in" "$INSTALL_SOURCE" \
  'defaults write com.claudecommand cliphistoryEnabled -bool false'

DOCTOR_SOURCE="$(cat "${DIR}/doctor.sh")"
assert_contains "doctor accepts built-in shortcuts without override file" "$DOCTOR_SOURCE" \
  'built-in default shortcuts active (no override file)'
assert_not_contains "doctor no longer reports missing override file as failure" "$DOCTOR_SOURCE" \
  'fail "no hotkey config"'

ACTION=comment CAPTURED_TEXT=x COMMAND_PROVIDER=codex OPENAI_DESTINATION=code \
  CODEX_WORKSPACE='/private/tmp/command-definitely-missing-workspace' \
  COMMAND_TEST_ASSUME_APP=1 COMMAND_TEST_SILENT=1 zsh "$SEND_SCRIPT" >/dev/null 2>&1
MISSING_WORKSPACE_STATUS=$?
assert_status "Codex missing workspace fails instead of logging success" "$MISSING_WORKSPACE_STATUS" "1"

TMP_NON_GIT_WORKSPACE="$(mktemp -d)"
ACTION=comment CAPTURED_TEXT=x COMMAND_PROVIDER=codex OPENAI_DESTINATION=code \
  CODEX_WORKSPACE="$TMP_NON_GIT_WORKSPACE" \
  COMMAND_TEST_ASSUME_APP=1 COMMAND_TEST_SILENT=1 zsh "$SEND_SCRIPT" >/dev/null 2>&1
NON_GIT_WORKSPACE_STATUS=$?
assert_status "Codex non-Git workspace fails instead of logging success" "$NON_GIT_WORKSPACE_STATUS" "1"

# ---- capture-handoff.sh compatibility path ---------------------------------
# ClaudeCommand's native background actions use submit-cli.js --retry-prompt
# directly, but capture-handoff.sh remains as a compatibility entry point for
# external callers. Keep the old bridge covered so future cleanup is deliberate.

CAPTURE_SCRIPT="${DIR}/capture-handoff.sh"
TMP_CAPTURE_BASE="$(mktemp -d)"
TMP_MISSING_CORE="$(mktemp -d)"
TMP_FAKE_CORE="$(mktemp -d)"
trap 'rm -f "$RULES_FILE"; rm -rf "$TMP_NON_GIT_WORKSPACE" "$TMP_CAPTURE_BASE" "$TMP_MISSING_CORE" "$TMP_FAKE_CORE"' EXIT

set +e
CLAUDE_CAPTURE_CORE="$TMP_MISSING_CORE" \
CLAUDE_CAPTURE_HOME="$TMP_CAPTURE_BASE" \
zsh "$CAPTURE_SCRIPT" >/dev/null 2>/dev/null <<<"hello"
MISSING_CAPTURE_STATUS="$?"
set -e
assert_status "capture-handoff missing core exits with failure" "$MISSING_CAPTURE_STATUS" "1"

mkdir -p "$TMP_FAKE_CORE/bin"
cat > "$TMP_FAKE_CORE/bin/submit-cli.js" <<'JS'
const fs = require('fs');
const path = process.env.CLAUDE_CAPTURE_TEST_OUT;
let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => { input += chunk; });
process.stdin.on('end', () => {
  fs.writeFileSync(path, JSON.stringify({ argv: process.argv.slice(2), input }));
});
JS

CAPTURE_OUT="${TMP_CAPTURE_BASE}/capture-output.json"
CLAUDE_CAPTURE_CORE="$TMP_FAKE_CORE" \
CLAUDE_CAPTURE_HOME="$TMP_CAPTURE_BASE" \
HANDOFF_SOURCE="popup" \
HANDOFF_CONTEXT="[from: Notes]" \
CLAUDE_CAPTURE_TEST_OUT="$CAPTURE_OUT" \
zsh "$CAPTURE_SCRIPT" >/dev/null 2>/dev/null <<<"Captured text"
assert_status "capture-handoff text path exits successfully" "$?" "0"

assert_eq "capture-handoff passes context plus text to submit-cli" \
  "$(python3 - "$CAPTURE_OUT" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(d["input"])
PY
)" \
  $'[from: Notes]\nCaptured text'

assert_eq "capture-handoff invokes submit-cli with text capture args" \
  "$(python3 - "$CAPTURE_OUT" "$TMP_CAPTURE_BASE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
base = sys.argv[2]
expected = ["--base-dir", base, "--source", "popup", "--kind", "text"]
print("ok" if d["argv"] == expected else d["argv"])
PY
)" \
  "ok"

print -r -- ""
print -r -- "shell tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
