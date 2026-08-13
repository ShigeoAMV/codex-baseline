#!/usr/bin/env bash
set -Eeuo pipefail
root=${1:?workspace required}
[[ -f $root/src/ids.js && ! -L $root/src/ids.js ]]
node - "$root" <<'NODE'
const path = require('path');
const assert = require('assert/strict');
const root = process.argv[2];
const { normalizeId } = require(path.join(root, 'src/ids.js'));
const { createUser } = require(path.join(root, 'src/user.js'));
const { createOrder } = require(path.join(root, 'src/order.js'));
for (const [input, expected] of [[' abc-1 ', 'ABC-1'], ['x_y', 'X_Y'], ['0', '0']]) {
  if (normalizeId(input) !== expected) process.exit(1);
}
for (const value of [null, 7, '', '   ', 'bad/id', 'x'.repeat(33), 'ä']) {
  let threw = false;
  try { normalizeId(value); } catch (error) { threw = error instanceof TypeError; }
  if (!threw) process.exit(1);
}
try {
  assert.deepStrictEqual(createUser(' a-1 ', 'Ada'), { id: 'A-1', name: 'Ada' });
  assert.deepStrictEqual(createOrder(' o_2 ', ' a-1 ', 9), { id: 'O_2', userId: 'A-1', total: 9 });
} catch (_) { process.exit(1); }
NODE
node --test "$root/test/domain.test.js" "$root/test/ids.test.js" >/dev/null
grep -Eq "require\(['\"]\./ids['\"]\)" "$root/src/user.js"
grep -Eq "require\(['\"]\./ids['\"]\)" "$root/src/order.js"
if grep -Eq 'trim\(\)\.toUpperCase\(\)' "$root/src/user.js" "$root/src/order.js"; then exit 1; fi
test "$(sha256sum -- "$root/test/domain.test.js" | awk '{print $1}')" = '2a43c9564b72cc107d61279c300c36dfe13000c4b3d72ab3880b1faf3fbef7ae'
test "$(find "$root" -path "$root/.git" -prune -o -type f -printf '%P\n' | LC_ALL=C sort | tr '\n' ' ')" = 'src/ids.js src/order.js src/user.js test/domain.test.js test/ids.test.js '
