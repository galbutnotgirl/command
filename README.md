# Command

[![Test](https://github.com/galbutnotgirl/command/actions/workflows/test.yml/badge.svg)](https://github.com/galbutnotgirl/command/actions/workflows/test.yml)
[![Pages](https://github.com/galbutnotgirl/command/actions/workflows/pages.yml/badge.svg)](https://github.com/galbutnotgirl/command/actions/workflows/pages.yml)
[![Latest Release](https://img.shields.io/github/v/release/galbutnotgirl/command?include_prereleases&label=latest%20release)](https://github.com/galbutnotgirl/command/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

Native macOS menu-bar shortcuts for Claude, ChatGPT, and Codex. Capture selected text, screenshots, typed popups, or voice; choose whether each prompt goes to an existing session, a new session, or a background CLI run.

Documentation site: [galbutnotgirl.github.io/command](https://galbutnotgirl.github.io/command/)

Alpha downloads: [Latest GitHub Release](https://github.com/galbutnotgirl/command/releases/latest)

Docs:

| Doc | Link |
|---|---|
| Install Guide | [docs/INSTALL.md](docs/INSTALL.md) |
| Uninstall | [docs/UNINSTALL.md](docs/UNINSTALL.md) |
| User Guide | [docs/USER_GUIDE.md](docs/USER_GUIDE.md) |
| Settings Reference | [docs/SETTINGS_REFERENCE.md](docs/SETTINGS_REFERENCE.md) |
| Quick Reference | [docs/QUICK_REFERENCE.md](docs/QUICK_REFERENCE.md) |
| Examples | [docs/EXAMPLES.md](docs/EXAMPLES.md) |
| FAQ | [docs/FAQ.md](docs/FAQ.md) |
| Changelog | [docs/CHANGELOG.md](docs/CHANGELOG.md) |
| Alpha Limitations | [docs/LIMITATIONS.md](docs/LIMITATIONS.md) |
| Updates | [docs/UPDATES.md](docs/UPDATES.md) |
| Permissions | [docs/PERMISSIONS.md](docs/PERMISSIONS.md) |
| Privacy | [docs/PRIVACY.md](docs/PRIVACY.md) |
| Troubleshooting | [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) |
| Icon Treatments | [docs/ICON_TREATMENTS.md](docs/ICON_TREATMENTS.md) |
| Background Architecture | [docs/BACKGROUND_TRIGGER_INTEGRATION.md](docs/BACKGROUND_TRIGGER_INTEGRATION.md) |
| Release Checklist | [docs/RELEASE_CHECKLIST.md](docs/RELEASE_CHECKLIST.md) |
| Support, bugs, and feature requests | [SUPPORT.md](SUPPORT.md) |
| Security reports | [SECURITY.md](SECURITY.md) |
| Private security report | [GitHub private advisory](https://github.com/galbutnotgirl/command/security/advisories/new) |
| Contributing | [CONTRIBUTING.md](CONTRIBUTING.md) |

Repo: [github.com/galbutnotgirl/command](https://github.com/galbutnotgirl/command)

## What It Does

Command is organized around prompts:

- Built-in Compose: one shared prompt with selected-text and screenshot combinations.
- Assistants: Claude or ChatGPT / Codex globally, per Custom Action, or per trigger.
- ChatGPT destinations: Chat for general chat, Codex for workspace coding. Stored `codex` provider keys remain backward compatible.
- Custom actions: one prompt, many triggers.
- Triggers: selected text, screenshot, popup, voice.
- Delivery: existing chat, new chat, background.
- Destination: default, Chat, Cowork, Code.
- History: foreground sends and background runs.
- Local tools: clipboard history, on-device dictation, import/export, troubleshooting.

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

Change prompt/action shortcuts in **Settings -> Shortcuts**. Dictation shortcuts live in **Settings -> Dictation Settings**.

## Install

Quick start for most users:

1. Download the latest `Command-*.zip` from the [latest GitHub Release](https://github.com/galbutnotgirl/command/releases/latest).
2. Unzip and launch `Command.app`. Choose **Move to Applications** when prompted, or move it to `~/Applications` manually.
3. Open **Settings -> Set Up**, grant required permissions, then verify **Accessibility** is green.

For alpha builds, use the [latest GitHub Release](https://github.com/galbutnotgirl/command/releases/latest) and download the latest `Command-*.zip`. The matching `.zip.sha256` file is available for checksum verification when kept beside the matching zip. See [docs/INSTALL.md](docs/INSTALL.md) for first launch, permissions, setup checks, and source install.

Binary installs do not require Terminal scripts. Global shortcuts, screenshots, clipboard history, and dictation run from the app.

Command requires macOS 14+. Source install is mainly for local development or testing unreleased changes, and requires Xcode command-line tools.

```bash
git clone https://github.com/galbutnotgirl/command
cd command
./build-agent.sh
./install-agent.sh
```

Optional, if you want the legacy SendHelper keystroke fallback for source testing:

```bash
./build-helper.sh
```

Optional, if you want legacy right-click Services in macOS Services menus:

```bash
./install-quick-action.sh
./set-hotkeys.sh
```

Those source-only Services include **Claude - To-Do**. It sends selected text when text is highlighted; otherwise Safari, Chrome, Brave, Chromium, and Arc send the current tab URL as a background action. Check **Command History -> Background** for captured source, result, and log.

Then open **Command menu-bar icon -> Settings -> Set Up** and grant:

- Accessibility: required for hotkeys, copy, paste, focus restore.
- Screen Recording: required for screenshot triggers.
- Microphone: required for dictation.

See [docs/PERMISSIONS.md](docs/PERMISSIONS.md) for what each permission does, what is optional, and reset commands if macOS permission state gets stuck.

For downloaded app installs, use **Settings -> About -> Copy Diagnostic Info** and review it before sharing. From a repo checkout, maintainers can also run:

```bash
./doctor.sh
```

## Settings Map

Full tab-by-tab details: [docs/SETTINGS_REFERENCE.md](docs/SETTINGS_REFERENCE.md).

| Tab | Use |
|---|---|
| Set Up | Permissions and live component checks. |
| Shortcuts | Default assistant, Claude destination or Codex workspace, built-in prompts, custom actions, trigger overrides. |
| Context | App/site context rules and prompt preview. |
| Command History | Foreground sends, background runs, retries, retention. |
| Clipboard History | Picker shortcut, retention, theme, clear controls. |
| Dictation History | Raw/processed dictation records and correction suggestions. |
| Corrections | Misheard -> correct rules. |
| Vocabulary | Proper nouns, product terms, filler words. |
| Dictation Settings | Model, microphone, shortcuts, processing, sounds. |
| About | Updates, launch options, import/export, docs, bug report, feature request. |

## Import / Export

Open **Settings -> About -> Import / Export**.

Export can include shortcuts, prompt settings, context rules, dictation vocabulary, background settings, and app preferences. Import previews available sections and lets you keep current, merge, or overwrite each section.

## Updates

Open **Settings -> About** to pick Alpha or Beta, check for updates, and install available releases. Stable is visible but unavailable until the first stable release exists. In-app update checks GitHub Releases for the newest accepted channel, downloads the attached `Command-*.zip`, replaces `~/Applications/Command.app`, clears quarantine, and restarts. For manual alpha installs, backup/export before updating, failed updates, and rollback, see [docs/UPDATES.md](docs/UPDATES.md).

## Background Actions

Background delivery renders prompt and sends it to selected local CLI:

```bash
claude -p       # Claude
codex exec -    # Codex, prompt on stdin
```

No assistant window opens. Results and logs appear in **Command History -> Background**. Codex screenshots use `-i <file>`. Claude skills render as `/skill`; Codex skills render as `$skill`. If last non-empty output line is `KEY=value`, Command displays it in notifications and history.

## Privacy

- Clipboard history stays local.
- Dictation runs on-device.
- App settings and histories are local files.
- Command itself does not upload history.
- Background actions use selected local Claude or Codex CLI; ChatGPT foreground actions never silently replace Codex background execution.

See [docs/USER_GUIDE.md](docs/USER_GUIDE.md#privacy-and-local-files) for exact local file locations.

## Uninstall

See [docs/UNINSTALL.md](docs/UNINSTALL.md) for Quick Action, LaunchAgent, legacy clipboard watcher, local data, logs, and app removal steps.

## Build, Test, Release

For local development, use:

```bash
./script/build_and_run.sh
```

It stops any running `Command`, builds `Command.app`, launches the fresh local bundle, pings the app dispatch socket, and checks bundled docs. Use `./script/build_and_run.sh --verify` when you need runtime confirmation.

```bash
cd agent && swift test
cd ../vendor/claude-command-capture && node --test
cd ../.. && ./test/test-shell.sh
python3 ./test/test-docs.py
./release.sh --skip-checks
./test/test-release-asset.sh
./build-agent.sh
./install-agent.sh
```

Release:

```bash
./release.sh --skip-checks  # local package smoke: zip shape, docs/README parity, runtime resources
./release.sh --publish      # tests, package, tag, push tag, create GitHub Release
```

## License

[MIT](LICENSE)
