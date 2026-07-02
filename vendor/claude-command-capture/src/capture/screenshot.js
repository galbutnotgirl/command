'use strict';

// Interactive region screenshot, saved as PNG into the captures directory.
//
// macOS: /usr/sbin/screencapture -i (requires Screen Recording permission).
// Linux: first available of gnome-screenshot / spectacle / scrot / maim.
// Windows: launches the Snipping Tool overlay (ms-screenclip:) and polls the
// clipboard for the resulting image.

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { execFile, spawn } = require('child_process');
const { clipboard } = require('electron');

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function execFileAsync(cmd, args) {
  return new Promise((resolve, reject) => {
    execFile(cmd, args, (err) => (err ? reject(err) : resolve()));
  });
}

function fileHasContent(file) {
  try {
    return fs.statSync(file).size > 0;
  } catch {
    return false;
  }
}

async function captureRegionToFile(file) {
  if (process.platform === 'darwin') {
    // -i interactive, -x no sound. User can press Esc to cancel.
    await execFileAsync('/usr/sbin/screencapture', ['-i', '-x', file]);
    return fileHasContent(file);
  }

  if (process.platform === 'linux') {
    const tools = [
      ['gnome-screenshot', ['-a', '-f', file]],
      ['spectacle', ['-r', '-b', '-n', '-o', file]],
      ['scrot', ['-s', file]],
      ['maim', ['-s', file]],
    ];
    for (const [cmd, args] of tools) {
      try {
        await execFileAsync(cmd, args);
        if (fileHasContent(file)) return true;
      } catch (err) {
        if (err && err.code === 'ENOENT') continue; // tool not installed
        // Tool exists but failed (e.g. user cancelled): stop trying others.
        return fileHasContent(file);
      }
    }
    if (!fileHasContent(file)) {
      throw new Error(
        'No screenshot tool found. Install one of: gnome-screenshot, spectacle, scrot, maim.'
      );
    }
    return true;
  }

  if (process.platform === 'win32') {
    // Snipping Tool puts the region on the clipboard; poll for it.
    clipboard.clear();
    spawn('explorer.exe', ['ms-screenclip:'], { detached: true, stdio: 'ignore' }).unref();
    const deadline = Date.now() + 60_000;
    while (Date.now() < deadline) {
      const image = clipboard.readImage();
      if (!image.isEmpty()) {
        fs.writeFileSync(file, image.toPNG());
        return true;
      }
      await sleep(250);
    }
    return false;
  }

  throw new Error(`Screenshot capture is not supported on ${process.platform}`);
}

async function captureScreenshot(dirs) {
  const capturedAt = new Date().toISOString();
  const file = path.join(dirs.captures, `${crypto.randomUUID()}.png`);
  const ok = await captureRegionToFile(file);
  if (!ok) {
    throw new Error('Screenshot cancelled or empty');
  }
  return { kind: 'image', source: 'screenshot', capturedAt, file };
}

module.exports = { captureScreenshot };
