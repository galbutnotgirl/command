'use strict';

// End-to-end pipeline for one capture:
//   persist capture -> render prompt -> write submission record ->
//   run the CLI in the background -> update record + notify.
//
// This module is Electron-free; the caller injects `notify(title, body)`.

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { buildPrompt } = require('./prompt');
const { createSubmission, updateSubmission } = require('./submissions');
const { runCli } = require('./runner');
const { ensureDirs } = require('./paths');

// capture: { kind: 'text'|'image', source, capturedAt, text?, file? }
// Returns the submission record immediately; the CLI keeps running in the
// background and the record is updated when it finishes. `donePromise` on the
// return value resolves with the final record (used by tests and callers that
// want to await completion).
function submitCapture({ dirs, settings, capture, notify = () => {} }) {
  ensureDirs(dirs);
  const id = crypto.randomUUID();

  // Persist text content so the submission is self-contained even after the
  // clipboard/selection changes. Image captures already live on disk.
  let contentFile = capture.file || null;
  if (capture.kind === 'text') {
    contentFile = path.join(dirs.captures, `${id}.txt`);
    fs.writeFileSync(contentFile, capture.text != null ? capture.text : '');
  }

  const prompt = buildPrompt(settings, capture);
  const logFile = path.join(dirs.logs, `${id}.log`);
  const skill = (settings.skill || '').trim().replace(/^\//, '') || null;

  const record = createSubmission(dirs, {
    id,
    source: capture.source,
    kind: capture.kind,
    skill,
    prompt,
    contentFile,
    logFile,
  });

  notify(
    'Submitted to Claude',
    skill ? `${capture.source} capture handed to /${skill}` : `${capture.source} capture submitted`
  );

  const donePromise = runCli({ cli: settings.cli, prompt, logFile }).then(({ exitCode, error }) => {
    const status = error ? 'failed' : 'succeeded';
    const updated = updateSubmission(dirs, id, {
      status,
      exitCode,
      error,
      finishedAt: new Date().toISOString(),
    });
    if (error) {
      notify('Claude submission failed', `${error} — see log: ${logFile}`);
    } else {
      notify('Claude finished', skill ? `/${skill} completed for ${capture.source} capture` : 'Submission completed');
    }
    return updated;
  });

  return { record, donePromise };
}

module.exports = { submitCapture };
