#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/codex-baseline-telemetry-test.XXXXXX")
trap 'status=$?; if (( status != 0 )); then find "$TMP/output" -name "telemetry-*.stderr.log" -type f -maxdepth 1 -exec sed -n "1,40p" {} \; >&2; find "$TMP/output" -name "telemetry-*.json" -type f -maxdepth 1 -exec sed -n "1,5p" {} \; >&2; fi; rm -rf -- "$TMP"' EXIT

# Source without running main. Privileged Bash startup mode is the runner's
# own environment-sanitizing invariant, not an OS privilege escalation.
source "$ROOT/scripts/benchmark.sh"
# The focused contract test exercises the networkless read-only Bubblewrap
# command itself. Aggregate cgroup enforcement is covered by the live runner's
# existing evaluation-boundary tests.
eval_run_scoped_command() { shift; "$@"; }

mkdir -p -- "$TMP/eval/benchmarks" "$TMP/output" "$TMP/arm"
adapter_source="$ROOT/tests/benchmark/runtime-telemetry-adapter.sh"
[[ -f $adapter_source && ! -L $adapter_source && -x $adapter_source ]] || {
  printf 'runtime telemetry test adapter is not an executable regular file\n' >&2
  exit 1
}
adapter_hash=$(cb_sha256_file "$adapter_source")
jq -nc --arg hash "$adapter_hash" \
  '{runtime_telemetry_adapter:{contract:"codex-runtime-telemetry/v1",sha256:$hash},
    runtime_telemetry_capability:{status:"available",checked_at:"2026-08-16",checked_codex_cli:"0.147.0",blocker:null},
    tasks:[{id:"sample",parallelism_class:"parallel-positive",expected_lanes:4}]}' \
  >"$TMP/eval/benchmarks/manifest.json"
BENCH_EVAL_ROOT="$TMP/eval"
BENCH_OUTPUT="$TMP/output"
BENCH_TELEMETRY_ADAPTER_INPUT="$adapter_source"
BENCH_EXPECTED_TELEMETRY_ADAPTER_HASH="$adapter_hash"
bench_prepare_telemetry_adapter

source_hash=$(printf source | cb_sha256_text)
config_hash=$(printf config | cb_sha256_text)
jq -nc --arg hash "$(printf profile | cb_sha256_text)" \
  '{evaluation_profile:"auto-routed",evaluation_profile_hash:$hash,auto_overlay_hash:null,agent_guidance_hash:null,configured_agent_cap:6}' \
  >"$TMP/arm/profile.json"
printf '%s\n' '{"status":"running"}' >"$TMP/output/run.json"
printf '%s\n' done >"$TMP/output/last.txt"

write_events() {
  local test_case=$1
  jq -nc --arg test_case "$test_case" '
    {type:"runtime.telemetry",test_case:$test_case,orchestration:{
      execution:"SWARM",selection_reason:"four independent lanes",planned_lane_ids:["lane-a","lane-b","lane-c","lane-d"],
      planned_fanout:4,actual_fanout:4,available_capacity:6,
      agents:[range(0;4) as $i | {id:("agent-"+($i|tostring)),lane_id:("lane-"+(["a","b","c","d"][$i])),
        requested_model:"test",actual_model:"test",requested_effort:"medium",actual_effort:"medium",status:"completed"}],
      depth_intended:1,depth_observed:1,waves_planned:1,waves_observed:1,peak_concurrency:5,
      spawn_errors:[],fallbacks:0,interrupts:0,timeouts:0,conflicts:0,integration_rework_events:0,
      handoff_bytes:128,duplicated_context_bytes:0,write_isolation:"single-writer",test_isolation:"serial",
      parent_before:{model:"test",effort:"medium",speed:"standard"},parent_after:{model:"test",effort:"medium",speed:"standard"}}}'
  jq -nc '{type:"turn.completed",usage:{input_tokens:100,cached_input_tokens:10,output_tokens:20,reasoning_tokens:5,usage_scope:"aggregate",cost_usd:0.01}}'
}

write_events valid >"$TMP/output/events.jsonl"
receipt=$(bench_runtime_telemetry sample 1 auto-routed "$TMP/output/events.jsonl" "$TMP/output/last.txt" \
  "$TMP/arm/profile.json" "$source_hash" "$config_hash" 6)
jq -e '.usage.usage_scope == "aggregate" and .usage.input_tokens == 100 and
  .orchestration.telemetry_verification == "verified" and .orchestration.planned_lane_ids == ["lane-a","lane-b","lane-c","lane-d"]' \
  <<<"$receipt" >/dev/null

