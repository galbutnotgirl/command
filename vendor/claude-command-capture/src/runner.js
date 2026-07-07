'use strict';

// Runs the Claude Code CLI in the background for one submission. The prompt
// is written to stdin (never argv) to avoid shell-escaping and length limits.
// stdout/stderr are appended to a per-submission log file.

const fs = require('fs');
const { spawn } = require('child_process');
const { resolveCwd } = require('./settings');

function buildArgs(cli) {
  const base = Array.isArray(cli.baseArgs) ? cli.baseArgs : ['-p'];
  const extra = Array.isArray(cli.extraArgs) ? cli.extraArgs : [];
  return [...base, ...extra];
}

// Returns a promise resolving to { exitCode, error }. Never rejects — the
// caller decides how to surface failures (notification + submission record).
function runCli({ cli, prompt, logFile }) {
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

    log(`[claude-command] ${new Date().toISOString()} running: ${cli.command} ${buildArgs(cli).join(' ')}\n`);

    let child;
    try {
      child = spawn(cli.command, buildArgs(cli), {
        cwd: resolveCwd(cli.cwd),
        env: process.env,
        stdio: ['pipe', 'pipe', 'pipe'],
      });
    } catch (err) {
      log(`[claude-command] spawn failed: ${err.message}\n`);
      closeLog();
      resolve({ exitCode: null, error: err.message });
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
      settle({ exitCode: null, error: err.message });
    });

    child.stdout.on('data', (chunk) => log(chunk));
    child.stderr.on('data', (chunk) => log(chunk));

    child.on('close', (code) => {
      log(`\n[claude-command] ${new Date().toISOString()} exited with code ${code}\n`);
      settle({ exitCode: code, error: code === 0 ? null : `CLI exited with code ${code}` });
    });

    child.stdin.on('error', () => {
      // EPIPE if the process died before reading stdin; 'close' handles it.
    });
    child.stdin.write(prompt);
    child.stdin.end();
  });
}

module.exports = { runCli, buildArgs };
