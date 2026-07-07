#!/bin/zsh
# send-to-claude.sh (v3)
# Grab the current selection (text OR image) + source context and hand it to the
# Claude DESKTOP app. CLAUDE_DESTINATION picks which mode inside that one app —
# chat, cowork, or code — via the claude:// URL scheme; all three are the same
# process, so paste/auto-submit/focus-restore work identically for all of them.
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
COPY_SOURCE="${HOME}/.claude/state/last_copy.json"
ACTION="${ACTION:-comment}"
CLIP_TTL="${CLIP_TTL:-60}"
INCLUDE_CONTEXT="${INCLUDE_CONTEXT:-1}"
DRY_RUN="${DRY_RUN:-0}"
SCRIPT_DIR="${0:A:h}"
HELPER_APP="${SCRIPT_DIR}/SendHelper.app"
HELPER="${HELPER_APP}/Contents/MacOS/sendhelper"
AGENT_SOCK="${AGENT_SOCK:-${HOME}/.claude/state/command-agent.sock}"
SOURCE_BUNDLE="${SOURCE_BUNDLE:-}"   # set by CommandAgent when a hotkey fires
CLAUDE_DESTINATION="${CLAUDE_DESTINATION:-code}"
CLAUDE_BUNDLE="com.anthropic.claudefordesktop"   # chat/cowork/code are all this one app
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
wait_for_claude(){ [ -z "$CLAUDE_BUNDLE" ] && return 1; local i=0; while (( i < 25 )); do [ "$(front_bundle)" = "$CLAUDE_BUNDLE" ] && return 0; sleep 0.2; (( i++ )); done; return 1; }

# Write $1 to the clipboard and, in the SAME process, stamp last_copy.json with the
# exact resulting changeCount (not just a timestamp) — clipwatch matches on that value,
# not a timing guess, so it deterministically tags this as our own "send" write instead
# of racing to attribute it to whichever app happens to be frontmost a moment later.
# Tagged com.claudecommand.send (not the plain-blocked com.claudecommand) so it shows
# up — once, correctly tagged — under the picker's "Claude Command" filter, unless
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
  shotgo|shotcomment|shotadd|shotfullgo|customshot|shothandoff)
    SHOT=1
    # shothandoff never touches the Claude window — skip the hide/restore dance.
    if [ "$DRY_RUN" != "1" ] && [ "$ACTION" != "shothandoff" ]; then
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
      [ "$ACTION" = "shothandoff" ] || agent_cmd "activate $CLAUDE_BUNDLE" >/dev/null 2>&1   # bring Claude back
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

if [ "$IMG" = "0" ] && [ -z "${SEL//[[:space:]]/}" ] && \
   [ "$ACTION" != "comment" ] && [ "$ACTION" != "go" ] && [ "$ACTION" != "custom" ]; then
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

# Auto-context rules: user-editable in Settings ▸ Templates ▸ Auto-Context Rules
# (~/.claude/state/enrichment-rules.json). If that file doesn't exist, fall back
# to the built-in defaults below unchanged — editing Templates is opt-in.
ENRICH_RULES_PATH="${HOME}/.claude/state/enrichment-rules.json"
ENRICH=""
if [ -f "$ENRICH_RULES_PATH" ]; then
  ENRICH="$(/usr/bin/python3 - "$ENRICH_RULES_PATH" "$BUNDLE_ID" "$HOST" "$APP_NAME" "$URL" <<'PY'
import json, sys, fnmatch
path, bundle, host, app, url = sys.argv[1:6]
try:
    rules = json.load(open(path))
except Exception:
    rules = []
for r in rules:
    m, pat, text = r.get("match"), r.get("pattern", ""), r.get("text", "")
    hit = (m == "bundle" and pat == bundle) or (m == "app" and pat == app) \
        or (m == "host" and host and fnmatch.fnmatch(host, pat))
    if hit:
        sys.stdout.write(text.replace("{url}", url))
        break
