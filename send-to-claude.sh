#!/bin/zsh
# send-to-claude.sh (v3)
# Grab current selection (text OR image) + source context and hand it to selected
# desktop assistant. Claude supports Chat/Cowork/Code through claude://. ChatGPT
# supports ChatGPT general chat plus workspace-aware Codex through ChatGPT app.
#
# ACTIONs (each wired to a right-click Quick Action):
#   go        Background-feel: open a NEW Claude Code session, auto-submit, then
#             return focus to where you were. Claude researches context + acts.
#   comment   Open a NEW Claude Code session, pre-filled. Stays foreground so you
#             add a note and send. No auto-submit.
#   add       Paste the selection into the ALREADY-OPEN Claude Code chat.
#   handoff   Submit captured content to the background runner.
#   todo      Legacy Quick Action alias for handoff.
#
# Selection: $@ args (testing) › stdin (Service) › auto-⌘C via the signed helper.
#   - Fresh selection (clipboard changed on ⌘C) is always used.
#   - If nothing was selected, the existing clipboard is used ONLY if it's fresh
#     (<CLIP_TTL, per the clipwatch daemon) AND not from a blocked/secret app.
#   - Images ride the clipboard and are PASTED into the new session (no temp file).
#
# Config: ACTION, CLIP_TTL=60, INCLUDE_CONTEXT=1, DRY_RUN=1.

emulate -L zsh
set -uo pipefail
export PATH="/opt/homebrew/bin:${HOME}/.claude/local:${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"

LOG_FILE="${HOME}/Library/Logs/claude-command.log"
DO_LOG="${HOME}/.claude/logs/claude-command-bg.log"
STATE="${HOME}/.claude/state/clipboard.json"
COPY_SOURCE="${HOME}/.claude/state/last_copy.json"
ACTION="${ACTION:-comment}"
if [ "$ACTION" = "todo" ]; then ACTION="handoff"; fi
CLIP_TTL="${CLIP_TTL:-60}"
INCLUDE_CONTEXT="${INCLUDE_CONTEXT:-1}"
DRY_RUN="${DRY_RUN:-0}"
SCRIPT_DIR="${0:A:h}"
HELPER_APP="${SCRIPT_DIR}/SendHelper.app"
HELPER="${HELPER_APP}/Contents/MacOS/sendhelper"
AGENT_SOCK="${AGENT_SOCK:-${HOME}/.claude/state/command-agent.sock}"
SOURCE_BUNDLE="${SOURCE_BUNDLE:-}"   # set by Command when a hotkey fires
SOURCE_APP_NAME="${SOURCE_APP_NAME:-}"
SKIP_SELECTION_CAPTURE="${SKIP_SELECTION_CAPTURE:-0}"   # tests only: jump straight to URL fallback
COMMAND_PROVIDER="${COMMAND_PROVIDER:-claude}"
CLAUDE_DESTINATION="${CLAUDE_DESTINATION:-code}"
OPENAI_DESTINATION="${OPENAI_DESTINATION:-code}"
CODEX_WORKSPACE="${CODEX_WORKSPACE:-${HOME}}"
CODEX_WORKSPACE="${CODEX_WORKSPACE/#\~/$HOME}"
BUILTIN_AUTO_SUBMIT="${BUILTIN_AUTO_SUBMIT:-}"
CLAUDE_BUNDLE="com.anthropic.claudefordesktop"   # chat/cowork/code are all this one app
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude 2>/dev/null)}"
CODEX_BUNDLE="com.openai.codex"
CODEX_BIN="${CODEX_BIN:-$(command -v codex 2>/dev/null)}"
[ -n "$CODEX_BIN" ] || [ ! -x /Applications/ChatGPT.app/Contents/Resources/codex ] || CODEX_BIN=/Applications/ChatGPT.app/Contents/Resources/codex
if [ "$COMMAND_PROVIDER" = "codex" ]; then
  TARGET_BUNDLE="$CODEX_BUNDLE"
  [ "$OPENAI_DESTINATION" = "chat" ] && TARGET_LABEL="ChatGPT" || TARGET_LABEL="Codex"
else
  TARGET_BUNDLE="$CLAUDE_BUNDLE"; TARGET_LABEL="Claude"
fi

# All paths below are absolute (SCRIPT_DIR/STATE/HELPER via ${0:A}); nothing uses
# the cwd. Move to / so Python's `-c` import scan (sys.path[0]=cwd) never hits a
# TCC-protected folder (Desktop/Documents/iCloud) → "Operation not permitted".
cd / 2>/dev/null || true

# Apps whose copies must never be captured (mirror clipwatch.py).
BLOCK_BUNDLES=(com.apple.keychainaccess com.apple.SecurityAgent com.1password.1password com.agilebits.onepassword7 com.apple.wallet com.apple.Passwords)

