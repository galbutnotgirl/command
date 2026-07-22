#!/usr/bin/env node
'use strict';

const fs = require('fs');

function packedEntries(buffer) {
  if (buffer.length < 16) throw new Error('ASAR header is truncated');
  const headerLength = buffer.readUInt32LE(12);
  const dataOffset = 16 + headerLength;
  if (dataOffset > buffer.length) throw new Error('ASAR header length is invalid');

  let header;
  try {
    header = JSON.parse(buffer.subarray(16, dataOffset).toString('utf8'));
  } catch (error) {
    throw new Error(`ASAR header is invalid JSON: ${error.message}`);
  }

  const entries = [];
  function walk(node, prefix = '') {
    for (const [name, value] of Object.entries(node.files || {})) {
      const path = prefix ? `${prefix}/${name}` : name;
      if (value.files) {
        walk(value, path);
        continue;
      }
      if (value.unpacked || typeof value.size !== 'number' || value.offset === undefined) continue;
      const start = dataOffset + Number(value.offset);
      const end = start + value.size;
      if (!Number.isSafeInteger(start) || start < dataOffset || end > buffer.length) {
        throw new Error(`ASAR entry bounds are invalid: ${path}`);
      }
      entries.push({ path, content: buffer.subarray(start, end).toString('utf8') });
    }
  }
  walk(header);
  return entries;
}

function matchingEntry(buffer, patterns) {
  const expressions = patterns.map(pattern => new RegExp(pattern, 's'));
  return packedEntries(buffer).find(entry => expressions.every(expression => expression.test(entry.content)));
}

if (require.main === module) {
  const [, , asarPath, ...patterns] = process.argv;
  if (!asarPath || patterns.length === 0) {
    console.error('usage: asar-contract.js APP.ASAR REGEX [REGEX ...]');
    process.exit(64);
  }
  try {
    const match = matchingEntry(fs.readFileSync(asarPath), patterns);
    if (!match) process.exit(1);
    process.stdout.write(`${match.path}\n`);
  } catch (error) {
    console.error(`asar-contract: ${error.message}`);
    process.exit(2);
  }
}

module.exports = { packedEntries, matchingEntry };
