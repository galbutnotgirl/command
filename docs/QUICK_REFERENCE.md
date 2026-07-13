# Command Quick Reference

## Default Shortcuts

| Built-in combination | Default | Result |
|---|---:|---|
| Selected text -> Existing chat | Option-F8 | Send selected text into current Claude chat. |
| Selected text -> New chat | F8 | Open new Claude chat and wait. |
| Selected text -> New chat + auto-submit | Unbound | Open new Claude chat, submit, restore focus. |
| Screenshot -> Existing chat | Option-F7 | Capture screenshot and add to current chat. |
| Screenshot -> New chat | F7 | Capture screenshot and open new chat. |
| Screenshot -> New chat + auto-submit | Unbound | Capture screenshot, open new chat, submit. |
| Clipboard History | F6 | Open searchable clipboard picker. |
| Dictate -> Insert | Home | Speak and paste transcript at cursor. |
| Dictate -> Assistant | Option-Home | Speak and send transcript to selected assistant. |

Change prompt/action shortcuts in **Settings -> Shortcuts**. Dictation shortcuts live in **Settings -> Dictation Settings**. Open the relevant editor or trigger row, click a key field, press a combo. Delete clears. Esc cancels.

The menu-bar menu only shows prompt/action shortcuts that are enabled and bound to a key. Unbound combinations such as Go stay editable in Settings but do not appear in the menu.

## Shortcut Capture

| Case | Guidance |
|---|---|
| Home, End, PgUp, PgDn | Good choices for press-and-hold dictation because they avoid F-key media behavior on many keyboards. rebind dictation shortcuts in Dictation Settings. |
| F6/F7/F8 and Home | Default alpha choices. F6/F7/F8 can still conflict with app shortcuts, and Home can conflict with navigation-heavy workflows. |
| Press-and-hold voice | Hold to record, release after the last word. The stop sound confirms release; the active menu-bar chip can stay visible while tail capture, transcription, cleanup, and dispatch finish. |
| Double-tap voice | Double-tap to lock recording on when holding is awkward; stop from the menu or dictation control. |

## Menu Bar

| Item | Shows when |
|---|---|
| Bound prompt/action shortcut | Trigger is enabled and has a key binding. |
| Stop Dictation / Cancel Dictation | Dictation is recording. |
| Settings | Always; shortcut is Command-,. |
| Quit Command | Always; shortcut is Command-Q. |

Unbound combinations, disabled triggers, and auto-submit combinations with no shortcut stay in Settings and do not appear in the menu.

## Glossary

| Term | Meaning |
|---|---|
| Prompt | The instruction text Command sends to Claude. |
| Action | A named prompt setup, with defaults and one or more triggers. |
| Trigger | The way content is captured: selected text, screenshot, popup, or voice. |
| Delivery | Where the rendered prompt goes: existing chat, new chat, or background. |
| Destination | Claude: Default, Chat, Cowork, or Code. ChatGPT: Default, Chat, or Codex. |
| Auto-submit | Whether Command presses Return after filling a new chat. |
| Background | A local `claude -p` run with no Claude window. |

## Prompt Model

| Layer | Choices |
|---|---|
| Trigger | Selected text, Screenshot, Popup, Voice |
| Delivery | Existing chat, New chat, Background |
| Destination | Claude: Default, Chat, Cowork, Code. ChatGPT: Default, Chat, Codex. |

`—` means inherit from prompt/action.

Default resolution:

1. Global destination in Shortcuts.
2. Prompt/action delivery and destination.
3. Trigger override.

## Built-In Compose

One shared Compose prompt powers six built-in combinations:

| Combination | Input | Delivery | Default submit |
|---|---|---|---|
| Selected text -> Existing chat | Selected text | Existing chat | No |
| Selected text -> New chat | Selected text | New chat | No |
| Selected text -> New chat + auto-submit | Selected text | New chat | Yes |
| Screenshot -> Existing chat | Screenshot | Existing chat | No |
| Screenshot -> New chat | Screenshot | New chat | No |
| Screenshot -> New chat + auto-submit | Screenshot | New chat | Yes |

Pencil opens Compose editor for shared prompt text and default/per-row auto-submit. Auto-submit is on by default only for the two "New chat + auto-submit" combinations.

## Prompt Variables

| Variable | Meaning |
|---|---|
| `{selection}` | Captured text, typed popup text, spoken text, or selected text. |
| `{context}` | Matching Context rule text. |
| `{source}` | Source app/site line. |
| `{url}` | Source URL when available. |
| `{file}` | Screenshot file path for background delivery. |

