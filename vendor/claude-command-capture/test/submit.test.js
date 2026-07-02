'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { appDirs } = require('../src/paths');
const { submitCapture } = require('../src/submit');
const { DEFAULT_SETTINGS, mergeSettings } = require('../src/settings');

function tmpDirs() {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'claude-command-test-'));
  return appDirs(base);
}

// A settings object whose "CLI" is plain `cat`, so the pipeline runs for real
// without the actual claude binary.
function fakeCliSettings(overrides = {}) {
  return mergeSettings(DEFAULT_SETTINGS, {
    skill: 'triage-capture',
    cli: { command: 'cat', baseArgs: [], extraArgs: [], cwd: '' },
    ...overrides,
  });
}

test('submitCapture runs the full pipeline for a text capture', async () => {
  const dirs = tmpDirs();
  const notifications = [];
  const { record, donePromise } = submitCapture({
    dirs,
    settings: fakeCliSettings(),
    capture: {
      kind: 'text',
      source: 'selection',
      capturedAt: '2026-07-02T12:00:00Z',
      text: 'highlighted words',
    },
    notify: (title, body) => notifications.push({ title, body }),
  });

  assert.strictEqual(record.status, 'running');
  assert.strictEqual(record.skill, 'triage-capture');
  assert.ok(record.prompt.startsWith('/triage-capture'));
  assert.strictEqual(fs.readFileSync(record.contentFile, 'utf8'), 'highlighted words');

  const finished = await donePromise;
  assert.strictEqual(finished.status, 'succeeded');
  assert.strictEqual(finished.exitCode, 0);
  assert.ok(finished.finishedAt);

  // The prompt (with the captured text) was piped to the CLI's stdin — `cat`
  // echoed it into the log.
  const log = fs.readFileSync(record.logFile, 'utf8');
  assert.ok(log.includes('highlighted words'));

  assert.ok(notifications.some((n) => n.title === 'Submitted to Claude'));
  assert.ok(notifications.some((n) => n.title === 'Claude finished'));
});

test('submitCapture keeps the image file as contentFile', async () => {
  const dirs = tmpDirs();
  const imageFile = path.join(os.tmpdir(), 'fake-shot.png');
  const { record, donePromise } = submitCapture({
    dirs,
    settings: fakeCliSettings(),
    capture: {
      kind: 'image',
      source: 'screenshot',
      capturedAt: '2026-07-02T12:00:00Z',
      file: imageFile,
    },
    notify: () => {},
  });
  assert.strictEqual(record.contentFile, imageFile);
  assert.ok(record.prompt.includes(imageFile));
  await donePromise;
});

test('submitCapture marks failures and notifies with the log path', async () => {
  const dirs = tmpDirs();
  const notifications = [];
  const { donePromise } = submitCapture({
    dirs,
    settings: fakeCliSettings({ cli: { command: 'no-such-cli-abc', baseArgs: [], extraArgs: [], cwd: '' } }),
    capture: { kind: 'text', source: 'text', capturedAt: '', text: 'x' },
    notify: (title, body) => notifications.push({ title, body }),
  });
  const finished = await donePromise;
  assert.strictEqual(finished.status, 'failed');
  assert.ok(finished.error);
  const failure = notifications.find((n) => n.title === 'Claude submission failed');
  assert.ok(failure);
  assert.ok(failure.body.includes(finished.logFile));
});
