# ClaudeCommand

A background capture utility for the Claude Code CLI. Hit a global hotkey (or use the tray
menu) to grab **typed text**, the **clipboard**, the **currently highlighted selection**, or a
**screenshot region** — ClaudeCommand renders a prompt from your settings-defined template and
hands it to `claude -p` in the background, addressed to the **skill** you configured.

This app deliberately owns only *capture + handoff*. The skill that processes the capture (and
any app that runs after the handoff) lives elsewhere — see [docs/HANDOFF.md](docs/HANDOFF.md)
for the contract and [`examples/skills/triage-capture`](examples/skills/triage-capture/SKILL.md)
for a starter skill.

```
┌─────────────┐   hotkey / tray    ┌──────────────────┐   stdin prompt    ┌────────────────┐
│  You        │ ─────────────────▶ │  ClaudeCommand    │ ────────────────▶ │  claude -p     │
│  (any app)  │  text · clipboard  │  render template  │   /your-skill …   │  runs skill    │
└─────────────┘  selection · shot  │  write submission │                   └───────┬────────┘
                                   └──────────────────┘                            │
                                        submissions/<id>.json  ◀───────────────────┘
                                        (downstream app picks up from here)
```

## Requirements

- Node.js 20+ and npm
- [Claude Code CLI](https://code.claude.com/docs) installed and authenticated (`claude` on PATH,
  or set an absolute path in Settings)
- macOS, Linux (X11 for selection capture), or Windows

## Install & run

```sh
npm install
npm start
```

The app lives in the menu bar / system tray (no dock icon, no main window). On first launch the
Settings window opens so you can name the skill that should process captures.

## Capture sources & default hotkeys

| Source | Default hotkey | How it works |
| --- | --- | --- |
| Text entry | `Cmd/Ctrl+Alt+T` | Small always-on-top window; Enter submits, Esc cancels |
| Clipboard | `Cmd/Ctrl+Alt+V` | Reads clipboard text, or a clipboard image saved as PNG |
| Highlighted selection | `Cmd/Ctrl+Alt+H` | Simulates the OS copy shortcut in the focused app, reads the clipboard, then restores it |
| Screenshot | `Cmd/Ctrl+Alt+S` | Interactive region capture saved as PNG |

Hotkeys use [Electron accelerator syntax](https://www.electronjs.org/docs/latest/api/accelerator)
and are editable in Settings; leave one blank to disable it.

## Settings

Open **Settings…** from the tray menu. Stored as JSON at the app's user-data directory
(`~/Library/Application Support/claude-command/settings.json` on macOS).

- **Skill name** — invoked as `/<skill>` at the top of the prompt. The skill's implementation
  lives in the Claude Code project the CLI runs in (its `.claude/skills/`), not in this app.
- **Prompt templates** — separate templates for text and image captures. Placeholders:
  `{skillInvocation}` (`/<skill>` or empty), `{skill}`, `{source}` (`text` | `clipboard` |
  `selection` | `screenshot`), `{timestamp}`, `{content}` (captured text), `{file}` (path to a
  captured image).
- **CLI command / working directory / extra args** — the working directory decides which
  project's skills are available. Add e.g. `--permission-mode` / `acceptEdits` (one arg per
  line) if your skill needs to write files without prompting. The **Test CLI** button runs
  `<command> --version` to confirm the CLI is reachable.
- **Notifications** — toggle submit/finish notifications.

The prompt is always piped to the CLI's **stdin**, never passed as an argument, so captures of
any size or content are safe from shell-escaping issues.

## Platform permissions

- **macOS** — *Accessibility* (System Settings → Privacy & Security) is required for selection
  capture (simulated ⌘C via System Events); *Screen Recording* is required for screenshots.
  You'll be prompted the first time each is used. Grant them to the app that runs ClaudeCommand
  (Electron during development).
- **Linux** — selection capture needs `xdotool` (X11); screenshots use the first available of
  `gnome-screenshot`, `spectacle`, `scrot`, `maim`.
- **Windows** — screenshots open the Snipping Tool overlay and read the result from the
  clipboard; selection capture uses `SendKeys`.

## Data layout

Everything lives under the app's user-data directory:

```
captures/     <id>.txt / <uuid>.png   — persisted capture content
submissions/  <id>.json               — one record per handoff (see docs/HANDOFF.md)
logs/         <id>.log                — CLI stdout/stderr per submission
settings.json
```

The tray menu's **Recent Submissions** shows the last runs (✓ succeeded, ✗ failed, … running);
clicking one opens its log.

## Development

```sh
npm test          # unit tests for the Electron-free core (settings, prompt, runner, pipeline)
npm run gen-icons # regenerate tray icons (no image deps — writes PNGs from scratch)
```

Layout: `src/` main-process code — capture layer in `src/capture/`, windows in `src/windows/`,
and an Electron-free core (`settings.js`, `prompt.js`, `runner.js`, `submit.js`,
`submissions.js`, `paths.js`) that is fully covered by `test/`. `renderer/` holds the two small
UIs (text entry, settings).

## What this app is *not*

It does not implement the skill, watch for results, or act on Claude's output. That's the
downstream app's job — it consumes the submission records described in
[docs/HANDOFF.md](docs/HANDOFF.md).
