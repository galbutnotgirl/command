# Command User Guide

Command is a native macOS menu-bar app for sending selected text, screenshots, typed notes, and dictated notes to Claude, ChatGPT, or Codex. It also supports background commands through `claude -p` or `codex exec -`, clipboard history, dictation history, import/export, and local troubleshooting.

This guide is written for end users. For a shorter cheat sheet, see [QUICK_REFERENCE.md](QUICK_REFERENCE.md). For ready-to-copy workflow setups, see [EXAMPLES.md](EXAMPLES.md). Maintainer and architecture notes live in [BACKGROUND_TRIGGER_INTEGRATION.md](BACKGROUND_TRIGGER_INTEGRATION.md).

## Quick Start

1. Install and launch Command. See [INSTALL.md](INSTALL.md) for first-time install details.
2. Open the menu-bar icon, then choose **Settings**.
3. In **Set Up**, grant Accessibility. Grant Screen Recording if you use screenshots. Grant Microphone if you use dictation or voice custom actions.
4. Open **Shortcuts** and confirm the built-in Compose combinations you want.
5. Try **Selected text -> Existing chat** or **Selected text -> New chat** with selected text in any app.

For permission details and reset commands, see [PERMISSIONS.md](PERMISSIONS.md).

## Choose Claude, ChatGPT, or Codex

Open **Settings -> Shortcuts** and choose **Default assistant**. Existing and fresh installations default to Claude. Choose **ChatGPT / Codex**, then select **ChatGPT** for general chats or **Codex** for workspace coding. ChatGPT and Codex delivery remain opt-in until **Set Up** shows ChatGPT app, Codex CLI, and workspace readiness.

Provider resolution is trigger override, then Custom Action default, then global default. Claude exposes Chat, Cowork, and Code destinations. Codex uses configured workspace instead. Command never silently sends to another provider when selected provider is unavailable.

Default built-in shortcuts:

| Built-in combination | Default | Result |
|---|---:|---|
| Selected text -> Existing chat | Option-F8 | Send selected text into current Claude chat. |
| Selected text -> New chat | F8 | Open new Claude chat and wait for your note. |
| Selected text -> New chat + auto-submit | Unbound | Open new Claude chat, submit, then restore focus. |
| Screenshot -> Existing chat | Option-F7 | Capture screenshot and add to current chat. |
| Screenshot -> New chat | F7 | Capture screenshot and open new chat. |
| Screenshot -> New chat + auto-submit | Unbound | Capture screenshot, open new chat, submit. |
| Clipboard History | F6 | Open searchable clipboard picker. |
| Dictate -> Insert | Home | Speak and paste transcript at cursor. |
| Dictate -> Assistant | Option-Home | Speak and send transcript to selected assistant. |

You can change prompt and trigger shortcuts from **Settings -> Shortcuts**. Open the prompt/action editor or trigger row, click a key field, press a combo, press Delete to clear, or Esc to cancel. Dictation shortcuts live in **Settings -> Dictation Settings**.

Shortcut capture notes:

| Case | Guidance |
|---|---|
| F6/F7/F8 and Home | Default alpha bindings. F6/F7/F8 can still conflict with app shortcuts, and Home can conflict with navigation-heavy workflows. |
| Home, End, PgUp, PgDn | Useful alternatives for press-and-hold dictation on keyboards where F-keys conflict. rebind dictation shortcuts in Dictation Settings. |
| Press-and-hold dictation | Hold to record, release after the last word. The stop sound confirms release; the active menu-bar chip may stay visible while tail capture, transcription, cleanup, and dispatch finish. |
| Locked dictation | Double-tap to lock recording on when holding is awkward; stop from the menu or dictation control. |

## Menu Bar

Command lives in the macOS menu bar. The menu is intentionally short:

| Menu item | Shows when | Use |
|---|---|---|
| Bound prompt/action shortcuts | Trigger is enabled and has a key binding. | Run that prompt/action without opening Settings. |
| Stop Dictation / Cancel Dictation | Dictation is recording. | End or cancel the current recording from the menu. |
| Settings | Always. | Open Settings; keyboard shortcut is Command-,. |
| Quit Command | Always. | Quit the app; keyboard shortcut is Command-Q. |

