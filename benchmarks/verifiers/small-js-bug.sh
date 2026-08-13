#!/usr/bin/env bash
set -Eeuo pipefail
root=${1:?workspace required}
node - "$root" <<'NODE'
const path = require('path');
const root = process.argv[2];
const { sum } = require(path.join(root, 'calc.js'));
const cases = [[2, 3, 5], [-4, 7, 3], [0.25, 0.5, 0.75]];
for (const [a, b, expected] of cases) {
  if (sum(a, b) !== expected) process.exit(1);
}
NODE
test "$(find "$root" -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort)" = 'calc.js'