mkdir -p "$(dirname "$DO_LOG")" 2>/dev/null
log()    { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') [s2c] $*" >> "$LOG_FILE" 2>/dev/null; }
notify() { [ "${COMMAND_TEST_SILENT:-0}" = "1" ] || osascript -e "display notification \"$1\" with title \"${2:-Command}\"" 2>/dev/null; }
urlencode() { printf '%s' "$1" | /usr/bin/python3 -c 'import sys,urllib.parse; sys.stdout.write(urllib.parse.quote(sys.stdin.read()))'; }
pb_cc()  { /usr/bin/python3 -c 'from AppKit import NSPasteboard; print(NSPasteboard.generalPasteboard().changeCount())' 2>/dev/null; }
clipboard_has_image() {
  osascript -e 'try
    repeat with i in (clipboard info)
      set k to (item 1 of i) as string
      if k contains "PNG" or k contains "TIFF" or k contains "picture" then return "yes"
    end repeat
  end try
  return "no"' 2>/dev/null | grep -q yes
}
front_bundle() { local a; a="$(lsappinfo front 2>/dev/null)"; [ -n "$a" ] && lsappinfo info -only bundleid "$a" 2>/dev/null | awk -F'"' '{print $4}'; }
front_name()   { local a; a="$(lsappinfo front 2>/dev/null)"; [ -n "$a" ] && lsappinfo info -only name "$a" 2>/dev/null | awk -F'"' '{print $4}'; }
# Keystroke synthesis: prefer the always-running Command app (its own TCC
# identity, granted once; instant — no launch latency, so submit/paste land in
# the right field). Fall back to launching SendHelper via `open -gW` (own
# process too, but slower) if the agent socket isn't up. No osascript/System
# Events fallback — that was the source of per-app Automation prompts.
agent_cmd() {  # $1 = command; prints the agent's reply on stdout; nonzero if unreachable
  [ -S "$AGENT_SOCK" ] || return 1
  /usr/bin/python3 - "$AGENT_SOCK" "$1" <<'PY'
import socket, sys
sock, cmd = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(5)
try:
    s.connect(sock); s.sendall((cmd + "\n").encode())
    sys.stdout.write(s.recv(1 << 20).decode("utf-8", "replace"))
except Exception:
    sys.exit(1)
PY
}
helper_run()   { [ -d "$HELPER_APP" ] && open -gW "$HELPER_APP" --args "$@" 2>/dev/null; }
helper_paste() {
  # New Claude and unified ChatGPT can create an Electron window without making
  # it AX-frontmost. Post directly to target process so paste cannot land in
  # whichever app macOS still reports as active.
  [ "$(agent_cmd "pasteapp $TARGET_BUNDLE" 2>/dev/null)" = "ok" ]
}
helper_return(){ [ "$(agent_cmd "returnapp $TARGET_BUNDLE" 2>/dev/null)" = "ok" ]; }
helper_newtask(){ [ "$(agent_cmd "newtask $TARGET_BUNDLE" 2>/dev/null)" = "ok" ]; }
helper_newchat(){ [ "$(agent_cmd "newchat $TARGET_BUNDLE" 2>/dev/null)" = "ok" ]; }
helper_copy()  {
  local t
  if t="$(agent_cmd copy)"; then print -r -- "$t"; return; fi
  local out; out="$(mktemp -t s2c_copy)"; rm -f "$out"; helper_run copy "$out"; [ -f "$out" ] && { cat "$out"; rm -f "$out"; }
}
helper_activate(){ [ -n "$1" ] && { agent_cmd "activate $1" >/dev/null 2>&1 || open -b "$1" 2>/dev/null; }; }   # focus restore
wait_for_assistant(){ [ -z "$TARGET_BUNDLE" ] && return 1; local i=0; while (( i < 25 )); do [ "$(front_bundle)" = "$TARGET_BUNDLE" ] && return 0; sleep 0.2; (( i++ )); done; return 1; }
wait_for_editor(){ local i=0; while (( i < 30 )); do [ "$(agent_cmd editable 2>/dev/null)" = "ok" ] && return 0; sleep 0.1; (( i++ )); done; return 1; }
provider_app_installed() {
  [ "${COMMAND_TEST_ASSUME_APP:-0}" = "1" ] && return 0
  /usr/bin/python3 - "$TARGET_BUNDLE" <<'PY' >/dev/null 2>&1
import sys
from AppKit import NSWorkspace
sys.exit(0 if NSWorkspace.sharedWorkspace().URLForApplicationWithBundleIdentifier_(sys.argv[1]) else 1)
PY
}
ensure_provider_app() {
  [ "$DRY_RUN" = "1" ] && return 0
  provider_app_installed || { notify "$TARGET_LABEL app not found. Open Set Up in Command."; return 1; }
}

# Write $1 to the clipboard and, in the SAME process, stamp last_copy.json with the
# exact resulting changeCount (not just a timestamp) — clipwatch matches on that value,
# not a timing guess, so it deterministically tags this as our own "send" write instead
# of racing to attribute it to whichever app happens to be frontmost a moment later.
# Tagged com.claudecommand.send (not the plain-blocked com.claudecommand) so it shows
# up — once, correctly tagged — under the picker's "Command" filter, unless
# add_history() finds it's byte-identical to the item it'd dupe, in which case it merges
# instead of inserting.
copy_for_send() {  # $1 = text, $2 = stamp path
  /usr/bin/python3 - "$1" "$2" <<'PY'
import sys, json, time
from AppKit import NSPasteboard
text, path = sys.argv[1], sys.argv[2]
pb = NSPasteboard.generalPasteboard()
pb.clearContents()
pb.setString_forType_(text, "public.utf8-plain-text")
with open(path, "w") as f:
    json.dump({"bundle": "com.claudecommand.send", "ts": time.time(), "cc": pb.changeCount()}, f)
PY
}

clip_fresh_ok() {  # 0 if existing clipboard is fresh AND not blocked
  [ -f "$STATE" ] || return 1
  local epoch blocked now
  epoch="$(/usr/bin/python3 -c "import json;print(json.load(open('$STATE')).get('epoch',0))" 2>/dev/null)"
  blocked="$(/usr/bin/python3 -c "import json;print(1 if json.load(open('$STATE')).get('blocked') else 0)" 2>/dev/null)"
  now="$(date +%s)"
  [ "$blocked" = "0" ] && [ -n "$epoch" ] && (( now - epoch < CLIP_TTL ))
}

log "start ACTION=$ACTION DRY_RUN=$DRY_RUN args=$#"

# --- source app + blocklist guard -------------------------------------------
# Command passes the app that was frontmost when the hotkey fired; prefer
# it over live detection (which can drift once the worker starts).
APP_NAME="${SOURCE_APP_NAME:-$(front_name)}"; BUNDLE_ID="${SOURCE_BUNDLE:-$(front_bundle)}"
for b in "${BLOCK_BUNDLES[@]}"; do
  if [ "$BUNDLE_ID" = "$b" ]; then log "BLOCKED source app $BUNDLE_ID — refusing"; notify "Won't capture from ${APP_NAME}." ; exit 1; fi
done

# --- cliphistory: ask Command to show its built-in picker ----------------
# The picker lives in the agent now (one app, one grant) — it sets the clipboard
# and pastes in-process. We just tell it which app to paste back into.
if [ "$ACTION" = "cliphistory" ]; then
  PREV="$BUNDLE_ID"
  log "showpicker prev=$PREV"
  if [ "$DRY_RUN" = "1" ]; then print -r -- "DRY_RUN agent showpicker (prev=$PREV)"; exit 0; fi
  agent_cmd "showpicker $PREV" >/dev/null 2>&1 || notify "Clipboard agent not running — run ./install-agent.sh"
  exit 0
fi

# --- screenshot pre-step: capture to clipboard, then reuse the image path -----
# shotgo / shotcomment  -> interactive: drag an area, or press Space to pick a
#                          window (native screencapture). shotfullgo -> whole screen.
# We hide the Claude window first so you can shoot whatever it was covering, then
# the go/comment dispatch reopens Claude (or we restore it on cancel).
SHOT=0
case "$ACTION" in
  shotgo|shotcomment|shotadd|shotfullgo|customshot|shothandoff)
    SHOT=1
    # shothandoff never touches the Claude window — skip the hide/restore dance.
    if [ "$DRY_RUN" != "1" ] && [ "$ACTION" != "shothandoff" ]; then
      agent_cmd "hide $TARGET_BUNDLE" >/dev/null 2>&1 && sleep 0.15   # let the window clear
    fi
    CC0="$(pb_cc)"
    if [ "$DRY_RUN" != "1" ]; then
      case "$ACTION" in
        shotfullgo) screencapture -c ;;       # entire screen → clipboard
        *)          screencapture -i -c ;;     # area drag / Space = window (esc cancels)
      esac
    fi
    CC1="$(pb_cc)"
    if [ "$DRY_RUN" != "1" ] && { [ "$CC1" = "$CC0" ] || ! clipboard_has_image; }; then
      log "screenshot cancelled / no image"
      [ "$ACTION" = "shothandoff" ] || agent_cmd "activate $TARGET_BUNDLE" >/dev/null 2>&1
      exit 0
    fi
    IMG=1
    case "$ACTION" in
      shotfullgo)  ACTION="go" ;;             # full-screen always auto-submits
      customshot)  ACTION="custom" ;;         # screenshot + custom prompt
      *)           ACTION="${ACTION#shot}" ;;  # shotgo→go, shotcomment→comment
    esac
    log "screenshot captured -> ACTION=$ACTION"
    ;;