If `{selection}` is missing, captured content is appended below prompt.

## Clipboard Picker

| Key | Action |
|---|---|
| Type | Search. |
| Up/Down | Select. |
| Return | Paste. |
| Command-Return | Paste and keep open. |
| Esc | Close. |

## Background Result Contract

Background actions run through `claude -p`.

If final non-empty stdout line is `KEY=value`, Command displays it in notification, Command History, and diagnostic summary.

Example:

```text
TASK_ID=abc123
```

Only final line is parsed. Prose containing `TASK_ID=abc123` does not count. No follow-up action runs from that value yet.

## Import / Export

Open **Settings -> About -> Import / Export**.

| Button | Use |
|---|---|
| Export | Save selected settings sections to JSON. |
| Import | Preview a saved JSON file, then choose per-section handling. |

| Import mode | Result |
|---|---|
| Keep current | Skip section. |
| Merge | Current plus incoming; incoming wins conflicts. |
| Overwrite | Replace section. |

## Local Data

| Area | Location |
|---|---|
| Shortcuts, prompts, context | `~/.claude/state/` |
| Clipboard history | `~/.claude/state/cliphistory/` |
| Dictation data | `~/Library/Application Support/DictationLab/` |
| Command/background history | `~/Library/Application Support/claude-command/` |

Background actions run local Claude CLI. Review prompts and CLI extra args before sharing exports.

## Common Fixes

| Problem | Fix |
|---|---|
| Hotkeys do nothing | Grant Accessibility, then restart Command. |
| Shortcut conflicts | Rebind prompt shortcuts in Shortcuts; rebind dictation shortcuts in Dictation Settings. |
| Screenshot fails | Grant Screen Recording, then restart Command. |
| Dictation fails | Grant Microphone; download model in Dictation Settings. |
| Claude opens wrong mode | Check global destination, action destination, trigger override. |
| To-Do URL not captured | Select no text, use `Claude - To-Do` from Safari, Chrome, Brave, Chromium, or Arc, then check Command History -> Background. |
| Background run fails | Open Command History -> Background, inspect log. |

For permission details and reset commands, see [PERMISSIONS.md](PERMISSIONS.md).

## Help From The App

Open **Settings -> About**:

| Button | Use |
|---|---|
| Help & Documentation | Repository link plus bundled docs buttons. |
| View on GitHub | Opens the project repository. |
| Documentation | Full bundled docs, with GitHub Pages fallback. |
| User Guide / Install Guide / Uninstall | End-to-end setup, first install, and removal. |
| Settings Reference | Tab-by-tab Settings map. |
| Quick Reference | Default shortcuts, prompt variables, common fixes, and local data paths. |
| Troubleshooting | Symptom-first fixes and log paths. |
| Permissions | Permission meanings, optional items, and reset commands. |
| Support | What to include in bug reports, feature requests, and help requests. |
| Security Policy | Private reporting path, supported alpha versions, redaction guidance, and privacy links. |
| Examples / FAQ / Updates / Privacy / Changelog / Alpha Limitations | Examples, common questions, update flow, local data, release notes, and alpha expectations. |
| Icon Treatments / Background Architecture / Release Checklist | Active-state visuals, background-run internals, and maintainer ship gates. |
| Support & Reporting | Diagnostics, public bug/feature routes, and private security reporting. |
| Copy Diagnostic Info | App path, bundle ID, version, minimum macOS, update channel/check status, shortcut binding summary, Set Up status, log tails, recent command summaries, Clipboard History errors, and recent dictation previews. |
| Report a Bug | Prefilled GitHub issue template. |
| Request Feature | Prefilled GitHub feature request template. |
| Private Security Report | GitHub private advisory for vulnerabilities, exposed secrets, private logs, or sensitive diagnostics. |

## Full Docs

- [Install Guide](INSTALL.md)
- [Uninstall](UNINSTALL.md)
- [User Guide](USER_GUIDE.md)
- [Settings Reference](SETTINGS_REFERENCE.md)
- [Updates](UPDATES.md)
- [Permissions](PERMISSIONS.md)
- [Privacy](PRIVACY.md)
- [Troubleshooting](TROUBLESHOOTING.md)
- [Support](SUPPORT.md)
- [Examples](EXAMPLES.md)
- [FAQ](FAQ.md)
- [Changelog](CHANGELOG.md)
- [Alpha Limitations](LIMITATIONS.md)
- [Icon Treatments](ICON_TREATMENTS.md)
- [Background Architecture](BACKGROUND_TRIGGER_INTEGRATION.md)
- [Release Checklist](RELEASE_CHECKLIST.md)