Unbound combinations, disabled triggers, and auto-submit combinations with no shortcut do not appear in the menu. They stay editable in **Settings -> Shortcuts**.

## Prompt Model

Command is organized around prompts.

Each prompt can have one or more triggers:

| Trigger | Captures |
|---|---|
| Selected text | Current selection, falling back to recent clipboard text. |
| Screenshot | A region or window capture. |
| Popup | Small type-in window; Command-Return submits. |
| Voice | Press-and-hold or lock dictation, then use transcript. |

Each prompt chooses delivery:

| Delivery | Result |
|---|---|
| Existing session | Paste into current Claude, ChatGPT, or Codex session. |
| New session | Open new session in selected assistant and wait. |
| Background | Run through selected local CLI with no assistant window. |

Claude prompts can choose destination. Codex prompts inherit configured workspace:

| Destination | Result |
|---|---|
| Default | Use global Claude destination from Shortcuts. |
| Chat | Send to Claude Chat mode. |
| Cowork | Send to Claude Cowork mode. |
| Code | Send to Claude Code mode. |

You can set provider defaults at three levels:

1. Global default assistant in **Shortcuts**.
2. Prompt/action default assistant, delivery, and Claude destination.
3. Trigger-level override for one specific trigger.

If a trigger shows `—`, it inherits from the prompt/action.

## Built-In Compose

Built-in Compose lives at the top of **Shortcuts**. It is one shared prompt with selected-text and screenshot combinations:

| Combination | Input | Delivery | Default submit |
|---|---|---|---|
| Selected text -> Existing chat | Selected text | Existing chat | No |
| Selected text -> New chat | Selected text | New chat | No |
| Selected text -> New chat + auto-submit | Selected text | New chat | Yes |
| Screenshot -> Existing chat | Screenshot | Existing chat | No |
| Screenshot -> New chat | Screenshot | New chat | No |
| Screenshot -> New chat + auto-submit | Screenshot | New chat | Yes |

Click the pencil icon to edit Compose. Prompt text, default auto-submit, and per-combination auto-submit overrides live in that editor. Prompt text is shared across selected-text and screenshot combinations.

Useful variables:

| Variable | Meaning |
|---|---|
| `{selection}` | Captured text, typed popup text, spoken text, or selected text. |
| `{context}` | App/site-specific context from Context rules. |
| `{url}` | Source URL when available. |
| `{file}` | Screenshot file path for background delivery. |

If `{selection}` is omitted, Command appends captured content under the prompt.

## Custom Actions

Use Custom Actions when one prompt needs its own triggers, delivery, destination, or background behavior.

To create one:

1. Open **Settings -> Shortcuts**.
2. Under **Custom Actions**, click **Add**.
3. Name the action.
4. Pick delivery: Existing chat, New chat, or Background.
5. Pick destination: Default, Chat, Cowork, or Code.
6. Write prompt text.
7. Save.
8. Add triggers under the action row.

Example custom action:

Name: `Summarize for follow-up`

Prompt:

```text
Summarize this for a follow-up message.

Return:
- Key points
- Open questions
- Suggested next step

{selection}
```

Suggested triggers:

| Trigger | Delivery | Destination |
|---|---|---|
| Selected text | New chat | Default |
| Popup | Existing chat | Default |
| Voice | New chat | Code |

More complete setups live in [EXAMPLES.md](EXAMPLES.md).

## Background Actions

Background delivery runs without opening assistant app. Command renders prompt and passes it to `claude -p` or `codex exec -`. Runs appear under **Command History -> Background** with provider, status, age, logs, retry, mark-failed, retention, and parsed result when available.

Use background actions for:

- Creating tasks.
- Summarizing selected text into a file.
- Running a local Claude Code skill.
- Processing a screenshot without switching apps.
- Any workflow where visible chat is not needed.

Legacy right-click Services are optional for source installs. If installed, **Claude - To-Do** is a background action: selected text wins when highlighted; otherwise Safari, Chrome, Brave, Chromium, and Arc send the current tab URL. Confirm the captured source, result, and log under **Command History -> Background**.

