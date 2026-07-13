#!/bin/zsh
# test/test-release-asset.sh — validate a local Command release zip.
#
# Usage:
#   ./test/test-release-asset.sh
#   ./test/test-release-asset.sh dist/Command-1.2.0-alpha.6.zip
#
# Default path is dist/Command-$(cat VERSION).zip.
emulate -L zsh
set -uo pipefail

DIR="${0:A:h:h}"
VERSION="$(tr -d ' \t\n' < "${DIR}/VERSION")"
ZIP="${1:-${DIR}/dist/Command-${VERSION}.zip}"
SHA256="${ZIP}.sha256"
NAME="${ZIP:t}"
FAIL=0
EXTRACT_DIR=""

cleanup() {
  [ -n "$EXTRACT_DIR" ] && rm -rf "$EXTRACT_DIR"
}
trap cleanup EXIT

fail() {
  print -r -- "FAIL: $*"
  FAIL=1
}

[ -f "$ZIP" ] || { fail "missing zip: $ZIP"; exit 1; }
[ -f "$SHA256" ] || fail "missing checksum: $SHA256"

if [ -f "$SHA256" ]; then
  (cd "${ZIP:h}" && shasum -a 256 -c "${SHA256:t}") >/dev/null || fail "checksum verification failed"
  grep -Eq "^[0-9a-f]{64}  ${NAME}$" "$SHA256" || fail "checksum file malformed"
fi

