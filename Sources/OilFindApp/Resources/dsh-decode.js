#!/usr/bin/env node
'use strict';
// Decodes DSH session files: an append-only sequence of zstd frames, one JSONL record per line.
// Node's zstd stream only yields the first frame, so scan frame boundaries and inflate each frame.
const fs = require('fs');
const zlib = require('zlib');

const ZSTD_MAGIC = 4247762216;
const file = process.argv[2];
const start = Math.max(0, Number(process.argv[3] || 0));

function fail(message) { process.stderr.write('ERROR ' + message + '\n'); process.exit(2); }
if (!file) fail('missing path');
if (typeof zlib.zstdDecompressSync !== 'function') fail('node without zstd support');

let size, buffer;
try {
  size = fs.statSync(file).size;
  const length = Math.max(0, size - start);
  buffer = Buffer.allocUnsafe(length);
  const fd = fs.openSync(file, 'r');
  try {
    let read = 0;
    while (read < length) {
      const count = fs.readSync(fd, buffer, read, length - read, start + read);
      if (count <= 0) break;
      read += count;
    }
    buffer = buffer.subarray(0, read);
  } finally { fs.closeSync(fd); }
} catch (error) { fail(String(error && error.message || error)); }

function scan(buf) {
  let off = 0;
  const frames = [];
  while (off + 4 <= buf.length) {
    if (buf.readUInt32LE(off) !== ZSTD_MAGIC) break;
    const frameStart = off;
    off += 4;
    if (off >= buf.length) { off = frameStart; break; }
    const descriptor = buf[off++];
    if ((descriptor & 24) !== 0) { off = frameStart; break; }
    const contentSizeFlag = descriptor >>> 6;
    const singleSegment = (descriptor & 32) !== 0;
    const checksum = (descriptor & 4) !== 0;
    const dictionaryFlag = descriptor & 3;
    const dictionaryBytes = dictionaryFlag === 3 ? 4 : dictionaryFlag;
    const contentSizeBytes = contentSizeFlag === 0 ? (singleSegment ? 1 : 0) : 1 << contentSizeFlag;
    const remainingHeaderBytes = (singleSegment ? 0 : 1) + dictionaryBytes + contentSizeBytes;
    if (off + remainingHeaderBytes > buf.length) { off = frameStart; break; }
    off += remainingHeaderBytes;
    let lastBlock = false, torn = false;
    while (!lastBlock) {
      if (off + 3 > buf.length) { torn = true; break; }
      const blockHeader = buf.readUIntLE(off, 3); off += 3;
      lastBlock = (blockHeader & 1) === 1;
      const blockType = (blockHeader >>> 1) & 3;
      const blockSize = blockHeader >>> 3;
      if (blockType === 3) { torn = true; break; }
      off += blockType === 1 ? 1 : blockSize;
      if (off > buf.length) { torn = true; break; }
    }
    if (torn) { off = frameStart; break; }
    if (checksum) {
      if (off + 4 > buf.length) { off = frameStart; break; }
      off += 4;
    }
    frames.push([frameStart, off]);
  }
  return { frames, end: off };
}

const scanned = scan(buffer);
let output = 0;
for (const [from, to] of scanned.frames) {
  let plain;
  try { plain = zlib.zstdDecompressSync(buffer.subarray(from, to)); }
  catch (error) { process.stderr.write('WARN frame ' + String(error && error.message || error) + '\n'); break; }
  if (plain.length) { fs.writeSync(1, plain); output += plain.length; }
}
process.stderr.write('CURSOR ' + (start + scanned.end) + ' ' + output + '\n');
