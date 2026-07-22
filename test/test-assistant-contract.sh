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

menu_shortcut() {
  /usr/bin/osascript - "$1" "$2" "$3" <<'APPLESCRIPT'
on run argv
    set processName to item 1 of argv
    set menuName to item 2 of argv
    set itemName to item 3 of argv
    tell application "System Events"
        tell process processName
            tell menu item itemName of menu 1 of menu bar item menuName of menu bar 1
                set shortcutChar to value of attribute "AXMenuItemCmdChar"
                set shortcutModifiers to value of attribute "AXMenuItemCmdModifiers"
            end tell
        end tell
    end tell
    return (shortcutChar as text) & "|" & (shortcutModifiers as text)
end run
APPLESCRIPT
}

process_running() {
  /usr/bin/osascript - "$1" <<'APPLESCRIPT'
on run argv
    tell application "System Events" to return exists process (item 1 of argv)
end run
APPLESCRIPT
}

CHATGPT_APP="/Applications/ChatGPT.app"
CLAUDE_APP="/Applications/Claude.app"

if [ -d "$CHATGPT_APP" ]; then
  CHATGPT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$CHATGPT_APP/Contents/Info.plist" 2>/dev/null || true)"
  print -- "ChatGPT ${CHATGPT_VERSION:-unknown}"
  CHATGPT_URL_TYPES="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes' "$CHATGPT_APP/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$CHATGPT_URL_TYPES" == *"codex"* ]] && pass "ChatGPT registers codex URL scheme" || fail "ChatGPT registers codex URL scheme"
  ASAR="$CHATGPT_APP/Contents/Resources/app.asar"
  if [ -f "$ASAR" ] && LC_ALL=C /usr/bin/grep -aFq 'id:`quickChat`' "$ASAR" && \
     LC_ALL=C /usr/bin/grep -aFq 'CmdOrCtrl+Alt+N' "$ASAR"; then
    pass "ChatGPT Quick Chat contract is Command-Option-N"
  else
    fail "ChatGPT Quick Chat contract is Command-Option-N"
  fi
  if [ -f "$ASAR" ] && LC_ALL=C /usr/bin/grep -aFq 'New Task' "$ASAR" && \
     LC_ALL=C /usr/bin/grep -aFq 'CmdOrCtrl+N' "$ASAR"; then
    pass "ChatGPT New Task resource contract is Command-N"
  else
    fail "ChatGPT New Task resource contract is Command-N"
  fi
  if [ -f "$ASAR" ] && LC_ALL=C /usr/bin/grep -aFq 'New Projectless Task' "$ASAR" && \
     LC_ALL=C /usr/bin/grep -aFq 'CmdOrCtrl+Alt+O' "$ASAR"; then
    pass "ChatGPT New Projectless Task resource contract is Command-Option-O"
  else
    fail "ChatGPT New Projectless Task resource contract is Command-Option-O"
  fi
  if [ "$(process_running ChatGPT 2>/dev/null || true)" = "true" ]; then
    assert_eq "ChatGPT New Task menu is Command-N" "$(menu_shortcut ChatGPT File 'New Task' 2>/dev/null || true)" "N|0"
    assert_eq "ChatGPT New Projectless Task menu is Command-Option-O" "$(menu_shortcut ChatGPT File 'New Projectless Task' 2>/dev/null || true)" "O|2"
  else
    skip "ChatGPT menu checks (app not running)"
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
  if [ -f "$CLAUDE_ASAR" ] && LC_ALL=C /usr/bin/grep -aFq 'New Conversation' "$CLAUDE_ASAR" && \
     LC_ALL=C /usr/bin/grep -aFq 'CmdOrCtrl+N' "$CLAUDE_ASAR"; then
    pass "Claude New Conversation resource contract is Command-N"
  else
    fail "Claude New Conversation resource contract is Command-N"
  fi
  if [ "$(process_running Claude 2>/dev/null || true)" = "true" ]; then
    assert_eq "Claude New Conversation menu is Command-N" "$(menu_shortcut Claude File 'New Conversation' 2>/dev/null || true)" "N|0"
  else
    skip "Claude menu checks (app not running)"
  fi
else
  fail "Claude app installed at /Applications/Claude.app"
fi

print -- ""
print -- "${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
(( FAIL == 0 )) || exit 1
(( SKIP == 0 )) || exit 2
