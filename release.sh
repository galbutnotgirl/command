#!/bin/zsh
# release.sh — build Command.app, package it as a GitHub Release asset,
# and (with --publish) tag + upload it. Guards against the mistakes that are
# easy to make doing this by hand: releasing a dirty tree, re-releasing a
# version that's already tagged, or shipping a zip whose embedded version
# doesn't match what you think you built.
#
# The in-app updater (agent/Updater.swift) looks for the latest release on
# GH_OWNER/GH_REPO, reads its tag as the version, and downloads the first .zip
# asset. This script produces exactly that asset.
#
# Usage:
#   ./release.sh                      # build + package only, to dist/
#   ./release.sh --notarize            # notarize + staple local package
#   ./release.sh --publish --notarize  # notarize, tag, push, and create release
#   ./release.sh --publish --notarize --notes="custom notes"  # skip generated notes
#   ./release.sh --publish --allow-unnotarized       # explicit alpha-only escape hatch
#   ./release.sh --skip-checks        # bypass the clean-tree/branch/tag guards (CI, one-offs)
#
# Bump VERSION first so the tag is newer than what users are running.
emulate -L zsh
set -uo pipefail

DIR="${0:A:h}"
VERSION="$( [ -f "${DIR}/VERSION" ] && tr -d ' \t\n' < "${DIR}/VERSION" || echo "1.0.0" )"
APP="${DIR}/Command.app"
DIST="${DIR}/dist"
FINAL_ZIP="${DIST}/Command-${VERSION}.zip"
FINAL_SHA256="${FINAL_ZIP}.sha256"
ZIP="$FINAL_ZIP"
SHA256="$FINAL_SHA256"
TAG="v${VERSION}"
EXPECTED_BUNDLE_ID="com.claudecommand"
EXPECTED_MIN_MACOS="14.0"
PACKAGE_ROOT=""
PACKAGE_SWAP_STARTED=0
PACKAGE_COMMITTED=0
PREVIOUS_ZIP=""
PREVIOUS_SHA256=""

cleanup_package_staging() {
  if [ "$PACKAGE_SWAP_STARTED" = "1" ] && [ "$PACKAGE_COMMITTED" = "0" ]; then
    rm -f "$FINAL_ZIP" "$FINAL_SHA256"
    [ -n "$PREVIOUS_ZIP" ] && [ -f "$PREVIOUS_ZIP" ] && mv "$PREVIOUS_ZIP" "$FINAL_ZIP" 2>/dev/null || true
    [ -n "$PREVIOUS_SHA256" ] && [ -f "$PREVIOUS_SHA256" ] && mv "$PREVIOUS_SHA256" "$FINAL_SHA256" 2>/dev/null || true
  fi
  [ -n "$PACKAGE_ROOT" ] && rm -rf "$PACKAGE_ROOT"
}
trap cleanup_package_staging EXIT HUP INT TERM

PUBLISH=0
SKIP_CHECKS=0
NOTARIZE=0
ALLOW_UNNOTARIZED=0
VALIDATE_CONFIG=0
NOTARY_PROFILE="${COMMAND_NOTARY_PROFILE:-}"
NOTES=""
for arg in "$@"; do
  case "$arg" in
    --publish) PUBLISH=1 ;;
    --notarize) NOTARIZE=1 ;;
    --allow-unnotarized) ALLOW_UNNOTARIZED=1 ;;
    --validate-config) VALIDATE_CONFIG=1 ;;
    --notary-profile=*) NOTARY_PROFILE="${arg#--notary-profile=}" ;;
    --skip-checks) SKIP_CHECKS=1 ;;
    --notes=*) NOTES="${arg#--notes=}" ;;
    *) print -- "[release] unknown option: $arg"; exit 2 ;;
  esac
done

fail() { print -- "[release] $1"; exit 1; }

# Publishing an unnotarized app creates Gatekeeper's "Apple could not verify"
# warning for every download. Require notarization by default; retain one
# explicit escape hatch for emergency alpha builds while Developer ID setup is
# unavailable. --validate-config lets CI test policy without building/publishing.
if [ "$PUBLISH" = "1" ] && [ "$NOTARIZE" = "0" ] && [ "$ALLOW_UNNOTARIZED" = "0" ]; then
  fail "--publish requires --notarize (or explicit --allow-unnotarized for an alpha-only emergency build)."
fi
if [ "$NOTARIZE" = "1" ] && [ -z "$NOTARY_PROFILE" ]; then
  fail "--notarize needs COMMAND_NOTARY_PROFILE or --notary-profile=<keychain profile>."