PY
)"
else
  case "$BUNDLE_ID" in
    com.tinyspeck.slackmacgap) ENRICH="This is from Slack. Use the Slack MCP to find this exact message (search by the text), then pull the channel, thread permalink, author and surrounding thread." ;;
  esac
  case "$HOST" in
    mail.google.com) ENRICH="From Gmail — use the Gmail MCP to find the source thread for full context." ;;
    *.atlassian.net) ENRICH="From Jira/Confluence — use the Atlassian MCP to pull the referenced issue/page." ;;
    docs.google.com) ENRICH="From a Google Doc (${URL}) — read it via gws if useful; obey the editable-doc rule before any write." ;;
    drive.google.com) ENRICH="From Google Drive (${URL}) — use gws drive to inspect or download the file before acting." ;;
    app.gong.io)     ENRICH="From Gong — use the Gong MCP to pull the related call/transcript." ;;
    *.lightning.force.com|*.salesforce.com) ENRICH="From Salesforce — use the Salesforce MCP to pull the related record." ;;
  esac
  [ "$APP_NAME" = "Granola" ] && ENRICH="From Granola — treat the meeting transcript as context via the Granola MCP."
fi
RESEARCH="Before acting, research for context to be maximally useful: ${ENRICH:-identify the source and pull any related thread, doc, message or record via the matching MCP connector.}"

CONTEXT=""
if [ "$INCLUDE_CONTEXT" = "1" ]; then
  SRC="$APP_NAME"; [ -n "$URL" ] && SRC="${APP_NAME} — ${URL}"
  [ -n "$SRC" ] && CONTEXT="[from: ${SRC}]"$'\n'
  [ -n "$ENRICH" ] && CONTEXT="${CONTEXT}${ENRICH}"$'\n'
  [ -n "$CONTEXT" ] && CONTEXT="${CONTEXT}"$'\n'
fi

# Pre/post wrap templates for the built-in go/comment/add commands: user-editable
# in Settings ▸ Templates (~/.claude/state/command-templates.json). Empty pre/post
# (the default — file usually doesn't exist) means zero behavior change.
TEMPLATES_PATH="${HOME}/.claude/state/command-templates.json"
read_template() {  # $1 = action, $2 = pre|post
  [ -f "$TEMPLATES_PATH" ] || { printf ''; return; }
  /usr/bin/python3 -c "
import json
try:
    d = json.load(open('$TEMPLATES_PATH'))
    print(d.get('$1', {}).get('$2', ''), end='')
except Exception:
    pass
" 2>/dev/null
}
GO_PRE="$(read_template go pre)"
GO_POST="$(read_template go post)"
[ -z "$GO_POST" ] && GO_POST='(Right-click "Go": {research} Then do what'"'"'s most useful and report.)'
GO_POST="${GO_POST//\{research\}/$RESEARCH}"
COMMENT_PRE="$(read_template comment pre)"
COMMENT_POST="$(read_template comment post)"
ADD_PRE="$(read_template add pre)"
ADD_POST="$(read_template add post)"

open_new() {  # $1 = q text (may be empty)
  local q="$1"
  if [ "$DRY_RUN" = "1" ]; then print -r -- "DRY_RUN open: dest=$CLAUDE_DESTINATION chars=${#q}"; return 0; fi
  local path
  case "$CLAUDE_DESTINATION" in
    chat)   path="claude.ai/new" ;;
    cowork) path="cowork/new" ;;
    *)      path="code/new" ;;
  esac
  local link="claude://${path}?q=$(urlencode "$q")"
  log "open new session dest=$CLAUDE_DESTINATION chars=${#link}"
  open "$link" 2>/dev/null
}

