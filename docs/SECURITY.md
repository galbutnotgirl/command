# Command Security Policy

Command is a local macOS app that can read selected text, screenshots, clipboard history, dictation text, and background command logs when those workflows are enabled.

## Report A Vulnerability

Do not file public GitHub issues for vulnerabilities, exposed secrets, private logs, or diagnostic output that contains sensitive text.

Use **Security Policy** or GitHub private vulnerability reporting instead:

[Report a private vulnerability](https://github.com/galbutnotgirl/command/security/advisories/new)

Include:

- Command version and macOS version.
- Whether this affects selected text, screenshots, clipboard history, dictation, background actions, import/export, updates, or permissions.
- Minimal repro steps with sensitive content removed.
- Relevant diagnostic lines only after redacting secrets, private text, tokens, file paths, or customer data.

## Supported Versions

Alpha builds are supported through the latest GitHub Release:

[Latest Alpha release](https://github.com/galbutnotgirl/command/releases/latest)

Older alpha builds should be upgraded before filing unless the vulnerability blocks updating.

## Privacy Reference

See [Privacy](PRIVACY.md) for local file locations, diagnostics, clipboard history, dictation data, background logs, and export safety.

For the in-app support buttons, diagnostics, and reporting actions, see [Settings Reference](SETTINGS_REFERENCE.md).
