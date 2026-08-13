#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source_root=$(cd -- "$script_dir/.." && pwd -P)
research_manifest="$source_root/docs/research/manifest.json"
payload_manifest="$source_root/baseline/manifest.json"
json=0

case ${1:-} in
  '') ;;
  --json) json=1 ;;
  -h|--help)
    printf '%s\n' 'Usage: scripts/research-check.sh [--json]' '' \
      'Validate versioned research metadata and report offline freshness.' \
      'This command never fetches the network or edits research records.'
    exit 0
    ;;
  *) printf 'research-check: unknown option: %s\n' "$1" >&2; exit 2 ;;
esac

for command in date jq; do
  command -v "$command" >/dev/null 2>&1 || { printf 'research-check: missing command: %s\n' "$command" >&2; exit 1; }
done

jq -e '
  keys == ["checked","codex","contract","review_by","schema","sources"] and
  .schema == 1 and .contract == "codex-baseline-research/v1" and
  (.checked | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) and
  (.review_by | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) and
  (.codex | keys == ["commit","release_date","stable_version"]) and
  (.codex.stable_version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
  (.codex.commit | test("^[0-9a-f]{40}$")) and
  (.sources | length >= 10) and
  ([.sources[].id] | length == (unique | length)) and
  ([.sources[].tier] | unique | sort == [1,2,3,4]) and
  all(.sources[];
    keys == ["id","license","observed","tier","url","version"] and
    (.id | test("^[a-z0-9][a-z0-9-]*$")) and
    (.tier >= 1 and .tier <= 4) and
    (.url | startswith("https://")) and
    (.observed | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) and
    (.version | type == "string" and length > 0) and
    (.license == null or (.license | type == "string" and length > 0)))
' "$research_manifest" >/dev/null || { printf '%s\n' 'research-check: invalid research manifest contract' >&2; exit 1; }

checked=$(jq -r .checked "$research_manifest")
review_by=$(jq -r .review_by "$research_manifest")
payload_checked=$(jq -r .research_checked "$payload_manifest")
payload_review_by=$(jq -r .research_review_by "$payload_manifest")
[[ $checked == "$payload_checked" && $review_by == "$payload_review_by" ]] || {
  printf '%s\n' 'research-check: research and payload freshness metadata disagree' >&2
  exit 1
}

review_epoch=$(date -u -d "$review_by 23:59:59" +%s) || { printf '%s\n' 'research-check: invalid review_by date' >&2; exit 1; }
now_epoch=$(date -u +%s)
state=current
exit_code=0
if [[ $now_epoch -gt $review_epoch ]]; then
  state=stale
  exit_code=1
fi

if [[ $json -eq 1 ]]; then
  jq -nc --arg checked "$checked" --arg review_by "$review_by" --arg state "$state" \
    --argjson sources "$(jq '.sources | length' "$research_manifest")" \
    '{schema:1,contract:"codex-baseline-research-check/v1",mode:"offline",checked:$checked,review_by:$review_by,state:$state,sources:$sources,network_access:false}'
else
  printf 'Research: %s (checked %s, review by %s, %d pinned sources, offline)\n' \
    "$state" "$checked" "$review_by" "$(jq '.sources | length' "$research_manifest")"
fi
exit "$exit_code"
