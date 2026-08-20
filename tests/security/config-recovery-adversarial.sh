#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

repository_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
baseline="$repository_root/scripts/codex-baseline.sh"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/codex-baseline-security.XXXXXX")

cleanup() {
  [[ $test_root == "${TMPDIR:-/tmp}"/codex-baseline-security.* && -d $test_root && ! -L $test_root ]] || return 0
  rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file_equals() {
  local path=$1 expected=$2 label=$3 actual
  [[ -f $path && ! -L $path ]] || fail "$label: missing ordinary file $path"
  actual=$(<"$path")
  [[ $actual == "$expected" ]] || fail "$label: file content changed"
}

set_fixture_paths() {
  local root=$1
  export HOME="$root/home"
  export CODEX_HOME="$HOME/.codex"
  export AGENTS_HOME="$HOME/.agents"
  export CODEX_BASELINE_TESTING=1
  export CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION=1
  mkdir -p -- "$CODEX_HOME" "$AGENTS_HOME"
}

run_baseline() {
  bash "$baseline" "$@"
}

assert_no_pending() {
  local label=$1 state="$CODEX_HOME/codex-baseline/state" path
  for path in "$state/pending" "$state/config/pending" "$state/config/composite-pending"; do
    [[ ! -e $path && ! -L $path ]] || fail "$label: pending pointer survived: $path"
  done
}

assert_no_baseline_state() {
  local label=$1 path
  for path in \
    "$CODEX_HOME/codex-baseline" \
    "$CODEX_HOME/agents/codex-baseline-reviewer.toml" \
    "$HOME/.local/bin/codex-baseline"; do
    [[ ! -e $path && ! -L $path ]] || fail "$label: predictable preflight failure created managed state: $path"
  done
  if [[ -d $AGENTS_HOME/skills ]]; then
    ! find -P "$AGENTS_HOME/skills" -mindepth 1 -maxdepth 1 -name 'codex-baseline-*' -print -quit | grep -q . ||
      fail "$label: predictable preflight failure installed a managed skill"
  fi
}

test_auto_cap_preflight_rejects_quoted_key() {
  local case_name=$1 table=$2 assignment=$3 root config before after output status
  root="$test_root/quoted-$case_name"
  set_fixture_paths "$root"
  config="$CODEX_HOME/config.toml"
  if [[ $table == root ]]; then printf '%s\n' "$assignment" >"$config"; else printf '[%s]\n%s\n' "$table" "$assignment" >"$config"; fi
  before=$(sha256sum -- "$config" | cut -d ' ' -f 1)
  set +e
  output=$(run_baseline install --acknowledge-unverified-source 2>&1)
  status=$?
  set -e
  [[ $status -ne 0 ]] || fail "$case_name: quoted activation key unexpectedly permitted install"
  grep -Fq 'quoted managed or activation keys are unsupported' <<<"$output" || fail "$case_name: unexpected diagnostic: $output"
  after=$(sha256sum -- "$config" | cut -d ' ' -f 1)
  [[ $after == "$before" ]] || fail "$case_name: quoted-key preflight changed config.toml"
  assert_no_baseline_state "$case_name"
}

test_auto_cap_veto_and_dry_run_plan() {
  local root="$test_root/auto-cap-veto" config before after output shim
  set_fixture_paths "$root"
  config="$CODEX_HOME/config.toml"
  printf '%s\n' '[features]' 'multi_agent = false # explicit user veto' >"$config"
  before=$(sha256sum -- "$config" | cut -d ' ' -f 1)
  shim="$root/shims"; mkdir -- "$shim"
  printf '#!/bin/sh\nexit 91\n' >"$shim/getfacl"
  printf '#!/bin/sh\nexit 92\n' >"$shim/getfattr"
  chmod 0700 "$shim/getfacl" "$shim/getfattr"
  PATH="$shim:/usr/bin:/bin" run_baseline install --acknowledge-unverified-source >"$root/install.log"
  after=$(sha256sum -- "$config" | cut -d ' ' -f 1)
  [[ $after == "$before" ]] || fail 'features.multi_agent=false did not preserve config bytes'
  ! grep -Eq '^max_concurrent_threads_per_session[[:space:]]*=' "$config" || fail 'features.multi_agent=false did not veto the fresh-install cap'
  [[ ! -e $CODEX_HOME/codex-baseline/state/config/current && ! -L $CODEX_HOME/codex-baseline/state/config/current ]] || fail 'features.multi_agent veto was incorrectly owned'

  root="$test_root/auto-cap-dry-run"
  set_fixture_paths "$root"
  output=$(run_baseline install --dry-run 2>&1)
  grep -Fq "install: $CODEX_HOME/config.toml (absent agent cap -> 6)" <<<"$output" || fail "dry-run omitted the structured automatic-cap plan: $output"
  assert_no_baseline_state 'automatic-cap dry-run'

  root="$test_root/auto-cap-veto-dry-run"
  set_fixture_paths "$root"
  printf '%s\n' '[features]' 'multi_agent = false # explicit user veto' >"$CODEX_HOME/config.toml"
  output=$(run_baseline install --dry-run 2>&1)
  ! grep -Fq 'absent agent cap -> 6' <<<"$output" || fail "vetoed dry-run advertised an automatic-cap mutation: $output"
  assert_no_baseline_state 'vetoed automatic-cap dry-run'
}

test_install_config_preflight_has_no_partial_core() {
  local root="$test_root/install-preflight-no-core" config before after output status shim
  set_fixture_paths "$root"
  config="$CODEX_HOME/config.toml"
  printf 'answer = 42\n' >"$config"
  before=$(sha256sum -- "$config" | cut -d ' ' -f 1)
  shim="$root/shims"; mkdir -- "$shim"
  printf '#!/bin/sh\nexit 91\n' >"$shim/getfacl"
  printf '#!/bin/sh\nexit 92\n' >"$shim/getfattr"
  chmod 0700 "$shim/getfacl" "$shim/getfattr"
  set +e
  output=$(PATH="$shim:/usr/bin:/bin" run_baseline install --acknowledge-unverified-source 2>&1)
  status=$?
  set -e
  [[ $status -ne 0 ]] || fail 'install config preflight unexpectedly ignored failing metadata inspection'
  grep -Fq 'cannot inspect CODEX_HOME default ACL' <<<"$output" || fail "install preflight diagnostic mismatch: $output"
  after=$(sha256sum -- "$config" | cut -d ' ' -f 1)
  [[ $after == "$before" ]] || fail 'failed install config preflight changed config.toml'
  assert_no_baseline_state 'failed install config preflight'
}

test_comment_roundtrip_and_key_flags() {
  local root="$test_root/comment-roundtrip" config before after current tx_dir
  set_fixture_paths "$root"
  config="$CODEX_HOME/config.toml"
  printf '%s\n' 'answer = 42' '' '[agents]' '# keep this comments-only table byte-for-byte' >"$config"
  before=$(sha256sum -- "$config" | cut -d ' ' -f 1)
  run_baseline optimize --apply >/dev/null
  run_baseline optimize --restore --apply >/dev/null
  after=$(sha256sum -- "$config" | cut -d ' ' -f 1)
  [[ $after == "$before" ]] || fail 'comments-only existing table did not round-trip byte-for-byte'

  root="$test_root/comment-after-create"
  set_fixture_paths "$root"
  config="$CODEX_HOME/config.toml"
  printf 'answer = 42\n' >"$config"
  run_baseline optimize --apply --speed fast >/dev/null
  current=$(<"$CODEX_HOME/codex-baseline/state/config/current")
  tx_dir="$CODEX_HOME/codex-baseline/state/config/transactions/$current/ownership/keys"
  [[ $(<"$tx_dir/service_tier/created_table") == 0 && $(<"$tx_dir/service_tier/separator_added") == 0 ]] || fail 'root speed key inherited another key table-restore flags'
  [[ $(<"$tx_dir/agents_enabled/created_table") == 1 && $(<"$tx_dir/agents_max/created_table") == 1 ]] || fail 'agents table creation flags were not recorded per key'
  printf '# independent user comment after Baseline-created keys\n' >>"$config"
  run_baseline optimize --restore --apply >/dev/null
  grep -Fqx '# independent user comment after Baseline-created keys' "$config" || fail 'restore discarded a user comment in a Baseline-created table'
  grep -Fqx '[features]' "$config" || fail 'restore removed the table containing independent user comment content'
}

test_metadata_only_recovery_tamper() {
  local root="$test_root/recovery-metadata-tamper" config state output status original_mode
  set_fixture_paths "$root"
  config="$CODEX_HOME/config.toml"
  printf 'answer = 42\n' >"$config"
  chmod 0640 "$config"
  export CODEX_BASELINE_TEST_CRASH_AFTER=9
  set +e
  output=$(run_baseline install --acknowledge-unverified-source 2>&1)
  status=$?
  set -e
  unset CODEX_BASELINE_TEST_CRASH_AFTER
  [[ $status -ne 0 ]] || fail 'metadata recovery fixture did not crash after config commit'
  grep -Fq 'config-committed:' <<<"$output" || fail "metadata recovery fixture missed config commit: $output"
  state="$CODEX_HOME/codex-baseline/state/config"
  [[ -f $state/pending ]] || fail 'metadata recovery fixture did not retain pending journal'
  original_mode=$(stat -Lc '%a' -- "$config")
  [[ $original_mode == 640 ]] || fail 'config commit did not preserve the original mode before tampering'
  chmod 0600 "$config"
  set +e
  output=$(run_baseline install --acknowledge-unverified-source 2>&1)
  status=$?
  set -e
  [[ $status -ne 0 ]] || fail 'metadata-only recovery tamper unexpectedly succeeded'
  grep -Fq 'metadata does not match the recovery journal' <<<"$output" || fail "metadata-only recovery tamper diagnostic mismatch: $output"
  [[ -f $state/pending ]] || fail 'failed metadata recovery did not retain its pending journal'
  [[ $(stat -Lc '%a' -- "$config") == 600 ]] || fail 'failed metadata recovery rewrote the tampered live metadata'
}

test_immediate_config_cas() {
  local root="$test_root/immediate-config-cas" config output status state
  set_fixture_paths "$root"
  config="$CODEX_HOME/config.toml"
  printf 'answer = 42\n' >"$config"
  run_baseline optimize --apply >/dev/null
  export CODEX_BASELINE_TEST_EDIT_CONFIG_BEFORE_RENAME=1
  set +e
  output=$(run_baseline optimize --apply --speed fast 2>&1)
  status=$?
  set -e
  unset CODEX_BASELINE_TEST_EDIT_CONFIG_BEFORE_RENAME
  [[ $status -ne 0 ]] || fail 'immediate config CAS fixture unexpectedly committed'
  grep -Fq 'changed immediately before atomic replace' <<<"$output" || fail "immediate config CAS diagnostic mismatch: $output"
  grep -Fqx 'concurrent-config-test-edit = true' "$config" || fail 'immediate config CAS discarded the concurrent edit'
  ! grep -Eq '^(service_tier|fast_mode)[[:space:]]*=' "$config" || fail 'immediate config CAS committed planned speed keys'
  state="$CODEX_HOME/codex-baseline/state/config"
  [[ -f $state/pending ]] || fail 'failed immediate config CAS did not retain recovery state'

  root="$test_root/immediate-config-remove-cas"
  set_fixture_paths "$root"
  config="$CODEX_HOME/config.toml"
  run_baseline optimize --apply >/dev/null
  export CODEX_BASELINE_TEST_EDIT_CONFIG_BEFORE_RENAME=1
  set +e
  output=$(run_baseline optimize --restore --apply 2>&1)
  status=$?
  set -e
  unset CODEX_BASELINE_TEST_EDIT_CONFIG_BEFORE_RENAME
  [[ $status -ne 0 ]] || fail 'immediate config removal CAS fixture unexpectedly committed'
  grep -Fq 'changed immediately before atomic remove' <<<"$output" || fail "immediate config removal CAS diagnostic mismatch: $output"
  grep -Fqx 'concurrent-config-test-edit = true' "$config" || fail 'immediate config removal CAS discarded the concurrent edit'
  state="$CODEX_HOME/codex-baseline/state/config"
  [[ -f $state/pending ]] || fail 'failed immediate config removal CAS did not retain recovery state'
}

test_prepared_config_is_not_published_early() {
  local root="$test_root/prepared-before-pending" config before after output status state
  set_fixture_paths "$root"
  config="$CODEX_HOME/config.toml"
  printf 'answer = 42\n' >"$config"
  before=$(sha256sum -- "$config" | cut -d ' ' -f 1)
  export CODEX_BASELINE_TEST_FAIL_AFTER_CONFIG_PREPARE_BEFORE_PENDING=1
  set +e
  output=$(run_baseline optimize --apply 2>&1)
  status=$?
  set -e
  unset CODEX_BASELINE_TEST_FAIL_AFTER_CONFIG_PREPARE_BEFORE_PENDING
  [[ $status -ne 0 ]] || fail 'prepared-before-pending fault unexpectedly committed'
  grep -Fq 'test fault after config preparation and before recovery publication' <<<"$output" ||
    fail "prepared-before-pending diagnostic mismatch: $output"
  after=$(sha256sum -- "$config" | cut -d ' ' -f 1)
  [[ $after == "$before" ]] || fail 'unpublished prepared transaction changed config.toml'
  state="$CODEX_HOME/codex-baseline/state/config"
  [[ ! -e $state/pending && ! -L $state/pending ]] || fail 'incomplete prepared transaction published a recovery pointer'
  run_baseline optimize --apply >/dev/null
  grep -Eq '^max_concurrent_threads_per_session[[:space:]]*=[[:space:]]*6$' "$config" ||
    fail 'unpublished prepared transaction blocked the next valid config transaction'
}

test_recovery_artifact_metadata_tamper() {
  local artifact=$1
  local root="$test_root/recovery-$artifact-metadata" config original state current tx_dir path output status
  set_fixture_paths "$root"
  config="$CODEX_HOME/config.toml"
  original="$root/original-config.toml"
  printf 'answer = 42\n' >"$config"
  chmod 0640 "$config"
  cp --preserve=all -- "$config" "$original"
  run_baseline optimize --apply >/dev/null
  state="$CODEX_HOME/codex-baseline/state/config"
  current=$(<"$state/current")
  tx_dir="$state/transactions/$current"
  path=$(<"$tx_dir/$artifact")
  case $artifact in
    stage)
      cp --preserve=all -- "$config" "$path"
      ;;
    old)
      cp --preserve=all -- "$original" "$path"
      rm -- "$config"
      ;;
    *) fail "unknown recovery metadata artifact: $artifact" ;;
  esac
  chmod 0600 "$path"
  printf 'committing\n' >"$tx_dir/state"
  printf '%s\n' "$current" >"$state/pending"
  set +e
  output=$(run_baseline optimize --apply 2>&1)
  status=$?
  set -e
  [[ $status -ne 0 ]] || fail "$artifact metadata tamper unexpectedly recovered"
  grep -Fq 'metadata does not match the recovery journal' <<<"$output" || fail "$artifact metadata tamper diagnostic mismatch: $output"
  [[ -f $state/pending ]] || fail "$artifact metadata tamper discarded pending recovery state"
  [[ $(stat -Lc '%a' -- "$path") == 600 ]] || fail "$artifact metadata tamper was rewritten during rejected recovery"
}

