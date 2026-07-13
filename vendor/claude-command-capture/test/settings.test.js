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
  settingsForProvider,
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

test('mergeSettings preserves unknown top-level and nested provider keys', () => {
  const merged = mergeSettings(DEFAULT_SETTINGS, {
    futureTopLevel: { enabled: true },
    providers: { codex: { futureOption: 'kept' } },
  });
  assert.deepStrictEqual(merged.futureTopLevel, { enabled: true });
  assert.strictEqual(merged.providers.codex.futureOption, 'kept');
  assert.strictEqual(merged.providers.codex.command, 'codex');
});

test('resolveCwd falls back to home and expands ~', () => {
  assert.strictEqual(resolveCwd(''), os.homedir());
  assert.strictEqual(resolveCwd('  '), os.homedir());
  assert.strictEqual(resolveCwd('~'), os.homedir());
  assert.strictEqual(resolveCwd('~/projects'), path.join(os.homedir(), 'projects'));
  assert.strictEqual(resolveCwd('/abs/path'), '/abs/path');
});

test('legacy cli migrates into Claude provider without changing Codex defaults', () => {
  const dir = tmpDir();
  fs.writeFileSync(path.join(dir, 'settings.json'), JSON.stringify({
    cli: { command: '/legacy/claude', extraArgs: ['--legacy'] },
  }));
  const loaded = loadSettings(dir);
  assert.strictEqual(loaded.providers.claude.command, '/legacy/claude');
  assert.deepStrictEqual(loaded.providers.claude.extraArgs, ['--legacy']);
  assert.strictEqual(loaded.providers.codex.command, 'codex');
});

test('settingsForProvider selects provider-specific command and workspace', () => {
  const settings = mergeSettings(DEFAULT_SETTINGS, {
    providers: { codex: { command: '/bin/codex', cwd: '/repo' } },
  });
  const selected = settingsForProvider(settings, 'codex');
  assert.strictEqual(selected.provider, 'codex');
  assert.strictEqual(selected.cli.command, '/bin/codex');
  assert.strictEqual(selected.workspace, '/repo');
});
