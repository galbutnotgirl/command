'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { appDirs, ensureDirs } = require('../src/paths');
const { createSubmission, updateSubmission, listSubmissions } = require('../src/submissions');

function tmpDirs() {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'claude-command-test-'));
  return ensureDirs(appDirs(base));
}

test('createSubmission writes a well-formed record', () => {
  const dirs = tmpDirs();
  const record = createSubmission(dirs, {
    source: 'clipboard',
    kind: 'text',
    skill: 's',
    prompt: 'p',
    contentFile: '/x.txt',
    logFile: '/x.log',
  });
  assert.ok(record.id);
  assert.strictEqual(record.status, 'running');
  const onDisk = JSON.parse(
    fs.readFileSync(path.join(dirs.submissions, `${record.id}.json`), 'utf8')
  );
  assert.deepStrictEqual(onDisk, record);
});

test('updateSubmission patches and persists', () => {
  const dirs = tmpDirs();
  const record = createSubmission(dirs, { source: 'text', kind: 'text', prompt: 'p' });
  const updated = updateSubmission(dirs, record.id, { status: 'succeeded', exitCode: 0 });
  assert.strictEqual(updated.status, 'succeeded');
  assert.strictEqual(updated.exitCode, 0);
  const onDisk = JSON.parse(
    fs.readFileSync(path.join(dirs.submissions, `${record.id}.json`), 'utf8')
  );
  assert.strictEqual(onDisk.status, 'succeeded');
});

test('listSubmissions returns newest first and respects limit', () => {
  const dirs = tmpDirs();
  const a = createSubmission(dirs, { source: 'text', kind: 'text', prompt: 'a' });
  // Force distinct createdAt ordering.
  updateSubmission(dirs, a.id, { createdAt: '2026-01-01T00:00:00Z' });
  const b = createSubmission(dirs, { source: 'text', kind: 'text', prompt: 'b' });
  updateSubmission(dirs, b.id, { createdAt: '2026-02-01T00:00:00Z' });

  const all = listSubmissions(dirs);
  assert.strictEqual(all[0].id, b.id);
  assert.strictEqual(all[1].id, a.id);
  assert.strictEqual(listSubmissions(dirs, 1).length, 1);
});

test('listSubmissions on empty/missing dir returns []', () => {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'claude-command-test-'));
  assert.deepStrictEqual(listSubmissions(appDirs(base)), []);
});

test('submission metadata is additive and defaults legacy records to Claude', () => {
  const dirs = tmpDirs();
  const legacy = createSubmission(dirs, { source: 'text', kind: 'text', prompt: 'p' });
  assert.strictEqual(legacy.provider, 'claude');
  assert.deepStrictEqual(legacy.attachments, []);
  const codex = createSubmission(dirs, {
    source: 'screenshot', kind: 'image', prompt: 'p', provider: 'codex',
    workspace: '/repo', attachments: ['/tmp/a.png'],
  });
  assert.strictEqual(codex.provider, 'codex');
  assert.strictEqual(codex.workspace, '/repo');
  assert.deepStrictEqual(codex.attachments, ['/tmp/a.png']);
});
