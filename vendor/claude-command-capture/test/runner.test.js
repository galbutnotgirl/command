'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { runCli, buildArgs } = require('../src/runner');

function tmpFile(name) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'claude-command-test-'));
  return path.join(dir, name);
}

test('buildArgs combines base and extra args', () => {
  assert.deepStrictEqual(
    buildArgs({ baseArgs: ['-p'], extraArgs: ['--permission-mode', 'acceptEdits'] }),
    ['-p', '--permission-mode', 'acceptEdits']
  );
  assert.deepStrictEqual(buildArgs({}), ['-p']);
});

test('runCli pipes the prompt to stdin and logs output', async () => {
  const logFile = tmpFile('run.log');
  // `cat` echoes stdin -> stdout, standing in for the claude CLI.
  const { exitCode, error } = await runCli({
    cli: { command: 'cat', baseArgs: [], extraArgs: [], cwd: '' },
    prompt: 'hello from test\n',
    logFile,
  });
  assert.strictEqual(exitCode, 0);
  assert.strictEqual(error, null);
  const log = fs.readFileSync(logFile, 'utf8');
  assert.ok(log.includes('hello from test'));
  assert.ok(log.includes('exited with code 0'));
});

test('runCli surfaces a missing CLI as an error, not a rejection', async () => {
  const logFile = tmpFile('missing.log');
  const { exitCode, error } = await runCli({
    cli: { command: 'definitely-not-a-real-cli-xyz', baseArgs: [], extraArgs: [], cwd: '' },
    prompt: 'x',
    logFile,
  });
  assert.strictEqual(exitCode, null);
  assert.ok(error && error.includes('ENOENT'));
});

test('runCli reports nonzero exit codes as failure', async () => {
  const logFile = tmpFile('fail.log');
  const { exitCode, error } = await runCli({
    cli: { command: 'sh', baseArgs: ['-c', 'exit 3'], extraArgs: [], cwd: '' },
    prompt: '',
    logFile,
  });
  assert.strictEqual(exitCode, 3);
  assert.ok(error.includes('code 3'));
});