for test_case in inflated replay contradictory extra; do
  write_events "$test_case" >"$TMP/output/events.jsonl"
  if (bench_runtime_telemetry sample 1 auto-routed "$TMP/output/events.jsonl" "$TMP/output/last.txt" \
      "$TMP/arm/profile.json" "$source_hash" "$config_hash" 6 >/dev/null 2>&1); then
    printf 'runtime telemetry negative case unexpectedly passed: %s\n' "$test_case" >&2
    exit 1
  fi
done

write_events valid | jq -c 'if .type == "runtime.telemetry" then
  .orchestration.execution = "SWARM" |
  .orchestration.planned_fanout = 6 |
  .orchestration.actual_fanout = 6 |
  .orchestration.planned_lane_ids = ["lane-a","lane-b","lane-c","lane-d","lane-e","lane-f"] |
  .orchestration.agents += [
    {id:"agent-4",lane_id:"lane-e",requested_model:"test",actual_model:"test",requested_effort:"medium",actual_effort:"medium",status:"completed"},
    {id:"agent-5",lane_id:"lane-f",requested_model:"test",actual_model:"test",requested_effort:"medium",actual_effort:"medium",status:"completed"}] |
  .orchestration.peak_concurrency = 7
  else . end' >"$TMP/output/events.jsonl"
if (bench_runtime_telemetry sample 1 auto-routed "$TMP/output/events.jsonl" "$TMP/output/last.txt" \
    "$TMP/arm/profile.json" "$source_hash" "$config_hash" 6 >/dev/null 2>&1); then
  printf 'runtime telemetry adapter accepted six planned lanes for a four-lane task\n' >&2
  exit 1
fi

write_events valid | jq -c 'if .type == "turn.completed" then .usage |= del(.usage_scope) else . end' >"$TMP/output/events.jsonl"
usage=$(bench_host_usage "$TMP/output/events.jsonl")
jq -e '.usage_scope == "unverified" and .input_tokens == null and .cost_usd == null' <<<"$usage" >/dev/null
receipt=$(bench_runtime_telemetry sample 1 auto-routed "$TMP/output/events.jsonl" "$TMP/output/last.txt" \
  "$TMP/arm/profile.json" "$source_hash" "$config_hash" 6)
jq -e '.usage.usage_scope == "unverified" and .usage.input_tokens == null and
  .orchestration.telemetry_verification == "verified"' <<<"$receipt" >/dev/null

if (BENCH_MODE=static; BENCH_MODE_SET=0; BENCH_TELEMETRY_ADAPTER_INPUT=''; BENCH_EXPECTED_TELEMETRY_ADAPTER_HASH='';
    bench_parse --static --runtime-telemetry-adapter "$adapter_source" \
      --expected-runtime-telemetry-adapter-sha256 "$adapter_hash" >/dev/null 2>&1); then
  printf 'static mode accepted a runtime telemetry adapter\n' >&2
  exit 1
fi
if (BENCH_MODE=static; BENCH_MODE_SET=0; BENCH_TELEMETRY_ADAPTER_INPUT=''; BENCH_EXPECTED_TELEMETRY_ADAPTER_HASH='';
    bench_parse --live --runtime-telemetry-adapter "$adapter_source" >/dev/null 2>&1); then
  printf 'runtime telemetry adapter path was accepted without its hash\n' >&2
  exit 1
fi

manifest_hash=$(cb_sha256_file "$TMP/eval/benchmarks/manifest.json")
jq -nc --arg hash "$manifest_hash" '{manifest_hash:$hash}' >"$TMP/arm/completed-run.json"
bench_stage_frozen_manifest "$TMP/arm/completed-run.json" "$TMP/output/benchmark-manifest.json"
cmp -s -- "$TMP/eval/benchmarks/manifest.json" "$TMP/output/benchmark-manifest.json" || {
  printf 'staged benchmark manifest bytes differ from the evaluated manifest\n' >&2
  exit 1
}
jq -nc --arg hash "$(printf mismatch | cb_sha256_text)" '{manifest_hash:$hash}' >"$TMP/arm/bad-run.json"
if (bench_stage_frozen_manifest "$TMP/arm/bad-run.json" "$TMP/output/bad-benchmark-manifest.json" >/dev/null 2>&1); then
  printf 'mismatched benchmark manifest was staged\n' >&2
  exit 1
fi

jq '.runtime_telemetry_adapter.sha256 = ("0" * 64)' "$TMP/eval/benchmarks/manifest.json" >"$TMP/eval/benchmarks/manifest.next"
mv -- "$TMP/eval/benchmarks/manifest.next" "$TMP/eval/benchmarks/manifest.json"
if (BENCH_TELEMETRY_ADAPTER=''; BENCH_TELEMETRY_ADAPTER_HASH=''; bench_prepare_telemetry_adapter >/dev/null 2>&1); then
  printf 'runtime telemetry adapter was accepted against a different manifest hash\n' >&2
  exit 1
fi

printf 'runtime telemetry adapter boundary tests passed\n'
