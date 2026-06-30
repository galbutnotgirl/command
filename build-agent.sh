#!/bin/zsh
# build-agent.sh — compile agent/*.swift into a codesigned ClaudeCommand.app with a
# stable bundle id, so its Accessibility grant sticks. Output: ClaudeCommand.app
# next to this script. Install/run it with install-agent.sh.
emulate -L zsh
set -uo pipefail

DIR="${0:A:h}"
SRC_DIR="${DIR}/agent"
APP="${DIR}/ClaudeCommand.app"
BIN_DIR="${APP}/Contents/MacOS"
BUNDLE_ID="com.claudecommand"

[ -f "${SRC_DIR}/main.swift" ] || { print -- "[agent] missing ${SRC_DIR}/main.swift"; exit 1; }

# App version — read from the VERSION file so the in-app updater has a real
# number to compare against the latest GitHub release tag.
VERSION="$( [ -f "${DIR}/VERSION" ] && tr -d ' \t\n' < "${DIR}/VERSION" || echo "1.0.0" )"
print -- "[agent] version ${VERSION}"

rm -rf "$APP"
mkdir -p "$BIN_DIR"

print -- "[agent] compiling (swift build)…"
# SPM build — FluidAudio dependency requires Package.swift resolution.
if ! ( cd "${SRC_DIR}" && swift build -c release 2>&1 ); then
  print -- "[agent] ERROR swift build failed"; exit 1
fi
cp "${SRC_DIR}/.build/release/ClaudeCommand" "${BIN_DIR}/ClaudeCommand"

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>ClaudeCommand</string>
	<key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
	<key>CFBundleName</key><string>Claude Command</string>
	<key>CFBundleDisplayName</key><string>Claude Command</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>${VERSION}</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>LSUIElement</key><true/>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>NSMicrophoneUsageDescription</key><string>ClaudeCommand uses your microphone for on-device dictation via Parakeet TDT.</string>
</dict>
</plist>
PLIST

# Bundle send-to-claude.sh + clipwatch.py into Resources.
mkdir -p "${APP}/Contents/Resources"
SEND="${DIR}/send-to-claude.sh"
if [ -f "$SEND" ]; then
  cp "$SEND" "${APP}/Contents/Resources/send-to-claude.sh"
  chmod +x "${APP}/Contents/Resources/send-to-claude.sh"
  print -- "[agent] bundled send-to-claude.sh"
fi
CLIPWATCH="${DIR}/clipwatch.py"
if [ -f "$CLIPWATCH" ]; then
  cp "$CLIPWATCH" "${APP}/Contents/Resources/clipwatch.py"
  print -- "[agent] bundled clipwatch.py"
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
print -- "First run prompts for Accessibility for 'ClaudeCommand' — allow once, covers all hotkeys + keystrokes."
