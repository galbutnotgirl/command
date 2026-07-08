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

Every background run — regardless of trigger — goes through one path now:

```
Custom Action hotkey/menu/popup/voice              ClaudeCommandCore/ActionModels.swift's
  (any kind: text/screenshot/popup/voice,           CustomAction.kind + isHandoff
   any isHandoff: true)
       │
       ├─ kind == .popup  → CustomActionTextEntryPanel (agent/Handoff.swift) shows a
       │                    floating text box; ⌘⏎ feeds the typed text in as content
       ├─ kind == .voice  → triggerDictation() (main.swift) — same press/hold/double-tap
       │                    state machine as the built-in Dictate actions — then
       │                    DictationOverlay.dispatchCustomAction feeds the transcript in
       ├─ kind == .screenshot → NSPasteboard → PNG directly (no shell round-trip)
       └─ kind == .text   → current selection, falling back to the clipboard
       │
       ▼
  agent/Handoff.swift runCustomHandoff() renders the action's OWN skill + prompt
  template (not the global settings.json's), then submitHandoffPrompt()
       │
       ▼
  node vendor/claude-command-capture/bin/submit-cli.js --retry-prompt
       │
       ▼
  submit-cli.js → resubmitPrompt()  (imported core, unchanged)
       ├─ submissions/<id>.json  (status running → succeeded/failed, + parsed `result`)
       ├─ logs/<id>.log
       └─ claude -p  (prompt on stdin, /<skill> addressed if one's set)
```

`capture-handoff.sh` and `send-to-claude.sh`'s `handoff)` case still exist (the vendor
core's `submitCapture()`/`buildPrompt()` non-retry path they drive is still part of the
documented contract for other callers — see `docs/HANDOFF.md`), but nothing in
ClaudeCommand's own UI calls them anymore; every trigger goes through the `--retry-prompt`
path above instead, even for a first run. There used to be a fixed "Text Handoff" action
built exactly on that older path — it's gone, folded into `kind == .popup` (see below).

### New pieces

- **`vendor/claude-command-capture/bin/submit-cli.js`** — headless entry point wrapping
  `submitCapture()`/`resubmitPrompt()`. Additive; core modules untouched. `--retry-prompt`
  re-runs an already-rendered prompt verbatim — the path every Custom Action handoff uses,
  and what the Retry button re-issues. Prints the submission record as JSON, waits for the
  CLI, exit code mirrors the run. Covered by `test/submit-cli.test.js` alongside the
  imported suite.
- **`ClaudeCommandCore/ActionModels.swift`** — `CustomAction.kind: ActionKind` (`text |
  screenshot | popup | voice`) plus `isHandoff`: any capture method × either delivery mode,
  one model. `actionID` picks a `customvoice(handoff)?:` prefix for voice (needs the
  press/hold trigger machinery, not fire-on-press) and `custom(handoff)?:` for everything
  else — `kind` itself isn't in the ID; dispatch reads it off the loaded record.
- **`agent/Handoff.swift`** — `CustomActionTextEntryPanel` (popup trigger, replaces the old
  fixed `HandoffTextEntryPanel`), `runCustomHandoff()` (renders + submits any handoff-kind
  action), `submitHandoffPrompt()` (shared by that and Retry).
- **`agent/DictationOverlay.swift`** — `dispatchCustomAction(id:text:)`: the third case
  besides paste-at-cursor/paste-to-Claude for a finished transcript — feeds it into a
  voice-kind Custom Action instead.
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

Settings ▸ Shortcuts ▸ Custom Actions ▸ Add. Pick a **Trigger** (Text / Screenshot / Popup /
Voice), turn on **Run as background handoff** if you want it to run silently instead of
pasting into Claude, set a **Skill** if it addresses one, write the **prompt template**, and
bind a hotkey. That's the whole surface — there's no separate config screen per trigger type.

The shared CLI config (command / working directory / extra args / notifications — applies to
every handoff-kind action, not per-action) lives in Menu bar ▸ **Handoff History ▸ Handoff
Settings…**, editing `~/Library/Application Support/claude-command/settings.json`.

## Native UI (agent/Handoff.swift + MenuBar.swift)

- **Handoff Settings window** — the shared CLI command/cwd/extraArgs/notifications every
  handoff-kind Custom Action uses. Reads/patches `settings.json` in place; keys this UI
  doesn't own (`cli.baseArgs`, the ignored Electron `hotkeys` block, `skill`/prompt template
  fields kept for the vendor core's own documented contract) are preserved verbatim.
