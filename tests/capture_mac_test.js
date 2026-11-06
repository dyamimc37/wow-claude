'use strict';
// capture_mac.py must outlive a failed window lookup: System Events drops the
// game window when it closes or leaves the current Space.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const SCRIPT = path.join(__dirname, '..', 'bridge', 'capture_mac.py');

test('a failing osascript does not kill the capture', { skip: process.platform === 'win32' }, async () => {
  const bin = fs.mkdtempSync(path.join(os.tmpdir(), 'fake-osascript-'));
  const fake = path.join(bin, 'osascript');
  fs.writeFileSync(fake, '#!/bin/sh\necho "Invalid index. (-1719)" >&2\nexit 1\n');
  fs.chmodSync(fake, 0o755);
  const ps = spawn('python3', [SCRIPT], { env: { ...process.env, PATH: `${bin}${path.delimiter}${process.env.PATH}` } });
  let out = '';
  ps.stdout.on('data', d => { out += d; });
  let exited = null;
  ps.on('exit', code => { exited = code; });
  try {
    const deadline = Date.now() + 10000;
    while (!/waiting for/.test(out) && exited === null && Date.now() < deadline) {
      await new Promise(r => setTimeout(r, 50));
    }
    assert.strictEqual(exited, null, `capture exited with ${exited}`);
    assert.match(out, /window lookup failed: Invalid index/);
    assert.match(out, /waiting for/);
  } finally {
    ps.kill();
    fs.rmSync(bin, { recursive: true, force: true });
  }
});
