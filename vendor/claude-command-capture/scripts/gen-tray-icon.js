'use strict';

// Generates the tray icons (no image dependencies — writes PNG chunks by
// hand). The glyph is a ring with a center dot, i.e. "capture".
//
//   node scripts/gen-tray-icon.js
//
// Outputs:
//   assets/trayTemplate.png     16x16 black+alpha (macOS template image)
//   assets/trayTemplate@2x.png  32x32
//   assets/tray.png             16x16 (Windows/Linux)

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

function crc32(buf) {
  let table = crc32.table;
  if (!table) {
    table = crc32.table = new Int32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      table[n] = c;
    }
  }
  let crc = -1;
  for (let i = 0; i < buf.length; i++) crc = (crc >>> 8) ^ table[(crc ^ buf[i]) & 0xff];
  return (crc ^ -1) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
}

// rgba: Uint8Array of size*size*4
function encodePng(size, rgba) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // color type RGBA
  // Raw scanlines, each prefixed with filter byte 0.
  const raw = Buffer.alloc(size * (size * 4 + 1));
  for (let y = 0; y < size; y++) {
    const rowStart = y * (size * 4 + 1);
    raw[rowStart] = 0;
    for (let x = 0; x < size * 4; x++) {
      raw[rowStart + 1 + x] = rgba[y * size * 4 + x];
    }
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

// Draw a ring + center dot with simple distance-field anti-aliasing.
function drawIcon(size) {
  const rgba = new Uint8Array(size * size * 4);
  const center = (size - 1) / 2;
  const ringRadius = size * 0.36;
  const ringWidth = size * 0.09;
  const dotRadius = size * 0.14;
  const aa = 0.75;

  const coverage = (dist) => Math.max(0, Math.min(1, aa + 0.5 - dist));

  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const dx = x - center;
      const dy = y - center;
      const r = Math.hypot(dx, dy);
      const ring = coverage(Math.abs(r - ringRadius) - ringWidth / 2);
      const dot = coverage(r - dotRadius);
      const alpha = Math.max(ring, dot);
      const i = (y * size + x) * 4;
      rgba[i] = 0;
      rgba[i + 1] = 0;
      rgba[i + 2] = 0;
      rgba[i + 3] = Math.round(alpha * 255);
    }
  }
  return rgba;
}

const assetsDir = path.join(__dirname, '..', 'assets');
fs.mkdirSync(assetsDir, { recursive: true });
fs.writeFileSync(path.join(assetsDir, 'trayTemplate.png'), encodePng(16, drawIcon(16)));
fs.writeFileSync(path.join(assetsDir, 'trayTemplate@2x.png'), encodePng(32, drawIcon(32)));
fs.writeFileSync(path.join(assetsDir, 'tray.png'), encodePng(16, drawIcon(16)));
console.log('Wrote assets/trayTemplate.png, trayTemplate@2x.png, tray.png');
