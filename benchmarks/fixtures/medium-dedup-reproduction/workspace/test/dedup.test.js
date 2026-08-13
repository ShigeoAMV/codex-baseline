'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { getOrLoad } = require('../src/dedup');

test('a later call after completion invokes the loader again', async () => {
  let calls = 0;
  assert.equal(await getOrLoad('sequential', async () => ++calls), 1);
  assert.equal(await getOrLoad('sequential', async () => ++calls), 2);
});
