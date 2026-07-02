'use strict';

// ClaudeCommand — background capture to a Claude Code CLI skill.
//
// This app owns capture + handoff only: it grabs text / clipboard /
// highlighted selection / screenshot, renders a prompt from the
// settings-defined template (which names the skill), and runs `claude -p`
// in the background. What happens after that handoff belongs to the skill
// and to downstream apps (see docs/HANDOFF.md).

const path = require('path');
const {
  app,
  Tray,
  Menu,
  Notification,
  globalShortcut,
  nativeImage,
  shell,
} = require('electron');

const { appDirs, ensureDirs } = require('./paths');
const { loadSettings } = require('./settings');
const { submitCapture } = require('./submit');
const { captureFrom } = require('./capture');
const { showSettings } = require('./windows/settings');
const { listSubmissions } = require('./submissions');

let tray = null;
let dirs = null;

const SOURCE_LABELS = {
  text: 'Submit Text…',
  clipboard: 'Submit Clipboard',
  selection: 'Submit Highlighted Selection',
  screenshot: 'Submit Screenshot…',
};

function notify(title, body) {
  const settings = loadSettings(dirs.base);
  if (!settings.notifications) return;
  try {
    new Notification({ title, body }).show();
  } catch {
    // Notifications are best-effort (may be unavailable unbundled/unsigned).
  }
}

async function handleCapture(source) {
  try {
    // Check configuration before capturing so nothing the user types or
    // snips gets discarded.
    const settings = loadSettings(dirs.base);
    if (!settings.skill || !settings.skill.trim()) {
      notify('ClaudeCommand', 'No skill configured yet — opening Settings.');
      openSettings();
      return;
    }
    const capture = await captureFrom(source, ensureDirs(dirs));
    if (!capture) return; // user cancelled
    const { donePromise } = submitCapture({ dirs, settings, capture, notify });
    rebuildTrayMenu();
    donePromise.then(rebuildTrayMenu);
  } catch (err) {
    notify('Capture failed', err.message);
  }
}

function openSettings() {
  showSettings({
    baseDir: dirs.base,
    onSaved: (settings) => {
      registerHotkeys(settings);
      rebuildTrayMenu();
    },
  });
}

function registerHotkeys(settings) {
  globalShortcut.unregisterAll();
  for (const [source, accelerator] of Object.entries(settings.hotkeys || {})) {
    if (!accelerator || !accelerator.trim()) continue;
    try {
      const ok = globalShortcut.register(accelerator, () => handleCapture(source));
      if (!ok) {
        notify('ClaudeCommand', `Could not register hotkey "${accelerator}" (already in use?)`);
      }
    } catch (err) {
      notify('ClaudeCommand', `Invalid hotkey "${accelerator}": ${err.message}`);
    }
  }
}

function recentSubmissionsMenu() {
  const records = listSubmissions(dirs, 8);
  if (records.length === 0) {
    return [{ label: 'No submissions yet', enabled: false }];
  }
  const icon = { running: '…', succeeded: '✓', failed: '✗' };
  return records.map((record) => ({
    label: `${icon[record.status] || '?'} ${record.source} → ${record.skill ? '/' + record.skill : '(no skill)'} · ${record.createdAt.slice(0, 16).replace('T', ' ')}`,
    click: () => {
      if (record.logFile) shell.openPath(record.logFile);
    },
  }));
}

function buildTrayMenu() {
  const settings = loadSettings(dirs.base);
  const captureItems = Object.entries(SOURCE_LABELS).map(([source, label]) => ({
    label,
    accelerator: settings.hotkeys[source] || undefined,
    click: () => handleCapture(source),
  }));

  return Menu.buildFromTemplate([
    {
      label: settings.skill ? `Skill: /${settings.skill}` : 'No skill configured',
      enabled: false,
    },
    { type: 'separator' },
    ...captureItems,
    { type: 'separator' },
    { label: 'Recent Submissions', submenu: recentSubmissionsMenu() },
    { label: 'Open Data Folder', click: () => shell.openPath(dirs.base) },
    { type: 'separator' },
    { label: 'Settings…', click: openSettings },
    { label: 'Quit ClaudeCommand', click: () => app.quit() },
  ]);
}

function rebuildTrayMenu() {
  if (tray) tray.setContextMenu(buildTrayMenu());
}

function createTray() {
  const iconPath = path.join(
    __dirname,
    '..',
    'assets',
    process.platform === 'darwin' ? 'trayTemplate.png' : 'tray.png'
  );
  let icon = nativeImage.createFromPath(iconPath);
  if (icon.isEmpty()) icon = nativeImage.createEmpty();
  if (process.platform === 'darwin') icon.setTemplateImage(true);

  tray = new Tray(icon);
  tray.setToolTip('ClaudeCommand — capture to a Claude Code skill');
  rebuildTrayMenu();
  // Rebuild lazily so "Recent Submissions" is fresh when the menu opens.
  tray.on('click', rebuildTrayMenu);
  tray.on('right-click', rebuildTrayMenu);
}

const gotLock = app.requestSingleInstanceLock();
if (!gotLock) {
  app.quit();
} else {
  app.whenReady().then(() => {
    dirs = ensureDirs(appDirs(app.getPath('userData')));

    // Menu-bar app: no dock icon, no main window.
    if (process.platform === 'darwin' && app.dock) app.dock.hide();

    createTray();
    registerHotkeys(loadSettings(dirs.base));

    const settings = loadSettings(dirs.base);
    if (!settings.skill) openSettings();
  });

  app.on('window-all-closed', () => {
    // Keep running in the tray; do not quit when windows close.
  });

  app.on('will-quit', () => {
    globalShortcut.unregisterAll();
  });
}
