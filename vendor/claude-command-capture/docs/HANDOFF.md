# Handoff contract

ClaudeCommand's job ends at the handoff: capture → prompt → `claude -p`. Everything after that
belongs to (a) the **skill** named in Settings, and (b) any **downstream app** that consumes the
artifacts described here. This document is the interface between the three.

## 1. The CLI invocation

For every capture, ClaudeCommand runs (in the background, from the configured working
directory):

```sh
<cli.command> -p [<cli.extraArgs>...]   # prompt piped via stdin
```

The prompt is rendered from the settings template. With the defaults and a skill named
`triage-capture`, a selection capture produces:

```
/triage-capture

Source: selection
Captured at: 2026-07-02T21:00:00.000Z

<the highlighted text>
```

Key points for skill authors:

- The skill is addressed as a slash command on the first line, so the CLI resolves it from the
  **working directory's** Claude Code project (`.claude/skills/<name>/SKILL.md`) or the user's
  `~/.claude/skills/`. Point ClaudeCommand's working directory at the project that owns the
  skill.
- `Source:` is one of `text`, `clipboard`, `selection`, `screenshot`.
- Image captures don't inline the image; the prompt names an absolute PNG path and asks the
  skill to `Read` it:

  ```
  A captured image was saved to: /path/to/captures/<uuid>.png
  Read that file to view the capture.
  ```

- The run is non-interactive (`-p`). If the skill needs to write files or run commands without
  permission prompts, add the appropriate flags (e.g. `--permission-mode acceptEdits`) as extra
  args in ClaudeCommand's settings.

## 2. Submission records (for the downstream app)

Every handoff writes durable artifacts under ClaudeCommand's user-data directory
(`app.getPath('userData')`, e.g. `~/Library/Application Support/claude-command` on macOS):

```
captures/<id>.txt        text captures, persisted verbatim
captures/<uuid>.png      clipboard-image / screenshot captures
submissions/<id>.json    one record per handoff (the thing to watch)
logs/<id>.log            full CLI stdout/stderr for the run
```

A downstream app should **watch `submissions/`** (fs events or polling). Record schema:

```jsonc
{
  "id": "6f0c…",                        // uuid, matches captures/<id>.txt and logs/<id>.log
  "createdAt": "2026-07-02T21:00:00.000Z",
  "source": "selection",                // text | clipboard | selection | screenshot
  "kind": "text",                       // text | image
  "skill": "triage-capture",            // skill name without the slash, or null
  "prompt": "/triage-capture\n…",       // exact prompt piped to the CLI
  "contentFile": "/…/captures/6f0c….txt", // captured payload (txt or png)
  "logFile": "/…/logs/6f0c….log",       // CLI output
  "status": "running",                  // running | succeeded | failed
  "exitCode": null,                     // set when finished
  "finishedAt": null,                   // ISO timestamp when finished
  "error": null                         // message when status = failed
}
```

Lifecycle: the record is written with `status: "running"` **before** the CLI starts, and
atomically rewritten (`.tmp` + rename) with `succeeded`/`failed` when it exits. So a downstream
app can either:

- react to *completions* — act when `status` flips and read `logFile` for Claude's output, or
- react to *submissions* — treat the record itself as a work item and ignore the CLI result.

Records are plain files; the downstream app may move/delete them once consumed if it owns the
queue, or track processed ids if it doesn't.

## 3. Recommended pattern for the skill ↔ downstream app boundary

Keep the skill thin: have it normalize the capture and write its result somewhere the
downstream app owns (a directory, a database, an API call). The skill defines *what a capture
means*; the downstream app defines *what happens next*. ClaudeCommand never needs to change
when either evolves — only the settings (skill name / template / extra args) do.

See [`examples/skills/triage-capture`](../examples/skills/triage-capture/SKILL.md) for a
starter skill implementing this pattern.
