#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

CB_SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
CB_SOURCE_ROOT=$(cd -- "$CB_SCRIPT_DIR/.." && pwd -P)
# shellcheck source=scripts/lib/common.sh
source "$CB_SCRIPT_DIR/lib/common.sh"

CB_DRY_RUN=0
CB_JSON=0
CB_ACKNOWLEDGE_UNVERIFIED_SOURCE=0
CB_ACTIVE_TX=''
CB_LOCK_HELD=0
CB_TX_ROOT=''
CB_DRY_TX_ROOT=''
CB_NEW_TX=''
CB_MUTATION_COUNT=0
CB_VERSION='unknown'
CB_VERIFIED_SOURCE_ROOT=''
CB_TEMP_PATHS=()

cb_usage() {
  cat <<'EOF'
Usage: codex-baseline <command> [options]

Commands:
  install [--dry-run] [--acknowledge-unverified-source]
                            Install from this reviewed local source tree
  update [--dry-run] [--acknowledge-unverified-source]
                            Apply the current local source as an update
  doctor [--json]           Inspect installation, Codex, paths, and conflicts
  rollback [--dry-run]      Restore the state before the current transaction
  uninstall [--dry-run]     Remove only baseline-owned content
  onboard [options] [repo]  Perform bounded static repository discovery
  benchmark [options]       Run the maintained evaluation harness
  help                      Show this help

Global mutation rules: no network fetch, no auth/session access, dry-run shows
targets, live drift is a conflict, and every applied operation records a backup
transaction under CODEX_HOME/codex-baseline/state.
EOF
}

cb_print_source_provenance() {
  local root=$1 payload_hash=$2 revision=unversioned dirty=unknown status_output='' untracked_output=''
  if command -v git >/dev/null 2>&1 && [[ -e $root/.git ]]; then
    revision=$(env GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_OPTIONAL_LOCKS=0 \
      git -c core.fsmonitor=false -C "$root" rev-parse --verify HEAD 2>/dev/null || printf 'unversioned')
    if [[ $revision == unversioned ]]; then
      dirty=yes
    elif status_output=$(env GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_OPTIONAL_LOCKS=0 \
      git -c core.fsmonitor=false -C "$root" status --porcelain=v1 --untracked-files=no 2>/dev/null) && \
      untracked_output=$(env GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_OPTIONAL_LOCKS=0 \
        git -c core.fsmonitor=false -C "$root" ls-files --others --exclude-standard --directory 2>/dev/null); then
      if [[ -n $status_output || -n $untracked_output ]]; then dirty=yes; else dirty=no; fi
    fi
  fi
  printf 'source-origin: %s\nsource-revision: %s\nsource-dirty: %s\nsource-trust: unverified-source (unsigned-local-source)\nsource-payload-sha256: %s\n' \
    "$root" "$revision" "$dirty" "$payload_hash"
}

cb_freeze_verified_source() {
  local source=$1 expected_manifest_hash=$2 expected_payload_hash=$3 snapshot version payload_hash manifest_hash
  snapshot=$(mktemp -d "${TMPDIR:-/tmp}/codex-baseline-source.XXXXXX")
  cb_register_temp "$snapshot"

  if [[ ${CODEX_BASELINE_TESTING:-0} == 1 && ${CODEX_BASELINE_TEST_MUTATE_SOURCE_AFTER_VERIFY:-0} == 1 ]]; then
    printf '\nsource-race-test\n' >>"$source/baseline/global/AGENTS.block.md"
  fi

  mkdir -p -- "$snapshot/scripts/lib"
  cp -p -- "$source/VERSION" "$snapshot/VERSION"
  cp -a -- "$source/baseline" "$snapshot/baseline"
  cp -p -- \
    "$source/scripts/codex-baseline.sh" "$source/scripts/codex-baseline.ps1" \
    "$source/scripts/onboard.sh" "$source/scripts/onboard.ps1" \
    "$source/scripts/benchmark.sh" "$source/scripts/benchmark.ps1" \
    "$snapshot/scripts/"
  cp -p -- "$source/scripts/lib/common.sh" "$source/scripts/lib/evaluation.sh" "$snapshot/scripts/lib/"
  cp -a -- "$source/benchmarks" "$snapshot/benchmarks"

  version=$(cb_verify_source_manifest "$snapshot")
  manifest_hash=$(cb_sha256_file "$snapshot/baseline/manifest.json")
  payload_hash=$(sed -n 's/^  "payload_hash": "\([0-9a-f]\{64\}\)",$/\1/p' "$snapshot/baseline/manifest.json")
  [[ $manifest_hash == "$expected_manifest_hash" ]] || cb_die 'source manifest changed while creating the verified snapshot'
  [[ $payload_hash == "$expected_payload_hash" ]] || cb_die 'source payload changed while creating the verified snapshot'
  [[ $version == "$CB_VERSION" ]] || cb_die 'source version changed while creating the verified snapshot'
  CB_VERIFIED_SOURCE_ROOT=$snapshot
}

