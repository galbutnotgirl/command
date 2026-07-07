# Claude Command

Global macOS hotkeys for the **Claude Code desktop app**. Select text or an image in any app, press a key, and it lands in Claude — no window switching, no copy-paste dance. Plus a searchable clipboard-history picker, screenshot→Claude, and voice dictation.

A menu-bar agent (SwiftUI/AppKit). One Accessibility grant powers everything.

> **Repo:** https://github.com/galbutnotgirl/claude-command

---

## Actions

**Text** — work on the current selection (right-click Quick Action or a global hotkey):

| Action | Default key | What it does |
|--------|-------------|--------------|
| **Go** | ⌘F8 | New Claude session, auto-submits, **returns focus** to where you were. |
| **Comment** | F8 | New session pre-filled; **stays foreground** so you add a note and send. |
| **Add** | ⌥F8 | Pastes the selection into the **already-open** Claude chat. |
| **To-Do** | ⌘F6 | Native popup → routes the note to `~/.claude/hooks/intake.sh` if you provide one. No Claude chat. |

**Screenshot / no-input** — hotkey-driven, no selection needed:

| Action | Default key | What it does |
|--------|-------------|--------------|
| **Screenshot Go** | ⌘F7 | Capture (drag an area, or **Space** to pick a window) → new session → auto-submits. |
| **Screenshot Comment** | F7 | Same capture → new session → you add a note. |
| **Screenshot Add** | ⌥F7 | Same capture → pastes into the already-open Claude chat. |
| **Clipboard History** | F6 | Floating picker — type to search, ↑/↓ select, ⏎ paste, ⌘⏎ paste + stay open, Esc. |

**Skill handoff (background trigger)** — unbound by default; bind in Settings → Shortcuts. No Claude window: the capture is rendered into a prompt addressed to your configured Claude Code skill and piped to `claude -p` in the background, leaving durable submission records for downstream apps ([contract](vendor/claude-command-capture/docs/HANDOFF.md), [integration notes](docs/BACKGROUND_TRIGGER_INTEGRATION.md)):

| Action | What it does |
|--------|--------------|
| **Skill Handoff** | Selection (or fresh clipboard) → background `claude -p /<skill>` run. |
| **Screenshot Handoff** | Region capture → PNG on disk → background run; the prompt names the file. |
| **Text Handoff** | Floating entry window (⌘⏎ submits, Esc closes) → background run. |

Configure the skill, CLI command/working directory, and prompt templates in **menu bar ▸ Handoffs ▸ Handoff Settings…** (stored at `~/Library/Application Support/claude-command/settings.json`). The **Handoffs** menu also shows recent runs (✓/✗/…) — click one to open its log. Requires Node.js 20+ on PATH.

**Dictation** — unbound by default; bind in Settings → Shortcuts:

| Action | What it does |
|--------|--------------|
| **Dictate** | Speak to insert text at your cursor. Live transcription, auto-stops on silence. |
| **Dictate → Claude** | Speak to open a new Claude session with your words. |

During any screenshot the Claude window is hidden first so it's never in the shot, then restored. Images ride the clipboard and are **pasted** into Claude (no temp files).

---

## Install

Requires **macOS 13+** and the Xcode command-line tools (`xcode-select --install`).

```bash
git clone https://github.com/galbutnotgirl/claude-command
cd claude-command
./build-agent.sh           # build + sign ClaudeCommand.app (hotkeys, socket, picker, window)
./build-helper.sh          # build + sign SendHelper.app (keystroke synthesis)
./install-clipwatch.sh     # clipboard-history daemon (login + now)
./install-agent.sh         # start the agent (login + now)
./install-quick-action.sh  # right-click Quick Actions
./set-hotkeys.sh           # write default global hotkeys + restart the agent
```

Then open the menu-bar **⌘ icon → Settings → Set Up** — it walks you through the grants and validates each live:

1. **Accessibility** — the one grant that drives every hotkey, keystroke, and paste. Required.
2. **Screen Recording** — needed for the screenshot actions.
3. **Microphone + Speech Recognition** — only if you use dictation. Optional.

Prefer the terminal? `./doctor.sh` validates the install (builds, services, socket, hotkeys, Quick Actions) and prints fix hints.

### Code signing

By default the build is **ad-hoc signed**, which works locally but means macOS re-prompts for Accessibility after each rebuild. To make grants stick, create a self-signed code-signing certificate in Keychain Access and build with it:

```bash
SIGN_ID="My Cert Name" ./build-agent.sh
SIGN_ID="My Cert Name" ./build-helper.sh
```

---

## Settings window

