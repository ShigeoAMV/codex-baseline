#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

TEST_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/codex-baseline-tests.XXXXXX")
TEST_PASSED=0
# shellcheck source=scripts/lib/common.sh
source "$TEST_ROOT/scripts/lib/common.sh"
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

validate_schema() {
  PYTHONDONTWRITEBYTECODE=1 python3 "$TEST_ROOT/tests/validate-json-schema.py" "$1" "$2"
}

assert_schema_rejects() {
  if validate_schema "$1" "$2" >/dev/null 2>&1; then
    printf 'schema unexpectedly accepted invalid fixture: %s\n' "$2" >&2
    return 1
  fi
}

validate_jsonl_schema() {
  local schema=$1 jsonl=$2 line number=0 instance="$TEST_TMP/jsonl-instance.json"
  while IFS= read -r line; do
    number=$((number + 1))
    [[ -n $line ]] || { printf 'blank JSONL record at line %d: %s\n' "$number" "$jsonl" >&2; return 1; }
    printf '%s\n' "$line" >"$instance"
    validate_schema "$schema" "$instance"
  done <"$jsonl"
  (( number > 0 ))
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
  local schema_fixture="$TEST_TMP/schema-fixture.json" source_tree="$TEST_TMP/source-hash" snapshot="$TEST_TMP/source-snapshot"
  local hash_before hash_after scan_tree="$TEST_TMP/evaluation-scan-state" git_guard="$TEST_TMP/evaluation-git-guard"
  bash -n "$TEST_ROOT/scripts/"*.sh "$TEST_ROOT/scripts/lib/"*.sh "$TEST_ROOT/benchmarks/verifiers/"*.sh \
    "$TEST_ROOT/tests/behavior/"*.sh "$TEST_ROOT/tests/behavior/verifiers/"*.sh
  shellcheck "$TEST_ROOT/scripts/lib/common.sh" "$TEST_ROOT/scripts/lib/evaluation.sh" "$TEST_ROOT/scripts/codex-baseline.sh" \
    "$TEST_ROOT/scripts/onboard.sh" "$TEST_ROOT/scripts/benchmark.sh" "$TEST_ROOT/scripts/routing-probe.sh" "$TEST_ROOT/scripts/release-payload.sh" "$TEST_ROOT/scripts/research-check.sh" \
    "$TEST_ROOT/benchmarks/verifiers/"*.sh "$TEST_ROOT/tests/behavior/"*.sh "$TEST_ROOT/tests/behavior/verifiers/"*.sh
  PYTHONDONTWRITEBYTECODE=1 python3 -c 'import jsonschema'
  [[ $(wc -c <"$TEST_ROOT/baseline/global/AGENTS.block.md") -le 3500 ]]
  [[ $(wc -w <"$TEST_ROOT/baseline/global/AGENTS.block.md") -le 500 ]]
  for json in "$TEST_ROOT/baseline/manifest.json" "$TEST_ROOT/baseline/operations.json" "$TEST_ROOT/docs/research/manifest.json" "$TEST_ROOT/contracts/"*.json "$TEST_ROOT/contracts/golden/"*.json; do
    jq -e . "$json" >/dev/null
  done
  jq -e . "$TEST_ROOT/tests/behavior/cases.json" "$TEST_ROOT/tests/behavior/output.schema.json" "$TEST_ROOT/tests/behavior/starter.json" >/dev/null
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
  jq -e '
    .additionalProperties == false and
    .properties.mode.enum == ["live-paired","live-containment-canary","static-contract-only"] and
    .allOf[0].if.properties.mode.const == "live-containment-canary" and
    .allOf[0].then.properties.platform.enum == ["linux","wsl2"] and
    .allOf[0].then.properties.isolation.const == "os-sandboxed-local-cgroup" and
    .allOf[0].then.properties.model_invoked.const and
    (.allOf[0].then.properties.verifiers_executed.const | not) and
    .allOf[0].then.properties.tool_network_target.const == "loopback-only" and
    .allOf[0].then.properties.auth.const == "dedicated-api-key-stdin-pipe" and
    .allOf[0].then.properties.resource_profile.const == "user-cgroup-memory2g-swap0-tasks128-cpu200-runtime-bounded-tmpfs" and
    (.allOf[0].then.required | index("source_hash") != null) and
    .allOf[1].if.properties.mode.const == "live-paired" and
    .allOf[1].then.properties.isolation.const == "os-sandboxed-local-cgroup" and
    .allOf[1].then.properties.model_invoked.const and .allOf[1].then.properties.verifiers_executed.const and
    .allOf[1].then.properties.resource_profile.const == "user-cgroup-memory2g-swap0-tasks128-cpu200-runtime-bounded-tmpfs" and
    (.allOf[1].then.required | index("manifest_hash") != null) and
    .allOf[2].if.properties.mode.const == "static-contract-only" and
    .allOf[2].then.properties.platform.const == "native-windows" and
    .allOf[2].then.properties.isolation.const == "not-applicable-no-worker" and
    (.allOf[2].then.properties.model_invoked.const | not) and
    (.allOf[2].then.properties.verifiers_executed.const | not)
  ' "$TEST_ROOT/contracts/benchmark-report.schema.json" >/dev/null
  jq -e '
    .additionalProperties == false and
    .properties.contract.const == "codex-baseline-containment-canary/v1" and
    ([.required[]] | index("proc_key_carrier_secret_unreadable") != null) and
    ([.required[]] | index("tool_network_loopback_denied") != null) and
    ([.required[]] | index("artifact_exact_secret_scan") != null)
  ' "$TEST_ROOT/contracts/benchmark-canary.schema.json" >/dev/null

  jq -n '{schema:1,contract:"codex-baseline-benchmark/v1",platform:"wsl2",mode:"live-containment-canary",status:"completed",isolation:"os-sandboxed-local-cgroup",model_invoked:true,verifiers_executed:false,created:"2026-08-13T12:00:00Z",codex:"codex 0.147.0",model:"account-default",source_revision:"abc",source_dirty:false,source_hash:("0"*64),codex_binary_hash:("1"*64),codex_identity:"caller-pinned-sha256",node_binary_hash:("2"*64),auth:"dedicated-api-key-stdin-pipe",tool_network_target:"loopback-only",resource_profile:"user-cgroup-memory2g-swap0-tasks128-cpu200-runtime-bounded-tmpfs"}' >"$schema_fixture"
  validate_schema "$TEST_ROOT/contracts/benchmark-report.schema.json" "$schema_fixture"
  jq '.model_invoked = false' "$schema_fixture" >"$schema_fixture.invalid"
  assert_schema_rejects "$TEST_ROOT/contracts/benchmark-report.schema.json" "$schema_fixture.invalid"
  jq -n '{schema:1,contract:"codex-baseline-benchmark/v1",platform:"linux",mode:"live-paired",status:"completed",isolation:"os-sandboxed-local-cgroup",model_invoked:true,verifiers_executed:true,created:"2026-08-13T12:00:00Z",codex:"codex 0.147.0",model:"account-default",source_revision:"abc",source_dirty:false,source_hash:("0"*64),manifest_hash:("1"*64),codex_binary_hash:("2"*64),codex_identity:"caller-pinned-sha256",node_binary_hash:("3"*64),auth:"dedicated-api-key-stdin-pipe",account_service_tier:"unknown",resource_profile:"user-cgroup-memory2g-swap0-tasks128-cpu200-runtime-bounded-tmpfs"}' >"$schema_fixture"
  validate_schema "$TEST_ROOT/contracts/benchmark-report.schema.json" "$schema_fixture"
  jq 'del(.source_hash)' "$schema_fixture" >"$schema_fixture.invalid"
  assert_schema_rejects "$TEST_ROOT/contracts/benchmark-report.schema.json" "$schema_fixture.invalid"
  jq -n '{schema:1,contract:"codex-baseline-benchmark/v1",platform:"native-windows",mode:"static-contract-only",status:"completed",isolation:"not-applicable-no-worker",model_invoked:false,verifiers_executed:false,tasks:[{}],limitations:["no worker"]}' >"$schema_fixture"
  validate_schema "$TEST_ROOT/contracts/benchmark-report.schema.json" "$schema_fixture"
  jq '.verifiers_executed = true' "$schema_fixture" >"$schema_fixture.invalid"
  assert_schema_rejects "$TEST_ROOT/contracts/benchmark-report.schema.json" "$schema_fixture.invalid"
  jq -n '{schema:1,contract:"codex-baseline-containment-canary/v1",pass:true,process_exit:0,environment_secret_absent:true,proc_key_carrier_secret_unreadable:true,tool_network_loopback_denied:true,artifact_exact_secret_scan:true,source_hash:("0"*64)}' >"$schema_fixture"
  validate_schema "$TEST_ROOT/contracts/benchmark-canary.schema.json" "$schema_fixture"
  jq '.proc_key_carrier_secret_unreadable = false' "$schema_fixture" >"$schema_fixture.invalid"
  assert_schema_rejects "$TEST_ROOT/contracts/benchmark-canary.schema.json" "$schema_fixture.invalid"

  jq -n '{schema:1,task:"small-js-bug",class:"small",arm:"baseline",repetition:1,pass:true,process_exit:0,verifier_exit:0,elapsed_ms:1,turns:1,commands:1,file_changes:1,changed_files:1,unnecessary_files:0,changed_paths:["calc.js"],unnecessary_paths:[],failed_command_events:0,subagent_events:0,input_tokens:null,output_tokens:null,baseline_layer_bytes:1,retry_count:null,review_findings:null,isolation:"os-sandboxed-local-cgroup",source_hash:("0"*64),layer_hash:("1"*64),fixture_hash:("2"*64),prompt_hash:("3"*64),verifier_hash:("4"*64)}' >"$schema_fixture"
  validate_schema "$TEST_ROOT/contracts/benchmark-result.schema.json" "$schema_fixture"
  jq '.process_exit = 7' "$schema_fixture" >"$schema_fixture.invalid"
  assert_schema_rejects "$TEST_ROOT/contracts/benchmark-result.schema.json" "$schema_fixture.invalid"
  jq -n '{schema:1,contract:"codex-baseline-routing-result/v1",id:"lean-typo",repetition:1,pass:true,process_exit:0,elapsed_ms:1,turns:1,commands:0,file_changes:0,input_tokens:null,output_tokens:null,source_hash:("0"*64),prompt_hash:("1"*64),expected:{workflow:"LEAN",high_risk:false,skill:null},actual:{workflow:"LEAN",high_risk:false,selected_skills:[],reason:"bounded"}}' >"$schema_fixture"
  validate_schema "$TEST_ROOT/contracts/routing-result.schema.json" "$schema_fixture"
  jq '.actual.workflow = "DEEP"' "$schema_fixture" >"$schema_fixture.invalid"
  assert_schema_rejects "$TEST_ROOT/contracts/routing-result.schema.json" "$schema_fixture.invalid"
  jq -n '{schema:1,contract:"codex-baseline-behavior-result/v1",id:"deep-risk-plan",repetition:1,pass:true,process_exit:0,verifier_exit:0,elapsed_ms:1,turns:1,commands:1,file_changes:0,input_tokens:null,output_tokens:null,source_hash:("0"*64),prompt_hash:("1"*64),actual:{case_id:"deep-risk-plan",workflow:"DEEP",high_risk:true,selected_skills:["codex-baseline-deep-work"],evidence_files:[],material_question:null,plan:null,risk_controls:null,onboarding:null,conformance:null,reason:"schema-valid test receipt"}}' >"$schema_fixture"
  validate_schema "$TEST_ROOT/contracts/behavior-result.schema.json" "$schema_fixture"
  jq '.actual = {}' "$schema_fixture" >"$schema_fixture.invalid"
  assert_schema_rejects "$TEST_ROOT/contracts/behavior-result.schema.json" "$schema_fixture.invalid"

  mkdir -- "$scan_tree"
  printf 'clean\n' >"$scan_tree/artifact.txt"
  /bin/bash -c '
    source "$1/scripts/lib/common.sh"
    source "$1/scripts/lib/evaluation.sh"
    set +e
    set +o pipefail
    eval_tree_is_clean "$2"
    [[ $- != *e* && $(set -o | awk '\''$1 == "pipefail" { print $2 }'\'') == off ]]
    set -e
    set -o pipefail
    eval_tree_is_clean "$2"
    [[ $- == *e* && $(set -o | awk '\''$1 == "pipefail" { print $2 }'\'') == on ]]
  ' _ "$TEST_ROOT" "$scan_tree"

  mkdir -p -- "$git_guard/repo" "$git_guard/home"
  printf 'tracked\n' >"$git_guard/repo/tracked.txt"
  printf '#!/bin/sh\n: >%q\nprintf "%%s\\n" "2 0000000000000000000000000000000000000000"\n' \
    "$git_guard/fsmonitor-invoked" >"$git_guard/fsmonitor"
  chmod 0755 -- "$git_guard/fsmonitor"
  git -C "$git_guard/repo" init -q
  git -C "$git_guard/repo" -c user.name=codex-baseline -c user.email=baseline.invalid add tracked.txt
  git -C "$git_guard/repo" -c user.name=codex-baseline -c user.email=baseline.invalid commit -qm starter
  git -C "$git_guard/repo" config core.fsmonitor "$git_guard/fsmonitor"
  /bin/bash -c '
    source "$1/scripts/lib/common.sh"
    source "$1/scripts/lib/evaluation.sh"
    eval_git "$2/repo" "$2/home" diff --quiet --no-ext-diff --no-textconv HEAD --
  ' _ "$TEST_ROOT" "$git_guard"
  test ! -e "$git_guard/fsmonitor-invoked"

  mkdir -p -- "$source_tree/excluded" "$source_tree/benchmark-results" "$source_tree/behavior-results" "$source_tree/.codebase-memory" "$snapshot"
  printf 'source\n' >"$source_tree/tracked.txt"
  printf 'ignored\n' >"$source_tree/benchmark-results/result.txt"
  hash_before=$(cb_source_tree_hash "$source_tree")
  mkdir -- "$source_tree/empty-directory"
  hash_after=$(cb_source_tree_hash "$source_tree")
  [[ $hash_before != "$hash_after" ]]
  hash_before=$hash_after
  chmod 0700 -- "$source_tree/empty-directory"
  hash_after=$(cb_source_tree_hash "$source_tree")
  [[ $hash_before != "$hash_after" ]]
  hash_before=$hash_after
  printf 'changed but excluded\n' >"$source_tree/benchmark-results/result.txt"
  [[ $(cb_source_tree_hash "$source_tree") == "$hash_before" ]]
  cb_copy_source_tree "$source_tree" "$snapshot"
  [[ $(cb_source_tree_hash "$snapshot") == "$hash_before" ]]
  test ! -e "$snapshot/benchmark-results"
  test ! -e "$snapshot/behavior-results"
  test ! -e "$snapshot/.codebase-memory"
  rm -rf -- "$source_tree/behavior-results"
  ln -s /tmp "$source_tree/behavior-results"
  if (cb_source_tree_hash "$source_tree" >/dev/null 2>&1); then return 1; fi
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
  local output="$TEST_TMP/benchmark-live" canary_output="$TEST_TMP/benchmark-canary"
  local git_attack_output="$TEST_TMP/benchmark-git-metadata" identity_output="$TEST_TMP/benchmark-identity"
  local leak_output="$TEST_TMP/benchmark-canary-leak" workspace_leak_output="$TEST_TMP/benchmark-canary-workspace-leak"
  local home_leak_output="$TEST_TMP/benchmark-canary-home-leak" sentinel_leak_output="$TEST_TMP/benchmark-canary-sentinel-leak"
  local forged_output="$TEST_TMP/benchmark-canary-forged" special_output="$TEST_TMP/benchmark-canary-special"
  local network_hit_output="$TEST_TMP/benchmark-canary-network-hit" proc_output="$TEST_TMP/benchmark-canary-proc"
  local listener_output="$TEST_TMP/benchmark-canary-listener" filename_output="$TEST_TMP/benchmark-canary-filename"
  local dirname_output="$TEST_TMP/benchmark-canary-dirname" invalidated_output="$TEST_TMP/benchmark-invalidated"
  local many_output="$TEST_TMP/benchmark-canary-many"
  local malformed_output="$TEST_TMP/benchmark-malformed"
  local failed_output="$TEST_TMP/benchmark-failed"
  local newline_output="$TEST_TMP/benchmark-newline-key" hijack_root="$TEST_TMP/benchmark-path-hijack"
  local startup_env="$TEST_TMP/benchmark-bash-env" startup_marker="$TEST_TMP/benchmark-startup-key-seen"
  local dispatcher_marker="$TEST_TMP/benchmark-dispatcher-key-seen"
  local quiescence_log="$TEST_TMP/benchmark-quiescence.log"
  local installed_root installed_result installed_bad status platform=linux
  local CODEX_BASELINE_TESTING=1
  local CODEX_BASELINE_EXPECTED_CODEX_SHA256
  CODEX_BASELINE_EXPECTED_CODEX_SHA256=$(sha256sum -- "$TEST_ROOT/tests/fixtures/codex" | awk '{print $1}')
  export CODEX_BASELINE_TESTING CODEX_BASELINE_EXPECTED_CODEX_SHA256
  if grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then platform=wsl2; fi
  "$TEST_ROOT/scripts/benchmark.sh" --static >/dev/null
  jq -e '.tasks | map(.class) | unique | sort == ["large","medium","risk-sensitive","small"]' "$TEST_ROOT/benchmarks/manifest.json" >/dev/null
  (
    # shellcheck source=scripts/lib/evaluation.sh
    source "$TEST_ROOT/scripts/lib/evaluation.sh"
    eval_validate_system_boundary
    eval_require_cgroup_boundary
    eval_run_scoped_command 15 \
      "$EVAL_ENV" -i PATH=/usr/bin:/bin LANG=C.UTF-8 LC_ALL=C.UTF-8 \
      "$EVAL_BWRAP" --unshare-all --unshare-user --disable-userns --die-with-parent --new-session --clearenv --cap-drop ALL \
      --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib --symlink usr/lib64 /lib64 \
      --proc /proc --dev /dev --size 16777216 --tmpfs /tmp --dir /eval-lib \
      --ro-bind "$TEST_ROOT/scripts/lib/common.sh" /eval-lib/common.sh \
      --ro-bind "$TEST_ROOT/scripts/lib/evaluation.sh" /eval-lib/evaluation.sh \
      --setenv CODEX_BASELINE_EVAL_PID_NAMESPACE 1 --setenv HOME /tmp --setenv PATH /usr/bin:/bin \
      /usr/bin/bash -c 'source /eval-lib/common.sh; source /eval-lib/evaluation.sh; /usr/bin/sleep 30 & eval_quiesce_worker_processes; printf "%s\n" worker-quiescence-pass'
  ) >"$quiescence_log" 2>&1
  grep -q '^worker-quiescence-pass$' "$quiescence_log"
  set +e
  "$TEST_ROOT/scripts/benchmark.sh" --static --live >"$TEST_TMP/benchmark-multiple-modes.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'select exactly one' "$TEST_TMP/benchmark-multiple-modes.log"
  set +e
  CODEX_BASELINE_BENCHMARK_API_KEY=synthetic PATH="$TEST_ROOT/tests/fixtures:$PATH" \
    "$TEST_ROOT/scripts/benchmark.sh" --live --tasks small-js-bug --repetitions 1 --output "$TEST_ROOT/docs/unapproved-benchmark-output" >"$TEST_TMP/bad-output.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'result directory inside source' "$TEST_TMP/bad-output.log"
  test ! -e "$TEST_ROOT/docs/unapproved-benchmark-output"

  set +e
  CODEX_BASELINE_BENCHMARK_API_KEY=$'invalid\nsecond-line' PATH="$TEST_ROOT/tests/fixtures:$PATH" \
    "$TEST_ROOT/scripts/benchmark.sh" --live --tasks small-js-bug --repetitions 1 --output "$newline_output" >"$TEST_TMP/benchmark-newline.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'invalid line break' "$TEST_TMP/benchmark-newline.log"
  test ! -e "$newline_output"

  mkdir -- "$hijack_root"
  for command in bash bwrap grep; do
    printf '#!/bin/sh\nprintf "%%s\\n" %q >>%q\nexit 97\n' "$command" "$hijack_root/invoked" >"$hijack_root/$command"
    chmod 0755 -- "$hijack_root/$command"
  done
  mkdir -- "$hijack_root/lib"
  printf '#!/bin/sh\nprintf "%%s\\n" %q >>%q\nprintf "%%s\\n" %q\n' \
    dirname "$hijack_root/invoked" "$hijack_root" >"$hijack_root/dirname"
  chmod 0755 -- "$hijack_root/dirname"
  printf 'if [[ ${CB_DISPATCH_BENCHMARK_KEY-} == synthetic ]]; then : >%q; fi\n' \
    "$dispatcher_marker" >"$hijack_root/lib/common.sh"
  printf 'if [[ -n ${CODEX_BASELINE_BENCHMARK_API_KEY-} ]]; then : >%q; fi\n' "$startup_marker" >"$startup_env"
  BASH_ENV="$startup_env" CODEX_BASELINE_BENCHMARK_API_KEY=synthetic PATH="$hijack_root:$TEST_ROOT/tests/fixtures:$PATH" \
    "$TEST_ROOT/scripts/benchmark.sh" --live --tasks small-js-bug --repetitions 1 --output "$output" >/dev/null
  test ! -e "$hijack_root/invoked"
  test ! -e "$startup_marker"
  test ! -e "$dispatcher_marker"
  jq -e --arg platform "$platform" '
    .contract == "codex-baseline-benchmark/v1" and .platform == $platform and
    .mode == "live-paired" and .status == "completed" and
    .isolation == "os-sandboxed-local-cgroup" and .model_invoked and .verifiers_executed and
    .auth == "dedicated-api-key-stdin-pipe" and
    .resource_profile == "user-cgroup-memory2g-swap0-tasks128-cpu200-runtime-bounded-tmpfs" and
    (.codex_binary_hash | test("^[0-9a-f]{64}$")) and .codex_identity == "caller-pinned-sha256" and
    (.node_binary_hash | test("^[0-9a-f]{64}$"))
  ' "$output/run.json" >/dev/null
  validate_schema "$TEST_ROOT/contracts/benchmark-report.schema.json" "$output/run.json"
  validate_jsonl_schema "$TEST_ROOT/contracts/benchmark-result.schema.json" "$output/results.jsonl"
  jq -s -e '
    length == 2 and all(.pass) and all(.class == "small") and all(.changed_files == 1) and
    all(.unnecessary_files == 0) and all(.changed_paths == ["calc.js"]) and
    all(.unnecessary_paths == []) and all(.retry_count == null) and
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

  CODEX_BASELINE_BENCHMARK_API_KEY=codex-baseline-test-git-metadata-0123456789 PATH="$TEST_ROOT/tests/fixtures:$PATH" \
    "$TEST_ROOT/scripts/benchmark.sh" --live --tasks small-js-bug --repetitions 1 --output "$git_attack_output" >/dev/null
  jq -s -e 'length == 2 and all(.pass) and all(.changed_paths == ["calc.js"]) and all(.unnecessary_paths == [])' \
    "$git_attack_output/results.jsonl" >/dev/null
  if rg -F 'git-host-executed' "$git_attack_output"; then return 1; fi

  set +e
  CODEX_BASELINE_EXPECTED_CODEX_SHA256=0000000000000000000000000000000000000000000000000000000000000000 \
    CODEX_BASELINE_BENCHMARK_API_KEY=synthetic PATH="$TEST_ROOT/tests/fixtures:$PATH" \
    "$TEST_ROOT/scripts/benchmark.sh" --canary --output "$identity_output" >"$TEST_TMP/benchmark-identity.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'does not match the caller-pinned SHA-256' "$TEST_TMP/benchmark-identity.log"
  test ! -e "$identity_output/run.json"

  CODEX_BASELINE_BENCHMARK_API_KEY=synthetic PATH="$TEST_ROOT/tests/fixtures:$PATH" \
    "$TEST_ROOT/scripts/benchmark.sh" --canary --output "$canary_output" >/dev/null
  jq -e '
    .contract == "codex-baseline-benchmark/v1" and .mode == "live-containment-canary" and
    .status == "completed" and .model_invoked and (.verifiers_executed | not) and
    .tool_network_target == "loopback-only" and
    .resource_profile == "user-cgroup-memory2g-swap0-tasks128-cpu200-runtime-bounded-tmpfs"
  ' "$canary_output/run.json" >/dev/null
  jq -e '
    .contract == "codex-baseline-containment-canary/v1" and .pass and
    .environment_secret_absent and .proc_key_carrier_secret_unreadable and
    .tool_network_loopback_denied and .artifact_exact_secret_scan
  ' "$canary_output/canary.json" >/dev/null
  validate_schema "$TEST_ROOT/contracts/benchmark-report.schema.json" "$canary_output/run.json"
  validate_schema "$TEST_ROOT/contracts/benchmark-canary.schema.json" "$canary_output/canary.json"
  test ! -e "$canary_output/INVALID.md"

  set +e
  CODEX_BASELINE_BENCHMARK_API_KEY=codex-baseline-test-leak-0123456789 PATH="$TEST_ROOT/tests/fixtures:$PATH" \
    "$TEST_ROOT/scripts/benchmark.sh" --canary --output "$leak_output" >"$TEST_TMP/canary-leak.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'active credential appeared in an evaluation artifact' "$TEST_TMP/canary-leak.log"
  test -f "$leak_output/INVALID.md"

  set +e
  CODEX_BASELINE_BENCHMARK_API_KEY=codex-baseline-test-workspace-leak-0123456789 PATH="$TEST_ROOT/tests/fixtures:$PATH" \
    "$TEST_ROOT/scripts/benchmark.sh" --canary --output "$workspace_leak_output" >"$TEST_TMP/canary-workspace-leak.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'active credential appeared in an evaluation artifact' "$workspace_leak_output/stderr.log"
  test -f "$workspace_leak_output/INVALID.md"

  set +e
  CODEX_BASELINE_BENCHMARK_API_KEY=codex-baseline-test-home-leak-0123456789 PATH="$TEST_ROOT/tests/fixtures:$PATH" \
    "$TEST_ROOT/scripts/benchmark.sh" --canary --output "$home_leak_output" >"$TEST_TMP/canary-home-leak.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'active credential appeared in an evaluation artifact' "$home_leak_output/stderr.log"
  test -f "$home_leak_output/INVALID.md"

  set +e
  CODEX_BASELINE_BENCHMARK_API_KEY=codex-baseline-test-sentinel-leak-0123456789 PATH="$TEST_ROOT/tests/fixtures:$PATH" \
    "$TEST_ROOT/scripts/benchmark.sh" --canary --output "$sentinel_leak_output" >"$TEST_TMP/canary-sentinel-leak.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'canary secret appeared in an evaluation artifact' "$sentinel_leak_output/stderr.log"
  test -f "$sentinel_leak_output/INVALID.md"

  set +e
  CODEX_BASELINE_BENCHMARK_API_KEY=codex-baseline-test-forged-markers-0123456789 PATH="$TEST_ROOT/tests/fixtures:$PATH" \
    "$TEST_ROOT/scripts/benchmark.sh" --canary --output "$forged_output" >"$TEST_TMP/canary-forged.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'real-model containment canary failed' "$TEST_TMP/canary-forged.log"
  test -f "$forged_output/INVALID.md"

  set +e
  CODEX_BASELINE_BENCHMARK_API_KEY=codex-baseline-test-special-artifact-0123456789 PATH="$TEST_ROOT/tests/fixtures:$PATH" \
    "$TEST_ROOT/scripts/benchmark.sh" --canary --output "$special_output" >"$TEST_TMP/canary-special.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'linked or special evaluation artifact is forbidden' "$special_output/stderr.log"
  test -f "$special_output/INVALID.md"

  set +e
  CODEX_BASELINE_BENCHMARK_API_KEY=codex-baseline-test-network-hit-0123456789 PATH="$TEST_ROOT/tests/fixtures:$PATH" \
    "$TEST_ROOT/scripts/benchmark.sh" --canary --output "$network_hit_output" >"$TEST_TMP/canary-network-hit.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'real-model containment canary failed' "$TEST_TMP/canary-network-hit.log"
  test -f "$network_hit_output/INVALID.md"

  jq -e '
    (.pass | not) and .environment_secret_absent and .proc_key_carrier_secret_unreadable and
    (.tool_network_loopback_denied | not) and .artifact_exact_secret_scan
  ' "$network_hit_output/canary.json" >/dev/null

  set +e
  CODEX_BASELINE_BENCHMARK_API_KEY=codex-baseline-test-proc-readable-0123456789 PATH="$TEST_ROOT/tests/fixtures:$PATH" \
    "$TEST_ROOT/scripts/benchmark.sh" --canary --output "$proc_output" >"$TEST_TMP/canary-proc.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  jq -e '
    (.pass | not) and .environment_secret_absent and (.proc_key_carrier_secret_unreadable | not) and
    .tool_network_loopback_denied and .artifact_exact_secret_scan
  ' "$proc_output/canary.json" >/dev/null
  test -f "$proc_output/INVALID.md"

  set +e
  CODEX_BASELINE_TEST_CANARY_KILL_LISTENER=1 CODEX_BASELINE_BENCHMARK_API_KEY=synthetic PATH="$TEST_ROOT/tests/fixtures:$PATH" \
    "$TEST_ROOT/scripts/benchmark.sh" --canary --output "$listener_output" >"$TEST_TMP/canary-listener.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  jq -e '
    (.pass | not) and .environment_secret_absent and .proc_key_carrier_secret_unreadable and
    (.tool_network_loopback_denied | not) and .artifact_exact_secret_scan
  ' "$listener_output/canary.json" >/dev/null
  test -f "$listener_output/INVALID.md"

  set +e
  CODEX_BASELINE_BENCHMARK_API_KEY=codex-baseline-test-filename-leak-0123456789 PATH="$TEST_ROOT/tests/fixtures:$PATH" \
    "$TEST_ROOT/scripts/benchmark.sh" --canary --output "$filename_output" >"$TEST_TMP/canary-filename.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  test -f "$filename_output/INVALID.md"
  if rg -F 'codex-baseline-test-filename-leak-0123456789' "$filename_output" "$TEST_TMP/canary-filename.log"; then return 1; fi

  set +e
  CODEX_BASELINE_BENCHMARK_API_KEY=codex-baseline-test-dirname-leak-0123456789 PATH="$TEST_ROOT/tests/fixtures:$PATH" \
    "$TEST_ROOT/scripts/benchmark.sh" --canary --output "$dirname_output" >"$TEST_TMP/canary-dirname.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  test -f "$dirname_output/INVALID.md"
  if rg -F 'codex-baseline-test-dirname-leak-0123456789' "$dirname_output" "$TEST_TMP/canary-dirname.log"; then return 1; fi

  set +e
  CODEX_BASELINE_BENCHMARK_API_KEY=codex-baseline-test-many-artifacts-0123456789 PATH="$TEST_ROOT/tests/fixtures:$PATH" \
    "$TEST_ROOT/scripts/benchmark.sh" --canary --output "$many_output" >"$TEST_TMP/canary-many.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'evaluation artifact entry limit exceeded' "$many_output/stderr.log"
  test -f "$many_output/INVALID.md"

  set +e
  CODEX_BASELINE_TEST_BENCH_INVALIDATE_AFTER_LAST=1 CODEX_BASELINE_BENCHMARK_API_KEY=synthetic PATH="$TEST_ROOT/tests/fixtures:$PATH" \
    "$TEST_ROOT/scripts/benchmark.sh" --live --tasks small-js-bug --repetitions 1 --output "$invalidated_output" >"$TEST_TMP/benchmark-invalidated.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'source changed after the final benchmark arm' "$TEST_TMP/benchmark-invalidated.log"
  jq -e '.status == "running"' "$invalidated_output/run.json" >/dev/null
  test -f "$invalidated_output/INVALID.md"

  set +e
  CODEX_BASELINE_BENCHMARK_API_KEY=codex-baseline-test-malformed-jsonl-0123456789 PATH="$TEST_ROOT/tests/fixtures:$PATH" \
    "$TEST_ROOT/scripts/benchmark.sh" --live --tasks small-js-bug --repetitions 1 --output "$malformed_output" >"$TEST_TMP/benchmark-malformed.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'evaluation JSONL is malformed, truncated, or incomplete' "$TEST_TMP/benchmark-malformed.log"
  test -f "$malformed_output/INVALID.md"

  set +e
  CODEX_BASELINE_BENCHMARK_API_KEY=codex-baseline-test-benchmark-fail-0123456789 PATH="$TEST_ROOT/tests/fixtures:$PATH" \
    "$TEST_ROOT/scripts/benchmark.sh" --live --tasks small-js-bug --repetitions 1 --output "$failed_output" >"$TEST_TMP/benchmark-failed.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'paired benchmark completed with 2 failing arm(s)' "$TEST_TMP/benchmark-failed.log"
  jq -e '.status == "completed"' "$failed_output/run.json" >/dev/null
  jq -s -e 'length == 2 and all(.pass == false)' "$failed_output/results.jsonl" >/dev/null
  test ! -e "$failed_output/INVALID.md"

  installed_root=$(new_home installed-benchmark)
  baseline "$installed_root" install >/dev/null
  HOME="$installed_root/home" CODEX_HOME="$installed_root/home/.codex" AGENTS_HOME="$installed_root/home/.agents" \
    BASH_ENV="$startup_env" CODEX_BASELINE_BENCHMARK_API_KEY=synthetic PATH="$hijack_root:$TEST_ROOT/tests/fixtures:$PATH" \
    "$installed_root/home/.local/bin/codex-baseline" benchmark --canary >"$installed_root/wrapper-canary.log"
  test ! -e "$startup_marker"
  test ! -e "$hijack_root/invoked"
  test ! -e "$dispatcher_marker"
  installed_result=$(sed -n 's/^containment canary passed: //p' "$installed_root/wrapper-canary.log")
  [[ $installed_result == "$installed_root/home/.local/state/codex-baseline/behavior-results/"* ]]
  test -f "$installed_result/canary.json"
  baseline "$installed_root" doctor >/dev/null
  installed_bad="$installed_root/home/.codex/codex-baseline/runtime/behavior-results/forbidden"
  set +e
  HOME="$installed_root/home" CODEX_HOME="$installed_root/home/.codex" AGENTS_HOME="$installed_root/home/.agents" \
    CODEX_BASELINE_BENCHMARK_API_KEY=synthetic PATH="$TEST_ROOT/tests/fixtures:$PATH" \
    "$installed_root/home/.local/bin/codex-baseline" benchmark --canary --output "$installed_bad" >"$installed_root/wrapper-bad.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'outside the managed runtime tree' "$installed_root/wrapper-bad.log"
  test ! -e "$installed_bad"
  baseline "$installed_root" doctor >/dev/null
  baseline "$installed_root" uninstall >"$installed_root/uninstall.log" 2>"$installed_root/uninstall.stderr"
  test ! -s "$installed_root/uninstall.stderr"
  pass 'benchmark contracts plus deterministic paired and containment-canary mechanics are valid'
}

