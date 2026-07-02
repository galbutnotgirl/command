'use strict';

const fs = require('fs');
const path = require('path');

// Directory layout under the app's data directory. Everything a downstream
// app needs to consume submissions lives here — see docs/HANDOFF.md.
function appDirs(baseDir) {
  return {
    base: baseDir,
    captures: path.join(baseDir, 'captures'),
    submissions: path.join(baseDir, 'submissions'),
    logs: path.join(baseDir, 'logs'),
  };
}

function ensureDirs(dirs) {
  for (const key of ['captures', 'submissions', 'logs']) {
    fs.mkdirSync(dirs[key], { recursive: true });
  }
  return dirs;
}

module.exports = { appDirs, ensureDirs };
