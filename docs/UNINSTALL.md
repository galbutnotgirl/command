# Command Uninstall

Use this when removing Command from a Mac. For installing or updating, see [INSTALL.md](INSTALL.md) and [UPDATES.md](UPDATES.md).

## Standard Uninstall

For a downloaded app install:

```bash
launchctl bootout "gui/$(id -u)/com.claudecommand" 2>/dev/null || true
pkill -x Command 2>/dev/null || true
rm -f ~/Library/LaunchAgents/com.claudecommand.plist
rm -rf ~/Applications/Command.app
```

If you installed source-only Quick Actions from a repo checkout, remove those too:

```bash
./uninstall-quick-action.sh
```

## Legacy Clipboard Watcher

Older alpha builds used a separate clipboard watcher LaunchAgent. Remove that legacy agent too if it exists:

```bash
launchctl bootout "gui/$(id -u)/com.claudecommand.clipwatch" 2>/dev/null || true
rm -f ~/Library/LaunchAgents/com.claudecommand.clipwatch.plist
```

Current builds launch Clipboard History from inside Command, so there is no separate clipboard watcher LaunchAgent to keep.

## Optional Data Removal

Settings, histories, and logs are local. Remove only if you do not want to keep them for reinstall or debugging:

| Data | Path |
|---|---|
| Shortcuts, prompts, context, preferences | `~/.claude/state/` |
| Clipboard History | `~/.claude/state/cliphistory/` |
| Dictation History / vocabulary | `~/Library/Application Support/DictationLab/` |
| Command History / background logs | `~/Library/Application Support/claude-command/` |
| App logs | `~/Library/Logs/claude-command.log` and `~/.claude/logs/` |

## Verify Removal

```bash
launchctl print gui/$(id -u)/com.claudecommand
pgrep -fl Command
pgrep -fl clipwatch.py
```

`launchctl` should report no service. `pgrep` should return no Command or bundled `clipwatch.py` process.

## Reinstall Later

Use [INSTALL.md](INSTALL.md). If you kept local data, Command should reuse existing settings on next launch.

For reinstall setup tabs and controls, see [SETTINGS_REFERENCE.md](SETTINGS_REFERENCE.md).