- **Set Up** — live permission + component checks.
- **Shortcuts** — see and rebind every global hotkey (click the key badge, press a combo; Delete clears). Applies instantly. Toggle any action on/off.
- **History** — clipboard retention (set the number of days) + **Clear** buttons (last 15 min / hour / 24 h / everything), each with a confirm.
- **Dictation** — mic/speech permissions, silence timeout, optional whisper-cli refinement, and a custom-vocabulary list for proper nouns and jargon.
- **Troubleshooting** — auto-scanning diagnostics.
- **About** — version, launch-at-login, menu-bar-icon toggle, and **Check for Updates**.

---

## Updates

Built-in. **Settings → About → Check for Updates** queries this repo's GitHub Releases, downloads the newest build on your channel, installs it in place, and restarts. No third-party framework.

**Channels** — pick one in Settings → About:

| Channel | Gets | Release tag |
|---------|------|-------------|
| **Alpha** | everything (alpha + beta + stable) | `v1.2.0-alpha.1` |
| **Beta** | beta + stable | `v1.2.0-beta.1` |
| **Prod** | stable only | `v1.2.0` |

A channel always sees its own builds plus everything more stable, so a tester lands on the newest build they opted into. Prod is disabled in the UI until the first stable release is cut (flip `PROD_AVAILABLE` in `agent/Updater.swift`).

Releasing a new build (maintainers):

```bash
# bump VERSION first (e.g. 1.2.0-alpha.1), then:
./release.sh                                   # builds + zips dist/ClaudeCommand-<version>.zip
gh release create "v$(cat VERSION)" dist/ClaudeCommand-*.zip --prerelease --generate-notes
```

Tag with `-alpha`/`-beta` (and `--prerelease`) for those channels; a plain `vX.Y.Z` is a stable/prod release.

---

## Privacy & security

- **No network calls of its own.** It opens `claude://` URLs and runs the local `claude` CLI — nothing else phones home.
- **Clipboard history is local and owner-only** (`~/.claude/state/cliphistory/`, `0600`), pruned on a schedule (default 7 days, configurable in Settings → History).
- **Secrets are skipped.** Copies from Keychain, 1Password, Wallet, Passwords, or any concealed/transient pasteboard item are never stored or sent. Edit `BLOCK_BUNDLES` in `clipwatch.py` to add more.
- The keystroke socket (`~/.claude/state/command-agent.sock`) is `0600` — only your user can drive it.

---

## Components

| Piece | Role |
|-------|------|
| `ClaudeCommand.app` (`agent/*.swift`, `build-agent.sh`) | The always-on core: global hotkeys, keystroke socket, clipboard picker, dictation, settings window, updater. |
| `send-to-claude.sh` | The worker — one script, dispatched by `ACTION`. |
| `capture-handoff.sh` + `vendor/claude-command-capture/` | Background skill handoff: native glue + the vendored Electron-free capture→`claude -p` pipeline. |
| `SendHelper.app` (`helper/SendHelper.swift`, `build-helper.sh`) | Signed helper for ⌘C / ⌘V / Return via CGEvent — one Accessibility grant, no per-app prompts. |
| `clipwatch.py` + `install-clipwatch.sh` | Background daemon: timestamps copies, blocks secrets, keeps the capped history. |
| `install-quick-action.sh` / `uninstall-quick-action.sh` | Generate / remove the right-click Quick Actions. |
| `set-hotkeys.sh` | Write the default global hotkey config. |
| `doctor.sh` | Validate the install from the terminal. |
| `release.sh` | Build + package a release zip. |

---

## Config (env vars for `send-to-claude.sh`)

| Var | Default | Effect |
|-----|---------|--------|
| `ACTION` | `comment` | `go`/`comment`/`add`/`todo`/`shotgo`/`shotcomment`/`shotadd`/`shotfullgo`/`cliphistory` (set per Quick Action). |
| `CLIP_TTL` | `60` | Max age (s) of the existing clipboard to use as a fallback. |
| `INCLUDE_CONTEXT` | `1` | Prepend `[from: app — URL]` context to the payload. |
| `DRY_RUN` | `0` | Print the action instead of running it. |

---

## Logs

- `~/Library/Logs/claude-command.log` — worker
- `~/.claude/logs/claude-command-bg.log` — background actions
- `~/.claude/logs/clipwatch.{out,err}` — daemon

## Uninstall

```bash
./uninstall-quick-action.sh
launchctl bootout gui/$(id -u)/com.claudecommand;           rm ~/Library/LaunchAgents/com.claudecommand.plist
launchctl bootout gui/$(id -u)/com.claudecommand.clipwatch; rm ~/Library/LaunchAgents/com.claudecommand.clipwatch.plist
```

---

## License

[MIT](LICENSE) © 2026 Gal Oppenheimer