# --- 3. dispatch -------------------------------------------------------------
case "$ACTION" in
  go)
    PRIOR="$BUNDLE_ID"
    GO_Q="${CONTEXT}${GO_PRE}${SEL}"$'\n\n'"${GO_POST}"
    if [ "$IMG" = "1" ]; then GO_Q="${CONTEXT}${GO_PRE}(image attached below)"$'\n\n'"${GO_POST}"; fi
    open_new "$GO_Q" || { notify "Could not open Claude."; exit 1; }
    if [ "$DRY_RUN" = "1" ]; then [ "$IMG" = "1" ] && print -r -- "DRY_RUN would paste image"; print -r -- "DRY_RUN would submit + restore focus to $PRIOR"; exit 0; fi
    wait_for_claude || log "WARN Claude not frontmost"
    sleep 0.8   # let input field populate + focus before submit
    [ "$IMG" = "1" ] && { helper_paste; sleep 0.4; }
    helper_return
    sleep 0.25
    case "$PRIOR" in
      ""|"$CLAUDE_BUNDLE"|com.claudecommand.*) log "submitted (prior=${PRIOR:-none}; no restore)" ;;
      *) helper_activate "$PRIOR"; log "submitted + restored focus to $PRIOR" ;;
    esac
    ;;

  comment)
    if [ "$IMG" = "1" ]; then
      open_new "${CONTEXT}${COMMENT_PRE}${COMMENT_POST}" || { notify "Could not open Claude."; exit 1; }
      [ "$DRY_RUN" = "1" ] && { print -r -- "DRY_RUN would paste image into new session"; exit 0; }
      wait_for_claude || log "WARN not frontmost"; sleep 0.3; helper_paste
    else
      open_new "${CONTEXT}${COMMENT_PRE}${SEL}${COMMENT_POST}"$'\n\n'
    fi
    ;;

  add)
    if [ "$IMG" = "1" ]; then
      [ "$DRY_RUN" = "1" ] && { print -r -- "DRY_RUN would activate Claude + paste image into open chat"; exit 0; }
      helper_activate "$CLAUDE_BUNDLE"; wait_for_claude || true; sleep 0.3; helper_paste
    else
      PAYLOAD="${CONTEXT}${ADD_PRE}${SEL}${ADD_POST}"
      if [ "$DRY_RUN" = "1" ]; then print -r -- "DRY_RUN would copy payload + paste into open Claude chat"; exit 0; fi
      copy_for_send "$PAYLOAD" "$COPY_SOURCE"
      helper_activate "$CLAUDE_BUNDLE"; wait_for_claude || true; sleep 0.3; helper_paste
    fi
    log "pasted into open Claude chat"
    ;;

  custom)
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
      # Paste into existing open Claude Code chat
      if [ "$IMG" = "1" ]; then
        [ "$DRY_RUN" = "1" ] && { print -r -- "DRY_RUN would paste image+prompt into open Claude"; exit 0; }
        # Image is still on the clipboard from the screenshot pre-step — paste it FIRST,
        # then overwrite the clipboard with the text prompt. Reversing this order (text
        # first) clobbers the image before it's ever pasted — the old bug here.
        helper_activate "$CLAUDE_BUNDLE"; wait_for_claude || true; sleep 0.3; helper_paste
        sleep 0.3
        copy_for_send "${PREFIX}${PAYLOAD}" "$COPY_SOURCE"
        helper_paste
      else
        [ "$DRY_RUN" = "1" ] && { print -r -- "DRY_RUN would paste into existing Claude"; exit 0; }
        copy_for_send "${PREFIX}${PAYLOAD}" "$COPY_SOURCE"
        helper_activate "$CLAUDE_BUNDLE"; wait_for_claude || true; sleep 0.5; helper_paste
      fi
      if [ "${CUSTOM_SUBMIT:-}" = "go" ]; then sleep 0.3; agent_cmd return >/dev/null 2>&1 || true; fi
    else
      # Open new Claude session
      if [ "$IMG" = "1" ]; then
        open_new "${PREFIX}${PAYLOAD}" || { notify "Could not open Claude."; exit 1; }
        [ "$DRY_RUN" = "1" ] && { print -r -- "DRY_RUN would paste screenshot into custom prompt"; exit 0; }
        wait_for_claude || log "WARN not frontmost"; sleep 0.3; helper_paste
        if [ "${CUSTOM_SUBMIT:-}" = "go" ]; then sleep 0.1; agent_cmd return >/dev/null 2>&1 || true; fi
      else
        open_new "${PREFIX}${PAYLOAD}"
        if [ "${CUSTOM_SUBMIT:-}" = "go" ]; then
          wait_for_claude || log "WARN not frontmost"; sleep 0.3; agent_cmd return >/dev/null 2>&1 || true
        fi
      fi
    fi
    ;;

  handoff)
    # Background skill handoff — no Claude window. The vendored Electron-free
    # pipeline renders the settings template and pipes it to `claude -p` in the
    # background; contract: vendor/claude-command-capture/docs/HANDOFF.md.
    HANDOFF_SH="${SCRIPT_DIR}/capture-handoff.sh"
    [ -f "$HANDOFF_SH" ] || { log "capture-handoff.sh missing at $HANDOFF_SH"; notify "Handoff worker missing — rebuild the agent."; exit 1; }
    [ "$SHOT" = "1" ] && SRC="screenshot" || SRC="selection"
    if [ "$DRY_RUN" = "1" ]; then print -r -- "DRY_RUN handoff src=$SRC img=$IMG sel_bytes=${#SEL}"; exit 0; fi
    export HANDOFF_IMG="$IMG" HANDOFF_SOURCE="$SRC" HANDOFF_CONTEXT="$CONTEXT"
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