esac

# --- 1. Resolve selection (text or image) -----------------------------------
SEL=""; IMG="${IMG:-0}"
CAPTURED_TEXT="${CAPTURED_TEXT:-}"
if [ "$SHOT" = "1" ]; then
  :   # image already on clipboard from screencapture
elif (( $# > 0 )); then
  SEL="$*"; log "input=args bytes=${#SEL}"
elif [ -n "${CAPTURED_TEXT//[[:space:]]/}" ]; then
  # Agent captured selection synchronously at hotkey time — no socket roundtrip needed.
  SEL="$CAPTURED_TEXT"; log "input=captured bytes=${#SEL}"
else
  # Read a piped selection if there's real data (macOS Service stdin). An agent
  # hotkey spawns us with stdin = /dev/null (empty) → fall through to ⌘C capture.
  STDIN_DATA=""
  [ ! -t 0 ] && STDIN_DATA="$(cat)"
  if [ -n "${STDIN_DATA//[[:space:]]/}" ]; then
    SEL="$STDIN_DATA"; log "input=stdin bytes=${#SEL}"
  elif [ "$SKIP_SELECTION_CAPTURE" = "1" ]; then
    log "selection capture skipped"
  else
    BEFORE="$(pbpaste 2>/dev/null)"; CC0="$(pb_cc)"
    NEW="$(helper_copy)"; CC1="$(pb_cc)"
    if [ "$CC1" != "$CC0" ]; then
      if [ -n "${NEW//[[:space:]]/}" ]; then SEL="$NEW"; log "fresh text selection bytes=${#SEL}"
      elif clipboard_has_image; then IMG=1; log "fresh image selection (on clipboard)"; fi
    else
      if clip_fresh_ok; then
        if clipboard_has_image; then IMG=1; log "no selection; using fresh clipboard image"
        elif [ -n "${BEFORE//[[:space:]]/}" ]; then SEL="$BEFORE"; log "no selection; using fresh clipboard text"
        else log "no selection; clipboard fresh but empty (rich-text only?) — ignoring"; fi
      else
        log "no selection; clipboard stale/blocked — ignoring"
      fi
    fi
    # restore clipboard text unless we need the image on it (paste path)
    [ "$IMG" = "0" ] && printf '%s' "$BEFORE" | pbcopy 2>/dev/null
  fi
fi

# --- 2. context + always-on enrichment --------------------------------------
URL="${SOURCE_URL:-}"
if [ -z "$URL" ]; then
  case "$BUNDLE_ID" in
    com.apple.Safari) URL="$(osascript -e 'tell application "Safari" to get URL of front document' 2>/dev/null)" ;;
    com.google.Chrome|com.brave.Browser|org.chromium.Chromium) URL="$(osascript -e "tell application \"$APP_NAME\" to get URL of active tab of front window" 2>/dev/null)" ;;
    company.thebrowser.Browser) URL="$(osascript -e 'tell application "Arc" to get URL of active tab of front window' 2>/dev/null)" ;;
  esac
