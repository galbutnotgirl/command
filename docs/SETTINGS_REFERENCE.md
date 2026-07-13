# Command Settings Reference

Use this as a map of every Settings tab and where each workflow lives.

## Sidebar

Set Up, About, Clipboard History, Shortcut Settings, Context, Background, History, Settings, Vocabulary, Corrections, History.

## Set Up

Use **Set Up** first after install or update.

| Area | What it checks |
|---|---|
| Permissions | Accessibility, Screen Recording, and Microphone state. |
| Components | App bundle, launch service, app dispatch socket, Clipboard History, shortcut config, optional Quick Actions, and Background runner. |
| Actions | Re-check current state, restart Command, open relevant macOS privacy panes. |

Required items should be green before using global shortcuts. Optional items only matter for workflows you use: Screen Recording for screenshots, Microphone for dictation or voice triggers, Clipboard History for picker/history, and Quick Actions for source installs that still use macOS Services.

## Shortcut Settings

Use **Shortcut Settings** for prompt-centered commands.

| Control | Purpose |
|---|---|
| Default assistant | Top-level Claude or ChatGPT / Codex fallback. |
| Default ChatGPT destination | Chat for general chat or Codex for workspace coding. |
| Claude destination | Claude-only fallback destination: Chat, Cowork, or Code. |
| Codex workspace | Workspace used for new Codex sessions and background runs. |
| Compose | Shared built-in prompt for selected-text and screenshot combinations: existing chat, new chat, or new chat with auto-submit. |
| Custom Actions | User-defined prompt groups with selected text, screenshot, popup, or voice triggers. |
| Trigger rows | Per-trigger key binding plus optional delivery, destination, and auto-submit override. |

Inheritance rule: `—` means no override. Trigger settings win over action defaults. Action defaults win over global destination.

## Context

Use **Context** to add app/site-specific source instructions to prompts.

| Control | Purpose |
|---|---|
| Preview as | Shows how current context rules affect a sample source. |
| Context rules | Match app name, bundle ID, URL host, and optional path prefix. |
| Display name | Replaces noisy browser names in `[from: ...]` source lines. |
| Rule text | Adds source-specific instruction text. Use `{url}` when the source URL should appear in prompt text. |

Use path prefixes for shared hosts like `docs.google.com`: split Google Docs, Sheets, and Slides into separate rules.

## Command History

Use **Command History** to inspect what Command sent.

| Section | Includes |
|---|---|
| Foreground | Existing-chat and new-chat sends. |
| Background | `claude -p` and `codex exec -` runs, provider, status, result line, logs, retry, and mark-failed controls. |

Retention defaults to seven days. Changing command retention also aligns background-run retention.

## Clipboard History

Use **Clipboard History** to configure the picker.

| Control | Purpose |
|---|---|
| Shortcut | Opens searchable clipboard picker. |
| Retention | How long local clipboard history is kept. Default is seven days. |
| Theme | Picker appearance. |
| Clear controls | Remove recent or all clipboard history. |

Clipboard History skips known password apps and secret-looking values.

## Dictation

Dictation has four tabs.

| Tab | Purpose |
|---|---|
| History | Raw and processed transcripts, audio playback, and suggested corrections. |
| Corrections | Misheard phrase replacement rules. |
| Vocabulary | Proper nouns, product names, filler words, and terms the model should preserve. |
| Dictation Settings | Microphone access, model status, dictation shortcuts, processing, and sounds. |

Voice custom actions are configured in **Shortcuts**. Built-in dictation shortcuts live in **Dictation Settings**.

## About

Use **About** for release, help, and portability workflows.

| Control | Purpose |
|---|---|
| Update channel | Alpha or Beta today; Stable is visible but unavailable until the first stable release exists. |
| Check for Updates | Finds releases allowed by selected channel. |
| Launch at login | Creates or toggles the Command launch service for startup. Downloaded app installs do not need Terminal scripts. |
| Show in Menu Bar | Shows or hides the status item. |
| Show Dock icon | Switches between menu-bar-only and Dock-visible app behavior. |
| Import / Export | Move shortcuts, prompt settings, context rules, dictation vocabulary, Background settings, and app preferences. Exports default to `command-export.json`. |
| Help & Documentation | Repository link plus bundled docs buttons. |
| View on GitHub | Opens the project repository. |
| Documentation / User Guide / Install Guide / Uninstall | Main help, end-to-end setup, first install, and removal. |
| Settings Reference / Quick Reference / Troubleshooting / Permissions / Support / Security Policy | Tab map, shortcut cheat sheet, symptom fixes, permission help, bug-report guidance, feature-request guidance, and private-report guidance. |
| Examples / FAQ / Updates / Privacy / Changelog / Alpha Limitations | Workflow examples, common questions, update flow, local data, release notes, and alpha expectations. |
| Icon Treatments / Background Architecture / Release Checklist | Active-state visuals, background-run internals, and maintainer ship gates. |
| Support & Reporting | Diagnostics, public bug/feature routes, and private security reporting. |
| Copy Diagnostic Info | Copies app path, bundle ID, version, minimum macOS, update channel/check status, shortcut binding summary, Set Up status, log tails, recent command summaries, Clipboard History errors, and recent dictation previews. |
| Report a Bug | Opens GitHub issue template with key diagnostic fields prefilled. |
| Request Feature | Opens GitHub feature request template for non-bug workflow, trigger, destination, docs, or release improvements. |
| Private Security Report | Opens GitHub private advisory for vulnerabilities, exposed secrets, private logs, or sensitive diagnostics. |

### Import / Export Sections

| Section | Includes |
|---|---|
| Shortcuts and prompts | Built-in shortcut bindings, custom actions, trigger rows, and built-in compose auto-submit settings. |
| Prompt text and context rules | Built-in prompt text and Context rules. |
| Dictation vocabulary | Corrections, vocabulary terms, and filler words. |
| Background settings | Separate Claude/Codex commands, working directories, extra args, safe Codex execution preset, tests, and notifications. |
| App preferences | Default assistant, Claude destination, Codex workspace, retention days, and dictation sounds. |

Import modes:

| Mode | Result |
|---|---|
| Keep current | Skip section. |
| Merge | Keep current items; incoming items win matching keys. |
| Overwrite | Replace current section with imported section. |

Review copied diagnostics before sharing because log tails, recent command summaries, and recent dictation previews can include sensitive text.

## Related Docs

- [Install Guide](INSTALL.md)
- [User Guide](USER_GUIDE.md)
- [Quick Reference](QUICK_REFERENCE.md)
- [Permissions](PERMISSIONS.md)
- [Troubleshooting](TROUBLESHOOTING.md)
