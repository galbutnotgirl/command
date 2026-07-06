#!/bin/zsh
# doctor.sh — validate a Claude Command install from the terminal.
#
# Complements the menu-bar window's Set Up tab. NOTE: Accessibility / Screen
# Recording are TCC grants attributed to CommandAgent.app — a shell script can't
# read them accurately, so those live in the Set Up tab. This checks everything
# else: builds, services, config, Quick Actions, and the Claude desktop app.
emulate -L zsh
set -uo pipefail

DIR="${0:A:h}"
UID_NUM="$(id -u)"
STATE="${HOME}/.claude/state"
SERVICES="${HOME}/Library/Services"
AGENT_LABEL="com.claudecommand"
CLIP_LABEL="com.claudecommand.clipwatch"
CLAUDE_BUNDLE="com.anthropic.claudefordesktop"

warn=0
pass(){ print -- "  ✓ $1"; }
fail(){ print -- "  ✗ $1"; (( warn++ )) || true; }
note(){ print -- "    → $1"; }

print -- "Claude Command — doctor"
print -- "(Accessibility / Screen Recording: open the menu-bar window ▸ Set Up for live status)"
print -- ""

print -- "Builds"
[ -x "${DIR}/ClaudeCommand.app/Contents/MacOS/ClaudeCommand" ] \
  && pass "ClaudeCommand.app built" \
  || { fail "ClaudeCommand.app missing"; note "run ./build-agent.sh"; }
[ -x "${DIR}/SendHelper.app/Contents/MacOS/sendhelper" ] \
  && pass "SendHelper.app built (keystroke fallback)" \
  || { fail "SendHelper.app missing"; note "run ./build-helper.sh (fallback only — agent socket is primary)"; }

print -- "Services"
launchctl print "gui/${UID_NUM}/${AGENT_LABEL}" >/dev/null 2>&1 \
  && pass "agent LaunchAgent loaded" \
  || { fail "agent LaunchAgent not loaded"; note "run ./install-agent.sh"; }
[ -S "${STATE}/command-agent.sock" ] \
  && pass "agent socket up" \
  || { fail "agent socket missing"; note "agent not running — see ~/.claude/logs/command-agent.err (often a missing Accessibility grant)"; }
launchctl print "gui/${UID_NUM}/${CLIP_LABEL}" >/dev/null 2>&1 \
  && pass "clipwatch daemon loaded" \
  || { fail "clipwatch daemon not loaded"; note "run ./install-clipwatch.sh"; }

print -- "Config"
[ -f "${STATE}/command-hotkeys.json" ] \
  && pass "hotkeys configured" \
  || { fail "no hotkey config"; note "run ./set-hotkeys.sh (or rebind in the Shortcuts tab)"; }
