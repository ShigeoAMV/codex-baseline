import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', '..');
const summarizer = path.join(root, 'benchmarks', 'summarize.mjs');
const schemaValidator = path.join(root, 'tests', 'validate-json-schema.py');
const python = process.env.PYTHON || (process.platform === 'win32' ? 'python' : 'python3');
const arms = ['vanilla', 'baseline-solo', 'auto-homogeneous', 'auto-routed'];
const overlayHash = '358511cdb2018098f2c513c666520cd9c588362c4dc8ff825aad66ffea21974b';
const adapterHash = '6'.repeat(64);
const payloadHash = '9'.repeat(64);
const tasks = [
  ['small-js-bug', 'small', 'serial-negative', 0],
  ['small-config-timeout', 'small', 'serial-negative', 0],
  ['small-doc-port', 'small', 'serial-negative', 0],
  ['risk-migration', 'risk-sensitive', 'serial-negative', 0],
  ['medium-js-feature', 'medium', 'parallel-positive', 2],
  ['medium-dedup-reproduction', 'medium', 'parallel-positive', 2],
  ['medium-id-refactor', 'medium', 'parallel-positive', 3],
  ['large-architecture', 'large', 'parallel-positive', 4],
  ['large-feature-flags', 'large', 'parallel-positive', 4],
  ['six-lane-packages', 'large', 'parallel-positive', 6]
];

function sha256(value) {
  return createHash('sha256').update(value).digest('hex');
}

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])]));
  }
  return value;
}

function profileHash(profile) {
  return sha256(JSON.stringify(canonical(profile)));
}

function makeManifest({adapter = true, releaseStatus = 'rc.1'} = {}) {
  return {
    schema: 2,
    suite: 'codex-baseline-autonomous-execution',
    preregistered: '2026-08-15',
    review_by: '2026-09-15',
    release_status: releaseStatus,
    promotion_target: 'stable-0.3.0',
    default_repetitions: 10,
    arms,
    run_order: 'stable-four-arm-rotation-by-task-and-repetition',
    bootstrap_resamples: 10000,
    auto_overlay: {path: 'benchmarks/auto-execution.overlay.md', sha256: overlayHash},
    runtime_telemetry_adapter: adapter ? {contract: 'codex-runtime-telemetry/v1', sha256: adapterHash} : null,
    app_server_telemetry: {
      contract: 'codex-app-server-telemetry/v1', checked_codex_cli: '0.147.0',
      runner: {path: 'benchmarks/runtime/app-server-runner.mjs', sha256: '4'.repeat(64)},
      reducer: {path: 'benchmarks/runtime/app-server-telemetry.mjs', sha256: '5'.repeat(64)},
      live_probe: 'synthetic-test-fixture'
    },
    runtime_telemetry_capability: adapter
      ? {status: 'available', checked_at: '2026-08-16', checked_codex_cli: '0.147.0', blocker: null}
      : {status: 'unavailable', checked_at: '2026-08-16', checked_codex_cli: '0.147.0',
          blocker: 'codex exec --json lacks authoritative orchestration events'},
    profiles: {
      vanilla: {guidance: 'absent', agents_enabled: null, agent_cap: null, auto_overlay: false, child_model_policy: 'account-default'},
      'baseline-solo': {guidance: 'installed', agents_enabled: false, agent_cap: 0, auto_overlay: false, child_model_policy: 'not-applicable'},
      'auto-homogeneous': {guidance: 'installed-plus-auto-overlay', agents_enabled: true, agent_cap: 6, auto_overlay: true, child_model_policy: 'inherit-parent'},
      'auto-routed': {guidance: 'installed-plus-auto-overlay', agents_enabled: true, agent_cap: 6, auto_overlay: true, child_model_policy: 'automatic'}
    },
    isolation: {}, metrics: [],
    tasks: tasks.map(([id, taskClass, parallelismClass, expectedLanes]) => ({
      id, class: taskClass, visibility: 'development', parallelism_class: parallelismClass,
      expected_lanes: expectedLanes, allowed_changed_paths: ['file']
    }))
  };
}

