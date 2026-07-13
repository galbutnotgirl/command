#!/bin/zsh
# doctor.sh — validate a Command install from the terminal.
#
# Complements the menu-bar window's Set Up tab. NOTE: Accessibility / Screen
# Recording are TCC grants attributed to Command.app — a shell script can't
# read them accurately, so those live in the Set Up tab. This checks everything
# else: builds, background service, config, optional Quick Actions, and Claude.
emulate -L zsh
set -uo pipefail

DIR="${0:A:h}"
UID_NUM="$(id -u)"
STATE="${HOME}/.claude/state"
SERVICES="${HOME}/Library/Services"
AGENT_LABEL="com.claudecommand"
CLAUDE_BUNDLE="com.anthropic.claudefordesktop"
BUILT_APP="${DIR}/Command.app"
INSTALLED_APP="${HOME}/Applications/Command.app"
EXPECTED_BUNDLE_ID="com.claudecommand"
EXPECTED_MIN_MACOS="14.0"
EXPECTED_VERSION="$( [ -f "${DIR}/VERSION" ] && tr -d ' \t\n' < "${DIR}/VERSION" || echo "" )"

warn=0
pass(){ print -- "  ✓ $1"; }
fail(){ print -- "  ✗ $1"; (( warn++ )) || true; }
note(){ print -- "    → $1"; }

print -- "Command — doctor"
print -- "(Accessibility / Screen Recording: open the menu-bar window ▸ Set Up for live status)"
print -- ""

print -- "Builds"
[ -x "${BUILT_APP}/Contents/MacOS/Command" ] \
  && pass "Command.app built" \
  || note "source Command.app not built — run ./build-agent.sh only when creating a new local bundle"

check_app_metadata() {
  local label="$1"
  local app="$2"
  local required="$3"
  local plist="${app}/Contents/Info.plist"
  if [ ! -d "$app" ]; then
    if [ "$required" = "required" ]; then
      fail "${label} missing"; note "run ./install-agent.sh"
    else
      note "${label} missing — run ./build-agent.sh"
    fi
    return
  fi
  if [ ! -f "$plist" ]; then
    if [ "$required" = "required" ]; then
      fail "${label} Info.plist missing"
    else
      note "${label} is incomplete — run ./build-agent.sh only when creating a new local bundle"
    fi
    return
  fi
  local version bundle min_macos docs_index
  version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist" 2>/dev/null || true)"
  bundle="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist" 2>/dev/null || true)"
  min_macos="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$plist" 2>/dev/null || true)"
  if [ -n "$EXPECTED_VERSION" ] && [ "$version" != "$EXPECTED_VERSION" ]; then
    fail "${label} version ${version:-missing}, expected ${EXPECTED_VERSION}"
  else
    pass "${label} version ${version:-unknown}"
  fi
  [ "$bundle" = "$EXPECTED_BUNDLE_ID" ] \
    && pass "${label} bundle id ${bundle}" \
    || fail "${label} bundle id ${bundle:-missing}, expected ${EXPECTED_BUNDLE_ID}"
  [ "$min_macos" = "$EXPECTED_MIN_MACOS" ] \
    && pass "${label} minimum macOS ${min_macos}" \
    || fail "${label} minimum macOS ${min_macos:-missing}, expected ${EXPECTED_MIN_MACOS}"
  [ -x "${app}/Contents/MacOS/Command" ] \
    && pass "${label} executable present" \
    || fail "${label} executable missing or not executable"
  docs_index="${app}/Contents/Resources/docs/index.html"
  [ -f "$docs_index" ] \
    && pass "${label} bundled docs present" \
    || { fail "${label} bundled docs missing"; note "run ./build-agent.sh"; }
}

check_app_metadata "built app" "$BUILT_APP" "optional"
check_app_metadata "installed app" "$INSTALLED_APP" "required"
if [ -x "${DIR}/SendHelper.app/Contents/MacOS/sendhelper" ]; then
  pass "SendHelper.app built (optional keystroke fallback)"
else
  note "SendHelper.app not built — optional fallback only; app dispatch socket is primary"
fi

print -- "Background service"
launchctl print "gui/${UID_NUM}/${AGENT_LABEL}" >/dev/null 2>&1 \
  && pass "Command LaunchAgent loaded" \
  || { fail "Command LaunchAgent not loaded"; note "run ./install-agent.sh"; }