- **Handoff History menu** (menu bar) — last 8 submission records as
  `✓/✗/… source → /skill — age — result` (replaces the imported tray's Recent Submissions;
  click opens the log), plus Handoff Settings.
- **`CustomActionTextEntryPanel`** — the popup trigger: floating panel, ⌘⏎ submits, Esc
  closes, title matches the action's name. One panel instance, re-shown/re-targeted per
  action rather than stacking a window per popup-kind action.
- **Handoff History tab** (Settings ▸ Handoff History) — every submission, filterable by
  status, with Retry (failed runs), a retention-days stepper (auto-deletes finished runs;
  default 7d, matches Clipboard History), and a "mark as failed" action for a run stuck at
  "running" (the CLI process died without the record ever getting rewritten).

## Custom Handoffs — building a structured background-prompt flow

A Custom Handoff is just a Custom Action (Settings ▸ Shortcuts ▸ Custom Actions) with "Run
as background handoff" turned on: instead of pasting the rendered prompt into the Claude
window, it pipes it to `claude -p` in the background and leaves a submission record — the
same mechanism as a Shortcuts automation that shells out to `claude -p` and posts the result
somewhere, just wired into a hotkey/menu instead of the Shortcuts app.

**Worked example** — replicating a "freeform text → parsed task → POST to an API" flow (the
shape of a typical Shortcuts intake script: Share Sheet or a hotkey hands off text, a shell
script wraps it in a `claude -p` prompt with explicit numbered steps and a strict output
contract, then acts on the result):

1. **Add a Custom Action.** Name it, pick **Text** (selection/clipboard) as the type, turn on
   **Run as background handoff**, set **Skill** if you have one written as a
   `.claude/skills/<name>/SKILL.md` (empty is fine — the prompt below is fully self-contained
   and doesn't need one).
2. **Prompt template** — write the same kind of explicit, numbered contract a hand-rolled
   shell script would build into its `claude -p` call: parse the input, do the work, then
   emit *one* machine-parseable line. `{selection}` is replaced with the captured text (or
   appended below the template if you don't reference it — same convention as every other
   Custom Action):

   ```text
   Extract a task from this input and create it via the tracker API.

   <input>{selection}</input>

   Parse title/notes/due date. POST to https://your-tracker/api/tasks with
   curl (see the API docs in this project for the shape). Then output ONLY:
     TASK_ID=<id>
   or, if it failed:
     ERROR=<reason>
   ```

3. **Permission flags** — a background run has no one at the keyboard to click through a
   permission prompt, so it needs a CLI invocation that doesn't stop and ask. That's
   `cli.extraArgs` in `settings.json` (Menu bar ▸ Handoff History ▸ Handoff Settings…, or
   edit the file directly): add `--dangerously-skip-permissions` and, to scope what it can
   touch instead of trusting it with everything, `--allowedTools "Bash"` (or whatever
   MCP tools the prompt above actually needs, comma-separated). This is a global setting —
   it applies to every handoff (Custom or Text), the same way a real intake script would pin
   its own `claude -p` flags once rather than per-call.
4. **Bind a hotkey** to the Custom Action (same key-binding field every action gets) —
   this replaces whatever gesture/trigger a Shortcuts automation would use.
5. **Check the result** — the app auto-detects the `TASK_ID=`/`ERROR=` contract from step 2:
   whatever the *last non-empty line* of `claude -p`'s output is, if it matches `KEY=value`,
   gets picked up as the submission's `result` — no extra config, it's a convention, not a
   setting. It shows up in three places: the "Claude finished" notification (appended after
   an em dash), the Handoff History row (a small badge under the age line), and the Handoff
   History **menu bar** submenu title (so you can see `TASK_ID=abc123` without opening
   anything). A line buried mid-output doesn't count — only the true last line, same as the
   worked script's own "output ONLY one line" discipline. See `runner.js`'s `extractResult()`
   for the exact rule, and `test/runner.test.js` for its edge cases.

   This is intentionally just a convention, not a plugin system — it doesn't POST anywhere or
   run follow-up actions on your behalf. If you need the app to actually *act* on the parsed
   value (not just show it), that's still a real gap worth designing separately.
