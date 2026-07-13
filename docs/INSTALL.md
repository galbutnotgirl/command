# Command Install Guide

Use this for first-time installs. For updating an existing install, see [UPDATES.md](UPDATES.md).

## Download Alpha

Command requires macOS 14 or later.

1. Open the [latest GitHub Release](https://github.com/galbutnotgirl/command/releases/latest).
2. Download [`ClaudeCommand-1.2.0-alpha.6.zip`](https://github.com/galbutnotgirl/command/releases/download/v1.2.0-alpha.6/ClaudeCommand-1.2.0-alpha.6.zip).
3. Unzip it.
4. Move `ClaudeCommand.app` to `~/Applications`.
5. Control-click `ClaudeCommand.app`, choose **Open**, then confirm **Open**.

If macOS says Command cannot be verified:

1. Control-click `ClaudeCommand.app` in Finder and choose **Open**.
2. Click **Open** in the confirmation dialog.
3. If only **Move to Trash** appears, open **System Settings -> Privacy & Security**, scroll down, click **Open Anyway**, authenticate, then reopen Command.

Terminal fallback:

```bash
xattr -dr com.apple.quarantine ~/Applications/ClaudeCommand.app
```

This warning exists because alpha.6 is not Apple-notarized. Never bypass this warning for an app from an untrusted source.

Binary installs do not require Terminal scripts. Global shortcuts, screenshots, clipboard history, and dictation run from the app. Optional right-click Services are only for source installs that run `./install-quick-action.sh`.

## Existing Alpha Installs

Command was previously named ClaudeCommand. New installers use `Command.app` and remove the old `~/Applications/ClaudeCommand.app` bundle during source installs. The bundle identifier and local support paths stay compatible (`com.claudecommand` and `~/Library/Application Support/claude-command/`) so macOS permissions, shortcuts, history, and exports keep working across the rename.

For permission details, optional items, and reset commands, see [PERMISSIONS.md](PERMISSIONS.md).

## First Run

Open the menu-bar icon, then choose **Settings -> Set Up**.

Grant:

| Permission | Needed for |
|---|---|
| Accessibility | Global shortcuts, copy, paste, submit, and focus restore. |
| Screen Recording | Screenshot triggers. |
| Microphone | Dictation and voice custom actions. |

After granting permissions, restart Command if a required Set Up item still shows red.

## Verify Install

In **Settings -> Set Up**, confirm:

- Accessibility is green.
- Screen Recording is green if you use screenshots.
- Microphone and dictation model are green if you use dictation.
- Clipboard History is running if you use clipboard history.

Then test:

| Test | Expected |
|---|---|
| Select text and press `Option-F8` | Selected text sends to existing Claude session. |
| Press `F8` | New Claude session opens with captured text. |
| Press `F6` | Clipboard History picker opens when enabled. |

If F-keys control brightness, media, or dictation instead of Command, enable standard function keys in macOS Keyboard settings, rebind prompt shortcuts in **Settings -> Shortcuts**, or rebind dictation shortcuts in **Settings -> Dictation Settings**.

## Help After Install

Open **Settings -> About**:

| Button | Use |
|---|---|
| Help & Documentation | Repository link plus bundled docs buttons. |
| View on GitHub | Opens the project repository. |
| Documentation | Opens bundled docs first, GitHub Pages fallback if docs are missing. |
| User Guide / Install Guide / Uninstall | End-to-end setup, first install, and removal. |
| Settings Reference | Tab-by-tab Settings map. |
| Quick Reference | Shortcuts, variables, and common fixes. |
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

## Install From Source

Source install is mainly for local development or testing unreleased changes.
It requires macOS 14 or later plus Xcode command-line tools.

```bash
git clone https://github.com/galbutnotgirl/command
cd command
./build-agent.sh
./install-agent.sh
```

For local development, use:

```bash
./script/build_and_run.sh
```

That script stops any running app, builds `Command.app`, launches the fresh local bundle, pings the app dispatch socket, and checks bundled docs. Use `./script/build_and_run.sh --verify` to confirm runtime readiness.

Optional, if you want the legacy SendHelper keystroke fallback for source testing:

```bash
./build-helper.sh
```

Optional, if you want legacy right-click Services in macOS Services menus:

```bash
./install-quick-action.sh
./set-hotkeys.sh
```

For downloaded app installs, use **Settings -> About -> Copy Diagnostic Info** and review it before sharing. From a repo checkout, maintainers can also run:

```bash
./doctor.sh
```

## Next

- Read [USER_GUIDE.md](USER_GUIDE.md) for prompt setup and custom actions.
- Read [QUICK_REFERENCE.md](QUICK_REFERENCE.md) for shortcuts and common fixes.
- Read [PERMISSIONS.md](PERMISSIONS.md) for macOS permission details and reset commands.
- Read [TROUBLESHOOTING.md](TROUBLESHOOTING.md) if a permission, shortcut, screenshot, or dictation step fails.
