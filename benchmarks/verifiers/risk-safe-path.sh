#!/usr/bin/env bash
set -Eeuo pipefail
root=${1:?workspace required}
node - "$root" <<'NODE'
const fs = require('fs');
const os = require('os');
const path = require('path');
const fixture = process.argv[2];
const { resolveExistingFile } = require(path.join(fixture, 'src/safe-path.js'));

const parent = fs.mkdtempSync(path.join(os.tmpdir(), 'safe-path-hidden-'));
{
  const root = path.join(parent, 'app');
  const sibling = path.join(parent, 'app-old');
  fs.mkdirSync(path.join(root, 'nested'), { recursive: true });
  fs.mkdirSync(sibling);
  fs.writeFileSync(path.join(root, 'public.txt'), 'public');
  fs.writeFileSync(path.join(root, 'nested/data.txt'), 'nested');
  fs.writeFileSync(path.join(sibling, 'secret.txt'), 'secret');
  fs.symlinkSync(sibling, path.join(root, 'linked-dir'));
  fs.symlinkSync(path.join(sibling, 'secret.txt'), path.join(root, 'linked-file'));

  const valid = [
    ['/public.txt', path.join(root, 'public.txt')],
    ['nested/data.txt', path.join(root, 'nested/data.txt')],
    ['/nested/%64ata.txt', path.join(root, 'nested/data.txt')],
  ];
  for (const [request, expected] of valid) {
    if (resolveExistingFile(root, request) !== fs.realpathSync(expected)) process.exit(1);
  }

  const invalid = [
    '../app-old/secret.txt',
    '/../app-old/secret.txt',
    '/%2e%2e/app-old/secret.txt',
    '/nested/%2e%2e/public.txt',
    '/nested%2fdata.txt',
    '/nested%5cdata.txt',
    '/nested\\data.txt',
    '//server/share',
    '/C:/Windows/file',
    '/bad%escape',
    '/public.txt\0tail',
    '/linked-dir/secret.txt',
    '/linked-file',
    '/nested',
    '/missing.txt',
    '/./public.txt',
    '/nested//data.txt',
  ];
  for (const request of invalid) {
    let threw = false;
    try { resolveExistingFile(root, request); } catch (_) { threw = true; }
    if (!threw) process.exit(1);
  }

  const rootLink = path.join(parent, 'root-link');
  fs.symlinkSync(root, rootLink);
  let rootThrew = false;
  try { resolveExistingFile(rootLink, '/public.txt'); } catch (_) { rootThrew = true; }
  if (!rootThrew) process.exit(1);
}
NODE
node --test "$root/test/safe-path.test.js" >/dev/null
grep -Eiq '(traversal|dot-dot|\.\.)' "$root/test/safe-path.test.js"
grep -Eiq 'symlink' "$root/test/safe-path.test.js"
grep -Eiq 'symlink|canonical|realpath' "$root/SECURITY.md"
grep -Eiq 'TOCTOU|time.of.check|race' "$root/SECURITY.md"
grep -Eiq 'no.follow|nofollow|descriptor|file descriptor' "$root/SECURITY.md"
test "$(find "$root" -path "$root/.git" -prune -o -type f -printf '%P\n' | LC_ALL=C sort | tr '\n' ' ')" = 'SECURITY.md src/safe-path.js test/safe-path.test.js '
