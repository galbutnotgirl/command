'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { appDirs } = require('../src/paths');
const { submitCapture, resubmitPrompt } = require('../src/submit');
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

  assert.ok(notifications.some((n) => n.title === 'Submitted in Command'));
  assert.ok(notifications.some((n) => n.title === 'Background action finished'));
});

test('submitCapture extracts a structured result and includes it in the finish notification', async () => {
  const dirs = tmpDirs();
  const notifications = [];
  // The default text template puts {content} last, so a capture whose text IS
  // the result line survives to the end of what `cat` echoes back.
  const { donePromise } = submitCapture({
    dirs,
    settings: fakeCliSettings(),
    capture: { kind: 'text', source: 'selection', capturedAt: '', text: 'TASK_ID=abc123' },
    notify: (title, body) => notifications.push({ title, body }),
  });
  const finished = await donePromise;
  assert.strictEqual(finished.result, 'TASK_ID=abc123');
  const done = notifications.find((n) => n.title === 'Background action finished');
  assert.ok(done);
  assert.ok(done.body.includes('TASK_ID=abc123'));
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
  const failure = notifications.find((n) => n.title === 'Background action failed');
  assert.ok(failure);
  assert.ok(failure.body.includes(finished.logFile));
});

test('resubmitPrompt reruns the exact prompt without re-rendering it', async () => {
  const dirs = tmpDirs();
  const originalPrompt = '/triage-capture\n\nSource: selection\n\nsome captured text';
  const { record, donePromise } = resubmitPrompt({
    dirs,
    settings: fakeCliSettings(),
    prompt: originalPrompt,
    source: 'selection',
    kind: 'text',
    skill: 'triage-capture',
    notify: () => {},
  });
  // A fresh id/log — never collides with (or overwrites) the record being retried.
  assert.strictEqual(record.prompt, originalPrompt);
  assert.strictEqual(record.status, 'running');
  const finished = await donePromise;
  assert.strictEqual(finished.status, 'succeeded');
  assert.strictEqual(finished.prompt, originalPrompt);
});

test('resubmitPrompt marks failures the same way submitCapture does', async () => {
  const dirs = tmpDirs();
  const notifications = [];
  const { donePromise } = resubmitPrompt({
    dirs,
    settings: fakeCliSettings({ cli: { command: 'no-such-cli-abc', baseArgs: [], extraArgs: [], cwd: '' } }),
    prompt: 'retry me',
    source: 'selection',
    kind: 'text',
    skill: null,
    notify: (title, body) => notifications.push({ title, body }),
  });
  const finished = await donePromise;
  assert.strictEqual(finished.status, 'failed');
  assert.ok(notifications.some((n) => n.title === 'Background action failed'));

});

test('Codex submissions record provider, workspace, and image attachment', async () => {
  const dirs = tmpDirs();
  const imageFile = path.join(os.tmpdir(), 'codex-shot.png');
  const settings = fakeCliSettings({ cli: { command: 'cat', baseArgs: [], extraArgs: [], cwd: '' } });
  settings.provider = 'codex';
  settings.workspace = '/tmp/workspace';
  const { record, donePromise } = submitCapture({
    dirs, settings,
    capture: { kind: 'image', source: 'screenshot', capturedAt: '', file: imageFile },
    notify: () => {},
  });
  assert.strictEqual(record.provider, 'codex');
  assert.strictEqual(record.workspace, '/tmp/workspace');
  assert.deepStrictEqual(record.attachments, [imageFile]);
  await donePromise;
});
