# Command Uninstall

Use this when removing Command from a Mac. For installing or updating, see [INSTALL.md](INSTALL.md) and [UPDATES.md](UPDATES.md).

## Standard Uninstall

In Command, open **About**, select **Uninstall Command…**, then choose:

- **Uninstall and Keep My Data** removes the app, background services, Quick Actions, and approvals. Settings and history remain for a later reinstall.
- **Uninstall and Remove Everything** also removes Command settings, Clipboard History, Command History, dictation history, vocabulary, logs, and old clean-install backups. Unrelated Claude files remain untouched.

Both options reset Accessibility, Screen Recording, and Microphone approvals. Command can revoke those approvals, but macOS never allows an app to grant them automatically.

For a source checkout or Terminal-based uninstall, run:

```bash
./uninstall-command.sh --keep-data
```

For full removal:

```bash
./uninstall-command.sh --remove-data
```

For an older downloaded build without the bundled uninstaller:

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

## Local Data

Settings, histories, and logs stay local. Full removal targets only Command-owned files inside these locations:

| Data | Path |
|---|---|
| Shortcuts, prompts, context, preferences | Named Command JSON files in `~/.claude/state/` |
| Clipboard History | `~/.claude/state/cliphistory/` |
| Dictation History / vocabulary | `~/Library/Application Support/DictationLab/` |
| Command History / background logs | `~/Library/Application Support/claude-command/` |
| App logs | `~/Library/Logs/claude-command.log` and `~/.claude/logs/` |

Full uninstall does not remove the whole `~/.claude/state/` or `~/.claude/logs/` directory.

## Permission Reset

To reset approvals without uninstalling:

```bash
tccutil reset Accessibility com.claudecommand
tccutil reset ScreenCapture com.claudecommand
tccutil reset Microphone com.claudecommand
```

System Settings may need to be closed and reopened before stale rows disappear.

## Verify Removal

```bash
launchctl print gui/$(id -u)/com.claudecommand
pgrep -fl Command
pgrep -x CommandClipboardWatcher
```

`launchctl` should report no service. `pgrep` should return no Command or bundled Clipboard History helper process.

## Reinstall Later

Use [INSTALL.md](INSTALL.md). If you kept local data, Command should reuse existing settings on next launch.

For reinstall setup tabs and controls, see [SETTINGS_REFERENCE.md](SETTINGS_REFERENCE.md).
