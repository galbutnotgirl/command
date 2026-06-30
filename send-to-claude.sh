#!/bin/zsh
# send-to-claude.sh (v3)
# Grab the current selection (text OR image) + source context and hand it to the
# Claude Code DESKTOP app. Everything goes to Claude Code — never Cowork.
#
# ACTIONs (each wired to a right-click Quick Action):
#   go        Background-feel: open a NEW Claude Code session, auto-submit, then
#             return focus to where you were. Claude researches context + acts.
#   comment   Open a NEW Claude Code session, pre-filled. Stays foreground so you
#             add a note and send. No auto-submit.
#   add       Paste the selection into the ALREADY-OPEN Claude Code chat.
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
ACTION="${ACTION:-comment}"
CLIP_TTL="${CLIP_TTL:-60}"
INCLUDE_CONTEXT="${INCLUDE_CONTEXT:-1}"
DRY_RUN="${DRY_RUN:-0}"
SCRIPT_DIR="${0:A:h}"
HELPER_APP="${SCRIPT_DIR}/SendHelper.app"
HELPER="${HELPER_APP}/Contents/MacOS/sendhelper"
AGENT_SOCK="${AGENT_SOCK:-${HOME}/.claude/state/command-agent.sock}"
SOURCE_BUNDLE="${SOURCE_BUNDLE:-}"   # set by CommandAgent when a hotkey fires
CLAUDE_BUNDLE="com.anthropic.claudefordesktop"
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude 2>/dev/null)}"

# All paths below are absolute (SCRIPT_DIR/STATE/HELPER via ${0:A}); nothing uses
# the cwd. Move to / so Python's `-c` import scan (sys.path[0]=cwd) never hits a
# TCC-protected folder (Desktop/Documents/iCloud) → "Operation not permitted".
cd / 2>/dev/null || true

# Apps whose copies must never be captured (mirror clipwatch.py).
BLOCK_BUNDLES=(com.apple.keychainaccess com.apple.SecurityAgent com.1password.1password com.agilebits.onepassword7 com.apple.wallet com.apple.Passwords)

mkdir -p "$(dirname "$DO_LOG")" 2>/dev/null
log()    { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') [s2c] $*" >> "$LOG_FILE" 2>/dev/null; }
notify() { osascript -e "display notification \"$1\" with title \"${2:-Claude Command}\"" 2>/dev/null; }
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
# Keystroke synthesis: prefer the always-running CommandAgent (its own TCC
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
helper_paste() { agent_cmd paste  >/dev/null 2>&1 || helper_run paste; }
helper_return(){ agent_cmd return >/dev/null 2>&1 || helper_run return; }
helper_copy()  {
  local t
  if t="$(agent_cmd copy)"; then print -r -- "$t"; return; fi
  local out; out="$(mktemp -t s2c_copy)"; rm -f "$out"; helper_run copy "$out"; [ -f "$out" ] && { cat "$out"; rm -f "$out"; }
}
helper_activate(){ [ -n "$1" ] && { agent_cmd "activate $1" >/dev/null 2>&1 || open -b "$1" 2>/dev/null; }; }   # focus restore
wait_for_claude(){ local i=0; while (( i < 25 )); do [ "$(front_bundle)" = "$CLAUDE_BUNDLE" ] && return 0; sleep 0.2; (( i++ )); done; return 1; }

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
# CommandAgent passes the app that was frontmost when the hotkey fired; prefer
# it over live detection (which can drift once the worker starts).
APP_NAME="$(front_name)"; BUNDLE_ID="${SOURCE_BUNDLE:-$(front_bundle)}"
for b in "${BLOCK_BUNDLES[@]}"; do
  if [ "$BUNDLE_ID" = "$b" ]; then log "BLOCKED source app $BUNDLE_ID — refusing"; notify "Won't capture from ${APP_NAME}." ; exit 1; fi
done

# --- cliphistory: ask CommandAgent to show its built-in picker ----------------
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
  shotgo|shotcomment|shotadd|shotfullgo)
    SHOT=1
    if [ "$DRY_RUN" != "1" ]; then
      agent_cmd "hide $CLAUDE_BUNDLE" >/dev/null 2>&1 && sleep 0.15   # let the window clear
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
      agent_cmd "activate $CLAUDE_BUNDLE" >/dev/null 2>&1   # bring Claude back
      exit 0
    fi
    IMG=1
    case "$ACTION" in
      shotfullgo) ACTION="go" ;;              # full-screen always auto-submits
      *)          ACTION="${ACTION#shot}" ;;  # shotgo→go, shotcomment→comment
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

if [ "$IMG" = "0" ] && [ -z "${SEL//[[:space:]]/}" ] && [ "$ACTION" != "comment" ] && [ "$ACTION" != "go" ]; then
  log "nothing captured for $ACTION — aborting"; notify "Nothing selected."; exit 1
fi

# --- 2. context + always-on enrichment --------------------------------------
URL=""
case "$BUNDLE_ID" in
  com.apple.Safari) URL="$(osascript -e 'tell application "Safari" to get URL of front document' 2>/dev/null)" ;;
  com.google.Chrome|com.brave.Browser|com.microsoft.edgemac|org.chromium.Chromium) URL="$(osascript -e "tell application \"$APP_NAME\" to get URL of active tab of front window" 2>/dev/null)" ;;
  company.thebrowser.Browser) URL="$(osascript -e 'tell application "Arc" to get URL of active tab of front window' 2>/dev/null)" ;;