Background action fields:

| Field | Meaning |
|---|---|
| Skill name | Optional slash skill name, without leading slash. |
| Prompt text | Prompt sent to `claude -p`. |
| Trigger kind | Selected text, screenshot, popup, or voice. |
| Command history | Run records, status, retry, mark-failed, retention, parsed result, and logs. |

Structured result convention:

If the last non-empty line printed by `claude -p` matches `KEY=value`, Command stores and shows it. Example:

```text
TASK_ID=abc123
```

Rules:

- Only the last non-empty stdout line is parsed.
- The whole trimmed line must be `KEY=value`; prose containing `TASK_ID=abc123` does not count.
- Common keys are `TASK_ID=<id>` and `ERROR=<reason>`, but any uppercase/lowercase key that starts with a letter or underscore works.
- Result text appears in the completion notification, Command History row, and diagnostic summary.
- Command does not run a follow-up action from that value yet.

Status meanings:

| Status | Meaning | What to do |
|---|---|---|
| Running | Local `claude -p` process has started. | Wait, or use Command History if it becomes stalled. |
| Succeeded | CLI exited with code 0. | Review result and log. |
| Failed | CLI failed, command was missing, or user marked the run failed. | Open log, fix prompt/settings, then Retry. |
| Stalled | Record stayed running after process likely died. | Mark failed, then Retry if the prompt is still valid. |

## Context Rules

Context rules add source-aware information to prompts. Open **Settings -> Context**.

Use them when Claude should know where content came from:

| Match type | Example | Use |
|---|---|---|
| App name | Slack | Add Slack-specific instruction. |
| Bundle ID | com.apple.mail | Add Mail-specific instruction. |
| URL host | docs.google.com | Add Docs/Sheets/Slides guidance. |
| Path prefix | /document/ | Split one host into several rules. |

Example:

Pattern: `docs.google.com`

Path prefix: `/document/`

Text:

```text
This came from Google Docs. Preserve document structure and call out suggested edits clearly.
```

## Clipboard History

Open **Settings -> Clipboard History** to configure:

- Enable or disable clipboard history.
- Open Clipboard History shortcut.
- Retention days.
- Picker theme.
- Clear recent clips.

Clipboard history is local. Secret-looking copies and copies from known password apps are skipped.

Picker controls:

| Key | Action |
|---|---|
| Type | Search clips. |
| Up/Down | Move selection. |
| Return | Paste selected clip. |
| Command-Return | Paste and keep picker open. |
| Esc | Close picker. |

## Dictation

Dictation is local and on-device through Parakeet TDT.

Tabs:

| Tab | Purpose |
|---|---|
| History | Past dictations, raw and processed text, suggested corrections. |
| Corrections | Misheard -> correct replacement rules. |
| Vocabulary | Proper nouns, product names, filler words. |
| Dictation Settings | Model, microphone access, shortcuts, processing, sounds. |

Use **Dictation Settings** for Dictate -> Insert and Dictate -> Assistant shortcuts. Use **Shortcuts** for voice triggers tied to prompt actions.

Voice custom actions use the same recording engine as built-in Dictate. Configure voice prompt actions in **Shortcuts**, not Dictation Settings.

If final words are missing, compare **Dictation History** raw text, processed text, and the sent command before filing a bug.

## Command History

Open **Settings -> Command History**.

Command History shows:

| Section | Includes |
|---|---|
| Foreground | Existing chat and New chat sends. |
| Background | `claude -p` runs, including logs and retry. |

Filters:

- All
- Running
- Succeeded
- Failed

Retention defaults to 7 days. Changing command retention also keeps background-command retention aligned.

## Import And Export

Open **Settings -> About -> Import / Export**.

Export can include:

- Shortcuts, custom actions, and built-in compose auto-submit settings.
- Built-in prompt text and Context rules.
- Dictation vocabulary, corrections, and filler words.
- Background action settings.
- App preferences.

Import lets you preview available sections and choose:

| Mode | Result |
|---|---|
| Keep current | Skip that section. |
| Merge | Keep current items, incoming items win on matching keys. |
| Overwrite | Replace current section with imported section. |

