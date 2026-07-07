# Background Trigger integration

How the imported capture-and-handoff app (`vendor/claude-command-capture/`, from
`galbutnotgirl/claudecommand` branch `claude/cli-submission-skill-app-cvciqf`) is folded into
Claude Command.

## Stack decision

**This repo is not Electron.** Claude Command is a native macOS menu-bar agent:

- `agent/*.swift` — SwiftUI/AppKit agent: Carbon global hotkeys, keystroke socket, clipboard
  picker, dictation, settings window, updater.
- `send-to-claude.sh` — zsh worker dispatched per hotkey with `ACTION=<id>`; owns selection
  capture (auto-⌘C via SendHelper/agent socket), clipboard-freshness fallback, screenshot
  pre-step (`screencapture`), and source-app context enrichment.
- `clipwatch.py`, `SendHelper.app` — support daemons.

The imported app is an Electron tray app, **but** its core pipeline
(`src/settings.js`, `src/prompt.js`, `src/runner.js`, `src/submit.js`, `src/submissions.js`,
`src/paths.js`) is plain Node with a full `node:test` suite and zero runtime dependencies.

**Decision: keep the Electron-free core + handoff contract verbatim; rework the capture layer
natively.** The native agent already has a better capture layer than the Electron one
(one Accessibility grant, signed helper, clipboard attribution/secret blocking, freshness
TTL). What it lacked is exactly what the imported core provides: render a skill-addressed
prompt from a template and hand it to `claude -p` in the background, leaving a durable
submission record for a downstream app.

Dropped (Electron-specific, superseded by native equivalents):

| Imported piece | Native equivalent |
|---|---|
| `src/main.js` (tray, globalShortcut) | `agent/main.swift` Carbon hotkeys + menu bar |
| `src/capture/*` (osascript ⌘C, screencapture, clipboard) | `send-to-claude.sh` capture stages |
| `src/windows/*`, `renderer/*` (settings/text-entry UIs) | native Handoff Settings window + text-entry panel (`agent/Handoff.swift`) |

Kept unchanged: `src/{settings,prompt,runner,submit,submissions,paths}.js`, `test/`,
`docs/HANDOFF.md` (the contract), `examples/skills/triage-capture/`.

## Architecture

```
hotkey (handoff / shothandoff)                     agent/Actions.swift catalog
  └─ CommandAgent → runWorker ACTION=…             (generic dispatch, no Swift changes)
       └─ send-to-claude.sh
            ├─ existing capture stages: selection auto-⌘C, clipboard fallback,
            │  screenshot pre-step, secret blocklist, source context
            └─ handoff) case → capture-handoff.sh          (new, repo root)
                 ├─ image on clipboard → PNG into <data>/captures/
                 └─ node vendor/claude-command-capture/bin/submit-cli.js
                      └─ loadSettings → submitCapture()    (imported core, unchanged)
                           ├─ captures/<id>.txt|png
                           ├─ submissions/<id>.json  (status running → succeeded/failed)
                           ├─ logs/<id>.log
                           └─ claude -p  (prompt on stdin, /<skill> addressed)
```

### New pieces

- **`vendor/claude-command-capture/bin/submit-cli.js`** — headless entry point wrapping
  `submitCapture()`. Additive; core modules untouched. Text on stdin or `--file` for images.
  Prints the submission record as JSON, waits for the CLI, exit code mirrors the run.
  `--init-settings` scaffolds `settings.json`; `--print-settings` shows the effective config.
  Covered by `test/submit-cli.test.js` alongside the imported suite.
- **`capture-handoff.sh`** — native glue. Receives captured text on stdin (or an image on the
  clipboard with `HANDOFF_IMG=1`), plus `HANDOFF_SOURCE` / `HANDOFF_CONTEXT` env from the
  worker. Dumps clipboard PNGs via AppKit/python3, locates node, invokes the shim.
- **`send-to-claude.sh`** — two small additions: `shothandoff` joins the screenshot pre-step
  (without hiding/refocusing the Claude window — this action never touches it), and a
  `handoff)` delivery case that execs `capture-handoff.sh`. All existing actions untouched.
- **`agent/Actions.swift`** — two catalog entries, `handoff` ("Skill Handoff") and
  `shothandoff` ("Screenshot Handoff"), unbound by default. The Shortcuts settings tab,
  hotkey registration, and worker dispatch all derive from the catalog, so no other Swift
  changes are needed.
- **`build-agent.sh`** — bundles `capture-handoff.sh` + the vendor core (src/bin only) into
  the app's Resources so installed builds work outside the repo checkout.

### Data layout & contract

Unchanged from `vendor/claude-command-capture/docs/HANDOFF.md`. Base directory on macOS:
`~/Library/Application Support/claude-command` (same path Electron's `app.getPath('userData')`
would use, so any downstream app written against the contract works identically). Override
with `CLAUDE_CAPTURE_HOME`.

Settings (`settings.json` in the base dir) keep the imported schema: `skill`,
`promptTemplate`, `imagePromptTemplate`, `cli.{command,baseArgs,extraArgs,cwd}`,
`notifications`. The Electron `hotkeys` field is retained in the schema but ignored — hotkeys
are owned by the native agent (`~/.claude/state/command-hotkeys.json`).

## Source mapping nuance

The worker resolves "selection, else fresh clipboard" in one stage, so a text handoff is
recorded with `source: "selection"` even when the clipboard fallback supplied the text;
screenshots record `source: "screenshot"`. The contract's `text` / `clipboard` values remain
valid inputs to `submit-cli.js` for other callers.

## Using it

1. Rebuild + restart the agent (`./build-agent.sh`, `./install-agent.sh`).
2. Menu bar ▸ **Handoffs ▸ Handoff Settings…** — set the skill name and the CLI working
   directory (the project that owns the skill). Equivalent: edit
   `~/Library/Application Support/claude-command/settings.json` or run
   `node vendor/claude-command-capture/bin/submit-cli.js --init-settings`.
3. Bind **Skill Handoff** / **Screenshot Handoff** / **Text Handoff** in Settings →
   Shortcuts.
4. Select text (or shoot a region, or type into the entry window) → notification "Submitted
   to Claude" → record in `submissions/`, output in `logs/<id>.log`, last runs under
   menu bar ▸ Handoffs.

## Native UI (agent/Handoff.swift + MenuBar.swift)

Ports of the imported Electron UI surfaces, kept out of the WIP-heavy Settings window:

- **Handoff Settings window** — skill, CLI command / cwd / extra args, both prompt
  templates, notifications toggle. Reads/patches `settings.json` in place; keys this UI
  doesn't own (`cli.baseArgs`, the ignored Electron `hotkeys` block, future fields) are
  preserved verbatim.
- **Handoffs menu** (menu bar) — last 8 submission records as `✓/✗/… source → /skill — age`
  (replaces the imported tray's Recent Submissions; click opens the log), plus Text Entry
  and Handoff Settings.
- **Text-entry panel** (replaces imported `renderer/text-entry`) — floating panel, ⌘⏎
  submits with `source: "text"`, Esc closes. Also reachable via the **Text Handoff**
  hotkey action.