test_routing_contract() {
  local output="$TEST_TMP/routing-live" invalid_output="$TEST_TMP/routing-invalid"
  local invalid_last_output="$TEST_TMP/routing-invalid-last" newline_output="$TEST_TMP/routing-newline-key"
  local malformed_output="$TEST_TMP/routing-malformed" command_output="$TEST_TMP/routing-command"
  local missing_output="$TEST_TMP/routing-missing" linked_output="$TEST_TMP/routing-linked"
  local home_leak_output="$TEST_TMP/routing-home-leak" special_output="$TEST_TMP/routing-special" status
  local behavior_id behavior_verifier behavior_fixture before_hash after_hash inspector_output
  local inspector_deep="$TEST_TMP/behavior-inspector-deep" inspector_special="$TEST_TMP/behavior-inspector-special" cursor
  local startup_env="$TEST_TMP/routing-bash-env" startup_marker="$TEST_TMP/routing-startup-key-seen"
  local CODEX_BASELINE_TESTING=1
  local CODEX_BASELINE_EXPECTED_CODEX_SHA256
  CODEX_BASELINE_EXPECTED_CODEX_SHA256=$(sha256sum -- "$TEST_ROOT/tests/fixtures/codex" | awk '{print $1}')
  export CODEX_BASELINE_TESTING CODEX_BASELINE_EXPECTED_CODEX_SHA256
  while IFS= read -r behavior_id; do
    behavior_fixture="$TEST_ROOT/tests/behavior/fixtures/$behavior_id"
    test -d "$behavior_fixture"
    behavior_verifier="$TEST_ROOT/tests/behavior/verifiers/$behavior_id.sh"
    test -x "$behavior_verifier"
    if "$behavior_verifier" "$TEST_ROOT/tests/behavior/starter.json" >/dev/null 2>&1; then return 1; fi
    before_hash=$(cb_tree_hash "$behavior_fixture")
    inspector_output="$TEST_TMP/behavior-inspector-$behavior_id.txt"
    (cd "$behavior_fixture" && "$TEST_ROOT/tests/behavior/inspect.sh" .) >"$inspector_output"
    grep -qx 'behavior-evidence-complete' "$inspector_output"
    after_hash=$(cb_tree_hash "$behavior_fixture")
    [[ $before_hash == "$after_hash" ]]
  done < <(jq -r '.cases[].id' "$TEST_ROOT/tests/behavior/cases.json")

  cursor="$inspector_deep"
  mkdir -- "$cursor"
  for depth in {1..17}; do cursor="$cursor/d$depth"; mkdir -- "$cursor"; done
  printf 'too deep\n' >"$cursor/file.txt"
  if (cd "$inspector_deep" && "$TEST_ROOT/tests/behavior/inspect.sh" . >/dev/null 2>&1); then return 1; fi
  mkdir -- "$inspector_special"
  printf 'ordinary\n' >"$inspector_special/file.txt"
  ln -s /etc/passwd "$inspector_special/link"
  if (cd "$inspector_special" && "$TEST_ROOT/tests/behavior/inspect.sh" . >/dev/null 2>&1); then return 1; fi

  set +e
  CODEX_BASELINE_BENCHMARK_API_KEY=$'invalid\rkey' PATH="$TEST_ROOT/tests/fixtures:$PATH" \
    "$TEST_ROOT/scripts/routing-probe.sh" --repetitions 1 --output "$newline_output" >"$TEST_TMP/routing-newline.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'invalid line break' "$TEST_TMP/routing-newline.log"
  test ! -e "$newline_output"

  printf 'if [[ -n ${CODEX_BASELINE_BENCHMARK_API_KEY-} ]]; then : >%q; fi\n' "$startup_marker" >"$startup_env"
  BASH_ENV="$startup_env" CODEX_BASELINE_BENCHMARK_API_KEY=synthetic PATH="$TEST_ROOT/tests/fixtures:$PATH" \
    "$TEST_ROOT/scripts/routing-probe.sh" --repetitions 1 --output "$output" >/dev/null
  test ! -e "$startup_marker"
  jq -e '
    .contract == "codex-baseline-routing-run/v1" and .mode == "live-routing-and-behavior" and
    .status == "completed" and .model_invoked and .host_checks_executed and
    .isolation == "os-sandboxed-local-cgroup" and .auth == "dedicated-api-key-stdin-pipe" and .repetitions == 1 and
    .resource_profile == "user-cgroup-memory2g-swap0-tasks128-cpu200-runtime-bounded-tmpfs" and
    .routing_cases == 6 and .behavior_cases == 4 and
    (.source_hash | test("^[0-9a-f]{64}$")) and
    (.codex_binary_hash | test("^[0-9a-f]{64}$")) and .codex_identity == "caller-pinned-sha256" and
    (.node_binary_hash | test("^[0-9a-f]{64}$"))
  ' "$output/run.json" >/dev/null
  validate_schema "$TEST_ROOT/contracts/routing-run.schema.json" "$output/run.json"
  validate_schema "$TEST_ROOT/contracts/routing-summary.schema.json" "$output/summary.json"
  validate_jsonl_schema "$TEST_ROOT/contracts/routing-result.schema.json" "$output/results.jsonl"
  validate_jsonl_schema "$TEST_ROOT/contracts/behavior-result.schema.json" "$output/behavior-results.jsonl"
  jq -e '
    .contract == "codex-baseline-routing-summary/v1" and .repetitions == 1 and
    .routing.runs == 6 and .routing.passes == 6 and all(.routing.by_case[]; .runs == 1 and .passes == 1) and
    .behavior.runs == 4 and .behavior.passes == 4 and all(.behavior.by_case[]; .runs == 1 and .passes == 1)
  ' "$output/summary.json" >/dev/null
  jq -s -e --slurpfile run "$output/run.json" --slurpfile summary "$output/summary.json" '
    length == 6 and all(.pass) and all(.process_exit == 0) and all(.commands == 0) and all(.file_changes == 0) and
    all(.contract == "codex-baseline-routing-result/v1") and
    (map(.source_hash) | unique) == [$run[0].source_hash] and
    $summary[0].source_hash == $run[0].source_hash
  ' "$output/results.jsonl" >/dev/null
  jq -s -e --slurpfile run "$output/run.json" --slurpfile summary "$output/summary.json" '
    length == 4 and all(.pass) and all(.process_exit == 0) and all(.verifier_exit == 0) and
    all(.contract == "codex-baseline-behavior-result/v1") and all(.commands == 1) and all(.file_changes == 0) and
    (map(.source_hash) | unique) == [$run[0].source_hash] and
    $summary[0].source_hash == $run[0].source_hash
  ' "$output/behavior-results.jsonl" >/dev/null
  test ! -e "$output/INVALID.md"

  set +e
  CODEX_BASELINE_TESTING=1 CODEX_BASELINE_TEST_ROUTING_INVALIDATE_AFTER_FIRST=1 \
    CODEX_BASELINE_BENCHMARK_API_KEY=synthetic PATH="$TEST_ROOT/tests/fixtures:$PATH" \
    "$TEST_ROOT/scripts/routing-probe.sh" --repetitions 1 --output "$invalid_output" >"$TEST_TMP/routing-invalid.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'source changed during routing probe' "$TEST_TMP/routing-invalid.log"
  test -f "$invalid_output/INVALID.md"
  jq -e '.status == "running"' "$invalid_output/run.json" >/dev/null

  set +e
  CODEX_BASELINE_TEST_ROUTING_INVALIDATE_AFTER_LAST=1 \
    CODEX_BASELINE_BENCHMARK_API_KEY=synthetic PATH="$TEST_ROOT/tests/fixtures:$PATH" \
    "$TEST_ROOT/scripts/routing-probe.sh" --repetitions 1 --output "$invalid_last_output" >"$TEST_TMP/routing-invalid-last.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'source changed during routing probe' "$TEST_TMP/routing-invalid-last.log"
  test -f "$invalid_last_output/INVALID.md"
  jq -e '.status == "running"' "$invalid_last_output/run.json" >/dev/null

  set +e
  CODEX_BASELINE_BENCHMARK_API_KEY=codex-baseline-test-routing-malformed-0123456789 PATH="$TEST_ROOT/tests/fixtures:$PATH" \
    "$TEST_ROOT/scripts/routing-probe.sh" --repetitions 1 --output "$malformed_output" >"$TEST_TMP/routing-malformed.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'routing JSONL is malformed, truncated, or incomplete' "$TEST_TMP/routing-malformed.log"
  test -f "$malformed_output/INVALID.md"

  set +e
  CODEX_BASELINE_TEST_ROUTING_INVALIDATE_AFTER_FIRST=1 \
    CODEX_BASELINE_BENCHMARK_API_KEY=codex-baseline-test-routing-command-0123456789 PATH="$TEST_ROOT/tests/fixtures:$PATH" \
    "$TEST_ROOT/scripts/routing-probe.sh" --repetitions 1 --output "$command_output" >"$TEST_TMP/routing-command.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  jq -e '(.pass | not) and .commands == 1 and .file_changes == 0' "$command_output/results.jsonl" >/dev/null
  test -f "$command_output/INVALID.md"

  set +e
  CODEX_BASELINE_BENCHMARK_API_KEY=codex-baseline-test-routing-missing-0123456789 PATH="$TEST_ROOT/tests/fixtures:$PATH" \
    "$TEST_ROOT/scripts/routing-probe.sh" --repetitions 1 --output "$missing_output" >"$TEST_TMP/routing-missing.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'missing routing last-message artifact' "$TEST_TMP/routing-missing.log"
  test -f "$missing_output/INVALID.md"

  set +e
  CODEX_BASELINE_BENCHMARK_API_KEY=codex-baseline-test-routing-linked-0123456789 PATH="$TEST_ROOT/tests/fixtures:$PATH" \
    "$TEST_ROOT/scripts/routing-probe.sh" --repetitions 1 --output "$linked_output" >"$TEST_TMP/routing-linked.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  test -f "$linked_output/INVALID.md"
  test -f "$linked_output/routing-lean-typo-r1.json"
  test ! -L "$linked_output/routing-lean-typo-r1.json"
  test ! -s "$linked_output/routing-lean-typo-r1.json"

  set +e
  CODEX_BASELINE_BENCHMARK_API_KEY=codex-baseline-test-routing-home-leak-0123456789 PATH="$TEST_ROOT/tests/fixtures:$PATH" \
    "$TEST_ROOT/scripts/routing-probe.sh" --repetitions 1 --output "$home_leak_output" >"$TEST_TMP/routing-home-leak.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'active credential appeared in an evaluation artifact' "$home_leak_output/routing-lean-typo-r1.stderr"
  test -f "$home_leak_output/INVALID.md"

  set +e
  CODEX_BASELINE_BENCHMARK_API_KEY=codex-baseline-test-routing-special-0123456789 PATH="$TEST_ROOT/tests/fixtures:$PATH" \
    "$TEST_ROOT/scripts/routing-probe.sh" --repetitions 1 --output "$special_output" >"$TEST_TMP/routing-special.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'linked or special evaluation artifact is forbidden' "$special_output/routing-lean-typo-r1.stderr"
  test -f "$special_output/INVALID.md"
  pass 'routing fixtures, frozen-source receipts, and fail-closed artifact mechanics are valid'
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
