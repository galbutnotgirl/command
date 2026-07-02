---
name: triage-capture
description: Process a capture handed off by ClaudeCommand — classify it, summarize it, and write a normalized result file for the downstream app to pick up.
---

# Triage a ClaudeCommand capture

You received a capture submitted in the background by ClaudeCommand. The message contains a
`Source:` line (`text`, `clipboard`, `selection`, or `screenshot`), a capture timestamp, and
either the captured text inline or an absolute path to a captured PNG.

This skill is a **starter template** — copy it into the `.claude/skills/` directory of the
project that ClaudeCommand's working directory points at, and adapt the steps and output
location to whatever your downstream app consumes.

## Steps

1. If the capture is an image, Read the PNG at the path given in the message and describe its
   contents before proceeding.
2. Classify the capture into one of: `todo`, `question`, `reference`, `code`, `other`.
3. Write a summary of at most three sentences.
4. Write the normalized result as JSON to `./claude-command-inbox/<timestamp>.json` (create the
   directory if needed) with this shape:

   ```json
   {
     "receivedAt": "<capture timestamp from the message>",
     "source": "<source from the message>",
     "category": "<classification>",
     "summary": "<your summary>",
     "content": "<captured text, or the image path>"
   }
   ```

5. Reply with a single line: the category followed by the summary. This ends up in
   ClaudeCommand's per-submission log.

## Notes

- Run non-interactively; do not ask clarifying questions.
- The `claude-command-inbox/` directory is the handoff point to the downstream app — it watches
  that directory and runs whatever comes next. Keep the JSON shape stable.