cb_init_paths() {
  CB_HOME=${HOME:?HOME must be set}
  CB_CODEX_HOME=${CODEX_HOME:-"$CB_HOME/.codex"}
  CB_AGENTS_HOME=${AGENTS_HOME:-"$CB_HOME/.agents"}
  CB_ROOT="$CB_CODEX_HOME/codex-baseline"
  CB_STATE_ROOT="$CB_ROOT/state"
  CB_TX_ROOT=${CB_TX_ROOT:-$CB_STATE_ROOT}
  CB_RUNTIME="$CB_ROOT/runtime"
  CB_LOCK="$CB_STATE_ROOT/lock"
  CB_CURRENT="$CB_STATE_ROOT/current"
  CB_PENDING="$CB_STATE_ROOT/pending"
  [[ $CB_HOME == /* && $CB_HOME != / && $CB_HOME != *$'\n'* && $CB_HOME != *$'\t'* ]] || cb_die "HOME must be a safe absolute directory: $CB_HOME"
  cb_assert_safe_root "$CB_CODEX_HOME"
  cb_assert_safe_root "$CB_AGENTS_HOME"
}

cb_init_mutation_roots() {
  cb_safe_mkdir_path "$CB_CODEX_HOME"
  cb_safe_mkdir_path "$CB_AGENTS_HOME"
  cb_assert_target_under "$CB_STATE_ROOT" "$CB_CODEX_HOME"
  cb_safe_mkdir_path "$CB_STATE_ROOT"
}

cb_register_temp() {
  CB_TEMP_PATHS+=("$1")
}

cb_cleanup_temps() {
  local path base
  for path in "${CB_TEMP_PATHS[@]}"; do
    [[ -n $path && $path != / ]] || continue
    base=$(basename -- "$path")
    case $base in
      codex-baseline-*) rm -rf -- "$path" ;;
      *) cb_err "refusing unexpected temporary cleanup path: $path" ;;
    esac
  done
  CB_TEMP_PATHS=()
}

cb_release_lock() {
  if [[ $CB_LOCK_HELD -eq 1 && -d $CB_LOCK ]]; then
    rm -f -- "$CB_LOCK/pid" "$CB_LOCK/proc_start"
    rmdir -- "$CB_LOCK" 2>/dev/null || true
  fi
  CB_LOCK_HELD=0
}

cb_process_start() {
  local pid=$1
  if [[ -r /proc/$pid/stat ]]; then
    awk '{print $22}' "/proc/$pid/stat"
  else
    printf 'unknown'
  fi
}

cb_acquire_lock() {
  local pid start recorded_pid recorded_start
  cb_safe_mkdir_path "$CB_STATE_ROOT"
  [[ ! -L $CB_LOCK ]] || cb_die "operation lock is a symbolic link: $CB_LOCK"
  if mkdir -- "$CB_LOCK" 2>/dev/null; then
    cb_write_field "$CB_LOCK/pid" "$$"
    cb_write_field "$CB_LOCK/proc_start" "$(cb_process_start "$$")"
    CB_LOCK_HELD=1
    return
  fi
  recorded_pid=$(cb_read_field "$CB_LOCK/pid")
  recorded_start=$(cb_read_field "$CB_LOCK/proc_start")
  if [[ $recorded_pid =~ ^[0-9]+$ ]] && kill -0 "$recorded_pid" 2>/dev/null; then
    start=$(cb_process_start "$recorded_pid")
    if [[ $recorded_start == unknown || $start == "$recorded_start" ]]; then
      cb_die "another baseline operation holds the lock (pid $recorded_pid)"
    fi
  fi
  cb_err 'recovering stale operation lock'
  rm -f -- "$CB_LOCK/pid" "$CB_LOCK/proc_start"
  rmdir -- "$CB_LOCK" || cb_die "cannot recover stale lock: $CB_LOCK"
  mkdir -- "$CB_LOCK" || cb_die 'cannot acquire recovered lock'
  cb_write_field "$CB_LOCK/pid" "$$"
  cb_write_field "$CB_LOCK/proc_start" "$(cb_process_start "$$")"
  CB_LOCK_HELD=1
}

cb_require_tx_id() {
  [[ $1 =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+$ ]] || cb_die "invalid transaction id: $1"
}

cb_require_scalar_file() {
  local path=$1 label=$2 lines bytes
  [[ -f $path && ! -L $path ]] || cb_die "missing or unsafe transaction field $label: $path"
  lines=$(wc -l <"$path")
  bytes=$(wc -c <"$path")
  [[ $lines -eq 1 && $bytes -le 4096 ]] || cb_die "transaction field is not a bounded scalar ($label): $path"
}

cb_valid_hash() {
  [[ $1 == absent || $1 =~ ^[0-9a-f]{64}$ ]]
}

cb_expected_object() {
  local id=$1
  CB_EXPECTED_TARGET_ALT=''
  case $id in
    00) CB_EXPECTED_KIND=block; CB_EXPECTED_ROOT=$CB_CODEX_HOME; CB_EXPECTED_TARGET=$CB_CODEX_HOME/AGENTS.md; CB_EXPECTED_TARGET_ALT=$CB_CODEX_HOME/AGENTS.override.md; CB_EXPECTED_SOURCE=baseline/global/AGENTS.block.md ;;
    10) CB_EXPECTED_KIND=tree; CB_EXPECTED_ROOT=$CB_AGENTS_HOME; CB_EXPECTED_TARGET=$CB_AGENTS_HOME/skills/codex-baseline-repo-onboarding; CB_EXPECTED_SOURCE=baseline/skills/codex-baseline-repo-onboarding ;;
    11) CB_EXPECTED_KIND=tree; CB_EXPECTED_ROOT=$CB_AGENTS_HOME; CB_EXPECTED_TARGET=$CB_AGENTS_HOME/skills/codex-baseline-deep-work; CB_EXPECTED_SOURCE=baseline/skills/codex-baseline-deep-work ;;
    12) CB_EXPECTED_KIND=tree; CB_EXPECTED_ROOT=$CB_AGENTS_HOME; CB_EXPECTED_TARGET=$CB_AGENTS_HOME/skills/codex-baseline-conformance-review; CB_EXPECTED_SOURCE=baseline/skills/codex-baseline-conformance-review ;;
    13) CB_EXPECTED_KIND=tree; CB_EXPECTED_ROOT=$CB_AGENTS_HOME; CB_EXPECTED_TARGET=$CB_AGENTS_HOME/skills/codex-baseline-retrospective; CB_EXPECTED_SOURCE=baseline/skills/codex-baseline-retrospective ;;
    20) CB_EXPECTED_KIND='file'; CB_EXPECTED_ROOT=$CB_CODEX_HOME; CB_EXPECTED_TARGET=$CB_CODEX_HOME/agents/codex-baseline-reviewer.toml; CB_EXPECTED_SOURCE=baseline/agents/codex-baseline-reviewer.toml ;;
    30) CB_EXPECTED_KIND=tree; CB_EXPECTED_ROOT=$CB_CODEX_HOME; CB_EXPECTED_TARGET=$CB_RUNTIME; CB_EXPECTED_SOURCE=runtime ;;
    31) CB_EXPECTED_KIND='file'; CB_EXPECTED_ROOT=$CB_HOME; CB_EXPECTED_TARGET=$CB_HOME/.local/bin/codex-baseline; CB_EXPECTED_SOURCE=generated-wrapper ;;
    *) cb_die "unexpected transaction object id: $id" ;;
  esac
}

cb_validate_object_contract() {
  local tx=$1 obj=$2 id kind target root desired previous desired_present previous_existed change status previous_kind
  local field value stage old parent base expected_prefix source
  id=$(basename -- "$obj")
  [[ $id =~ ^(00|10|11|12|13|20|30|31)$ && -d $obj && ! -L $obj ]] || cb_die "unsafe transaction object: $obj"
  while IFS= read -r -d '' entry; do
    field=$(basename -- "$entry")
    case $field in
      kind|target|root|desired_hash|desired_present|source|status|previous_hash|previous_kind|previous_existed|previous_managed_existed|previous_file_hash|change|stage|old|backup|backup_file|backup_hash|desired_file_hash|installed_hash|installed_file_hash|restore_source|restore_mode) ;;
      *) cb_die "unexpected transaction object field: $entry" ;;
    esac
    [[ ! -L $entry ]] || cb_die "symbolic transaction object entry is not allowed: $entry"
  done < <(find -P "$obj" -mindepth 1 -maxdepth 1 -print0 | LC_ALL=C sort -z)
  cb_expected_object "$id"
  for field in kind target root desired_hash desired_present source status previous_hash previous_kind previous_existed change; do
    cb_require_scalar_file "$obj/$field" "$id/$field"
  done
  kind=$(cb_read_field "$obj/kind")
  target=$(cb_read_field "$obj/target")
  root=$(cb_read_field "$obj/root")
  desired=$(cb_read_field "$obj/desired_hash")
  desired_present=$(cb_read_field "$obj/desired_present")
  previous=$(cb_read_field "$obj/previous_hash")
  previous_kind=$(cb_read_field "$obj/previous_kind")
  previous_existed=$(cb_read_field "$obj/previous_existed")
  change=$(cb_read_field "$obj/change")
  status=$(cb_read_field "$obj/status")
  source=$(cb_read_field "$obj/source")
  [[ $kind == "$CB_EXPECTED_KIND" && $root == "$CB_EXPECTED_ROOT" ]] || cb_die "transaction object contract mismatch: $obj"
  [[ $target == "$CB_EXPECTED_TARGET" || ( -n $CB_EXPECTED_TARGET_ALT && $target == "$CB_EXPECTED_TARGET_ALT" ) ]] || cb_die "unexpected managed target in transaction: $target"
  [[ $source == "$CB_EXPECTED_SOURCE" || $source =~ ^rollback:[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+/$id$ ]] || cb_die "unexpected transaction source label: $source"
  cb_assert_target_under "$target" "$root"
  [[ $desired_present =~ ^[01]$ && $previous_existed =~ ^[01]$ && $change =~ ^[01]$ ]] || cb_die "invalid boolean transaction field: $obj"
  if ! cb_valid_hash "$desired" || ! cb_valid_hash "$previous"; then cb_die "invalid transaction hash: $obj"; fi
  case $previous_kind in absent|file|tree|block) ;; *) cb_die "invalid previous kind in transaction: $obj" ;; esac
  case $status in planned|prepared|ready|moving-old|old-moved|new-moved|committed|unchanged|rolled-back) ;; *) cb_die "invalid object status in transaction: $obj" ;; esac
  if [[ $kind == block ]]; then
    cb_require_scalar_file "$obj/previous_managed_existed" "$id/previous_managed_existed"
    [[ $(cb_read_field "$obj/previous_managed_existed") =~ ^[01]$ ]] || cb_die "invalid previous-managed flag: $obj"
    cb_require_scalar_file "$obj/previous_file_hash" "$id/previous_file_hash"
    cb_valid_hash "$(cb_read_field "$obj/previous_file_hash")" || cb_die "invalid previous physical hash: $obj"
    if [[ $change == 1 && $desired_present == 1 ]]; then
      case $status in
        prepared|ready|moving-old|old-moved|new-moved|committed)
          cb_require_scalar_file "$obj/desired_file_hash" "$id/desired_file_hash"
          cb_valid_hash "$(cb_read_field "$obj/desired_file_hash")" || cb_die "invalid desired physical hash: $obj"
          ;;
      esac
    fi
  fi
  for field in installed_hash installed_file_hash desired_file_hash backup_hash; do
    if [[ -e $obj/$field || -L $obj/$field ]]; then
      cb_require_scalar_file "$obj/$field" "$id/$field"
      value=$(cb_read_field "$obj/$field")
      cb_valid_hash "$value" || cb_die "invalid optional transaction hash: $obj/$field"
    fi
  done
  parent=$(dirname -- "$target")
  if [[ -e $obj/stage || -L $obj/stage ]]; then
    cb_require_scalar_file "$obj/stage" "$id/stage"
    stage=$(cb_read_field "$obj/stage")
    base=$(basename -- "$stage")
    expected_prefix=".codex-baseline-stage-$tx-$id"
    [[ $(dirname -- "$stage") == "$parent" && ( $base == "$expected_prefix.delete" || $base == "$expected_prefix".[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9] ) ]] || cb_die "invalid transaction stage path: $stage"
    cb_assert_target_under "$stage" "$root"
  fi
  if [[ -e $obj/old || -L $obj/old ]]; then
    cb_require_scalar_file "$obj/old" "$id/old"
    old=$(cb_read_field "$obj/old")
    base=$(basename -- "$old")
    expected_prefix=".codex-baseline-old-$tx-$id"
    [[ $(dirname -- "$old") == "$parent" && $base == "$expected_prefix".[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9] ]] || cb_die "invalid transaction old path: $old"
    cb_assert_target_under "$old" "$root"
  fi
}

cb_validate_tx() {
  local tx=$1 expected_state=${2:-} transaction_root=${3:-$CB_TX_ROOT} dir state operation parent entry rollback_target result_current
  local obj id restore_mode restore_source expected_source rollback_parent source_operation object_status
  local actual_ids expected_ids
  cb_require_tx_id "$tx"
  dir="$transaction_root/transactions/$tx"
  [[ $(dirname -- "$dir") == "$transaction_root/transactions" && -d $dir && ! -L $dir ]] || cb_die "unsafe or missing transaction directory: $dir"
  while IFS= read -r -d '' entry; do
    case $(basename -- "$entry") in
      schema|operation|version|created_utc|parent|state|objects|rollback_target|result_current) ;;
      *) cb_die "unexpected transaction field: $entry" ;;
    esac
    [[ ! -L $entry ]] || cb_die "symbolic transaction entry is not allowed: $entry"
  done < <(find -P "$dir" -mindepth 1 -maxdepth 1 -print0 | LC_ALL=C sort -z)
  for entry in schema operation version created_utc parent state; do cb_require_scalar_file "$dir/$entry" "$tx/$entry"; done
  [[ $(cb_read_field "$dir/schema") == "$CB_SCHEMA" ]] || cb_die "unsupported transaction schema: $tx"
  operation=$(cb_read_field "$dir/operation")
  case $operation in install|update|rollback|uninstall) ;; *) cb_die "invalid transaction operation: $tx" ;; esac
  state=$(cb_read_field "$dir/state")
  case $state in planned|prepared|committing|recovering|committed|rolled-back) ;; *) cb_die "invalid transaction state: $tx" ;; esac
  [[ -z $expected_state || $state == "$expected_state" ]] || cb_die "transaction $tx is not $expected_state"
  parent=$(cb_read_field "$dir/parent")
  [[ $(cb_read_field "$dir/version") =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || cb_die "invalid transaction version: $tx"
  [[ $(cb_read_field "$dir/created_utc") =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || cb_die "invalid transaction timestamp: $tx"
  if [[ -n $parent ]]; then
    cb_require_tx_id "$parent"
    [[ $parent != "$tx" ]] || cb_die "transaction cannot parent itself: $tx"
    [[ -d $CB_STATE_ROOT/transactions/$parent && ! -L $CB_STATE_ROOT/transactions/$parent ]] || cb_die "transaction parent is missing: $parent"
    cb_require_scalar_file "$CB_STATE_ROOT/transactions/$parent/state" "$parent/state"
    [[ $(cb_read_field "$CB_STATE_ROOT/transactions/$parent/state") == committed ]] || cb_die "transaction parent is not committed: $parent"
  fi
  [[ -d $dir/objects && ! -L $dir/objects ]] || cb_die "transaction object directory is unsafe: $tx"
  actual_ids=''
  while IFS= read -r -d '' entry; do
    [[ -d $entry && ! -L $entry ]] || cb_die "unexpected entry in transaction objects: $entry"
    if [[ -n $actual_ids ]]; then actual_ids+=','; fi
    actual_ids+=$(basename -- "$entry")
    cb_validate_object_contract "$tx" "$entry"
  done < <(find -P "$dir/objects" -mindepth 1 -maxdepth 1 -print0 | LC_ALL=C sort -z)
  if [[ $operation == install || $operation == update ]]; then
    [[ $actual_ids == '00,10,11,12,13,20,30,31' ]] || cb_die "transaction has an incomplete object inventory: $tx"
  fi
  if [[ $state == committed ]]; then
    while IFS= read -r -d '' obj; do
      object_status=$(cb_read_field "$obj/status")
      case $object_status in committed|unchanged) ;; *) cb_die "committed transaction contains incomplete object state: $obj" ;; esac
      if [[ $(cb_read_field "$obj/change") == 1 ]]; then
        [[ $object_status == committed ]] || cb_die "committed transaction change/status mismatch: $obj"
      else
        [[ $object_status == unchanged ]] || cb_die "committed transaction change/status mismatch: $obj"
      fi
    done < <(find -P "$dir/objects" -mindepth 1 -maxdepth 1 -type d -print0 | LC_ALL=C sort -z)
  fi
  for entry in rollback_target result_current; do
    if [[ -e $dir/$entry || -L $dir/$entry ]]; then
      cb_require_scalar_file "$dir/$entry" "$tx/$entry"
      value=$(cb_read_field "$dir/$entry")
      if [[ -n $value ]]; then cb_require_tx_id "$value"; fi
    fi
  done
  rollback_target=$(cb_read_field "$dir/rollback_target")
  result_current=$(cb_read_field "$dir/result_current")
  if [[ $operation == rollback || $operation == uninstall ]]; then
    [[ -n $rollback_target && $parent == "$rollback_target" ]] || cb_die "rollback transaction target/parent mismatch: $tx"
    cb_require_tx_id "$rollback_target"
    [[ -d $CB_STATE_ROOT/transactions/$rollback_target && ! -L $CB_STATE_ROOT/transactions/$rollback_target ]] || cb_die "rollback source transaction is missing: $rollback_target"
    source_operation=$(cb_read_field "$CB_STATE_ROOT/transactions/$rollback_target/operation")
    [[ $source_operation == install || $source_operation == update ]] || cb_die "rollback source transaction has an invalid operation: $rollback_target"
    cb_validate_tx "$rollback_target" committed "$CB_STATE_ROOT"
    rollback_parent=$(cb_read_field "$CB_STATE_ROOT/transactions/$rollback_target/parent")
    [[ $result_current == "$rollback_parent" ]] || cb_die "rollback result-current mismatch: $tx"
    if [[ $operation == uninstall ]]; then
      expected_ids='00,10,11,12,13,20,30,31'
    else
      expected_ids=''
      while IFS= read -r -d '' obj; do
        [[ $(cb_read_field "$obj/status") == committed ]] || continue
        if [[ -n $expected_ids ]]; then expected_ids+=','; fi
        expected_ids+=$(basename -- "$obj")
      done < <(find -P "$CB_STATE_ROOT/transactions/$rollback_target/objects" -mindepth 1 -maxdepth 1 -type d -print0 | LC_ALL=C sort -z)
    fi
    [[ -n $expected_ids && $actual_ids == "$expected_ids" ]] || cb_die "rollback transaction has an incomplete object inventory: $tx"
    while IFS= read -r -d '' obj; do
      id=$(basename -- "$obj")
      cb_require_scalar_file "$obj/restore_mode" "$id/restore_mode"
      cb_require_scalar_file "$obj/restore_source" "$id/restore_source"
      restore_mode=$(cb_read_field "$obj/restore_mode")
      restore_source=$(cb_read_field "$obj/restore_source")
      case $restore_mode in
        delete) expected_source=:delete ;;
        remove-block) expected_source=:remove-block ;;
        full-file) expected_source="$CB_STATE_ROOT/transactions/$rollback_target/objects/$id/backup_file" ;;
        restore) expected_source="$CB_STATE_ROOT/transactions/$rollback_target/objects/$id/backup" ;;
        *) cb_die "invalid restore mode in transaction: $obj" ;;
      esac
      [[ $restore_source == "$expected_source" ]] || cb_die "invalid restore source in transaction: $obj"
    done < <(find -P "$dir/objects" -mindepth 1 -maxdepth 1 -type d -print0 | LC_ALL=C sort -z)
  else
    [[ -z $rollback_target && -z $result_current ]] || cb_die "unexpected rollback metadata: $tx"
  fi
}

cb_read_tx_pointer() {
  local path=$1 value
  value=$(cb_read_field "$path")
  [[ -z $value ]] || cb_require_tx_id "$value"
  printf '%s' "$value"
}

cb_tx_dir() {
  cb_require_tx_id "$1"
  printf '%s/transactions/%s' "$CB_TX_ROOT" "$1"
}

cb_live_tx_dir() {
  cb_require_tx_id "$1"
  printf '%s/transactions/%s' "$CB_STATE_ROOT" "$1"
}

cb_set_tx_state() {
  case $2 in planned|prepared|committing|recovering|committed|rolled-back|no-op|dry-run) ;; *) cb_die "invalid transaction state transition target: $2" ;; esac
  cb_write_field "$(cb_tx_dir "$1")/state" "$2"
}

cb_new_tx() {
  local operation=$1 id dir parent
  id=$(date -u '+%Y%m%dT%H%M%SZ')-$$-$RANDOM
  dir=$(cb_tx_dir "$id")
  cb_safe_mkdir_path "$dir/objects"
  cb_write_field "$dir/schema" "$CB_SCHEMA"
  cb_write_field "$dir/operation" "$operation"
  cb_write_field "$dir/version" "$CB_VERSION"
  cb_write_field "$dir/created_utc" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  parent=$(cb_current_tx)
  cb_write_field "$dir/parent" "$parent"
  cb_set_tx_state "$id" planned
  CB_ACTIVE_TX=$id
  CB_NEW_TX=$id
}

cb_discard_tx() {
  local tx=$1 dir parent
  [[ $tx =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+$ ]] || cb_die "invalid transaction id: $tx"
  dir=$(cb_tx_dir "$tx")
  parent=$(dirname -- "$dir")
  [[ $parent == "$CB_TX_ROOT/transactions" ]] || cb_die "transaction path escaped state root: $dir"
  rm -rf -- "$dir"
  cb_sync_file "$parent"
}

cb_current_tx() {
  cb_read_tx_pointer "$CB_CURRENT"
}

cb_find_current_object() {
  local target=$1 current obj object_target
  current=$(cb_current_tx)
  [[ -n $current && -d $(cb_live_tx_dir "$current")/objects ]] || return 1
  for obj in "$(cb_live_tx_dir "$current")"/objects/*; do
    [[ -d $obj ]] || continue
    object_target=$(cb_read_field "$obj/target")
    if [[ $object_target == "$target" ]]; then
      printf '%s' "$obj"
      return 0
    fi
  done
  return 1
}

cb_live_hash() {
  local kind=$1 target=$2
  if [[ $kind == block ]]; then
    cb_block_hash "$target"
    return
  fi
  case $(cb_kind "$target") in
    absent) printf 'absent' ;;
    file) [[ $kind == file ]] || cb_die "object kind conflict at $target"; cb_sha256_file "$target" ;;
    tree) [[ $kind == tree ]] || cb_die "object kind conflict at $target"; cb_tree_hash "$target" ;;
    *) cb_die "unsafe object at managed target: $target" ;;
  esac
}

cb_fault_after_mutation() {
  local label=$1 requested=${CODEX_BASELINE_TEST_CRASH_AFTER:-}
  CB_MUTATION_COUNT=$((CB_MUTATION_COUNT + 1))
  if [[ ${CODEX_BASELINE_TESTING:-0} == 1 && $requested =~ ^[0-9]+$ && $CB_MUTATION_COUNT -eq $requested ]]; then
    cb_err "test fault injection after mutation $CB_MUTATION_COUNT ($label)"
    kill -KILL "$$"
  fi
}

cb_create_object() {
  local tx=$1 id=$2 kind=$3 target=$4 desired=$5 source_label=$6 root=$7 desired_present=${8:-1}
  local obj current_obj installed live existed previous_hash previous_kind
  obj="$(cb_tx_dir "$tx")/objects/$id"
  cb_safe_mkdir_path "$obj"
  cb_write_field "$obj/kind" "$kind"
  cb_write_field "$obj/target" "$target"
  cb_write_field "$obj/root" "$root"
  cb_write_field "$obj/desired_hash" "$desired"
  cb_write_field "$obj/desired_present" "$desired_present"
  cb_write_field "$obj/source" "$source_label"
  cb_write_field "$obj/status" planned
  live=$(cb_live_hash "$kind" "$target")
  previous_hash=$live
  previous_kind=$(cb_kind "$target")
  [[ $kind == block ]] && previous_kind=block
  existed=1
  [[ -e $target || -L $target ]] || existed=0
  if [[ $kind == block ]]; then
    if [[ $live == absent ]]; then
      cb_write_field "$obj/previous_managed_existed" 0
    else
      cb_write_field "$obj/previous_managed_existed" 1
    fi
    if [[ $existed == 1 ]]; then
      [[ -f $target && ! -L $target ]] || cb_die "guidance target is not a regular file: $target"
      cb_write_field "$obj/previous_file_hash" "$(cb_sha256_file "$target")"
    else
      cb_write_field "$obj/previous_file_hash" absent
    fi
  fi
  cb_write_field "$obj/previous_hash" "$previous_hash"
  cb_write_field "$obj/previous_kind" "$previous_kind"
  cb_write_field "$obj/previous_existed" "$existed"
  if current_obj=$(cb_find_current_object "$target"); then
    installed=$(cb_read_field "$current_obj/installed_hash")
    [[ $live == "$installed" ]] || cb_die "managed content drifted; refusing to overwrite: $target"
  elif [[ $kind == block ]]; then
    [[ $live == absent ]] || cb_die "unowned baseline marker exists: $target"
  elif [[ $live != absent ]]; then
    cb_die "unowned target exists: $target"
  fi
  if [[ $live == "$desired" ]]; then
    cb_write_field "$obj/change" 0
  else
    cb_write_field "$obj/change" 1
  fi
}

cb_select_agents_file() {
  local override="$CB_CODEX_HOME/AGENTS.override.md" normal="$CB_CODEX_HOME/AGENTS.md"
  if [[ -s $override && -s $normal ]]; then
    cb_die "both non-empty global AGENTS.override.md and AGENTS.md exist; choose the intended active file before install"
  fi
  if [[ -s $override ]]; then
    printf '%s' "$override"
  else
    printf '%s' "$normal"
  fi
}

cb_build_runtime() {
  local output=$1 source_root=$2
  mkdir -p -- "$output/scripts/lib"
  cp -- "$source_root/VERSION" "$output/VERSION"
  cp -a -- "$source_root/baseline" "$output/baseline"
  cp -p -- \
    "$source_root/scripts/codex-baseline.sh" "$source_root/scripts/codex-baseline.ps1" \
    "$source_root/scripts/onboard.sh" "$source_root/scripts/onboard.ps1" \
    "$source_root/scripts/benchmark.sh" "$source_root/scripts/benchmark.ps1" \
    "$output/scripts/"
  cp -p -- "$source_root/scripts/lib/common.sh" "$source_root/scripts/lib/evaluation.sh" "$output/scripts/lib/"
  if [[ -d $source_root/benchmarks ]]; then
    cp -a -- "$source_root/benchmarks" "$output/benchmarks"
  fi
}

cb_installed_tree_hash() {
  local source=$1 tmp digest
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/codex-baseline-hash.XXXXXX")
  mkdir -- "$tmp/tree"
  chmod --reference="$source" "$tmp/tree"
  cp -a -- "$source/." "$tmp/tree/"
  digest=$(cb_tree_hash "$tmp/tree")
  rm -rf -- "$tmp"
  printf '%s' "$digest"
}

cb_render_wrapper() {
  local output=$1
  cat >"$output" <<'EOF'
#!/bin/sh
set -eu
codex_home=${CODEX_HOME:-"${HOME:?HOME must be set}/.codex"}
exec "$codex_home/codex-baseline/runtime/scripts/codex-baseline.sh" "$@"
EOF
  chmod 0755 "$output"
}

cb_stage_source_object() {
  local obj=$1 source=$2 kind=$3 stage
  stage=$(cb_read_field "$obj/stage")
  case $kind in
    file) [[ -f $stage && ! -L $stage ]] || cb_die "unsafe reserved stage: $stage"; cp -p -- "$source" "$stage" ;;
    tree) [[ -d $stage && ! -L $stage ]] || cb_die "unsafe reserved stage: $stage"; chmod --reference="$source" "$stage"; cp -a -- "$source/." "$stage/" ;;
    *) cb_die "cannot stage source kind: $kind" ;;
  esac
}

cb_prepare_backup() {
  local obj=$1 kind target existed backup previous_file_hash
  kind=$(cb_read_field "$obj/kind")
  target=$(cb_read_field "$obj/target")
  existed=$(cb_read_field "$obj/previous_existed")
  backup="$obj/backup"
  [[ $existed == 1 ]] || return 0
  if [[ $kind == block ]]; then
    previous_file_hash=$(cb_read_field "$obj/previous_file_hash")
    [[ $(cb_sha256_file "$target") == "$previous_file_hash" ]] || cb_die "guidance file changed before backup: $target"
    cp -p -- "$target" "$obj/backup_file"
    [[ $(cb_sha256_file "$obj/backup_file") == "$previous_file_hash" ]] || cb_die "guidance backup verification failed: $target"
    if [[ $(cb_read_field "$obj/previous_managed_existed") == 1 ]]; then
      cb_extract_block "$target" "$backup" || cb_die "expected previous managed block in $target"
    else
      cb_write_field "$obj/backup_hash" absent
      return
    fi
  elif [[ $kind == file ]]; then
    cp -p -- "$target" "$backup"
  elif [[ $kind == tree ]]; then
    mkdir -- "$backup"
    chmod --reference="$target" "$backup"
    cp -a -- "$target/." "$backup/"
  fi
  cb_write_field "$obj/backup_hash" "$(cb_object_hash "$kind" "$backup")"
}

cb_prepare_object() {
  local obj=$1 source=$2 kind target root parent stage old desired_block desired_present stage_mode=${4:-managed}
  local tx id stage_template old_template
  kind=$(cb_read_field "$obj/kind")
  target=$(cb_read_field "$obj/target")
  root=$(cb_read_field "$obj/root")
  desired_present=$(cb_read_field "$obj/desired_present")
  parent=$(dirname -- "$target")
  id=$(basename -- "$obj")
  tx=$(basename -- "$(dirname -- "$(dirname -- "$obj")")")
  cb_safe_mkdir_parent "$target" "$root"
  stage_template="$parent/.codex-baseline-stage-$tx-$id.XXXXXX"
  old_template="$parent/.codex-baseline-old-$tx-$id.XXXXXX"
  if [[ $desired_present == 0 ]]; then
    stage="$parent/.codex-baseline-stage-$tx-$id.delete"
    [[ ! -e $stage && ! -L $stage ]] || cb_die "staging collision near $target"
  elif [[ $kind == tree ]]; then
    stage=$(mktemp -d "$stage_template")
  else
    stage=$(mktemp "$stage_template")
  fi
  old=$(mktemp "$old_template")
  rm -f -- "$old"
  [[ ! -e $old && ! -L $old ]] || cb_die "old-path reservation failed near $target"
  cb_write_field "$obj/stage" "$stage"
  cb_write_field "$obj/old" "$old"
  cb_prepare_backup "$obj"
  if [[ $desired_present == 0 ]]; then
    [[ $kind != block || $(cb_read_field "$obj/desired_hash") == absent ]] || cb_die "invalid block deletion plan: $target"
    cb_write_field "$obj/status" prepared
    return 0
  fi
  case $kind in
    block)
      if [[ $stage_mode == full-file ]]; then
        [[ -f $stage && ! -L $stage ]] || cb_die "unsafe reserved stage: $stage"
        cp -p -- "$source" "$stage"
      elif [[ $source == :remove-block ]]; then
        cb_remove_block "$target" "$stage"
      else
        desired_block=$source
        cb_replace_block "$target" "$desired_block" "$stage"
      fi
      [[ ! -f $target || -L $target ]] || chmod --reference="$target" "$stage"
      ;;
    file|tree) cb_stage_source_object "$obj" "$source" "$kind" ;;
    *) cb_die "unsupported prepare kind: $kind" ;;
  esac
  [[ $(cb_live_hash "$kind" "$stage") == "$(cb_read_field "$obj/desired_hash")" ]] || cb_die "staged hash mismatch for $target"
  if [[ $kind == block ]]; then cb_write_field "$obj/desired_file_hash" "$(cb_sha256_file "$stage")"; fi
  cb_write_field "$obj/status" prepared
}

cb_path_absent() {
  [[ ! -e $1 && ! -L $1 ]]
}

cb_path_matches_previous() {
  local obj=$1 path=$2 kind existed previous previous_file
  kind=$(cb_read_field "$obj/kind")
  existed=$(cb_read_field "$obj/previous_existed")
  if [[ $existed == 0 ]]; then cb_path_absent "$path"; return; fi
  if [[ $kind == block ]]; then
    [[ -f $path && ! -L $path ]] || return 1
    previous=$(cb_read_field "$obj/previous_hash")
    previous_file=$(cb_read_field "$obj/previous_file_hash")
    [[ $(cb_sha256_file "$path") == "$previous_file" && $(cb_block_hash "$path") == "$previous" ]]
  else
    [[ $(cb_live_hash "$kind" "$path") == "$(cb_read_field "$obj/previous_hash")" ]]
  fi
}

cb_path_matches_desired() {
  local obj=$1 path=$2 kind desired_present desired desired_file
  kind=$(cb_read_field "$obj/kind")
  desired_present=$(cb_read_field "$obj/desired_present")
  if [[ $desired_present == 0 ]]; then cb_path_absent "$path"; return; fi
  desired=$(cb_read_field "$obj/desired_hash")
  if [[ $kind == block ]]; then
    [[ -f $path && ! -L $path ]] || return 1
    desired_file=$(cb_read_field "$obj/desired_file_hash")
    [[ -n $desired_file && $(cb_sha256_file "$path") == "$desired_file" && $(cb_block_hash "$path") == "$desired" ]]
  else
    [[ $(cb_live_hash "$kind" "$path") == "$desired" ]]
  fi
}

cb_recovery_preflight_object() {
  local obj=$1 status target root old stage recovery_new existed target_state old_state recovery_state
  status=$(cb_read_field "$obj/status")
  target=$(cb_read_field "$obj/target")
  root=$(cb_read_field "$obj/root")
  existed=$(cb_read_field "$obj/previous_existed")
  case $status in
    planned|unchanged)
      return
      ;;
    rolled-back)
      if [[ -e $obj/stage || -L $obj/stage ]]; then
        stage=$(cb_read_field "$obj/stage")
        old=$(cb_read_field "$obj/old")
        recovery_new="$stage.recovery-new"
        if ! cb_path_absent "$stage" || ! cb_path_absent "$old" || ! cb_path_absent "$recovery_new"; then
          cb_die "rolled-back object retains transaction paths: $obj"
        fi
      fi
      return
      ;;
  esac
  stage=$(cb_read_field "$obj/stage")
  old=$(cb_read_field "$obj/old")
  recovery_new="$stage.recovery-new"
  cb_assert_target_under "$target" "$root"
  cb_assert_target_under "$stage" "$root"
  cb_assert_target_under "$old" "$root"
  cb_assert_target_under "$recovery_new" "$root"
  case $status in
    prepared|ready)
      cb_path_absent "$old" || cb_die "unexpected recovery preimage before commit: $old"
      cb_path_absent "$recovery_new" || cb_die "unexpected recovery scratch before commit: $recovery_new"
      cb_path_matches_previous "$obj" "$target" || cb_die "live preimage changed before recovery: $target"
      if [[ $(cb_read_field "$obj/desired_present") == 1 ]]; then
        cb_path_matches_desired "$obj" "$stage" || cb_die "staged desired object is corrupt: $stage"
      else
        cb_path_absent "$stage" || cb_die "deletion plan has unexpected stage: $stage"
      fi
      return
      ;;
    moving-old)
      cb_path_absent "$recovery_new" || cb_die "unexpected recovery scratch while moving old target: $target"
      if cb_path_absent "$old"; then
        cb_path_matches_previous "$obj" "$target" || cb_die "missing or corrupt live preimage: $target"
      else
        [[ $existed == 1 ]] || cb_die "unexpected old object for previously absent target: $target"
        cb_path_matches_previous "$obj" "$old" || cb_die "corrupt recovery preimage: $old"
        cb_path_absent "$target" || cb_die "ambiguous target while moving old object: $target"
      fi
      return
      ;;
  esac

  target_state=other
  if cb_path_absent "$target"; then target_state=absent
  elif cb_path_matches_desired "$obj" "$target"; then target_state=desired
  elif [[ $existed == 1 ]] && cb_path_matches_previous "$obj" "$target"; then target_state=previous
  fi
  old_state=other
  if cb_path_absent "$old"; then old_state=absent
  elif [[ $existed == 1 ]] && cb_path_matches_previous "$obj" "$old"; then old_state=previous
  fi
  recovery_state=other
  if cb_path_absent "$recovery_new"; then recovery_state=absent
  elif cb_path_matches_desired "$obj" "$recovery_new"; then recovery_state=desired
  fi
  [[ $old_state != other ]] || cb_die "corrupt recovery preimage: $old"
  [[ $target_state != other ]] || cb_die "unverifiable live object during recovery: $target"
  [[ $recovery_state != other ]] || cb_die "corrupt recovery scratch: $recovery_new"
  [[ $target_state != desired || $recovery_state == absent ]] || cb_die "duplicate desired state during recovery: $target"
  [[ $target_state != previous || $old_state == absent ]] || cb_die "duplicate preimage during recovery: $target"
  if [[ $existed == 1 ]]; then
    [[ $target_state == previous || $old_state == previous ]] || cb_die "recovery preimage is missing: $target"
  else
    [[ $old_state == absent && $target_state != previous ]] || cb_die "unexpected recovery preimage: $target"
  fi
}

cb_restore_object_now() {
  local obj=$1 status target root old stage existed recovery_new
  status=$(cb_read_field "$obj/status")
  target=$(cb_read_field "$obj/target")
  root=$(cb_read_field "$obj/root")
  old=$(cb_read_field "$obj/old")
  stage=$(cb_read_field "$obj/stage")
  existed=$(cb_read_field "$obj/previous_existed")
  case $status in
    planned|unchanged|rolled-back)
      cb_write_field "$obj/status" rolled-back
      return
      ;;
  esac
  recovery_new="$stage.recovery-new"
  case $status in
    moving-old)
      if ! cb_path_absent "$old"; then mv -T -- "$old" "$target"; fi
      ;;
    old-moved|new-moved|committed)
      if cb_path_matches_desired "$obj" "$target"; then
        cb_path_absent "$recovery_new" || cb_die "recovery scratch collision: $recovery_new"
        mv -T -- "$target" "$recovery_new"
      fi
      if [[ $existed == 1 ]] && ! cb_path_matches_previous "$obj" "$target"; then
        cb_path_absent "$target" || cb_die "target is not empty before preimage restore: $target"
        mv -T -- "$old" "$target"
      fi
      ;;
  esac
  cb_path_absent "$recovery_new" || cb_remove_internal "$recovery_new" "$root"
  cb_path_absent "$stage" || cb_remove_internal "$stage" "$root"
  cb_path_absent "$old" || cb_remove_internal "$old" "$root"
  cb_sync_parent "$target"
  cb_write_field "$obj/status" rolled-back
}

cb_recover_tx() {
  local tx=$1 dir obj prior_current
  cb_validate_tx "$tx"
  dir=$(cb_tx_dir "$tx")
  while IFS= read -r -d '' obj; do cb_recovery_preflight_object "$obj"; done \
    < <(find -P "$dir/objects" -mindepth 1 -maxdepth 1 -type d -print0 | LC_ALL=C sort -zr)
  cb_set_tx_state "$tx" recovering
  while IFS= read -r -d '' obj; do cb_restore_object_now "$obj"; done \
    < <(find -P "$dir/objects" -mindepth 1 -maxdepth 1 -type d -print0 | LC_ALL=C sort -zr)
  prior_current=$(cb_read_field "$dir/parent")
  if [[ -n $prior_current ]]; then
    cb_write_field "$CB_CURRENT" "$prior_current"
  else
    rm -f -- "$CB_CURRENT"
    cb_sync_parent "$CB_CURRENT"
  fi
  cb_set_tx_state "$tx" rolled-back
  rm -f -- "$CB_PENDING"
  cb_sync_parent "$CB_PENDING"
}

cb_recover_pending() {
  local pending
  pending=$(cb_read_tx_pointer "$CB_PENDING")
  [[ -n $pending ]] || return 0
  cb_err "recovering incomplete transaction $pending"
  cb_recover_tx "$pending"
}

cb_on_exit() {
  local code=$?
  trap - EXIT
  if [[ $code -ne 0 && -n $CB_ACTIVE_TX && -f $CB_PENDING ]]; then
    cb_err "operation failed; recovering transaction $CB_ACTIVE_TX"
    cb_recover_tx "$CB_ACTIVE_TX" || cb_err "automatic recovery failed; run doctor before another mutation"
  fi
  cb_release_lock
  cb_cleanup_temps
  exit "$code"
}

cb_commit_object() {
  local obj=$1 kind target root stage old existed live desired desired_present tx previous_file desired_file
  kind=$(cb_read_field "$obj/kind")
  target=$(cb_read_field "$obj/target")
  root=$(cb_read_field "$obj/root")
  stage=$(cb_read_field "$obj/stage")
  old=$(cb_read_field "$obj/old")
  existed=$(cb_read_field "$obj/previous_existed")
  desired=$(cb_read_field "$obj/desired_hash")
  desired_present=$(cb_read_field "$obj/desired_present")
  tx=$(basename -- "$(dirname -- "$(dirname -- "$obj")")")
  cb_validate_object_contract "$tx" "$obj"
  cb_assert_target_under "$target" "$root"
  cb_path_absent "$old" || cb_die "old path appeared before commit: $old"
  if [[ $desired_present == 1 ]]; then
    cb_path_matches_desired "$obj" "$stage" || cb_die "stage changed before commit: $stage"
  else
    cb_path_absent "$stage" || cb_die "unexpected deletion stage before commit: $stage"
  fi
  if [[ ${CODEX_BASELINE_TESTING:-0} == 1 && ${CODEX_BASELINE_TEST_EDIT_AGENTS_BEFORE_COMMIT:-0} == 1 && $kind == block ]]; then
    printf '%s\n' 'concurrent-test-edit' >>"$target"
    unset CODEX_BASELINE_TEST_EDIT_AGENTS_BEFORE_COMMIT
  fi
  live=$(cb_live_hash "$kind" "$target")
  [[ $live == "$(cb_read_field "$obj/previous_hash")" ]] || cb_die "target changed during transaction: $target"
  if [[ $kind == block ]]; then
    previous_file=$(cb_read_field "$obj/previous_file_hash")
    [[ $existed == 0 && $previous_file == absent ]] || \
      [[ -f $target && ! -L $target && $(cb_sha256_file "$target") == "$previous_file" ]] || \
      cb_die "guidance file changed during transaction: $target"
  fi
  cb_write_field "$obj/status" moving-old
  if [[ $existed == 1 ]]; then
    cb_path_absent "$old" || cb_die "old path appeared during commit: $old"
    mv -T -- "$target" "$old"
    cb_sync_parent "$target"
    cb_fault_after_mutation "moved-old:$target"
  fi
  cb_write_field "$obj/status" old-moved
  if [[ $desired_present == 1 ]]; then
    cb_assert_target_under "$target" "$root"
    cb_path_absent "$target" || cb_die "target appeared before desired move: $target"
    cb_path_matches_desired "$obj" "$stage" || cb_die "stage changed before desired move: $stage"
    mv -T -- "$stage" "$target"
    cb_sync_file "$target"
    cb_sync_parent "$target"
    cb_fault_after_mutation "moved-new:$target"
  fi
  cb_write_field "$obj/status" new-moved
  [[ $(cb_live_hash "$kind" "$target") == "$desired" ]] || cb_die "committed hash mismatch: $target"
  if [[ $kind == block && $desired_present == 1 ]]; then
    desired_file=$(cb_read_field "$obj/desired_file_hash")
    [[ $(cb_sha256_file "$target") == "$desired_file" ]] || cb_die "committed guidance file hash mismatch: $target"
  fi
  cb_write_field "$obj/installed_hash" "$desired"
  if [[ $kind == block && -f $target && ! -L $target ]]; then
    cb_write_field "$obj/installed_file_hash" "$(cb_sha256_file "$target")"
  fi
  cb_write_field "$obj/status" committed
}

cb_cleanup_old_paths() {
  local dir=$1 obj old_path root
  for obj in "$dir"/objects/*; do
    [[ -d $obj && -f $obj/old ]] || continue
    old_path=$(cb_read_field "$obj/old")
    root=$(cb_read_field "$obj/root")
    [[ ! -e $old_path && ! -L $old_path ]] || cb_remove_internal "$old_path" "$root"
  done
}

cb_begin_operation() {
  if [[ $CB_DRY_RUN -eq 1 ]]; then
    [[ ! -f $CB_PENDING ]] || cb_die 'an incomplete transaction requires recovery before dry-run'
    CB_DRY_TX_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/codex-baseline-dry.XXXXXX")
    cb_register_temp "$CB_DRY_TX_ROOT"
    CB_TX_ROOT="$CB_DRY_TX_ROOT/state"
    cb_safe_mkdir_path "$CB_TX_ROOT/transactions"
  else
    cb_init_mutation_roots
    cb_acquire_lock
    cb_recover_pending
    if [[ -n $(cb_current_tx) ]]; then cb_validate_tx "$(cb_current_tx)" committed "$CB_STATE_ROOT"; fi
  fi
}

cb_install_like() {
  local operation=$1 version payload_hash manifest_hash verified_root tx dir agents_file block_tmp runtime_tmp wrapper_tmp obj changed=0
  version=$(cb_verify_source_manifest "$CB_SOURCE_ROOT")
  payload_hash=$(sed -n 's/^  "payload_hash": "\([0-9a-f]\{64\}\)",$/\1/p' "$CB_SOURCE_ROOT/baseline/manifest.json")
  manifest_hash=$(cb_sha256_file "$CB_SOURCE_ROOT/baseline/manifest.json")
  cb_print_source_provenance "$CB_SOURCE_ROOT" "$payload_hash"
  if [[ $CB_DRY_RUN -eq 0 && $CB_ACKNOWLEDGE_UNVERIFIED_SOURCE -ne 1 ]]; then
    cb_die 'unsigned local source requires --acknowledge-unverified-source before mutation'
  fi
  CB_VERSION=$version
  cb_freeze_verified_source "$CB_SOURCE_ROOT" "$manifest_hash" "$payload_hash"
  verified_root=$CB_VERIFIED_SOURCE_ROOT
  cb_init_paths
  cb_begin_operation
  cb_new_tx "$operation"
  tx=$CB_NEW_TX
  dir=$(cb_tx_dir "$tx")
  agents_file=$(cb_select_agents_file)
  block_tmp=$(mktemp "${TMPDIR:-/tmp}/codex-baseline-rendered.XXXXXX")
  runtime_tmp=$(mktemp -d "${TMPDIR:-/tmp}/codex-baseline-runtime.XXXXXX")
  wrapper_tmp=$(mktemp "${TMPDIR:-/tmp}/codex-baseline-wrapper.XXXXXX")
  cb_register_temp "$block_tmp"
  cb_register_temp "$runtime_tmp"
  cb_register_temp "$wrapper_tmp"
  cb_render_managed_block "$verified_root/baseline/global/AGENTS.block.md" "$version" "$block_tmp"
  cb_build_runtime "$runtime_tmp" "$verified_root"
  cb_render_wrapper "$wrapper_tmp"

  cb_create_object "$tx" 00 block "$agents_file" "$(cb_sha256_file "$block_tmp")" 'baseline/global/AGENTS.block.md' "$CB_CODEX_HOME"
  cb_create_object "$tx" 10 tree "$CB_AGENTS_HOME/skills/codex-baseline-repo-onboarding" "$(cb_installed_tree_hash "$verified_root/baseline/skills/codex-baseline-repo-onboarding")" 'baseline/skills/codex-baseline-repo-onboarding' "$CB_AGENTS_HOME"
  cb_create_object "$tx" 11 tree "$CB_AGENTS_HOME/skills/codex-baseline-deep-work" "$(cb_installed_tree_hash "$verified_root/baseline/skills/codex-baseline-deep-work")" 'baseline/skills/codex-baseline-deep-work' "$CB_AGENTS_HOME"
  cb_create_object "$tx" 12 tree "$CB_AGENTS_HOME/skills/codex-baseline-conformance-review" "$(cb_installed_tree_hash "$verified_root/baseline/skills/codex-baseline-conformance-review")" 'baseline/skills/codex-baseline-conformance-review' "$CB_AGENTS_HOME"
  cb_create_object "$tx" 13 tree "$CB_AGENTS_HOME/skills/codex-baseline-retrospective" "$(cb_installed_tree_hash "$verified_root/baseline/skills/codex-baseline-retrospective")" 'baseline/skills/codex-baseline-retrospective' "$CB_AGENTS_HOME"
  cb_create_object "$tx" 20 file "$CB_CODEX_HOME/agents/codex-baseline-reviewer.toml" "$(cb_sha256_file "$verified_root/baseline/agents/codex-baseline-reviewer.toml")" 'baseline/agents/codex-baseline-reviewer.toml' "$CB_CODEX_HOME"
  cb_create_object "$tx" 30 tree "$CB_RUNTIME" "$(cb_tree_hash "$runtime_tmp")" runtime "$CB_CODEX_HOME"
  cb_create_object "$tx" 31 file "$CB_HOME/.local/bin/codex-baseline" "$(cb_sha256_file "$wrapper_tmp")" generated-wrapper "$CB_HOME"

  for obj in "$dir"/objects/*; do
    if [[ $(cb_read_field "$obj/change") == 1 ]]; then
      changed=1
      printf '%s: %s\n' "$operation" "$(cb_read_field "$obj/target")"
    fi
  done
  if [[ $changed -eq 0 ]]; then
    printf 'codex-baseline %s is already installed; no changes\n' "$version"
    cb_set_tx_state "$tx" no-op
    cb_discard_tx "$tx"
    cb_cleanup_temps
    CB_ACTIVE_TX=''
    return
  fi
  if [[ $CB_DRY_RUN -eq 1 ]]; then
    printf 'dry-run: no files changed\n'
    cb_set_tx_state "$tx" dry-run
    cb_cleanup_temps
    CB_ACTIVE_TX=''
    return
  fi

  cb_write_field "$CB_PENDING" "$tx"
  for obj in "$dir"/objects/*; do
    [[ $(cb_read_field "$obj/change") == 1 ]] || {
      cb_write_field "$obj/installed_hash" "$(cb_read_field "$obj/desired_hash")"
      cb_write_field "$obj/status" unchanged
      continue
    }
    case $(basename "$obj") in
      00) cb_prepare_object "$obj" "$block_tmp" block ;;
      10) cb_prepare_object "$obj" "$verified_root/baseline/skills/codex-baseline-repo-onboarding" tree ;;
      11) cb_prepare_object "$obj" "$verified_root/baseline/skills/codex-baseline-deep-work" tree ;;
      12) cb_prepare_object "$obj" "$verified_root/baseline/skills/codex-baseline-conformance-review" tree ;;
      13) cb_prepare_object "$obj" "$verified_root/baseline/skills/codex-baseline-retrospective" tree ;;
      20) cb_prepare_object "$obj" "$verified_root/baseline/agents/codex-baseline-reviewer.toml" file ;;
      30) cb_prepare_object "$obj" "$runtime_tmp" tree ;;
      31) cb_prepare_object "$obj" "$wrapper_tmp" file ;;
    esac
  done
  cb_set_tx_state "$tx" prepared
  cb_set_tx_state "$tx" committing
  for obj in "$dir"/objects/*; do
    [[ $(cb_read_field "$obj/change") == 1 ]] || continue
    cb_commit_object "$obj"
  done
  cb_write_field "$CB_CURRENT" "$tx"
  cb_set_tx_state "$tx" committed
  rm -f -- "$CB_PENDING"
  cb_sync_parent "$CB_PENDING"
  cb_cleanup_old_paths "$dir"
  cb_cleanup_temps
  CB_ACTIVE_TX=''
  printf 'installed codex-baseline %s (transaction %s)\n' "$version" "$tx"
}

cb_plan_rollback_object() {
  local tx=$1 current_obj=$2 id kind target root desired previous_existed previous_managed
  local desired_present=1 source mode installed_file_hash live_file_hash exact_file=0
  id=$(basename -- "$current_obj")
  kind=$(cb_read_field "$current_obj/kind")
  target=$(cb_read_field "$current_obj/target")
  root=$(cb_read_field "$current_obj/root")
  desired=$(cb_read_field "$current_obj/previous_hash")
  previous_existed=$(cb_read_field "$current_obj/previous_existed")
  source="$current_obj/backup"
  mode=restore
  if [[ $kind == block && -f $target && ! -L $target ]]; then
    installed_file_hash=$(cb_read_field "$current_obj/installed_file_hash")
    live_file_hash=$(cb_sha256_file "$target")
    [[ -n $installed_file_hash && $live_file_hash == "$installed_file_hash" ]] && exact_file=1
  fi
  if [[ $previous_existed == 0 && ( $kind != block || $exact_file -eq 1 ) ]]; then
    desired_present=0
    desired=absent
    source=:delete
    mode=delete
  elif [[ $kind == block ]]; then
    if [[ $exact_file -eq 1 && -f $current_obj/backup_file && ! -L $current_obj/backup_file ]]; then
      [[ $(cb_sha256_file "$current_obj/backup_file") == "$(cb_read_field "$current_obj/previous_file_hash")" ]] || \
        cb_die "rollback whole-file backup is corrupt: $current_obj/backup_file"
      source="$current_obj/backup_file"
      mode=full-file
    else
      previous_managed=$(cb_read_field "$current_obj/previous_managed_existed")
    fi
    if [[ ${previous_managed:-1} == 0 ]]; then
      desired=absent
      source=:remove-block
      mode=remove-block
    elif [[ $exact_file -eq 0 ]]; then
      [[ -f $source && ! -L $source && $(cb_block_hash "$source") == "$(cb_read_field "$current_obj/backup_hash")" ]] || \
        cb_die "rollback block backup is corrupt: $source"
    fi
  fi
  if [[ $desired_present == 1 && $source != :remove-block ]]; then
    case $kind in
      file) [[ -f $source && ! -L $source ]] || cb_die "rollback backup is missing: $source" ;;
      tree) [[ -d $source && ! -L $source ]] || cb_die "rollback backup is missing: $source" ;;
      block) [[ -f $source && ! -L $source ]] || cb_die "rollback block backup is missing: $source" ;;
    esac
    if [[ $kind == file || $kind == tree ]]; then
      [[ $(cb_object_hash "$kind" "$source") == "$(cb_read_field "$current_obj/backup_hash")" && \
         $(cb_read_field "$current_obj/backup_hash") == "$(cb_read_field "$current_obj/previous_hash")" ]] || \
        cb_die "rollback backup is corrupt: $source"
    fi
  fi
  cb_create_object "$tx" "$id" "$kind" "$target" "$desired" "rollback:$(basename "$(dirname "$(dirname "$current_obj")")")/$id" "$root" "$desired_present"
  cb_write_field "$(cb_tx_dir "$tx")/objects/$id/restore_source" "$source"
  cb_write_field "$(cb_tx_dir "$tx")/objects/$id/restore_mode" "$mode"
}

cb_rollback_once() {
  local operation=$1 current current_dir parent tx dir current_obj obj changed=0 source kind
  current=$(cb_current_tx)
  if [[ -z $current ]]; then
    printf 'codex-baseline is not installed; no changes\n'
    return 2
  fi
  current_dir=$(cb_live_tx_dir "$current")
  cb_validate_tx "$current" committed "$CB_STATE_ROOT"
  parent=$(cb_read_field "$current_dir/parent")
  cb_new_tx "$operation"
  tx=$CB_NEW_TX
  dir=$(cb_tx_dir "$tx")
  cb_write_field "$dir/rollback_target" "$current"
  cb_write_field "$dir/result_current" "$parent"
  for current_obj in "$current_dir"/objects/*; do
    [[ -d $current_obj && $(cb_read_field "$current_obj/status") == committed ]] || continue
    cb_plan_rollback_object "$tx" "$current_obj"
  done
  for obj in "$dir"/objects/*; do
    [[ -d $obj ]] || continue
    if [[ $(cb_read_field "$obj/change") == 1 ]]; then
      changed=1
      printf '%s: %s\n' "$operation" "$(cb_read_field "$obj/target")"
    fi
  done
  [[ $changed -eq 1 ]] || cb_die "transaction $current has no reversible changes"
  if [[ $CB_DRY_RUN -eq 1 ]]; then
    printf 'dry-run: would restore transaction %s; no files changed\n' "$current"
    cb_cleanup_temps
    CB_ACTIVE_TX=''
    return 0
  fi
  cb_write_field "$CB_PENDING" "$tx"
  for obj in "$dir"/objects/*; do
    [[ -d $obj && $(cb_read_field "$obj/change") == 1 ]] || continue
    source=$(cb_read_field "$obj/restore_source")
    kind=$(cb_read_field "$obj/kind")
    if [[ $(cb_read_field "$obj/restore_mode") == full-file ]]; then
      cb_prepare_object "$obj" "$source" "$kind" full-file
    else
      cb_prepare_object "$obj" "$source" "$kind"
    fi
  done
  cb_set_tx_state "$tx" prepared
  cb_set_tx_state "$tx" committing
  for obj in "$dir"/objects/*; do
    [[ -d $obj && $(cb_read_field "$obj/change") == 1 ]] || continue
    cb_commit_object "$obj"
  done
  if [[ -n $parent ]]; then
    cb_write_field "$CB_CURRENT" "$parent"
  else
    rm -f -- "$CB_CURRENT"
    cb_sync_parent "$CB_CURRENT"
  fi
  cb_set_tx_state "$tx" committed
  rm -f -- "$CB_PENDING"
  cb_sync_parent "$CB_PENDING"
  cb_cleanup_old_paths "$dir"
  CB_ACTIVE_TX=''
  printf 'restored state before transaction %s (recovery transaction %s)\n' "$current" "$tx"
  return 0
}

cb_rollback() {
  CB_VERSION=$(<"$CB_SOURCE_ROOT/VERSION")
  cb_init_paths
  cb_begin_operation
  cb_rollback_once rollback || {
    local code=$?
    [[ $code -eq 2 ]] && return 0
    return "$code"
  }
}

cb_uninstall() {
  local current current_dir obj
  CB_VERSION=$(<"$CB_SOURCE_ROOT/VERSION")
  cb_init_paths
  cb_begin_operation
  if [[ $CB_DRY_RUN -eq 1 ]]; then
    current=$(cb_current_tx)
    if [[ -z $current ]]; then
      printf 'codex-baseline is not installed; no changes\n'
      return 0
    fi
    while [[ -n $current ]]; do
      current_dir=$(cb_live_tx_dir "$current")
      [[ -d $current_dir ]] || cb_die "transaction chain is incomplete: $current"
      printf 'uninstall: would unwind transaction %s\n' "$current"
      for obj in "$current_dir"/objects/*; do
        [[ -d $obj && $(cb_read_field "$obj/status") == committed ]] || continue
        printf 'uninstall: %s\n' "$(cb_read_field "$obj/target")"
      done
      current=$(cb_read_field "$current_dir/parent")
    done
    printf 'dry-run: no files changed\n'
    return 0
  fi
  while [[ -n $(cb_current_tx) ]]; do
    cb_rollback_once uninstall
  done
  printf 'codex-baseline is uninstalled; transaction history retained in %s\n' "$CB_STATE_ROOT"
}

cb_doctor() {
  local current state failures=0 warnings=0 codex_version='not-found' codex_number='' agents_file markers
  local current_dir obj kind target installed live managed_total=0 managed_ok=0 skill_count=0
  local manifest manifest_root manifest_error_file manifest_error='' minimum_codex='' tested_codex='' research_checked='' research_review_by='' research_state=unknown platform=linux capabilities=unknown
  local baseline_version='' provenance_scope='local-source' provenance_version='' provenance_trust='' provenance_hash=''
  local codex_verification=not-found marker_begin marker_end transaction_json baseline_version_json provenance_version_json provenance_trust_json provenance_hash_json research_checked_json research_review_json
  local dependency dependency_state=verified config_state=unverified-codex-not-found deprecated_state=unverified-codex-not-found
  local -a warning_messages=() failure_messages=() required_dependencies=(
    awk bash basename chmod cp cut date dirname find grep head ln mkdir mktemp mv
    realpath sed sort stat tail wc
  ) missing_dependencies=()
  cb_init_paths
  for dependency in "${required_dependencies[@]}"; do
    if ! command -v "$dependency" >/dev/null 2>&1; then missing_dependencies+=("$dependency"); fi
  done
  if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    missing_dependencies+=('sha256sum-or-shasum')
  fi
  if [[ ${#missing_dependencies[@]} -gt 0 ]]; then
    dependency_state=missing
    failures=$((failures + 1))
    failure_messages+=("Required runtime commands are missing: ${missing_dependencies[*]}")
  fi
  manifest_root=$CB_SOURCE_ROOT
  if [[ -f $CB_RUNTIME/baseline/manifest.json ]]; then
    manifest_root=$CB_RUNTIME
    provenance_scope='installed-runtime'
  fi
  manifest="$manifest_root/baseline/manifest.json"
  if [[ $dependency_state == verified ]]; then
    manifest_error_file=$(mktemp "${TMPDIR:-/tmp}/codex-baseline-doctor-manifest.XXXXXX")
    if provenance_version=$(cb_verify_source_manifest "$manifest_root" 2>"$manifest_error_file"); then
      provenance_trust=$(sed -n 's/^  "source_trust": "\([A-Za-z0-9._-]*\)",$/\1/p' "$manifest")
      provenance_hash=$(sed -n 's/^  "payload_hash": "\([0-9a-f]*\)",$/\1/p' "$manifest")
      minimum_codex=$(sed -n 's/^  "minimum_codex": "\([0-9.]*\)",$/\1/p' "$manifest")
      tested_codex=$(sed -n 's/^  "tested_codex": "\([0-9.]*\)",$/\1/p' "$manifest")
      if [[ ! $minimum_codex =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        failures=$((failures + 1))
        failure_messages+=('Source manifest minimum_codex is malformed.')
        minimum_codex=''
      fi
      if [[ ! $tested_codex =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        failures=$((failures + 1))
        failure_messages+=('Source manifest tested_codex is malformed.')
        tested_codex=''
      fi
    else
      IFS= read -r manifest_error <"$manifest_error_file" || true
      manifest_error=${manifest_error#codex-baseline: }
      failures=$((failures + 1))
      failure_messages+=("Source/research manifest check failed: ${manifest_error:-unknown manifest verification error}")
    fi
    rm -f -- "$manifest_error_file"
  fi
  if command -v codex >/dev/null 2>&1; then
    codex_verification=executed
    if codex_version=$(codex --version 2>/dev/null); then
      if [[ $codex_version =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
        codex_number=${BASH_REMATCH[1]}
      else
        failures=$((failures + 1))
        failure_messages+=('Codex version output does not contain a semantic version.')
      fi
    else
      codex_version=error
      failures=$((failures + 1))
      failure_messages+=('Codex version probe failed.')
    fi
    if codex --strict-config --version >/dev/null 2>&1; then
      config_state=accepted-by-strict-config
      deprecated_state=none-reported-by-strict-config
    else
      config_state=rejected-by-strict-config
      deprecated_state=unverified-config-rejected
      failures=$((failures + 1))
      failure_messages+=('Codex strict-config version probe failed.')
    fi
    if codex features list 2>/dev/null | awk '$1 == "goals" || $1 == "multi_agent" || $1 == "skill_search" { if ($2 == "stable" && $3 == "true") seen[$1] = 1 } END { exit seen["goals"] && seen["multi_agent"] && seen["skill_search"] ? 0 : 1 }'; then
      capabilities=verified
    else
      warnings=$((warnings + 1))
      warning_messages+=('Native Codex capability probe is degraded.')
      capabilities=degraded
    fi
    if [[ -n $minimum_codex && -n $codex_number ]] && [[ $(printf '%s\n%s\n' "$minimum_codex" "$codex_number" | sort -V | head -n 1) != "$minimum_codex" ]]; then
      failures=$((failures + 1))
      failure_messages+=("Codex is older than the supported minimum version $minimum_codex.")
    fi
    if [[ -n $tested_codex && -n $codex_number && $codex_number != "$tested_codex" ]] &&
      [[ $(printf '%s\n%s\n' "$tested_codex" "$codex_number" | sort -V | head -n 1) == "$tested_codex" ]]; then
      capabilities=unverified-future-version
      warnings=$((warnings + 1))
      warning_messages+=("Codex $codex_number is newer than the tested version $tested_codex; volatile capabilities remain unverified.")
    fi
  else
    failures=$((failures + 1))
    failure_messages+=('Codex executable was not found.')
  fi
  if grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then platform=wsl2; fi
  current=$(cb_current_tx)
  state=not-installed
  if [[ -n $current && -d $(cb_live_tx_dir "$current") ]]; then
    current_dir=$(cb_live_tx_dir "$current")
    state=$(cb_read_field "$current_dir/state")
    baseline_version=$(cb_read_field "$current_dir/version")
    [[ $state == committed ]] || { failures=$((failures + 1)); failure_messages+=('Current transaction is not committed.'); }
    for obj in "$current_dir"/objects/*; do
      [[ -d $obj ]] || continue
      case $(cb_read_field "$obj/status") in committed|unchanged) ;; *) continue ;; esac
      managed_total=$((managed_total + 1))
      kind=$(cb_read_field "$obj/kind")
      target=$(cb_read_field "$obj/target")
      installed=$(cb_read_field "$obj/installed_hash")
      if live=$(cb_live_hash "$kind" "$target" 2>/dev/null); then
        if [[ $live == "$installed" ]]; then managed_ok=$((managed_ok + 1)); else failures=$((failures + 1)); failure_messages+=("Managed content drifted: $target"); fi
      else
        failures=$((failures + 1))
        failure_messages+=("Managed object could not be inspected: $target")
      fi
    done
  fi
  if [[ -f $CB_PENDING ]]; then
    failures=$((failures + 1))
    failure_messages+=('An incomplete transaction is pending recovery.')
  fi
  if [[ -d $CB_LOCK ]]; then
    warnings=$((warnings + 1))
    warning_messages+=('An operation lock exists.')
  fi
  agents_file="$CB_CODEX_HOME/AGENTS.md"
  if [[ -s $CB_CODEX_HOME/AGENTS.override.md ]]; then
    agents_file="$CB_CODEX_HOME/AGENTS.override.md"
  fi
  markers=$(cb_marker_counts "$agents_file")
  [[ $markers == '1 1' || $state == not-installed ]] || { failures=$((failures + 1)); failure_messages+=('Global guidance marker counts are invalid.'); }
  for target in \
    "$CB_AGENTS_HOME/skills/codex-baseline-repo-onboarding/SKILL.md" \
    "$CB_AGENTS_HOME/skills/codex-baseline-deep-work/SKILL.md" \
    "$CB_AGENTS_HOME/skills/codex-baseline-conformance-review/SKILL.md" \
    "$CB_AGENTS_HOME/skills/codex-baseline-retrospective/SKILL.md"; do
    [[ -f $target && ! -L $target ]] && skill_count=$((skill_count + 1))
  done
  [[ $state == not-installed || $skill_count -eq 4 ]] || { failures=$((failures + 1)); failure_messages+=('One or more baseline skills are missing.'); }
  if [[ -f $manifest ]]; then
    research_checked=$(sed -n 's/^  "research_checked": "\([0-9-]*\)",$/\1/p' "$manifest")
    research_review_by=$(sed -n 's/^  "research_review_by": "\([0-9-]*\)",$/\1/p' "$manifest")
    if [[ -n $research_review_by ]] && date -d "$research_review_by" >/dev/null 2>&1; then
      if [[ $(date -u +%s) -le $(date -u -d "$research_review_by 23:59:59" +%s) ]]; then
        research_state=current
      else
        research_state=stale
        warnings=$((warnings + 1))
        warning_messages+=('Research evidence is past its review-by date.')
      fi
    else
      research_state=invalid
      warnings=$((warnings + 1))
      warning_messages+=('Research freshness metadata is invalid.')
    fi
  fi
  if [[ $CB_JSON -eq 1 ]]; then
    marker_begin=${markers%% *}; marker_end=${markers##* }
    transaction_json=null; [[ -z $current ]] || transaction_json="\"$(cb_json_escape "$current")\""
    baseline_version_json=null; [[ -z $baseline_version ]] || baseline_version_json="\"$(cb_json_escape "$baseline_version")\""
    provenance_version_json=null; [[ -z $provenance_version ]] || provenance_version_json="\"$(cb_json_escape "$provenance_version")\""
    provenance_trust_json=null; [[ -z $provenance_trust ]] || provenance_trust_json="\"$(cb_json_escape "$provenance_trust")\""
    provenance_hash_json=null; [[ -z $provenance_hash ]] || provenance_hash_json="\"$(cb_json_escape "$provenance_hash")\""
    research_checked_json=null; [[ -z $research_checked ]] || research_checked_json="\"$(cb_json_escape "$research_checked")\""
    research_review_json=null; [[ -z $research_review_by ]] || research_review_json="\"$(cb_json_escape "$research_review_by")\""
    printf '{"schema":1,"contract":"codex-baseline-doctor/v1","platform":"%s","powershell":null,"codex":"%s","codex_verification":"%s","state":"%s","transaction":%s,"baseline_version":%s,"source_provenance":{"scope":"%s","version":%s,"trust":%s,"payload_sha256":%s},"global_guidance":"%s","marker_counts":{"begin":%d,"end":%d},"managed_objects":{"ok":%d,"total":%d},"skills":{"ok":%d,"total":4},"native_capabilities":"%s","runtime_dependencies":{"status":"%s","required":' \
      "$platform" "$(cb_json_escape "$codex_version")" "$codex_verification" "$(cb_json_escape "$state")" "$transaction_json" "$baseline_version_json" "$(cb_json_escape "$provenance_scope")" "$provenance_version_json" "$provenance_trust_json" "$provenance_hash_json" \
      "$(cb_json_escape "$agents_file")" "$marker_begin" "$marker_end" "$managed_ok" "$managed_total" "$skill_count" "$capabilities" "$dependency_state"
    cb_json_string_array "${required_dependencies[@]}"
    printf ',"missing":'
    cb_json_string_array "${missing_dependencies[@]}"
    printf '},"active_config":{"status":"%s","verification":"codex --strict-config --version"},"hook_state":{"baseline_owned":0,"user_owned":"preserved-not-enumerated"},"deprecated_settings":{"status":"%s"},"paths":{"home":"%s","codex_home":"%s","agents_home":"%s","state_root":"%s"},"owned_config_keys":0,"owned_hooks":0,"research":{"checked":%s,"review_by":%s,"state":"%s"},"warnings":' \
      "$config_state" "$deprecated_state" "$(cb_json_escape "$CB_HOME")" "$(cb_json_escape "$CB_CODEX_HOME")" "$(cb_json_escape "$CB_AGENTS_HOME")" "$(cb_json_escape "$CB_STATE_ROOT")" \
      "$research_checked_json" "$research_review_json" "$research_state"
    cb_json_string_array "${warning_messages[@]}"
    printf ',"failures":'
    cb_json_string_array "${failure_messages[@]}"
    printf ',"warning_count":%d,"failure_count":%d}\n' "$warnings" "$failures"
  else
    printf 'Codex: %s\nPlatform: %s\nInstallation: %s\nTransaction: %s\nBaseline version: %s\nSource provenance: %s version=%s trust=%s payload=%s\nGlobal guidance: %s (markers %s)\nManaged objects: %d/%d\nSkills: %d/4\nNative capabilities: %s\nRuntime dependencies: %s (%d required, %d missing)\nActive config: %s; deprecated settings: %s\nPaths: HOME=%s CODEX_HOME=%s AGENTS_HOME=%s state=%s\nOwned config keys/hooks: 0/0\nResearch: %s (checked %s, review by %s)\nWarnings: %d\nFailures: %d\n' \
      "$codex_version" "$platform" "$state" "${current:-none}" "${baseline_version:-none}" "$provenance_scope" "${provenance_version:-unknown}" "${provenance_trust:-unknown}" "${provenance_hash:-unknown}" "$agents_file" "$markers" "$managed_ok" "$managed_total" "$skill_count" "$capabilities" \
      "$dependency_state" "${#required_dependencies[@]}" "${#missing_dependencies[@]}" "$config_state" "$deprecated_state" "$CB_HOME" "$CB_CODEX_HOME" "$CB_AGENTS_HOME" "$CB_STATE_ROOT" \
      "$research_state" "${research_checked:-unknown}" "${research_review_by:-unknown}" "$warnings" "$failures"
  fi
  [[ $failures -eq 0 ]]
}

cb_parse_common_flags() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --dry-run) CB_DRY_RUN=1 ;;
      --json) CB_JSON=1 ;;
      --acknowledge-unverified-source) CB_ACKNOWLEDGE_UNVERIFIED_SOURCE=1 ;;
      *) cb_die "unknown option: $1" ;;
    esac
    shift
  done
}

main() {
  local command=${1:-help}
  [[ $# -eq 0 ]] || shift
  trap cb_on_exit EXIT
  case $command in
    install|update)
      cb_parse_common_flags "$@"
      cb_install_like "$command"
      ;;
    doctor)
      cb_parse_common_flags "$@"
      cb_doctor
      ;;
    rollback)
      cb_parse_common_flags "$@"
      cb_rollback
      ;;
    uninstall)
      cb_parse_common_flags "$@"
      cb_uninstall
      ;;
    onboard)
      exec "$CB_SCRIPT_DIR/onboard.sh" "$@"
      ;;
    benchmark)
      exec "$CB_SCRIPT_DIR/benchmark.sh" "$@"
      ;;
    help|-h|--help) cb_usage ;;
    *) cb_usage >&2; cb_die "unknown command: $command" ;;
  esac
}

main "$@"
