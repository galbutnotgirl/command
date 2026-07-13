'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { runCli, buildArgs, extractResult, redactArgs } = require('../src/runner');

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

test('buildArgs creates Codex exec invocation with images before stdin marker', () => {
  assert.deepStrictEqual(
    buildArgs({ baseArgs: ['exec'], extraArgs: ['--sandbox', 'read-only'] },
      { provider: 'codex', attachments: ['/tmp/a.png', '/tmp/b.png'] }),
    ['exec', '--sandbox', 'read-only', '-i', '/tmp/a.png', '-i', '/tmp/b.png', '-']
  );
});

test('redactArgs hides common secret-bearing flags without changing safe args', () => {
  assert.deepStrictEqual(
    redactArgs(['--sandbox', 'read-only', '--api-key', 'secret-value', '--token=abc']),
    ['--sandbox', 'read-only', '--api-key', '[REDACTED]', '--token=[REDACTED]']
  );
});

test('runCli pipes the prompt to stdin and logs output', async () => {
  const logFile = tmpFile('run.log');
  // `cat` echoes stdin -> stdout, standing in for the claude CLI.
  const { exitCode, error, result } = await runCli({
    cli: { command: 'cat', baseArgs: [], extraArgs: [], cwd: '' },
    prompt: 'hello from test\n',
    logFile,
  });
  assert.strictEqual(exitCode, 0);
  assert.strictEqual(error, null);
  assert.strictEqual(result, null); // "hello from test" isn't a KEY=value line
  const log = fs.readFileSync(logFile, 'utf8');
  assert.ok(log.includes('hello from test'));
  assert.ok(log.includes('exited with code 0'));
});

test('runCli extracts a structured result from the last stdout line', async () => {
  const logFile = tmpFile('result.log');
  const { exitCode, result } = await runCli({
    cli: { command: 'cat', baseArgs: [], extraArgs: [], cwd: '' },
    prompt: 'some prose\n\nTASK_ID=abc123\n',
    logFile,
  });
  assert.strictEqual(exitCode, 0);
  assert.strictEqual(result, 'TASK_ID=abc123');
});

// ---- extractResult (pure) ---------------------------------------------------

test('extractResult reads the last non-empty line when it matches KEY=value', () => {
  assert.strictEqual(extractResult('some prose\nTASK_ID=abc123\n'), 'TASK_ID=abc123');
  assert.strictEqual(extractResult('ERROR=could not reach api\n'), 'ERROR=could not reach api');
});

test('extractResult ignores trailing blank lines', () => {
  assert.strictEqual(extractResult('TASK_ID=abc123\n\n\n'), 'TASK_ID=abc123');
});

test('extractResult returns null when the last line is prose', () => {
  assert.strictEqual(extractResult('TASK_ID=abc123\nbut then it kept talking\n'), null);
});

test('extractResult returns null for empty or whitespace-only stdout', () => {
  assert.strictEqual(extractResult(''), null);
  assert.strictEqual(extractResult('   \n  \n'), null);
});

test('extractResult requires the whole trimmed line to match (not just a substring)', () => {
  assert.strictEqual(extractResult('the value was TASK_ID=abc123 apparently'), null);
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