esac
HOST="$(printf '%s' "$URL" | sed -n 's#^[a-z][a-z]*://\([^/]*\).*#\1#p')"
log "src app=$APP_NAME bundle=$BUNDLE_ID host=${HOST:-none} img=$IMG"

ENRICH=""
case "$BUNDLE_ID" in
  com.tinyspeck.slackmacgap) ENRICH="This is from Slack. Use the Slack MCP to find this exact message (search by the text), then pull the channel, thread permalink, author and surrounding thread." ;;
esac
case "$HOST" in
  mail.google.com) ENRICH="From Gmail — use the Gmail MCP to find the source thread for full context." ;;
  *.atlassian.net) ENRICH="From Jira/Confluence — use the Atlassian MCP to pull the referenced issue/page." ;;
  docs.google.com) ENRICH="From a Google Doc (${URL}) — read it via gws if useful; obey the editable-doc rule before any write." ;;
  app.gong.io)     ENRICH="From Gong — use the Gong MCP to pull the related call/transcript." ;;
  *.lightning.force.com|*.salesforce.com) ENRICH="From Salesforce — use the Salesforce MCP to pull the related record." ;;
esac
[ "$APP_NAME" = "Granola" ] && ENRICH="From Granola — treat the meeting transcript as context via the Granola MCP."
RESEARCH="Before acting, research for context to be maximally useful: ${ENRICH:-identify the source and pull any related thread, doc, message or record via the matching MCP connector.}"

CONTEXT=""
if [ "$INCLUDE_CONTEXT" = "1" ]; then
  SRC="$APP_NAME"; [ -n "$URL" ] && SRC="${APP_NAME} — ${URL}"
  [ -n "$SRC" ] && CONTEXT="[from: ${SRC}]"$'\n'
  [ -n "$ENRICH" ] && CONTEXT="${CONTEXT}${ENRICH}"$'\n'
  [ -n "$CONTEXT" ] && CONTEXT="${CONTEXT}"$'\n'
fi

open_new() {  # $1 = q text (may be empty)
  local link="claude://code/new?q=$(urlencode "$1")"
  log "open new session chars=${#link}"
  if [ "$DRY_RUN" = "1" ]; then print -r -- "DRY_RUN open: $link"; return 0; fi
  open "$link" 2>/dev/null
}

# --- 3. dispatch -------------------------------------------------------------
case "$ACTION" in
  go)
    PRIOR="$BUNDLE_ID"
    GO_Q="${CONTEXT}${SEL}"$'\n\n'"(Right-click \"Go\": ${RESEARCH} Then do what's most useful and report.)"
    if [ "$IMG" = "1" ]; then GO_Q="${CONTEXT}(image attached below)"$'\n\n'"(Right-click \"Go\": ${RESEARCH} Then do what's most useful and report.)"; fi
    open_new "$GO_Q" || { notify "Could not open Claude."; exit 1; }
    if [ "$DRY_RUN" = "1" ]; then [ "$IMG" = "1" ] && print -r -- "DRY_RUN would paste image"; print -r -- "DRY_RUN would submit + restore focus to $PRIOR"; exit 0; fi
    wait_for_claude || log "WARN Claude not frontmost"
    sleep 0.8   # new session: let the input field populate + focus before we submit
    [ "$IMG" = "1" ] && { helper_paste; sleep 0.4; }
    helper_return
    sleep 0.25
    # Restore focus only to a real source app — never the agent itself (would yank
    # focus off Claude before the submit registers) or Claude (already frontmost).
    case "$PRIOR" in
      ""|"$CLAUDE_BUNDLE"|com.claudecommand.*) log "submitted (prior=${PRIOR:-none}; no restore)" ;;
      *) helper_activate "$PRIOR"; log "submitted + restored focus to $PRIOR" ;;
    esac
    ;;

  comment)
    if [ "$IMG" = "1" ]; then
      open_new "${CONTEXT}" || { notify "Could not open Claude."; exit 1; }
      [ "$DRY_RUN" = "1" ] && { print -r -- "DRY_RUN would paste image into new session"; exit 0; }
      wait_for_claude || log "WARN not frontmost"; sleep 0.3; helper_paste
    else
      open_new "${CONTEXT}${SEL}"$'\n\n'
    fi
    ;;

  add)
    if [ "$IMG" = "1" ]; then
      [ "$DRY_RUN" = "1" ] && { print -r -- "DRY_RUN would activate Claude + paste image into open chat"; exit 0; }
      helper_activate "$CLAUDE_BUNDLE"; wait_for_claude || true; sleep 0.3; helper_paste
    else
      PAYLOAD="${CONTEXT}${SEL}"
      if [ "$DRY_RUN" = "1" ]; then print -r -- "DRY_RUN would copy payload + paste into open Claude chat"; exit 0; fi
      # Stamp clipboard attribution as our own app so clipwatch blocks this write from history.
      # Without this, the 25ms-poll sees Claude frontmost after activate() and records wrong icon.
      /usr/bin/python3 -c "import json,time; open('${HOME}/.claude/state/last_copy.json','w').write(json.dumps({'bundle':'com.claudecommand','ts':time.time()}))" 2>/dev/null || true
      printf '%s' "$PAYLOAD" | pbcopy
      helper_activate "$CLAUDE_BUNDLE"; wait_for_claude || true; sleep 0.3; helper_paste
    fi
    log "pasted into open Claude chat"
    ;;

  *) log "unknown ACTION=$ACTION"; notify "Unknown action: $ACTION"; exit 1 ;;
esac
log "done"
