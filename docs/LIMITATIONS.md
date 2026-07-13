# Command Alpha Limitations

Use this before trying or sharing an alpha build. These are current expectations, not hidden failures.

## Alpha Expectations

- Alpha builds can change shortcuts, Settings layout, storage format, and import/export sections.
- Export settings before updating if a workflow matters.
- Use the latest Alpha release before reporting a bug unless the update path itself is broken.
- New chat + auto-submit combinations are unbound by default because they submit immediately and restore focus.
- F6/F7/F8 may control macOS features unless standard function keys are enabled. Rebind shortcuts in **Settings -> Shortcuts** and **Settings -> Dictation Settings** when needed.

## Permissions

- Accessibility is required for global shortcuts, copy/paste, and focus restore.
- Screen Recording is only required for screenshot triggers.
- Microphone is only required for dictation and voice triggers.
- Quick Actions are optional source-install Services; global shortcuts do not need them.

See [PERMISSIONS.md](PERMISSIONS.md).

## Dictation And Voice

Dictation runs on-device, but finalization timing still matters. If final words are missing:

1. Release the key after the last word.
2. Open **Dictation History**.
3. Compare raw text, processed text, and the sent command.
4. Report whether words are missing from raw text, only processed text, or only dispatch.

That separates recording/model timing from text cleanup and paste/dispatch.

## Background Actions

Background actions run local `claude -p`. Command does not control Claude CLI account, network, tool, or file access behavior.

Structured `KEY=value` output is displayed in notifications and Command History. It does not run follow-up actions yet.

See [BACKGROUND_TRIGGER_INTEGRATION.md](BACKGROUND_TRIGGER_INTEGRATION.md) for maintainer details.

## Updates

Alpha, Beta, and Stable channels are visible in Settings. Stable stays unavailable until a stable release exists.

If update install fails, use [INSTALL.md](INSTALL.md) for manual reinstall and [UPDATES.md](UPDATES.md) for rollback.

## Reporting

Use [SUPPORT.md](SUPPORT.md) for normal bugs. Include Copy Diagnostic Info only after reviewing it for sensitive content.

Use [Security Policy](SECURITY.md) for vulnerabilities, exposed secrets, private logs, or sensitive diagnostics.

For tab-by-tab Settings details, see [SETTINGS_REFERENCE.md](SETTINGS_REFERENCE.md).