AGENT_PLIST="${HOME}/Library/LaunchAgents/${AGENT_LABEL}.plist"
EXPECTED_AGENT_PROGRAM="${INSTALLED_APP}/Contents/MacOS/Command"
if [ -f "$AGENT_PLIST" ]; then
  AGENT_PROGRAM="$(/usr/libexec/PlistBuddy -c "Print :Program" "$AGENT_PLIST" 2>/dev/null || true)"
  if [ "$AGENT_PROGRAM" = "$EXPECTED_AGENT_PROGRAM" ]; then
    pass "LaunchAgent Program points at installed Command.app"
  else
    fail "LaunchAgent Program points at ${AGENT_PROGRAM:-missing}"
    note "expected ${EXPECTED_AGENT_PROGRAM}; toggle Launch at login off/on or run ./install-agent.sh"
  fi
else
  fail "LaunchAgent plist missing"
  note "toggle Launch at login on in Settings -> About or run ./install-agent.sh"
fi
[ -S "${STATE}/command-agent.sock" ] \
  && pass "app dispatch socket up" \
  || { fail "app dispatch socket missing"; note "Command is not ready — see ~/.claude/logs/command-agent.err (often a missing Accessibility grant)"; }
CLIP_ENABLED="$(defaults read com.claudecommand cliphistoryEnabled 2>/dev/null || echo 1)"
if [ "${CLIP_ENABLED}" = "0" ]; then
  note "Clipboard History disabled in Settings"
else
  CLIPWATCH_STATUS=0
  pgrep -f "[c]lipwatch.py" >/dev/null 2>&1 || CLIPWATCH_STATUS=$?
  if [ "${CLIPWATCH_STATUS}" = "0" ]; then
    pass "Clipboard History running (bundled with Command)"
  elif [ "${CLIPWATCH_STATUS}" = "3" ]; then
    note "Clipboard History process list unavailable here — check Set Up if Clipboard History is not updating"
  else
    fail "Clipboard History not running"; note "run ./install-agent.sh, then enable Clipboard History in Settings if needed"
  fi
fi

print -- "Config"
[ -f "${STATE}/command-hotkeys.json" ] \
  && pass "custom hotkeys configured" \
  || pass "built-in default shortcuts active (no override file)"
