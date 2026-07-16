# Command Support

Use this when filing a bug, requesting a feature, or asking for help.

## Fast Path

1. Open **Settings -> Set Up** and confirm required items are OK. Optional items only need to be OK if you use that workflow.
2. Open **Settings -> About -> Copy Diagnostic Info**. It includes app path, bundle ID, version, minimum macOS, update channel/check status, shortcut binding summary, Set Up permission/component status, recent log tails, recent command summaries, Clipboard History errors, and the last three dictation raw/processed previews.
3. For bugs, open **Settings -> About -> Report a Bug**.
4. For non-bug requests, open **Settings -> About -> Request Feature**.
5. For vulnerabilities, exposed secrets, private logs, or sensitive diagnostic output, open **Security Policy** instead of a public issue.
6. Review copied diagnostics for sensitive log or recent-text content, then paste only relevant lines into the GitHub issue or private advisory.

If the report involves a vulnerability, exposed secret, private log, or sensitive diagnostic output, do not use a public issue. Use [Security Policy](SECURITY.md) instead.

## Feature Requests

Use **Settings -> About -> Request Feature** or the [Feature request template](https://github.com/galbutnotgirl/command/issues/new?template=feature_request.md) for non-bug workflow, trigger, destination, docs, or release improvements.

Good feature requests include the workflow, trigger type, delivery mode, destination, auto-submit preference, current workaround, and whether the request needs Settings UI, menu-bar behavior, docs/examples, import/export support, or release-note coverage.

## What To Include

| Field | Example |
|---|---|
| Version, bundle ID, minimum macOS, and app path | Version, `Bundle ID`, `Minimum macOS`, and `App path` shown in **Copy Diagnostic Info**. |
| macOS | `15.5` |
| Trigger | Selected text, Screenshot, Popup, Voice, Dictation, Clipboard History, Background |
| Expected result | What should have happened. |
| Actual result | What happened instead. |
| Repro steps | Exact shortcut/action and app where it happened. |

## Workflow Details

Add the detail that matches the failure:

| Workflow | Include |
|---|---|
| Shortcut / trigger | Whether the row is enabled and bound in **Settings -> Shortcuts** or **Dictation Settings**, and whether macOS or another app already uses the shortcut. |
| Dictation / Voice | Whether **Dictation History** raw text or processed text lost words; whether it was press-and-hold or locked recording. |
| Screenshot | Whether Screen Recording is green in **Set Up**; whether selection capture or window capture failed. |
| Clipboard History | Whether `~/.claude/logs/clipwatch.err` has recent errors; source app copied from. |
| Background action | Failed run status, parsed result if shown, and relevant log from Command History. |
| Claude - To-Do URL capture | Whether text was highlighted, which browser was frontmost, current tab URL if safe to share, captured source/result in **Command History -> Background**. |
| Update | Update channel, target version, and whether manual install from [Install Guide](INSTALL.md) worked. |

## Logs

| Log | Purpose |
|---|---|
| `~/Library/Logs/claude-command.log` | Shortcut actions and paste/open flow. |
| `~/.claude/logs/command-agent.err` | App dispatch, hotkey, and startup errors. |
| `~/.claude/logs/clipwatch.err` | Clipboard History errors. |
| `~/.claude/logs/attribution.log` | Clipboard/source attribution. |
| `~/Library/Application Support/claude-command/logs/` | Background run logs. |

## Before Filing

Binary install checks:

- Restart Command.
- Open **Settings -> Set Up** and confirm required items are OK; optional items only matter for workflows you use.
- Open **Settings -> About -> Copy Diagnostic Info** and review copied diagnostics before sharing. It includes app path, bundle ID, minimum macOS, update-check status, and shortcut binding summary; background run summaries include status/result/error/log path; full background log text still comes from **Command History**.

From a repo checkout, maintainers can also run:

```bash
./doctor.sh
python3 ./test/test-docs.py
./test/test-shell.sh
```

`./doctor.sh` checks source and installed app metadata, including version, bundle ID, minimum macOS `14.0`, bundled docs, executable presence, LaunchAgent Program path/socket, Clipboard History, Background runner, and dictation state files.

If a specific shortcut fails, include whether that shortcut is shown in **Settings -> Shortcuts** and whether another app already uses it.

For dictation tail-cutoff bugs, say whether the missing words are absent from **raw text**, absent only from **processed text**, or present in both but missing from the sent command. That separates recording/model timing from text cleanup and dispatch.

If an update failed, include update channel, target version, and whether manual install from [Install Guide](INSTALL.md) worked.

For vulnerabilities, exposed secrets, private logs, or sensitive diagnostic output, use **Security Policy** or [Security Policy](SECURITY.md) instead of a public issue.

For tab-by-tab Settings help, see [Settings Reference](SETTINGS_REFERENCE.md). For symptom-first fixes before filing, see [Troubleshooting](TROUBLESHOOTING.md).
