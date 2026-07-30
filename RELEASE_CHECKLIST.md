# Command Maintainer Release Checklist

Maintainer-only checklist for cutting an alpha, beta, or stable release. This file is not bundled with Command or published on GitHub Pages.

## Version

1. Decide channel:

| Channel | Tag shape | GitHub Release |
|---|---|---|
| Alpha | `v1.2.0-alpha.8` | Prerelease |
| Beta | `v1.2.0-beta.1` | Prerelease |
| Stable | `v1.2.0` | Release |

2. Update `VERSION`.
3. Confirm shareable docs describe current defaults: [docs/index.html](docs/index.html), [install.html](docs/install.html), [uninstall.html](docs/uninstall.html), [guide.html](docs/guide.html), [settings.html](docs/settings.html), [SETTINGS_REFERENCE.md](docs/SETTINGS_REFERENCE.md), [quick-reference.html](docs/quick-reference.html), [examples.html](docs/examples.html), [faq.html](docs/faq.html), [changelog.html](docs/changelog.html), [limitations.html](docs/limitations.html), [LIMITATIONS.md](docs/LIMITATIONS.md), [updates.html](docs/updates.html), [permissions.html](docs/permissions.html), [PERMISSIONS.md](docs/PERMISSIONS.md), [troubleshooting.html](docs/troubleshooting.html), [privacy.html](docs/privacy.html), [PRIVACY.md](docs/PRIVACY.md), [support.html](docs/support.html), [security.html](docs/security.html), [SECURITY.md](docs/SECURITY.md), [background.html](docs/background.html), and [404.html](docs/404.html).
4. Confirm repo trust files are current: [README.md](README.md), [SUPPORT.md](SUPPORT.md), [SECURITY.md](SECURITY.md), [CONTRIBUTING.md](CONTRIBUTING.md), [.github/ISSUE_TEMPLATE/config.yml](.github/ISSUE_TEMPLATE/config.yml), [.github/ISSUE_TEMPLATE/bug_report.md](.github/ISSUE_TEMPLATE/bug_report.md), [.github/ISSUE_TEMPLATE/feature_request.md](.github/ISSUE_TEMPLATE/feature_request.md), and [.github/pull_request_template.md](.github/pull_request_template.md).

## Preflight

Run:

```bash
cd agent && swift test
cd ../vendor/claude-command-capture && node --test
cd ../.. && ./test/test-shell.sh
./test/test-build-transaction.sh
./test/test-release-transaction.sh
./test/test-install-state.sh
./test/test-uninstall.sh
./test/test-updater-swap.sh
./test/test-restart-app.sh
./test/test-release-policy.sh
python3 ./test/test-regression-attestation.py
./test/test-regression-attestation.sh
./test/test-static-analysis.sh
python3 ./test/test-docs.py
python3 ./test/test-pages.py
python3 ./test/test_string_review.py
./doctor.sh
```

With installed Command running under launchd, run `./test/test-installed-restart.sh` before
`./test/test-installed-runtime.sh`. Restart must return `ok`, replace PID, recover socket,
preserve UserDefaults, and produce no crash report before idle soak begins.

Run `./test/test-installed-hotkeys.sh` before and after restart. Expected and successful Carbon
registration counts must match, event tap must be installed and enabled with Accessibility trust,
and all tagged HID events must reach callback without firing configured actions or replacing PID.

Run `./test/test-installed-dictation.sh` before and after restart. It performs repeated raw
microphone-buffer probes, then drives production trigger and release paths through model
streaming, recorder buffers, stop-tail drain, ASR finish, and clean terminal health. Diagnostic
mode then drives tagged Fn down/up through installed HID event-tap voice dispatch, requires four
live buffers and full cleanup, and runs three consecutive injected-failure/immediate-retry cycles
without restarting. It must keep session IDs increasing, PID stable, and dictation history
unchanged. This installed check does not prove physical-key
dispatch or spoken-content accuracy; manual shortcut checks and cached final-word fixtures cover
those boundaries.

With current Claude and ChatGPT apps running, verify installed assistant contracts without opening or submitting conversations:

```bash
./test/test-assistant-contract.sh
```

This checks registered URL schemes plus bundled resources for current Quick Chat, New Task, New Projectless Task, Claude New Conversation, and Claude Chat/Cowork/Code deep links. It does not drive assistant UI or prove prompt-field focus; those remain manual checks. Any mismatch means provider routing must be reviewed before release.

Optional local packaging check:

```bash
./release.sh --skip-checks
./test/test-release-asset.sh
```

Review `test/regression-contracts.json` for behavior touched by this release. `./release.sh --publish --notarize` requires full gates and runs cached Parakeet final-word fixtures automatically; `--skip-checks` cannot publish.

Full release gates generate signed `regression-gates-attestation.json` after all required
checks pass. Confirm qualified zip contains it and `verify-regression-attestation.sh` accepts
extracted app. Never install direct `build-agent.sh` output or use
`COMMAND_ALLOW_UNQUALIFIED_INSTALL` outside isolated installer tests.

Run `time ./qualify-installed-build.sh` on exact clean release commit no more
than 24 hours before publishing. `release.sh --publish` verifies all ten
installed checks before gates and again before tagging; stale, mismatched,
failed, clean-install, or edited reports stop publication. Dictation lifecycle
and hotkey-input checks run on both sides of qualification's launchd restart.

Run `./test/test-regression-impact.sh` and review `test/regression-impact.json`. Every changed runtime area since latest `v*` tag must include matching automated evidence before release preflight can pass.

That builds `dist/Command-<version>.zip`, writes `dist/Command-<version>.zip.sha256`, and verifies `Command.app` is at the zip top level, the embedded version matches `VERSION`, the bundle identifier is `com.claudecommand`, the minimum macOS metadata is `14.0`, the packaged executable exists and is executable, codesign metadata identifies `com.claudecommand`, every shareable bundled docs asset plus the bundled README is present and byte-for-byte current with source, including `PRIVACY.md` and `SECURITY.md`, required runtime resources (`send-to-claude.sh`, Clipboard History, restart/update helpers, and background vendor core) are present, internal `STATUS.md` is absent, and AppleDouble `._*` metadata files are absent. Those checks match what updater install, restart, shortcut dispatch, Clipboard History, background actions, and About -> Documentation expect.

For manual spot checks, run:

```bash
cd dist
VERSION="$(cat ../VERSION)"
shasum -a 256 -c "Command-<version>.zip.sha256"
unzip -l "Command-<version>.zip" | rg "__MACOSX|\\.DS_Store|com\\.apple\\.quarantine|/\\._"
unzip -p "Command-<version>.zip" Command.app/Contents/Resources/docs/index.html | rg "Command"
```

For the metadata scan, `rg` should return no matches and exit 1. That is the expected clean result.

## Publish

Store notarization credentials once in Keychain using an Apple Developer account:

```bash
xcrun notarytool store-credentials "command-notary" \
  --apple-id "APPLE_ID" \
  --team-id "TEAM_ID" \
  --password "APP_SPECIFIC_PASSWORD"
```

Release from `main` with clean working tree and a `Developer ID Application` certificate:

```bash
SIGN_ID="Developer ID Application: NAME (TEAM_ID)" \
COMMAND_NOTARY_PROFILE="command-notary" \
./release.sh --publish --notarize
```

For custom notes, append them to same release command:

```bash
./release.sh --publish --notarize --notes="Short release notes here."
```

`release.sh` checks embedded version, bundle identifier, and minimum macOS `14.0`; enables hardened runtime and secure timestamp for Developer ID builds; submits zip to Apple; staples ticket to app; validates ticket; rebuilds zip; checks Gatekeeper acceptance; tags release; pushes tag; and creates GitHub Release. Alpha and beta tags are marked prerelease automatically.

Publishing without notarization is blocked by default. `--allow-unnotarized` exists only as an explicit emergency override for alpha versions and leaves users with Gatekeeper warning. Never use override for beta or stable release.

Normal release runs also execute regression-contract audit, `swift test`, `node --test`, shell and transaction suites, install/update/uninstall/restart checks, release policy, static analysis, docs/Pages/string checks, and cached Parakeet final-word fixtures before public packaging. App/core failures, missing regression evidence, background runner failures, install-state regressions, updater failures, restart failures, signing policy regressions, syntax errors, broken docs, stale assets, or dictation-tail regressions stop release. GitHub workflow runs deterministic suite plus packaging smoke. `--skip-checks` is limited to local packaging and CI smoke and cannot publish.

## After Publish