fi
HOST="$(printf '%s' "$URL" | sed -n 's#^[a-z][a-z]*://\([^/]*\).*#\1#p')"
log "src app=$APP_NAME bundle=$BUNDLE_ID host=${HOST:-none} img=$IMG"

# Context rules: user-editable in Settings ▸ Context
# (~/.claude/state/enrichment-rules.json). If that file doesn't exist, fall back
# to the built-in defaults below unchanged — editing Templates is opt-in.
ENRICH_RULES_PATH="${HOME}/.claude/state/enrichment-rules.json"
ENRICH=""
DISPLAY_NAME=""
if [ -f "$ENRICH_RULES_PATH" ]; then
  IFS=$'\x1e' read -r ENRICH DISPLAY_NAME <<< "$(/usr/bin/python3 "${SCRIPT_DIR}/match-enrich-rule.py" "$ENRICH_RULES_PATH" "$BUNDLE_ID" "$HOST" "$APP_NAME" "$URL")"
else
  # App-name matching throughout (not bundle ID) — same as the Swift defaults, so
  # editing "Slack" in Templates and seeing this fallback behave identically.
  case "$APP_NAME" in
    Slack) ENRICH="From Slack. Use the Slack MCP to find this exact message (search by the text), then pull the channel, thread permalink, author and surrounding thread." DISPLAY_NAME="Slack" ;;
    Granola) ENRICH="From Granola — treat the meeting transcript as context via the Granola MCP." DISPLAY_NAME="Granola" ;;
  esac
  case "$BUNDLE_ID" in
    com.mimestream.Mimestream) ENRICH="From Mimestream (a Gmail client) — use the Gmail MCP to find the source thread for full context." DISPLAY_NAME="Mimestream" ;;
  esac
  URL_PATH="$(printf '%s' "$URL" | sed -n 's#^[a-z][a-z]*://[^/]*\(/[^?#]*\).*#\1#p')"
  case "$HOST" in
    mail.google.com) ENRICH="From Gmail — use the Gmail MCP to find the source thread for full context." DISPLAY_NAME="Gmail" ;;
    *.atlassian.net) ENRICH="From Jira/Confluence — use the Atlassian MCP to pull the referenced issue/page." DISPLAY_NAME="Jira/Confluence" ;;
    # Docs/Sheets/Slides all live under docs.google.com, split by URL path.
    docs.google.com)
      case "$URL_PATH" in
        /document/*)     ENRICH="From a Google Doc (${URL}) — read it via gws if useful, obey the editable-doc rule before any write." DISPLAY_NAME="Google Docs" ;;
        /spreadsheets/*) ENRICH="From a Google Sheet (${URL}) — read it via gws if useful, obey the editable-doc rule before any write." DISPLAY_NAME="Google Sheets" ;;
        /presentation/*) ENRICH="From a Google Slides deck (${URL}) — read it via gws if useful, obey the editable-doc rule before any write." DISPLAY_NAME="Google Slides" ;;
        *) ENRICH="From a Google Drive file (${URL}) — Docs, Sheets, or Slides; read it via gws if useful, obey the editable-doc rule before any write." DISPLAY_NAME="Google Drive" ;;
      esac
      ;;
    drive.google.com) ENRICH="From Google Drive (${URL}) — use gws drive to inspect or download the file before acting." DISPLAY_NAME="Google Drive" ;;
    app.gong.io)     ENRICH="From Gong — use the Gong MCP to pull the related call/transcript." DISPLAY_NAME="Gong" ;;
    *.lightning.force.com|*.salesforce.com) ENRICH="From Salesforce — use the Salesforce MCP to pull the related record." DISPLAY_NAME="Salesforce" ;;
  esac
fi
# {context} in any pre/post template below expands to this — the context rule
# text (if one matched) wrapped in an instruction to actually go use it.
CONTEXT_LINE="Before acting, research for context to be maximally useful: ${ENRICH:-identify the source and pull any related thread, doc, message or record via the matching MCP connector.}"

# {source} expands to this — "[from: …]" plus the matched rule's hint, if any.
# A matched rule's display name replaces "AppName — URL": for a browser match
# that's otherwise just "Google Chrome — https://mail.google.com/..." once the
# URL has already said "this is Gmail" — the browser itself is noise at that point.
SOURCE_LINE=""
if [ "$INCLUDE_CONTEXT" = "1" ]; then
  SRC="${DISPLAY_NAME:-$APP_NAME}"
  [ -z "$DISPLAY_NAME" ] && [ -n "$URL" ] && SRC="${APP_NAME} — ${URL}"
  [ -n "$SRC" ] && SOURCE_LINE="[from: ${SRC}]"
  [ -n "$ENRICH" ] && SOURCE_LINE="${SOURCE_LINE}"$'\n'"${ENRICH}"
fi

URL_FALLBACK=0
if [ "$IMG" = "0" ] && [ -z "${SEL//[[:space:]]/}" ] && [ -n "${URL//[[:space:]]/}" ]; then
  SEL="$URL"
  URL_FALLBACK=1
  log "input=url fallback bytes=${#SEL}"
fi

if [ "$IMG" = "0" ] && [ -z "${SEL//[[:space:]]/}" ] && \
   [ "$ACTION" != "comment" ] && [ "$ACTION" != "go" ] && [ "$ACTION" != "custom" ]; then
  log "nothing captured for $ACTION — aborting"; notify "Nothing selected."; exit 1
fi

# One template per built-in command (go/comment/add): user-editable in Settings ▸
# Templates (~/.claude/state/command-templates.json), single string with
# placeholders instead of separate before/after fields — same {selection}-or-
# auto-appended model custom actions already use. Absent file (the default)
# means zero behavior change. Mirrors CommandTemplates.swift's expandTemplate().
TEMPLATES_PATH="${HOME}/.claude/state/command-templates.json"
source "${SCRIPT_DIR}/send-to-claude-lib.sh"
GO_RAW="$(read_template go)"
[ -z "$GO_RAW" ] && GO_RAW='{selection}

(Right-click "Go": {context} Then do what'"'"'s most useful and report.)'
COMMENT_RAW="$(read_template comment)"
ADD_RAW="$(read_template add)"

open_new() {  # $1 = q text (may be empty)
  local q="$1"
  if [ "$DRY_RUN" = "1" ]; then
    local dest="$CLAUDE_DESTINATION"; [ "$COMMAND_PROVIDER" = "codex" ] && dest="$OPENAI_DESTINATION"
    local route=""
    if [ "$COMMAND_PROVIDER" = "codex" ]; then
      if [ "$OPENAI_DESTINATION" = "chat" ]; then
        route="native-new-session"
      else
        route="codex://threads/new?path=$(urlencode "$CODEX_WORKSPACE")"
      fi
    elif [ "$CLAUDE_DESTINATION" = "cowork" ]; then
      route="claude://cowork/new"
    elif [ "$CLAUDE_DESTINATION" = "code" ]; then
      route="claude://code/new"
    elif [ "$CLAUDE_DESTINATION" = "recent" ]; then
      route="native-new-session"
    else
      route="claude://claude.ai/new"
    fi
    print -r -- "DRY_RUN open: provider=$COMMAND_PROVIDER dest=$dest workspace=$CODEX_WORKSPACE route=$route chars=${#q}"; return 0
  fi
  ensure_provider_app || return 1
  if [ "$COMMAND_PROVIDER" = "codex" ]; then
    if [ "$OPENAI_DESTINATION" = "chat" ]; then
      helper_activate "$TARGET_BUNDLE" || return 1
      sleep 0.2
      helper_newchat || { notify "Command could not open a new ChatGPT chat. Restart Command and try again."; return 1; }
      sleep 0.45
      if [ "${IMG:-0}" = "1" ]; then
        CODEX_PENDING_PROMPT="$q"
      else
        copy_for_send "$q" "$COPY_SOURCE"
        helper_paste || return 1
      fi
      return 0
    fi
    local link="codex://threads/new"
    [ -d "$CODEX_WORKSPACE" ] || { notify "Codex workspace not found: $CODEX_WORKSPACE"; return 1; }
    /usr/bin/git -C "$CODEX_WORKSPACE" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
      || { notify "Codex workspace is not a Git repository: $CODEX_WORKSPACE"; return 1; }
    link="${link}?path=$(urlencode "$CODEX_WORKSPACE")"
    /usr/bin/open -b "$TARGET_BUNDLE" "$link" 2>/dev/null || { notify "Could not open $TARGET_LABEL."; return 1; }
    sleep 0.25
    if [ "${IMG:-0}" = "1" ]; then
      CODEX_PENDING_PROMPT="$q"
    else
      copy_for_send "$q" "$COPY_SOURCE"; helper_paste || return 1
    fi
    return 0
  fi
  if [ "$CLAUDE_DESTINATION" = "recent" ]; then
    helper_activate "$TARGET_BUNDLE" || return 1
    sleep 0.2
    helper_newtask || { notify "Command could not open a new Claude session. Restart Command and try again."; return 1; }
    sleep 0.45
    copy_for_send "$q" "$COPY_SOURCE"
    helper_paste
    return $?
  fi
  local routePath
  case "$CLAUDE_DESTINATION" in
    chat)   routePath="claude.ai/new" ;;
    cowork) routePath="cowork/new" ;;
    *)      routePath="code/new" ;;
  esac
  local link="claude://${routePath}?q=$(urlencode "$q")"
  log "open new session dest=$CLAUDE_DESTINATION chars=${#link}"
  /usr/bin/open -b "$TARGET_BUNDLE" "$link" 2>/dev/null || return 1
  sleep 0.45
}

paste_codex_pending() {
  [ "$COMMAND_PROVIDER" = "codex" ] || return 0
  [ -n "${CODEX_PENDING_PROMPT:-}" ] || return 0
  sleep 0.2
  copy_for_send "$CODEX_PENDING_PROMPT" "$COPY_SOURCE"
  helper_paste || return 1
  CODEX_PENDING_PROMPT=""
}

builtin_should_submit() {
  if [ -n "$BUILTIN_AUTO_SUBMIT" ]; then
    [ "$BUILTIN_AUTO_SUBMIT" = "1" ]
    return
  fi
  [ "$ACTION" = "go" ]
}

# --- 3. dispatch -------------------------------------------------------------
case "$ACTION" in
  go)
    ensure_provider_app || exit 1
    PRIOR="$BUNDLE_ID"
    SHOULD_SUBMIT=0; builtin_should_submit && SHOULD_SUBMIT=1
    GO_Q="$(expand_template "$GO_RAW" "$([ "$IMG" = "1" ] && echo "(image attached below)" || printf '%s' "$SEL")")"
    open_new "$GO_Q" || { notify "Could not open $TARGET_LABEL."; exit 1; }
    if [ "$DRY_RUN" = "1" ]; then
      [ "$IMG" = "1" ] && print -r -- "DRY_RUN would paste image"
      if [ "$SHOULD_SUBMIT" = "1" ]; then
        print -r -- "DRY_RUN would submit + restore focus to $PRIOR"
      else
        print -r -- "DRY_RUN would leave new session open"
      fi
      exit 0
    fi
    wait_for_assistant || log "WARN $TARGET_LABEL not frontmost"
    sleep 0.8   # let input field populate + focus before follow-up action
    [ "$IMG" = "1" ] && { helper_paste || exit 1; paste_codex_pending || exit 1; sleep 0.4; }
    if [ "$SHOULD_SUBMIT" = "1" ]; then
      helper_return
      sleep 0.25
      case "$PRIOR" in
        ""|"$TARGET_BUNDLE"|com.claudecommand.*) log "submitted (prior=${PRIOR:-none}; no restore)" ;;
        *) helper_activate "$PRIOR"; log "submitted + restored focus to $PRIOR" ;;
      esac
    else
      log "opened new session without auto-submit"
    fi
    ;;

  comment)
    ensure_provider_app || exit 1
    SHOULD_SUBMIT=0; builtin_should_submit && SHOULD_SUBMIT=1
    if [ "$IMG" = "1" ]; then
      open_new "$(expand_template "$COMMENT_RAW" "")" || { notify "Could not open $TARGET_LABEL."; exit 1; }
      [ "$DRY_RUN" = "1" ] && { print -r -- "DRY_RUN would paste image into new session"; exit 0; }
      wait_for_assistant || log "WARN not frontmost"; sleep 0.3; helper_paste || exit 1; paste_codex_pending || exit 1
      [ "$SHOULD_SUBMIT" = "1" ] && { sleep 0.1; helper_return; }
    else
      open_new "$(expand_template "$COMMENT_RAW" "$SEL")"$'\n\n' \
        || { notify "Could not open $TARGET_LABEL."; exit 1; }
      if [ "$SHOULD_SUBMIT" = "1" ] && [ "$DRY_RUN" != "1" ]; then
        wait_for_assistant || log "WARN not frontmost"; sleep 0.3; helper_return
      fi
    fi
    ;;

  add)
    ensure_provider_app || exit 1
    SHOULD_SUBMIT=0; builtin_should_submit && SHOULD_SUBMIT=1
    if [ "$IMG" = "1" ]; then
      [ "$DRY_RUN" = "1" ] && { print -r -- "DRY_RUN would activate $TARGET_LABEL + paste image into open chat"; exit 0; }
      helper_activate "$TARGET_BUNDLE" || { notify "Could not activate $TARGET_LABEL."; exit 1; }
      wait_for_assistant || { notify "$TARGET_LABEL did not become ready."; exit 1; }
      sleep 0.3; helper_paste || exit 1
      [ "$SHOULD_SUBMIT" = "1" ] && { sleep 0.1; helper_return; }
    else
      PAYLOAD="$(expand_template "$ADD_RAW" "$SEL")"
      if [ "$DRY_RUN" = "1" ]; then print -r -- "DRY_RUN would copy payload + paste into open $TARGET_LABEL session"; exit 0; fi
      copy_for_send "$PAYLOAD" "$COPY_SOURCE"
      helper_activate "$TARGET_BUNDLE" || { notify "Could not activate $TARGET_LABEL."; exit 1; }
      wait_for_assistant || { notify "$TARGET_LABEL did not become ready."; exit 1; }
      sleep 0.3; helper_paste || exit 1
      [ "$SHOULD_SUBMIT" = "1" ] && { sleep 0.1; helper_return; }
    fi
    log "pasted into open $TARGET_LABEL session"
    ;;

  custom)
    ensure_provider_app || exit 1
    TMPL="${CUSTOM_PROMPT:-}"
    # If template uses {selection}/{text} placeholder — substitute it.
    # If template has no placeholder — auto-append the selection below the prompt
    # so the content is never silently dropped.
    if [[ "$TMPL" == *"{selection}"* ]] || [[ "$TMPL" == *"{text}"* ]]; then
      PAYLOAD="${TMPL//\{selection\}/$SEL}"
      PAYLOAD="${PAYLOAD//\{text\}/$SEL}"
    elif [ -n "$SEL" ]; then
      PAYLOAD="${TMPL}"$'\n\n'"${SEL}"
    else
      PAYLOAD="${TMPL}"
    fi
    # Source context prefix (on by default, off if CUSTOM_INCLUDE_SOURCE=0)
    if [ "${CUSTOM_INCLUDE_SOURCE:-1}" = "0" ]; then
      PREFIX=""
    else
      PREFIX="${CONTEXT}"
    fi
    log "custom: session=${CUSTOM_SESSION:-new} submit=${CUSTOM_SUBMIT:-} src=${CUSTOM_INCLUDE_SOURCE:-1} img=$IMG sel_bytes=${#SEL}"
    if [ "${CUSTOM_SESSION:-new}" = "add" ]; then
      # Paste into existing task for selected foreground destination.
      if [ "$IMG" = "1" ]; then
        [ "$DRY_RUN" = "1" ] && { print -r -- "DRY_RUN would paste image+prompt into open $TARGET_LABEL"; exit 0; }
        # Image is still on the clipboard from the screenshot pre-step — paste it FIRST,
        # then overwrite the clipboard with the text prompt. Reversing this order (text
        # first) clobbers the image before it's ever pasted — the old bug here.
        helper_activate "$TARGET_BUNDLE" || { notify "Could not activate $TARGET_LABEL."; exit 1; }
        wait_for_assistant || { notify "$TARGET_LABEL did not become ready."; exit 1; }
        sleep 0.3; helper_paste || exit 1
        sleep 0.3
        copy_for_send "${PREFIX}${PAYLOAD}" "$COPY_SOURCE"
        helper_paste || exit 1
      else
        [ "$DRY_RUN" = "1" ] && { print -r -- "DRY_RUN would paste into existing $TARGET_LABEL"; exit 0; }
        copy_for_send "${PREFIX}${PAYLOAD}" "$COPY_SOURCE"
        helper_activate "$TARGET_BUNDLE" || { notify "Could not activate $TARGET_LABEL."; exit 1; }
        wait_for_assistant || { notify "$TARGET_LABEL did not become ready."; exit 1; }
        sleep 0.5; helper_paste || exit 1
      fi
      if [ "${CUSTOM_SUBMIT:-}" = "go" ]; then sleep 0.3; helper_return || true; fi
    else
      # Open new task for selected foreground destination.
      if [ "$IMG" = "1" ]; then
        open_new "${PREFIX}${PAYLOAD}" || { notify "Could not open $TARGET_LABEL."; exit 1; }
        [ "$DRY_RUN" = "1" ] && { print -r -- "DRY_RUN would paste screenshot into custom prompt"; exit 0; }
        wait_for_assistant || log "WARN not frontmost"; sleep 0.3; helper_paste || exit 1; paste_codex_pending || exit 1
        if [ "${CUSTOM_SUBMIT:-}" = "go" ]; then sleep 0.1; helper_return || true; fi
      else
        open_new "${PREFIX}${PAYLOAD}" || { notify "Could not open $TARGET_LABEL."; exit 1; }
        if [ "${CUSTOM_SUBMIT:-}" = "go" ]; then
          wait_for_assistant || log "WARN not frontmost"; sleep 0.3; helper_return || true
        fi
      fi
    fi
    ;;

  handoff)
    # Compatibility Background path — no Claude window. The vendored Electron-free
    # pipeline renders the settings template and pipes it to `claude -p` in the
    # background; contract: vendor/claude-command-capture/docs/HANDOFF.md.
    HANDOFF_SH="${SCRIPT_DIR}/capture-handoff.sh"
    [ -f "$HANDOFF_SH" ] || { log "capture-handoff.sh missing at $HANDOFF_SH"; notify "Background runner missing — reinstall from the Install Guide."; exit 1; }
    if [ "$SHOT" = "1" ]; then
      SRC="screenshot"
    elif [ "$URL_FALLBACK" = "1" ]; then
      SRC="url"
    else
      SRC="selection"
    fi
    if [ "$DRY_RUN" = "1" ]; then print -r -- "DRY_RUN handoff src=$SRC img=$IMG sel_bytes=${#SEL}"; exit 0; fi
    export HANDOFF_IMG="$IMG" HANDOFF_SOURCE="$SRC" HANDOFF_CONTEXT="$SOURCE_LINE"
    if [ "$IMG" = "1" ]; then
      exec /bin/zsh "$HANDOFF_SH" </dev/null
    else
      print -rn -- "$SEL" | /bin/zsh "$HANDOFF_SH"
      exit $?
    fi
    ;;

  *) log "unknown ACTION=$ACTION"; notify "Unknown action: $ACTION"; exit 1 ;;
esac
log "done"
