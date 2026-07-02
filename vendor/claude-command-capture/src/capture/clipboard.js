'use strict';

// Capture whatever is currently on the clipboard: text preferred, image as a
// fallback (saved to the captures directory as PNG).

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { clipboard } = require('electron');

function saveClipboardImage(dirs) {
  const image = clipboard.readImage();
  if (image.isEmpty()) return null;
  const file = path.join(dirs.captures, `${crypto.randomUUID()}.png`);
  fs.writeFileSync(file, image.toPNG());
  return file;
}

async function captureClipboard(dirs) {
  const capturedAt = new Date().toISOString();
  const text = clipboard.readText();
  if (text && text.trim()) {
    return { kind: 'text', source: 'clipboard', capturedAt, text };
  }
  const file = saveClipboardImage(dirs);
  if (file) {
    return { kind: 'image', source: 'clipboard', capturedAt, file };
  }
  throw new Error('Clipboard has no text or image content');
}

module.exports = { captureClipboard, saveClipboardImage };
