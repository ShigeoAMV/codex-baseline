#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

TEST_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/codex-baseline-tests.XXXXXX")
TEST_PASSED=0
trap 'rm -rf -- "$TEST_TMP"' EXIT

pass() {
  TEST_PASSED=$((TEST_PASSED + 1))
  printf 'ok %d - %s\n' "$TEST_PASSED" "$1"
}

new_home() {
  local name=$1 root
  root="$TEST_TMP/$name"
  mkdir -p -- "$root/home/.codex" "$root/home/.agents"
  printf '%s' "$root"
}

baseline() {
  local root=$1; shift
  local -a args=("$@")
  case ${args[0]:-} in
    install|update) args+=(--acknowledge-unverified-source) ;;
  esac
  HOME="$root/home" CODEX_HOME="$root/home/.codex" AGENTS_HOME="$root/home/.agents" \
    "$TEST_ROOT/scripts/codex-baseline.sh" "${args[@]}"
}

snapshot_files() {
  local root=$1 output=$2
  find "$root" -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum >"$output"
}

refresh_test_source_manifest() {
  local root=$1 generated payload_hash bytes digest
  generated=$("$root/scripts/release-payload.sh")
  payload_hash=$(jq -r .payload_hash <<<"$generated")
  bytes=$(jq -r '.payload[] | select(.path == "baseline/operations.json") | .bytes' <<<"$generated")
  digest=$(jq -r '.payload[] | select(.path == "baseline/operations.json") | .sha256' <<<"$generated")
  sed -i -E \
    -e "s#^(  \"payload_hash\": )\"[0-9a-f]{64}\"#\\1\"$payload_hash\"#" \
    -e "s#^    \{\"path\": \"baseline/operations.json\", \"bytes\": [0-9]+, \"sha256\": \"[0-9a-f]{64}\"\},#    {\"path\": \"baseline/operations.json\", \"bytes\": $bytes, \"sha256\": \"$digest\"},#" \
    "$root/baseline/manifest.json"
}

test_static_quality() {
  bash -n "$TEST_ROOT/scripts/"*.sh "$TEST_ROOT/scripts/lib/"*.sh "$TEST_ROOT/benchmarks/verifiers/"*.sh
  shellcheck "$TEST_ROOT/scripts/lib/common.sh" "$TEST_ROOT/scripts/codex-baseline.sh" \
    "$TEST_ROOT/scripts/onboard.sh" "$TEST_ROOT/scripts/benchmark.sh" "$TEST_ROOT/scripts/routing-probe.sh" "$TEST_ROOT/scripts/release-payload.sh" "$TEST_ROOT/scripts/research-check.sh" \
    "$TEST_ROOT/benchmarks/verifiers/"*.sh
  [[ $(wc -c <"$TEST_ROOT/baseline/global/AGENTS.block.md") -le 3500 ]]
  [[ $(wc -w <"$TEST_ROOT/baseline/global/AGENTS.block.md") -le 500 ]]
  for json in "$TEST_ROOT/baseline/manifest.json" "$TEST_ROOT/baseline/operations.json" "$TEST_ROOT/docs/research/manifest.json" "$TEST_ROOT/contracts/"*.json "$TEST_ROOT/contracts/golden/"*.json; do
    jq -e . "$json" >/dev/null
  done
  jq -e '
    .contract == "codex-baseline-operations/v1" and
    .transaction_states == ["planned","prepared","committing","recovering","committed","rolled-back"] and
    .object_states == ["planned","prepared","moving-old","old-moved","new-moved","committed","unchanged","rolled-back"] and
    .operations == ["install","update","rollback","uninstall"] and
    (.objects | length) == 8 and
    ([.objects[].id] | sort) == ["00","10","11","12","13","20","30","31"] and
    .reports == {doctor:"codex-baseline-doctor/v1",onboarding:"codex-baseline-onboarding/v1",benchmark:"codex-baseline-benchmark/v1"}
  ' "$TEST_ROOT/baseline/operations.json" >/dev/null
  jq -e --slurpfile operations "$TEST_ROOT/baseline/operations.json" '
    [.properties.transaction_states.prefixItems[].const] == $operations[0].transaction_states and
    [.properties.object_states.prefixItems[].const] == $operations[0].object_states and
    [.properties.operations.prefixItems[].const] == $operations[0].operations and
    ([.properties.objects.allOf[].contains.const] | sort_by(.id)) == ($operations[0].objects | sort_by(.id)) and
    .properties.reports.properties == {
      doctor:{const:"codex-baseline-doctor/v1"},
      onboarding:{const:"codex-baseline-onboarding/v1"},
      benchmark:{const:"codex-baseline-benchmark/v1"}
    }
  ' "$TEST_ROOT/contracts/operations.schema.json" >/dev/null
  "$TEST_ROOT/scripts/release-payload.sh" | jq -e --slurpfile manifest "$TEST_ROOT/baseline/manifest.json" '
    .payload_hash == $manifest[0].payload_hash and .payload == $manifest[0].payload and
    $manifest[0].source_trust == "unsigned-local-source"
  ' >/dev/null
  "$TEST_ROOT/scripts/research-check.sh" --json | jq -e '.contract == "codex-baseline-research-check/v1" and .state == "current" and .sources >= 10 and .network_access == false' >/dev/null
  test "$(jq -S 'keys' "$TEST_ROOT/contracts/golden/doctor-unix.json")" = "$(jq -S 'keys' "$TEST_ROOT/contracts/golden/doctor-windows.json")"
  test "$(jq -S 'keys' "$TEST_ROOT/contracts/golden/onboarding-unix.json")" = "$(jq -S 'keys' "$TEST_ROOT/contracts/golden/onboarding-windows.json")"
  if rg -n -e '/home/[A-Za-z0-9][A-Za-z0-9._-]*/' -e '[A-Z]:\\Users\\[^\\]+' "$TEST_ROOT/baseline" "$TEST_ROOT/scripts" "$TEST_ROOT/benchmarks"; then
    return 1
  fi
  pass 'static syntax, lint, context budget, and portable paths'
}

