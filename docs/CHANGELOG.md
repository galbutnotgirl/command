# Command Changelog

## 1.2.0-alpha.8

- Fixed new projectless Codex sessions in current ChatGPT builds by matching the app's `Command-Option-O` shortcut instead of stale `Shift-Command-O` routing.
- Warmed dictation cue audio with separate silent playback so first Purr cue starts at same volume as stop cue after cold launch.
- Added first-class Claude and ChatGPT provider selection globally, per Custom Action, and per trigger, with Codex as a ChatGPT destination.
- Added ChatGPT destination parity: ChatGPT general chat and workspace-aware Codex, with global, action, and trigger inheritance.
- Preserved legacy `codex` provider keys while adopting current ChatGPT app and Codex coding-product names.
- Routed ChatGPT through the unified app's Quick Chat command and Codex through workspace-aware ChatGPT app routing with a native projectless fallback.
- Targeted paste and submit keystrokes to the assistant process, fixing delivery when Electron creates a background window without becoming AX-frontmost.
- Fixed Claude Chat/Cowork/Code routing after a zsh-local variable accidentally replaced the worker's executable search path.
- Fixed foreground failures that previously logged success when Codex workspace validation or new-task creation failed.
- Added Codex foreground existing/new-task delivery, configured workspace, screenshots, clipboard sends, dictation, popup, voice, and auto-submit paths.
- Added provider-specific background settings and `codex exec -` delivery with image attachments, safe execution presets, provider-tagged history, retry, diagnostics, and schema-v2 migration.
- Fresh installations default to ChatGPT with Recent as the destination; existing installations and provider-less records keep their saved assistant. Bundle ID and local support paths stay unchanged.
- Hardened in-app updates: only `Command-*.zip` assets are accepted, extracted app metadata/version/signing identity are verified, replacement is staged, and failed copies or validation restore prior app automatically.
- Fixed update ordering so stable beats beta and beta beats alpha at same version, and highest compatible SemVer is selected instead of newest publish timestamp.
- Added isolated fresh/incremental install tests; fresh profiles now create a missing `~/Library/LaunchAgents` directory while updates preserve onboarding and Clipboard History preferences.
- Added onboarding resume tests so interrupted setup returns to first incomplete permission or opt-in step without skipping required setup.
- Fixed Restart Command and onboarding Quit & Reopen so both return through one launchd-safe
  handoff instead of leaving Command stopped or racing duplicate app instances.

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
- About includes GitHub, Report a Bug, Request Feature, and Docs routes so public links go to the right place.
- App and repository are now named Command. Release assets use `Command-*.zip`, GitHub Pages lives under `/command/`, and compatibility IDs/paths stay stable so existing alpha permissions and local history continue working.
- Docs site now includes install, uninstall, user guide, settings reference, quick reference, examples, FAQ, alpha limitations, updates, permissions, troubleshooting, privacy, support, security policy, icon treatments, background architecture, release checklist, and 404 fallback.
- App bundle includes offline HTML/CSS/SVG/Markdown docs.
- Release packaging verifies zip shape, bundled docs/README source parity, and required runtime resources; CI runs a release-asset smoke test.

## Defaults In This Alpha

| Built-in combination | Default |
|---|---:|
| Selected text -> Existing conversation | F8 |
| Selected text -> New conversation | Command-F8 |
| Selected text -> New conversation + auto-submit | Unbound |
| Screenshot -> Existing conversation | F7 |
| Screenshot -> New conversation | Command-F7 |
| Screenshot -> New conversation + auto-submit | Unbound |
| Clipboard History | F6 |
| Dictate -> Insert | Fn |
| Dictate -> Assistant | Unbound |
| Dictate -> Assistant 2 | Unbound |

## Alpha Notes

- Structured `KEY=value` results are displayed in notifications and Command History, but do not run follow-up actions yet.
- Background actions use local `claude -p`; file/network/tool access depends on your Claude CLI setup and prompt.
- Some default F-key shortcuts may conflict with macOS keyboard settings or other apps. Rebind prompt shortcuts in Shortcuts, or rebind dictation shortcuts in Dictation Settings.

For current tab-by-tab Settings details, see [SETTINGS_REFERENCE.md](SETTINGS_REFERENCE.md).
