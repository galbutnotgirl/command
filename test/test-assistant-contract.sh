#!/bin/zsh
# Read-only compatibility check against installed Claude and ChatGPT builds.
# Launch both apps first so macOS exposes their current application menus.
emulate -L zsh
set -uo pipefail

PASS=0
FAIL=0
SKIP=0

pass() { PASS=$((PASS + 1)); print -- "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); print -- "FAIL: $1${2:+ ($2)}"; }
skip() { SKIP=$((SKIP + 1)); print -- "SKIP: $1"; }

assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"
  else fail "$1" "expected $3, got ${2:-empty}"; fi
}

CHATGPT_APP="/Applications/ChatGPT.app"
CLAUDE_APP="/Applications/Claude.app"
ASAR_CONTRACT="${0:A:h}/asar-contract.js"

if [ -d "$CHATGPT_APP" ]; then
  CHATGPT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$CHATGPT_APP/Contents/Info.plist" 2>/dev/null || true)"
  print -- "ChatGPT ${CHATGPT_VERSION:-unknown}"
  CHATGPT_URL_TYPES="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes' "$CHATGPT_APP/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$CHATGPT_URL_TYPES" == *"codex"* ]] && pass "ChatGPT registers codex URL scheme" || fail "ChatGPT registers codex URL scheme"
  ASAR="$CHATGPT_APP/Contents/Resources/app.asar"
  if [ -f "$ASAR" ] && node "$ASAR_CONTRACT" "$ASAR" \
      'id:`quickChat`' 'CmdOrCtrl\+Alt\+N' >/dev/null 2>&1; then
    pass "ChatGPT Quick Chat contract is Command-Option-N"
  else
    fail "ChatGPT Quick Chat contract is Command-Option-N"
  fi
  if [ -f "$ASAR" ] && node "$ASAR_CONTRACT" "$ASAR" \
      'New Task' 'CmdOrCtrl\+N' >/dev/null 2>&1; then
    pass "ChatGPT New Task resource contract is Command-N"
  else
    fail "ChatGPT New Task resource contract is Command-N"
  fi
  if [ -f "$ASAR" ] && node "$ASAR_CONTRACT" "$ASAR" \
      'New Projectless Task' 'CmdOrCtrl\+Alt\+O' >/dev/null 2>&1; then
    pass "ChatGPT New Projectless Task resource contract is Command-Option-O"
  else
    fail "ChatGPT New Projectless Task resource contract is Command-Option-O"
  fi
else
  fail "ChatGPT app installed at /Applications/ChatGPT.app"
fi

if [ -d "$CLAUDE_APP" ]; then
  CLAUDE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$CLAUDE_APP/Contents/Info.plist" 2>/dev/null || true)"
  print -- "Claude ${CLAUDE_VERSION:-unknown}"
  CLAUDE_URL_TYPES="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes' "$CLAUDE_APP/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$CLAUDE_URL_TYPES" == *"claude"* ]] && pass "Claude registers claude URL scheme" || fail "Claude registers claude URL scheme"
  CLAUDE_ASAR="$CLAUDE_APP/Contents/Resources/app.asar"
  if [ -f "$CLAUDE_ASAR" ] && node "$ASAR_CONTRACT" "$CLAUDE_ASAR" \
      'New Conversation' 'CmdOrCtrl\+N' >/dev/null 2>&1; then
    pass "Claude New Conversation resource contract is Command-N"
  else
    fail "Claude New Conversation resource contract is Command-N"
  fi
  if node "$ASAR_CONTRACT" "$CLAUDE_ASAR" \
      '\[\["claude\.ai",[A-Za-z_$][A-Za-z0-9_$]*=>[A-Za-z_$][A-Za-z0-9_$]*==="/new",[A-Za-z_$][A-Za-z0-9_$]*\]' \
      'new Set\(\["q"\]\)' >/dev/null 2>&1; then
    pass "Claude Chat deep link accepts /new with q"
  else
    fail "Claude Chat deep link accepts /new with q"
  fi
  if node "$ASAR_CONTRACT" "$CLAUDE_ASAR" \
      '\["cowork",[A-Za-z_$][A-Za-z0-9_$]*=>[A-Za-z_$][A-Za-z0-9_$]*==="/new",[A-Za-z_$][A-Za-z0-9_$]*\]' \
      'claudeURLHandler: unrecognized cowork path' >/dev/null 2>&1; then
    pass "Claude Cowork deep link accepts /new with q"
  else
    fail "Claude Cowork deep link accepts /new with q"
  fi
  if node "$ASAR_CONTRACT" "$CLAUDE_ASAR" \
      'pathname!=="/new".{0,200}claudeURLHandler: unrecognized code path' \
      'searchParams\.get\("q"\)\?\?.{0,100}searchParams\.get\("prompt"\)' \
      'desktop_code_deeplink_received' >/dev/null 2>&1; then
    pass "Claude Code deep link accepts /new with q or prompt"
  else
    fail "Claude Code deep link accepts /new with q or prompt"
  fi
else
  fail "Claude app installed at /Applications/Claude.app"
fi

print -- ""
print -- "${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
(( FAIL == 0 )) || exit 1
(( SKIP == 0 )) || exit 2
