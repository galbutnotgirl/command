'use strict';

// End-to-end tests for the headless CLI shim (bin/submit-cli.js) used by
// native capture layers. Uses a fake "claude" (node echo script) via
// settings.json, same as the pipeline tests.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFile } = require('child_process');

const SHIM = path.join(__dirname, '..', 'bin', 'submit-cli.js');

function tmpBase() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'submit-cli-'));
}

// Fake CLI: reads stdin, writes it to stdout, exits with the given code.
function writeFakeCli(dir, exitCode = 0) {
  const script = path.join(dir, 'fake-cli.js');
  fs.writeFileSync(
    script,
    `let d='';process.stdin.on('data',c=>d+=c);` +
      `process.stdin.on('end',()=>{process.stdout.write('SAW: '+d);process.exit(${exitCode});});`
  );
  return script;
}

function writeSettings(base, cliScript, extra = {}) {
  fs.mkdirSync(base, { recursive: true });
  fs.writeFileSync(
    path.join(base, 'settings.json'),
    JSON.stringify({
      skill: 'triage-capture',
      cli: { command: process.execPath, baseArgs: [cliScript], extraArgs: [], cwd: base },
      notifications: false,
      ...extra,
    })
  );
}

function runShim(args, { input = '', env = {} } = {}) {
  return new Promise((resolve) => {
    const child = execFile(
      process.execPath,
      [SHIM, ...args],
      { env: { ...process.env, ...env } },
      (err, stdout, stderr) => resolve({ code: err ? err.code ?? 1 : 0, stdout, stderr })
    );
    child.stdin.write(input);
    child.stdin.end();
  });
}

test('text capture on stdin runs the pipeline and exits 0', async () => {
  const base = tmpBase();
  writeSettings(base, writeFakeCli(base));

  const { code, stdout, stderr } = await runShim(
    ['--base-dir', base, '--source', 'selection', '--kind', 'text'],
    { input: 'hello from native' }
  );
  assert.strictEqual(code, 0, stderr);

  const lines = stdout.trim().split('\n').map((l) => JSON.parse(l));
  assert.strictEqual(lines.length, 2);
  assert.strictEqual(lines[0].status, 'running');
  assert.strictEqual(lines[1].status, 'succeeded');
  assert.strictEqual(lines[1].source, 'selection');
  assert.strictEqual(lines[1].skill, 'triage-capture');

  // Durable artifacts per the handoff contract.
  assert.strictEqual(fs.readFileSync(lines[1].contentFile, 'utf8'), 'hello from native');
  const log = fs.readFileSync(lines[1].logFile, 'utf8');
  assert.match(log, /SAW: \/triage-capture/);
  assert.match(log, /hello from native/);
  const record = JSON.parse(
    fs.readFileSync(path.join(base, 'submissions', `${lines[1].id}.json`), 'utf8')
  );
  assert.strictEqual(record.status, 'succeeded');
});

test('image capture passes the file path through the prompt', async () => {
  const base = tmpBase();
  writeSettings(base, writeFakeCli(base));
  const png = path.join(base, 'shot.png');
  fs.writeFileSync(png, 'not-really-a-png');

  const { code, stdout } = await runShim([
    '--base-dir', base, '--source', 'screenshot', '--kind', 'image', '--file', png,
  ]);
  assert.strictEqual(code, 0);
  const final = JSON.parse(stdout.trim().split('\n').pop());
  assert.strictEqual(final.kind, 'image');
  assert.strictEqual(final.contentFile, png);
  assert.match(fs.readFileSync(final.logFile, 'utf8'), new RegExp(`saved to: ${png}`));
});

test('CLI failure surfaces as exit 1 and a failed record', async () => {
  const base = tmpBase();
  writeSettings(base, writeFakeCli(base, 3));

  const { code, stdout } = await runShim(
    ['--base-dir', base, '--source', 'clipboard'],
    { input: 'doomed' }
  );
  assert.strictEqual(code, 1);
  const final = JSON.parse(stdout.trim().split('\n').pop());
  assert.strictEqual(final.status, 'failed');
  assert.strictEqual(final.exitCode, 3);
});

test('empty text and missing image file are usage errors (exit 2)', async () => {
  const base = tmpBase();
  writeSettings(base, writeFakeCli(base));

  assert.strictEqual((await runShim(['--base-dir', base], { input: '  ' })).code, 2);
  assert.strictEqual(
    (await runShim(['--base-dir', base, '--kind', 'image', '--file', path.join(base, 'nope.png')])).code,
    2
  );
});

test('--init-settings scaffolds defaults and never overwrites', async () => {
  const base = tmpBase();
  const first = await runShim(['--base-dir', base, '--init-settings']);
  assert.strictEqual(first.code, 0);
  const settingsFile = path.join(base, 'settings.json');
  assert.ok(fs.existsSync(settingsFile));

  fs.writeFileSync(settingsFile, JSON.stringify({ skill: 'keep-me' }));
  const second = await runShim(['--base-dir', base, '--init-settings']);
  assert.strictEqual(second.code, 0);
  assert.match(second.stdout, /already exist/);
  assert.strictEqual(JSON.parse(fs.readFileSync(settingsFile, 'utf8')).skill, 'keep-me');
});

test('CLAUDE_CAPTURE_HOME selects the base dir', async () => {
  const base = tmpBase();
  writeSettings(base, writeFakeCli(base));

  const { code, stdout } = await runShim(['--source', 'text'], {
    input: 'via env',
    env: { CLAUDE_CAPTURE_HOME: base },
  });
  assert.strictEqual(code, 0);
  const final = JSON.parse(stdout.trim().split('\n').pop());
  assert.ok(final.contentFile.startsWith(base));
});