fi
if [ "$NOTARIZE" = "1" ] && [ "$ALLOW_UNNOTARIZED" = "1" ]; then
  fail "choose --notarize or --allow-unnotarized, not both."
fi
if [ "$ALLOW_UNNOTARIZED" = "1" ] && [[ "$TAG" != *alpha* ]]; then
  fail "--allow-unnotarized is restricted to alpha versions; notarize beta and stable releases."
fi
if [ "$VALIDATE_CONFIG" = "1" ]; then
  print -- "[release] configuration ok"
  exit 0
fi

# ---- pre-flight guards (skippable with --skip-checks) -----------------------
if [ "$SKIP_CHECKS" = "0" ]; then
  BRANCH="$(git -C "$DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [ "$BRANCH" = "main" ] || fail "on branch '${BRANCH:-unknown}', not main — releases should come from main (--skip-checks to override)."

  if [ -n "$(git -C "$DIR" status --porcelain 2>/dev/null)" ]; then
    fail "working tree isn't clean — commit or stash first (--skip-checks to override)."
  fi

  if git -C "$DIR" rev-parse "$TAG" >/dev/null 2>&1; then
    fail "tag ${TAG} already exists — bump VERSION first (--skip-checks to override)."
  fi

  if [ "$PUBLISH" = "1" ] && command -v gh >/dev/null 2>&1 && gh release view "$TAG" >/dev/null 2>&1; then
    fail "GitHub release ${TAG} already exists — bump VERSION first (--skip-checks to override)."
  fi

  command -v swift >/dev/null 2>&1 || fail "swift not found — needed for app tests (--skip-checks to override)."
  command -v node >/dev/null 2>&1 || fail "node not found — needed for background runner tests (--skip-checks to override)."
  command -v python3 >/dev/null 2>&1 || fail "python3 not found — needed for docs validation (--skip-checks to override)."
  (cd "${DIR}/agent" && swift test) || fail "Swift tests failed — fix app/core tests before release."
  (cd "${DIR}/vendor/claude-command-capture" && node --test) || fail "Node tests failed — fix background runner tests before release."
  "${DIR}/test/test-shell.sh" || fail "shell tests failed — fix scripts before release."
  "${DIR}/test/test-build-transaction.sh" || fail "build transaction tests failed — fix artifact preservation before release."
  "${DIR}/test/test-release-transaction.sh" || fail "release transaction tests failed — fix package preservation before release."
  "${DIR}/test/test-install-state.sh" || fail "install state tests failed — fix fresh/update behavior before release."
  "${DIR}/test/test-updater-swap.sh" || fail "updater swap tests failed — fix install/rollback before release."
  "${DIR}/test/test-restart-app.sh" || fail "restart handoff tests failed — fix relaunch behavior before release."
  "${DIR}/test/test-release-policy.sh" || fail "release policy tests failed — fix signing/notarization guards before release."
  "${DIR}/test/test-static-analysis.sh" || fail "static analysis failed — fix script or configuration syntax before release."
  python3 "${DIR}/test/test-docs.py" || fail "docs validation failed — fix docs links/metadata/packaging guards before release."
  python3 "${DIR}/test/test-pages.py" || fail "Pages validation failed — fix deploy assets and install recovery before release."
  python3 "${DIR}/test/test_string_review.py" || fail "string review round-trip failed — fix export/apply safety before release."
fi

print -- "[release] building ${TAG}…"
"${DIR}/build-agent.sh" || fail "build failed"
[ -d "$APP" ] || fail "missing $APP"

SIGN_INFO="$(codesign -dv --verbose=4 "$APP" 2>&1 || true)"
if [ "$NOTARIZE" = "1" ]; then
  print -r -- "$SIGN_INFO" | grep -q '^Authority=Developer ID Application:' \
    || fail "--notarize requires a Developer ID Application signature. Set SIGN_ID to that Keychain identity."
  print -r -- "$SIGN_INFO" | grep -Eq '^flags=.*\(runtime\)' \
    || fail "Developer ID build is missing hardened runtime."
  codesign --verify --deep --strict --verbose=2 "$APP" \
    || fail "Developer ID signature verification failed before notarization."
fi

