'use strict';

// Smoke tests for the Electron-dependent modules, run under plain Node by
// injecting a fake `electron` module. This catches wiring mistakes (bad
// imports, module-level throws) without needing a display server.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const Module = require('module');

// --- fake electron -----------------------------------------------------

const clipboardState = { text: '', imagePng: null };

const fakeImage = (png) => ({
  isEmpty: () => png == null,
  toPNG: () => png,
});

const fakeElectron = {
  app: {
    requestSingleInstanceLock: () => false, // main.js should quit quietly
    quit: () => {},
    whenReady: () => new Promise(() => {}),
    on: () => {},
    getPath: () => os.tmpdir(),
    dock: { hide: () => {} },
  },
  Tray: class {
    setToolTip() {}
    setContextMenu() {}
    on() {}
  },
  Menu: { buildFromTemplate: () => ({}) },
  Notification: class {
    show() {}
  },
  globalShortcut: { register: () => true, unregisterAll: () => {} },
  nativeImage: {
    createFromPath: () => ({ isEmpty: () => true, setTemplateImage: () => {} }),
    createEmpty: () => ({ setTemplateImage: () => {} }),
  },
  shell: { openPath: () => {} },
  BrowserWindow: class {
    loadFile() {}
    once() {}
    on() {}
    focus() {}
    show() {}
    close() {}
    isDestroyed() {
      return false;
    }
  },
  ipcMain: { on: () => {}, handle: () => {}, removeListener: () => {} },
  clipboard: {
    readText: () => clipboardState.text,
    writeText: (t) => {
      clipboardState.text = t;
    },
    readImage: () => fakeImage(clipboardState.imagePng),
    writeImage: () => {},
    clear: () => {
      clipboardState.text = '';
      clipboardState.imagePng = null;
    },
  },
};

const originalLoad = Module._load;
Module._load = function (request, parent, isMain) {
  if (request === 'electron') return fakeElectron;
  return originalLoad(request, parent, isMain);
};

// --- tests ---------------------------------------------------------------

function tmpDirs() {
  const { appDirs, ensureDirs } = require('../src/paths');
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'claude-command-smoke-'));
  return ensureDirs(appDirs(base));
}

test('main.js loads without throwing (single-instance lock denied path)', () => {
  assert.doesNotThrow(() => require('../src/main'));
});

test('window modules load without throwing', () => {
  assert.doesNotThrow(() => require('../src/windows/text-entry'));
  assert.doesNotThrow(() => require('../src/windows/settings'));
});

test('captureFrom rejects unknown sources', async () => {
  const { captureFrom } = require('../src/capture');
  await assert.rejects(() => captureFrom('nope', tmpDirs()), /Unknown capture source/);
});

test('clipboard capture returns text when clipboard has text', async () => {
  const { captureClipboard } = require('../src/capture/clipboard');
  clipboardState.text = 'copied stuff';
  clipboardState.imagePng = null;
  const capture = await captureClipboard(tmpDirs());
  assert.strictEqual(capture.kind, 'text');
  assert.strictEqual(capture.source, 'clipboard');
  assert.strictEqual(capture.text, 'copied stuff');
});

test('clipboard capture saves an image when clipboard has only an image', async () => {
  const { captureClipboard } = require('../src/capture/clipboard');
  clipboardState.text = '';
  clipboardState.imagePng = Buffer.from('fake-png-bytes');
  const dirs = tmpDirs();
  const capture = await captureClipboard(dirs);
  assert.strictEqual(capture.kind, 'image');
  assert.ok(capture.file.startsWith(dirs.captures));
  assert.strictEqual(fs.readFileSync(capture.file).toString(), 'fake-png-bytes');
});

test('clipboard capture throws on empty clipboard', async () => {
  const { captureClipboard } = require('../src/capture/clipboard');
  clipboardState.text = '';
  clipboardState.imagePng = null;
  await assert.rejects(() => captureClipboard(tmpDirs()), /no text or image/);
});
