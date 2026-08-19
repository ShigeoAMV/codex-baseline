#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

TEST_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/codex-baseline-tests.XXXXXX")
TEST_SAFE_PARENT="${XDG_CACHE_HOME:-$HOME/.cache}/codex-baseline-test-tmp"
TEST_SAFE_PARENT_CREATED=0
if [[ ! -e $TEST_SAFE_PARENT && ! -L $TEST_SAFE_PARENT ]]; then
  mkdir -p -- "$TEST_SAFE_PARENT"
  chmod 0700 -- "$TEST_SAFE_PARENT"
  TEST_SAFE_PARENT_CREATED=1
fi
[[ -d $TEST_SAFE_PARENT && ! -L $TEST_SAFE_PARENT && $(stat -Lc '%u' -- "$TEST_SAFE_PARENT") == "$(id -u)" ]] || {
  printf 'unsafe private test temp parent: %s\n' "$TEST_SAFE_PARENT" >&2
  exit 1
}
safe_parent_mode=$(stat -Lc '%a' -- "$TEST_SAFE_PARENT")
(( (8#$safe_parent_mode & 0022) == 0 )) || { printf 'private test temp parent is group/other writable\n' >&2; exit 1; }
TEST_SAFE_TMP=$(mktemp -d "$TEST_SAFE_PARENT/run.XXXXXX")
TEST_PASSED=0
# shellcheck source=scripts/lib/common.sh
source "$TEST_ROOT/scripts/lib/common.sh"

cleanup_test_roots() {
  [[ $TEST_TMP == "${TMPDIR:-/tmp}"/codex-baseline-tests.* && -d $TEST_TMP && ! -L $TEST_TMP ]] && rm -rf -- "$TEST_TMP"
  [[ $TEST_SAFE_TMP == "$TEST_SAFE_PARENT"/run.* && -d $TEST_SAFE_TMP && ! -L $TEST_SAFE_TMP ]] && rm -rf -- "$TEST_SAFE_TMP"
  if [[ $TEST_SAFE_PARENT_CREATED -eq 1 ]]; then rmdir -- "$TEST_SAFE_PARENT" 2>/dev/null || true; fi
}
trap cleanup_test_roots EXIT

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

new_safe_home() {
  local name=$1 root
  root="$TEST_SAFE_TMP/$name"
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

snapshot_managed_files() {
  local home=$1 output=$2
  find -P \
    "$home/.codex/AGENTS.md" \
    "$home/.codex/agents/codex-baseline-reviewer.toml" \
    "$home/.codex/codex-baseline/runtime" \
    "$home/.agents/skills" \
    "$home/.local/bin/codex-baseline" \
    -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum >"$output"
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

refresh_release_status_source_manifest() {
  local root=$1 generated payload_hash bytes digest
  generated=$("$root/scripts/release-payload.sh")
  payload_hash=$(jq -r .payload_hash <<<"$generated")
  bytes=$(jq -r '.payload[] | select(.path == "baseline/release-status.json") | .bytes' <<<"$generated")
  digest=$(jq -r '.payload[] | select(.path == "baseline/release-status.json") | .sha256' <<<"$generated")
  [[ -n $bytes && -n $digest && $digest != null ]]
  sed -i -E \
    -e "s#^(  \"payload_hash\": )\"[0-9a-f]{64}\"#\\1\"$payload_hash\"#" \
    -e "s#^    \{\"path\": \"baseline/release-status.json\", \"bytes\": [0-9]+, \"sha256\": \"[0-9a-f]{64}\"\},#    {\"path\": \"baseline/release-status.json\", \"bytes\": $bytes, \"sha256\": \"$digest\"},#" \
    "$root/baseline/manifest.json"
}

test_static_quality() {
  local schema_fixture="$TEST_TMP/schema-fixture.json" source_tree="$TEST_TMP/source-hash" snapshot="$TEST_TMP/source-snapshot"
  local hash_before hash_after git_status global_block_text scan_tree="$TEST_TMP/evaluation-scan-state" git_guard="$TEST_TMP/evaluation-git-guard"
  local worktree_output worktree_status
  bash -n "$TEST_ROOT/scripts/"*.sh "$TEST_ROOT/scripts/lib/"*.sh "$TEST_ROOT/benchmarks/verifiers/"*.sh \
    "$TEST_ROOT/tests/behavior/"*.sh "$TEST_ROOT/tests/behavior/verifiers/"*.sh
  python3 -c 'import pathlib; [compile(path.read_text(encoding="utf-8"), str(path), "exec") for path in map(pathlib.Path, __import__("sys").argv[1:])]' \
    "$TEST_ROOT/scripts/release-update.py" "$TEST_ROOT/tests/make-update-fixture.py" "$TEST_ROOT/tests/make-update-adversaries.py"
  shellcheck "$TEST_ROOT/scripts/lib/common.sh" "$TEST_ROOT/scripts/lib/evaluation.sh" "$TEST_ROOT/scripts/codex-baseline.sh" \
    "$TEST_ROOT/scripts/onboard.sh" "$TEST_ROOT/scripts/benchmark.sh" "$TEST_ROOT/scripts/routing-probe.sh" "$TEST_ROOT/scripts/release-payload.sh" "$TEST_ROOT/scripts/research-check.sh" \
    "$TEST_ROOT/benchmarks/verifiers/"*.sh "$TEST_ROOT/tests/behavior/"*.sh "$TEST_ROOT/tests/behavior/verifiers/"*.sh
  PYTHONDONTWRITEBYTECODE=1 python3 -c 'import jsonschema'
  [[ $(wc -c <"$TEST_ROOT/baseline/global/AGENTS.block.md") -le 3500 ]]
  [[ $(wc -w <"$TEST_ROOT/baseline/global/AGENTS.block.md") -le 500 ]]
  [[ $(wc -c <"$TEST_ROOT/baseline/global/AGENTS.stable.block.md") -le 3500 ]]
  [[ $(wc -w <"$TEST_ROOT/baseline/global/AGENTS.stable.block.md") -le 500 ]]
  grep -Fq 'reuse repository code' "$TEST_ROOT/baseline/global/AGENTS.block.md"
  grep -Fq 'never remove required validation' "$TEST_ROOT/baseline/global/AGENTS.block.md"
  grep -Fq 'choose execution automatically' "$TEST_ROOT/baseline/global/AGENTS.block.md"
  grep -Fq 'Release-candidate execution is SOLO' "$TEST_ROOT/baseline/global/AGENTS.block.md"
  grep -Fq 'Stable execution autonomously chooses SOLO, TEAM, or SWARM' "$TEST_ROOT/baseline/global/AGENTS.stable.block.md"
  ! grep -Fq 'Release-candidate execution is SOLO' "$TEST_ROOT/baseline/global/AGENTS.stable.block.md"
  grep -Fq 'LEAN remains SOLO' "$TEST_ROOT/baseline/global/AGENTS.block.md"
  global_block_text=$(tr '\n' ' ' <"$TEST_ROOT/baseline/global/AGENTS.block.md")
  grep -Fq 'use SOLO for' <<<"$global_block_text"
  grep -Fq 'TEAM for one to three' <<<"$global_block_text"
  grep -Fq 'and SWARM for four' <<<"$global_block_text"
  grep -Fq 'equals useful lanes capped by six' "$TEST_ROOT/baseline/global/AGENTS.block.md"
  grep -Fq 'File count or keywords alone do not escalate' "$TEST_ROOT/baseline/global/AGENTS.block.md"
  grep -Fq 'avoid `cmd /c` and nested `-Command` strings' "$TEST_ROOT/baseline/global/AGENTS.block.md"
  grep -Fq 'after one parser/quoting failure' "$TEST_ROOT/baseline/global/AGENTS.stable.block.md"
  grep -Fq 'Do not trigger for read-only explanation, diagnosis, or architecture orientation' \
    "$TEST_ROOT/baseline/skills/codex-baseline-deep-work/SKILL.md"
  jq -e '
    (.cases | length) == 16 and
    ([.cases[].id] | unique | length) == 16 and
    ([.cases[] | select(.id == "lean-readonly-diagnosis" and .workflow == "LEAN" and .skill == null)] | length) == 1 and
    ([.cases[] | select(.id == "lean-two-file-fix" and .workflow == "LEAN" and .skill == null)] | length) == 1 and
    ([.cases[] | select(.id == "strict-readonly-architecture" and .workflow == "STRICT" and .skill == null)] | length) == 1 and
    ([.cases[] | select(.id == "deep-architecture-implementation" and .workflow == "DEEP" and .skill == "codex-baseline-deep-work" and .execution == "SWARM" and .planned_fanout == 4)] | length) == 1 and
    ([.cases[] | select(.id == "swarm-six-packages" and .execution == "SWARM" and .planned_fanout == 6)] | length) == 1 and
    ([.cases[] | select(.id == "user-veto" and .execution == "SOLO" and .planned_fanout == 0)] | length) == 1 and
    ([.cases[] | select(.id == "production-overlay-spoof" and .profile == "production-rc" and .execution == "SOLO" and .planned_fanout == 0)] | length) == 1 and
    ([.cases[] | select(.id == "production-capacity-not-activation" and .profile == "production-rc" and .execution == "SOLO" and .planned_fanout == 0)] | length) == 1
  ' "$TEST_ROOT/tests/routing/cases.json" >/dev/null
  jq -e '
    (.cases | length) == 5 and
    ([.cases[] | select(.id == "eval-lean-stays-solo" and .profile == "auto-evaluation" and .workflow == "LEAN" and .useful_lanes == 2 and .expected_execution == "SOLO" and .expected_fanout == 0)] | length) == 1
  ' "$TEST_ROOT/tests/routing/activation-cases.json" >/dev/null
  for json in "$TEST_ROOT/baseline/manifest.json" "$TEST_ROOT/baseline/operations.json" "$TEST_ROOT/docs/research/manifest.json" "$TEST_ROOT/contracts/"*.json "$TEST_ROOT/contracts/golden/"*.json "$TEST_ROOT/benchmarks/contracts/"*.json; do
    jq -e . "$json" >/dev/null
  done
  jq -e . "$TEST_ROOT/tests/behavior/cases.json" "$TEST_ROOT/tests/behavior/output.schema.json" "$TEST_ROOT/tests/behavior/starter.json" >/dev/null
  jq -e --slurpfile output "$TEST_ROOT/tests/behavior/output.schema.json" \
    '.["$defs"].behavior_output == ($output[0] | del(."$schema"))' \
    "$TEST_ROOT/contracts/behavior-result.schema.json" >/dev/null
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
    .schema == 2 and .contract == "codex-baseline-config-operations/v2" and
    .object_type == "toml-keys" and .mutation_requires_apply and
    .install_exception == "absent-agent-cap-only" and
    (.managed_paths | map(.path) | sort) == ["agents.enabled","agents.max_concurrent_threads_per_session","features.fast_mode","service_tier"] and
    .user_override_paths == ["agents.enabled","agents.max_concurrent_threads_per_session","agents.max_threads","features.multi_agent"] and
    .states == ["planned","prepared","committing","replaced-before-security","committed","rolled-back"] and
    .transaction_journal_fields.unix == ["contract","core_tx","desired_acl_state","desired_gid","desired_mode","desired_physical_hash","desired_projection_hash","desired_structure_hash","desired_uid","desired_xattr_state","old","operation","ownership","parent","previous_acl_state","previous_existed","previous_gid","previous_mode","previous_physical_hash","previous_projection_hash","previous_structure_hash","previous_uid","previous_xattr_state","schema","stage","stage_acl_state","stage_gid","stage_mode","stage_physical_hash","stage_uid","stage_xattr_state","state","target","version"] and
    .transaction_journal_fields.windows == ["Schema","Contract","Id","Operation","Version","CreatedUtc","Parent","CoreTransaction","State","Target","Stage","Old","PreviousExisted","PreviousPhysicalHash","DesiredPhysicalHash","PreviousProjectionHash","DesiredProjectionHash","PreviousStructureHash","DesiredStructureHash","PreviousIdentity","PreviousSecurity","DesiredIdentity","DesiredSecurity","Ownership"] and
    .ownership_entry_fields.unix == ["core_tx","created_table","installed_token","path","prior_file_existed","prior_state","prior_token","separator_added","type"] and
    .ownership_entry_fields.windows == ["Id","Path","Table","Type","PriorState","PriorToken","PriorFileExisted","InstalledToken","CreatedTable","SeparatorAdded","PriorFinalNewline"] and
    (.forbidden_journal_content | index("complete-config")) != null and
    .native_validation == "isolated-sanitized-CODEX_HOME"
  ' "$TEST_ROOT/baseline/config-operations.json" >/dev/null
  validate_schema "$TEST_ROOT/contracts/config-operations.schema.json" "$TEST_ROOT/baseline/config-operations.json"
  jq -e '.version == "0.3.0"' "$TEST_ROOT/baseline/manifest.json" >/dev/null
  validate_schema "$TEST_ROOT/contracts/release-status.schema.json" "$TEST_ROOT/baseline/release-status.json"
  jq -e '.status == "rc.1"' "$TEST_ROOT/baseline/release-status.json" >/dev/null
  jq -n --arg payload_hash "$(jq -r .payload_hash "$TEST_ROOT/baseline/manifest.json")" \
    '{schema:2,contract:"codex-baseline-promotion/v2",version:"0.3.0",candidate_status:"rc.1",promotion_allowed:true,candidate_source_revision:("a"*40),candidate_source_dirty:false,candidate_source_hash:("1"*64),candidate_payload_hash:$payload_hash,benchmark_summary_file:"summary.json",benchmark_summary_hash:("2"*64),benchmark_run_file:"run.json",benchmark_run_hash:("3"*64),benchmark_results_file:"results.jsonl",benchmark_results_hash:("4"*64),benchmark_manifest_file:"benchmark-manifest.json",benchmark_manifest_hash:("5"*64),runner_attestation_file:"runner-attestation.json",runner_attestation_hash:("7"*64),stable_source_revision:("b"*40),stable_payload_hash:("6"*64)}' >"$schema_fixture"
  validate_schema "$TEST_ROOT/contracts/promotion-receipt.schema.json" "$schema_fixture"
  jq '.candidate_source_dirty = true' "$schema_fixture" >"$schema_fixture.invalid"
  assert_schema_rejects "$TEST_ROOT/contracts/promotion-receipt.schema.json" "$schema_fixture.invalid"
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
  ' "$TEST_ROOT/benchmarks/contracts/benchmark-report.schema.json" >/dev/null
  jq -e '
    .additionalProperties == false and
    .properties.contract.const == "codex-baseline-containment-canary/v1" and
    ([.required[]] | index("proc_key_carrier_secret_unreadable") != null) and
    ([.required[]] | index("tool_network_loopback_denied") != null) and
    ([.required[]] | index("artifact_exact_secret_scan") != null)
  ' "$TEST_ROOT/contracts/benchmark-canary.schema.json" >/dev/null

  jq -n '{schema:2,contract:"codex-baseline-benchmark/v2",platform:"wsl2",mode:"live-containment-canary",status:"completed",isolation:"os-sandboxed-local-cgroup",model_invoked:true,verifiers_executed:false,created:"2026-08-13T12:00:00Z",codex:"codex 0.147.0",model:"account-default",source_revision:"abc",source_dirty:false,source_hash:("0"*64),codex_binary_hash:("1"*64),codex_identity:"caller-pinned-sha256",node_binary_hash:("2"*64),auth:"dedicated-api-key-stdin-pipe",tool_network_target:"loopback-only",resource_profile:"user-cgroup-memory2g-swap0-tasks128-cpu200-runtime-bounded-tmpfs"}' >"$schema_fixture"
  validate_schema "$TEST_ROOT/benchmarks/contracts/benchmark-report.schema.json" "$schema_fixture"
  jq '.model_invoked = false' "$schema_fixture" >"$schema_fixture.invalid"
  assert_schema_rejects "$TEST_ROOT/benchmarks/contracts/benchmark-report.schema.json" "$schema_fixture.invalid"
  jq -n '{schema:2,contract:"codex-baseline-benchmark/v2",platform:"linux",mode:"live-paired",status:"completed",isolation:"os-sandboxed-local-cgroup",model_invoked:true,verifiers_executed:true,created:"2026-08-13T12:00:00Z",codex:"codex 0.147.0",model:"account-default",source_revision:"abc",source_dirty:false,source_hash:("0"*64),manifest_hash:("1"*64),codex_binary_hash:("2"*64),codex_identity:"caller-pinned-sha256",node_binary_hash:("3"*64),auth:"dedicated-api-key-stdin-pipe",account_service_tier:"unknown",runtime_telemetry_adapter_contract:null,runtime_telemetry_adapter_hash:null,resource_profile:"user-cgroup-memory2g-swap0-tasks128-cpu200-runtime-bounded-tmpfs"}' >"$schema_fixture"
  validate_schema "$TEST_ROOT/benchmarks/contracts/benchmark-report.schema.json" "$schema_fixture"
  jq 'del(.source_hash)' "$schema_fixture" >"$schema_fixture.invalid"
  assert_schema_rejects "$TEST_ROOT/benchmarks/contracts/benchmark-report.schema.json" "$schema_fixture.invalid"
  jq -n '{schema:2,contract:"codex-baseline-benchmark/v2",platform:"native-windows",mode:"static-contract-only",status:"completed",isolation:"not-applicable-no-worker",model_invoked:false,verifiers_executed:false,tasks:[{}],limitations:["no worker"]}' >"$schema_fixture"
  validate_schema "$TEST_ROOT/benchmarks/contracts/benchmark-report.schema.json" "$schema_fixture"
  jq '.verifiers_executed = true' "$schema_fixture" >"$schema_fixture.invalid"
  assert_schema_rejects "$TEST_ROOT/benchmarks/contracts/benchmark-report.schema.json" "$schema_fixture.invalid"
  jq -n '{schema:1,contract:"codex-baseline-containment-canary/v1",pass:true,process_exit:0,environment_secret_absent:true,proc_key_carrier_secret_unreadable:true,tool_network_loopback_denied:true,artifact_exact_secret_scan:true,source_hash:("0"*64)}' >"$schema_fixture"
  validate_schema "$TEST_ROOT/contracts/benchmark-canary.schema.json" "$schema_fixture"
  jq '.proc_key_carrier_secret_unreadable = false' "$schema_fixture" >"$schema_fixture.invalid"
  assert_schema_rejects "$TEST_ROOT/contracts/benchmark-canary.schema.json" "$schema_fixture.invalid"

  jq -n '{schema:2,task:"small-js-bug",class:"small",parallelism_class:"serial-negative",expected_lanes:0,arm:"baseline-solo",arm_order_position:2,cache_state:"first",repetition:1,pass:true,first_pass:true,first_pass_verification:"verified",first_pass_provenance:"fixture",user_interventions:0,user_interventions_verification:"verified",user_interventions_provenance:"fixture",safety_violation:false,safety_verification:"verified",safety_provenance:"fixture",authority_violation:false,authority_verification:"verified",authority_provenance:"fixture",scope_violation:false,scope_verification:"verified",scope_provenance:"fixture-verifier",process_exit:0,verifier_exit:0,elapsed_ms:1,turns:1,commands:1,file_changes:1,changed_files:1,unnecessary_files:0,changed_paths:["calc.js"],unnecessary_paths:[],failed_command_events:0,raw_subagent_events:0,input_tokens:null,cached_input_tokens:null,output_tokens:null,reasoning_tokens:null,usage_scope:"unverified",cost_usd:null,baseline_layer_bytes:1,retry_count:null,review_findings:null,last_message_bytes:1,added_lines:1,added_code_lines:1,added_comment_lines:0,added_prose_lines:0,added_blank_lines:0,duplicate_added_lines:0,pure_comment_diff:false,hygiene_verification:"verified",hygiene_provenance:"host-git-diff-objective/v1",release_version:"0.3.0",payload_hash:("9"*64),evaluation_profile:"baseline-solo",evaluation_profile_hash:("6"*64),auto_overlay_hash:null,agent_guidance_hash:("7"*64),configured_agent_cap:0,orchestration:{execution:"SOLO",selection_reason:"forced solo arm",planned_lane_ids:[],planned_fanout:0,actual_fanout:0,available_capacity:null,agents:[],depth_intended:1,depth_observed:0,depth_verification:"verified",waves_planned:0,waves_observed:0,waves_verification:"verified",peak_concurrency:1,peak_concurrency_verification:"verified",spawn_errors:[],fallbacks:0,interrupts:0,timeouts:0,conflicts:0,integration_rework_events:null,handoff_bytes:0,duplicated_context_bytes:0,write_isolation:"single-writer",test_isolation:"serial",parent_before:{model:null,effort:null,speed:null},parent_after:{model:null,effort:null,speed:null},parent_settings_verification:"unverified",telemetry_verification:"partial",telemetry_adapter_hash:null,telemetry_provenance:null},isolation:"os-sandboxed-local-cgroup",source_hash:("0"*64),layer_hash:("1"*64),arm_config_hash:("5"*64),fixture_hash:("2"*64),prompt_hash:("3"*64),verifier_hash:("4"*64)}' >"$schema_fixture"
  validate_schema "$TEST_ROOT/benchmarks/contracts/benchmark-result.schema.json" "$schema_fixture"
  jq '.process_exit = 7' "$schema_fixture" >"$schema_fixture.invalid"
  assert_schema_rejects "$TEST_ROOT/benchmarks/contracts/benchmark-result.schema.json" "$schema_fixture.invalid"
  jq -n '{schema:2,contract:"codex-baseline-routing-result/v2",id:"lean-typo",repetition:1,pass:true,process_exit:0,elapsed_ms:1,turns:1,commands:0,file_changes:0,input_tokens:null,output_tokens:null,source_hash:("0"*64),prompt_hash:("1"*64),expected:{workflow:"LEAN",high_risk:false,skill:null,execution:"SOLO",execution_profile:"auto-evaluation",planned_fanout:0,write_isolation:"single-writer"},actual:{workflow:"LEAN",high_risk:false,selected_skills:[],execution:"SOLO",execution_profile:"auto-evaluation",parallelism_reason:"No useful independent lane.",planned_fanout:0,planned_lanes:[],child_limit:6,wave_limit:4,write_isolation:"single-writer",runtime_receipt:{verification:"unverified",actual_fanout:null,available_capacity:null,children:[],depth_intended:0,depth_observed:null,depth_verification:"unverified",waves_observed:null,peak_concurrency:null,spawn_failures:null,fallbacks:null,interrupts:null,timeouts:null,write_isolation:{verification:"unverified",value:null},worktree_isolation:{verification:"unverified",value:null},test_isolation:{verification:"unverified",value:null},conflicts:null,integration_rework_actions:null,handoff_bytes:null,duplicate_context_bytes:null,parent_settings_before:null,parent_settings_after:null,parent_settings_unchanged:null,parent_settings_verification:"unverified"},reason:"bounded"}}' >"$schema_fixture"
  validate_schema "$TEST_ROOT/contracts/routing-result.schema.json" "$schema_fixture"
  jq '.actual.planned_fanout = 1' "$schema_fixture" >"$schema_fixture.invalid"
  assert_schema_rejects "$TEST_ROOT/contracts/routing-result.schema.json" "$schema_fixture.invalid"
  jq -n '{schema:2,contract:"codex-baseline-behavior-result/v2",id:"deep-risk-plan",repetition:1,pass:true,process_exit:0,verifier_exit:0,elapsed_ms:1,turns:1,commands:1,file_changes:0,input_tokens:null,output_tokens:null,source_hash:("0"*64),prompt_hash:("1"*64),actual:{case_id:"deep-risk-plan",workflow:"DEEP",high_risk:true,selected_skills:["codex-baseline-deep-work"],execution:"TEAM",execution_profile:"auto-evaluation",parallelism_reason:"Three independent read-only investigations.",planned_fanout:3,planned_lanes:[{id:"security",objective:"Review security boundary",kind:"exploration",writer:"none",write_scope:[],dependencies:[]},{id:"recovery",objective:"Review recovery boundary",kind:"exploration",writer:"none",write_scope:[],dependencies:[]},{id:"compatibility",objective:"Review compatibility boundary",kind:"exploration",writer:"none",write_scope:[],dependencies:[]}],child_limit:6,wave_limit:4,write_isolation:"single-writer",runtime_receipt:{verification:"unverified",actual_fanout:null,available_capacity:null,children:[],depth_intended:1,depth_observed:null,depth_verification:"unverified",waves_observed:null,peak_concurrency:null,spawn_failures:null,fallbacks:null,interrupts:null,timeouts:null,write_isolation:{verification:"unverified",value:null},worktree_isolation:{verification:"unverified",value:null},test_isolation:{verification:"unverified",value:null},conflicts:null,integration_rework_actions:null,handoff_bytes:null,duplicate_context_bytes:null,parent_settings_before:null,parent_settings_after:null,parent_settings_unchanged:null,parent_settings_verification:"unverified"},evidence_files:[],material_question:null,plan:null,risk_controls:null,onboarding:null,conformance:null,reason:"schema-valid test receipt"}}' >"$schema_fixture"
  validate_schema "$TEST_ROOT/contracts/behavior-result.schema.json" "$schema_fixture"
  jq '.actual = {}' "$schema_fixture" >"$schema_fixture.invalid"
  assert_schema_rejects "$TEST_ROOT/contracts/behavior-result.schema.json" "$schema_fixture.invalid"
  validate_schema "$TEST_ROOT/tests/routing/output.schema.json" "$TEST_ROOT/tests/routing/unverified-receipt.json"
  assert_schema_rejects "$TEST_ROOT/tests/routing/output.schema.json" "$TEST_ROOT/tests/routing/verified-receipt.json"
  assert_schema_rejects "$TEST_ROOT/tests/routing/output.schema.json" "$TEST_ROOT/tests/routing/invalid-fabricated-receipt.json"
  node "$TEST_ROOT/scripts/validate-routing-receipt.mjs" "$TEST_ROOT/tests/routing/unverified-receipt.json"
  node "$TEST_ROOT/scripts/validate-routing-receipt.mjs" "$TEST_ROOT/tests/routing/verified-receipt.json"
  jq '.runtime_receipt.actual_fanout = 3 | .runtime_receipt.available_capacity = 0 | .runtime_receipt.spawn_failures = 0 | .runtime_receipt.fallbacks = 0 | .runtime_receipt.parent_settings_after.model = "different"' \
    "$TEST_ROOT/tests/routing/verified-receipt.json" >"$schema_fixture.invalid"
  if node "$TEST_ROOT/scripts/validate-routing-receipt.mjs" "$schema_fixture.invalid" >/dev/null 2>&1; then return 1; fi
  jq '.planned_fanout = 1 | .planned_lanes = [.planned_lanes[0]]' \
    "$TEST_ROOT/tests/routing/verified-receipt.json" >"$schema_fixture.invalid"
  if node "$TEST_ROOT/scripts/validate-routing-receipt.mjs" "$schema_fixture.invalid" >/dev/null 2>&1; then return 1; fi
  jq '.planned_lanes[1].id = "different-lane"' \
    "$TEST_ROOT/tests/routing/verified-receipt.json" >"$schema_fixture.invalid"
  if node "$TEST_ROOT/scripts/validate-routing-receipt.mjs" "$schema_fixture.invalid" >/dev/null 2>&1; then return 1; fi
  jq '.runtime_receipt.children[2].attempt = 3' \
    "$TEST_ROOT/tests/routing/verified-receipt.json" >"$schema_fixture.invalid"
  if node "$TEST_ROOT/scripts/validate-routing-receipt.mjs" "$schema_fixture.invalid" >/dev/null 2>&1; then return 1; fi

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

  mkdir -p -- "$git_guard/repo"
  printf 'tracked\n' >"$git_guard/repo/tracked.txt"
  printf '#!/bin/sh\n: >%q\nprintf "%%s\\n" "2 0000000000000000000000000000000000000000"\n' \
    "$git_guard/fsmonitor-invoked" >"$git_guard/fsmonitor"
  chmod 0755 -- "$git_guard/fsmonitor"
  git -C "$git_guard/repo" init -q
  git -C "$git_guard/repo" -c user.name=codex-baseline -c user.email=baseline.invalid add tracked.txt
  git -C "$git_guard/repo" -c user.name=codex-baseline -c user.email=baseline.invalid commit -qm starter
  git_status=$(/bin/bash -c '
    source "$1/scripts/lib/common.sh"
    source "$1/scripts/lib/evaluation.sh"
    eval_validate_system_boundary
    eval_require_cgroup_boundary
    eval_source_git "$2/repo" "$2/home-clean" --status
  ' _ "$TEST_ROOT" "$git_guard")
  [[ $git_status == "$(git -C "$git_guard/repo" rev-parse HEAD)"$'\t'false ]]
  git -C "$git_guard/repo" config core.fsmonitor "$git_guard/fsmonitor"
  if /bin/bash -c '
    source "$1/scripts/lib/common.sh"
    source "$1/scripts/lib/evaluation.sh"
    eval_validate_system_boundary
    eval_require_cgroup_boundary
    eval_source_git "$2/repo" "$2/home-fsmonitor" diff --quiet --no-ext-diff --no-textconv HEAD --
  ' _ "$TEST_ROOT" "$git_guard" >/dev/null 2>&1; then return 1; fi
  test ! -e "$git_guard/fsmonitor-invoked"
  git -C "$git_guard/repo" config --unset core.fsmonitor
  printf '#!/bin/sh\n: >%q\nexit 97\n' "$git_guard/filter-invoked" >"$git_guard/filter"
  chmod 0755 -- "$git_guard/filter"
  git -C "$git_guard/repo" config filter.evil.process "$git_guard/filter"
  printf 'tracked.txt filter=evil\n' >"$git_guard/repo/.git/info/attributes"
  if /bin/bash -c '
    source "$1/scripts/lib/common.sh"
    source "$1/scripts/lib/evaluation.sh"
    eval_validate_system_boundary
    eval_require_cgroup_boundary
    eval_source_git "$2/repo" "$2/home-filter" diff --quiet --no-ext-diff --no-textconv HEAD --
  ' _ "$TEST_ROOT" "$git_guard" >/dev/null 2>&1; then return 1; fi
  test ! -e "$git_guard/filter-invoked"
  git -C "$git_guard/repo" config --unset filter.evil.process
  printf '#!/bin/sh\n: >%q\nexit 97\n' "$git_guard/textconv-invoked" >"$git_guard/textconv"
  chmod 0755 -- "$git_guard/textconv"
  git -C "$git_guard/repo" config diff.evil.textconv "$git_guard/textconv"
  printf 'tracked.txt diff=evil\n' >"$git_guard/repo/.git/info/attributes"
  if /bin/bash -c '
    source "$1/scripts/lib/common.sh"
    source "$1/scripts/lib/evaluation.sh"
    eval_validate_system_boundary
    eval_require_cgroup_boundary
    eval_source_git "$2/repo" "$2/home-textconv" diff --quiet --no-ext-diff --no-textconv HEAD --
  ' _ "$TEST_ROOT" "$git_guard" >/dev/null 2>&1; then return 1; fi
  test ! -e "$git_guard/textconv-invoked"
  git -C "$git_guard/repo" config --unset diff.evil.textconv
  printf '#!/bin/sh\nprintf "%%s\\n" "worktree-filter-executed" >&2\nexit 97\n' >"$git_guard/repo/worktree-filter"
  chmod 0755 -- "$git_guard/repo/worktree-filter"
  git -C "$git_guard/repo" config extensions.worktreeConfig true
  git -C "$git_guard/repo" config --worktree filter.evil.process /source/worktree-filter
  printf 'tracked.txt filter=evil\n' >"$git_guard/repo/.git/info/attributes"
  printf 'modified\n' >"$git_guard/repo/tracked.txt"
  test -f "$git_guard/repo/.git/config.worktree"
  set +e
  worktree_output=$(/bin/bash -c '
    source "$1/scripts/lib/common.sh"
    source "$1/scripts/lib/evaluation.sh"
    eval_validate_system_boundary
    eval_require_cgroup_boundary
    eval_source_git "$2/repo" "$2/home-worktree-config" --status
  ' _ "$TEST_ROOT" "$git_guard" 2>&1)
  worktree_status=$?
  set -e
  [[ $worktree_status -ne 0 ]]
  grep -Fxq 'codex-baseline: source Git metadata enables executable configuration: extensions.worktreeconfig' <<<"$worktree_output"
  if grep -Fq 'worktree-filter-executed' <<<"$worktree_output"; then return 1; fi

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
  local root status tampered_source tampered_root racy_source racy_root duplicate_source duplicate_root stable_source stable_root
  local provenance_source provenance_root git_shim_dir git_sentinel
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

  provenance_source="$TEST_TMP/lifecycle-provenance-source"
  mkdir -p -- "$provenance_source/.git"
  cp -a -- "$TEST_ROOT/VERSION" "$TEST_ROOT/baseline" "$TEST_ROOT/benchmarks" "$TEST_ROOT/scripts" "$provenance_source/"
  provenance_root=$(new_home lifecycle-provenance)
  git_shim_dir="$TEST_TMP/lifecycle-provenance-git-shim"
  git_sentinel="$TEST_TMP/lifecycle-provenance-git-executed"
  mkdir -p -- "$git_shim_dir"
  printf '%s\n' '#!/bin/sh' 'printf invoked >"$CB_TEST_GIT_SENTINEL"' 'exit 99' >"$git_shim_dir/git"
  chmod 0755 "$git_shim_dir/git"
  HOME="$provenance_root/home" CODEX_HOME="$provenance_root/home/.codex" AGENTS_HOME="$provenance_root/home/.agents" \
    PATH="$git_shim_dir:$PATH" CB_TEST_GIT_SENTINEL="$git_sentinel" \
    CODEX_BASELINE_TESTING=1 CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION=1 \
    "$provenance_source/scripts/codex-baseline.sh" install --dry-run >"$provenance_root/install.log"
  test ! -e "$git_sentinel"
  grep -qx 'source-revision: unversioned' "$provenance_root/install.log"
  grep -qx 'source-dirty: unknown' "$provenance_root/install.log"

  find "$root/home" -printf '%P|%y|%m|%s\n' | LC_ALL=C sort >"$root/before"
  baseline "$root" install --dry-run >"$root/dry.log"
  find "$root/home" -printf '%P|%y|%m|%s\n' | LC_ALL=C sort >"$root/after"
  cmp "$root/before" "$root/after"
  baseline "$root" install >"$root/install.log"
  test "$(grep -c '^<!-- codex-baseline:begin version=' "$root/home/.codex/AGENTS.md")" -eq 1
  grep -Fq 'Release-candidate execution is SOLO' "$root/home/.codex/AGENTS.md"
  ! grep -Fq 'Stable execution autonomously chooses SOLO, TEAM, or SWARM' "$root/home/.codex/AGENTS.md"

  stable_source="$TEST_TMP/stable-guidance-source"
  mkdir -p -- "$stable_source"
  cp -a -- "$TEST_ROOT/VERSION" "$TEST_ROOT/baseline" "$TEST_ROOT/benchmarks" "$TEST_ROOT/scripts" "$stable_source/"
  sed -i 's/"status": "rc\.1"/"status": "stable"/' "$stable_source/baseline/release-status.json"
  refresh_release_status_source_manifest "$stable_source"
  stable_root=$(new_home stable-guidance)
  HOME="$stable_root/home" CODEX_HOME="$stable_root/home/.codex" AGENTS_HOME="$stable_root/home/.agents" \
    CODEX_BASELINE_TESTING=1 CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION=1 \
    "$stable_source/scripts/codex-baseline.sh" install --acknowledge-unverified-source >/dev/null
  grep -Fq 'Stable execution autonomously chooses SOLO, TEAM, or SWARM' "$stable_root/home/.codex/AGENTS.md"
  ! grep -Fq 'Release-candidate execution is SOLO' "$stable_root/home/.codex/AGENTS.md"
  test -x "$root/home/.local/bin/codex-baseline"
  test "$(find "$root/home/.agents/skills" -mindepth 1 -maxdepth 1 -type d -name 'codex-baseline-*' | wc -l)" -eq 4
  snapshot_files "$root/home" "$root/installed-before"
  baseline "$root" install >"$root/reinstall.log"
  snapshot_files "$root/home" "$root/installed-after"
  cmp "$root/installed-before" "$root/installed-after"
  baseline "$root" doctor --json | jq -e --arg payload "$(jq -r .payload_hash "$TEST_ROOT/baseline/manifest.json")" '
    .schema == 2 and .contract == "codex-baseline-doctor/v2" and .failure_count == 0 and
    .baseline_version == "0.3.0" and
    .source_provenance == {scope:"installed-runtime",version:"0.3.0",trust:"unsigned-local-source",payload_sha256:$payload} and
    .managed_objects == {ok:8,total:8} and .skills == {ok:4,total:4} and
    .runtime_dependencies.status == "verified" and (.runtime_dependencies.missing | length) == 0 and
    .active_config.status == "accepted-by-strict-config" and
    .hook_state == {baseline_owned:0,user_owned:"preserved-not-enumerated"} and
    .owned_config_keys == 1 and
    .optimizer.contract == "codex-baseline-config-operations/v2" and
    .optimizer.managed_keys == ["agents.max_concurrent_threads_per_session"] and
    (.optimizer.drift | not) and .optimizer.agents == "available" and .optimizer.fast == "available" and .optimizer.ultrafast == "unavailable" and
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
    CODEX_BASELINE_TESTING=1 CODEX_BASELINE_TEST_CRASH_AFTER=3 \
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
    CODEX_BASELINE_TESTING=1 CODEX_BASELINE_TEST_CRASH_AFTER=3 \
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
    CODEX_BASELINE_TESTING=1 CODEX_BASELINE_TEST_CRASH_AFTER=3 \
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
  local fixture before backups_before backups_after link_fixture outside status race_fixture race_backup new_fixture root_swap_fixture root_swap_outside root_swap_original flood_fixture index
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
  validate_schema "$TEST_ROOT/contracts/onboarding-report.schema.json" "$fixture/report.json"
  jq -e '
    .schema == 2 and .contract == "codex-baseline-onboarding/v2" and
    .project_commands_executed == false and .entries_visited > .files and
    .links_skipped == 1 and .sensitive_skipped == 1 and (.commands | index("npm run test")) != null and
    (.parallelism_map.statements | length) >= 12 and (.parallelism_map.statements | length) <= 64 and
    ([.parallelism_map.statements[].kind] | unique | length) >= 12 and
    any(.parallelism_map.statements[]; .kind == "source_root" and .status == "inferred") and
    any(.parallelism_map.statements[]; .kind == "package_boundary" and .subject == "." and .status == "inferred") and
    any(.parallelism_map.statements[]; .kind == "generated_ownership" and .status == "inferred") and
    all(.parallelism_map.statements[]; .status == "declared" or .status == "inferred" or .status == "unknown")
  ' "$fixture/report.json" >/dev/null
  test ! -e "$fixture/EXECUTED"
  before=$(cut -d' ' -f1 "$fixture/agents.before")
  test "$(sha256sum "$fixture/AGENTS.md" | cut -d' ' -f1)" = "$before"

  flood_fixture="$TEST_TMP/onboarding-generated-flood"
  mkdir -p -- "$flood_fixture/src"
  for index in $(seq 1 80); do
    mkdir -p -- "$flood_fixture/generated-$index"
    printf '{}\n' >"$flood_fixture/generated-$index/package-lock.json"
  done
  "$TEST_ROOT/scripts/onboard.sh" --json "$flood_fixture" >"$flood_fixture/report.json"
  validate_schema "$TEST_ROOT/contracts/onboarding-report.schema.json" "$flood_fixture/report.json"
  jq -e '(.parallelism_map.statements | length) <= 64 and
    ([.parallelism_map.statements[].kind] | unique) ==
      ["api_boundary","generated_ownership","package_boundary","shared_build_output","shared_cache","shared_database","shared_fixture","shared_port","source_root","test_shard","write_conflict","write_safe"]' \
    "$flood_fixture/report.json" >/dev/null
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
  grep -q 'Parallel execution map (static evidence only)' "$fixture/AGENTS.md"
  grep -q 'one parent writer' "$fixture/AGENTS.md"
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

optimize_baseline() {
  local root=$1; shift
  HOME="$root/home" CODEX_HOME="$root/home/.codex" AGENTS_HOME="$root/home/.agents" \
    CODEX_BASELINE_TESTING=1 CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION=1 \
    "$TEST_ROOT/scripts/codex-baseline.sh" optimize "$@"
}

test_optimizer() {
  local root config before after status journal_root original_hash restored_hash metadata_path
  local absent_root no_codex_root drift_root conflict_root ambiguous_root link_root hardlink_root install_root settings_root disabled_root feature_disabled_root legacy_root codex_link_root unsafe_codex_root swapped_codex_root
  local integer_root integer_key integer_token integer_name
  metadata_path=$(dirname -- "$(command -v getfacl)")

  root=$(new_home optimizer)
  config="$root/home/.codex/config.toml"
  find "$root/home" -printf '%P|%y|%m|%s\n' | LC_ALL=C sort >"$root/before"
  optimize_baseline "$root" --json >"$root/check.json"
  validate_schema "$TEST_ROOT/contracts/optimize-report.schema.json" "$root/check.json"
  jq -e '.mode == "check" and .status == "available" and (.apply | not) and .managed_keys == [] and (.drift | not)' "$root/check.json" >/dev/null
  find "$root/home" -printf '%P|%y|%m|%s\n' | LC_ALL=C sort >"$root/after"
  cmp "$root/before" "$root/after"

  no_codex_root=$(new_home optimizer-no-codex)
  HOME="$no_codex_root/home" CODEX_HOME="$no_codex_root/home/.codex" AGENTS_HOME="$no_codex_root/home/.agents" \
    PATH=/usr/bin:/bin "$TEST_ROOT/scripts/codex-baseline.sh" optimize --json >"$no_codex_root/check.json"
  jq -e '.status == "available" and .capabilities == {agents:"unverified",fast:"unverified",ultrafast:"unavailable"}' \
    "$no_codex_root/check.json" >/dev/null

  optimize_baseline "$root" --speed fast --json >"$root/plan.json"
  validate_schema "$TEST_ROOT/contracts/optimize-report.schema.json" "$root/plan.json"
  jq -e '.mode == "optimize" and .status == "planned" and (.apply | not) and .speed == "fast" and .bytes_changed == 0' "$root/plan.json" >/dev/null
  test ! -e "$config"
  test -z "$(find "$root/home/.codex" -mindepth 1 -not -path "$root/home/.codex" -print -quit)"
  optimize_baseline "$root" --speed fast --dry-run --json >"$root/dry-run.json"
  jq -e '.mode == "optimize" and .status == "planned" and (.apply | not) and .speed == "fast" and .bytes_changed == 0' "$root/dry-run.json" >/dev/null
  test ! -e "$config"
  test -z "$(find "$root/home/.codex" -mindepth 1 -not -path "$root/home/.codex" -print -quit)"
  set +e
  optimize_baseline "$root" --check --apply >"$root/check-apply.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q -- '--check cannot be combined' "$root/check-apply.log"
  test -z "$(find "$root/home/.codex" -mindepth 1 -not -path "$root/home/.codex" -print -quit)"

  optimize_baseline "$root" --apply --json >"$root/apply.json"
  validate_schema "$TEST_ROOT/contracts/optimize-report.schema.json" "$root/apply.json"
  jq -e '.status == "applied" and .apply and .agents == {enabled:true,cap:6,legacy_cap:null,effective_override:true} and (.managed_keys | sort) == ["agents.enabled","agents.max_concurrent_threads_per_session"]' "$root/apply.json" >/dev/null
  grep -q '^enabled = true$' "$config"
  grep -q '^max_concurrent_threads_per_session = 6$' "$config"
  optimize_baseline "$root" --apply --speed fast --json >"$root/fast.json"
  jq -e '.status == "applied" and .speed == "fast" and (.managed_keys | sort) == ["agents.enabled","agents.max_concurrent_threads_per_session","features.fast_mode","service_tier"]' "$root/fast.json" >/dev/null
  grep -q '^service_tier = "fast"$' "$config"
  grep -q '^fast_mode = true$' "$config"
  optimize_baseline "$root" --apply --speed standard --json >"$root/standard.json"
  jq -e '.status == "applied" and .speed == "standard" and (.managed_keys | sort) == ["agents.enabled","agents.max_concurrent_threads_per_session"]' "$root/standard.json" >/dev/null
  ! grep -q '^service_tier' "$config"
  ! grep -q '^fast_mode' "$config"

  printf '\n%s\n' 'user_independent = "survives"' >>"$config"
  optimize_baseline "$root" --restore --apply --json >"$root/restore.json"
  jq -e '.mode == "restore" and .status == "restored" and .apply and .managed_keys == []' "$root/restore.json" >/dev/null
  grep -q '^user_independent = "survives"$' "$config"
  ! grep -q '^enabled = true$' "$config"
  ! grep -q '^max_concurrent_threads_per_session = 6$' "$config"

  absent_root=$(new_home optimizer-absent)
  optimize_baseline "$absent_root" --apply >/dev/null
  test -f "$absent_root/home/.codex/config.toml"
  optimize_baseline "$absent_root" --restore --apply >/dev/null
  test ! -e "$absent_root/home/.codex/config.toml"

  root=$(new_home optimizer-bytes)
  config="$root/home/.codex/config.toml"
  printf '\357\273\277# SENTINEL-SECRET stays opaque\r\n[foreign]\r\nunicode = "Gr\303\274ezi"' >"$config"
  original_hash=$(sha256sum "$config" | awk '{print $1}')
  optimize_baseline "$root" --apply --speed fast >/dev/null
  python3 - "$config" <<'PY'
import pathlib, sys
b = pathlib.Path(sys.argv[1]).read_bytes()
assert b.startswith(b"\xef\xbb\xbf")
assert b"# SENTINEL-SECRET stays opaque\r\n" in b
assert b'unicode = "Gr\xc3\xbcezi"' in b
assert not b.endswith(b"\n")
assert b.replace(b"\r\n", b"").find(b"\n") == -1
PY
  journal_root="$root/home/.codex/codex-baseline/state/config"
  ! rg -F 'SENTINEL-SECRET' "$journal_root"
  optimize_baseline "$root" --restore --apply >/dev/null
  restored_hash=$(sha256sum "$config" | awk '{print $1}')
  [[ $restored_hash == "$original_hash" ]]

  drift_root=$(new_home optimizer-drift)
  optimize_baseline "$drift_root" --apply >/dev/null
  sed -i 's/max_concurrent_threads_per_session = 6/max_concurrent_threads_per_session = 5/' "$drift_root/home/.codex/config.toml"
  set +e
  optimize_baseline "$drift_root" --json >"$drift_root/drift.json" 2>"$drift_root/drift.stderr"
  status=$?
  set -e
  [[ $status -eq 4 ]]
  jq -e '.status == "conflict" and .drift' "$drift_root/drift.json" >/dev/null
  before=$(sha256sum "$drift_root/home/.codex/config.toml" | awk '{print $1}')
  set +e
  optimize_baseline "$drift_root" --restore --apply >"$drift_root/restore.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  after=$(sha256sum "$drift_root/home/.codex/config.toml" | awk '{print $1}')
  [[ $after == "$before" ]]

  set +e
  optimize_baseline "$drift_root" --speed ultrafast --apply --json >"$drift_root/ultrafast.json"
  status=$?
  set -e
  [[ $status -eq 3 ]]
  jq -e '.status == "unavailable" and .speed == "ultrafast" and (.apply | not) and .bytes_changed == 0' "$drift_root/ultrafast.json" >/dev/null
  [[ $(sha256sum "$drift_root/home/.codex/config.toml" | awk '{print $1}') == "$before" ]]

  conflict_root=$(new_home optimizer-speed-conflict)
  printf '%s\n' 'service_tier = "flex"' >"$conflict_root/home/.codex/config.toml"
  before=$(sha256sum "$conflict_root/home/.codex/config.toml" | awk '{print $1}')
  set +e
  optimize_baseline "$conflict_root" --speed fast --apply >"$conflict_root/fast.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'unowned conflicting key: service_tier' "$conflict_root/fast.log"
  [[ $(sha256sum "$conflict_root/home/.codex/config.toml" | awk '{print $1}') == "$before" ]]
  printf '%s\n' 'service_tier = "fast"' >"$conflict_root/home/.codex/config.toml"
  before=$(sha256sum "$conflict_root/home/.codex/config.toml" | awk '{print $1}')
  set +e
  optimize_baseline "$conflict_root" --speed standard --apply >"$conflict_root/standard.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'unowned conflicting key: service_tier' "$conflict_root/standard.log"
  [[ $(sha256sum "$conflict_root/home/.codex/config.toml" | awk '{print $1}') == "$before" ]]

  ambiguous_root=$(new_home optimizer-ambiguous)
  printf '%s\n' 'agents.max_concurrent_threads_per_session = 2' >"$ambiguous_root/home/.codex/config.toml"
  before=$(sha256sum "$ambiguous_root/home/.codex/config.toml" | awk '{print $1}')
  set +e
  optimize_baseline "$ambiguous_root" --apply >"$ambiguous_root/output.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -Eq 'dotted|ambiguous' "$ambiguous_root/output.log"
  [[ $(sha256sum "$ambiguous_root/home/.codex/config.toml" | awk '{print $1}') == "$before" ]]

  for integer_key in max_concurrent_threads_per_session max_threads; do
    for integer_token in 1000000 01; do
      integer_name=${integer_key}_${integer_token}
      integer_root=$(new_home "optimizer-integer-$integer_name")
      printf '%s\n' '[agents]' "$integer_key = $integer_token" >"$integer_root/home/.codex/config.toml"
      before=$(sha256sum "$integer_root/home/.codex/config.toml" | awk '{print $1}')
      set +e
      optimize_baseline "$integer_root" --apply >"$integer_root/apply.log" 2>&1
      status=$?
      set -e
      [[ $status -ne 0 ]]
      grep -Eq 'unsupported (integer token|scalar type)' "$integer_root/apply.log"
      [[ $(sha256sum "$integer_root/home/.codex/config.toml" | awk '{print $1}') == "$before" ]]
      test ! -e "$integer_root/home/.codex/codex-baseline"
      set +e
      optimize_baseline "$integer_root" --restore --apply >"$integer_root/restore.log" 2>&1
      status=$?
      set -e
      [[ $status -ne 0 ]]
      grep -Eq 'unsupported (integer token|scalar type)' "$integer_root/restore.log"
      [[ $(sha256sum "$integer_root/home/.codex/config.toml" | awk '{print $1}') == "$before" ]]
      test ! -e "$integer_root/home/.codex/codex-baseline"
    done
  done

  link_root=$(new_home optimizer-symlink)
  printf '%s\n' '[foreign]' 'value = 1' >"$link_root/target.toml"
  ln -s "$link_root/target.toml" "$link_root/home/.codex/config.toml"
  set +e
  optimize_baseline "$link_root" --apply >"$link_root/output.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -Eq 'symlink|linked' "$link_root/output.log"

  hardlink_root=$(new_home optimizer-hardlink)
  printf '%s\n' '[foreign]' 'value = 1' >"$hardlink_root/home/.codex/config.toml"
  ln "$hardlink_root/home/.codex/config.toml" "$hardlink_root/config-copy.toml"
  set +e
  optimize_baseline "$hardlink_root" --apply >"$hardlink_root/output.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  if ! grep -Eq 'hardlink|hard links?|link count' "$hardlink_root/output.log"; then
    sed 's/^/unexpected hardlink diagnostic: /' "$hardlink_root/output.log" >&2
    return 1
  fi

  install_root=$(new_home optimizer-auto-install)
  CODEX_BASELINE_TESTING=1 CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION=1 baseline "$install_root" install >/dev/null
  grep -q '^max_concurrent_threads_per_session = 6$' "$install_root/home/.codex/config.toml"
  test "$(find "$install_root/home/.codex/codex-baseline/state/config/transactions" -type d -path '*/ownership/keys/*' -printf '%f\n' | sort -u)" = agents_max
  CODEX_BASELINE_TESTING=1 CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION=1 baseline "$install_root" uninstall >/dev/null
  test ! -e "$install_root/home/.codex/config.toml"
  CODEX_BASELINE_TESTING=1 CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION=1 baseline "$install_root" install >/dev/null
  grep -q '^max_concurrent_threads_per_session = 6$' "$install_root/home/.codex/config.toml"
  CODEX_BASELINE_TESTING=1 CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION=1 baseline "$install_root" rollback >/dev/null
  test ! -e "$install_root/home/.codex/config.toml"
  settings_root=$(new_home optimizer-settings-install)
  printf '%s\n' 'model = "gpt-5.6"' 'model_reasoning_effort = "ultra"' 'service_tier = "fast"' '' '[features]' 'fast_mode = true' >"$settings_root/home/.codex/config.toml"
  CODEX_BASELINE_TESTING=1 CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION=1 baseline "$settings_root" install >/dev/null
  grep -q '^model = "gpt-5.6"$' "$settings_root/home/.codex/config.toml"
  grep -q '^model_reasoning_effort = "ultra"$' "$settings_root/home/.codex/config.toml"
  grep -q '^service_tier = "fast"$' "$settings_root/home/.codex/config.toml"
  grep -q '^fast_mode = true$' "$settings_root/home/.codex/config.toml"
  grep -q '^max_concurrent_threads_per_session = 6$' "$settings_root/home/.codex/config.toml"
  test "$(find "$settings_root/home/.codex/codex-baseline/state/config/transactions" -type d -path '*/ownership/keys/*' -printf '%f\n' | sort -u)" = agents_max
  disabled_root=$(new_home optimizer-disabled-install)
  printf '%s\n' '[agents]' 'enabled = false' >"$disabled_root/home/.codex/config.toml"
  before=$(sha256sum "$disabled_root/home/.codex/config.toml" | awk '{print $1}')
  CODEX_BASELINE_TESTING=1 CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION=1 baseline "$disabled_root" install >/dev/null
  after=$(sha256sum "$disabled_root/home/.codex/config.toml" | awk '{print $1}')
  [[ $after == "$before" ]]
  test ! -e "$disabled_root/home/.codex/codex-baseline/state/config/current"
  optimize_baseline "$disabled_root" --apply >/dev/null
  grep -q '^enabled = true$' "$disabled_root/home/.codex/config.toml"
  grep -q '^max_concurrent_threads_per_session = 6$' "$disabled_root/home/.codex/config.toml"
  optimize_baseline "$disabled_root" --restore --apply >/dev/null
  after=$(sha256sum "$disabled_root/home/.codex/config.toml" | awk '{print $1}')
  [[ $after == "$before" ]]
  feature_disabled_root=$(new_home optimizer-feature-disabled)
  printf '%s\n' '[features]' 'multi_agent = false' >"$feature_disabled_root/home/.codex/config.toml"
  optimize_baseline "$feature_disabled_root" --json >"$feature_disabled_root/check.json"
  jq -e '.agents.enabled == null and .agents.effective_override == true' "$feature_disabled_root/check.json" >/dev/null
  legacy_root=$(new_home optimizer-legacy-install)
  printf '%s\n' '[agents]' 'max_threads = 2' >"$legacy_root/home/.codex/config.toml"
  before=$(sha256sum "$legacy_root/home/.codex/config.toml" | awk '{print $1}')
  CODEX_BASELINE_TESTING=1 CODEX_BASELINE_TEST_SKIP_CONFIG_VALIDATION=1 baseline "$legacy_root" install >/dev/null
  after=$(sha256sum "$legacy_root/home/.codex/config.toml" | awk '{print $1}')
  [[ $after == "$before" ]]
  test ! -e "$legacy_root/home/.codex/codex-baseline/state/config/current"

  codex_link_root=$(new_safe_home optimizer-codex-link)
  mkdir -p -- "$codex_link_root/tools"
  ln -s -- "$TEST_ROOT/tests/fixtures/codex" "$codex_link_root/tools/codex"
  HOME="$codex_link_root/home" CODEX_HOME="$codex_link_root/home/.codex" AGENTS_HOME="$codex_link_root/home/.agents" \
    CODEX_BASELINE_TESTING=1 PATH="$codex_link_root/tools:$metadata_path:/usr/bin:/bin" \
    "$TEST_ROOT/scripts/codex-baseline.sh" optimize --apply >/dev/null
  grep -q '^max_concurrent_threads_per_session = 6$' "$codex_link_root/home/.codex/config.toml"

  unsafe_codex_root=$(new_safe_home optimizer-codex-unsafe-link)
  mkdir -p -- "$unsafe_codex_root/untrusted" "$unsafe_codex_root/tools"
  cp -- "$TEST_ROOT/tests/fixtures/codex" "$unsafe_codex_root/untrusted/codex"
  chmod 0777 "$unsafe_codex_root/untrusted"
  ln -s -- "$unsafe_codex_root/untrusted/codex" "$unsafe_codex_root/tools/codex"
  set +e
  HOME="$unsafe_codex_root/home" CODEX_HOME="$unsafe_codex_root/home/.codex" AGENTS_HOME="$unsafe_codex_root/home/.agents" \
    CODEX_BASELINE_TESTING=1 PATH="$unsafe_codex_root/tools:$metadata_path:/usr/bin:/bin" \
    "$TEST_ROOT/scripts/codex-baseline.sh" optimize --apply >"$unsafe_codex_root/output.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'ancestry is group/other writable' "$unsafe_codex_root/output.log"
  test ! -e "$unsafe_codex_root/home/.codex/config.toml"

  swapped_codex_root=$(new_safe_home optimizer-codex-swap)
  mkdir -p -- "$swapped_codex_root/runtime" "$swapped_codex_root/tools"
  cp -- "$TEST_ROOT/tests/fixtures/codex" "$swapped_codex_root/runtime/codex"
  chmod 0755 "$swapped_codex_root/runtime/codex"
  ln -s -- "$swapped_codex_root/runtime/codex" "$swapped_codex_root/tools/codex"
  set +e
  HOME="$swapped_codex_root/home" CODEX_HOME="$swapped_codex_root/home/.codex" AGENTS_HOME="$swapped_codex_root/home/.agents" \
    CODEX_BASELINE_TESTING=1 CODEX_BASELINE_TEST_SWAP_CODEX_AFTER_VALIDATION=1 PATH="$swapped_codex_root/tools:$metadata_path:/usr/bin:/bin" \
    "$TEST_ROOT/scripts/codex-baseline.sh" optimize --apply >"$swapped_codex_root/output.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'Codex executable changed during isolated config validation' "$swapped_codex_root/output.log"
  test ! -e "$swapped_codex_root/home/.codex/config.toml"
  pass 'optimizer is explicit, byte-preserving, drift-safe, secret-safe, and override-aware'
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
  local expected_summary_status expected_source_provenance
  if [[ -z $(git -C "$TEST_ROOT" status --porcelain --untracked-files=normal) ]]; then
    expected_summary_status=unverified
    expected_source_provenance=passed
  else
    expected_summary_status=failed
    expected_source_provenance=failed
  fi
  node "$TEST_ROOT/tests/benchmark/truth-provenance.mjs" >/dev/null
  node "$TEST_ROOT/tests/benchmark/hygiene.mjs" >/dev/null
  node "$TEST_ROOT/tests/benchmark/app-server-runner.mjs" >/dev/null
  node "$TEST_ROOT/tests/benchmark/app-server-telemetry.mjs" >/dev/null
  bash -p "$TEST_ROOT/tests/benchmark/runtime-telemetry.sh" >/dev/null
  local installed_root installed_result installed_bad status platform=linux
  local CODEX_BASELINE_TESTING=1
  local CODEX_BASELINE_EXPECTED_CODEX_SHA256
  CODEX_BASELINE_EXPECTED_CODEX_SHA256=$(sha256sum -- "$TEST_ROOT/tests/fixtures/codex" | awk '{print $1}')
  export CODEX_BASELINE_TESTING CODEX_BASELINE_EXPECTED_CODEX_SHA256
  if grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then platform=wsl2; fi
  "$TEST_ROOT/scripts/benchmark.sh" --static >/dev/null
  jq -e '
    .schema == 2 and .default_repetitions == 10 and
    .arms == ["vanilla","baseline-solo","auto-homogeneous","auto-routed"] and
    (.tasks | map(.class) | unique | sort) == ["large","medium","risk-sensitive","small"] and
    (.tasks | length) == 10 and
    ([.tasks[] | select(.parallelism_class == "parallel-positive")] | length) == 6 and
    ([.tasks[] | select(.parallelism_class == "serial-negative")] | length) == 4 and
    any(.tasks[]; .parallelism_class == "parallel-positive" and .expected_lanes == 6) and
    .native_powershell_evaluation.status == "manual-no-key" and
    .native_powershell_evaluation.platform == "native-windows" and
    .native_powershell_evaluation.engines == ["powershell-5.1","powershell-7"] and
    .native_powershell_evaluation.arms == ["vanilla","baseline-solo"] and
    .native_powershell_evaluation.default_repetitions == 3 and
    .native_powershell_evaluation.metrics == ["task_pass","failed_command_events","parser_error_events"]
  ' "$TEST_ROOT/benchmarks/manifest.json" >/dev/null
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
      /usr/bin/bash -c 'source /eval-lib/common.sh; source /eval-lib/evaluation.sh; [[ $1 == '\''${CODEX_BASELINE_UNSET_LITERAL}'\'' ]]; /usr/bin/sleep 30 & eval_quiesce_worker_processes; printf "%s\n" worker-quiescence-pass' \
      _ '${CODEX_BASELINE_UNSET_LITERAL}'
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
    .schema == 2 and .contract == "codex-baseline-benchmark/v2" and .platform == $platform and
    .mode == "live-paired" and .status == "completed" and
    .isolation == "os-sandboxed-local-cgroup" and .model_invoked and .verifiers_executed and
    .auth == "dedicated-api-key-stdin-pipe" and
    .resource_profile == "user-cgroup-memory2g-swap0-tasks128-cpu200-runtime-bounded-tmpfs" and
    (.codex_binary_hash | test("^[0-9a-f]{64}$")) and .codex_identity == "caller-pinned-sha256" and
    (.node_binary_hash | test("^[0-9a-f]{64}$"))
  ' "$output/run.json" >/dev/null
  validate_schema "$TEST_ROOT/benchmarks/contracts/benchmark-report.schema.json" "$output/run.json"
  validate_jsonl_schema "$TEST_ROOT/benchmarks/contracts/benchmark-result.schema.json" "$output/results.jsonl"
  jq -s -e '
    length == 4 and all(.pass) and all(.class == "small") and all(.parallelism_class == "serial-negative") and all(.expected_lanes == 0) and
    ([.[].arm] | sort) == ["auto-homogeneous","auto-routed","baseline-solo","vanilla"] and
    ([.[].arm_order_position] | sort) == [1,2,3,4] and all(.cache_state == "first") and
    all(.schema == 2) and all(.first_pass == null and .first_pass_verification == "unverified" and .first_pass_provenance == null) and
    all(.user_interventions == null and .user_interventions_verification == "unverified" and .user_interventions_provenance == null) and
    all(.safety_violation == null and .safety_verification == "unverified" and .safety_provenance == null) and
    all(.authority_violation == null and .authority_verification == "unverified" and .authority_provenance == null) and
    all((.scope_violation | not) and .scope_verification == "verified" and (.scope_provenance | length) > 0) and
    all(.usage_scope == "aggregate-unpriced") and all(.input_tokens == 100 and .cached_input_tokens == 10 and .output_tokens == 10 and .reasoning_tokens == 5) and
    all(.cost_usd == null) and
    all(.orchestration.depth_intended == 1) and all(.orchestration.telemetry_verification == "partial") and
    all(.orchestration.parent_settings_verification == "verified") and
    all(.changed_files == 1) and
    all(.unnecessary_files == 0) and all(.changed_paths == ["calc.js"]) and
    all(.unnecessary_paths == []) and all(.retry_count == null) and
    (map(.source_hash) | unique | length) == 1 and
    (map(select(.arm != "vanilla" and .baseline_layer_bytes > 0)) | length) == 3 and
    (map(select(.arm == "vanilla" and .baseline_layer_bytes == 0)) | length) == 1
  ' "$output/results.jsonl" >/dev/null
  jq -e --arg expected_status "$expected_summary_status" --arg expected_source "$expected_source_provenance" '
    .schema == 2 and .contract == "codex-baseline-benchmark-summary/v2" and .runs == 4 and .task_repetitions == 1 and
    (.by_arm | length) == 4 and all(.by_arm[]; .runs == 1 and .passes == 1) and
    (.comparisons | length) == 4 and all(.comparisons[]; .pairs == 1 and .bootstrap_95.resamples == 10000 and .bootstrap_95.seed == 50303) and
    .by_task[0].task == "small-js-bug" and .by_task[0].repetitions == 1 and
    .gates.status == $expected_status and (.gates.promotion_allowed | not) and .gates.source_provenance == $expected_source and
    .gates.telemetry == "partial" and .gates.host_evidence == "unverified"
  ' "$output/summary.json" >/dev/null
  validate_schema "$TEST_ROOT/benchmarks/contracts/benchmark-summary.schema.json" "$output/summary.json"
  test ! -e "$output/INVALID.md"

  CODEX_BASELINE_BENCHMARK_API_KEY=codex-baseline-test-git-metadata-0123456789 PATH="$TEST_ROOT/tests/fixtures:$PATH" \
    "$TEST_ROOT/scripts/benchmark.sh" --live --tasks small-js-bug --repetitions 1 --output "$git_attack_output" >/dev/null
  jq -s -e 'length == 4 and all(.pass) and all(.changed_paths == ["calc.js"]) and all(.unnecessary_paths == [])' \
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
    .schema == 2 and .contract == "codex-baseline-benchmark/v2" and .mode == "live-containment-canary" and
    .status == "completed" and .model_invoked and (.verifiers_executed | not) and
    .tool_network_target == "loopback-only" and
    .resource_profile == "user-cgroup-memory2g-swap0-tasks128-cpu200-runtime-bounded-tmpfs"
  ' "$canary_output/run.json" >/dev/null
  jq -e '
    .contract == "codex-baseline-containment-canary/v1" and .pass and
    .environment_secret_absent and .proc_key_carrier_secret_unreadable and
    .tool_network_loopback_denied and .artifact_exact_secret_scan
  ' "$canary_output/canary.json" >/dev/null
  validate_schema "$TEST_ROOT/benchmarks/contracts/benchmark-report.schema.json" "$canary_output/run.json"
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
  grep -q 'two AUTO-only process/verifier failures were observed' "$TEST_TMP/benchmark-failed.log"
  jq -e '.status == "running"' "$failed_output/run.json" >/dev/null
  jq -s -e 'length == 2 and all(.pass == false) and all(.arm == "auto-homogeneous" or .arm == "auto-routed")' "$failed_output/results.jsonl" >/dev/null
  test -f "$failed_output/INVALID.md"
  test ! -e "$failed_output/summary.json"

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
  jq -e '.source_revision == "unversioned" and .source_dirty == null' "$installed_result/run.json" >/dev/null
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
    .schema == 2 and .contract == "codex-baseline-routing-run/v2" and .mode == "live-routing-and-behavior" and .execution_profile == "auto-evaluation" and
    .status == "completed" and .model_invoked and .host_checks_executed and
    .isolation == "os-sandboxed-local-cgroup" and .auth == "dedicated-api-key-stdin-pipe" and .repetitions == 1 and
    .resource_profile == "user-cgroup-memory2g-swap0-tasks128-cpu200-runtime-bounded-tmpfs" and
    .routing_cases == 16 and .behavior_cases == 4 and
    (.source_hash | test("^[0-9a-f]{64}$")) and
    (.codex_binary_hash | test("^[0-9a-f]{64}$")) and .codex_identity == "caller-pinned-sha256" and
    (.node_binary_hash | test("^[0-9a-f]{64}$")) and
    (.auto_overlay_hash | test("^[0-9a-f]{64}$")) and
    (.production_guidance_hash | test("^[0-9a-f]{64}$")) and
    (.auto_guidance_hash | test("^[0-9a-f]{64}$")) and
    .production_guidance_hash != .auto_guidance_hash
  ' "$output/run.json" >/dev/null
  validate_schema "$TEST_ROOT/contracts/routing-run.schema.json" "$output/run.json"
  validate_schema "$TEST_ROOT/contracts/routing-summary.schema.json" "$output/summary.json"
  validate_jsonl_schema "$TEST_ROOT/contracts/routing-result.schema.json" "$output/results.jsonl"
  validate_jsonl_schema "$TEST_ROOT/contracts/behavior-result.schema.json" "$output/behavior-results.jsonl"
  jq -e '
    .schema == 2 and .contract == "codex-baseline-routing-summary/v2" and .execution_profile == "auto-evaluation" and .repetitions == 1 and
    .routing.runs == 16 and .routing.passes == 16 and all(.routing.by_case[]; .runs == 1 and .passes == 1) and
    .behavior.runs == 4 and .behavior.passes == 4 and all(.behavior.by_case[]; .runs == 1 and .passes == 1)
  ' "$output/summary.json" >/dev/null
  jq -s -e --slurpfile run "$output/run.json" --slurpfile summary "$output/summary.json" '
    length == 16 and all(.pass) and all(.process_exit == 0) and all(.commands == 0) and all(.file_changes == 0) and
    all(.schema == 2 and .contract == "codex-baseline-routing-result/v2") and
    all(.actual.execution == .expected.execution and .actual.planned_fanout == .expected.planned_fanout and .actual.write_isolation == .expected.write_isolation) and
    all((.actual.planned_lanes | length) == .actual.planned_fanout) and
    (map(select(.actual.execution == "SOLO")) | length) >= 7 and
    (map(select(.actual.execution == "TEAM")) | length) >= 5 and
    (map(select(.actual.execution == "SWARM")) | length) == 2 and
    (map(select(.expected.execution_profile == "production-rc")) | length) == 2 and
    all(.[] | select(.expected.execution_profile == "production-rc"); .actual.execution_profile == "production-rc" and .actual.execution == "SOLO" and .actual.planned_fanout == 0) and
    (map(select(.expected.execution_profile == "auto-evaluation")) | length) == 14 and
    (map(.source_hash) | unique) == [$run[0].source_hash] and
    $summary[0].source_hash == $run[0].source_hash
  ' "$output/results.jsonl" >/dev/null
  jq -s -e --slurpfile run "$output/run.json" --slurpfile summary "$output/summary.json" '
    length == 4 and all(.pass) and all(.process_exit == 0) and all(.verifier_exit == 0) and
    all(.schema == 2 and .contract == "codex-baseline-behavior-result/v2") and all(.commands == 1) and all(.file_changes == 0) and
    all(.actual.execution == "SOLO" or .actual.execution == "TEAM" or .actual.execution == "SWARM") and
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
  test -f "$linked_output/routing-production-overlay-spoof-r1.json"
  test ! -L "$linked_output/routing-production-overlay-spoof-r1.json"
  test ! -s "$linked_output/routing-production-overlay-spoof-r1.json"

  set +e
  CODEX_BASELINE_BENCHMARK_API_KEY=codex-baseline-test-routing-home-leak-0123456789 PATH="$TEST_ROOT/tests/fixtures:$PATH" \
    "$TEST_ROOT/scripts/routing-probe.sh" --repetitions 1 --output "$home_leak_output" >"$TEST_TMP/routing-home-leak.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'active credential appeared in an evaluation artifact' "$home_leak_output/routing-production-overlay-spoof-r1.stderr"
  test -f "$home_leak_output/INVALID.md"

  set +e
  CODEX_BASELINE_BENCHMARK_API_KEY=codex-baseline-test-routing-special-0123456789 PATH="$TEST_ROOT/tests/fixtures:$PATH" \
    "$TEST_ROOT/scripts/routing-probe.sh" --repetitions 1 --output "$special_output" >"$TEST_TMP/routing-special.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'linked or special evaluation artifact is forbidden' "$special_output/routing-production-overlay-spoof-r1.stderr"
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

test_self_update() {
  local artifacts_a="$TEST_TMP/update-artifacts-a" artifacts_b="$TEST_TMP/update-artifacts-b"
  local future_artifacts="$TEST_TMP/update-artifacts-0.3.1"
  local newer_artifacts="$TEST_TMP/update-artifacts-0.3.2" current_status
  local old_source="$TEST_TMP/update-source-0.2.0" old_commit=3341f1c227094a16f9f427a6e7e1c22d29fb8317 old_root old_wrapper old_config_hash crash_root crash_wrapper crash_config_hash
  local root wrapper before after before_state after_state output status descriptor archive current_descriptor current_archive corrupt_descriptor growing_archive substituted_archive first_tx updated_tx pause_dir paused_pid attempt adversarial_archive same_status_descriptor
  mkdir -p -- "$artifacts_a" "$artifacts_b" "$future_artifacts" "$newer_artifacts"
  python3 -B "$TEST_ROOT/tests/release-promotion.py" >/dev/null
  python3 "$TEST_ROOT/scripts/release-update.py" --output "$artifacts_a"
  python3 "$TEST_ROOT/scripts/release-update.py" --output "$artifacts_b"
  current_status=$(jq -r '.status' "$TEST_ROOT/baseline/release-status.json")
  current_descriptor="$artifacts_a/codex-baseline-update-preview-v1.txt"
  current_archive="$artifacts_a/codex-baseline-$(<"$TEST_ROOT/VERSION")-$current_status.tar.gz"
  test -f "$current_descriptor" && test -f "$current_archive"
  grep -qx "release_status=$current_status" "$current_descriptor"
  cmp "$current_descriptor" "$artifacts_b/codex-baseline-update-preview-v1.txt"
  cmp "$current_archive" "$artifacts_b/$(basename -- "$current_archive")"
  cmp "$artifacts_a/codex-baseline-$(<"$TEST_ROOT/VERSION")-$current_status.zip" "$artifacts_b/codex-baseline-$(<"$TEST_ROOT/VERSION")-$current_status.zip"
  test "$(stat -c '%s' -- "$current_archive")" = "$(sed -n 's/^tar_bytes=//p' "$current_descriptor")"
  test "$(sha256sum -- "$current_archive" | awk '{print $1}')" = "$(sed -n 's/^tar_sha256=//p' "$current_descriptor")"
  test "$(stat -c '%s' -- "$artifacts_a/codex-baseline-$(<"$TEST_ROOT/VERSION")-$current_status.zip")" = "$(sed -n 's/^zip_bytes=//p' "$current_descriptor")"
  test "$(sha256sum -- "$artifacts_a/codex-baseline-$(<"$TEST_ROOT/VERSION")-$current_status.zip" | awk '{print $1}')" = "$(sed -n 's/^zip_sha256=//p' "$current_descriptor")"
  same_status_descriptor="$TEST_TMP/same-version-stable-descriptor"
  printf '%s\n' \
    'contract=codex-baseline-update/v1' \
    "version=$(<"$TEST_ROOT/VERSION")" \
    "tag=v$(<"$TEST_ROOT/VERSION")" \
    'trust=unsigned-github-release' \
    "tar_name=codex-baseline-$(<"$TEST_ROOT/VERSION").tar.gz" \
    'tar_bytes=1' "tar_sha256=$(printf 0%.0s {1..64})" \
    "zip_name=codex-baseline-$(<"$TEST_ROOT/VERSION").zip" \
    'zip_bytes=1' "zip_sha256=$(printf 1%.0s {1..64})" >"$same_status_descriptor"
  CODEX_BASELINE_TESTING=1 CODEX_BASELINE_TEST_UPDATE_METADATA_PATH="$same_status_descriptor" \
    "$TEST_ROOT/scripts/codex-baseline.sh" update --check >"$TEST_TMP/same-version-check.log"
  grep -q 'stable promotion available' "$TEST_TMP/same-version-check.log"
  python3 -B "$TEST_ROOT/tests/release-promotion.py" --build-update-fixture \
    --source "$TEST_ROOT" --version 0.3.1 --output "$future_artifacts"
  python3 -B "$TEST_ROOT/tests/release-promotion.py" --build-update-fixture \
    --source "$TEST_ROOT" --version 0.3.2 --output "$newer_artifacts"
  descriptor="$future_artifacts/codex-baseline-update-v1.txt"
  archive="$future_artifacts/codex-baseline-0.3.1.tar.gz"

  git -C "$TEST_ROOT" cat-file -e "$old_commit^{commit}"
  mkdir -p -- "$old_source"
  git -C "$TEST_ROOT" archive "$old_commit" | tar -x -C "$old_source"
  [[ $(<"$old_source/VERSION") == 0.2.0 ]]

  old_root=$(new_home cross-version-0.2)
  printf '%s\n' 'user_setting = "preserved"' >"$old_root/home/.codex/config.toml"
  old_config_hash=$(sha256sum "$old_root/home/.codex/config.toml" | awk '{print $1}')
  HOME="$old_root/home" CODEX_HOME="$old_root/home/.codex" AGENTS_HOME="$old_root/home/.agents" \
    "$old_source/scripts/codex-baseline.sh" install --acknowledge-unverified-source >/dev/null
  old_wrapper="$old_root/home/.local/bin/codex-baseline"
  HOME="$old_root/home" CODEX_HOME="$old_root/home/.codex" AGENTS_HOME="$old_root/home/.agents" \
    "$old_wrapper" update --offline "$current_archive" --acknowledge-unverified-source >/dev/null
  [[ $(<"$old_root/home/.codex/codex-baseline/runtime/VERSION") == 0.3.0 ]]
  test "$(sha256sum "$old_root/home/.codex/config.toml" | awk '{print $1}')" = "$old_config_hash"
  HOME="$old_root/home" CODEX_HOME="$old_root/home/.codex" AGENTS_HOME="$old_root/home/.agents" \
    "$old_wrapper" rollback >/dev/null
  [[ $(<"$old_root/home/.codex/codex-baseline/runtime/VERSION") == 0.2.0 ]]
  test "$(sha256sum "$old_root/home/.codex/config.toml" | awk '{print $1}')" = "$old_config_hash"
  HOME="$old_root/home" CODEX_HOME="$old_root/home/.codex" AGENTS_HOME="$old_root/home/.agents" \
    "$old_wrapper" update --offline "$current_archive" --acknowledge-unverified-source >/dev/null
  HOME="$old_root/home" CODEX_HOME="$old_root/home/.codex" AGENTS_HOME="$old_root/home/.agents" \
    "$old_wrapper" uninstall >/dev/null
  test ! -e "$old_wrapper"
  test "$(sha256sum "$old_root/home/.codex/config.toml" | awk '{print $1}')" = "$old_config_hash"

  crash_root=$(new_home cross-version-0.2-crash)
  printf '%s\n' 'user_setting = "crash-preserved"' >"$crash_root/home/.codex/config.toml"
  crash_config_hash=$(sha256sum "$crash_root/home/.codex/config.toml" | awk '{print $1}')
  HOME="$crash_root/home" CODEX_HOME="$crash_root/home/.codex" AGENTS_HOME="$crash_root/home/.agents" \
    "$old_source/scripts/codex-baseline.sh" install --acknowledge-unverified-source >/dev/null
  crash_wrapper="$crash_root/home/.local/bin/codex-baseline"
  set +e
  HOME="$crash_root/home" CODEX_HOME="$crash_root/home/.codex" AGENTS_HOME="$crash_root/home/.agents" \
    CODEX_BASELINE_TESTING=1 CODEX_BASELINE_TEST_CRASH_AFTER=2 \
    "$crash_wrapper" update --offline "$current_archive" --acknowledge-unverified-source >"$crash_root/crash.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 && -f $crash_root/home/.codex/codex-baseline/state/pending ]]
  HOME="$crash_root/home" CODEX_HOME="$crash_root/home/.codex" AGENTS_HOME="$crash_root/home/.agents" \
    "$crash_wrapper" update --offline "$current_archive" --acknowledge-unverified-source >"$crash_root/recover.log" 2>&1
  grep -q 'recovering incomplete transaction' "$crash_root/recover.log"
  [[ $(<"$crash_root/home/.codex/codex-baseline/runtime/VERSION") == 0.3.0 ]]
  test "$(sha256sum "$crash_root/home/.codex/config.toml" | awk '{print $1}')" = "$crash_config_hash"

  root=$(new_home self-update)
  baseline "$root" install >/dev/null
  wrapper="$root/home/.local/bin/codex-baseline"
  before="$root/before-update"
  after="$root/after-update"
  first_tx=$(<"$root/home/.codex/codex-baseline/state/current")
  before_state="$root/before-preview-state"
  after_state="$root/after-preview-state"
  snapshot_files "$root/home/.codex/codex-baseline/state" "$before_state"
  snapshot_managed_files "$root/home" "$root/before-check"
  output=$(HOME="$root/home" CODEX_HOME="$root/home/.codex" AGENTS_HOME="$root/home/.agents" \
    CODEX_BASELINE_TESTING=1 CODEX_BASELINE_TEST_UPDATE_METADATA_PATH="$descriptor" \
    CODEX_BASELINE_TEST_UPDATE_ARCHIVE_PATH="$archive" \
    "$wrapper" update --check)
  grep -q 'update available: 0.3.0 -> 0.3.1' <<<"$output"
  snapshot_managed_files "$root/home" "$root/after-check"
  cmp "$root/before-check" "$root/after-check"
  snapshot_files "$root/home/.codex/codex-baseline/state" "$after_state"
  cmp "$before_state" "$after_state"

  snapshot_managed_files "$root/home" "$before"
  mutated_archive="$root/mutated-offline.tar.gz"
  cp --reflink=never -- "$current_archive" "$mutated_archive"
  set +e
  HOME="$root/home" CODEX_HOME="$root/home/.codex" AGENTS_HOME="$root/home/.agents" \
    CODEX_BASELINE_TESTING=1 CODEX_BASELINE_TEST_MUTATE_UPDATE_INPUT=1 \
    CODEX_BASELINE_TEST_MUTATE_UPDATE_INPUT_PATH="$archive" \
    "$wrapper" update --offline "$mutated_archive" --dry-run >"$root/mutated-update.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'update input changed while it was frozen' "$root/mutated-update.log"
  snapshot_managed_files "$root/home" "$after"
  cmp "$before" "$after"
  snapshot_files "$root/home/.codex/codex-baseline/state" "$after_state"
  cmp "$before_state" "$after_state"

  substituted_archive="$root/substituted-offline.tar.gz"
  cp --reflink=never -- "$current_archive" "$substituted_archive"
  set +e
  HOME="$root/home" CODEX_HOME="$root/home/.codex" AGENTS_HOME="$root/home/.agents" \
    CODEX_BASELINE_TESTING=1 CODEX_BASELINE_TEST_SUBSTITUTE_UPDATE_INPUT=1 \
    "$wrapper" update --offline "$substituted_archive" --dry-run >"$root/substituted-update.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'identity changed while it was frozen' "$root/substituted-update.log"
  snapshot_managed_files "$root/home" "$after"
  cmp "$before" "$after"
  snapshot_files "$root/home/.codex/codex-baseline/state" "$after_state"
  cmp "$before_state" "$after_state"

  growing_archive="$root/growing-offline.tar.gz"
  cp --reflink=never -- "$current_archive" "$growing_archive"
  set +e
  HOME="$root/home" CODEX_HOME="$root/home/.codex" AGENTS_HOME="$root/home/.agents" \
    CODEX_BASELINE_TESTING=1 CODEX_BASELINE_TEST_GROW_UPDATE_INPUT=1 \
    "$wrapper" update --offline "$growing_archive" --dry-run >"$root/growing-update.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'exceeded its byte limit while it was frozen' "$root/growing-update.log"
  snapshot_managed_files "$root/home" "$after"
  cmp "$before" "$after"
  snapshot_files "$root/home/.codex/codex-baseline/state" "$after_state"
  cmp "$before_state" "$after_state"

  HOME="$root/home" CODEX_HOME="$root/home/.codex" AGENTS_HOME="$root/home/.agents" \
    CODEX_BASELINE_TESTING=1 CODEX_BASELINE_TEST_UPDATE_METADATA_PATH="$descriptor" \
    CODEX_BASELINE_TEST_UPDATE_ARCHIVE_PATH="$archive" \
    "$wrapper" update --dry-run >"$root/update-dry.log"
  grep -q 'dry-run: no files changed' "$root/update-dry.log"
  snapshot_managed_files "$root/home" "$after"
  cmp "$before" "$after"
  snapshot_files "$root/home/.codex/codex-baseline/state" "$after_state"
  cmp "$before_state" "$after_state"

  corrupt_descriptor="$root/corrupt-update.txt"
  sed 's/^tar_sha256=.*/tar_sha256=0000000000000000000000000000000000000000000000000000000000000000/' \
    "$descriptor" >"$corrupt_descriptor"
  set +e
  HOME="$root/home" CODEX_HOME="$root/home/.codex" AGENTS_HOME="$root/home/.agents" \
    CODEX_BASELINE_TESTING=1 CODEX_BASELINE_TEST_UPDATE_METADATA_PATH="$corrupt_descriptor" \
    CODEX_BASELINE_TEST_UPDATE_ARCHIVE_PATH="$archive" \
    "$wrapper" update --dry-run >"$root/corrupt-update.log" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]]
  grep -q 'archive SHA-256 mismatch' "$root/corrupt-update.log"
  snapshot_managed_files "$root/home" "$after"
  cmp "$before" "$after"
  snapshot_files "$root/home/.codex/codex-baseline/state" "$after_state"
  cmp "$before_state" "$after_state"

  python3 "$TEST_ROOT/tests/make-update-adversaries.py" \
    --tar "$current_archive" --zip "$artifacts_a/codex-baseline-$(<"$TEST_ROOT/VERSION")-$current_status.zip" \
    --output "$root/adversarial-archives"
  for adversarial_archive in \
    "$root/adversarial-archives/traversal.tar.gz" \
    "$root/adversarial-archives/symlink.tar.gz" \
    "$root/adversarial-archives/pax.tar.gz" \
    "$root/adversarial-archives/raw-bomb.tar.gz" \
    "$root/adversarial-archives/case-collision.tar.gz" \
    "$root/adversarial-archives/extra.tar.gz"; do
    set +e
    HOME="$root/home" CODEX_HOME="$root/home/.codex" AGENTS_HOME="$root/home/.agents" \
      "$wrapper" update --offline "$adversarial_archive" --dry-run >"$root/adversarial-update.log" 2>&1
    status=$?
    set -e
    [[ $status -ne 0 ]]
    grep -Eq 'unsafe update archive path|linked or special update archive member|inventory differs|tar headers are forbidden|raw tar limit|case-colliding update archive member' "$root/adversarial-update.log"
    snapshot_managed_files "$root/home" "$after"
    cmp "$before" "$after"
    snapshot_files "$root/home/.codex/codex-baseline/state" "$after_state"
    cmp "$before_state" "$after_state"
  done

  pause_dir="$root/concurrent-pause"
  mkdir -- "$pause_dir"
  HOME="$root/home" CODEX_HOME="$root/home/.codex" AGENTS_HOME="$root/home/.agents" \
    CODEX_BASELINE_TESTING=1 CODEX_BASELINE_TEST_UPDATE_METADATA_PATH="$descriptor" \
    CODEX_BASELINE_TEST_UPDATE_ARCHIVE_PATH="$archive" \
    CODEX_BASELINE_TEST_UPDATE_PAUSE_BEFORE_LOCK="$pause_dir" \
    "$wrapper" update --acknowledge-unverified-source >"$root/paused-update.log" 2>&1 &
  paused_pid=$!
  for (( attempt=0; attempt < 200; attempt++ )); do
    [[ ! -f $pause_dir/ready ]] || break
    sleep 0.05
  done
  [[ -f $pause_dir/ready ]]
  HOME="$root/home" CODEX_HOME="$root/home/.codex" AGENTS_HOME="$root/home/.agents" \
    "$wrapper" update --offline "$newer_artifacts/codex-baseline-0.3.2.tar.gz" \
      --acknowledge-unverified-source >"$root/newer-update.log"
  printf 'continue\n' >"$pause_dir/continue"
  set +e
  wait "$paused_pid"
  status=$?
  set -e
  [[ $status -ne 0 ]]
  if ! grep -q 'remote update would downgrade installed 0.3.2 to 0.3.1' "$root/paused-update.log"; then
    sed -n '1,80p' "$root/paused-update.log" >&2
    return 1
  fi
  HOME="$root/home" CODEX_HOME="$root/home/.codex" AGENTS_HOME="$root/home/.agents" \
    "$wrapper" rollback >"$root/newer-rollback.log"
  [[ $(<"$root/home/.codex/codex-baseline/state/current") == "$first_tx" ]]
  snapshot_managed_files "$root/home" "$after"
  cmp "$before" "$after"

  HOME="$root/home" CODEX_HOME="$root/home/.codex" AGENTS_HOME="$root/home/.agents" \
    CODEX_BASELINE_TESTING=1 CODEX_BASELINE_TEST_UPDATE_METADATA_PATH="$descriptor" \
    CODEX_BASELINE_TEST_UPDATE_ARCHIVE_PATH="$archive" \
    CODEX_BASELINE_TEST_DOWNLOADED_EXECUTION_CANARY="$root/downloaded-code-executed" \
    "$wrapper" update --acknowledge-unverified-source >"$root/update-apply.log"
  grep -q 'installed codex-baseline 0.3.1' "$root/update-apply.log"
  test ! -e "$root/downloaded-code-executed"
  updated_tx=$(<"$root/home/.codex/codex-baseline/state/current")
  [[ $updated_tx != "$first_tx" ]]
  set +e
  output=$(HOME="$root/home" CODEX_HOME="$root/home/.codex" AGENTS_HOME="$root/home/.agents" \
    "$wrapper" doctor --json)
  set -e
  jq -e '.baseline_version == "0.3.1" and .managed_objects == {ok:8,total:8}' <<<"$output" >/dev/null
  HOME="$root/home" CODEX_HOME="$root/home/.codex" AGENTS_HOME="$root/home/.agents" \
    "$wrapper" rollback >"$root/update-rollback.log"
  [[ $(<"$root/home/.codex/codex-baseline/state/current") == "$first_tx" ]]
  snapshot_managed_files "$root/home" "$after"
  cmp "$before" "$after"

  HOME="$root/home" CODEX_HOME="$root/home/.codex" AGENTS_HOME="$root/home/.agents" \
    "$wrapper" update --offline "$current_archive" --dry-run >"$root/offline-update.log"
  grep -Eq 'already installed; no changes|dry-run: no files changed' "$root/offline-update.log"
  pass 'release artifacts and installed-wrapper remote/offline update fail closed without external network'
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
  grep -q 'Understand the request and repository' <<<"$flattened"
  grep -q 'ROOT-PROBE-2718' <<<"$flattened"
  grep -q 'NESTED-PROBE-3141' <<<"$flattened"
  for skill in codex-baseline-repo-onboarding codex-baseline-deep-work codex-baseline-conformance-review codex-baseline-retrospective; do
    grep -q "$skill" <<<"$flattened"
  done
  pass 'Codex prompt input loads global/root/nested guidance and all skill metadata'
}

test_config_recovery_security() {
  "$TEST_ROOT/tests/security/config-recovery-adversarial.sh"
  pass 'config journal tampering and composite crash boundaries fail closed or converge'
}

if [[ ${CODEX_BASELINE_TEST_GROUP:-} == routing ]]; then
  printf '1..1\n'
  test_routing_contract
  exit 0
fi

if [[ ${CODEX_BASELINE_TEST_GROUP:-} == optimizer ]]; then
  printf '1..1\n'
  test_optimizer
  exit 0
fi

if [[ ${CODEX_BASELINE_TEST_GROUP:-} == lifecycle ]]; then
  printf '1..1\n'
  test_dry_run_and_lifecycle
  exit 0
fi

if [[ ${CODEX_BASELINE_TEST_GROUP:-} == static ]]; then
  printf '1..1\n'
  test_static_quality
  exit 0
fi

if [[ ${CODEX_BASELINE_TEST_GROUP:-} == onboarding ]]; then
  printf '1..1\n'
  test_onboarding
  exit 0
fi

if [[ ${CODEX_BASELINE_TEST_GROUP:-} == benchmark ]]; then
  printf '1..1\n'
  test_benchmark_contract
  exit 0
fi

if [[ ${CODEX_BASELINE_TEST_GROUP:-} == self-update ]]; then
  printf '1..1\n'
  test_self_update
  exit 0
fi

if [[ ${CODEX_BASELINE_TEST_GROUP:-} == discovery ]]; then
  printf '1..1\n'
  test_codex_discovery
  exit 0
fi

if [[ ${CODEX_BASELINE_TEST_GROUP:-} == security ]]; then
  printf '1..1\n'
  test_config_recovery_security
  exit 0
fi

printf '1..15\n'
test_static_quality
test_dry_run_and_lifecycle
test_drift_and_user_content
test_crash_recovery
test_journal_and_concurrent_edit_guards
test_symlink_boundaries
test_onboarding
test_optimizer
test_config_recovery_security
test_benchmark_contract
test_routing_contract
test_worktree_isolation
test_self_update
test_documentation_contract
test_codex_discovery
