#!/bin/zsh
# build-agent.sh — compile agent/*.swift into a codesigned Command.app with a
# stable bundle id, so its Accessibility grant sticks. Output: Command.app
# next to this script. Install/run it with install-agent.sh.
emulate -L zsh
set -uo pipefail

DIR="${0:A:h}"
SRC_DIR="${DIR}/agent"
APP="${DIR}/Command.app"
BIN_DIR="${APP}/Contents/MacOS"
BUNDLE_ID="com.claudecommand"

[ -f "${SRC_DIR}/main.swift" ] || { print -- "[agent] missing ${SRC_DIR}/main.swift"; exit 1; }

# App version — read from the VERSION file so the in-app updater has a real
# number to compare against the latest GitHub release tag.
VERSION="$( [ -f "${DIR}/VERSION" ] && tr -d ' \t\n' < "${DIR}/VERSION" || echo "1.0.0" )"
print -- "[agent] version ${VERSION}"

# Branch + short commit, so a local dev build says which worktree/branch it came
# from (Settings ▸ About). Empty when not a git checkout (e.g. a release zip has
# no .git) — About only shows this line when it's non-empty.
GIT_BRANCH=""
if command -v git >/dev/null 2>&1 && git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  b="$(git -C "$DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  h="$(git -C "$DIR" rev-parse --short HEAD 2>/dev/null)"
  [ -n "$b" ] && [ "$b" != "HEAD" ] && GIT_BRANCH="${b}@${h}"
fi
[ -n "$GIT_BRANCH" ] && print -- "[agent] branch ${GIT_BRANCH}"

rm -rf "$APP"
mkdir -p "$BIN_DIR"

print -- "[agent] compiling (swift build)…"
# SPM build — FluidAudio dependency requires Package.swift resolution.
if ! ( cd "${SRC_DIR}" && swift build -c release 2>&1 ); then
  print -- "[agent] ERROR swift build failed"; exit 1
fi
cp "${SRC_DIR}/.build/release/ClaudeCommand" "${BIN_DIR}/Command"

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>Command</string>
	<key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
	<key>CFBundleName</key><string>Command</string>
	<key>CFBundleDisplayName</key><string>Command</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>${VERSION}</string>
	<key>ClaudeCommandGitBranch</key><string>${GIT_BRANCH}</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>LSUIElement</key><true/>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>NSMicrophoneUsageDescription</key><string>Command uses your microphone for on-device dictation via Parakeet TDT.</string>
</dict>
</plist>
PLIST

# Bundle send-to-claude.sh + clipwatch.py into Resources.
mkdir -p "${APP}/Contents/Resources"
SEND="${DIR}/send-to-claude.sh"
if [ -f "$SEND" ]; then
  cp "$SEND" "${APP}/Contents/Resources/send-to-claude.sh"
  chmod +x "${APP}/Contents/Resources/send-to-claude.sh"
  cp "${DIR}/send-to-claude-lib.sh" "${APP}/Contents/Resources/send-to-claude-lib.sh"
  cp "${DIR}/match-enrich-rule.py" "${APP}/Contents/Resources/match-enrich-rule.py"
  chmod +x "${APP}/Contents/Resources/match-enrich-rule.py"
  print -- "[agent] bundled send-to-claude.sh + lib + match-enrich-rule.py"
fi
CLIPWATCH="${DIR}/clipwatch.py"
if [ -f "$CLIPWATCH" ]; then
  cp "$CLIPWATCH" "${APP}/Contents/Resources/clipwatch.py"
  print -- "[agent] bundled clipwatch.py"
fi