test_dry_run_and_lifecycle() {
  local root status tampered_source tampered_root racy_source racy_root duplicate_source duplicate_root
  root=$(new_home lifecycle)
  printf 'custom-before\n' >"$root/home/.codex/AGENTS.md"
  printf 'unrelated\n' >"$root/home/.agents/keep.txt"
  set +e
  HOME="$root/home" CODEX_HOME="$root/home/.codex" AGENTS_HOME="$root/home/.agents" \
    "$TEST_ROOT/scripts/codex-baseline.sh" install >"$root/unacknowledged.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q -- '--acknowledge-unverified-source' "$root/unacknowledged.log"
  test ! -e "$root/home/.codex/codex-baseline"

  tampered_source="$TEST_TMP/tampered-source"
  mkdir -p -- "$tampered_source"
  cp -a -- "$TEST_ROOT/VERSION" "$TEST_ROOT/baseline" "$TEST_ROOT/benchmarks" "$TEST_ROOT/scripts" "$tampered_source/"
  printf '\ntampered\n' >>"$tampered_source/baseline/global/AGENTS.block.md"
  tampered_root=$(new_home tampered-payload)
  set +e
  HOME="$tampered_root/home" CODEX_HOME="$tampered_root/home/.codex" AGENTS_HOME="$tampered_root/home/.agents" \
    "$tampered_source/scripts/codex-baseline.sh" install --acknowledge-unverified-source >"$tampered_root/install.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -Eq 'payload (byte length|hash) mismatch' "$tampered_root/install.log"
  test ! -e "$tampered_root/home/.codex/codex-baseline"

  racy_source="$TEST_TMP/racy-source"
  mkdir -p -- "$racy_source"
  cp -a -- "$TEST_ROOT/VERSION" "$TEST_ROOT/baseline" "$TEST_ROOT/benchmarks" "$TEST_ROOT/scripts" "$racy_source/"
  racy_root=$(new_home racy-payload)
  find "$racy_root/home" -printf '%P|%y|%m|%s\n' | LC_ALL=C sort >"$racy_root/before"
  set +e
  HOME="$racy_root/home" CODEX_HOME="$racy_root/home/.codex" AGENTS_HOME="$racy_root/home/.agents" \
    CODEX_BASELINE_TESTING=1 CODEX_BASELINE_TEST_MUTATE_SOURCE_AFTER_VERIFY=1 \
    "$racy_source/scripts/codex-baseline.sh" install --acknowledge-unverified-source >"$racy_root/install.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -Eq 'payload (byte length|hash) mismatch|changed while creating the verified snapshot' "$racy_root/install.log"
  find "$racy_root/home" -printf '%P|%y|%m|%s\n' | LC_ALL=C sort >"$racy_root/after"
  cmp "$racy_root/before" "$racy_root/after"

  find "$root/home" -printf '%P|%y|%m|%s\n' | LC_ALL=C sort >"$root/before"
  baseline "$root" install --dry-run >"$root/dry.log"
  find "$root/home" -printf '%P|%y|%m|%s\n' | LC_ALL=C sort >"$root/after"
  cmp "$root/before" "$root/after"
  baseline "$root" install >"$root/install.log"
  test "$(grep -c '^<!-- codex-baseline:begin version=' "$root/home/.codex/AGENTS.md")" -eq 1
  test -x "$root/home/.local/bin/codex-baseline"
  test "$(find "$root/home/.agents/skills" -mindepth 1 -maxdepth 1 -type d -name 'codex-baseline-*' | wc -l)" -eq 4
  snapshot_files "$root/home" "$root/installed-before"
  baseline "$root" install >"$root/reinstall.log"
  snapshot_files "$root/home" "$root/installed-after"
  cmp "$root/installed-before" "$root/installed-after"
  baseline "$root" doctor --json | jq -e --arg payload "$(jq -r .payload_hash "$TEST_ROOT/baseline/manifest.json")" '
    .contract == "codex-baseline-doctor/v1" and .failure_count == 0 and
    .baseline_version == "0.1.0" and
    .source_provenance == {scope:"installed-runtime",version:"0.1.0",trust:"unsigned-local-source",payload_sha256:$payload} and
    .managed_objects == {ok:8,total:8} and .skills == {ok:4,total:4} and
    .runtime_dependencies.status == "verified" and (.runtime_dependencies.missing | length) == 0 and
    .active_config.status == "accepted-by-strict-config" and
    .hook_state == {baseline_owned:0,user_owned:"preserved-not-enumerated"} and
    .deprecated_settings.status == "none-reported-by-strict-config" and
    (.paths.home | length) > 0 and (.paths.state_root | length) > 0
  ' >/dev/null
  mkdir -p -- "$root/old-codex"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ ${1:-} == --version || ${1:-} == --strict-config ]]; then printf "%s\n" "codex-cli 0.146.0"; exit 0; fi' \
    'if [[ ${1:-} == features && ${2:-} == list ]]; then printf "%s\n" "goals stable true" "multi_agent stable true" "skill_search stable true"; exit 0; fi' \
    'exit 1' >"$root/old-codex/codex"
  chmod 0755 "$root/old-codex/codex"
  set +e
  HOME="$root/home" CODEX_HOME="$root/home/.codex" AGENTS_HOME="$root/home/.agents" PATH="$root/old-codex:$PATH" \
    "$TEST_ROOT/scripts/codex-baseline.sh" doctor --json >"$root/old-doctor.json"
  status=$?
  set -e
  [[ $status -ne 0 ]]
  jq -e '.native_capabilities == "verified" and any(.failures[]; test("older than the supported minimum version 0.147.0"))' "$root/old-doctor.json" >/dev/null
  mkdir -p -- "$root/future-codex"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ ${1:-} == --version || ${1:-} == --strict-config ]]; then printf "%s\n" "codex-cli 0.148.0"; exit 0; fi' \
    'if [[ ${1:-} == features && ${2:-} == list ]]; then printf "%s\n" "goals stable true" "multi_agent stable true" "skill_search stable true"; exit 0; fi' \
    'exit 1' >"$root/future-codex/codex"
  chmod 0755 "$root/future-codex/codex"
  HOME="$root/home" CODEX_HOME="$root/home/.codex" AGENTS_HOME="$root/home/.agents" PATH="$root/future-codex:$PATH" \
    "$TEST_ROOT/scripts/codex-baseline.sh" doctor --json >"$root/future-doctor.json"
  jq -e '.failure_count == 0 and .native_capabilities == "unverified-future-version" and any(.warnings[]; test("newer than the tested version 0.147.0"))' "$root/future-doctor.json" >/dev/null
  mkdir -p -- "$root/duplicate-feature-codex"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ ${1:-} == --version || ${1:-} == --strict-config ]]; then printf "%s\n" "codex-cli 0.147.0"; exit 0; fi' \
    'if [[ ${1:-} == features && ${2:-} == list ]]; then printf "%s\n" "goals stable true" "goals stable true" "goals stable true"; exit 0; fi' \
    'exit 1' >"$root/duplicate-feature-codex/codex"
  chmod 0755 "$root/duplicate-feature-codex/codex"
  HOME="$root/home" CODEX_HOME="$root/home/.codex" AGENTS_HOME="$root/home/.agents" PATH="$root/duplicate-feature-codex:$PATH" \
    "$TEST_ROOT/scripts/codex-baseline.sh" doctor --json >"$root/duplicate-feature-doctor.json"
  jq -e '.native_capabilities == "degraded" and any(.warnings[]; test("capability probe is degraded"))' "$root/duplicate-feature-doctor.json" >/dev/null

  duplicate_source="$TEST_TMP/duplicate-operation-source"
  mkdir -p -- "$duplicate_source"
  cp -a -- "$TEST_ROOT/VERSION" "$TEST_ROOT/baseline" "$TEST_ROOT/benchmarks" "$TEST_ROOT/scripts" "$duplicate_source/"
  awk '/"id": "00"/ { duplicate = $0 } /"id": "10"/ { $0 = duplicate } { print }' \
    "$duplicate_source/baseline/operations.json" >"$duplicate_source/baseline/operations.json.tmp"
  mv -- "$duplicate_source/baseline/operations.json.tmp" "$duplicate_source/baseline/operations.json"
  refresh_test_source_manifest "$duplicate_source"
  duplicate_root=$(new_home duplicate-operation-contract)
  set +e
  HOME="$duplicate_root/home" CODEX_HOME="$duplicate_root/home/.codex" AGENTS_HOME="$duplicate_root/home/.agents" \
    "$duplicate_source/scripts/codex-baseline.sh" install --dry-run >"$duplicate_root/install.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'operations object contract mismatch' "$duplicate_root/install.log"
  baseline "$root" rollback --dry-run >"$root/rollback-dry.log"
  baseline "$root" rollback >"$root/rollback.log"
  cmp <(printf 'custom-before\n') "$root/home/.codex/AGENTS.md"
  cmp <(printf 'unrelated\n') "$root/home/.agents/keep.txt"
  test ! -e "$root/home/.local/bin/codex-baseline"
  test ! -e "$root/home/.agents/skills/codex-baseline-deep-work"
  pass 'dry-run, clean install, idempotence, doctor, and exact rollback'
}

