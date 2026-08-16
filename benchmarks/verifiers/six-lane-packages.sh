#!/usr/bin/env bash
set -Eeuo pipefail
root=${1:?workspace required}
node - "$root" <<'NODE'
const root = process.argv[2];
const assert = require('node:assert/strict');

const a = require(`${root}/packages/a/index.js`);
const headerInput = [[' Content-Type ', ' application/json '], ['X-ID', ' one '], ['x-id', 'two']];
assert.deepEqual(a.normalizeHeaders(headerInput), {'content-type': 'application/json', 'x-id': 'one, two'});
assert.deepEqual(headerInput, [[' Content-Type ', ' application/json '], ['X-ID', ' one '], ['x-id', 'two']]);

const b = require(`${root}/packages/b/index.js`);
assert.deepEqual(b.retryDelays(100, 5, 650), [100, 200, 400, 650, 650]);
assert.deepEqual(b.retryDelays(3, 0, 10), []);
for (const args of [[0, 2, 10], [2, -1, 10], [2, 1.5, 10], [2, 2, 0]]) {
  assert.throws(() => b.retryDelays(...args), TypeError);
}

const c = require(`${root}/packages/c/index.js`);
const values = [{id: 2, value: 'first'}, {id: 1, value: 'only'}, {id: 2, value: 'later'}];
assert.deepEqual(c.dedupeStable(values, (value) => value.id), [values[0], values[1]]);
assert.equal(values.length, 3);

const d = require(`${root}/packages/d/index.js`);
assert.deepEqual(d.parseFeatureFlags(' # ignored\nalpha=true\nbeta = false\nalpha=false\n'), {alpha: false, beta: false});
assert.throws(() => d.parseFeatureFlags('missing-value'), /malformed/i);
assert.throws(() => d.parseFeatureFlags('x=maybe'), /malformed/i);

const e = require(`${root}/packages/e/index.js`);
assert.deepEqual(e.partitionSettled([
  {status: 'fulfilled', value: 0}, {status: 'rejected', reason: ''},
  {status: 'fulfilled', value: false}, {status: 'rejected', reason: 'boom'}
]), {fulfilled: [0, false], rejected: ['', 'boom']});

const f = require(`${root}/packages/f/index.js`);
assert.equal(f.joinUrl('https://example.test/api/', '/users?active=1#top'), 'https://example.test/api/users?active=1#top');
assert.equal(f.joinUrl('https://example.test', 'health'), 'https://example.test/health');
NODE
