'use strict';

// Submission records: one JSON file per capture handed to the CLI. These are
// the durable handoff artifact — a downstream app can watch the submissions
// directory (or query by id) to pick up work after this app is done.

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

function recordPath(dirs, id) {
  return path.join(dirs.submissions, `${id}.json`);
}

function writeRecord(dirs, record) {
  fs.mkdirSync(dirs.submissions, { recursive: true });
  const target = recordPath(dirs, record.id);
  const tmp = target + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(record, null, 2) + '\n');
  fs.renameSync(tmp, target);
  return record;
}

function createSubmission(dirs, { id, source, kind, skill, prompt, contentFile, logFile }) {
  if (!id) id = crypto.randomUUID();
  const record = {
    id,
    createdAt: new Date().toISOString(),
    source, // 'text' | 'clipboard' | 'selection' | 'screenshot'
    kind, // 'text' | 'image'
    skill: skill || null,
    prompt,
    contentFile: contentFile || null,
    logFile: logFile || null,
    status: 'running', // 'running' | 'succeeded' | 'failed'
    exitCode: null,
    finishedAt: null,
    error: null,
  };
  return writeRecord(dirs, record);
}

function updateSubmission(dirs, id, patch) {
  const target = recordPath(dirs, id);
  const record = JSON.parse(fs.readFileSync(target, 'utf8'));
  const updated = { ...record, ...patch };
  return writeRecord(dirs, updated);
}

function listSubmissions(dirs, limit = 20) {
  let files;
  try {
    files = fs.readdirSync(dirs.submissions).filter((f) => f.endsWith('.json'));
  } catch {
    return [];
  }
  const records = [];
  for (const file of files) {
    try {
      records.push(JSON.parse(fs.readFileSync(path.join(dirs.submissions, file), 'utf8')));
    } catch {
      // Skip unreadable/partial records rather than failing the listing.
    }
  }
  records.sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
  return records.slice(0, limit);
}

module.exports = { createSubmission, updateSubmission, listSubmissions, recordPath };