# The version baked into Info.plist by build-agent.sh should match VERSION
# exactly — if it doesn't, something read a stale build or a stale file.
BUILT_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP}/Contents/Info.plist" 2>/dev/null)"
[ "$BUILT_VERSION" = "$VERSION" ] || fail "built Info.plist says v${BUILT_VERSION}, expected v${VERSION} — stale build?"
BUILT_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${APP}/Contents/Info.plist" 2>/dev/null)"
[ "$BUILT_BUNDLE_ID" = "$EXPECTED_BUNDLE_ID" ] || fail "built Info.plist bundle id ${BUILT_BUNDLE_ID:-missing}, expected ${EXPECTED_BUNDLE_ID} — wrong app bundle?"
BUILT_MIN_MACOS="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "${APP}/Contents/Info.plist" 2>/dev/null)"
[ "$BUILT_MIN_MACOS" = "$EXPECTED_MIN_MACOS" ] || fail "built Info.plist minimum macOS ${BUILT_MIN_MACOS:-missing}, expected ${EXPECTED_MIN_MACOS} — wrong deployment floor?"

mkdir -p "$DIST"
PACKAGE_ROOT="$(mktemp -d "${DIST}/.command-release.XXXXXX")" || fail "could not create package staging directory"
ZIP="${PACKAGE_ROOT}/Command-${VERSION}.zip"
SHA256="${ZIP}.sha256"
# COPYFILE_DISABLE + --norsrc prevents AppleDouble ._* metadata from leaking
# into release zips. ditto -ck --keepParent → zip contains Command.app at
# top level, which is what Updater.install expects to find after 'ditto -xk'.
COPYFILE_DISABLE=1 ditto -ck --norsrc --keepParent "$APP" "$ZIP" || fail "zip failed"