const evidence = verified => verified ? {
  first_pass: true, first_pass_verification: 'verified', first_pass_provenance: 'test-host-verifier',
  user_interventions: 0, user_interventions_verification: 'verified', user_interventions_provenance: 'test-host-verifier',
  safety_violation: false, safety_verification: 'verified', safety_provenance: 'test-host-verifier',
  authority_violation: false, authority_verification: 'verified', authority_provenance: 'test-host-verifier'
} : {
  first_pass: null, first_pass_verification: 'unverified', first_pass_provenance: null,
  user_interventions: null, user_interventions_verification: 'unverified', user_interventions_provenance: null,
  safety_violation: null, safety_verification: 'unverified', safety_provenance: null,
  authority_violation: null, authority_verification: 'unverified', authority_provenance: null
};

function makeRuns(manifest, {hostVerified = true, telemetryVerified = true} = {}) {
  const runs = [];
  for (const [task, taskClass, parallelismClass, expectedLanes] of tasks) {
    for (let repetition = 1; repetition <= 10; repetition++) {
      for (const [armIndex, arm] of arms.entries()) {
        const positive = parallelismClass === 'parallel-positive';
        const elapsed = positive
          ? {vanilla: 120, 'baseline-solo': 100, 'auto-homogeneous': 80, 'auto-routed': 50}[arm]
          : 100;
        const auto = arm.startsWith('auto-');
        const execution = arm === 'baseline-solo' || (auto && !positive)
          ? 'SOLO'
          : auto && positive ? expectedLanes <= 3 ? 'TEAM' : 'SWARM' : null;
        const fanout = execution === 'SWARM' || execution === 'TEAM' ? expectedLanes : execution === 'SOLO' ? 0 : null;
        const telemetry = auto && telemetryVerified && manifest.runtime_telemetry_adapter !== null;
        runs.push({
          schema: 2, task, class: taskClass, parallelism_class: parallelismClass,
          expected_lanes: expectedLanes, arm, arm_order_position: armIndex + 1,
          cache_state: repetition === 1 ? 'first' : 'subsequent', repetition,
          pass: true, ...evidence(hostVerified), scope_violation: false,
          scope_verification: 'verified', scope_provenance: 'host-git-scope-allowlist/v1',
          process_exit: 0, verifier_exit: 0, elapsed_ms: elapsed,
          turns: 1, commands: 1, file_changes: 1, changed_files: 1,
          unnecessary_files: 0, changed_paths: ['file'], unnecessary_paths: [],
          failed_command_events: 0, raw_subagent_events: execution === 'SWARM' ? fanout : 0,
          input_tokens: 10, cached_input_tokens: 0, output_tokens: 10, reasoning_tokens: 10,
          usage_scope: 'aggregate', cost_usd: 0, baseline_layer_bytes: arm === 'vanilla' ? 0 : 1,
          retry_count: 0, review_findings: 0,
          last_message_bytes: 20, added_lines: 4, added_code_lines: 4, added_comment_lines: 0,
          added_prose_lines: 0, added_blank_lines: 0, duplicate_added_lines: 0, pure_comment_diff: false,
          hygiene_verification: 'verified', hygiene_provenance: 'host-git-diff-objective/v1',
          release_version: '0.3.0', payload_hash: payloadHash,
          evaluation_profile: arm,
          evaluation_profile_hash: profileHash(manifest.profiles[arm]),
          auto_overlay_hash: auto ? manifest.auto_overlay.sha256 : null,
          agent_guidance_hash: arm === 'vanilla' ? null : `${armIndex + 1}`.repeat(64),
          configured_agent_cap: arm === 'vanilla' ? null : arm === 'baseline-solo' ? 0 : 6,
          orchestration: {
            execution, selection_reason: 'test', planned_fanout: fanout,
            planned_lane_ids: telemetry ? Array.from({length: fanout || 0}, (_, index) => `lane-${index + 1}`) : null,
            actual_fanout: fanout, available_capacity: auto ? 6 : arm === 'baseline-solo' ? 0 : null,
            agents: telemetry ? Array.from({length: fanout || 0}, (_, index) => ({
              id: `agent-${index + 1}`, lane_id: `lane-${index + 1}`, requested_model: 'test', actual_model: 'test',
              requested_effort: 'test', actual_effort: 'test', status: 'completed'
            })) : execution === 'SOLO' && telemetry ? [] : null,
            depth_intended: 1, depth_observed: telemetry ? (execution === 'SWARM' ? 1 : 0) : null,
            depth_verification: telemetry ? 'verified' : 'unverified',
            waves_planned: execution === 'SWARM' ? 1 : execution === 'SOLO' ? 0 : null,
            waves_observed: telemetry ? (execution === 'SWARM' ? 1 : 0) : null,
            waves_verification: telemetry ? 'verified' : 'unverified',
            peak_concurrency: telemetry ? (execution === 'SWARM' ? fanout + 1 : 1) : null,
            peak_concurrency_verification: telemetry ? 'verified' : 'unverified',
            spawn_errors: telemetry ? [] : null, fallbacks: telemetry ? 0 : null,
            interrupts: telemetry ? 0 : null, timeouts: telemetry ? 0 : null,
            conflicts: telemetry ? 0 : null, integration_rework_events: telemetry ? 0 : null,
            handoff_bytes: telemetry ? 0 : null, duplicated_context_bytes: telemetry ? 0 : null,
            write_isolation: telemetry ? 'single-writer' : 'unverified', test_isolation: telemetry ? 'serial' : 'unverified',
            parent_before: {model: telemetry ? 'test' : null, effort: telemetry ? 'test' : null, speed: telemetry ? 'standard' : null},
            parent_after: {model: telemetry ? 'test' : null, effort: telemetry ? 'test' : null, speed: telemetry ? 'standard' : null},
            parent_settings_verification: telemetry ? 'verified' : 'unverified',
            telemetry_verification: telemetry ? 'verified' : 'unverified',
            telemetry_adapter_hash: telemetry ? manifest.runtime_telemetry_adapter.sha256 : null,
            telemetry_provenance: telemetry ? `runtime-telemetry-adapter-sha256:${manifest.runtime_telemetry_adapter.sha256}` : null
          },
          isolation: 'os-sandboxed-local-cgroup', source_hash: '0'.repeat(64),
          layer_hash: arm === 'vanilla' ? 'vanilla' : '1'.repeat(64),
          arm_config_hash: (auto ? 'c' : arm === 'baseline-solo' ? 'b' : 'a').repeat(64), fixture_hash: '3'.repeat(64),
          prompt_hash: '4'.repeat(64), verifier_hash: '5'.repeat(64)
        });
      }
    }
  }
  return runs;
}

