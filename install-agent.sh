#!/bin/zsh
# install-agent.sh — write a LaunchAgent plist, bootstrap it, and start Command.
# launchd owns the process so KeepAlive (restart on non-zero exit) works.
# Re-run after every rebuild to pick up the new binary.
emulate -L zsh
set -uo pipefail

DIR="${0:A:h}"
LABEL="com.claudecommand"
SRC_APP="${DIR}/Command.app"
# Install to ~/Applications so macOS Login Items shows the correct app icon.
# Apps outside /Applications or ~/Applications get a generic executable icon.
INSTALL_DIR="${HOME}/Applications"
APP="${INSTALL_DIR}/Command.app"
OLD_APP="${INSTALL_DIR}/ClaudeCommand.app"
BIN="${APP}/Contents/MacOS/Command"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
OLD_CLIPWATCH="${HOME}/Library/LaunchAgents/com.claudecommand.clipwatch.plist"

[ -x "${SRC_APP}/Contents/MacOS/Command" ] || { print -- "[agent] missing Command.app — run ./build-agent.sh first"; exit 1; }

# Fresh install = no prior LaunchAgent plist AND no prior app bundle.
# Update = app already exists (in-place sync, TCC grants survive).
# Never clear onboardingCompleted or re-prompt grants on update.
FRESH_INSTALL=false
[[ ! -f "$PLIST" && ! -d "$APP" ]] && FRESH_INSTALL=true

# In-place update: sync files without destroying the bundle.
# Removing + recreating the .app causes macOS TCC to treat it as a new app and
# revoke Accessibility / Screen Recording grants. rsync replaces only changed files
# while the bundle stays at the same path with the same identity → grants persist.
mkdir -p "$INSTALL_DIR"
if [ -d "$APP" ]; then
rsync -a --delete "${SRC_APP}/" "${APP}/"
if [ -d "$OLD_APP" ]; then
  rm -rf "$OLD_APP"
  print -- "[agent] removed old ClaudeCommand.app bundle"
fi
    print -- "[agent] updated in-place at ${APP} (TCC grants preserved)"
else
    cp -R "$SRC_APP" "$APP"
    print -- "[agent] installed to ${APP} (first install)"
fi

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
pkill -x Command 2>/dev/null || true
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

# Clipboard History is opt-in during onboarding. Never turn it on during install.
if ! defaults read com.claudecommand cliphistoryEnabled >/dev/null 2>&1; then
    defaults write com.claudecommand cliphistoryEnabled -bool false
fi

# Fresh install: clear persisted onboarding flag so setup flow triggers on first launch.
# On update-installs (plist already existed) this is skipped — preserves user state.
if $FRESH_INSTALL; then
    defaults delete com.claudecommand onboardingCompleted 2>/dev/null || true
    print -- "[agent] fresh install — onboarding will run on first launch"
    print -- "[agent] ⚠ re-grant Accessibility + Screen Recording in System Settings → Privacy"
fi
