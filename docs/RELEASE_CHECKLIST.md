# Command Release Checklist

Use this before cutting an alpha, beta, or stable release.

## Version

1. Decide channel:

| Channel | Tag shape | GitHub Release |
|---|---|---|
| Alpha | `v1.2.0-alpha.8` | Prerelease |
| Beta | `v1.2.0-beta.1` | Prerelease |
| Stable | `v1.2.0` | Release |

2. Update `VERSION`.
3. Confirm shareable docs describe current defaults: [docs/index.html](index.html), [install.html](install.html), [uninstall.html](uninstall.html), [guide.html](guide.html), [settings.html](settings.html), [SETTINGS_REFERENCE.md](SETTINGS_REFERENCE.md), [quick-reference.html](quick-reference.html), [examples.html](examples.html), [faq.html](faq.html), [changelog.html](changelog.html), [limitations.html](limitations.html), [LIMITATIONS.md](LIMITATIONS.md), [updates.html](updates.html), [permissions.html](permissions.html), [PERMISSIONS.md](PERMISSIONS.md), [troubleshooting.html](troubleshooting.html), [privacy.html](privacy.html), [PRIVACY.md](PRIVACY.md), [support.html](support.html), [security.html](security.html), [SECURITY.md](SECURITY.md), [icon-treatments.html](icon-treatments.html), [background.html](background.html), [release.html](release.html), and [404.html](404.html).
4. Confirm repo trust files are current: [README.md](../README.md), [SUPPORT.md](../SUPPORT.md), [SECURITY.md](../SECURITY.md), [CONTRIBUTING.md](../CONTRIBUTING.md), [.github/ISSUE_TEMPLATE/config.yml](../.github/ISSUE_TEMPLATE/config.yml), [.github/ISSUE_TEMPLATE/bug_report.md](../.github/ISSUE_TEMPLATE/bug_report.md), [.github/ISSUE_TEMPLATE/feature_request.md](../.github/ISSUE_TEMPLATE/feature_request.md), and [.github/pull_request_template.md](../.github/pull_request_template.md).

## Preflight

Run:

```bash
cd agent && swift test
cd ../vendor/claude-command-capture && node --test
cd ../.. && ./test/test-shell.sh
python3 ./test/test-docs.py
./doctor.sh
```

Optional local packaging check:

```bash
./release.sh --skip-checks
./test/test-release-asset.sh
```

That builds `dist/Command-<version>.zip`, writes `dist/Command-<version>.zip.sha256`, and verifies `Command.app` is at the zip top level, the embedded version matches `VERSION`, the bundle identifier is `com.claudecommand`, the minimum macOS metadata is `14.0`, the packaged executable exists and is executable, codesign metadata identifies `com.claudecommand`, every shareable bundled docs asset plus the bundled README is present and byte-for-byte current with source, including `PRIVACY.md` and `SECURITY.md`, required runtime resources (`send-to-claude.sh`, Clipboard History, and background vendor core) are present, internal `STATUS.md` is absent, and AppleDouble `._*` metadata files are absent. Those checks match what updater install, shortcut dispatch, Clipboard History, background actions, and About -> Documentation expect.

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

Release from `main` with clean working tree:

```bash
./release.sh --publish
```

For custom notes:

```bash
./release.sh --publish --notes="Short release notes here."
```

`release.sh` builds app, checks embedded version, bundle identifier, and minimum macOS `14.0`, creates zip, tags release, pushes tag, and creates GitHub Release. Alpha and beta tags are marked prerelease automatically.

Normal release runs also execute `swift test`, `node --test`, `./test/test-shell.sh`, and `python3 ./test/test-docs.py` before packaging, so app/core test failures, background runner failures, script regressions, broken docs links, metadata, rendered HTML structure, heading parity, shared CSS, local media assets, sitemap drift, docs-home coverage drift, README docs-table drift, Settings sidebar drift, About docs-button drift, stale bundled docs, or missing bundled-doc guards stop the release. The GitHub test workflow runs the same unit/docs suite plus `./release.sh --skip-checks` and `./test/test-release-asset.sh` as a packaging smoke test on macOS. `--skip-checks` is only for local one-off packaging and CI packaging smoke tests.

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
   - [Icon Treatments](https://galbutnotgirl.github.io/command/icon-treatments.html)
   - [Background Architecture](https://galbutnotgirl.github.io/command/background.html)
   - [Release Checklist](https://galbutnotgirl.github.io/command/release.html)
   - [404 fallback](https://galbutnotgirl.github.io/command/404.html)
5. On the docs home, confirm **Find Your Path** routes common tasks: install/update, configure prompts, write prompt text, use voice, run background actions, and fix/report.
6. On two or three Pages docs, confirm sidebar navigation links the full docs set: Overview, Install, Uninstall, User Guide, Settings Reference, Quick Reference, Examples, FAQ, Changelog, Alpha Limitations, Updates, Permissions, Privacy, Troubleshooting, Support, Security Policy, Icon Treatments, Background Architecture, and Release Checklist.
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
17. Open **Settings -> About -> View on GitHub** and confirm the project repository opens.
18. Open each **Settings -> About** support action: **Copy Diagnostic Info**, **Report a Bug**, **Request Feature**, and **Private Security Report**. Confirm diagnostics copy, public issue buttons open the right templates, and Private Security Report opens GitHub private advisory creation.
19. Open each **Settings -> About** docs button: **Documentation**, **User Guide**, **Install Guide**, **Uninstall**, **Settings Reference**, **Quick Reference**, **Troubleshooting**, **Permissions**, **Support**, **Security Policy**, **Examples**, **FAQ**, **Updates**, **Privacy**, **Changelog**, **Alpha Limitations**, **Icon Treatments**, **Background Architecture**, and **Release Checklist**. Confirm bundled docs load offline.
20. If testing a build without bundled docs, confirm those About docs buttons fall back to GitHub Pages, not raw Markdown.

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
