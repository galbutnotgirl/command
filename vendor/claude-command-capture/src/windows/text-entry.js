'use strict';

// Small always-on-top window for typing a quick submission. Resolves with a
// text capture, or null if the user cancels/closes it.

const path = require('path');
const { BrowserWindow, ipcMain } = require('electron');

let openWindow = null;

function showTextEntry() {
  return new Promise((resolve) => {
    if (openWindow) {
      openWindow.focus();
      resolve(null);
      return;
    }

    const win = new BrowserWindow({
      width: 560,
      height: 240,
      frame: false,
      resizable: true,
      alwaysOnTop: true,
      skipTaskbar: true,
      show: false,
      webPreferences: {
        preload: path.join(__dirname, 'preload-text-entry.js'),
        contextIsolation: true,
        nodeIntegration: false,
      },
    });
    openWindow = win;

    let settled = false;
    const settle = (value) => {
      if (settled) return;
      settled = true;
      cleanup();
      resolve(value);
      if (!win.isDestroyed()) win.close();
    };

    const onSubmit = (event, text) => {
      if (event.sender !== win.webContents) return;
      if (text && text.trim()) {
        settle({
          kind: 'text',
          source: 'text',
          capturedAt: new Date().toISOString(),
          text,
        });
      } else {
        settle(null);
      }
    };
    const onCancel = (event) => {
      if (event.sender !== win.webContents) return;
      settle(null);
    };
    const cleanup = () => {
      ipcMain.removeListener('text-entry:submit', onSubmit);
      ipcMain.removeListener('text-entry:cancel', onCancel);
      openWindow = null;
    };

    ipcMain.on('text-entry:submit', onSubmit);
    ipcMain.on('text-entry:cancel', onCancel);
    win.on('closed', () => settle(null));

    win.loadFile(path.join(__dirname, '..', '..', 'renderer', 'text-entry.html'));
    win.once('ready-to-show', () => {
      win.show();
      win.focus();
    });
  });
}

module.exports = { showTextEntry };
