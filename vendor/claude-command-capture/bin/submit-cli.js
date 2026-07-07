#!/usr/bin/env node
'use strict';

// Headless entry point for native (non-Electron) capture layers.
// Wraps the Electron-free core (settings -> prompt -> submit -> runner ->
// submissions) without touching it; the handoff contract in docs/HANDOFF.md
// is unchanged.
//
// Usage:
//   submit-cli.js --source selection --kind text          # text on stdin
//   submit-cli.js --source screenshot --kind image --file /abs/path.png
//   submit-cli.js --init-settings                          # scaffold settings.json
//   submit-cli.js --print-settings
//
// Options:
//   --base-dir <dir>   data directory (default: $CLAUDE_CAPTURE_HOME, else the
//                      platform path Electron's app.getPath('userData') would
//                      use for this app name, e.g.
//                      ~/Library/Application Support/claude-command on macOS)
//   --no-wait          exit after the submission record is written; the CLI
//                      keeps running detached
//   --quiet            suppress desktop notifications
//
// Output: the submission record as JSON on stdout (once when created; with
// --no-wait that is the only output, otherwise the final record follows).
// Exit code: 0 if the run succeeded, 1 if it failed, 2 on usage errors.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');
const { appDirs } = require('../src/paths');
const { loadSettings, saveSettings, settingsPath, DEFAULT_SETTINGS } = require('../src/settings');
const { submitCapture } = require('../src/submit');

function defaultBaseDir() {
  const name = 'claude-command'; // matches the Electron app's userData dir name
  if (process.platform === 'darwin') {
    return path.join(os.homedir(), 'Library', 'Application Support', name);
  }
  if (process.platform === 'win32') {
    return path.join(process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming'), name);
  }
  return path.join(process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config'), name);
}

function parseArgs(argv) {
  const args = { wait: true, quiet: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const next = () => {
      i += 1;
      if (i >= argv.length) throw new Error(`missing value for ${a}`);
      return argv[i];
    };
    switch (a) {
      case '--source': args.source = next(); break;
      case '--kind': args.kind = next(); break;
      case '--file': args.file = next(); break;
      case '--base-dir': args.baseDir = next(); break;
      case '--no-wait': args.wait = false; break;
      case '--quiet': args.quiet = true; break;
      case '--init-settings': args.initSettings = true; break;
      case '--print-settings': args.printSettings = true; break;
      case '--help': case '-h': args.help = true; break;
      default: throw new Error(`unknown argument ${a}`);
    }
  }
  return args;
}

function notifyDesktop(title, body) {
  if (process.platform !== 'darwin') return;
  const script = `display notification ${JSON.stringify(body)} with title ${JSON.stringify(title)}`;
  try {
    spawn('osascript', ['-e', script], { stdio: 'ignore', detached: true }).unref();
  } catch {
    // Notifications are best-effort.
  }
}

function readStdin() {
  return new Promise((resolve, reject) => {
    let data = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (chunk) => { data += chunk; });
    process.stdin.on('end', () => resolve(data));
    process.stdin.on('error', reject);
  });
}

async function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (err) {
    process.stderr.write(`submit-cli: ${err.message}\n`);
    process.exit(2);
  }

  if (args.help) {
    process.stdout.write(fs.readFileSync(__filename, 'utf8').split('\n')
      .filter((l) => l.startsWith('//')).map((l) => l.replace(/^\/\/ ?/, '')).join('\n') + '\n');
    return;
  }

  const baseDir = args.baseDir || process.env.CLAUDE_CAPTURE_HOME || defaultBaseDir();

  if (args.initSettings) {
    const target = settingsPath(baseDir);
    if (fs.existsSync(target)) {
      process.stdout.write(`settings already exist: ${target}\n`);
    } else {
      saveSettings(baseDir, DEFAULT_SETTINGS);
      process.stdout.write(`wrote defaults to: ${target}\nset "skill" (and cli.cwd) there.\n`);
    }
    return;
  }

  if (args.printSettings) {
    process.stdout.write(JSON.stringify(loadSettings(baseDir), null, 2) + '\n');
    return;
  }

  const kind = args.kind || (args.file ? 'image' : 'text');
  const source = args.source || (kind === 'image' ? 'screenshot' : 'text');
  if (!['text', 'image'].includes(kind)) {
    process.stderr.write(`submit-cli: bad --kind ${kind}\n`);
    process.exit(2);
  }
  if (kind === 'image' && !args.file) {
    process.stderr.write('submit-cli: --kind image requires --file\n');
    process.exit(2);
  }

  const capture = { kind, source, capturedAt: new Date().toISOString() };
  if (kind === 'image') {
    capture.file = path.resolve(args.file);
    if (!fs.existsSync(capture.file)) {
      process.stderr.write(`submit-cli: no such file: ${capture.file}\n`);
      process.exit(2);
    }
  } else {
    capture.text = args.file ? fs.readFileSync(args.file, 'utf8') : await readStdin();
    if (!capture.text.trim()) {
      process.stderr.write('submit-cli: empty text capture\n');
      process.exit(2);
    }
  }

  const settings = loadSettings(baseDir);
  const notify = !args.quiet && settings.notifications ? notifyDesktop : () => {};
  const { record, donePromise } = submitCapture({
    dirs: appDirs(baseDir),
    settings,
    capture,
    notify,
  });
  process.stdout.write(JSON.stringify(record) + '\n');

  if (!args.wait) return;
  const finalRecord = await donePromise;
  process.stdout.write(JSON.stringify(finalRecord) + '\n');
  process.exitCode = finalRecord.status === 'succeeded' ? 0 : 1;
}

main().catch((err) => {
  process.stderr.write(`submit-cli: ${err.stack || err}\n`);
  process.exit(1);
});
