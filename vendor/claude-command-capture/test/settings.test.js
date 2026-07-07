'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const {
  DEFAULT_SETTINGS,
  loadSettings,
  saveSettings,
  mergeSettings,
  resolveCwd,
} = require('../src/settings');

function tmpDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'claude-command-test-'));
}

test('loadSettings returns defaults when no file exists', () => {
  const dir = tmpDir();
  const settings = loadSettings(dir);
  assert.deepStrictEqual(settings, DEFAULT_SETTINGS);
});

test('loadSettings returns defaults on corrupt file', () => {
  const dir = tmpDir();
  fs.writeFileSync(path.join(dir, 'settings.json'), '{not json');
  assert.deepStrictEqual(loadSettings(dir), DEFAULT_SETTINGS);
});

test('save/load roundtrip preserves values', () => {
  const dir = tmpDir();
  const settings = loadSettings(dir);
  settings.skill = 'my-skill';
  settings.cli.extraArgs = ['--permission-mode', 'acceptEdits'];
  saveSettings(dir, settings);
  const loaded = loadSettings(dir);
  assert.strictEqual(loaded.skill, 'my-skill');
  assert.deepStrictEqual(loaded.cli.extraArgs, ['--permission-mode', 'acceptEdits']);
});

test('mergeSettings backfills fields missing from stored settings', () => {
  const merged = mergeSettings(DEFAULT_SETTINGS, { skill: 'x' });
  assert.strictEqual(merged.skill, 'x');
  assert.strictEqual(merged.cli.command, 'claude');
  assert.strictEqual(merged.hotkeys.text, DEFAULT_SETTINGS.hotkeys.text);
});

test('mergeSettings keeps nested overrides', () => {
  const merged = mergeSettings(DEFAULT_SETTINGS, { cli: { command: '/usr/local/bin/claude' } });
  assert.strictEqual(merged.cli.command, '/usr/local/bin/claude');
  assert.deepStrictEqual(merged.cli.baseArgs, ['-p']);
});

test('resolveCwd falls back to home and expands ~', () => {
  assert.strictEqual(resolveCwd(''), os.homedir());
  assert.strictEqual(resolveCwd('  '), os.homedir());
  assert.strictEqual(resolveCwd('~'), os.homedir());
  assert.strictEqual(resolveCwd('~/projects'), path.join(os.homedir(), 'projects'));
  assert.strictEqual(resolveCwd('/abs/path'), '/abs/path');
});
