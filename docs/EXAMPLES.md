# Command Examples

These examples show common prompt/action setups. Use them as starting points, then adjust delivery, destination, trigger, and prompt text for your own workflow.

## Review Selected Text In Current Chat

Use this when you are already in a Claude conversation and want to add selected text without opening a new chat.

Settings:

| Field | Value |
|---|---|
| Prompt | Built-in `Add` |
| Trigger | Selected text |
| Delivery | Existing chat |
| Destination | Default |
| Default shortcut | Option-F8 |

Prompt text:

```text
Review this and call out the most important issue first.

{selection}
```

## Start A Fresh Rewrite Thread

Use this when selected text should open a new Claude conversation but not submit automatically.

Settings:

| Field | Value |
|---|---|
| Prompt | Built-in `New` |
| Trigger | Selected text |
| Delivery | New chat |
| Destination | Default or Code |
| Default shortcut | F8 |

Prompt text:

```text
Rewrite this for clarity. Preserve meaning, remove filler, and keep tone direct.

{selection}
```

## Screenshot Design Review

Use this to capture UI and send it to Claude as context.

Settings:

| Field | Value |
|---|---|
| Prompt | Built-in `Screenshot -> New chat` combination or custom action |
| Trigger | Screenshot |
| Delivery | New chat |
| Destination | Chat |
| Default shortcut | F7 |

Prompt text:

```text
Review this interface. Focus on layout, hierarchy, contrast, and what feels confusing.
Return the top five improvements.
```

## Voice Note Into Claude Code

Use this when spoken notes should become instructions in Claude Code.

Settings:

| Field | Value |
|---|---|
| Action name | Voice to Code |
| Trigger | Voice |
| Delivery | New chat |
| Destination | Code |

Prompt text:

```text
Turn this spoken note into a clear implementation brief.
Keep requirements, assumptions, and next steps separate.

{selection}
```

## Background Task Capture

Use this when selected text should run through `claude -p` without opening Claude.

Settings:

| Field | Value |
|---|---|
| Action name | Post To Do |
| Trigger | Selected text or Popup |
| Delivery | Background |
| Destination | Default |
| Skill | Optional |

Prompt text:

```text
Create one task from this input.

Rules:
1. Write a short action-oriented title.
2. Include source context if present.
3. Output only TASK_ID=<id> on the final line.

{selection}
```

The last line follows the background result convention. Command shows `TASK_ID=<id>` in the notification and Command History.

Source-only right-click variant:

| Item | Behavior |
|---|---|
| Service | Claude - To-Do |
| Text selected | Sends selected text to the background action. |
| No text selected in supported browser | Sends current tab URL from Safari, Chrome, Brave, Chromium, or Arc. |
| Result check | Open Command History -> Background. |

## Google Docs Context Rule

Use this when selected text from Google Docs needs document-specific handling.

Settings:

| Field | Value |
|---|---|
| Tab | Context |
| Match type | URL host |
| Pattern | docs.google.com |
| Path prefix | /document/ |
| Display name | Google Docs |

Context text:

```text
This came from Google Docs. Preserve document structure and suggest edits clearly.
```

## Import Settings On A New Mac

Use this when moving Command setup between machines.

On old Mac:

1. Open **Settings -> About -> Import / Export**.
2. Click **Export**.
3. Keep every section checked unless you intentionally want a partial export.

On new Mac:

1. Install Command.
2. Open **Settings -> About -> Import / Export**.
3. Click **Import** and choose the export file.
4. Preview available sections.
5. Choose **Merge** for most sections, or **Overwrite** when you want the file to replace local settings.

## More Detail

- [User Guide](USER_GUIDE.md)
- [Settings Reference](SETTINGS_REFERENCE.md)
- [Quick Reference](QUICK_REFERENCE.md)
- [Background Architecture](BACKGROUND_TRIGGER_INTEGRATION.md)
