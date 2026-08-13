'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const test = require('node:test');
const assert = require('node:assert/strict');
const { resolveExistingFile } = require('../src/safe-path');

test('resolves a normal path below root', () => {
  const parent = fs.mkdtempSync(path.join(os.tmpdir(), 'safe-path-'));
  const root = path.join(parent, 'public');
  fs.mkdirSync(root);
  fs.writeFileSync(path.join(root, 'index.txt'), 'ok');
  assert.equal(resolveExistingFile(root, '/index.txt'), path.join(root, 'index.txt'));
});