1. Open GitHub Release page.
2. Confirm `Command-<version>.zip` and `Command-<version>.zip.sha256` assets exist.
3. Confirm Pages workflow completed.
4. Confirm GitHub Pages docs open:
   - [Overview](https://galbutnotgirl.github.io/command/)
   - [Install Guide](https://galbutnotgirl.github.io/command/install.html)
   - [Uninstall](https://galbutnotgirl.github.io/command/uninstall.html)
   - [User Guide](https://galbutnotgirl.github.io/command/guide.html)
   - [Settings Reference](https://galbutnotgirl.github.io/command/settings.html)
   - [Quick Reference](https://galbutnotgirl.github.io/command/quick-reference.html)
   - [Examples](https://galbutnotgirl.github.io/command/examples.html)
   - [FAQ](https://galbutnotgirl.github.io/command/faq.html)
   - [Changelog](https://galbutnotgirl.github.io/command/changelog.html)
   - [Alpha Limitations](https://galbutnotgirl.github.io/command/limitations.html)
   - [Updates](https://galbutnotgirl.github.io/command/updates.html)
   - [Permissions](https://galbutnotgirl.github.io/command/permissions.html)
   - [Troubleshooting](https://galbutnotgirl.github.io/command/troubleshooting.html)
   - [Privacy](https://galbutnotgirl.github.io/command/privacy.html)
   - [Support](https://galbutnotgirl.github.io/command/support.html)
   - [Security Policy](https://galbutnotgirl.github.io/command/security.html)
   - [Background Actions](https://galbutnotgirl.github.io/command/background.html)
   - [404 fallback](https://galbutnotgirl.github.io/command/404.html)
5. On the docs home, confirm **Find Your Path** routes common tasks: install/update, configure prompts, write prompt text, use voice, run background actions, and fix/report.
6. On two or three Pages docs, confirm sidebar navigation links user documentation only: Overview, Install Guide, Uninstall, User Guide, Settings Reference, Quick Reference, Examples, FAQ, Changelog, Alpha Limitations, Updates, Permissions, Privacy, Troubleshooting, Support, and Security Policy.
7. Confirm homepage **Download Alpha** and Install Guide download steps point to [latest GitHub Release](https://github.com/galbutnotgirl/command/releases/latest), not the generic releases list.
8. Confirm the canonical GitHub Pages base is [galbutnotgirl.github.io/command](https://galbutnotgirl.github.io/command/) and no public release/docs/repo surface points users to the old `/claude-command/` Pages path.
9. If an old `/claude-command/` Pages project remains online, confirm it is redirect-only to `/command/`, or disable it after checking no shared alpha links still depend on it.
10. Confirm [sitemap.xml](https://galbutnotgirl.github.io/command/sitemap.xml) and [robots.txt](https://galbutnotgirl.github.io/command/robots.txt) load.
11. Confirm Pages workflow still runs docs quality checks before upload and uses scoped Pages permissions plus the GitHub Pages environment.
12. Confirm GitHub repo surface opens: [README](https://github.com/galbutnotgirl/command#readme), [Support](https://github.com/galbutnotgirl/command/blob/main/SUPPORT.md), [Security](https://github.com/galbutnotgirl/command/security/policy), [Contributing](https://github.com/galbutnotgirl/command/blob/main/CONTRIBUTING.md), [Bug report](https://github.com/galbutnotgirl/command/issues/new?template=bug_report.md), [Feature request](https://github.com/galbutnotgirl/command/issues/new?template=feature_request.md), and [Private security report](https://github.com/galbutnotgirl/command/security/advisories/new).
13. Confirm issue chooser routes install, troubleshooting, support, private security report, latest Alpha release, bug reports, and feature requests.
14. Confirm pull request template asks for user impact, docs parity, sensitive-report routing, issue-template/chooser parity, bundled-doc release smoke, release-note/checklist needs, and validation evidence.
15. In installed app, open **Settings -> About -> Check for Updates**.
16. Download update and confirm app relaunches.
17. Open **Settings -> About -> Website** and confirm GitHub Pages opens.
18. Open **Settings -> About -> Docs** and confirm bundled docs open offline. If testing a build without bundled docs, confirm Docs falls back to GitHub Pages.
19. Open **Settings -> About -> GitHub** and confirm project repository opens.
20. Open **Copy Diagnostic Info**, **Report a Bug**, and **Request Feature**. Confirm diagnostics copy and public issue buttons open correct templates.

## Rollback

If release asset is broken:

1. Delete GitHub Release.
2. Delete local and remote tag:

```bash
git tag -d vX.Y.Z
git push origin :refs/tags/vX.Y.Z
```

3. Fix issue.
4. Bump `VERSION` to new patch/prerelease number.
5. Run checklist again.
