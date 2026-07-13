# Command Changelog

## 1.2.0-alpha.8

- Added first-class Claude and ChatGPT / Codex provider selection globally, per Custom Action, and per trigger.
- Added ChatGPT destination parity: ChatGPT general chat and workspace-aware Codex, with global, action, and trigger inheritance.
- Preserved legacy `codex` provider keys while adopting current ChatGPT app and Codex coding-product names.
- Routed ChatGPT through the unified app's Quick Chat command and Codex through a workspace-aware `codex://threads/new` deep link.
- Targeted paste and submit keystrokes to the assistant process, fixing delivery when Electron creates a background window without becoming AX-frontmost.
- Fixed Claude Chat/Cowork/Code routing after a zsh-local variable accidentally replaced the worker's executable search path.
- Fixed foreground failures that previously logged success when Codex workspace validation or new-task creation failed.
- Added Codex foreground existing/new-task delivery, configured workspace, screenshots, clipboard sends, dictation, popup, voice, and auto-submit paths.
- Added provider-specific background settings and `codex exec -` delivery with image attachments, safe execution presets, provider-tagged history, retry, diagnostics, and schema-v2 migration.
- Existing installations and provider-less records remain Claude by default; bundle ID and local support paths stay unchanged.

## 1.2.0-alpha.6

Current alpha line. Major changes:

- Prompt-centered Shortcuts UI: compose prompts, custom actions, multiple triggers, delivery, destination, and trigger overrides.
- Compose section groups selected-text and screenshot combinations under one shared prompt.
- Custom Actions support selected text, screenshot, popup, and voice triggers from one prompt.
- Background actions run through local `claude -p` and show results in Command History.
- Command History includes foreground sends plus background runs, logs, retry, retention, and stalled-run recovery.
- Import / Export moved to About with section preview and keep/merge/overwrite choices.
- Dictation got history, corrections, vocabulary, settings, and voice custom action routing.
- Active dictation now uses a compact solid-purple voice-lines menu-bar icon with animated white bars for stronger visibility without the earlier wide badge.
- Copy Diagnostic Info includes app path, bundle ID, update channel/check status, shortcut binding summary, Set Up status, log tails, recent command summaries, Clipboard History errors, and recent dictation previews for faster install/update/support triage.
- About includes View on GitHub, Report a Bug, Request Feature, Security Policy, and Private Security Report routes so repository links, public issues, feature requests, and sensitive reports go to the right place.
- App and repository are now named Command. Release assets use `Command-*.zip`, GitHub Pages lives under `/command/`, and compatibility IDs/paths stay stable so existing alpha permissions and local history continue working.
- Docs site now includes install, uninstall, user guide, settings reference, quick reference, examples, FAQ, alpha limitations, updates, permissions, troubleshooting, privacy, support, security policy, icon treatments, background architecture, release checklist, and 404 fallback.
- App bundle includes offline HTML/CSS/SVG/Markdown docs.
- Release packaging verifies zip shape, bundled docs/README source parity, and required runtime resources; CI runs a release-asset smoke test.

## Defaults In This Alpha

| Built-in combination | Default |
|---|---:|
| Selected text -> Existing chat | Option-F8 |
| Selected text -> New chat | F8 |
| Selected text -> New chat + auto-submit | Unbound |
| Screenshot -> Existing chat | Option-F7 |
| Screenshot -> New chat | F7 |
| Screenshot -> New chat + auto-submit | Unbound |
| Clipboard History | F6 |
| Dictate -> Insert | Home |
| Dictate -> Assistant | Option-Home |

## Alpha Notes

- Structured `KEY=value` results are displayed in notifications and Command History, but do not run follow-up actions yet.
- Background actions use local `claude -p`; file/network/tool access depends on your Claude CLI setup and prompt.
- Some default F-key shortcuts may conflict with macOS keyboard settings or other apps. Rebind prompt shortcuts in Shortcuts, or rebind dictation shortcuts in Dictation Settings.

For current tab-by-tab Settings details, see [SETTINGS_REFERENCE.md](SETTINGS_REFERENCE.md).
