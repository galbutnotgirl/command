'use strict';

// Capture the currently highlighted text in whatever app has focus, by
// simulating the OS copy shortcut and reading the clipboard. The previous
// clipboard contents (text or image) are restored afterwards.
//
// macOS: requires the Accessibility permission (System Settings > Privacy &
// Security > Accessibility) so System Events may send keystrokes.
// Linux: requires `xdotool` (X11).
// Windows: uses WScript SendKeys via PowerShell.

const { execFile } = require('child_process');
const { clipboard } = require('electron');

const COPY_TIMEOUT_MS = 1500;
const POLL_INTERVAL_MS = 50;

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function execFileAsync(cmd, args) {
  return new Promise((resolve, reject) => {
    execFile(cmd, args, (err) => (err ? reject(err) : resolve()));
  });
}

async function simulateCopy() {
  if (process.platform === 'darwin') {
    await execFileAsync('osascript', [
      '-e',
      'tell application "System Events" to keystroke "c" using {command down}',
    ]);
  } else if (process.platform === 'linux') {
    await execFileAsync('xdotool', ['key', '--clearmodifiers', 'ctrl+c']);
  } else if (process.platform === 'win32') {
    await execFileAsync('powershell', [
      '-NoProfile',
      '-Command',
      "$w = New-Object -ComObject WScript.Shell; $w.SendKeys('^c')",
    ]);
  } else {
    throw new Error(`Selection capture is not supported on ${process.platform}`);
  }
}

function snapshotClipboard() {
  const image = clipboard.readImage();
  return {
    text: clipboard.readText(),
    image: image.isEmpty() ? null : image,
  };
}

function restoreClipboard(snapshot) {
  clipboard.clear();
  if (snapshot.image) {
    clipboard.writeImage(snapshot.image);
  } else if (snapshot.text) {
    clipboard.writeText(snapshot.text);
  }
}

async function captureSelection() {
  const capturedAt = new Date().toISOString();
  const snapshot = snapshotClipboard();
  let text = '';
  try {
    // Clear first so we can detect the copy even when the selection equals
    // the old clipboard contents.
    clipboard.clear();
    await simulateCopy();
    const deadline = Date.now() + COPY_TIMEOUT_MS;
    while (Date.now() < deadline) {
      text = clipboard.readText();
      if (text) break;
      await sleep(POLL_INTERVAL_MS);
    }
  } finally {
    restoreClipboard(snapshot);
  }
  if (!text || !text.trim()) {
    throw new Error(
      'No highlighted text found. Make sure something is selected' +
        (process.platform === 'darwin' ? ' and Accessibility permission is granted.' : '.')
    );
  }
  return { kind: 'text', source: 'selection', capturedAt, text };
}

module.exports = { captureSelection };
