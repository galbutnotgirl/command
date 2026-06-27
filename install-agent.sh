#!/bin/zsh
# install-agent.sh — write a LaunchAgent plist, bootstrap it, and start ClaudeCommand.
# launchd owns the process so KeepAlive (restart on non-zero exit) works.
# Re-run after every rebuild to pick up the new binary.
emulate -L zsh
set -uo pipefail

DIR="${0:A:h}"
LABEL="com.claudecommand"
APP="${DIR}/ClaudeCommand.app"
BIN="${APP}/Contents/MacOS/ClaudeCommand"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
OLD_CLIPWATCH="${HOME}/Library/LaunchAgents/com.claudecommand.clipwatch.plist"

[ -x "$BIN" ] || { print -- "[agent] missing ClaudeCommand.app — run ./build-agent.sh first"; exit 1; }

print -- "[agent] using app at ${APP}"

# Register with Launch Services so the app icon shows in System Settings privacy panes.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP" 2>/dev/null || true

mkdir -p "${HOME}/.claude/logs" "${HOME}/.claude/state"

UID_NUM="$(id -u)"

# Remove stale clipwatch LaunchAgent (now a subprocess, not a separate agent).
if [ -f "$OLD_CLIPWATCH" ]; then
    print -- "[agent] removing old clipwatch LaunchAgent (now bundled subprocess)"
    launchctl bootout "gui/${UID_NUM}/com.claudecommand.clipwatch" 2>/dev/null || true
    rm -f "$OLD_CLIPWATCH"
fi

# Kill any running instance.
pkill -x ClaudeCommand 2>/dev/null || true
sleep 0.3

# Unload existing LaunchAgent if loaded (bootout is idempotent on failure).
launchctl bootout "gui/${UID_NUM}/${LABEL}" 2>/dev/null || true
sleep 0.2

# Write the LaunchAgent plist. BIN is the absolute path so launchd resolves it
# correctly regardless of what directory it was bootstrapped from.
cat > "$PLIST" <<APLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>${LABEL}</string>
	<key>Program</key><string>${BIN}</string>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key>
	<dict><key>SuccessfulExit</key><false/></dict>
	<key>ProcessType</key><string>Interactive</string>
	<key>StandardErrorPath</key><string>${HOME}/.claude/logs/command-agent.err</string>
	<key>StandardOutPath</key><string>${HOME}/.claude/logs/command-agent.out</string>
</dict>
</plist>
APLIST
print -- "[agent] wrote ${PLIST}"

# Bootstrap and kickstart — launchd now owns the process; KeepAlive is active.
launchctl bootstrap "gui/${UID_NUM}" "$PLIST"
launchctl kickstart "gui/${UID_NUM}/${LABEL}"

# Wait for socket (launchd-started instance binds it on startup).
for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    [ -S "${HOME}/.claude/state/command-agent.sock" ] && break
    sleep 0.2
done

if [ -S "${HOME}/.claude/state/command-agent.sock" ]; then
    print -- "[agent] ✓ running under launchd — restart-on-exit active"
    print -- "[agent] Login Item: System Settings → General → Login Items"
else
    print -- "[agent] ⚠ socket not up yet — check ~/.claude/logs/command-agent.err"
fi
