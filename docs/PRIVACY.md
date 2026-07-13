# Command Privacy

Command stores settings and history on this Mac. Clipboard and dictation history do not leave through Command; background actions use selected local Claude or Codex CLI setup.

## Short Version

- Settings, shortcuts, history, vocabulary, and logs are local files.
- Clipboard History skips known password apps and secret-looking copies.
- Dictation runs on-device and stores history, corrections, and vocabulary locally.
- Background actions call local `claude -p` or `codex exec -`; access depends on provider CLI, sandbox, allowed tools, and prompt.

## Local File Locations

| Area | Location | Notes |
|---|---|---|
| Shortcuts and prompt text | `~/.claude/state/` | Hotkeys, compose prompt text, custom actions, context rules, command config, and clipboard metadata. |
| Clipboard history | `~/.claude/state/cliphistory/` | Local searchable history; password-app and secret-looking copies are skipped. |
| Dictation data | `~/Library/Application Support/DictationLab/` | Transcripts, corrections, vocabulary, and processing settings. |
| Command history | `~/Library/Application Support/claude-command/command-history/` | Foreground shortcut send records. |
| Background runs | `~/Library/Application Support/claude-command/submissions/` | `claude -p` submission records. |
| Background captures | `~/Library/Application Support/claude-command/captures/` | Temporary captured files used by background image actions. |
| Background logs | `~/Library/Application Support/claude-command/logs/` | Run logs for background actions. |
| Background CLI settings | `~/Library/Application Support/claude-command/settings.json` | Command, working directory, extra args, and notification settings. |
| App preferences | `~/Library/Preferences/com.claudecommand.plist` | Update channel, launch options, picker theme, sound preferences, and app toggles. |
| App logs | `~/Library/Logs/claude-command.log` and `~/.claude/logs/` | Shortcut actions, app dispatch, Clipboard History, and attribution logs. |
| LaunchAgent | `~/Library/LaunchAgents/com.claudecommand.plist` | Starts Command at login when Launch at login is enabled; source installs may create it during install. |

## Background Actions

Background delivery sends rendered prompts to selected local CLI. Command defaults Codex to read-only, but network access, file access, MCP/tool use, and account behavior ultimately depend on Claude/Codex configuration and chosen execution settings.

Review background prompts and CLI extra args before enabling a shortcut or sharing an export.

## Import And Export Safety

Exports can include shortcuts, prompt settings, context rules, vocabulary, background settings, and app preferences. Import previews sections before changes apply.

| Import mode | Result |
|---|---|
| Keep current | Skip section entirely. |
| Merge | Keep current items; incoming items win matching keys. |
| Overwrite | Replace current section with imported section. |

## Diagnostics

**Settings -> About -> Copy Diagnostic Info** copies app path, bundle ID, version, minimum macOS, update channel/check status, shortcut binding summary, Set Up status, log tails, recent command summaries, and recent dictation previews. Review copied diagnostics before sharing if logs or recent text may include sensitive content.

If diagnostics, logs, clipboard text, dictation text, screenshots, or exports reveal a vulnerability, exposed secret, private log, or sensitive data path, do not file a public issue. Use [Security Policy](SECURITY.md).

For a tab-by-tab map of Settings controls, see [SETTINGS_REFERENCE.md](SETTINGS_REFERENCE.md).
