#!/bin/zsh
# set-hotkeys.sh — configure Command global hotkeys.
#
# Hotkeys are owned by Command (Carbon RegisterEventHotKey), NOT by macOS
# Services — Service shortcuts don't fire for no-input actions (screenshot,
# clipboard history). This writes Command hotkey config and restarts it. It also
# CLEARS any leftover pbs Service shortcuts so nothing double-binds.
#
# HOTKEYS table format:  "action | <tokens>"
#   modifiers: cmd|command  opt|option|alt  ctrl|control  shift   (any order)
#   key:       a letter (a), digit (4), function key (F1..F12), or navigation key (home)
emulate -L zsh
set -uo pipefail

# action(worker ACTION) | "Service menu name" | hotkey tokens
# Tip: you can also rebind these visually in the menu-bar window (Shortcuts tab).
HOTKEYS=(
  "add|Command - Add|opt F8"
  "comment|Command - New|F8"
  "shotadd|Command - Screenshot Add|opt F7"
  "shotcomment|Command - Screenshot New|F7"
  "cliphistory|Command - Clipboard History|F6"
  # Go and Screenshot Go default to unbound in the app to avoid F-key conflicts.
  # Bind them visually in Settings → Shortcuts if you want one-key submit.
  # Custom prompt actions (selected text, screenshot, popup, voice) also live in
  # Settings → Shortcuts; this bootstrap script only seeds built-in shortcuts.
)

CFG="${HOME}/.claude/state/command-hotkeys.json"
mkdir -p "${HOME}/.claude/state"

# 1) Write Command hotkey config (action -> Carbon keycode + modifier mask).
/usr/bin/python3 - "$CFG" "${HOTKEYS[@]}" <<'PY'
import json, sys
cfg, rows = sys.argv[1], sys.argv[2:]
MODS = {'cmd':256,'command':256,'opt':2048,'option':2048,'alt':2048,
        'ctrl':4096,'control':4096,'shift':512}          # Carbon masks
FKEY = {1:122,2:120,3:99,4:118,5:96,6:97,7:98,8:100,9:101,10:109,11:103,12:111}
KEY  = {'a':0,'b':11,'c':8,'d':2,'e':14,'f':3,'g':5,'h':4,'i':34,'j':38,'k':40,
        'l':37,'m':46,'n':45,'o':31,'p':35,'q':12,'r':15,'s':1,'t':17,'u':32,
        'v':9,'w':13,'x':7,'y':16,'z':6,'1':18,'2':19,'3':20,'4':21,'5':23,
        '6':22,'7':26,'8':28,'9':25,'0':29,'space':49,'home':115}

def parse(tokens):
    mods, keycode = 0, None
    for tok in tokens.split():
        t = tok.lower()
        if t in MODS:
            mods |= MODS[t]
        elif len(t) > 1 and t[0] == 'f' and t[1:].isdigit():
            keycode = FKEY[int(t[1:])]
        elif t in KEY:
            keycode = KEY[t]
        else:
            raise SystemExit(f"bad token {tok!r}")
    if keycode is None: raise SystemExit(f"no key in {tokens!r}")
    return keycode, mods

out = []
for r in rows:
    action, _name, spec = r.split('|', 2)
    kc, m = parse(spec.strip())
    out.append({"action": action, "keycode": kc, "mods": m})
    print(f"  {action:<12} {spec.strip():<10} keycode={kc} mods={m}")
with open(cfg, 'w') as f:
    json.dump(out, f, indent=2)
PY

# 2) Clear any leftover pbs Service shortcuts (Command owns hotkeys now → no dupes).
NAMES=()
for r in "${HOTKEYS[@]}"; do NAMES+=("${${r#*|}%|*}"); done   # middle field = menu name
TMP="$(mktemp -t pbs_export)"
if defaults export pbs "$TMP" 2>/dev/null; then
  /usr/bin/python3 - "$TMP" "${NAMES[@]}" <<'PY'
import plistlib, sys
tmp, names = sys.argv[1], sys.argv[2:]
with open(tmp,'rb') as f:
    try: d = plistlib.load(f)
    except Exception: d = {}
st = d.get('NSServicesStatus') or {}
for n in names:
    st.pop(f"(null) - {n} - runWorkflowAsService", None)
d['NSServicesStatus'] = st
with open(tmp,'wb') as f: plistlib.dump(d, f)
PY
  defaults import pbs "$TMP"
  /System/Library/CoreServices/pbs -flush 2>/dev/null
fi
rm -f "$TMP"

# 3) Restart Command so it re-reads the config and re-registers hotkeys.
UID_NUM="$(id -u)"
launchctl kickstart -k "gui/${UID_NUM}/com.claudecommand" 2>/dev/null \
  && print -- "[hotkeys] Command restarted with new config." \
  || print -- "[hotkeys] Command not running — start it with ./install-agent.sh"

print -- "[hotkeys] wrote $CFG ; cleared pbs Service shortcuts."