Import preview shows counts before anything changes.

## Privacy And Local Files

Command stores its own settings and history on this Mac.

| Area | Location | Notes |
|---|---|---|
| Shortcuts and prompt text | `~/.claude/state/` | Includes built-in prompt text, hotkeys, custom actions, and context rules. |
| Clipboard history | `~/.claude/state/cliphistory/` | Local searchable history. Secret-looking copies and known password-app copies are skipped. |
| Dictation history and vocabulary | `~/Library/Application Support/DictationLab/` | Local transcripts, corrections, vocabulary, and processing settings. |
| Command history | `~/Library/Application Support/claude-command/command-history/` | Foreground shortcut send records. |
| Background runs | `~/Library/Application Support/claude-command/submissions/` and `logs/` | `claude -p` submission records and logs. |
| Background CLI settings | `~/Library/Application Support/claude-command/settings.json` | Command, working directory, extra args, and notification settings. |

Clipboard history and dictation history do not leave your Mac through Command. Background actions are different: they run the local Claude CLI (`claude -p`), so network access, file access, and tool use depend on your Claude CLI setup, allowed tools, and the prompt you wrote.

Review background prompts and CLI extra args before sharing an export with another user. Imports preview sections before changes are applied, and **Keep current** skips a section entirely.

## Troubleshooting

Start with **Settings -> Set Up** for permission and component status. Use **Settings -> Command History** for foreground/background command logs, and **Settings -> Dictation Settings** for microphone/model checks.

See [Troubleshooting](TROUBLESHOOTING.md) for symptom-first fixes, log locations, command checks, and support details. For vulnerabilities, exposed secrets, private logs, or sensitive diagnostics, use [Security Policy](SECURITY.md) instead of a public issue.

For a full tab-by-tab map of Settings, see [Settings Reference](SETTINGS_REFERENCE.md).

Common fixes:

| Problem | Fix |
|---|---|
| Hotkeys do nothing | Grant Accessibility, then restart Command. |
| Shortcut keys conflict | Rebind prompt shortcuts in Shortcuts; rebind dictation shortcuts in Dictation Settings. |
| Screenshot fails | Grant Screen Recording, then restart Command. |
| Dictation does not start | Grant Microphone and download model in Dictation Settings. |
| Background action fails | Open Command History, expand failed run, inspect log. |
| Claude opens wrong surface | Check global destination, prompt destination, then trigger override. |
| Import does not show expected content | Confirm JSON is Command export or legacy settings/templates/vocabulary export. |

Terminal checks:

```bash
./doctor.sh
./build-agent.sh
./install-agent.sh
python3 ./test/test-docs.py
```

Logs:

| Log | Purpose |
|---|---|
| `~/Library/Logs/claude-command.log` | Shortcut activity. |
| `~/.claude/logs/command-agent.err` | App dispatch, hotkey, and startup errors. |
| `~/.claude/logs/clipwatch.err` | Clipboard History errors. |
| `~/Library/Application Support/claude-command/logs/` | Background run logs. |

## Updating

Open **Settings -> About -> Check for Updates**.

Channels:

| Channel | Receives |
|---|---|
| Alpha | Alpha, beta, and stable builds. |
| Beta | Beta and stable builds. |
| Stable | Stable builds only; visible but unavailable until the first stable release exists. |

See [Updates](UPDATES.md) for manual alpha installs, backup before updating, failed updates, and rollback.

## Uninstall

For full removal steps, local data choices, and verification commands, see [Uninstall](UNINSTALL.md).

For a source checkout that installed Quick Actions and a LaunchAgent:

```bash
./uninstall-quick-action.sh
launchctl bootout "gui/$(id -u)/com.claudecommand" 2>/dev/null || true
rm -f ~/Library/LaunchAgents/com.claudecommand.plist
```

If you installed older alpha builds that used a separate clipboard watcher LaunchAgent, remove that legacy agent too:

```bash
launchctl bootout "gui/$(id -u)/com.claudecommand.clipwatch" 2>/dev/null || true
rm -f ~/Library/LaunchAgents/com.claudecommand.clipwatch.plist
```

Then remove `~/Applications/Command.app` if installed there.
