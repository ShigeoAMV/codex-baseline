#!/usr/bin/env bash
set -Eeuo pipefail
root=${1:?workspace required}
node - "$root" <<'NODE'
const path = require('path');
const root = process.argv[2];
const { quote } = require(path.join(root, 'src/quote.js'));
const result = quote([{quantity: 2, unitPrice: 1.005}, {quantity: 1, unitPrice: 3}], 10);
if (JSON.stringify(result) !== JSON.stringify({subtotal: 5.01, discount: 0.5, total: 4.51})) process.exit(1);
if (!Object.isFrozen(result)) process.exit(1);
for (const args of [[[], 0], [[{quantity: 0, unitPrice: 1}], 0], [[{quantity: 1.5, unitPrice: 1}], 0], [[{quantity: 1, unitPrice: -1}], 0], [[{quantity: 1, unitPrice: 1}], 101], [[{quantity: 1, unitPrice: 1}], NaN]]) {
  let threw = false;
  try { quote(...args); } catch (_) { threw = true; }
  if (!threw) process.exit(1);
}
NODE
test "$(find "$root" -path "$root/.git" -prune -o -type f -printf '%P\n' | LC_ALL=C sort | tr '\n' ' ')" = 'src/money.js src/quote.js '
