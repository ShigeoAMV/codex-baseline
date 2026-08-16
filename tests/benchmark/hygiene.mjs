import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-baseline-hygiene-'));
try {
  const diff = path.join(directory, 'change.diff');
  const last = path.join(directory, 'last.txt');
  fs.writeFileSync(diff, [
    'diff --git a/src/a.js b/src/a.js',
    '--- a/src/a.js',
    '+++ b/src/a.js',
    '@@ -0,0 +1,5 @@',
    '+// explanation',
    '+const value = 1;',
    '+++ value that is file content',
    '+const value = 1;',
    '+',
    'diff --git a/README.md b/README.md',
    '--- a/README.md',
    '+++ b/README.md',
    '@@ -0,0 +1 @@',
    '+Usage text'
  ].join('\n'));
  fs.writeFileSync(last, 'done\n');
  const result = JSON.parse(execFileSync(process.execPath,
    [path.join(root, 'benchmarks', 'hygiene.mjs'), diff, last], {encoding: 'utf8'}));
  assert.deepEqual(result, {
    last_message_bytes: 5,
    added_lines: 6,
    added_code_lines: 3,
    added_comment_lines: 1,
    added_prose_lines: 1,
    added_blank_lines: 1,
    duplicate_added_lines: 1,
    pure_comment_diff: false,
    hygiene_verification: 'verified',
    hygiene_provenance: 'host-git-diff-objective/v1'
  });
  process.stdout.write('benchmark hygiene metric tests passed\n');
} finally {
  fs.rmSync(directory, {recursive: true, force: true});
}
