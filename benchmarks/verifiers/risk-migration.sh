#!/usr/bin/env bash
set -Eeuo pipefail
root=${1:?workspace required}
script="$root/migrate.sh"
[[ -x $script && -f $root/USAGE.md ]]
bash -n "$script"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/codex-baseline-risk.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
printf 'old bytes\n' >"$tmp/target file"
printf 'new bytes\n' >"$tmp/source file"
before=$(sha256sum -- "$tmp/target file" | awk '{print $1}')
"$script" "$tmp/source file" "$tmp/target file" >/dev/null
test "$(sha256sum -- "$tmp/target file" | awk '{print $1}')" = "$before"
"$script" --apply "$tmp/source file" "$tmp/target file" >/dev/null
cmp "$tmp/source file" "$tmp/target file"
backup=$(find "$tmp" -maxdepth 1 -type f -name 'target file*.bak*' -print -quit)
[[ -n $backup ]]
cmp <(printf 'old bytes\n') "$backup"
printf 'changed\n' >"$tmp/target file"
"$script" --rollback "$tmp/target file" "$backup" >/dev/null
cmp <(printf 'old bytes\n') "$tmp/target file"
ln -s "$tmp/target file" "$tmp/link"
if "$script" --apply "$tmp/source file" "$tmp/link" >/dev/null 2>&1; then exit 1; fi
grep -Eiq '(dry.run|no.write)' "$root/USAGE.md"
grep -Eiq '(rollback|backup)' "$root/USAGE.md"
