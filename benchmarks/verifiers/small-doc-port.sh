#!/usr/bin/env bash
set -Eeuo pipefail
root=${1:?workspace required}
readme="$root/README.md"
server="$root/server.js"
[[ -f $readme && ! -L $readme && -f $server && ! -L $server ]]
grep -Eq 'PORT=4100[[:space:]]+node[[:space:]]+server\.js' "$readme"
grep -Eiq '(default|no port).*(3000)|3000.*(default|no port)' "$readme"
grep -Fq 'curl http://127.0.0.1:4100/health' "$readme"
if grep -Eq 'SERVICE_PORT|8080' "$readme"; then exit 1; fi
node - "$root" <<'NODE'
const path = require('path');
const root = process.argv[2];
const { portFrom } = require(path.join(root, 'server.js'));
if (portFrom({}) !== 3000 || portFrom({ PORT: '4100' }) !== 4100) process.exit(1);
NODE
test "$(sha256sum -- "$server" | awk '{print $1}')" = '3b379301d6143c53f81173c5b1116c2da20e81f19b76653ca3081d38e1c93cc9'
test "$(find "$root" -path "$root/.git" -prune -o -type f -printf '%P\n' | LC_ALL=C sort | tr '\n' ' ')" = 'README.md server.js '
