'use strict';

// Settings window. IPC handlers are registered once; the window is a
// singleton. `onSaved` lets main.js re-register hotkeys after changes.

const path = require('path');
const { BrowserWindow, ipcMain } = require('electron');
const { execFile } = require('child_process');
const { loadSettings, saveSettings, DEFAULT_SETTINGS } = require('../settings');

let settingsWindow = null;
let registered = false;

function registerIpc({ baseDir, onSaved }) {
  if (registered) return;
  registered = true;

  ipcMain.handle('settings:get', () => ({
    settings: loadSettings(baseDir),
    defaults: DEFAULT_SETTINGS,
  }));

  ipcMain.handle('settings:save', (_event, settings) => {
    const merged = saveSettings(baseDir, settings);
    if (onSaved) onSaved(merged);
    return merged;
  });

  // Sanity check that the configured CLI is reachable.
  ipcMain.handle('settings:test-cli', async (_event, command) => {
    return new Promise((resolve) => {
      execFile(command || 'claude', ['--version'], { timeout: 15_000 }, (err, stdout, stderr) => {
        if (err) {
          resolve({ ok: false, output: err.message + (stderr ? `\n${stderr}` : '') });
        } else {
          resolve({ ok: true, output: String(stdout).trim() });
        }
      });
    });
  });
}

function showSettings({ baseDir, onSaved }) {
  registerIpc({ baseDir, onSaved });

  if (settingsWindow && !settingsWindow.isDestroyed()) {
    settingsWindow.show();
    settingsWindow.focus();
    return settingsWindow;
  }

  settingsWindow = new BrowserWindow({
    width: 640,
    height: 720,
    title: 'ClaudeCommand Settings',
    show: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload-settings.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });

  settingsWindow.loadFile(path.join(__dirname, '..', '..', 'renderer', 'settings.html'));
  settingsWindow.once('ready-to-show', () => {
    settingsWindow.show();
    settingsWindow.focus();
  });
  settingsWindow.on('closed', () => {
    settingsWindow = null;
  });
  return settingsWindow;
}

module.exports = { showSettings };
