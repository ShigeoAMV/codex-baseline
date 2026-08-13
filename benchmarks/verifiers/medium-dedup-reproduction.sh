#!/usr/bin/env bash
set -Eeuo pipefail
root=${1:?workspace required}
node - "$root" <<'NODE'
const path = require('path');
const root = process.argv[2];
const { getOrLoad } = require(path.join(root, 'src/dedup.js'));

(async () => {
  let release;
  const gate = new Promise(resolve => { release = resolve; });
  let calls = 0;
  const loader = async () => { calls += 1; await gate; return { ok: true }; };
  const first = getOrLoad('same', loader);
  const second = getOrLoad('same', loader);
  const other = getOrLoad('other', async () => 'independent');
  await new Promise(resolve => setImmediate(resolve));
  if (calls !== 1 || await other !== 'independent') process.exit(1);
  release();
  const [a, b] = await Promise.all([first, second]);
  if (calls !== 1 || a !== b || a.ok !== true) process.exit(1);

  let rejectedCalls = 0;
  const rejectLoader = async () => { rejectedCalls += 1; throw new Error('expected'); };
  const rejected = await Promise.allSettled([
    getOrLoad('reject', rejectLoader),
    getOrLoad('reject', rejectLoader),
  ]);
  if (rejectedCalls !== 1 || rejected.some(item => item.status !== 'rejected')) process.exit(1);
  if (await getOrLoad('reject', async () => 'retry') !== 'retry') process.exit(1);

  let threw = false;
  try { getOrLoad('bad', null); } catch (error) { threw = error instanceof TypeError; }
  if (!threw) process.exit(1);
})().catch(() => process.exit(1));
NODE
node --test "$root/test/dedup.test.js" >/dev/null
grep -Eq 'Promise\.all|allSettled' "$root/test/dedup.test.js"
grep -Eiq '(concurrent|in.flight|pending|share)' "$root/test/dedup.test.js"
grep -Eiq '(reject|retry|failure)' "$root/test/dedup.test.js"
test "$(find "$root" -path "$root/.git" -prune -o -type f -printf '%P\n' | LC_ALL=C sort | tr '\n' ' ')" = 'src/dedup.js test/dedup.test.js '