test_drift_and_user_content() {
  local root status
  root=$(new_home drift)
  printf 'before\n' >"$root/home/.codex/AGENTS.md"
  baseline "$root" install >/dev/null
  printf '\nafter-user-content\n' >>"$root/home/.codex/AGENTS.md"
  baseline "$root" rollback >/dev/null
  grep -q '^before$' "$root/home/.codex/AGENTS.md"
  grep -q '^after-user-content$' "$root/home/.codex/AGENTS.md"
  if grep -q 'codex-baseline:begin' "$root/home/.codex/AGENTS.md"; then return 1; fi

  root=$(new_home drift-owned)
  baseline "$root" install >/dev/null
  printf '\nuser-edit\n' >>"$root/home/.agents/skills/codex-baseline-deep-work/SKILL.md"
  set +e
  baseline "$root" update >"$root/drift.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'managed content drifted' "$root/drift.log"
  grep -q 'user-edit' "$root/home/.agents/skills/codex-baseline-deep-work/SKILL.md"
  pass 'user-owned AGENTS content survives and managed drift fails closed'
}

test_crash_recovery() {
  local root status tx old target_hash
  root=$(new_home crash)
  printf 'pre-crash\n' >"$root/home/.codex/AGENTS.md"
  set +e
  HOME="$root/home" CODEX_HOME="$root/home/.codex" AGENTS_HOME="$root/home/.agents" \
    CODEX_BASELINE_TESTING=1 CODEX_BASELINE_TEST_CRASH_AFTER=2 \
    "$TEST_ROOT/scripts/codex-baseline.sh" install --acknowledge-unverified-source >"$root/crash.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 && -f $root/home/.codex/codex-baseline/state/pending ]]
  tx=$(<"$root/home/.codex/codex-baseline/state/pending")
  old=$(<"$root/home/.codex/codex-baseline/state/transactions/$tx/objects/00/old")
  target_hash=$(sha256sum "$root/home/.codex/AGENTS.md" | cut -d' ' -f1)
  printf '%s\n' 'corrupt-preimage' >"$old"
  set +e
  baseline "$root" install >"$root/corrupt-recovery.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'recovery preimage' "$root/corrupt-recovery.log"
  test "$(sha256sum "$root/home/.codex/AGENTS.md" | cut -d' ' -f1)" = "$target_hash"
  cp -- "$root/home/.codex/codex-baseline/state/transactions/$tx/objects/00/backup_file" "$old"
  baseline "$root" install >"$root/recover.log" 2>&1
  grep -q 'recovering incomplete transaction' "$root/recover.log"
  baseline "$root" doctor --json | jq -e '.failure_count == 0 and .state == "committed"' >/dev/null
  grep -Rqx 'rolled-back' "$root/home/.codex/codex-baseline/state/transactions"/*/state
  pass 'hard-crash journal recovery returns to a consistent install'
}

test_journal_and_concurrent_edit_guards() {
  local root outside status tx target_field agents_before skill_before
  root=$(new_home journal-id)
  outside="$root/outside-sentinel"
  printf '%s\n' 'outside-safe' >"$outside"
  mkdir -p -- "$root/home/.codex/codex-baseline/state"
  printf '%s\n' '../../outside-sentinel' >"$root/home/.codex/codex-baseline/state/pending"
  set +e
  baseline "$root" install >"$root/invalid-id.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'invalid transaction id' "$root/invalid-id.log"
  cmp <(printf '%s\n' 'outside-safe') "$outside"

  root=$(new_home journal-target)
  outside="$root/outside-sentinel"
  printf '%s\n' 'outside-safe' >"$outside"
  printf '%s\n' 'owner-text' >"$root/home/.codex/AGENTS.md"
  set +e
  HOME="$root/home" CODEX_HOME="$root/home/.codex" AGENTS_HOME="$root/home/.agents" \
    CODEX_BASELINE_TESTING=1 CODEX_BASELINE_TEST_CRASH_AFTER=2 \
    "$TEST_ROOT/scripts/codex-baseline.sh" install --acknowledge-unverified-source >"$root/crash.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  tx=$(<"$root/home/.codex/codex-baseline/state/pending")
  target_field="$root/home/.codex/codex-baseline/state/transactions/$tx/objects/00/target"
  printf '%s\n' "$outside" >"$target_field"
  set +e
  baseline "$root" install >"$root/invalid-target.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'unexpected managed target' "$root/invalid-target.log"
  cmp <(printf '%s\n' 'outside-safe') "$outside"
  printf '%s\n' "$root/home/.codex/AGENTS.md" >"$target_field"
  baseline "$root" install >/dev/null

  root=$(new_home journal-incomplete-set)
  set +e
  HOME="$root/home" CODEX_HOME="$root/home/.codex" AGENTS_HOME="$root/home/.agents" \
    CODEX_BASELINE_TESTING=1 CODEX_BASELINE_TEST_CRASH_AFTER=2 \
    "$TEST_ROOT/scripts/codex-baseline.sh" install --acknowledge-unverified-source >"$root/crash.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  tx=$(<"$root/home/.codex/codex-baseline/state/pending")
  agents_before=$(sha256sum "$root/home/.codex/AGENTS.md" | cut -d' ' -f1)
  skill_before=$(sha256sum "$root/home/.agents/skills/codex-baseline-repo-onboarding/SKILL.md" | cut -d' ' -f1)
  rm -rf -- "$root/home/.codex/codex-baseline/state/transactions/$tx/objects/31"
  set +e
  baseline "$root" install >"$root/incomplete-set.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'incomplete object inventory' "$root/incomplete-set.log"
  test "$(sha256sum "$root/home/.codex/AGENTS.md" | cut -d' ' -f1)" = "$agents_before"
  test "$(sha256sum "$root/home/.agents/skills/codex-baseline-repo-onboarding/SKILL.md" | cut -d' ' -f1)" = "$skill_before"
  test -f "$root/home/.codex/codex-baseline/state/pending"

  root=$(new_home physical-race)
  printf '%s\n' 'owner-text' >"$root/home/.codex/AGENTS.md"
  set +e
  HOME="$root/home" CODEX_HOME="$root/home/.codex" AGENTS_HOME="$root/home/.agents" \
    CODEX_BASELINE_TESTING=1 CODEX_BASELINE_TEST_EDIT_AGENTS_BEFORE_COMMIT=1 \
    "$TEST_ROOT/scripts/codex-baseline.sh" install --acknowledge-unverified-source >"$root/physical-race.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'guidance file changed during transaction' "$root/physical-race.log"
  grep -q '^owner-text$' "$root/home/.codex/AGENTS.md"
  grep -q '^concurrent-test-edit$' "$root/home/.codex/AGENTS.md"
  tx=$(<"$root/home/.codex/codex-baseline/state/pending")
  cp -- "$root/home/.codex/codex-baseline/state/transactions/$tx/objects/00/backup_file" "$root/home/.codex/AGENTS.md"
  baseline "$root" install >/dev/null
  pass 'journal tampering, corrupt preimages, and concurrent AGENTS edits fail closed'
}

test_symlink_boundaries() {
  local root outside status
  root=$(new_home symlink)
  outside="$TEST_TMP/outside"
  mkdir -p -- "$outside"
  rmdir -- "$root/home/.agents"
  ln -s -- "$outside" "$root/home/.agents"
  set +e
  baseline "$root" install >"$root/symlink.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  test -z "$(find "$outside" -mindepth 1 -print -quit)"
  grep -Eq 'safe directory|symbolic-link' "$root/symlink.log"
  pass 'symlinked managed roots fail closed without writing through the link'
}

test_onboarding() {
  local fixture before backups_before backups_after link_fixture outside status race_fixture race_backup new_fixture root_swap_fixture root_swap_outside root_swap_original
  fixture="$TEST_TMP/onboarding"
  mkdir -p -- "$fixture/.github/workflows" "$fixture/src/auth"
  printf '%s\n' '{' '  "scripts": {' '    "test": "touch EXECUTED",' '    "lint": "echo nope"' '  }' '}' >"$fixture/package.json"
  printf 'name: ci\n' >"$fixture/.github/workflows/ci.yml"
  printf 'existing repo rule\n' >"$fixture/AGENTS.md"
  printf '%s\n' '{}' >"$fixture/package-lock.json"
  printf '%s\n' '# Architecture' >"$fixture/ARCHITECTURE.md"
  printf 'TOP SECRET\n' >"$fixture/.env"
  printf 'code\n' >"$fixture/src/auth/login.ts"
  printf 'untrusted name\n' >"$fixture/src/auth-](bad).md"
  ln -s /etc/passwd "$fixture/outside-link"
  sha256sum "$fixture/AGENTS.md" >"$fixture/agents.before"
  "$TEST_ROOT/scripts/onboard.sh" --json "$fixture" >"$fixture/report.json"
  jq -e '.project_commands_executed == false and .entries_visited > .files and .links_skipped == 1 and .sensitive_skipped == 1 and (.commands | index("npm run test")) != null' "$fixture/report.json" >/dev/null
  test ! -e "$fixture/EXECUTED"
  before=$(cut -d' ' -f1 "$fixture/agents.before")
  test "$(sha256sum "$fixture/AGENTS.md" | cut -d' ' -f1)" = "$before"
  set +e
  "$TEST_ROOT/scripts/onboard.sh" --apply "$fixture" >"$fixture/unacknowledged-apply.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q -- '--acknowledge-existing-instructions' "$fixture/unacknowledged-apply.log"
  test "$(sha256sum "$fixture/AGENTS.md" | cut -d' ' -f1)" = "$before"
  "$TEST_ROOT/scripts/onboard.sh" --apply --acknowledge-existing-instructions "$fixture" >"$fixture/apply.log"
  grep -q 'npm run test.*declared, not executed' "$fixture/AGENTS.md"
  grep -q '^existing repo rule$' "$fixture/AGENTS.md"
  grep -q '`src`' "$fixture/AGENTS.md"
  grep -q '`ARCHITECTURE.md`' "$fixture/AGENTS.md"
  grep -q '`package-lock.json`' "$fixture/AGENTS.md"
  grep -q '`src/auth/login.ts`' "$fixture/AGENTS.md"
  ! grep -q 'auth-](bad)' "$fixture/AGENTS.md"
  backups_before=$(find "$fixture" -maxdepth 1 -name 'AGENTS.md.codex-baseline-backup.*' | wc -l)
  "$TEST_ROOT/scripts/onboard.sh" --apply --acknowledge-existing-instructions "$fixture" >"$fixture/reapply.log"
  backups_after=$(find "$fixture" -maxdepth 1 -name 'AGENTS.md.codex-baseline-backup.*' | wc -l)
  test "$backups_before" -eq "$backups_after"

  outside="$TEST_TMP/onboarding-outside"
  link_fixture="$TEST_TMP/onboarding-package-link"
  mkdir -p -- "$outside" "$link_fixture"
  printf '%s\n' '{"scripts":{"outside-secret-command":"echo no"}}' >"$outside/package.json"
  ln -s -- "$outside/package.json" "$link_fixture/package.json"
  "$TEST_ROOT/scripts/onboard.sh" --json "$link_fixture" >"$link_fixture/report.json"
  jq -e '.links_skipped == 1 and (.commands | length) == 0' "$link_fixture/report.json" >/dev/null
  ! grep -q 'outside-secret-command' "$link_fixture/report.json"

  set +e
  "$TEST_ROOT/scripts/onboard.sh" --max-entries 2 "$fixture" >"$fixture/entry-limit.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'entry visit limit exceeded' "$fixture/entry-limit.log"

  race_fixture="$TEST_TMP/onboarding-race"
  mkdir -p -- "$race_fixture"
  printf '%s\n' 'original-rule' >"$race_fixture/AGENTS.md"
  set +e
  CODEX_BASELINE_TESTING=1 CODEX_BASELINE_TEST_ONBOARD_RACE=1 \
    "$TEST_ROOT/scripts/onboard.sh" --apply --acknowledge-existing-instructions "$race_fixture" >"$race_fixture/race.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'concurrent-test-edit' "$race_fixture/AGENTS.md"
  race_backup=$(find "$race_fixture" -maxdepth 1 -type f -name 'AGENTS.md.codex-baseline-backup.*' -print -quit)
  cmp <(printf '%s\n' 'original-rule') "$race_backup"

  root_swap_fixture="$TEST_TMP/onboarding-root-swap"
  root_swap_outside="$TEST_TMP/onboarding-root-swap-outside"
  root_swap_original="$root_swap_fixture.codex-baseline-test-original"
  mkdir -p -- "$root_swap_fixture" "$root_swap_outside"
  printf '%s\n' 'root-swap-original' >"$root_swap_fixture/AGENTS.md"
  set +e
  CODEX_BASELINE_TESTING=1 CODEX_BASELINE_TEST_ONBOARD_ROOT_SWAP=1 \
    CODEX_BASELINE_TEST_ONBOARD_ROOT_SWAP_TARGET="$root_swap_outside" \
    "$TEST_ROOT/scripts/onboard.sh" --apply --acknowledge-existing-instructions "$root_swap_fixture" >"$TEST_TMP/root-swap.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -Eq 'repository (root|ancestor).*changed|became linked' "$TEST_TMP/root-swap.log"
  test -L "$root_swap_fixture"
  cmp <(printf '%s\n' 'root-swap-original') "$root_swap_original/AGENTS.md"
  test -z "$(find "$root_swap_outside" -mindepth 1 -print -quit)"
  test -z "$(find "$root_swap_original" -maxdepth 1 -name '.codex-baseline-*' -print -quit)"

  new_fixture="$TEST_TMP/onboarding-new-repository"
  mkdir -p -- "$new_fixture"
  git -C "$new_fixture" init -q
  "$TEST_ROOT/scripts/onboard.sh" --apply "$new_fixture" >"$new_fixture/apply.log"
  test "$(grep -c '^<!-- codex-baseline:onboarding:begin version=' "$new_fixture/AGENTS.md")" -eq 1
  test -z "$(find "$new_fixture" -maxdepth 1 -name 'AGENTS.md.codex-baseline-backup.*' -print -quit)"
  "$TEST_ROOT/scripts/onboard.sh" --apply "$new_fixture" >"$new_fixture/reapply.log"
  grep -q 'already current' "$new_fixture/reapply.log"
  pass 'onboarding is static, bounded, secret/link-safe, explicit, and idempotent'
}

test_benchmark_contract() {
  local output="$TEST_TMP/benchmark-live" status platform=linux
  if grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then platform=wsl2; fi
  "$TEST_ROOT/scripts/benchmark.sh" --static >/dev/null
  jq -e '.tasks | map(.class) | unique | sort == ["large","medium","risk-sensitive","small"]' "$TEST_ROOT/benchmarks/manifest.json" >/dev/null
  set +e
  CODEX_BASELINE_BENCHMARK_API_KEY=synthetic PATH="$TEST_ROOT/tests/fixtures:$PATH" \
    "$TEST_ROOT/scripts/benchmark.sh" --live --tasks small-js-bug --repetitions 1 --output "$TEST_ROOT/docs/unapproved-benchmark-output" >"$TEST_TMP/bad-output.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'result directory inside source' "$TEST_TMP/bad-output.log"
  test ! -e "$TEST_ROOT/docs/unapproved-benchmark-output"
  CODEX_BASELINE_BENCHMARK_API_KEY=synthetic PATH="$TEST_ROOT/tests/fixtures:$PATH" \
    "$TEST_ROOT/scripts/benchmark.sh" --live --tasks small-js-bug --repetitions 1 --output "$output" >/dev/null
  jq -e --arg platform "$platform" '
    .contract == "codex-baseline-benchmark/v1" and .platform == $platform and
    .mode == "live-paired" and .status == "completed" and
    .isolation == "os-sandboxed-local" and .model_invoked and .verifiers_executed
  ' "$output/run.json" >/dev/null
  jq -s -e '
    length == 2 and all(.pass) and all(.class == "small") and all(.changed_files == 1) and
    all(.unnecessary_files == 0) and all(.retry_count == null) and
    (map(.source_hash) | unique | length) == 1 and
    (map(select(.arm == "baseline" and .baseline_layer_bytes > 0)) | length) == 1 and
    (map(select(.arm == "vanilla" and .baseline_layer_bytes == 0)) | length) == 1
  ' "$output/results.jsonl" >/dev/null
  jq -e '
    .contract == "codex-baseline-benchmark-summary/v1" and .runs == 2 and .pairs == 1 and
    .paired_outcomes.both_pass == 1 and .by_task[0].task == "small-js-bug" and
    .by_task[0].repetitions == 1 and .by_task[0].pass_rate_delta == 0 and
    .inference.confidence_interval == null
  ' "$output/summary.json" >/dev/null
  test ! -e "$output/INVALID.md"
  pass 'benchmark static contracts and deterministic paired live-run mechanics are valid'
}

test_routing_contract() {
  local output="$TEST_TMP/routing-live"
  CODEX_BASELINE_BENCHMARK_API_KEY=synthetic PATH="$TEST_ROOT/tests/fixtures:$PATH" \
    "$TEST_ROOT/scripts/routing-probe.sh" --repetitions 1 --output "$output" >/dev/null
  jq -e '.runs == 6 and .passes == 6 and all(.by_case[]; .runs == 1 and .passes == 1)' "$output/summary.json" >/dev/null
  jq -s -e 'length == 6 and all(.pass) and all(.process_exit == 0)' "$output/results.jsonl" >/dev/null
  pass 'routing fixtures and isolated repeated-probe mechanics are valid'
}

test_worktree_isolation() {
  local repository="$TEST_TMP/worktree-source" worker_a="$TEST_TMP/worktree-agent-a" worker_b="$TEST_TMP/worktree-agent-b"
  mkdir -p -- "$repository"
  git -C "$repository" init -q
  git -C "$repository" config user.name 'Codex Baseline Test'
  git -C "$repository" config user.email 'codex-baseline-test@localhost'
  printf 'base\n' >"$repository/shared.txt"
  git -C "$repository" add shared.txt
  git -C "$repository" commit -q -m base
  git -C "$repository" branch agent-a
  git -C "$repository" branch agent-b
  git -C "$repository" worktree add -q "$worker_a" agent-a
  git -C "$repository" worktree add -q "$worker_b" agent-b
  printf 'agent-a\n' >"$worker_a/shared.txt"
  printf 'agent-b\n' >"$worker_b/shared.txt"
  cmp <(printf 'base\n') "$repository/shared.txt"
  cmp <(printf 'agent-a\n') "$worker_a/shared.txt"
  cmp <(printf 'agent-b\n') "$worker_b/shared.txt"
  test "$(git -C "$worker_a" status --short)" = ' M shared.txt'
  test "$(git -C "$worker_b" status --short)" = ' M shared.txt'
  git -C "$repository" worktree remove --force "$worker_a"
  git -C "$repository" worktree remove --force "$worker_b"
  pass 'conflicting writable workers remain isolated in explicit worktrees'
}

test_documentation_contract() {
  "$TEST_ROOT/scripts/check-docs.sh" >/dev/null
  for document in README.md CHANGELOG.md PLAN.md docs/ARCHITECTURE.md docs/INSTALL.md \
    docs/PLATFORMS.md docs/OPERATIONS.md docs/ONBOARDING.md docs/SECURITY.md \
    docs/BENCHMARKS.md docs/TROUBLESHOOTING.md docs/RELEASE.md; do
    test -s "$TEST_ROOT/$document"
  done
  pass 'documentation inventory and all repository-local links are valid'
}

test_codex_discovery() {
  local root repo prompt flattened skill
  root=$(new_home discovery)
  repo="$root/repo"
  mkdir -p -- "$repo/nested"
  git -C "$repo" init -q
  printf 'Root project rule: ROOT-PROBE-2718.\n' >"$repo/AGENTS.md"
  printf 'Nested refinement: NESTED-PROBE-3141.\n' >"$repo/nested/AGENTS.md"
  baseline "$root" install >/dev/null
  prompt="$root/prompt.json"
  (
    cd "$repo/nested"
    HOME="$root/home" CODEX_HOME="$root/home/.codex" AGENTS_HOME="$root/home/.agents" \
      codex debug prompt-input 'discovery probe' >"$prompt" 2>"$root/prompt.stderr"
  )
  jq -e 'type == "array"' "$prompt" >/dev/null
  flattened=$(jq -r '.. | strings' "$prompt")
  grep -q 'Understand the request and the repository' <<<"$flattened"
  grep -q 'ROOT-PROBE-2718' <<<"$flattened"
  grep -q 'NESTED-PROBE-3141' <<<"$flattened"
  for skill in codex-baseline-repo-onboarding codex-baseline-deep-work codex-baseline-conformance-review codex-baseline-retrospective; do
    grep -q "$skill" <<<"$flattened"
  done
  pass 'Codex prompt input loads global/root/nested guidance and all skill metadata'
}

printf '1..12\n'
test_static_quality
test_dry_run_and_lifecycle
test_drift_and_user_content
test_crash_recovery
test_journal_and_concurrent_edit_guards
test_symlink_boundaries
test_onboarding
test_benchmark_contract
test_routing_contract
test_worktree_isolation
test_documentation_contract
test_codex_discovery
