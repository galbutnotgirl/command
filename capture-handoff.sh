#!/bin/zsh
# capture-handoff.sh — background skill handoff (the "background trigger").
#
# Native glue between send-to-claude.sh's capture stages and the vendored
# Electron-free pipeline (vendor/claude-command-capture): render a prompt from
# the settings template addressed to /<skill> and pipe it to `claude -p` in the
# background, leaving durable submission records for a downstream app.
# Contract: vendor/claude-command-capture/docs/HANDOFF.md
#
# Inputs:
#   stdin              captured text (when HANDOFF_IMG != 1)
#   HANDOFF_IMG        "1" = take the PNG currently on the clipboard
#   HANDOFF_SOURCE     text | clipboard | selection | screenshot
#   HANDOFF_CONTEXT    optional "[from: app — url]" prefix, prepended to text
#   CLAUDE_CAPTURE_HOME  data dir override (default: ~/Library/Application
#                        Support/claude-command — same as the contract)

emulate -L zsh
set -uo pipefail
export PATH="/opt/homebrew/bin:${HOME}/.claude/local:${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"

LOG_FILE="${HOME}/Library/Logs/claude-command.log"
log()    { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') [handoff] $*" >> "$LOG_FILE" 2>/dev/null; }
notify() { osascript -e "display notification \"$1\" with title \"${2:-Claude Command}\"" 2>/dev/null; }

SCRIPT_DIR="${0:A:h}"
# Bundled layout (app Resources) puts the core next to this script; repo layout
# keeps it under vendor/.
CORE="${CLAUDE_CAPTURE_CORE:-${SCRIPT_DIR}/claude-command-capture}"
[ -d "$CORE" ] || CORE="${SCRIPT_DIR}/vendor/claude-command-capture"
SHIM="${CORE}/bin/submit-cli.js"
BASE="${CLAUDE_CAPTURE_HOME:-${HOME}/Library/Application Support/claude-command}"

[ -f "$SHIM" ] || { log "shim missing at $SHIM"; notify "Handoff core missing — rebuild the agent."; exit 1; }
NODE="$(command -v node 2>/dev/null)" || true
[ -n "${NODE:-}" ] || { log "node not found on PATH"; notify "Handoff needs Node.js 20+ on PATH."; exit 1; }

SRC="${HANDOFF_SOURCE:-selection}"
CTX="${HANDOFF_CONTEXT:-}"

if [ "${HANDOFF_IMG:-0}" = "1" ]; then
  # Clipboard image → PNG file; the prompt names the path, never inlines it.
  mkdir -p "${BASE}/captures"
  PNG="${BASE}/captures/$(uuidgen | tr 'A-Z' 'a-z').png"
  /usr/bin/python3 - "$PNG" <<'PY' || { log "clipboard PNG dump failed"; exit 1; }
import sys
from AppKit import NSPasteboard, NSPasteboardTypePNG, NSPasteboardTypeTIFF, NSBitmapImageRep
pb = NSPasteboard.generalPasteboard()
data = pb.dataForType_(NSPasteboardTypePNG)
if data is None:
    tiff = pb.dataForType_(NSPasteboardTypeTIFF)
    if tiff is None:
        sys.exit(1)
    rep = NSBitmapImageRep.imageRepWithData_(tiff)
    data = rep.representationUsingType_properties_(4, None)  # 4 = PNG
data.writeToFile_atomically_(sys.argv[1], True)
PY
  log "handoff image src=$SRC file=$PNG"
  exec "$NODE" "$SHIM" --base-dir "$BASE" --source "$SRC" --kind image --file "$PNG" </dev/null
else
  TEXT="$(cat)"
  [ -n "${TEXT//[[:space:]]/}" ] || { log "empty text handoff — aborting"; notify "Nothing captured."; exit 1; }
  log "handoff text src=$SRC bytes=${#TEXT} ctx_bytes=${#CTX}"
  { [ -n "$CTX" ] && print -r -- "$CTX"; print -rn -- "$TEXT"; } \
    | "$NODE" "$SHIM" --base-dir "$BASE" --source "$SRC" --kind text
fi