ZIP_LIST="$(unzip -Z1 "$ZIP" 2>/dev/null)" || { fail "could not list zip"; exit 1; }
FIRST_ENTRY="$(print -r -- "$ZIP_LIST" | head -1)"
case "$FIRST_ENTRY" in
  Command.app/*|Command.app/) ;;
  *) fail "zip does not start with Command.app top-level entry (saw: ${FIRST_ENTRY:-empty})" ;;
esac

if print -r -- "$ZIP_LIST" | grep -Eq '(^|/)(\._|__MACOSX(/|$)|\.DS_Store$|com\.apple\.quarantine$)'; then
  fail "zip contains metadata junk (__MACOSX, .DS_Store, quarantine, or AppleDouble)"
fi

if print -r -- "$ZIP_LIST" | grep -qx "Command.app/Contents/Resources/docs/STATUS.md"; then
  fail "zip contains internal docs/STATUS.md"
fi

for required_doc in 404.html index.html install.html uninstall.html guide.html settings.html quick-reference.html examples.html faq.html changelog.html limitations.html updates.html permissions.html troubleshooting.html privacy.html support.html security.html icon-treatments.html background.html release.html site.css robots.txt sitemap.xml INSTALL.md UNINSTALL.md USER_GUIDE.md SETTINGS_REFERENCE.md QUICK_REFERENCE.md EXAMPLES.md FAQ.md CHANGELOG.md LIMITATIONS.md UPDATES.md PERMISSIONS.md TROUBLESHOOTING.md PRIVACY.md SUPPORT.md SECURITY.md ICON_TREATMENTS.md BACKGROUND_TRIGGER_INTEGRATION.md RELEASE_CHECKLIST.md icon-treatment-bold-animated.svg icon-treatment-green-voice.svg icon-treatment-options-animated.svg icon-treatment-options.svg; do
  print -r -- "$ZIP_LIST" | grep -qx "Command.app/Contents/Resources/docs/${required_doc}" \
    || fail "missing bundled docs asset: docs/${required_doc}"
  if [ -f "${DIR}/docs/${required_doc}" ]; then
    cmp -s "${DIR}/docs/${required_doc}" <(unzip -p "$ZIP" "Command.app/Contents/Resources/docs/${required_doc}" 2>/dev/null) \
      || fail "bundled docs asset is stale: docs/${required_doc}"
  fi
done

if ! python3 - "$ZIP" <<'PY'
import re
import sys
import zipfile

zip_path = sys.argv[1]
terms = [
    "Add/New/Go behavior",
    "Go behavior",
    "docs page for missing links",
    "Handoff History",
    "Claude Command",
    "Templates",
    "Clipboard daemon",
]
patterns = [
    re.compile(r"<title>([^<]+)</title>"),
    re.compile(r"""<meta\s+name=["']description["']\s+content=["']([^"']+)["']>"""),
    re.compile(r"""<meta\s+property=["']og:description["']\s+content=["']([^"']+)["']>"""),
    re.compile(r"""<meta\s+name=["']twitter:description["']\s+content=["']([^"']+)["']>"""),
]
bad = []
with zipfile.ZipFile(zip_path) as archive:
    for name in archive.namelist():
        if not name.startswith("Command.app/Contents/Resources/docs/") or not name.endswith(".html"):
            continue
        text = archive.read(name).decode("utf-8")
        values = []
        for pattern in patterns:
            values.extend(pattern.findall(text))
        for term in terms:
            if any(term in value for value in values):
                bad.append(f"{name}: {term}")
if bad:
    print("\n".join(bad))
    sys.exit(1)
PY
then
  fail "bundled docs HTML metadata contains stale preview term"
fi

print -r -- "$ZIP_LIST" | grep -qx "Command.app/Contents/Resources/README.md" \
  || fail "missing bundled README.md"
if [ -f "${DIR}/README.md" ]; then
  cmp -s "${DIR}/README.md" <(unzip -p "$ZIP" Command.app/Contents/Resources/README.md 2>/dev/null) \
    || fail "bundled README.md is stale"
fi
for required_resource in \
  send-to-claude.sh \
  send-to-claude-lib.sh \
  match-enrich-rule.py \
  clipwatch.py \
  capture-handoff.sh \
  claude-command-capture/bin/submit-cli.js \
  claude-command-capture/src/submit.js \
  claude-command-capture/src/runner.js \
  claude-command-capture/src/submissions.js; do
  print -r -- "$ZIP_LIST" | grep -qx "Command.app/Contents/Resources/${required_resource}" \
    || fail "missing bundled runtime resource: ${required_resource}"
done

BUILT_VERSION="$(unzip -p "$ZIP" Command.app/Contents/Info.plist 2>/dev/null | plutil -extract CFBundleShortVersionString raw -o - - 2>/dev/null)"
[ "$BUILT_VERSION" = "$VERSION" ] || fail "Info.plist version ${BUILT_VERSION:-missing}, expected ${VERSION}"
BUNDLE_ID="$(unzip -p "$ZIP" Command.app/Contents/Info.plist 2>/dev/null | plutil -extract CFBundleIdentifier raw -o - - 2>/dev/null)"
[ "$BUNDLE_ID" = "com.claudecommand" ] || fail "Info.plist bundle id ${BUNDLE_ID:-missing}, expected com.claudecommand"
MIN_MACOS="$(unzip -p "$ZIP" Command.app/Contents/Info.plist 2>/dev/null | plutil -extract LSMinimumSystemVersion raw -o - - 2>/dev/null)"
[ "$MIN_MACOS" = "14.0" ] || fail "Info.plist minimum macOS ${MIN_MACOS:-missing}, expected 14.0"

EXTRACT_DIR="$(mktemp -d)"
if ditto -xk "$ZIP" "$EXTRACT_DIR" 2>/dev/null; then
  APP_PATH="${EXTRACT_DIR}/Command.app"
  EXE_PATH="${APP_PATH}/Contents/MacOS/Command"
  [ -x "$EXE_PATH" ] || fail "packaged app executable missing or not executable"
  SIGN_INFO="$(codesign -dv "$APP_PATH" 2>&1 || true)"
  print -r -- "$SIGN_INFO" | grep -q "Identifier=com.claudecommand" \
    || fail "packaged app codesign identifier missing or wrong"
  print -r -- "$SIGN_INFO" | grep -q "Format=app bundle with Mach-O" \
    || fail "packaged app codesign metadata missing Mach-O app bundle format"
else
  fail "could not extract zip for executable/signature checks"
fi

unzip -p "$ZIP" Command.app/Contents/Resources/docs/index.html 2>/dev/null | grep -q "Default Shortcuts" \
  || fail "bundled docs/index.html missing Default Shortcuts"
unzip -p "$ZIP" Command.app/Contents/Resources/docs/uninstall.html 2>/dev/null | grep -q "<title>Command Uninstall</title>" \
  || fail "bundled docs/uninstall.html title label drifted"
unzip -p "$ZIP" Command.app/Contents/Resources/docs/uninstall.html 2>/dev/null | grep -q "<h1>Uninstall</h1>" \
  || fail "bundled docs/uninstall.html h1 label drifted"
unzip -p "$ZIP" Command.app/Contents/Resources/docs/privacy.html 2>/dev/null | grep -q "<h1>Privacy</h1>" \
  || fail "bundled docs/privacy.html h1 label drifted"
unzip -p "$ZIP" Command.app/Contents/Resources/docs/quick-reference.html 2>/dev/null | grep -q "<strong>Background Architecture</strong>" \
  || fail "bundled docs/quick-reference.html missing Background Architecture card label"
unzip -p "$ZIP" Command.app/Contents/Resources/docs/examples.html 2>/dev/null | grep -q "<h1>Examples</h1>" \
  || fail "bundled docs/examples.html h1 label drifted"
unzip -p "$ZIP" Command.app/Contents/Resources/docs/release.html 2>/dev/null | grep -q "Open each .*Settings -> About.* docs button" \
  || fail "bundled docs/release.html missing About docs-button checklist"
unzip -p "$ZIP" Command.app/Contents/Resources/docs/release.html 2>/dev/null | grep -q "Icon Treatments" \
  || fail "bundled docs/release.html missing Icon Treatments About docs-button check"
unzip -p "$ZIP" Command.app/Contents/Resources/docs/release.html 2>/dev/null | grep -q "Open each .*Settings -> About.*Alpha Limitations" \
  || fail "bundled docs/release.html missing Alpha Limitations About docs-button check"
unzip -p "$ZIP" Command.app/Contents/Resources/docs/release.html 2>/dev/null | grep -q "Background Architecture" \
  || fail "bundled docs/release.html missing Background Architecture About docs-button check"
unzip -p "$ZIP" Command.app/Contents/Resources/docs/release.html 2>/dev/null | grep -q "Release Checklist" \
  || fail "bundled docs/release.html missing Release Checklist About docs-button check"
unzip -p "$ZIP" Command.app/Contents/Resources/docs/support.html 2>/dev/null | grep -q "Copy Diagnostic Info" \
  || fail "bundled docs/support.html missing diagnostic guidance"
unzip -p "$ZIP" Command.app/Contents/Resources/docs/support.html 2>/dev/null | grep -q "Feature request template" \
  || fail "bundled docs/support.html missing feature request guidance"
unzip -p "$ZIP" Command.app/Contents/Resources/docs/faq.html 2>/dev/null | grep -q "Request Feature" \
  || fail "bundled docs/faq.html missing Request Feature guidance"
unzip -p "$ZIP" Command.app/Contents/Resources/docs/faq.html 2>/dev/null | grep -q "auto-submit behavior" \
  || fail "bundled docs/faq.html missing auto-submit preview wording"
unzip -p "$ZIP" Command.app/Contents/Resources/docs/faq.html 2>/dev/null | grep -qv "Add/New/Go behavior" \
  || fail "bundled docs/faq.html still has stale Add/New/Go preview wording"
unzip -p "$ZIP" Command.app/Contents/Resources/docs/install.html 2>/dev/null | grep -q 'id="existing-alpha"' \
  || fail "bundled docs/install.html missing existing-alpha migration anchor"
unzip -p "$ZIP" Command.app/Contents/Resources/docs/install.html 2>/dev/null | grep -Eqi "move .*Applications" \
  || fail "bundled docs/install.html missing automatic relocation guidance"
unzip -p "$ZIP" Command.app/Contents/Resources/docs/install.html 2>/dev/null | grep -q "For local development, use" \
  || fail "bundled docs/install.html missing neutral local-development wording"
unzip -p "$ZIP" Command.app/Contents/Resources/docs/install.html 2>/dev/null | grep -qv "For local Codex development" \
  || fail "bundled docs/install.html still has Codex-specific local-development wording"
unzip -p "$ZIP" Command.app/Contents/Resources/docs/permissions.html 2>/dev/null | grep -q "The identifier remains <code>com.claudecommand</code>" \
  || fail "bundled docs/permissions.html missing bundle-id compatibility note"
unzip -p "$ZIP" Command.app/Contents/Resources/docs/faq.html 2>/dev/null | grep -q "Why do some local paths still say <code>claude-command</code>" \
  || fail "bundled docs/faq.html missing local-path compatibility answer"
unzip -p "$ZIP" Command.app/Contents/Resources/docs/settings.html 2>/dev/null | grep -q "command-export.json" \
  || fail "bundled docs/settings.html missing Command export filename"
unzip -p "$ZIP" Command.app/Contents/Resources/docs/release.html 2>/dev/null | grep -q "Feature request" \
  || fail "bundled docs/release.html missing Feature request repo-surface check"
unzip -p "$ZIP" Command.app/Contents/Resources/docs/index.html 2>/dev/null | grep -Eqi "auto-submit (behavior|when)" \
  || fail "bundled docs/index.html missing auto-submit FAQ wording"
unzip -p "$ZIP" Command.app/Contents/Resources/docs/index.html 2>/dev/null | grep -qv "Go behavior" \
  || fail "bundled docs/index.html still has stale Go behavior wording"
unzip -p "$ZIP" Command.app/Contents/Resources/docs/index.html 2>/dev/null | grep -q "Local development:" \
  || fail "bundled docs/index.html missing neutral local-development wording"
unzip -p "$ZIP" Command.app/Contents/Resources/docs/index.html 2>/dev/null | grep -qv "Codex local development:" \
  || fail "bundled docs/index.html still has tool-specific local-development wording"
unzip -p "$ZIP" Command.app/Contents/Resources/docs/404.html 2>/dev/null | grep -q "Command docs fallback for moved or mistyped links" \
  || fail "bundled docs/404.html missing polished fallback preview wording"
unzip -p "$ZIP" Command.app/Contents/Resources/docs/404.html 2>/dev/null | grep -q "Shortcut conflicts, auto-submit behavior, inheritance, privacy, dictation, background runs, and imports." \
  || fail "bundled docs/404.html missing current FAQ card wording"
unzip -p "$ZIP" Command.app/Contents/Resources/docs/404.html 2>/dev/null | grep -qv "docs page for missing links" \
  || fail "bundled docs/404.html still has rough missing-links preview wording"
unzip -p "$ZIP" Command.app/Contents/Resources/docs/updates.html 2>/dev/null | grep -q 'href="#rename-compatibility"' \
  || fail "bundled docs/updates.html missing rename compatibility sidebar anchor"
unzip -p "$ZIP" Command.app/Contents/Resources/docs/release.html 2>/dev/null | grep -q "redirect-only to <code>/command/</code>" \
  || fail "bundled docs/release.html missing old Pages redirect guidance"
unzip -p "$ZIP" Command.app/Contents/Resources/docs/security.html 2>/dev/null | grep -q 'href="#local-data-scope"' \
  || fail "bundled docs/security.html missing local data scope sidebar anchor"
unzip -p "$ZIP" Command.app/Contents/Resources/docs/support.html 2>/dev/null | grep -q 'href="#feature-requests"' \
  || fail "bundled docs/support.html missing feature requests sidebar anchor"
for linked_doc in PRIVACY.md LIMITATIONS.md SUPPORT.md; do
  unzip -p "$ZIP" "Command.app/Contents/Resources/docs/${linked_doc}" 2>/dev/null | grep -q "Security Policy](SECURITY.md)" \
    || fail "bundled docs/${linked_doc} missing sibling Security Policy link"
  unzip -p "$ZIP" "Command.app/Contents/Resources/docs/${linked_doc}" 2>/dev/null | grep -qv "../SECURITY.md" \
    || fail "bundled docs/${linked_doc} still links outside bundled docs"
done
unzip -p "$ZIP" Command.app/Contents/Resources/README.md 2>/dev/null | grep -q "Command" \
  || fail "bundled README.md missing Command"
unzip -p "$ZIP" Command.app/Contents/Resources/README.md 2>/dev/null | grep -q "For local development, use" \
  || fail "bundled README.md missing neutral local-development wording"
unzip -p "$ZIP" Command.app/Contents/Resources/README.md 2>/dev/null | grep -qv "Codex app Run button uses" \
  || fail "bundled README.md still has Codex-specific local-development wording"
unzip -p "$ZIP" Command.app/Contents/Resources/README.md 2>/dev/null | grep -q "actions/workflows/test.yml/badge.svg" \
  || fail "bundled README.md missing Test workflow badge"
unzip -p "$ZIP" Command.app/Contents/Resources/README.md 2>/dev/null | grep -q "actions/workflows/pages.yml/badge.svg" \
  || fail "bundled README.md missing Pages workflow badge"
unzip -p "$ZIP" Command.app/Contents/Resources/README.md 2>/dev/null | grep -q "img.shields.io/github/v/release/galbutnotgirl/command" \
  || fail "bundled README.md missing latest release badge"
unzip -p "$ZIP" Command.app/Contents/Resources/README.md 2>/dev/null | grep -q "license-MIT-green.svg" \
  || fail "bundled README.md missing MIT license badge"

if [ "$FAIL" -eq 0 ]; then
  print -r -- "release asset ok: $ZIP"
fi
exit "$FAIL"