qa=("${SERVICES}/Claude - "*.workflow(N))
(( ${#qa} > 0 )) \
  && pass "Quick Actions installed (${#qa})" \
  || note "Quick Actions not installed — optional source-only Services; global shortcuts do not need them"

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
CLAUDE_APP_ID="$(osascript -e 'id of app "Claude"' 2>/dev/null || true)"
if mdfind "kMDItemCFBundleIdentifier == '${CLAUDE_BUNDLE}'" 2>/dev/null | grep -q .; then
  pass "Claude desktop app found"
elif [ -d "/Applications/Claude.app" ] || [ -d "${HOME}/Applications/Claude.app" ]; then
  pass "Claude desktop app found at standard app path"
elif [ -n "${CLAUDE_APP_ID}" ]; then
  pass "Claude desktop app found (${CLAUDE_APP_ID})"
else
  fail "Claude desktop app not found"; note "install it — every action opens claude://code/…"
fi

print -- "Background actions"
HANDOFF_BASE="${CLAUDE_CAPTURE_HOME:-${HOME}/Library/Application Support/claude-command}"
CUSTOM_ACTIONS_FILE="${STATE}/custom-actions.json"
BACKGROUND_ACTIONS=0
if [ -f "${CUSTOM_ACTIONS_FILE}" ]; then
  BACKGROUND_ACTIONS="$(/usr/bin/python3 - "${CUSTOM_ACTIONS_FILE}" <<'PY' 2>/dev/null || echo 0
import json, sys
try:
    actions = json.load(open(sys.argv[1]))
except Exception:
    print(0)
    raise SystemExit
count = 0
for action in actions if isinstance(actions, list) else []:
    if not isinstance(action, dict) or action.get("enabled") is False:
        continue
    if action.get("delivery") == "background" or action.get("isHandoff") is True:
        count += 1
        continue
    triggers = action.get("triggers") or []
    if any(isinstance(t, dict) and t.get("enabled") is not False and t.get("deliveryOverride") == "background" for t in triggers):
        count += 1
print(count)
PY
)"
fi
if (( ${BACKGROUND_ACTIONS:-0} > 0 )); then
  pass "Background actions configured: ${BACKGROUND_ACTIONS}"
else
  note "no Background actions configured — CLI checks are optional"
fi

if command -v node >/dev/null 2>&1; then
  NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null)"
  if [ "${NODE_MAJOR:-0}" -ge 20 ]; then
    pass "node $(node --version 2>/dev/null) found"
  elif (( ${BACKGROUND_ACTIONS:-0} > 0 )); then
    fail "node too old ($(node --version 2>/dev/null)) — Background delivery needs 20+"; note "brew install node"
  else
    note "node too old ($(node --version 2>/dev/null)) — only needed for Background delivery"
  fi
elif (( ${BACKGROUND_ACTIONS:-0} > 0 )); then
  fail "node not found"; note "brew install node — required for configured Background actions"
else
  note "node not found — only needed for Background delivery"
fi
if [ -x "${DIR}/capture-handoff.sh" ]; then
  pass "capture-handoff.sh present"
elif (( ${BACKGROUND_ACTIONS:-0} > 0 )); then
  fail "capture-handoff.sh missing"; note "re-clone or git checkout capture-handoff.sh"
else
  note "capture-handoff.sh missing — only needed for Background delivery"
fi
if [ -f "${DIR}/vendor/claude-command-capture/bin/submit-cli.js" ]; then
  pass "vendor background core present"
elif (( ${BACKGROUND_ACTIONS:-0} > 0 )); then
  fail "vendor/claude-command-capture missing"; note "git checkout vendor/"
else
  note "vendor background core missing — only needed for Background delivery"
fi
BUNDLED_HANDOFF="${DIR}/Command.app/Contents/Resources/capture-handoff.sh"
if [ -f "$BUNDLED_HANDOFF" ]; then
  pass "background runner bundled into Command.app"
elif (( ${BACKGROUND_ACTIONS:-0} > 0 )); then
  fail "background runner not bundled into Command.app"; note "rebuild: ./build-agent.sh"
else
  note "background runner not bundled — only needed for Background delivery"
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
    if (( ${BACKGROUND_ACTIONS:-0} > 0 )); then
      fail "background settings.json unreadable"; note "fix or delete ${HANDOFF_BASE}/settings.json"
    else
      note "background settings.json unreadable — only matters for Background delivery"
    fi
  elif [ "$HANDOFF_SKILL" = "-" ]; then
    note "no default skill configured — optional unless a background action needs one"
  else
    pass "skill configured: /${HANDOFF_SKILL}"
  fi
  if command -v "${HANDOFF_CLI:-claude}" >/dev/null 2>&1 || [ -x "${HANDOFF_CLI:-claude}" ]; then
    pass "background CLI reachable (${HANDOFF_CLI:-claude})"
  elif (( ${BACKGROUND_ACTIONS:-0} > 0 )); then
    fail "background CLI not found (${HANDOFF_CLI:-claude})"; note "set an absolute path in Command History ▸ Background Settings…"
  else
    note "background CLI not found (${HANDOFF_CLI:-claude}) — only needed for Background delivery"
  fi
else
  note "no background settings yet — Settings ▸ Command History ▸ Background Settings… (optional feature)"
fi
subs=("${HANDOFF_BASE}/submissions/"*.json(N))
(( ${#subs} > 0 )) && pass "submission records: ${#subs}"

print -- "Dictation"

# Microphone TCC can't be queried reliably from this shell. Command's
# current dictation path is Parakeet/AVAudio; Speech Recognition permission is
# not required.
print -- "  ⚠  Microphone: System Settings → Privacy & Security → Microphone → confirm Command is enabled"
print -- "    → Speech Recognition permission is not required for current Parakeet dictation"
print -- "    → Open Settings → Set Up / Dictation Settings for live microphone and model status"

DICTATION_DIR="${HOME}/Library/Application Support/DictationLab"
VOCAB_FILE="${DICTATION_DIR}/vocabulary.json"
HISTORY_FILE="${DICTATION_DIR}/history.json"
[ -f "${VOCAB_FILE}" ] \
  && pass "dictation vocabulary exists ($(wc -c < "${VOCAB_FILE}" | tr -d ' ') bytes)" \
  || note "dictation vocabulary not set — add custom terms in Settings → Vocabulary (optional)"
[ -f "${HISTORY_FILE}" ] \
  && pass "dictation history exists ($(wc -c < "${HISTORY_FILE}" | tr -d ' ') bytes)" \
  || note "dictation history not created yet — use a Dictate shortcut once (optional)"

print -- ""
if (( warn == 0 )); then
  print -- "All component checks passed. If a hotkey still does nothing, grant Accessibility in the Set Up tab."
else
  print -- "${warn} issue(s) above — follow the → hints. Permissions live in the menu-bar Set Up tab."
fi