qa=("${SERVICES}/Claude - "*.workflow(N))
(( ${#qa} > 0 )) \
  && pass "Quick Actions installed (${#qa})" \
  || { fail "no Quick Actions"; note "run ./install-quick-action.sh"; }

# clipboard retention (set in the About tab → command-config.json; default 7)
if [ -f "${STATE}/command-config.json" ]; then
  days="$(/usr/bin/python3 -c "import json;print(json.load(open('${STATE}/command-config.json')).get('retentionDays',7))" 2>/dev/null)"
  pass "clipboard retention: ${days:-7} days"
else
  pass "clipboard retention: 7 days (default — set it in the About tab)"
fi
if [ -f "${STATE}/cliphistory/index.json" ]; then
  items="$(/usr/bin/python3 -c "import json;print(len(json.load(open('${STATE}/cliphistory/index.json'))))" 2>/dev/null)"
  pass "clipboard history: ${items:-0} items stored"
fi

print -- "Claude Code desktop app"
if mdfind "kMDItemCFBundleIdentifier == '${CLAUDE_BUNDLE}'" 2>/dev/null | grep -q .; then
  pass "Claude desktop app found"
else
  fail "Claude desktop app not found"; note "install it — every action opens claude://code/…"
fi

print -- "Skill handoff (background trigger)"
HANDOFF_BASE="${CLAUDE_CAPTURE_HOME:-${HOME}/Library/Application Support/claude-command}"
if command -v node >/dev/null 2>&1; then
  NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null)"
  if [ "${NODE_MAJOR:-0}" -ge 20 ]; then
    pass "node $(node --version 2>/dev/null) found"
  else
    fail "node too old ($(node --version 2>/dev/null)) — handoff core needs 20+"; note "brew install node"
  fi
else
  fail "node not found"; note "brew install node — required for the handoff pipeline"
fi
[ -x "${DIR}/capture-handoff.sh" ] \
  && pass "capture-handoff.sh present" \
  || { fail "capture-handoff.sh missing"; note "re-clone or git checkout capture-handoff.sh"; }
[ -f "${DIR}/vendor/claude-command-capture/bin/submit-cli.js" ] \
  && pass "vendor handoff core present" \
  || { fail "vendor/claude-command-capture missing"; note "git checkout vendor/"; }
BUNDLED_HANDOFF="${DIR}/ClaudeCommand.app/Contents/Resources/capture-handoff.sh"
if [ -f "$BUNDLED_HANDOFF" ]; then
  pass "handoff bundled into ClaudeCommand.app"
else
  fail "handoff not bundled into ClaudeCommand.app"; note "rebuild: ./build-agent.sh (older build predates the handoff feature)"
fi
if [ -f "${HANDOFF_BASE}/settings.json" ]; then
  HANDOFF_INFO="$(/usr/bin/python3 - "${HANDOFF_BASE}/settings.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
print((d.get("skill") or "").strip().lstrip("/") or "-")
print((d.get("cli", {}).get("command") or "claude").strip())
PY
)"
  HANDOFF_SKILL="${HANDOFF_INFO%%$'\n'*}"; HANDOFF_CLI="${HANDOFF_INFO##*$'\n'}"
  if [ -z "$HANDOFF_INFO" ]; then
    fail "handoff settings.json unreadable"; note "fix or delete ${HANDOFF_BASE}/settings.json"
  elif [ "$HANDOFF_SKILL" = "-" ]; then
    fail "no skill configured"; note "menu bar ▸ Handoffs ▸ Handoff Settings… — set the skill name"
  else
    pass "skill configured: /${HANDOFF_SKILL}"
  fi
  if command -v "${HANDOFF_CLI:-claude}" >/dev/null 2>&1 || [ -x "${HANDOFF_CLI:-claude}" ]; then
    pass "handoff CLI reachable (${HANDOFF_CLI:-claude})"
  else
    fail "handoff CLI not found (${HANDOFF_CLI:-claude})"; note "set an absolute path in Handoff Settings"
  fi
else
  note "no handoff settings yet — menu bar ▸ Handoffs ▸ Handoff Settings… (optional feature)"
fi
subs=("${HANDOFF_BASE}/submissions/"*.json(N))
(( ${#subs} > 0 )) && pass "submission records: ${#subs}"

print -- "Dictation"

# Mic/speech TCC can't be queried from shell — prompt user to verify manually.
print -- "  ⚠  Microphone: System Settings → Privacy & Security → Microphone → confirm ClaudeCommand is enabled"
print -- "  ⚠  Speech Recognition: System Settings → Privacy & Security → Speech Recognition → confirm ClaudeCommand is enabled"

VOCAB_FILE="${STATE}/dictation-vocab.json"
[ -f "${VOCAB_FILE}" ] \
  && pass "dictation-vocab.json exists ($(wc -c < "${VOCAB_FILE}" | tr -d ' ') bytes)" \
  || note "dictation-vocab.json not set — add custom terms in Settings → Dictation (optional)"

if command -v whisper-cli >/dev/null 2>&1; then
  pass "whisper-cli found at $(command -v whisper-cli)"
elif command -v whisper >/dev/null 2>&1; then
  pass "whisper found at $(command -v whisper)"
else
  note "whisper-cli not found — optional for post-processing accuracy (brew install whisper-cpp)"
fi

print -- ""
if (( warn == 0 )); then
  print -- "All component checks passed. If a hotkey still does nothing, grant Accessibility in the Set Up tab."
else
  print -- "${warn} issue(s) above — follow the → hints. Permissions live in the menu-bar Set Up tab."
fi
