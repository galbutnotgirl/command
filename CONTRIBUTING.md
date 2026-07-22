# Contributing

Command is a native macOS menu-bar app. Most users should install from the latest release; this guide is for local development, docs changes, and release checks.

## Local Setup

Requirements:

- macOS 14+.
- Xcode command-line tools.
- Node.js 20+ for the background capture core.
- GitHub CLI only when publishing a release.

Build and run the local app:

```bash
./script/build_and_run.sh
```

Verify the app process, dispatch socket, and bundled docs:

```bash
./script/build_and_run.sh --verify
```

## Test Matrix

Run the same checks CI and release preflight use:

```bash
cd agent && swift test
cd ../vendor/claude-command-capture && node --test
cd ../.. && ./test/test-shell.sh
./test/test-install-state.sh
./test/test-updater-swap.sh
./test/test-restart-app.sh
./test/test-release-policy.sh
./test/test-static-analysis.sh
python3 ./test/test-docs.py
python3 ./test/test-pages.py
python3 ./test/test_string_review.py
./release.sh --skip-checks
./test/test-release-asset.sh
```

`test/test-docs.py` validates README/docs links, rendered HTML structure, metadata, sitemap, bundled-doc asset lists, release docs coverage, About docs buttons, Markdown/HTML parity, local media assets, and repo support/security policy links.

For provider-routing changes, launch current Claude and ChatGPT builds and run `./test/test-assistant-contract.sh`. It reads their URL schemes and native menu shortcuts without creating or submitting conversations.

Use [TEST_PLAN.md](TEST_PLAN.md) for full automated and manual release gates.

## Docs Changes

User docs live in `docs/*.md` and rendered `docs/*.html`. Keep paired Markdown and HTML pages aligned when changing user-facing guidance.

Update these when behavior changes:

- [README.md](README.md) for repo overview and quick install.
- [docs/USER_GUIDE.md](docs/USER_GUIDE.md) and [docs/guide.html](docs/guide.html) for full user flow.
- [docs/SETTINGS_REFERENCE.md](docs/SETTINGS_REFERENCE.md) and [docs/settings.html](docs/settings.html) for Settings tabs.
- [docs/QUICK_REFERENCE.md](docs/QUICK_REFERENCE.md) and [docs/quick-reference.html](docs/quick-reference.html) for shortcut defaults.
- [docs/SUPPORT.md](docs/SUPPORT.md), [SUPPORT.md](SUPPORT.md), and [SECURITY.md](SECURITY.md) for support and sensitive-report routing.
- [docs/RELEASE_CHECKLIST.md](docs/RELEASE_CHECKLIST.md) and [docs/release.html](docs/release.html) for ship checks.

Run `python3 ./test/test-docs.py` before committing docs.

## App Changes

- Prefer SwiftPM tests in `agent`.
- Keep user-facing labels aligned with docs and tests.
- Do not reintroduce old public labels like `Claude Command`, `Handoff History`, or `Templates` for prompt text.
- Preserve local-first privacy behavior: clipboard history, dictation history, command history, diagnostics, and exports stay local unless the user shares them.
- Route vulnerabilities, exposed secrets, private logs, and sensitive diagnostics through [SECURITY.md](SECURITY.md), not public issues.
- Use the pull request template checklist for user impact, docs parity, release-note needs, and validation evidence.

## Release

Use [docs/RELEASE_CHECKLIST.md](docs/RELEASE_CHECKLIST.md). Normal release runs execute Swift, Node, shell, and docs tests before packaging.

```bash
./release.sh --skip-checks
./release.sh --publish
```

--skip-checks is only for local one-off packaging and CI packaging smoke tests. Use `./release.sh --publish` for real releases from a clean `main` branch.
