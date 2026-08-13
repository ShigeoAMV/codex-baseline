#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
failures=0

while IFS= read -r file; do
  while IFS= read -r match; do
    target=${match#](}
    target=${target%)}
    case $target in
      http://*|https://*|mailto:*|app://*|\#*|'') continue ;;
    esac
    if [[ $target == '<'*'>' ]]; then
      target=${target#<}
      target=${target%>}
    fi
    target=${target%%#*}
    target=${target//%20/ }
    [[ -n $target ]] || continue
    resolved=$(realpath -m -- "$(dirname -- "$file")/$target")
    case $resolved in
      "$ROOT"|"$ROOT"/*) ;;
      *) printf 'documentation link escapes repository: %s -> %s\n' "${file#"$ROOT"/}" "$target" >&2; failures=$((failures + 1)); continue ;;
    esac
    if [[ ! -e $resolved ]]; then
      printf 'broken local documentation link: %s -> %s\n' "${file#"$ROOT"/}" "$target" >&2
      failures=$((failures + 1))
    fi
  done < <(rg -o --no-filename '\]\([^)]+\)' "$file" || true)
done < <(rg --files "$ROOT" -g '*.md' -g '!benchmark-results/**' -g '!behavior-results/**' -g '!.codebase-memory/**' | LC_ALL=C sort)

[[ $failures -eq 0 ]] || exit 1
printf 'documentation links: PASS\n'
