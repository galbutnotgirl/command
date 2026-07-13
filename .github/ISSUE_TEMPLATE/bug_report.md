---
name: Bug report
about: Report a Command problem
title: "Bug: "
labels: bug
assignees: ""
---

## Version

Command:
Bundle ID:
App path:
macOS:
Update channel:

Before filing, check [Support](https://galbutnotgirl.github.io/command/support.html) and [Troubleshooting](https://galbutnotgirl.github.io/command/troubleshooting.html). If this is install/update related, also check [Install Guide](https://galbutnotgirl.github.io/command/install.html).

## Trigger / workflow

- [ ] Selected text
- [ ] Screenshot
- [ ] Popup
- [ ] Voice
- [ ] Dictation
- [ ] Clipboard History
- [ ] Background action
- [ ] Import / Export
- [ ] Update / install

Shortcut:
Shortcut row enabled and bound in Settings:
Another app or macOS already uses that shortcut:
Source app:
For Claude - To-Do URL capture: was text highlighted?
For Claude - To-Do URL capture: browser and current tab URL, if safe to share:
Action or built-in command name:
Default assistant:
Destination or workspace:
Action/trigger delivery, destination, and auto-submit overrides, if relevant:
Target update version, if relevant:

## What happened?


## What did you expect?


## Steps to reproduce

1.

## Diagnostics

In Command, open **Settings -> About -> Copy Diagnostic Info**. Review copied diagnostics for sensitive log or recent-text content, then paste relevant lines here.

Do not use this public issue for vulnerabilities, exposed secrets, private logs, or sensitive diagnostic output. Use [Security Policy](https://galbutnotgirl.github.io/command/security.html) or [private vulnerability reporting](https://github.com/galbutnotgirl/command/security/advisories/new) instead.

If this involves dictation or voice, also include whether **Dictation History** raw text or processed text lost the words, and whether recording was press-and-hold or locked.

If this involves a shortcut or custom trigger, Copy Diagnostic Info includes current built-in and custom trigger binding summary. If this involves a background action, include failed run status, parsed result if shown, and relevant log text from **Command History**. Copy Diagnostic Info includes recent run status/result/error/log path; full background log text still comes from **Command History** when needed.

Useful log paths:

- Shortcut actions: `~/Library/Logs/claude-command.log`
- App dispatch, hotkey, and startup errors: `~/.claude/logs/command-agent.err`
- Clipboard History errors: `~/.claude/logs/clipwatch.err`
- Clipboard source attribution: `~/.claude/logs/attribution.log`
- Background run logs: `~/Library/Application Support/claude-command/logs/`

## Notes / screenshots
