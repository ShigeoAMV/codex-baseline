#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

root=${1:-.}
[[ $root == . && -d $root && ! -L $root ]] || exit 64
inventory=$(/usr/bin/mktemp /tmp/codex-baseline-behavior.XXXXXX)
trap '/usr/bin/rm -f -- "$inventory"' EXIT

# Enumerate the complete fixture first. A failed producer can never be hidden by
# process substitution or a partial consumer.
/usr/bin/find -P "$root" -mindepth 1 -print0 >"$inventory" || exit 65
/usr/bin/sort -z -o "$inventory" "$inventory" || exit 65

entries=0
files=0
total=0
while IFS= read -r -d '' entry; do
  entries=$((entries + 1))
  (( entries <= 128 )) || exit 66
  rel=${entry#./}
  [[ $rel != *$'\n'* && $rel != *$'\t'* ]] || exit 67
  slashes=${rel//[^\/]/}
  (( ${#slashes} < 16 )) || exit 68
  if [[ -d $entry && ! -L $entry ]]; then
    [[ -r $entry && -x $entry ]] || exit 69
    continue
  fi
  [[ -f $entry && ! -L $entry && -r $entry ]] || exit 70
  bytes=$(/usr/bin/stat -c '%s' -- "$entry") || exit 71
  (( bytes <= 1048576 )) || exit 72
  files=$((files + 1))
  total=$((total + bytes))
  (( files <= 64 && total <= 4194304 )) || exit 73
  printf '\n--- FILE %s ---\n' "$rel"
  /usr/bin/cat -- "$entry"
done <"$inventory"
(( files >= 1 )) || exit 74
printf '\nbehavior-evidence-complete\n'
