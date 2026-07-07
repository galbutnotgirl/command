'use strict';

// Settings persistence. Electron-free on purpose: everything takes a base
// directory so it can be unit-tested without a running app. The Electron
// layer passes app.getPath('userData').

const fs = require('fs');
const os = require('os');
const path = require('path');

// {skillInvocation} renders as "/<skill>" when a skill is configured and ""
// otherwise, so the same template works with or without a skill.
const DEFAULT_TEXT_TEMPLATE = [
  '{skillInvocation}',
  '',
  'Source: {source}',
  'Captured at: {timestamp}',
  '',
  '{content}',
].join('\n');

const DEFAULT_IMAGE_TEMPLATE = [
  '{skillInvocation}',
  '',
  'Source: {source}',
  'Captured at: {timestamp}',
  '',
  'A captured image was saved to: {file}',
  'Read that file to view the capture.',
].join('\n');

const DEFAULT_SETTINGS = {
  // Name of the Claude Code skill (slash command) that should process
  // captures. The skill itself lives elsewhere; this app only invokes it.
  skill: '',
  // Prompt templates. Placeholders: {skillInvocation} {skill} {source}
  // {timestamp} {content} {file}
  promptTemplate: DEFAULT_TEXT_TEMPLATE,
  imagePromptTemplate: DEFAULT_IMAGE_TEMPLATE,
  cli: {
    // Command used to reach the Claude Code CLI. Absolute path or something
    // resolvable on PATH.
    command: 'claude',
    // Args that make the CLI read a prompt non-interactively. The prompt is
    // written to stdin, never passed as an argument.
    baseArgs: ['-p'],
    // Extra args appended verbatim, e.g. ["--permission-mode", "acceptEdits"].
    extraArgs: [],
    // Working directory for the CLI process. Empty -> home directory.
    cwd: '',
  },
  hotkeys: {
    text: 'CommandOrControl+Alt+T',
    clipboard: 'CommandOrControl+Alt+V',
    selection: 'CommandOrControl+Alt+H',
    screenshot: 'CommandOrControl+Alt+S',
  },
  notifications: true,
};

function settingsPath(baseDir) {
  return path.join(baseDir, 'settings.json');
}

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

// Recursively overlay stored settings on top of the defaults so that new
// fields added in later versions pick up their default values.
function mergeSettings(defaults, stored) {
  if (!isPlainObject(stored)) return structuredClone(defaults);
  const merged = {};
  for (const key of Object.keys(defaults)) {
    const defVal = defaults[key];
    const storedVal = stored[key];
    if (isPlainObject(defVal)) {
      merged[key] = mergeSettings(defVal, storedVal);
    } else if (storedVal === undefined) {
      merged[key] = structuredClone(defVal);
    } else {
      merged[key] = structuredClone(storedVal);
    }
  }
  return merged;
}

function loadSettings(baseDir) {
  try {
    const raw = fs.readFileSync(settingsPath(baseDir), 'utf8');
    return mergeSettings(DEFAULT_SETTINGS, JSON.parse(raw));
  } catch {
    return structuredClone(DEFAULT_SETTINGS);
  }
}

function saveSettings(baseDir, settings) {
  const merged = mergeSettings(DEFAULT_SETTINGS, settings);
  fs.mkdirSync(baseDir, { recursive: true });
  const target = settingsPath(baseDir);
  const tmp = target + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(merged, null, 2) + '\n');
  fs.renameSync(tmp, target);
  return merged;
}

// Expand "~" and fall back to the home directory so the CLI always gets a
// valid cwd.
function resolveCwd(cwd) {
  if (!cwd || !cwd.trim()) return os.homedir();
  let resolved = cwd.trim();
  if (resolved === '~') return os.homedir();
  if (resolved.startsWith('~/') || resolved.startsWith('~\\')) {
    resolved = path.join(os.homedir(), resolved.slice(2));
  }
  return resolved;
}

module.exports = {
  DEFAULT_SETTINGS,
  loadSettings,
  saveSettings,
  mergeSettings,
  resolveCwd,
  settingsPath,
};