function summarize(runs, manifest, {dirty = false, revision = 'a'.repeat(40), status = 'completed'} = {}) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-baseline-benchmark-truth-'));
  try {
    const input = path.join(directory, 'results.jsonl');
    fs.writeFileSync(input, `${runs.map(run => JSON.stringify(run)).join('\n')}\n`);
    const manifestPath = path.join(directory, 'manifest.json');
    fs.writeFileSync(manifestPath, `${JSON.stringify(manifest)}\n`);
    const runPath = path.join(directory, 'run.json');
    fs.writeFileSync(runPath, `${JSON.stringify({
      schema: 2, contract: 'codex-baseline-benchmark/v2', platform: 'linux', mode: 'live-paired',
      status, isolation: 'os-sandboxed-local-cgroup', model_invoked: true,
      verifiers_executed: true, created: '2026-08-15T12:00:00Z', codex: 'codex 0.147.0',
      model: 'test', source_revision: revision, source_dirty: dirty, source_hash: '0'.repeat(64),
      manifest_hash: sha256(fs.readFileSync(manifestPath)), codex_binary_hash: '7'.repeat(64),
      codex_identity: 'caller-pinned-sha256', node_binary_hash: '8'.repeat(64),
      auth: 'dedicated-api-key-stdin-pipe', account_service_tier: 'unknown',
      runtime_telemetry_adapter_contract: manifest.runtime_telemetry_adapter?.contract ?? null,
      runtime_telemetry_adapter_hash: manifest.runtime_telemetry_adapter?.sha256 ?? null,
      resource_profile: 'user-cgroup-memory2g-swap0-tasks128-cpu200-runtime-bounded-tmpfs'
    })}\n`);
    const representative = path.join(directory, 'result.json');
    fs.writeFileSync(representative, `${JSON.stringify(runs.at(-1))}\n`);
    execFileSync(python, [schemaValidator, path.join(root, 'benchmarks', 'contracts', 'benchmark-result.schema.json'), representative], {stdio: 'pipe'});
    const summary = JSON.parse(execFileSync(process.execPath, [summarizer, input, runPath, manifestPath],
      {encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']}));
    const summaryPath = path.join(directory, 'summary.json');
    fs.writeFileSync(summaryPath, `${JSON.stringify(summary)}\n`);
    execFileSync(python, [schemaValidator, path.join(root, 'benchmarks', 'contracts', 'benchmark-summary.schema.json'), summaryPath], {stdio: 'pipe'});
    return summary;
  } finally {
    fs.rmSync(directory, {recursive: true, force: true});
  }
}

function assertResultSchemaRejects(result) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-baseline-benchmark-result-'));
  try {
    const resultPath = path.join(directory, 'result.json');
    fs.writeFileSync(resultPath, `${JSON.stringify(result)}\n`);
    assert.throws(() => execFileSync(python,
      [schemaValidator, path.join(root, 'benchmarks', 'contracts', 'benchmark-result.schema.json'), resultPath],
      {stdio: 'pipe'}));
  } finally {
    fs.rmSync(directory, {recursive: true, force: true});
  }
}

const promotionManifest = makeManifest();
const verified = makeRuns(promotionManifest);
const passing = summarize(verified, promotionManifest);
assert.equal(passing.gates.status, 'passed');
assert.equal(passing.gates.promotion_allowed, true);
assert.equal(passing.gates.execution_success, 'passed');
assert.equal(passing.gates.run_parity, 'passed');
assert.equal(passing.gates.source_provenance, 'passed');
assert.equal(passing.gates.profile_provenance, 'passed');
assert.equal(passing.gates.six_lane_capacity, 'passed');
assert.equal(passing.gates.smallest_effective_team, 'passed');
assert.equal(passing.provenance.source_revision, 'a'.repeat(40));
assert.equal(passing.provenance.source_dirty, false);
assert.equal(passing.provenance.release_status, 'rc.1');
assert.equal(passing.provenance.version, '0.3.0');
assert.equal(passing.provenance.candidate_status, 'rc.1');
assert.equal(passing.provenance.payload_hash, payloadHash);
assert.equal(passing.provenance.run_receipt_status, 'completed');
assert.match(passing.provenance.run_receipt_hash, /^[0-9a-f]{64}$/);

const productionManifest = makeManifest({adapter: false});
const noAdapter = summarize(makeRuns(productionManifest, {telemetryVerified: false}), productionManifest);
assert.equal(noAdapter.gates.status, 'unverified');
assert.equal(noAdapter.gates.promotion_allowed, false);
assert.equal(noAdapter.gates.telemetry, 'unverified');
assert.equal(noAdapter.gates.promotion_capability, 'unavailable');
assert.match(noAdapter.gates.reasons.join('\n'), /capability is unavailable/);

const allFailed = makeRuns(promotionManifest);
for (const run of allFailed) {
  run.pass = false; run.first_pass = false; run.process_exit = 1; run.verifier_exit = 1;
}
const failedExecution = summarize(allFailed, promotionManifest);
assert.equal(failedExecution.gates.execution_success, 'failed');
assert.equal(failedExecution.gates.promotion_allowed, false);

assert.throws(() => summarize(verified.slice(1), promotionManifest), /incomplete four-arm group|run parity/i);
assert.throws(() => summarize(verified, promotionManifest, {status: 'running'}), /run receipt contract/i);
const duplicate = structuredClone(verified);
duplicate.push(structuredClone(duplicate[0]));
assert.throws(() => summarize(duplicate, promotionManifest), /duplicate benchmark result/i);

const dirty = summarize(verified, promotionManifest, {dirty: true});
assert.equal(dirty.gates.source_provenance, 'failed');
assert.equal(dirty.gates.promotion_allowed, false);

const sourceMismatch = structuredClone(verified);
sourceMismatch[0].source_hash = 'f'.repeat(64);
assert.throws(() => summarize(sourceMismatch, promotionManifest), /source hash/i);

const payloadMismatch = structuredClone(verified);
payloadMismatch[0].payload_hash = 'e'.repeat(64);
assert.throws(() => summarize(payloadMismatch, promotionManifest), /release provenance mismatch/i);

const absolutePassMismatch = structuredClone(verified);
absolutePassMismatch[0].process_exit = 1;
assert.throws(() => summarize(absolutePassMismatch, promotionManifest), /pass\/process\/verifier mismatch/i);

const sixLaneRegression = structuredClone(verified);
for (const run of sixLaneRegression.filter(run => run.task === 'six-lane-packages' && run.arm === 'auto-routed')) {
  run.orchestration.actual_fanout = 5;
  run.orchestration.peak_concurrency = 6;
  run.orchestration.agents.pop();
}
const failedSixLane = summarize(sixLaneRegression, promotionManifest);
assert.equal(failedSixLane.gates.six_lane_capacity, 'failed');
assert.equal(failedSixLane.gates.promotion_allowed, false);

const profileDrift = structuredClone(verified);
profileDrift[0].evaluation_profile_hash = 'f'.repeat(64);
assert.throws(() => summarize(profileDrift, promotionManifest), /evaluation profile mismatch/i);

const nonCausalOverlay = structuredClone(verified);
for (const group of new Set(nonCausalOverlay.map(run => `${run.task}\0${run.repetition}`))) {
  const [task, repetition] = group.split('\0');
  const solo = nonCausalOverlay.find(run => run.task === task && run.repetition === Number(repetition) && run.arm === 'baseline-solo');
  nonCausalOverlay.find(run => run.task === task && run.repetition === Number(repetition) && run.arm === 'auto-routed').agent_guidance_hash = solo.agent_guidance_hash;
}
assert.throws(() => summarize(nonCausalOverlay, promotionManifest), /profile\/overlay causality/i);

const swappedProfile = structuredClone(verified);
swappedProfile.find(run => run.arm === 'auto-homogeneous').evaluation_profile = 'auto-routed';
assert.throws(() => summarize(swappedProfile, promotionManifest), /evaluation profile mismatch/i);

const contradictoryCapacity = structuredClone(verified);
const capacityRun = contradictoryCapacity.find(run => run.task === 'six-lane-packages' && run.arm === 'auto-routed');
capacityRun.orchestration.available_capacity = 5;
assert.throws(() => summarize(contradictoryCapacity, promotionManifest), /fanout\/capacity telemetry is contradictory/i);

const duplicatePlannedLane = structuredClone(verified);
const laneRun = duplicatePlannedLane.find(run => run.task === 'large-architecture' && run.arm === 'auto-routed');
laneRun.orchestration.planned_lane_ids[1] = laneRun.orchestration.planned_lane_ids[0];
assert.throws(() => summarize(duplicatePlannedLane, promotionManifest), /fanout\/capacity telemetry is contradictory/i);

const overProvisionedPositive = structuredClone(verified);
const overProvisionedRun = overProvisionedPositive.find(run =>
  run.task === 'medium-js-feature' && run.arm === 'auto-routed');
overProvisionedRun.orchestration.execution = 'SWARM';
overProvisionedRun.orchestration.planned_fanout = 6;
overProvisionedRun.orchestration.actual_fanout = 6;
overProvisionedRun.orchestration.planned_lane_ids = Array.from({length: 6}, (_, index) => `lane-${index + 1}`);
overProvisionedRun.orchestration.agents = Array.from({length: 6}, (_, index) => ({
  id: `agent-${index + 1}`, lane_id: `lane-${index + 1}`, requested_model: 'test', actual_model: 'test',
  requested_effort: 'test', actual_effort: 'test', status: 'completed'
}));
overProvisionedRun.orchestration.peak_concurrency = 7;
assertResultSchemaRejects(overProvisionedRun);
assert.throws(() => summarize(overProvisionedPositive, promotionManifest), /smallest-effective-team|manifest lane/i);

const parallelizedSerial = structuredClone(verified);
const parallelizedSerialRun = parallelizedSerial.find(run =>
  run.task === 'small-js-bug' && run.arm === 'auto-homogeneous');
parallelizedSerialRun.orchestration.execution = 'TEAM';
parallelizedSerialRun.orchestration.planned_fanout = 1;
parallelizedSerialRun.orchestration.actual_fanout = 1;
parallelizedSerialRun.orchestration.available_capacity = 6;
parallelizedSerialRun.orchestration.planned_lane_ids = ['lane-1'];
parallelizedSerialRun.orchestration.agents = [{
  id: 'agent-1', lane_id: 'lane-1', requested_model: 'test', actual_model: 'test',
  requested_effort: 'test', actual_effort: 'test', status: 'completed'
}];
parallelizedSerialRun.orchestration.depth_observed = 1;
parallelizedSerialRun.orchestration.waves_planned = 1;
parallelizedSerialRun.orchestration.waves_observed = 1;
parallelizedSerialRun.orchestration.peak_concurrency = 2;
assertResultSchemaRejects(parallelizedSerialRun);
assert.throws(() => summarize(parallelizedSerial, promotionManifest), /smallest-effective-team|manifest lane/i);

const retryMismatch = structuredClone(verified);
retryMismatch.find(run => run.task === 'medium-js-feature' && run.arm === 'auto-routed').retry_count = 1;
assert.throws(() => summarize(retryMismatch, promotionManifest), /retry\/depth\/concurrency telemetry is contradictory/i);

const unverifiableUsage = structuredClone(verified);
const soloUsage = unverifiableUsage.find(run => run.task === 'small-js-bug' && run.arm === 'baseline-solo');
soloUsage.input_tokens = null;
soloUsage.cached_input_tokens = null;
soloUsage.output_tokens = null;
soloUsage.reasoning_tokens = null;
soloUsage.usage_scope = 'unverified';
soloUsage.cost_usd = null;
const usageBlocked = summarize(unverifiableUsage, promotionManifest);
assert.equal(usageBlocked.gates.non_dominated, 'unverified');
assert.equal(usageBlocked.gates.promotion_allowed, false);

const hygieneRegression = structuredClone(verified);
for (const run of hygieneRegression.filter(run => run.task === 'medium-js-feature' && run.arm === 'auto-routed')) {
  run.added_lines += 1;
}
const failedHygiene = summarize(hygieneRegression, promotionManifest);
assert.equal(failedHygiene.gates.hygiene, 'failed');
assert.equal(failedHygiene.gates.promotion_allowed, false);

const promptDrift = structuredClone(verified);
promptDrift.find(run => run.task === 'small-js-bug' && run.repetition === 1 && run.arm === 'auto-routed').prompt_hash = 'e'.repeat(64);
assert.throws(() => summarize(promptDrift, promotionManifest), /task input parity mismatch/i);

const missingHost = summarize(makeRuns(promotionManifest, {hostVerified: false}), promotionManifest);
assert.equal(missingHost.gates.host_evidence, 'unverified');
assert.equal(missingHost.gates.promotion_allowed, false);

const safetyViolation = structuredClone(verified);
safetyViolation[0].safety_violation = true;
const failedSafety = summarize(safetyViolation, promotionManifest);
assert.equal(failedSafety.gates.authority_safety_scope, 'failed');
assert.equal(failedSafety.gates.promotion_allowed, false);

process.stdout.write('benchmark truth/provenance tests passed\n');
