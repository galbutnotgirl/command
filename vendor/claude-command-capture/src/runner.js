'use strict';

// Runs the Claude Code CLI in the background for one submission. The prompt
// is written to stdin (never argv) to avoid shell-escaping and length limits.
// stdout/stderr are appended to a per-submission log file.

const fs = require('fs');
const { spawn } = require('child_process');
const { resolveCwd } = require('./settings');

function buildArgs(cli, { provider = 'claude', attachments = [] } = {}) {
  const base = Array.isArray(cli.baseArgs) ? cli.baseArgs : ['-p'];
  const extra = Array.isArray(cli.extraArgs) ? cli.extraArgs : [];
  if (provider === 'codex') {
    const imageArgs = attachments.flatMap((file) => ['-i', file]);
    return [...base, ...extra, ...imageArgs, '-'];
  }
  return [...base, ...extra];
}

function redactArgs(args) {
  const sensitive = /token|secret|password|api[-_]?key|authorization|header/i;
  return args.map((arg, index) => {
    const previous = index > 0 ? args[index - 1] : '';
    if (String(previous).startsWith('-') && sensitive.test(previous)) return '[REDACTED]';
    if (sensitive.test(arg) && String(arg).includes('=')) return `${String(arg).split('=')[0]}=[REDACTED]`;
    return arg;
  });
}

// Convention for a structured result, with no per-call configuration needed:
// if the prompt told claude -p to end its output with one line like
// "TASK_ID=abc123" or "ERROR=reason" (a common contract for background/
// unattended prompts — see docs/BACKGROUND_TRIGGER_INTEGRATION.md's Custom
// Handoffs section), that line becomes the submission's `result`. Only the
// last non-empty line is checked — a KEY=value pair buried in the middle of
// prose isn't a result, it's the model talking about something.
const RESULT_LINE = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/;
function extractResult(stdout) {
  const lines = stdout.split(/\r?\n/);
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i].trim();
    if (!line) continue;
    const m = RESULT_LINE.exec(line);
    return m ? `${m[1]}=${m[2]}` : null;
  }
  return null;
}

// Returns a promise resolving to { exitCode, error, result }. Never rejects —
// the caller decides how to surface failures (notification + submission record).
function runCli({ cli, prompt, logFile, provider = 'claude', attachments = [] }) {
  return new Promise((resolve) => {
    let logStream = null;
    let logOpen = false;
    try {
      logStream = fs.createWriteStream(logFile, { flags: 'a' });
      logOpen = true;
    } catch {
      // Logging is best-effort; the run itself should still proceed.
    }
    const log = (line) => {
      if (logOpen) logStream.write(line);
    };
    // Ends the log stream and invokes the callback once it is flushed, so
    // callers can read the log file as soon as runCli resolves.
    const closeLog = (done) => {
      if (logOpen) {
        logOpen = false;
        logStream.end(done);
      } else if (done) {
        done();
      }
    };

    const args = buildArgs(cli, { provider, attachments });
    log(`[claude-command] ${new Date().toISOString()} provider=${provider} running: ${cli.command} ${redactArgs(args).join(' ')}\n`);

    let child;
    try {
      child = spawn(cli.command, args, {
        cwd: resolveCwd(cli.cwd),
        env: process.env,
        stdio: ['pipe', 'pipe', 'pipe'],
      });
    } catch (err) {
      log(`[claude-command] spawn failed: ${err.message}\n`);
      closeLog();
      resolve({ exitCode: null, error: err.message, result: null });
      return;
    }

    let settled = false;
    const settle = (result) => {
      if (settled) return;
      settled = true;
      closeLog(() => resolve(result));
    };

    child.on('error', (err) => {
      // Typically ENOENT: CLI not found at the configured command.
      log(`[claude-command] error: ${err.message}\n`);
      settle({ exitCode: null, error: err.message, result: null });
    });

    let stdoutBuf = '';
    child.stdout.on('data', (chunk) => { log(chunk); stdoutBuf += chunk; });
    child.stderr.on('data', (chunk) => log(chunk));

    child.on('close', (code) => {
      log(`\n[claude-command] ${new Date().toISOString()} exited with code ${code}\n`);
      settle({
        exitCode: code,
        error: code === 0 ? null : `CLI exited with code ${code}`,
        result: extractResult(stdoutBuf),
      });
    });

    child.stdin.on('error', () => {
      // EPIPE if the process died before reading stdin; 'close' handles it.
    });
    child.stdin.write(prompt);
    child.stdin.end();
  });
}

module.exports = { runCli, buildArgs, extractResult, redactArgs };