test_tampered_config_journal() {
  local case_name=$1 expected=$2 root state current tx_dir sentinel output status before after owned
  root="$test_root/journal-$case_name"
  set_fixture_paths "$root"
  run_baseline optimize --apply >/dev/null
  state="$CODEX_HOME/codex-baseline/state/config"
  current=$(<"$state/current")
  tx_dir="$state/transactions/$current"
  sentinel="$root/outside-sentinel"
  printf 'OUTSIDE-SENTINEL-%s\n' "$case_name" >"$sentinel"
  before=$(sha256sum -- "$CODEX_HOME/config.toml" | cut -d ' ' -f 1)
  printf 'committing\n' >"$tx_dir/state"
  printf '%s\n' "$current" >"$state/pending"
  case $case_name in
    target-outside) printf '%s\n' "$sentinel" >"$tx_dir/target" ;;
    stage-outside) printf '%s\n' "$sentinel" >"$tx_dir/stage" ;;
    old-outside) printf '%s\n' "$sentinel" >"$tx_dir/old" ;;
    extra-field) printf 'unexpected\n' >"$tx_dir/unexpected" ;;
    missing-field) rm -- "$tx_dir/desired_structure_hash" ;;
    unknown-ownership)
      owned="$tx_dir/ownership/keys/agents_enabled"
      mv -- "$owned" "$tx_dir/ownership/keys/unknown_key"
      ;;
    ownership-path) printf '%s\n' "$sentinel" >"$tx_dir/ownership/keys/agents_enabled/path" ;;
    prior-token)
      printf 'present\n' >"$tx_dir/ownership/keys/agents_enabled/prior_state"
      printf 'truthy\n' >"$tx_dir/ownership/keys/agents_enabled/prior_token"
      ;;
    installed-token) printf 'truthy\n' >"$tx_dir/ownership/keys/agents_enabled/installed_token" ;;
    metadata-overflow) printf '99999999999\n' >"$tx_dir/desired_uid" ;;
    metadata-owner) printf '4294967294\n' >"$tx_dir/desired_uid" ;;
    metadata-mode) printf '777\n' >"$tx_dir/desired_mode" ;;
    *) fail "unknown journal adversary: $case_name" ;;
  esac

  set +e
  output=$(run_baseline optimize --apply 2>&1)
  status=$?
  set -e
  [[ $status -ne 0 ]] || fail "$case_name: tampered journal unexpectedly succeeded"
  grep -Fq -- "$expected" <<<"$output" || fail "$case_name: unexpected diagnostic: $output"
  assert_file_equals "$sentinel" "OUTSIDE-SENTINEL-$case_name" "$case_name"
  after=$(sha256sum -- "$CODEX_HOME/config.toml" | cut -d ' ' -f 1)
  [[ $after == "$before" ]] || fail "$case_name: config.toml changed during rejected recovery"
  [[ -f $state/pending && $(<"$state/pending") == "$current" ]] || fail "$case_name: rejected pending state was not retained"
}

