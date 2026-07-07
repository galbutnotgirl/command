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

print -r -- ""
print -r -- "shell tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
