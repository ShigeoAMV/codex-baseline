#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source_root=$(cd -- "$script_dir/.." && pwd -P)

if [[ ${1:-} == -h || ${1:-} == --help ]]; then
  printf '%s\n' 'Usage: scripts/release-payload.sh' '' \
    'Print the canonical installable payload inventory and aggregate SHA-256 as JSON.' \
    'The command is read-only; review and apply the result to baseline/manifest.json.'
  exit 0
fi
[[ $# -eq 0 ]] || { printf 'unknown option: %s\n' "$1" >&2; exit 2; }

for command in find jq sha256sum sort stat; do
  command -v "$command" >/dev/null 2>&1 || { printf 'missing command: %s\n' "$command" >&2; exit 1; }
done

cd -- "$source_root"
mapfile -t payload_paths < <(
  {
    printf '%s\n' VERSION
    find -P baseline -type f ! -path baseline/manifest.json -printf '%p\n'
    printf '%s\n' \
      scripts/codex-baseline.sh scripts/codex-baseline.ps1 \
      scripts/onboard.sh scripts/onboard.ps1 \
      scripts/benchmark.sh scripts/benchmark.ps1 scripts/lib/common.sh
    find -P benchmarks -type f -printf '%p\n'
  } | LC_ALL=C sort -u
)

canonical=''
entries=''
for path in "${payload_paths[@]}"; do
  [[ $path != *$'\n'* && $path != *$'\t'* && -f $path && ! -L $path ]] || {
    printf 'unsafe payload path: %s\n' "$path" >&2
    exit 1
  }
  bytes=$(stat -c '%s' -- "$path")
  digest=$(sha256sum -- "$path" | awk '{print $1}')
  canonical+=$(printf '%s\t%s\t%s\n' "$path" "$bytes" "$digest")
  canonical+=$'\n'
  entries+=$(jq -nc --arg path "$path" --argjson bytes "$bytes" --arg sha256 "$digest" \
    '{path:$path,bytes:$bytes,sha256:$sha256}')
  entries+=$'\n'
done

payload_hash=$(printf '%s' "$canonical" | sha256sum | awk '{print $1}')
printf '%s' "$entries" | jq -sc --arg payload_hash "$payload_hash" \
  '{payload_hash:$payload_hash,payload:.}'