test_prefix_neighbors_and_standard_values() {
  local root="$test_root/prefix-neighbors" config line
  set_fixture_paths "$root"
  config="$CODEX_HOME/config.toml"
  printf '%s\n' \
    'service_tiers = "fast"' \
    'service_tier = "flex"' \
    '' \
    '[agents]' \
    'enabled_shadow = false' \
    'max_concurrent_threads_per_session_shadow = 9' \
    '' \
    '[features]' \
    'fast_mode_shadow = true' \
    'fast_mode = false' >"$config"
  run_baseline optimize --apply --speed standard >/dev/null
  for line in \
    'service_tiers = "fast"' \
    'service_tier = "flex"' \
    'enabled_shadow = false' \
    'max_concurrent_threads_per_session_shadow = 9' \
    'fast_mode_shadow = true' \
    'fast_mode = false'; do
    grep -Fqx -- "$line" "$config" || fail "prefix-neighbor line was changed or removed: $line"
  done
  grep -Eq '^enabled = true\r?$' "$config" || fail 'exact agents.enabled key was not installed'
  grep -Eq '^max_concurrent_threads_per_session = 6\r?$' "$config" || fail 'exact agents cap key was not installed'
}

test_metadata_fail_closed() {
  local case_name=$1 root config before after output status shim
  root="$test_root/metadata-$case_name"
  set_fixture_paths "$root"
  config="$CODEX_HOME/config.toml"

  case $case_name in
    missing-inspectors)
      printf 'answer = 42\n' >"$config"
      before=$(sha256sum -- "$config" | cut -d ' ' -f 1)
      shim="$root/path-without-inspectors"; mkdir -- "$shim"
      cp -as -- /usr/bin/. "$shim/"
      rm -f -- "$shim/getfacl" "$shim/getfattr"
      set +e
      output=$(PATH="$shim" run_baseline optimize --apply 2>&1)
      status=$?
      set -e
      [[ $status -ne 0 ]] || fail 'missing inspectors unexpectedly permitted config mutation'
      grep -Fq 'required command not found: getfacl' <<<"$output" || fail "missing-inspector diagnostic mismatch: $output"
      ;;
    inspector-error)
      printf 'answer = 42\n' >"$config"
      before=$(sha256sum -- "$config" | cut -d ' ' -f 1)
      shim="$root/shims"; mkdir -- "$shim"
      printf '#!/bin/sh\nexit 1\n' >"$shim/getfacl"
      printf '#!/bin/sh\nexit 0\n' >"$shim/getfattr"
      chmod 0700 "$shim/getfacl" "$shim/getfattr"
      set +e
      output=$(PATH="$shim:/usr/bin:/bin" run_baseline optimize --apply 2>&1)
      status=$?
      set -e
      [[ $status -ne 0 ]] || fail 'failing inspector unexpectedly permitted config mutation'
      grep -Fq 'cannot inspect CODEX_HOME default ACL' <<<"$output" || fail "inspector-error diagnostic mismatch: $output"
      ;;
    file-xattr)
      printf 'answer = 42\n' >"$config"
      setfattr -n user.codex_baseline_test -v present -- "$config"
      before=$(sha256sum -- "$config" | cut -d ' ' -f 1)
      set +e
      output=$(run_baseline optimize --apply 2>&1)
      status=$?
      set -e
      [[ $status -ne 0 ]] || fail 'file xattr unexpectedly permitted config mutation'
      grep -Fq 'extended attributes that cannot be preserved safely' <<<"$output" || fail "xattr diagnostic mismatch: $output"
      ;;
    file-acl)
      printf 'answer = 42\n' >"$config"
      setfacl -m u:65534:r-- -- "$config"
      before=$(sha256sum -- "$config" | cut -d ' ' -f 1)
      set +e
      output=$(run_baseline optimize --apply 2>&1)
      status=$?
      set -e
      [[ $status -ne 0 ]] || fail 'named ACL unexpectedly permitted config mutation'
      grep -Eq 'extended (ACL|attributes).*cannot be preserved safely' <<<"$output" || fail "ACL diagnostic mismatch: $output"
      ;;
    parent-default-acl)
      setfacl -d -m u:65534:r-x -- "$CODEX_HOME"
      before=absent
      set +e
      output=$(run_baseline optimize --apply 2>&1)
      status=$?
      set -e
      [[ $status -ne 0 ]] || fail 'parent default ACL unexpectedly permitted config creation'
      grep -Fq 'CODEX_HOME has a default ACL' <<<"$output" || fail "default-ACL diagnostic mismatch: $output"
      ;;
    *) fail "unknown metadata adversary: $case_name" ;;
  esac

  after=absent
  [[ ! -e $config ]] || after=$(sha256sum -- "$config" | cut -d ' ' -f 1)
  [[ $after == "$before" ]] || fail "$case_name: config.toml changed during rejected metadata check"
  [[ ! -e $CODEX_HOME/codex-baseline/state && ! -L $CODEX_HOME/codex-baseline/state ]] ||
    fail "$case_name: rejected metadata check created transaction state"
}

