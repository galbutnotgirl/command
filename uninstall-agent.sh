#!/bin/zsh
# uninstall-agent.sh — fully remove ClaudeCommand for clean reinstall/testing.
# Stops the process, unloads launchd, removes app + state + prefs + TCC grants.
emulate -L zsh
set -uo pipefail

DIR="${0:A:h}"
LABEL="com.claudecommand"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
APP="${HOME}/Applications/ClaudeCommand.app"
SRC_APP="${DIR}/ClaudeCommand.app"  # also remove build artifact if present
UID_NUM="$(id -u)"

print -- "[uninstall] stopping ClaudeCommand…"
pkill -x ClaudeCommand 2>/dev/null || true
sleep 0.3

print -- "[uninstall] unloading LaunchAgent…"
launchctl bootout "gui/${UID_NUM}/${LABEL}" 2>/dev/null || true

print -- "[uninstall] removing LaunchAgent plist…"
rm -f "$PLIST"

# Stale clipwatch agent (old installs).
CLIPWATCH_PLIST="${HOME}/Library/LaunchAgents/com.claudecommand.clipwatch.plist"
if [ -f "$CLIPWATCH_PLIST" ]; then
    launchctl bootout "gui/${UID_NUM}/com.claudecommand.clipwatch" 2>/dev/null || true
    rm -f "$CLIPWATCH_PLIST"
    print -- "[uninstall] removed old clipwatch LaunchAgent"
fi

print -- "[uninstall] removing app bundle…"
rm -rf "$APP" "$SRC_APP"

print -- "[uninstall] clearing UserDefaults (preferences + onboarding state)…"
defaults delete com.claudecommand 2>/dev/null || true

print -- "[uninstall] clearing runtime state files…"
rm -f \
    "${HOME}/.claude/state/clipboard.json" \
    "${HOME}/.claude/state/command-agent.sock"

# User config (hotkeys, settings) — ask before nuking.
for cfg_file in command-hotkeys.json command-config.json; do
    cfg_path="${HOME}/.claude/state/${cfg_file}"
    if [ -f "$cfg_path" ]; then
        print -n "[uninstall] remove ${cfg_file} (hotkeys/settings)? [y/N] "
        read -r REPLY
        if [[ "${REPLY}" =~ ^[Yy]$ ]]; then
            rm -f "$cfg_path"
            print -- "[uninstall] ${cfg_file} removed"
        else
            print -- "[uninstall] ${cfg_file} kept"
        fi
    fi
done

# Clipboard history — ask before nuking (can be large / personal).
if [ -d "${HOME}/.claude/state/cliphistory" ]; then
    print -n "[uninstall] remove clipboard history? [y/N] "
    read -r REPLY
    if [[ "${REPLY}" =~ ^[Yy]$ ]]; then
        rm -rf "${HOME}/.claude/state/cliphistory"
        print -- "[uninstall] clipboard history removed"
    else
        print -- "[uninstall] clipboard history kept"
    fi
fi

print -- "[uninstall] clearing log files…"
rm -f \
    "${HOME}/.claude/logs/command-agent.out" \
    "${HOME}/.claude/logs/command-agent.err" \
    "${HOME}/.claude/logs/clipwatch.out" \
    "${HOME}/.claude/logs/clipwatch.err" \
    "${HOME}/.claude/logs/claude-command.err" \
    "${HOME}/.claude/logs/claude-command-bg.log"

# TCC grants — reset Accessibility + Screen Recording for the bundle.
# tccutil requires sudo for some services on macOS 14+; try without first.
print -- "[uninstall] resetting TCC permissions (Accessibility + ScreenCapture)…"
tccutil reset Accessibility "${LABEL}" 2>/dev/null \
    && print -- "[uninstall]   ✓ Accessibility reset" \
    || print -- "[uninstall]   ⚠ Accessibility reset failed — may need: sudo tccutil reset Accessibility ${LABEL}"
tccutil reset ScreenCapture "${LABEL}" 2>/dev/null \
    && print -- "[uninstall]   ✓ ScreenCapture reset" \
    || print -- "[uninstall]   ⚠ ScreenCapture reset failed — may need: sudo tccutil reset ScreenCapture ${LABEL}"

print -- ""
print -- "[uninstall] ✓ done. State:"
print -- "  • LaunchAgent: removed"
print -- "  • App bundle: removed"
print -- "  • UserDefaults: cleared"
print -- "  • TCC grants: reset"
print -- ""
print -- "Next: ./build-agent.sh && ./install-agent.sh"
