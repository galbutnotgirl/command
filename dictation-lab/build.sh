#!/bin/zsh
# build.sh — compile DictationLab.swift into a standalone foreground .app.
#
# This is a NORMAL app (not LSUIElement, not launchd) so it runs in the user's
# GUI/audio session. Own bundle id → its own mic + speech TCC grant, isolated
# from the ClaudeCommand agent. Launch by double-click or `open` so macOS gives
# it a proper audio session and shows the permission prompts.
emulate -L zsh
set -uo pipefail

DIR="${0:A:h}"
APP="${DIR}/DictationLab.app"
BIN_DIR="${APP}/Contents/MacOS"
BUNDLE_ID="com.gal.dictationlab"

rm -rf "$APP"
mkdir -p "$BIN_DIR"

print -- "[lab] compiling…"
if ! swiftc -O "${DIR}/DictationLab.swift" -o "${BIN_DIR}/DictationLab" \
       -framework SwiftUI -framework Speech -framework AVFoundation \
       -framework CoreAudio -framework AudioToolbox 2>&1; then
  print -- "[lab] ERROR swiftc failed"; exit 1
fi

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
	<key>CFBundleShortVersionString</key><string>0.1</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>NSMicrophoneUsageDescription</key><string>Dictation Lab uses the microphone to test speech transcription.</string>
	<key>NSSpeechRecognitionUsageDescription</key><string>Dictation Lab uses speech recognition to test transcription.</string>
</dict>
</plist>
PLIST

# Sign with the stable local "Command" cert if present (keeps TCC grants across
# rebuilds); fall back to ad-hoc.
codesign --force --sign "81C8C94D179A86E681E28236AB00CE634088D13E" --identifier "$BUNDLE_ID" "$APP" 2>/dev/null \
  && print -- "[lab] codesigned (Command cert)" \
  || { codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"; print -- "[lab] ad-hoc signed"; }

print -- "[lab] built: $APP"
print -- "Run:  open '$APP'   (first launch prompts for Mic + Speech — approve both)"