test_composite_crash_recovery() {
  local operation=$1 crash_after=$2 root output status state core config_current config_tx core_ref
  root="$test_root/composite-$operation"
  set_fixture_paths "$root"
  if [[ $operation != install ]]; then
    run_baseline install --acknowledge-unverified-source >/dev/null
  fi
  export CODEX_BASELINE_TEST_CRASH_AFTER=$crash_after
  set +e
  case $operation in
    install) output=$(run_baseline install --acknowledge-unverified-source 2>&1); status=$? ;;
    rollback) output=$(run_baseline rollback 2>&1); status=$? ;;
    uninstall) output=$(run_baseline uninstall 2>&1); status=$? ;;
    *) fail "unknown composite operation: $operation" ;;
  esac
  set -e
  unset CODEX_BASELINE_TEST_CRASH_AFTER
  [[ $status -ne 0 ]] || fail "$operation: phase fault did not interrupt the operation"
  grep -Fq 'test fault injection after mutation' <<<"$output" || fail "$operation: phase fault did not reach the requested mutation: $output"

  case $operation in
    install) run_baseline install --acknowledge-unverified-source >/dev/null ;;
    rollback) run_baseline rollback >/dev/null ;;
    uninstall) run_baseline uninstall >/dev/null ;;
  esac
  state="$CODEX_HOME/codex-baseline/state"
  if [[ $operation == install ]]; then
    [[ -f $state/current ]] || fail 'install recovery did not retain the desired core transaction'
    core=$(<"$state/current")
    [[ -f $CODEX_HOME/config.toml ]] || fail 'install recovery left core installed without the automatic config cap'
    grep -Eq '^max_concurrent_threads_per_session = 6\r?$' "$CODEX_HOME/config.toml" || fail 'install recovery did not commit the automatic config cap'
    config_current=$(<"$state/config/current")
    config_tx="$state/config/transactions/$config_current"
    core_ref=$(<"$config_tx/core_tx")
    [[ $core_ref == "$core" ]] || fail 'install recovery did not bind config ownership to the desired core transaction'
  else
    [[ ! -e $state/current && ! -L $state/current ]] || fail "$operation recovery retained an installed core transaction"
    if [[ -f $CODEX_HOME/config.toml ]]; then
      ! grep -Eq '^max_concurrent_threads_per_session = 6\r?$' "$CODEX_HOME/config.toml" || fail "$operation recovery left the baseline-owned cap behind"
    fi
  fi
  assert_no_pending "$operation"
}

