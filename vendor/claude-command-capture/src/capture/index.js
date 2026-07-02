'use strict';

// Dispatch a capture by source. Each capture resolves to
// { kind: 'text'|'image', source, capturedAt, text?, file? } or null when the
// user cancels (e.g. dismisses the text-entry window).

const { captureClipboard } = require('./clipboard');
const { captureSelection } = require('./selection');
const { captureScreenshot } = require('./screenshot');
const { showTextEntry } = require('../windows/text-entry');

const SOURCES = ['text', 'clipboard', 'selection', 'screenshot'];

async function captureFrom(source, dirs) {
  switch (source) {
    case 'text':
      return showTextEntry();
    case 'clipboard':
      return captureClipboard(dirs);
    case 'selection':
      return captureSelection();
    case 'screenshot':
      return captureScreenshot(dirs);
    default:
      throw new Error(`Unknown capture source: ${source}`);
  }
}

module.exports = { captureFrom, SOURCES };
