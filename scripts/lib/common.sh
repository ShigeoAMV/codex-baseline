#!/usr/bin/env bash

# Shared Unix/WSL implementation for codex-baseline. This file is sourced by
# codex-baseline.sh and must never be sourced from an untrusted repository.

# shellcheck disable=SC2034 # consumed by the sourcing command implementation
CB_SCHEMA=1
CB_BEGIN_PREFIX='<!-- codex-baseline:begin version='
CB_END_MARKER='<!-- codex-baseline:end -->'

cb_err() {
  printf 'codex-baseline: %s\n' "$*" >&2
}

cb_die() {
  cb_err "$*"
  exit 1
}

cb_require_command() {
  command -v "$1" >/dev/null 2>&1 || cb_die "required command not found: $1"
}

cb_sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -- "$1" | awk '{print $1}'
  else
    cb_die 'sha256sum or shasum is required'
  fi
}

cb_sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    cb_die 'sha256sum or shasum is required'
  fi
}

# Hash the complete release-candidate source while excluding only generated
# results and repository metadata. The inventory is type-aware and rejects
# links, special files, and ambiguous control characters rather than silently
# omitting them from a live-evaluation receipt.
cb_source_tree_hash() {
  local root=$1 inventory manifest entry rel mode digest error='' excluded
  local entries=0 total_bytes=0 bytes
  [[ $root == /* && -d $root && ! -L $root ]] || cb_die "unsafe source tree: $root"
  for excluded in "$root/.git" "$root/benchmark-results" "$root/behavior-results" "$root/.codebase-memory"; do
    [[ ! -L $excluded ]] || cb_die "linked excluded source path is forbidden: $excluded"
    if [[ -e $excluded && $excluded != "$root/.git" && ! -d $excluded ]]; then
      cb_die "excluded result path is not a directory: $excluded"
    fi
    if [[ -e $excluded && $excluded == "$root/.git" && ! -d $excluded && ! -f $excluded ]]; then
      cb_die "unsupported Git metadata path: $excluded"
    fi
  done
  inventory=$(mktemp "${TMPDIR:-/tmp}/codex-baseline-source-inventory.XXXXXX")
  manifest=$(mktemp "${TMPDIR:-/tmp}/codex-baseline-source-manifest.XXXXXX")
  if ! mode=$(stat -c '%a' -- "$root"); then
    rm -f -- "$inventory" "$manifest"
    cb_die "cannot stat source root: $root"
  fi
  printf 'd\t%s\t.\n' "$mode" >"$manifest"
  if ! find -P "$root" -mindepth 1 \
    \( -path "$root/.git" -o -path "$root/benchmark-results" -o -path "$root/behavior-results" -o -path "$root/.codebase-memory" \) -prune -o \
    -print0 >"$inventory"; then
    rm -f -- "$inventory" "$manifest"
    cb_die "cannot inventory source tree: $root"
  fi
  LC_ALL=C sort -z -o "$inventory" "$inventory"
  while IFS= read -r -d '' entry; do
    rel=${entry#"$root"/}
    entries=$((entries + 1))
    if (( entries > 20000 )); then
      error='source tree exceeds the 20000-entry evaluation limit'
      break
    fi
    if [[ $rel == *$'\n'* || $rel == *$'\t'* ]]; then
      error="source path contains unsupported control characters: $rel"
      break
    fi
    if [[ -d $entry && ! -L $entry ]]; then
      if ! mode=$(stat -c '%a' -- "$entry"); then
        error="cannot stat source directory: $rel"
        break
      fi
      printf 'd\t%s\t%s\n' "$mode" "$rel" >>"$manifest"
      continue
    fi
    if [[ ! -f $entry || -L $entry || ! -r $entry ]]; then
      error="linked, special, or unreadable source entry is forbidden: $rel"
      break
    fi
    if ! mode=$(stat -c '%a' -- "$entry"); then
      error="cannot stat source entry: $rel"
      break
    fi
    if ! bytes=$(stat -c '%s' -- "$entry"); then
      error="cannot size source entry: $rel"
      break
    fi
    total_bytes=$((total_bytes + bytes))
    if (( total_bytes > 1073741824 )); then
      error='source tree exceeds the 1 GiB evaluation limit'
      break
    fi
    digest=$(cb_sha256_file "$entry")
    printf 'f\t%s\t%s\t%s\n' "$mode" "$digest" "$rel" >>"$manifest"
  done <"$inventory"
  if [[ -n $error ]]; then
    rm -f -- "$inventory" "$manifest"
    cb_die "$error"
  fi
  digest=$(cb_sha256_file "$manifest")
  rm -f -- "$inventory" "$manifest"
  printf '%s' "$digest"
}

# Copy exactly the tree covered by cb_source_tree_hash into a new private
# snapshot. Excluded metadata/results never enter the snapshot. The caller must
# compare both source and snapshot hashes with its frozen value after this
# function returns; that comparison is the race detector for the path-based
# copy itself.
cb_copy_source_tree() {
  local source=$1 target=$2 inventory entry rel mode error='' excluded
  [[ $source == /* && -d $source && ! -L $source ]] || cb_die "unsafe source tree: $source"
  [[ $target == /* && -d $target && ! -L $target ]] || cb_die "unsafe source snapshot target: $target"
  [[ -z $(find -P "$target" -mindepth 1 -print -quit) ]] || cb_die "source snapshot target is not empty: $target"
  for excluded in "$source/.git" "$source/benchmark-results" "$source/behavior-results" "$source/.codebase-memory"; do
    [[ ! -L $excluded ]] || cb_die "linked excluded source path is forbidden: $excluded"
  done
  inventory=$(mktemp "${TMPDIR:-/tmp}/codex-baseline-source-copy.XXXXXX")
  if ! find -P "$source" -mindepth 1 \
    \( -path "$source/.git" -o -path "$source/benchmark-results" -o -path "$source/behavior-results" -o -path "$source/.codebase-memory" \) -prune -o \
    -print0 >"$inventory"; then
    rm -f -- "$inventory"
    cb_die "cannot inventory source tree for snapshot: $source"
  fi
  LC_ALL=C sort -z -o "$inventory" "$inventory"
  while IFS= read -r -d '' entry; do
    rel=${entry#"$source"/}
    if [[ $rel == *$'\n'* || $rel == *$'\t'* ]]; then
      error='source snapshot path contains unsupported control characters'
      break
    fi
    if [[ -d $entry && ! -L $entry ]]; then
      mkdir -p -- "$target/$rel" || { error="cannot create source snapshot directory: $rel"; break; }
    elif [[ -f $entry && ! -L $entry && -r $entry ]]; then
      mkdir -p -- "$(dirname -- "$target/$rel")" || { error="cannot create source snapshot parent: $rel"; break; }
      cp --reflink=never -- "$entry" "$target/$rel" || { error="cannot copy source snapshot entry: $rel"; break; }
      mode=$(stat -c '%a' -- "$entry") || { error="cannot stat source snapshot entry: $rel"; break; }
      chmod "$mode" -- "$target/$rel" || { error="cannot set source snapshot mode: $rel"; break; }
    else
      error="linked, special, or unreadable source entry is forbidden: $rel"
      break
    fi
  done <"$inventory"
  if [[ -z $error ]]; then
    while IFS= read -r -d '' entry; do
      rel=${entry#"$source"/}
      [[ -d $entry && ! -L $entry ]] || continue
      mode=$(stat -c '%a' -- "$entry") || { error="cannot stat source snapshot directory: $rel"; break; }
      chmod "$mode" -- "$target/$rel" || { error="cannot set source snapshot directory mode: $rel"; break; }
    done <"$inventory"
  fi
  if [[ -z $error ]]; then
    mode=$(stat -c '%a' -- "$source") || error='cannot stat source root for snapshot'
    [[ -n $error ]] || chmod "$mode" -- "$target" || error='cannot set source snapshot root mode'
  fi
  rm -f -- "$inventory"
  [[ -z $error ]] || cb_die "$error"
}

cb_write_field() {
  local path=$1 value=$2 tmp
  tmp="${path}.tmp.$$"
  [[ ! -L $path && ! -e $tmp && ! -L $tmp ]] || cb_die "unsafe state field path: $path"
  printf '%s\n' "$value" >"$tmp"
  mv -f -- "$tmp" "$path"
  cb_sync_file "$path"
}

cb_sync_file() {
  local path=$1
  if command -v sync >/dev/null 2>&1 && sync --help 2>&1 | grep -q -- ' -f'; then
    sync -f -- "$path" 2>/dev/null || sync 2>/dev/null || true
  elif command -v sync >/dev/null 2>&1; then
    sync 2>/dev/null || true
  fi
}

cb_sync_parent() {
  local path=$1
  cb_sync_file "$(dirname -- "$path")"
}

cb_read_field() {
  local path=$1 value=''
  [[ ! -L $path ]] || cb_die "symbolic state field is not allowed: $path"
  if [[ -f $path ]]; then
    IFS= read -r value <"$path" || true
  fi
  printf '%s' "$value"
}

cb_kind() {
  local path=$1
  if [[ -L $path ]]; then
    printf 'link'
  elif [[ -f $path ]]; then
    printf 'file'
  elif [[ -d $path ]]; then
    printf 'tree'
  elif [[ -e $path ]]; then
    printf 'other'
  else
    printf 'absent'
  fi
}

cb_tree_hash() {
  local root=$1 entry rel mode digest manifest
  [[ -d $root && ! -L $root ]] || cb_die "not a safe directory: $root"
  manifest=$(mktemp "${TMPDIR:-/tmp}/codex-baseline-tree.XXXXXX")
  mode=$(stat -c '%a' -- "$root")
  printf 'd\t%s\t.\n' "$mode" >"$manifest"
  while IFS= read -r -d '' entry; do
    rel=${entry#"$root"/}
    [[ $rel != *$'\n'* && $rel != *$'\t'* ]] || {
      rm -f -- "$manifest"
      cb_die "unsupported control character in path below $root"
    }
    if [[ -L $entry ]]; then
      rm -f -- "$manifest"
      cb_die "symbolic links are not allowed in managed trees: $entry"
    elif [[ -d $entry ]]; then
      mode=$(stat -c '%a' -- "$entry")
      printf 'd\t%s\t%s\n' "$mode" "$rel" >>"$manifest"
    elif [[ -f $entry ]]; then
      mode=$(stat -c '%a' -- "$entry")
      digest=$(cb_sha256_file "$entry")
      printf 'f\t%s\t%s\t%s\n' "$mode" "$digest" "$rel" >>"$manifest"
    else
      rm -f -- "$manifest"
      cb_die "unsupported object in managed tree: $entry"
    fi
  done < <(find -P "$root" -mindepth 1 -print0 | LC_ALL=C sort -z)
  digest=$(cb_sha256_file "$manifest")
  rm -f -- "$manifest"
  printf '%s' "$digest"
}

cb_object_hash() {
  local kind=$1 path=$2
  case $kind in
    absent) printf 'absent' ;;
    file) [[ -f $path && ! -L $path ]] || cb_die "expected regular file: $path"; cb_sha256_file "$path" ;;
    tree) cb_tree_hash "$path" ;;
    block) cb_block_hash "$path" ;;
    *) cb_die "unsupported object kind: $kind" ;;
  esac
}

cb_marker_counts() {
  local file=$1 starts=0 ends=0
  if [[ -f $file && ! -L $file ]]; then
    starts=$(LC_ALL=C grep -c '^<!-- codex-baseline:begin version=[^>]* -->$' "$file" || true)
    ends=$(LC_ALL=C grep -c '^<!-- codex-baseline:end -->$' "$file" || true)
  fi
  printf '%s %s' "$starts" "$ends"
}

cb_extract_block() {
  local file=$1 output=$2 counts starts ends
  : >"$output"
  [[ -e $file ]] || return 1
  [[ -f $file && ! -L $file ]] || cb_die "guidance target is not a regular file: $file"
  counts=$(cb_marker_counts "$file")
  starts=${counts%% *}
  ends=${counts##* }
  if [[ $starts -eq 0 && $ends -eq 0 ]]; then
    return 1
  fi
  [[ $starts -eq 1 && $ends -eq 1 ]] || cb_die "malformed or duplicate baseline markers in $file"
  awk '
    /^<!-- codex-baseline:begin version=[^>]* -->$/ { active=1 }
    active { print }
    /^<!-- codex-baseline:end -->$/ && active { exit }
  ' "$file" >"$output"
  [[ $(tail -n 1 "$output") == "$CB_END_MARKER" ]] || cb_die "baseline end marker precedes begin marker in $file"
}

cb_block_hash() {
  local file=$1 tmp digest
  tmp=$(mktemp "${TMPDIR:-/tmp}/codex-baseline-block.XXXXXX")
  if cb_extract_block "$file" "$tmp"; then
    digest=$(cb_sha256_file "$tmp")
  else
    digest=absent
  fi
  rm -f -- "$tmp"
  printf '%s' "$digest"
}

cb_render_managed_block() {
  local block_source=$1 version=$2 output=$3
  {
    printf '%s%s -->\n' "$CB_BEGIN_PREFIX" "$version"
    awk '1' "$block_source"
    printf '%s\n' "$CB_END_MARKER"
  } >"$output"
}

cb_replace_block() {
  local live=$1 desired_block=$2 output=$3 counts starts ends
  local start_line end_line
  if [[ ! -e $live ]]; then
    cp -- "$desired_block" "$output"
    return
  fi
  [[ -f $live && ! -L $live ]] || cb_die "guidance target is not a regular file: $live"
  counts=$(cb_marker_counts "$live")
  starts=${counts%% *}
  ends=${counts##* }
  [[ $starts -le 1 && $ends -le 1 && $starts -eq $ends ]] || cb_die "malformed or duplicate baseline markers in $live"
  if [[ $starts -eq 0 ]]; then
    cp -- "$live" "$output"
    if [[ -s $output && $(tail -c 1 "$output" | wc -l) -eq 0 ]]; then
      printf '\n' >>"$output"
    fi
    printf '\n' >>"$output"
    awk '1' "$desired_block" >>"$output"
    return
  fi
  start_line=$(LC_ALL=C grep -n '^<!-- codex-baseline:begin version=[^>]* -->$' "$live" | cut -d: -f1)
  end_line=$(LC_ALL=C grep -n '^<!-- codex-baseline:end -->$' "$live" | cut -d: -f1)
  [[ $end_line -ge $start_line ]] || cb_die "baseline marker order is invalid in $live"
  : >"$output"
  if [[ $start_line -gt 1 ]]; then
    head -n "$((start_line - 1))" -- "$live" >>"$output"
  fi
  cat -- "$desired_block" >>"$output"
  tail -n "+$((end_line + 1))" -- "$live" >>"$output"
}

cb_remove_block() {
  local live=$1 output=$2 counts starts ends start_line end_line
  if [[ ! -e $live ]]; then
    : >"$output"
    return
  fi
  [[ -f $live && ! -L $live ]] || cb_die "guidance target is not a regular file: $live"
  counts=$(cb_marker_counts "$live")
  starts=${counts%% *}
  ends=${counts##* }
  [[ $starts -le 1 && $ends -le 1 && $starts -eq $ends ]] || cb_die "malformed or duplicate baseline markers in $live"
  if [[ $starts -eq 0 ]]; then
    cp -- "$live" "$output"
    return
  fi
  start_line=$(LC_ALL=C grep -n '^<!-- codex-baseline:begin version=[^>]* -->$' "$live" | cut -d: -f1)
  end_line=$(LC_ALL=C grep -n '^<!-- codex-baseline:end -->$' "$live" | cut -d: -f1)
  [[ $end_line -ge $start_line ]] || cb_die "baseline marker order is invalid in $live"
  : >"$output"
  if [[ $start_line -gt 1 ]]; then
    head -n "$((start_line - 1))" -- "$live" >>"$output"
  fi
  tail -n "+$((end_line + 1))" -- "$live" >>"$output"
}

cb_assert_safe_root() {
  local root=$1
  [[ -n $root && $root != / && $root != "$HOME" ]] || cb_die "unsafe managed root: $root"
  [[ $root == /* ]] || cb_die "managed root must be absolute: $root"
  [[ $root != *$'\n'* && $root != *$'\t'* ]] || cb_die 'managed root contains unsupported control characters'
}

cb_assert_target_under() {
  local target=$1 root=$2 canonical_root canonical_target rel segment cursor
  cb_require_command realpath
  [[ $target == /* && $root == /* ]] || cb_die 'managed paths must be absolute'
  canonical_root=$(realpath -ms -- "$root") || cb_die "cannot normalize managed root: $root"
  canonical_target=$(realpath -ms -- "$target") || cb_die "cannot normalize target: $target"
  case $canonical_target in
    "$canonical_root"/*) ;;
    *) cb_die "target escapes managed root: $target" ;;
  esac
  rel=${canonical_target#/}
  cursor=''
  IFS='/' read -r -a _cb_segments <<<"$rel"
  for segment in "${_cb_segments[@]}"; do
    [[ -n $segment && $segment != . && $segment != .. ]] || cb_die "unsafe path segment in $target"
    cursor="$cursor/$segment"
    if [[ -L $cursor ]]; then
      cb_die "symbolic-link path segment is not allowed: $cursor"
    fi
  done
}

cb_safe_mkdir_path() {
  local path=$1 normalized cursor segment
  local -a missing=()
  cb_require_command realpath
  [[ $path == /* && $path != / ]] || cb_die "unsafe directory path: $path"
  normalized=$(realpath -ms -- "$path") || cb_die "cannot normalize directory: $path"
  cursor=$normalized
  while [[ ! -e $cursor && ! -L $cursor ]]; do
    segment=$(basename -- "$cursor")
    [[ -n $segment && $segment != . && $segment != .. ]] || cb_die "unsafe path segment in $path"
    missing=("$segment" "${missing[@]}")
    cursor=$(dirname -- "$cursor")
  done
  [[ -d $cursor && ! -L $cursor ]] || cb_die "existing path is not a safe directory: $cursor"
  for segment in "${missing[@]}"; do
    cursor="$cursor/$segment"
    mkdir -- "$cursor"
    [[ -d $cursor && ! -L $cursor ]] || cb_die "failed to create safe directory: $cursor"
    cb_sync_parent "$cursor"
  done
}

cb_safe_mkdir_parent() {
  local target=$1 root=$2 parent
  parent=$(dirname -- "$target")
  cb_assert_target_under "$target" "$root"
  cb_safe_mkdir_path "$parent"
  cb_assert_target_under "$target" "$root"
}

cb_remove_internal() {
  local path=$1 root=$2 base
  [[ -n $path && $path != / ]] || cb_die 'refusing broad internal cleanup'
  cb_assert_target_under "$path" "$root"
  base=$(basename -- "$path")
  case $base in
    .codex-baseline-stage-*|.codex-baseline-old-*) rm -rf -- "$path" ;;
    *) cb_die "refusing to remove non-internal path: $path" ;;
  esac
}

cb_verify_source_manifest() {
  local root=$1 manifest operations line path bytes digest version declared_payload_hash actual_payload_hash
  local payload_entries expected_paths actual_paths
  manifest="$root/baseline/manifest.json"
  [[ -f $manifest && ! -L $manifest ]] || cb_die "source manifest missing: $manifest"
  grep -q '^  "schema": 1,$' "$manifest" || cb_die 'unsupported or malformed source manifest schema'
  version=$(sed -n 's/^  "version": "\([0-9][0-9.]*\)",$/\1/p' "$manifest")
  [[ -n $version && $(<"$root/VERSION") == "$version" ]] || cb_die 'VERSION and source manifest disagree'
  grep -Fqx '  "source_trust": "unsigned-local-source",' "$manifest" || cb_die 'source trust label is missing or unsupported'
  declared_payload_hash=$(sed -n 's/^  "payload_hash": "\([0-9a-f]\{64\}\)",$/\1/p' "$manifest")
  [[ -n $declared_payload_hash ]] || cb_die 'source payload hash is missing or malformed'
  payload_entries=$(mktemp "${TMPDIR:-/tmp}/codex-baseline-payload.XXXXXX")
  expected_paths=$(mktemp "${TMPDIR:-/tmp}/codex-baseline-expected.XXXXXX")
  actual_paths=$(mktemp "${TMPDIR:-/tmp}/codex-baseline-paths.XXXXXX")
  while IFS= read -r line; do
    path=$(sed -n 's/^    {"path": "\([A-Za-z0-9._\/-]*\)", "bytes": [0-9][0-9]*, "sha256": "[0-9a-f][0-9a-f]*"}[,]*$/\1/p' <<<"$line")
    bytes=$(sed -n 's/^    {"path": "[A-Za-z0-9._\/-]*", "bytes": \([0-9][0-9]*\), "sha256": "[0-9a-f][0-9a-f]*"}[,]*$/\1/p' <<<"$line")
    digest=$(sed -n 's/^    {"path": "[A-Za-z0-9._\/-]*", "bytes": [0-9][0-9]*, "sha256": "\([0-9a-f]\{64\}\)"}[,]*$/\1/p' <<<"$line")
    [[ -n $path && -n $bytes && -n $digest && $path != *..* ]] || { rm -f -- "$payload_entries" "$expected_paths" "$actual_paths"; cb_die "malformed payload entry: $line"; }
    case $path in VERSION|baseline/*|scripts/*|benchmarks/*) ;; *) rm -f -- "$payload_entries" "$expected_paths" "$actual_paths"; cb_die "unsafe payload entry: $path" ;; esac
    [[ -f $root/$path && ! -L $root/$path ]] || cb_die "payload file missing or linked: $path"
    [[ $(stat -c '%s' -- "$root/$path") == "$bytes" ]] || cb_die "payload byte length mismatch: $path"
    [[ $(cb_sha256_file "$root/$path") == "$digest" ]] || cb_die "payload hash mismatch: $path"
    printf '%s\t%s\t%s\n' "$path" "$bytes" "$digest" >>"$payload_entries"
    printf '%s\n' "$path" >>"$actual_paths"
  done < <(grep '^    {"path": ' "$manifest")
  {
    printf '%s\n' VERSION
    find -P "$root/baseline" -type f ! -path "$manifest" -printf '%P\n' | sed 's#^#baseline/#'
    printf '%s\n' scripts/codex-baseline.sh scripts/codex-baseline.ps1 scripts/onboard.sh scripts/onboard.ps1 scripts/benchmark.sh scripts/benchmark.ps1 scripts/lib/common.sh scripts/lib/evaluation.sh
    find -P "$root/benchmarks" -type f -printf '%P\n' | sed 's#^#benchmarks/#'
  } >"$expected_paths"
  LC_ALL=C sort -u -o "$expected_paths" "$expected_paths"
  LC_ALL=C sort -o "$actual_paths" "$actual_paths"
  cmp -s "$expected_paths" "$actual_paths" || { rm -f -- "$payload_entries" "$expected_paths" "$actual_paths"; cb_die 'source payload inventory differs from the manifest'; }
  LC_ALL=C sort -o "$payload_entries" "$payload_entries"
  actual_payload_hash=$(cb_sha256_file "$payload_entries")
  rm -f -- "$payload_entries" "$expected_paths" "$actual_paths"
  [[ $actual_payload_hash == "$declared_payload_hash" ]] || cb_die 'aggregate source payload hash mismatch'
  operations="$root/baseline/operations.json"
  grep -Fqx '  "contract": "codex-baseline-operations/v1",' "$operations" || cb_die 'operations contract identity mismatch'
  grep -Fqx '  "owned_text_encoding": "utf-8-no-bom",' "$operations" || cb_die 'operations encoding contract mismatch'
  grep -Fqx '  "owned_line_endings": "lf",' "$operations" || cb_die 'operations line-ending contract mismatch'
  grep -Fqx '  "transaction_states": ["planned", "prepared", "committing", "recovering", "committed", "rolled-back"],' "$operations" || cb_die 'operations transaction-state contract mismatch'
  grep -Fqx '  "object_states": ["planned", "prepared", "moving-old", "old-moved", "new-moved", "committed", "unchanged", "rolled-back"],' "$operations" || cb_die 'operations object-state contract mismatch'
  grep -Fqx '  "operations": ["install", "update", "rollback", "uninstall"],' "$operations" || cb_die 'operations command inventory mismatch'
  grep -Fqx '    "doctor": "codex-baseline-doctor/v1",' "$operations" || cb_die 'operations doctor-report contract mismatch'
  grep -Fqx '    "onboarding": "codex-baseline-onboarding/v1",' "$operations" || cb_die 'operations onboarding-report contract mismatch'
  grep -Fqx '    "benchmark": "codex-baseline-benchmark/v1"' "$operations" || cb_die 'operations benchmark-report contract mismatch'
  [[ $(grep -c '^    {"id": ' "$operations") -eq 8 ]] || cb_die 'operations object inventory must contain exactly eight objects'
  for line in \
    '    {"id": "00", "kind": "block", "root": "codex_home", "destination": "AGENTS.active.md", "source": "baseline/global/AGENTS.block.md"},' \
    '    {"id": "10", "kind": "tree", "root": "agents_home", "destination": "skills/codex-baseline-repo-onboarding", "source": "baseline/skills/codex-baseline-repo-onboarding"},' \
    '    {"id": "11", "kind": "tree", "root": "agents_home", "destination": "skills/codex-baseline-deep-work", "source": "baseline/skills/codex-baseline-deep-work"},' \
    '    {"id": "12", "kind": "tree", "root": "agents_home", "destination": "skills/codex-baseline-conformance-review", "source": "baseline/skills/codex-baseline-conformance-review"},' \
    '    {"id": "13", "kind": "tree", "root": "agents_home", "destination": "skills/codex-baseline-retrospective", "source": "baseline/skills/codex-baseline-retrospective"},' \
    '    {"id": "20", "kind": "file", "root": "codex_home", "destination": "agents/codex-baseline-reviewer.toml", "source": "baseline/agents/codex-baseline-reviewer.toml"},' \
    '    {"id": "30", "kind": "tree", "root": "codex_home", "destination": "codex-baseline/runtime", "source": "generated/runtime"},' \
    '    {"id": "31", "kind": "file", "root": "home", "destination": ".local/bin/codex-baseline{platform-extension}", "source": "generated/wrapper"}'
  do
    grep -Fqx -- "$line" "$operations" || cb_die "operations object contract mismatch: $line"
  done
  printf '%s' "$version"
}

cb_json_escape() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

cb_json_string_array() {
  local separator='' value
  printf '['
  for value in "$@"; do
    printf '%s"%s"' "$separator" "$(cb_json_escape "$value")"
    separator=,
  done
  printf ']'
}