for dependency in bash cut grep mktemp mv sha256sum; do
  command -v "$dependency" >/dev/null 2>&1 || fail "required test dependency is missing: $dependency"
done

run_journal_adversaries() {
  test_tampered_config_journal target-outside 'config transaction target mismatch'
  test_tampered_config_journal stage-outside 'config transaction stage mismatch'
  test_tampered_config_journal old-outside 'config transaction old-path mismatch'
  test_tampered_config_journal extra-field 'invalid field inventory'
  test_tampered_config_journal missing-field 'invalid field inventory'
  test_tampered_config_journal unknown-ownership 'unknown config ownership key'
  test_tampered_config_journal ownership-path 'config ownership path mismatch'
  test_tampered_config_journal prior-token 'invalid boolean token'
  test_tampered_config_journal installed-token 'invalid boolean token'
  test_tampered_config_journal metadata-overflow 'invalid config metadata in desired journal'
  test_tampered_config_journal metadata-owner 'desired config journal owner mismatch'
  test_tampered_config_journal metadata-mode 'metadata does not match the recovery journal'
}

run_composite_adversaries() {
  # Eight core objects mutate first. The ninth mutation is the first config
  # commit/removal point, so these faults exercise the durable core/config split.
  test_composite_crash_recovery install 9
  test_composite_crash_recovery rollback 9
  test_composite_crash_recovery uninstall 9
}

