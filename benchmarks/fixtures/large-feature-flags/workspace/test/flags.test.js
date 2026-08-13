'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createEvaluator } = require('../src/flags');

test('exports the evaluator factory', () => {
  assert.equal(typeof createEvaluator, 'function');
});
