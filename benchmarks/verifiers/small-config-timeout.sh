#!/usr/bin/env bash
set -Eeuo pipefail
root=${1:?workspace required}
node - "$root" <<'NODE'
const fs = require('fs');
const path = require('path');
const assert = require('assert/strict');
const root = process.argv[2];
const actual = JSON.parse(fs.readFileSync(path.join(root, 'config/service.json'), 'utf8'));
const expected = {
  service: 'billing',
  requestTimeoutMs: 7500,
  retry: { attempts: 2, backoffMs: 250 },
  telemetry: true,
};
try { assert.deepStrictEqual(actual, expected); } catch (_) { process.exit(1); }
NODE
test "$(find "$root" -path "$root/.git" -prune -o -type f -printf '%P\n' | LC_ALL=C sort)" = 'config/service.json'