# Sanity-check the zip actually has the app at top level, not nested or empty —
# this is exactly the shape Updater.install's unzip step assumes.
ZIP_TOP="$(unzip -Z1 "$ZIP" 2>/dev/null | head -1)"
case "$ZIP_TOP" in
  Command.app/*) ;;
  *) fail "packaged zip doesn't have Command.app at top level (saw: ${ZIP_TOP:-empty}) — Updater.install would fail to unpack this." ;;
esac

# About's docs buttons and GitHub Pages docs depend on bundled docs being
# present in release zips. Check every shareable docs asset, not a subset.
ZIP_LIST="$(unzip -Z1 "$ZIP" 2>/dev/null)"
if print -r -- "$ZIP_LIST" | grep -Eq '(^|/)(\._|__MACOSX(/|$))'; then
  fail "packaged zip contains AppleDouble metadata files — release assets should not include ._* or __MACOSX entries."
fi
if print -r -- "$ZIP_LIST" | grep -qx "Command.app/Contents/Resources/docs/STATUS.md"; then
  fail "packaged zip contains internal docs/STATUS.md — release assets should bundle shareable docs only."
fi
for required_doc in 404.html index.html install.html uninstall.html guide.html settings.html quick-reference.html examples.html faq.html changelog.html limitations.html updates.html permissions.html troubleshooting.html privacy.html support.html security.html icon-treatments.html background.html release.html site.css robots.txt sitemap.xml INSTALL.md UNINSTALL.md USER_GUIDE.md SETTINGS_REFERENCE.md QUICK_REFERENCE.md EXAMPLES.md FAQ.md CHANGELOG.md LIMITATIONS.md UPDATES.md PERMISSIONS.md TROUBLESHOOTING.md PRIVACY.md SUPPORT.md SECURITY.md ICON_TREATMENTS.md BACKGROUND_TRIGGER_INTEGRATION.md RELEASE_CHECKLIST.md icon-treatment-bold-animated.svg icon-treatment-green-voice.svg icon-treatment-options-animated.svg icon-treatment-options.svg; do
  print -r -- "$ZIP_LIST" | grep -qx "Command.app/Contents/Resources/docs/${required_doc}" \
    || fail "packaged zip missing bundled docs asset: docs/${required_doc}"
  cmp -s "${DIR}/docs/${required_doc}" <(unzip -p "$ZIP" "Command.app/Contents/Resources/docs/${required_doc}" 2>/dev/null) \
    || fail "bundled docs asset is stale: docs/${required_doc}"
done
print -r -- "$ZIP_LIST" | grep -qx "Command.app/Contents/Resources/README.md" \
  || fail "packaged zip missing bundled README.md"
cmp -s "${DIR}/README.md" <(unzip -p "$ZIP" Command.app/Contents/Resources/README.md 2>/dev/null) \
  || fail "bundled README.md is stale"
for required_resource in \
  send-to-claude.sh \
  send-to-claude-lib.sh \
  match-enrich-rule.py \
  clipwatch.py \
  update-swap.sh \
  restart-app.sh \
  capture-handoff.sh \
  claude-command-capture/bin/submit-cli.js \
  claude-command-capture/src/submit.js \
  claude-command-capture/src/runner.js \
  claude-command-capture/src/submissions.js; do
  print -r -- "$ZIP_LIST" | grep -qx "Command.app/Contents/Resources/${required_resource}" \
    || fail "packaged zip missing bundled runtime resource: ${required_resource}"
done

if [ "$NOTARIZE" = "1" ]; then
  command -v xcrun >/dev/null 2>&1 || fail "--notarize needs xcrun/Xcode command-line tools."
  print -- "[release] submitting ${ZIP:t} to Apple notarization…"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait \
    || fail "Apple notarization failed. Inspect notarytool output before publishing."
  xcrun stapler staple "$APP" || fail "stapling notarization ticket failed."
  xcrun stapler validate "$APP" || fail "stapled notarization ticket did not validate."

  # Stapling changes app bundle, so rebuild archive from ticket-bearing app.
  rm -f "$ZIP"
  COPYFILE_DISABLE=1 ditto -ck --norsrc --keepParent "$APP" "$ZIP" \
    || fail "repackaging stapled app failed."
  spctl -a -vv -t exec "$APP" || fail "Gatekeeper rejected notarized app."
  print -- "[release] notarized, stapled, and Gatekeeper accepted"
elif [ "$ALLOW_UNNOTARIZED" = "1" ]; then
  print -- "[release] WARNING publishing unnotarized alpha; users will see a Gatekeeper warning."
fi

(
  cd "${ZIP:h}" || exit 1
  shasum -a 256 "${ZIP:t}" > "${SHA256:t}"
) || fail "checksum failed"

if ! grep -Eq "^[0-9a-f]{64}  ${ZIP:t}$" "$SHA256"; then
  fail "checksum file malformed: $SHA256"
fi

# Replace zip + checksum only after every package/notarization check succeeds.
# Keep previous pair inside staging so signal or move failure can restore it.
PREVIOUS_ZIP="${PACKAGE_ROOT}/previous.zip"
PREVIOUS_SHA256="${PACKAGE_ROOT}/previous.zip.sha256"
PACKAGE_SWAP_STARTED=1
[ -f "$FINAL_ZIP" ] && mv "$FINAL_ZIP" "$PREVIOUS_ZIP"
[ -f "$FINAL_SHA256" ] && mv "$FINAL_SHA256" "$PREVIOUS_SHA256"
if ! mv "$ZIP" "$FINAL_ZIP" || ! mv "$SHA256" "$FINAL_SHA256"; then
  fail "could not commit packaged zip and checksum; previous release assets will be restored"
fi
PACKAGE_COMMITTED=1
ZIP="$FINAL_ZIP"
SHA256="$FINAL_SHA256"
rm -rf "$PACKAGE_ROOT"
PACKAGE_ROOT=""

print -- "[release] packaged: ${ZIP} ($(du -h "$ZIP" | cut -f1))"
print -- "[release] checksum: ${SHA256}"

if [ "$PUBLISH" = "0" ]; then
  print -- ""
  print -- "Next:"
  print -- "  COMMAND_NOTARY_PROFILE=<profile> SIGN_ID='Developer ID Application: …' ./release.sh --publish --notarize"
  print -- ""
  print -- "That reruns guards, notarizes + staples the app, checks Gatekeeper, tags ${TAG}, and creates the GitHub Release."
  exit 0
fi

command -v gh >/dev/null 2>&1 || fail "--publish needs the gh CLI on PATH."

# Only alpha/beta tags are marked pre-release — a plain "vX.Y.Z" is a real
# stable release (see PROD_AVAILABLE in Updater.swift, which gates this).
PRERELEASE_FLAG=()
case "$TAG" in
  *alpha*|*beta*) PRERELEASE_FLAG=(--prerelease) ;;
esac

print -- "[release] tagging ${TAG}…"
git -C "$DIR" tag "$TAG" || fail "git tag failed"
git -C "$DIR" push origin "$TAG" || fail "git push (tag) failed"

print -- "[release] creating GitHub release ${TAG}…"
if [ -n "$NOTES" ]; then
  gh release create "$TAG" "$ZIP" "$SHA256" --title "$TAG" "${PRERELEASE_FLAG[@]}" --notes "$NOTES" || fail "gh release create failed"
else
  gh release create "$TAG" "$ZIP" "$SHA256" --title "$TAG" "${PRERELEASE_FLAG[@]}" --generate-notes || fail "gh release create failed"
fi

print -- "[release] published: https://github.com/$(git -C "$DIR" remote get-url origin | sed -E 's#.*[:/]([^/]+/[^/]+)\.git#\1#')/releases/tag/${TAG}"
print -- "Any installed copy will see ${TAG} via Settings → About → Check for Updates."
