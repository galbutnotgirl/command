# Command Troubleshooting

Start here when something does not work.

## First Checks

1. Open **Settings -> Set Up**.
2. Confirm Accessibility is green.
3. Confirm Screen Recording if using screenshots.
4. Confirm Microphone and model status if using dictation or voice custom actions.
5. Restart Command if a permission changed.

For what each permission does, optional Set Up items, and reset commands, see [PERMISSIONS.md](PERMISSIONS.md).

For binary installs, quit and reopen `~/Applications/Command.app`. From a repo checkout, you can also restart launchd:

```bash
./install-agent.sh
```

## Common Symptoms

| Symptom | Fix |
|---|---|
| Hotkeys do nothing | Grant Accessibility, then restart Command. Confirm shortcut row is enabled and bound in **Settings -> Shortcuts** or **Dictation Settings**. |
| Shortcut keys do system functions | Rebind prompt shortcuts in **Settings -> Shortcuts**, or rebind dictation shortcuts in **Settings -> Dictation Settings**. |
| Home or another non-F-key shortcut does not start dictation | Rebind it in **Settings -> Dictation Settings**, not **Shortcuts**. Dictate shortcuts use the press-and-hold/double-tap recorder path; prompt voice triggers live under **Shortcuts**. |
| Screenshot capture fails | Grant Screen Recording, then restart Command. If macOS still blocks capture, quit and relaunch Command. |
| Screenshot -> New chat shortcut does nothing | Confirm the **Screenshot -> New chat** combination is bound and enabled in **Settings -> Shortcuts**. Confirm Screen Recording is granted. |
| Dictation does not start | Grant Microphone, download Parakeet model in **Dictation Settings**, then retry. |
| Dictation cuts off final words | Release the key after the last word, then check **Dictation History** to see whether raw text or processed text lost the tail. The stop sound means release was accepted; the menu-bar recording chip stays visible until tail capture, model finalization, and dispatch finish. Include exact behavior and diagnostic lines in a support report. |
| Dictation feels slow after release | Watch the active menu-bar chip, not the sound. The sound fires on release; the chip remains during tail capture and transcription. Shorter utterances should finish faster. If it stays visible after transcription appears, include diagnostics. |
| Dictation History has full raw text but sent command is missing words | Report whether processed text is also complete. If raw and processed text are complete, include the Command History entry or sent-command diagnostic lines because the loss happened during dispatch, not recording. |
| Voice custom action records but does not send | Confirm trigger delivery/destination in **Settings -> Shortcuts** and inspect **Command History**. |
| Clipboard History is empty | Confirm Clipboard History is enabled and running in **Settings -> Set Up**. Copy a normal text snippet from a non-password app. |
| Right-click actions show as optional or missing | This is not a broken binary install. Global shortcuts do not need Services. Source installs can run `./install-quick-action.sh` if you want legacy macOS Services menu items. |
| Right-click To-Do does not capture a browser URL | If text is selected, Command sends the selection. If no text is selected and the front app is Safari, Chrome, Brave, Chromium, or Arc, it sends the current tab URL. Check **Command History -> Background** for the captured source and result. |
| Claude opens wrong surface | Check global destination, prompt/action destination, then trigger override. |
| Background action fails | Open **Settings -> Command History -> Background**, expand failed run, inspect log, and check **Background Settings**. |
| Import does not show expected content | Confirm file is a Command export or legacy settings/templates/vocabulary export. |
| Update fails | Confirm channel in **Settings -> About**; try manual install from [Install Guide](INSTALL.md). |

## Logs

| Log | Purpose |
|---|---|
| `~/Library/Logs/claude-command.log` | Shortcut activity, capture/paste/open flow. |
| `~/.claude/logs/command-agent.err` | App dispatch, hotkey, and startup errors. |
| `~/.claude/logs/clipwatch.err` | Clipboard History errors. |
| `~/.claude/logs/attribution.log` | Clipboard/source attribution. |
| `~/Library/Application Support/claude-command/logs/` | Background run logs. |

Use **Settings -> About -> Copy Diagnostic Info** to copy app path, bundle ID, version, minimum macOS, update channel/check status, shortcut binding summary, Set Up permission/component status, recent log tails, recent command summaries, Clipboard History errors, and last three dictation raw/processed previews.

## Command Checks

From repo checkout:

```bash
./doctor.sh
python3 ./test/test-docs.py
./test/test-shell.sh
```

For code changes:

```bash
cd agent && swift test
cd ../vendor/claude-command-capture && node --test
```

## Bug Reports

For bugs, open **Settings -> About -> Report a Bug** and include:

- Version and macOS version.
- Trigger kind and shortcut.
- Source app.
- Expected result.
- Actual result.
- Relevant diagnostic lines from **Copy Diagnostic Info**.

For a tab-by-tab map of the controls named here, see [Settings Reference](SETTINGS_REFERENCE.md).
