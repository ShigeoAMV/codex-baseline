#!/usr/bin/env bash
set -Eeuo pipefail
root=${1:?workspace required}
node - "$root" <<'NODE'
const crypto = require('crypto');
const path = require('path');
const assert = require('assert/strict');
const root = process.argv[2];
const { createEvaluator } = require(path.join(root, 'src/flags.js'));

function expectedRollout(flag, subject) {
  const hex = crypto.createHash('sha256').update(`${flag}:${subject}`, 'utf8').digest('hex').slice(0, 8);
  return (Number.parseInt(hex, 16) / 0x100000000) * 100 < 25 ? 'canary' : 'stable';
}

function same(actual, expected) {
  try { assert.deepStrictEqual(actual, expected); return true; } catch (_) { return false; }
}

const definitions = {
  checkout: {
    default: 'off',
    rules: [
      { when: { country: 'CH', tier: 'pro' }, value: 'on' },
      { when: { country: 'CH' }, value: 'preview' },
    ],
  },
  search: {
    default: 'stable',
    rollout: [
      { percentage: 25, value: 'canary' },
      { percentage: 75, value: 'stable' },
    ],
  },
  audit: { default: true },
};
const evaluator = createEvaluator(definitions);
definitions.checkout.default = 'mutated';
definitions.checkout.rules[0].value = 'mutated';

let result = evaluator.evaluate('checkout', { country: 'CH', tier: 'pro' });
if (!Object.isFrozen(result) || !same(result, { value: 'on', source: 'rule', ruleIndex: 0 })) process.exit(1);
result = evaluator.evaluate('checkout', { country: 'CH', tier: 'free' });
if (!same(result, { value: 'preview', source: 'rule', ruleIndex: 1 })) process.exit(1);
result = evaluator.evaluate('checkout');
if (!same(result, { value: 'off', source: 'default' })) process.exit(1);
for (const subject of ['alice', 'bob', 'charlie', 'delta']) {
  result = evaluator.evaluate('search', { subject });
  const expected = expectedRollout('search', subject);
  const expectedIndex = expected === 'canary' ? 0 : 1;
  if (!same(result, { value: expected, source: 'rollout', rolloutIndex: expectedIndex })) process.exit(1);
}
const names = evaluator.listFlags();
if (!Object.isFrozen(names) || !same(names, ['audit', 'checkout', 'search'])) process.exit(1);

const invalid = [
  null,
  [],
  { bad: {} },
  { bad: { default: Infinity } },
  { bad: { default: false, rules: [] } },
  { bad: { default: false, rules: [{ when: {}, value: false }] } },
  { bad: { default: false, rules: [{ when: { x: 1 }, value: 'wrong-type' }] } },
  { bad: { default: 1, rollout: [{ percentage: 99, value: 1 }] } },
  { bad: { default: 1, rollout: [{ percentage: 50.5, value: 1 }, { percentage: 49.5, value: 1 }] } },
  { bad: { default: 1, rollout: [{ percentage: 50, value: 1 }, { percentage: 50, value: '1' }] } },
];
for (const candidate of invalid) {
  let threw = false;
  try { createEvaluator(candidate); } catch (_) { threw = true; }
  if (!threw) process.exit(1);
}
for (const [name, context] of [['missing', {}], ['search', {}], ['search', { subject: '' }], ['audit', null]]) {
  let threw = false;
  try { evaluator.evaluate(name, context); } catch (_) { threw = true; }
  if (!threw) process.exit(1);
}
NODE
node --test "$root/test/flags.test.js" >/dev/null
grep -Eiq 'rule' "$root/test/flags.test.js"
grep -Eiq 'rollout|subject' "$root/test/flags.test.js"
grep -Eiq 'default' "$root/test/flags.test.js"
grep -Eiq 'invalid|throw|reject' "$root/test/flags.test.js"
grep -Eiq 'createEvaluator|create evaluator' "$root/README.md"
grep -Eiq 'SHA-?256|determin' "$root/README.md"
grep -Eiq 'rule' "$root/README.md"
grep -Eiq 'rollout' "$root/README.md"
grep -Eiq 'default' "$root/README.md"
grep -Eiq 'throw|invalid|validation' "$root/README.md"
test "$(find "$root" -path "$root/.git" -prune -o -type f -printf '%P\n' | LC_ALL=C sort | tr '\n' ' ')" = 'README.md src/flags.js test/flags.test.js '