# Bundle end-user docs so About's docs buttons work before a release is pushed
# and when the user is offline.
DOCS_SRC="${DIR}/docs"
if [ -f "${DOCS_SRC}/USER_GUIDE.md" ]; then
  mkdir -p "${APP}/Contents/Resources/docs"
  for doc_asset in 404.html index.html install.html uninstall.html guide.html settings.html quick-reference.html examples.html faq.html changelog.html limitations.html updates.html permissions.html troubleshooting.html privacy.html support.html security.html icon-treatments.html background.html release.html site.css robots.txt sitemap.xml INSTALL.md UNINSTALL.md USER_GUIDE.md SETTINGS_REFERENCE.md QUICK_REFERENCE.md EXAMPLES.md FAQ.md CHANGELOG.md LIMITATIONS.md UPDATES.md PERMISSIONS.md TROUBLESHOOTING.md PRIVACY.md SUPPORT.md SECURITY.md ICON_TREATMENTS.md BACKGROUND_TRIGGER_INTEGRATION.md RELEASE_CHECKLIST.md icon-treatment-bold-animated.svg icon-treatment-green-voice.svg icon-treatment-options-animated.svg icon-treatment-options.svg; do
    if [ -f "${DOCS_SRC}/${doc_asset}" ]; then
      cp "${DOCS_SRC}/${doc_asset}" "${APP}/Contents/Resources/docs/"
    else
      print -- "[agent] ERROR missing bundled docs asset: docs/${doc_asset}"; exit 1
    fi
  done
  cp "${DIR}/README.md" "${APP}/Contents/Resources/README.md" 2>/dev/null || true
  print -- "[agent] bundled user docs"
fi

# Background skill handoff: capture-handoff.sh + the vendored Electron-free
# core it drives (src/ + bin/ only — no tests, renderer, or node_modules).
HANDOFF="${DIR}/capture-handoff.sh"
if [ -f "$HANDOFF" ]; then
  cp "$HANDOFF" "${APP}/Contents/Resources/capture-handoff.sh"
  chmod +x "${APP}/Contents/Resources/capture-handoff.sh"
  CORE_SRC="${DIR}/vendor/claude-command-capture"
  CORE_DST="${APP}/Contents/Resources/claude-command-capture"
  rm -rf "$CORE_DST"
  mkdir -p "$CORE_DST/src" "$CORE_DST/bin"
  cp "$CORE_SRC"/src/*.js "$CORE_DST/src/"
  cp "$CORE_SRC"/bin/*.js "$CORE_DST/bin/"
  print -- "[agent] bundled capture-handoff.sh + vendor core"
fi

# App icon (orbital-ring star). Build AppIcon.icns from agent/icon.png if present.
ICON_SRC="${DIR}/agent/icon.png"
if [ -f "$ICON_SRC" ] && command -v iconutil >/dev/null 2>&1; then
  ISET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$ISET"
  for s in 16 32 128 256 512; do
    sips -z $s $s        "$ICON_SRC" --out "$ISET/icon_${s}x${s}.png"    >/dev/null 2>&1
    sips -z $((s*2)) $((s*2)) "$ICON_SRC" --out "$ISET/icon_${s}x${s}@2x.png" >/dev/null 2>&1
  done
  mkdir -p "${APP}/Contents/Resources"
  iconutil -c icns "$ISET" -o "${APP}/Contents/Resources/AppIcon.icns" 2>/dev/null \
    && print -- "[agent] app icon embedded" \
    || print -- "[agent] ⚠ icon build failed (non-fatal)"
  rm -rf "$(dirname "$ISET")"
fi

# Code signing identity. Default is ad-hoc ("-"), which is fine for a local build.
# To make TCC grants (Accessibility, Screen Recording) survive rebuilds, create a
# self-signed code-signing cert in Keychain Access and export its name/SHA-1:
#   SIGN_ID="My Cert Name" ./build-agent.sh
# For a distributable build, use a Developer ID Application identity.
# Use a stable signing identity so TCC grants survive rebuilds.
# Check (in order): env override, any valid codesigning cert in Keychain, ad-hoc.
if [[ -z "${SIGN_ID:-}" ]]; then
    EXISTING="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -o '"[^"]*"' | head -1 | tr -d '"')"
    if [[ -n "$EXISTING" ]]; then
        SIGN_ID="$EXISTING"
        print -- "[agent] using keychain cert: $SIGN_ID"
    else
        SIGN_ID="-"
        print -- "[agent] ⚠ no signing cert found — using ad-hoc; TCC grants may reset on rebuild"
        print -- "[agent]   To fix: open Keychain Access → Certificate Assistant → Create Certificate"
        print -- "[agent]   Name: ClaudeCommandDev, Type: Self-Signed Root, override: Code Signing"
    fi
fi
codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP" \
  && print -- "[agent] codesigned ($SIGN_ID)" \
  || { print -- "[agent] ERROR codesign failed (SIGN_ID=$SIGN_ID)"; exit 1; }

print -- "[agent] built: $APP"
print -- "First run prompts for Accessibility for 'Command' — allow once, covers all hotkeys + keystrokes."