run_config_regressions() {
  test_prefix_neighbors_and_standard_values
  test_auto_cap_preflight_rejects_quoted_key quoted-disable agents '"enabled" = false'
  test_auto_cap_preflight_rejects_quoted_key quoted-cap agents '"max_concurrent_threads_per_session" = 4'
  test_auto_cap_preflight_rejects_quoted_key quoted-feature-veto features '"multi_agent" = false'
  test_auto_cap_preflight_rejects_quoted_key quoted-fast features '"fast_mode" = true'
  test_auto_cap_preflight_rejects_quoted_key quoted-root-service root '"service_tier" = "fast"'
  test_auto_cap_veto_and_dry_run_plan
  test_install_config_preflight_has_no_partial_core
  test_comment_roundtrip_and_key_flags
  test_metadata_only_recovery_tamper
  test_recovery_artifact_metadata_tamper stage
  test_recovery_artifact_metadata_tamper old
  test_prepared_config_is_not_published_early
  test_immediate_config_cas
}

run_config_adversaries() {
  for dependency in getfacl getfattr setfacl setfattr; do
    command -v "$dependency" >/dev/null 2>&1 || fail "required config metadata dependency is missing: $dependency"
  done
  run_config_regressions
  test_metadata_fail_closed missing-inspectors
  test_metadata_fail_closed inspector-error
  test_metadata_fail_closed file-xattr
  test_metadata_fail_closed file-acl
  test_metadata_fail_closed parent-default-acl
}

security_group=${CODEX_BASELINE_SECURITY_GROUP:-all}
case $security_group in
  journal) run_journal_adversaries ;;
  regression)
    for dependency in getfacl getfattr; do
      command -v "$dependency" >/dev/null 2>&1 || fail "required config regression dependency is missing: $dependency"
    done
    run_config_regressions
    ;;
  config) run_config_adversaries ;;
  composite) run_composite_adversaries ;;
  all)
    run_journal_adversaries
    run_composite_adversaries
    run_config_adversaries
    ;;
  *) fail "unknown CODEX_BASELINE_SECURITY_GROUP: ${CODEX_BASELINE_SECURITY_GROUP}" ;;
esac

printf 'PASS: adversarial config/recovery group %s\n' "$security_group"
