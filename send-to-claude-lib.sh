#!/bin/zsh
# send-to-claude-lib.sh — pure function definitions used by send-to-claude.sh,
# split out so they're sourceable (and testable — see test/test-shell.sh)
# without also running the rest of the script's side-effecting top half
# (clipboard capture, AppleScript, etc).
#
# expand_template() reads these globals from its caller rather than taking them
# as extra args (matches how send-to-claude.sh already used it inline): set
# CONTEXT_LINE / URL / SOURCE_LINE before calling. Mirrors
# CommandTemplates.swift's expandTemplate() — keep both in sync by hand.

read_template() {  # $1 = action, needs $TEMPLATES_PATH set by the caller
  [ -f "$TEMPLATES_PATH" ] || { printf ''; return; }
  /usr/bin/python3 -c "
import json
try:
    d = json.load(open('$TEMPLATES_PATH'))
    print(d.get('$1', ''), end='')
except Exception:
    pass
" 2>/dev/null
}

expand_template() {  # $1 = raw template string, $2 = selection text to substitute
                      # ($2 lets the go+image case pass "(image attached below)" in
                      # place of $SEL, same as the old hardcoded behavior there)
  local raw="$1" t="$1" sel="$2"
  t="${t//\{selection\}/$sel}"; t="${t//\{prompt\}/$sel}"; t="${t//\{text\}/$sel}"
  t="${t//\{context\}/$CONTEXT_LINE}"
  t="${t//\{url\}/$URL}"
  if [[ "$raw" != *"{selection}"* && "$raw" != *"{prompt}"* && "$raw" != *"{text}"* ]]; then
    if [ -z "$t" ]; then t="$sel"; else t="${t}"$'\n\n'"${sel}"; fi
  fi
  if [[ "$raw" == *"{source}"* ]]; then
    t="${t//\{source\}/$SOURCE_LINE}"
  elif [ -n "$SOURCE_LINE" ]; then
    t="${SOURCE_LINE}"$'\n\n'"${t}"
  fi
  printf '%s' "$t"
}
