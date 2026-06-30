#!/bin/zsh
# build.sh — compile DictationLab via SPM (FluidAudio/Parakeet TDT dependency).
emulate -L zsh
set -uo pipefail

DIR="${0:A:h}"
APP="${DIR}/DictationLab.app"
BIN_DIR="${APP}/Contents/MacOS"
BUNDLE_ID="com.gal.dictationlab"

rm -rf "$APP"
mkdir -p "$BIN_DIR"

print -- "[lab] building (SPM + FluidAudio)…"
cd "$DIR"
if ! swift build -c release 2>&1; then
    print -- "[lab] ERROR: swift build failed"; exit 1
fi

cp ".build/release/DictationLab" "$BIN_DIR/DictationLab"

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>DictationLab</string>
	<key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
	<key>CFBundleName</key><string>Dictation Lab</string>
	<key>CFBundleDisplayName</key><string>Dictation Lab</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.2</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>NSMicrophoneUsageDescription</key><string>Dictation Lab uses the microphone to transcribe speech.</string>
	<key>NSAccessibilityUsageDescription</key><string>Dictation Lab needs Accessibility to paste transcribed text at the cursor.</string>
</dict>
</plist>
PLIST

codesign --force --sign "81C8C94D179A86E681E28236AB00CE634088D13E" --identifier "$BUNDLE_ID" "$APP" 2>/dev/null \
  && print -- "[lab] codesigned (Command cert)" \
  || { codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"; print -- "[lab] ad-hoc signed"; }

# Install to /Applications so TCC (Accessibility/Microphone) permissions survive rebuilds.
# Permissions are keyed to app path + signing identity — stable path = no re-grant on updates.
INSTALL="/Applications/DictationLab.app"
print -- "[lab] stopping existing instance…"
pkill -x "DictationLab" 2>/dev/null; sleep 0.3 || true
print -- "[lab] installing to ${INSTALL}…"
rm -rf "$INSTALL"
cp -R "$APP" "$INSTALL"
print -- "[lab] installed: $INSTALL"
print -- ""
print -- "Launch: open '$INSTALL'"
print -- "(first launch downloads ~650 MB Parakeet model)"
