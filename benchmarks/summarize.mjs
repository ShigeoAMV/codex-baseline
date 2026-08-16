import {createHash} from 'node:crypto';
import fs from 'node:fs';

const [resultsPath, runPath, manifestPath] = process.argv.slice(2);
if (!resultsPath || !runPath || !manifestPath) {
  throw new Error('usage: node summarize.mjs RESULTS.jsonl RUN.json MANIFEST.json');
}

const sha256 = value => createHash('sha256').update(value).digest('hex');
const loadObject = (path, label) => {
  const value = JSON.parse(fs.readFileSync(path, 'utf8'));
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error(`${label} must be a JSON object`);
  return value;
};
const canonical = value => {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])]));
  }
  return value;
};
const profileHash = profile => sha256(JSON.stringify(canonical(profile)));
const isHash = value => typeof value === 'string' && /^[0-9a-f]{64}$/.test(value);

const resultBytes = fs.readFileSync(resultsPath);
const resultText = resultBytes.toString('utf8');
const lines = resultText.split(/\r?\n/).filter(Boolean);
if (!lines.length) throw new Error('benchmark result set is empty');
const runs = lines.map((line, index) => {
  try { return JSON.parse(line); }
  catch (error) { throw new Error(`invalid benchmark result JSON at line ${index + 1}: ${error.message}`); }
});
const runReceiptBytes = fs.readFileSync(runPath);
const runReceipt = loadObject(runPath, 'benchmark run receipt');
const manifestBytes = fs.readFileSync(manifestPath);
const manifest = JSON.parse(manifestBytes.toString('utf8'));

if (manifest.schema !== 2 || !Array.isArray(manifest.arms) || !Array.isArray(manifest.tasks)) {
  throw new Error('benchmark manifest contract is invalid');
}
const arms = manifest.arms;
const requiredArms = ['vanilla', 'baseline-solo', 'auto-homogeneous', 'auto-routed'];
if (JSON.stringify(arms) !== JSON.stringify(requiredArms)) throw new Error('benchmark manifest arm contract is invalid');
if (!Number.isInteger(manifest.default_repetitions) || manifest.default_repetitions < 1) {
  throw new Error('benchmark manifest repetition contract is invalid');
}
if (!manifest.profiles || typeof manifest.profiles !== 'object' ||
    !requiredArms.every(arm => manifest.profiles[arm] && typeof manifest.profiles[arm] === 'object')) {
  throw new Error('benchmark manifest profile contract is invalid');
}
if (!manifest.auto_overlay || !isHash(manifest.auto_overlay.sha256) || typeof manifest.auto_overlay.path !== 'string') {
  throw new Error('benchmark manifest AUTO overlay contract is invalid');
}
if (manifest.runtime_telemetry_adapter !== null &&
    (!manifest.runtime_telemetry_adapter ||
     JSON.stringify(Object.keys(manifest.runtime_telemetry_adapter).sort()) !== '["contract","sha256"]' ||
     manifest.runtime_telemetry_adapter.contract !== 'codex-runtime-telemetry/v1' ||
     !isHash(manifest.runtime_telemetry_adapter.sha256))) {
  throw new Error('benchmark runtime telemetry adapter contract is invalid');
}
const telemetryCapability = manifest.runtime_telemetry_capability;
if (!telemetryCapability || typeof telemetryCapability !== 'object' || Array.isArray(telemetryCapability) ||
    JSON.stringify(Object.keys(telemetryCapability).sort()) !== '["blocker","checked_at","checked_codex_cli","status"]' ||
    !['available', 'unavailable'].includes(telemetryCapability.status) ||
    typeof telemetryCapability.checked_at !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(telemetryCapability.checked_at) ||
    typeof telemetryCapability.checked_codex_cli !== 'string' || !/^\d+\.\d+\.\d+$/.test(telemetryCapability.checked_codex_cli) ||
    !((manifest.runtime_telemetry_adapter === null && telemetryCapability.status === 'unavailable' &&
       typeof telemetryCapability.blocker === 'string' && telemetryCapability.blocker.length > 0) ||
      (manifest.runtime_telemetry_adapter !== null && telemetryCapability.status === 'available' &&
       telemetryCapability.blocker === null))) {
  throw new Error('benchmark runtime telemetry capability contract is invalid');
}
const taskMap = new Map();
for (const task of manifest.tasks) {
  if (!task || typeof task.id !== 'string' || taskMap.has(task.id)) throw new Error('benchmark manifest task inventory is invalid');
  taskMap.set(task.id, task);
}

if (runReceipt.schema !== 2 || runReceipt.contract !== 'codex-baseline-benchmark/v2' ||
    runReceipt.mode !== 'live-paired' || runReceipt.status !== 'completed' ||
    runReceipt.model_invoked !== true || runReceipt.verifiers_executed !== true ||
    runReceipt.isolation !== 'os-sandboxed-local-cgroup') {
  throw new Error('benchmark run receipt contract is invalid');
}
const actualManifestHash = sha256(manifestBytes);
if (runReceipt.manifest_hash !== actualManifestHash) throw new Error('benchmark run manifest hash mismatch');
const registeredAdapter = manifest.runtime_telemetry_adapter;
const expectedAdapterContract = registeredAdapter?.contract ?? null;
const expectedAdapterHash = registeredAdapter?.sha256 ?? null;
const runAdapterContract = runReceipt.runtime_telemetry_adapter_contract ?? null;
const runAdapterHash = runReceipt.runtime_telemetry_adapter_hash ?? null;
if (!((runAdapterContract === null && runAdapterHash === null) ||
      (runAdapterContract === expectedAdapterContract && runAdapterHash === expectedAdapterHash))) {
  throw new Error('benchmark run telemetry adapter provenance mismatch');
}
if (!isHash(runReceipt.source_hash)) throw new Error('benchmark run source hash is invalid');
let releaseVersion = null;
let payloadHash = null;

const expectedArms = new Set(arms);
const groups = new Map();
const observedTasks = new Set();
const assertRuntimeSemantics = (result, taskContract) => {
  if (result.schema !== 2 || result.pass !== (result.process_exit === 0 && result.verifier_exit === 0)) {
    throw new Error(`benchmark result pass/process/verifier mismatch: ${result.task} r${result.repetition} ${result.arm}`);
  }
  if (result.first_pass === true && result.pass !== true) {
    throw new Error(`benchmark result first-pass contradiction: ${result.task} r${result.repetition} ${result.arm}`);
  }
  const hygieneIntegers = ['last_message_bytes', 'added_lines', 'added_code_lines', 'added_comment_lines',
    'added_prose_lines', 'added_blank_lines', 'duplicate_added_lines'];
  if (result.hygiene_verification !== 'verified' || result.hygiene_provenance !== 'host-git-diff-objective/v1' ||
      hygieneIntegers.some(key => !Number.isInteger(result[key]) || result[key] < 0) ||
      typeof result.pure_comment_diff !== 'boolean') {
    throw new Error(`benchmark hygiene telemetry is invalid: ${result.task} r${result.repetition} ${result.arm}`);
  }
  if ((taskContract.parallelism_class === 'serial-negative') !== (taskContract.expected_lanes === 0) ||
      (taskContract.parallelism_class === 'parallel-positive' &&
       (!Number.isInteger(taskContract.expected_lanes) || taskContract.expected_lanes < 2 || taskContract.expected_lanes > 6))) {
    throw new Error(`benchmark manifest lane contract is invalid: ${result.task}`);
  }
  if (result.cache_state !== (result.repetition === 1 ? 'first' : 'subsequent')) {
    throw new Error(`benchmark result cache-state mismatch: ${result.task} r${result.repetition} ${result.arm}`);
  }
  if (result.evaluation_profile !== result.arm || result.evaluation_profile_hash !== profileHash(manifest.profiles[result.arm])) {
    throw new Error(`benchmark evaluation profile mismatch: ${result.task} r${result.repetition} ${result.arm}`);
  }
  const auto = result.arm.startsWith('auto-');
  const expectedCap = result.arm === 'vanilla' ? null : result.arm === 'baseline-solo' ? 0 : 6;
  if (result.configured_agent_cap !== expectedCap ||
      (auto ? result.auto_overlay_hash !== manifest.auto_overlay.sha256 : result.auto_overlay_hash !== null) ||
      (result.arm === 'vanilla' ? result.agent_guidance_hash !== null : !isHash(result.agent_guidance_hash))) {
    throw new Error(`benchmark profile provenance mismatch: ${result.task} r${result.repetition} ${result.arm}`);
  }
  const receipt = result.orchestration;
  if (!receipt || typeof receipt !== 'object' || Array.isArray(receipt)) {
    throw new Error(`benchmark orchestration receipt is invalid: ${result.task} r${result.repetition} ${result.arm}`);
  }
  if (receipt.telemetry_verification !== 'verified') return;
  const adapter = manifest.runtime_telemetry_adapter;
  if (!adapter || adapter.contract !== 'codex-runtime-telemetry/v1' ||
      receipt.telemetry_adapter_hash !== adapter.sha256 ||
      receipt.telemetry_provenance !== `runtime-telemetry-adapter-sha256:${adapter.sha256}`) {
    throw new Error(`benchmark telemetry adapter provenance mismatch: ${result.task} r${result.repetition} ${result.arm}`);
  }
  const integers = ['planned_fanout', 'actual_fanout', 'available_capacity', 'depth_observed',
    'waves_observed', 'peak_concurrency', 'fallbacks', 'interrupts', 'timeouts', 'conflicts',
    'integration_rework_events', 'handoff_bytes', 'duplicated_context_bytes'];
  const invalidIntegers = integers.filter(key => !Number.isInteger(receipt[key]) || receipt[key] < 0);
  if (invalidIntegers.length ||
      !Array.isArray(receipt.planned_lane_ids) || !Array.isArray(receipt.agents) || !Array.isArray(receipt.spawn_errors) ||
      receipt.depth_verification !== 'verified' || receipt.waves_verification !== 'verified' ||
      receipt.peak_concurrency_verification !== 'verified' || receipt.parent_settings_verification !== 'verified') {
    throw new Error(`verified benchmark telemetry is incomplete${invalidIntegers.length ? ` (${invalidIntegers.join(',')})` : ''}: ${result.task} r${result.repetition} ${result.arm}`);
  }
  const expectedExecution = receipt.planned_fanout === 0 ? 'SOLO' : receipt.planned_fanout <= 3 ? 'TEAM' : 'SWARM';
  const configuredCap = result.configured_agent_cap ?? 6;
  if (receipt.execution !== expectedExecution || receipt.planned_fanout > 6 ||
      receipt.actual_fanout > receipt.planned_fanout || receipt.actual_fanout > receipt.available_capacity ||
      receipt.planned_fanout > receipt.available_capacity || receipt.planned_fanout > configuredCap ||
      receipt.agents.length !== receipt.actual_fanout || receipt.planned_lane_ids.length !== receipt.planned_fanout ||
      new Set(receipt.planned_lane_ids).size !== receipt.planned_fanout ||
      receipt.planned_lane_ids.some(lane => typeof lane !== 'string' || !lane)) {
    throw new Error(`benchmark fanout/capacity telemetry is contradictory: ${result.task} r${result.repetition} ${result.arm}`);
  }
  if (auto && (receipt.planned_fanout !== taskContract.expected_lanes ||
      receipt.planned_lane_ids.length !== taskContract.expected_lanes ||
      (taskContract.parallelism_class === 'serial-negative' && receipt.execution !== 'SOLO') ||
      (taskContract.parallelism_class === 'parallel-positive' && receipt.execution === 'SOLO'))) {
    throw new Error(`benchmark smallest-effective-team telemetry does not match manifest lanes: ${result.task} r${result.repetition} ${result.arm}`);
  }
  const ids = new Set();
  const lanes = new Set();
  for (const agent of receipt.agents) {
    if (!agent || typeof agent.id !== 'string' || !agent.id || typeof agent.lane_id !== 'string' || !agent.lane_id ||
        typeof agent.actual_model !== 'string' || !agent.actual_model ||
        typeof agent.actual_effort !== 'string' || !agent.actual_effort ||
        !['completed', 'failed', 'interrupted', 'timeout'].includes(agent.status) ||
        ids.has(agent.id) || lanes.has(agent.lane_id) || !receipt.planned_lane_ids.includes(agent.lane_id)) {
      throw new Error(`benchmark child identity telemetry is contradictory: ${result.task} r${result.repetition} ${result.arm}`);
    }
    ids.add(agent.id); lanes.add(agent.lane_id);
  }
  if (!receipt.parent_before || !receipt.parent_after ||
      ['model', 'effort', 'speed'].some(key => typeof receipt.parent_before[key] !== 'string' ||
        !receipt.parent_before[key] || receipt.parent_before[key] !== receipt.parent_after[key])) {
    throw new Error(`benchmark parent settings telemetry is contradictory: ${result.task} r${result.repetition} ${result.arm}`);
  }
  if (result.arm === 'auto-homogeneous' && receipt.agents.some(agent =>
    agent.actual_model !== receipt.parent_before.model || agent.actual_effort !== receipt.parent_before.effort)) {
    throw new Error(`homogeneous-arm model/effort telemetry is not homogeneous: ${result.task} r${result.repetition}`);
  }
  const fallbackAgents = receipt.agents.filter(agent =>
    (agent.requested_model != null && agent.requested_model !== agent.actual_model) ||
    (agent.requested_effort != null && agent.requested_effort !== agent.actual_effort)).length;
  const timedOutAgents = receipt.agents.filter(agent => agent.status === 'timeout').length;
  const interruptedAgents = receipt.agents.filter(agent => agent.status === 'interrupted').length;
  if (receipt.fallbacks !== fallbackAgents || result.retry_count !== receipt.fallbacks ||
      receipt.fallbacks > receipt.spawn_errors.length || receipt.timeouts !== timedOutAgents ||
      receipt.interrupts !== interruptedAgents || receipt.depth_observed > 1 || receipt.waves_observed > 4 ||
      receipt.peak_concurrency < 1 || receipt.peak_concurrency > receipt.actual_fanout + 1) {
    throw new Error(`benchmark retry/depth/concurrency telemetry is contradictory: ${result.task} r${result.repetition} ${result.arm}`);
  }
};
for (const result of runs) {
  if (!result || typeof result !== 'object' || Array.isArray(result)) throw new Error('benchmark result must be an object');
  const taskContract = taskMap.get(result.task);
  if (!taskContract) throw new Error(`benchmark result names an unregistered task: ${result.task}`);
  if (!expectedArms.has(result.arm)) throw new Error(`benchmark result names an invalid arm: ${result.arm}`);
  if (!Number.isInteger(result.repetition) || result.repetition < 1) throw new Error('benchmark result repetition is invalid');
  if (result.source_hash !== runReceipt.source_hash) throw new Error(`benchmark result source hash mismatch: ${result.task} r${result.repetition} ${result.arm}`);
  if (!/^\d+\.\d+\.\d+$/.test(result.release_version) || !isHash(result.payload_hash)) {
    throw new Error(`benchmark release provenance is invalid: ${result.task} r${result.repetition} ${result.arm}`);
  }
  releaseVersion ??= result.release_version;
  payloadHash ??= result.payload_hash;
  if (result.release_version !== releaseVersion || result.payload_hash !== payloadHash) {
    throw new Error(`benchmark release provenance mismatch: ${result.task} r${result.repetition} ${result.arm}`);
  }
  if (result.class !== taskContract.class || result.parallelism_class !== taskContract.parallelism_class ||
      result.expected_lanes !== taskContract.expected_lanes) {
    throw new Error(`benchmark result task contract mismatch: ${result.task}`);
  }
  assertRuntimeSemantics(result, taskContract);
  const key = `${result.task}\0${result.repetition}`;
  if (!groups.has(key)) groups.set(key, new Map());
  const group = groups.get(key);
  if (group.has(result.arm)) throw new Error(`duplicate benchmark result: ${result.task} r${result.repetition} ${result.arm}`);
  group.set(result.arm, result);
  observedTasks.add(result.task);
}
for (const [key, group] of groups) {
  if (group.size !== arms.length || arms.some(arm => !group.has(arm))) throw new Error(`incomplete four-arm group: ${key}`);
  const positions = arms.map(arm => group.get(arm).arm_order_position).sort((a, b) => a - b);
  if (JSON.stringify(positions) !== '[1,2,3,4]') throw new Error(`invalid arm order parity: ${key}`);
  const promptHashes = new Set(arms.map(arm => group.get(arm).prompt_hash));
  const fixtureHashes = new Set(arms.map(arm => group.get(arm).fixture_hash));
  const verifierHashes = new Set(arms.map(arm => group.get(arm).verifier_hash));
  if (promptHashes.size !== 1 || fixtureHashes.size !== 1 || verifierHashes.size !== 1) {
    throw new Error(`task input parity mismatch: ${key}`);
  }
  const solo = group.get('baseline-solo');
  const homogeneous = group.get('auto-homogeneous');
  const routed = group.get('auto-routed');
  if (homogeneous.agent_guidance_hash === solo.agent_guidance_hash ||
      routed.agent_guidance_hash === solo.agent_guidance_hash ||
      homogeneous.arm_config_hash !== routed.arm_config_hash ||
      homogeneous.arm_config_hash === solo.arm_config_hash) {
    throw new Error(`AUTO profile/overlay causality mismatch: ${key}`);
  }
}

const repetitionsByTask = new Map();
for (const task of observedTasks) {
  const repetitions = [...groups.values()]
    .filter(group => group.get('vanilla').task === task)
    .map(group => group.get('vanilla').repetition)
    .sort((a, b) => a - b);
  if (repetitions.some((value, index) => value !== index + 1)) throw new Error(`non-contiguous benchmark repetitions: ${task}`);
  repetitionsByTask.set(task, repetitions.length);
}
if (new Set(repetitionsByTask.values()).size !== 1) throw new Error('benchmark tasks have unequal repetition counts');
const taskRepetitions = Math.min(...repetitionsByTask.values());
const fullTaskInventory = observedTasks.size === taskMap.size && [...taskMap.keys()].every(task => observedTasks.has(task));
const runParityPassed = fullTaskInventory && taskRepetitions === manifest.default_repetitions &&
  runs.length === taskMap.size * manifest.default_repetitions * arms.length;

const median = values => {
  const sorted = [...values].sort((a, b) => a - b);
  const half = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[half] : (sorted[half - 1] + sorted[half]) / 2;
};
const sumNullable = (items, key) => items.some(item => item[key] == null) ? null : items.reduce((total, item) => total + item[key], 0);
const verifiedTruth = (result, key, evidence = key) => result[`${evidence}_verification`] === 'verified' &&
  typeof result[`${evidence}_provenance`] === 'string' && result[`${evidence}_provenance`].length > 0 && result[key] != null;
const booleanRate = (items, key) => items.length && items.every(item => verifiedTruth(item, key))
  ? items.filter(item => item[key] === true).length / items.length
  : null;
const summarizeArm = (arm, source = runs) => {
  const items = source.filter(item => item.arm === arm);
  return {arm, runs: items.length, passes: items.filter(item => item.pass).length,
    pass_rate: items.length ? items.filter(item => item.pass).length / items.length : 0,
    median_elapsed_ms: items.length ? median(items.map(item => item.elapsed_ms)) : 0,
    input_tokens: sumNullable(items, 'input_tokens'), cached_input_tokens: sumNullable(items, 'cached_input_tokens'),
    output_tokens: sumNullable(items, 'output_tokens'), reasoning_tokens: sumNullable(items, 'reasoning_tokens'),
    raw_subagent_events: items.reduce((total, item) => total + item.raw_subagent_events, 0),
    last_message_bytes: items.reduce((total, item) => total + item.last_message_bytes, 0),
    added_lines: items.reduce((total, item) => total + item.added_lines, 0),
    added_code_lines: items.reduce((total, item) => total + item.added_code_lines, 0),
    added_comment_lines: items.reduce((total, item) => total + item.added_comment_lines, 0),
    added_prose_lines: items.reduce((total, item) => total + item.added_prose_lines, 0),
    added_blank_lines: items.reduce((total, item) => total + item.added_blank_lines, 0),
    duplicate_added_lines: items.reduce((total, item) => total + item.duplicate_added_lines, 0),
    pure_comment_diffs: items.filter(item => item.pure_comment_diff).length};
};
const byArm = arms.map(arm => summarizeArm(arm));
const byCacheState = ['first', 'subsequent'].map(cache_state => {
  const items = runs.filter(item => item.cache_state === cache_state);
  return {cache_state, runs: items.length, by_arm: arms.map(arm => summarizeArm(arm, items))};
});

let randomState = 50303;
const random = () => { randomState ^= randomState << 13; randomState ^= randomState >>> 17; randomState ^= randomState << 5; return (randomState >>> 0) / 4294967296; };
const bootstrap = ratios => {
  const values = [];
  for (let sample = 0; sample < manifest.bootstrap_resamples; sample++) {
    const draw = [];
    for (let index = 0; index < ratios.length; index++) draw.push(ratios[Math.floor(random() * ratios.length)]);
    values.push(median(draw));
  }
  values.sort((a, b) => a - b);
  return {resamples: manifest.bootstrap_resamples, low: values[249], high: values[9749], seed: 50303};
};
if (manifest.bootstrap_resamples !== 10000) throw new Error('benchmark bootstrap contract is invalid');
const comparisonSpecs = [
  ['baseline-solo / vanilla', 'baseline-solo', 'vanilla'],
  ['auto-homogeneous / baseline-solo', 'auto-homogeneous', 'baseline-solo'],
  ['auto-routed / baseline-solo', 'auto-routed', 'baseline-solo'],
  ['auto-routed / vanilla', 'auto-routed', 'vanilla']
];
const comparisons = comparisonSpecs.map(([name, numerator, denominator]) => {
  const ratios = [...groups.values()].map(group => group.get(numerator).elapsed_ms / Math.max(1, group.get(denominator).elapsed_ms));
  return {name, numerator, denominator, pairs: ratios.length,
    paired_median_elapsed_ratio: median(ratios), bootstrap_95: bootstrap(ratios)};
});

const taskIds = [...observedTasks].sort();
const byTask = taskIds.map(task => {
  const taskGroups = [...groups.values()].filter(group => group.get('vanilla').task === task);
  const taskRuns = taskGroups.flatMap(group => arms.map(arm => group.get(arm)));
  const vanilla = taskGroups.map(group => group.get('vanilla'));
  const baseline = taskGroups.map(group => group.get('baseline-solo'));
  const homogeneous = taskGroups.map(group => group.get('auto-homogeneous'));
  const routed = taskGroups.map(group => group.get('auto-routed'));
  return {task, class: taskRuns[0].class, parallelism_class: taskRuns[0].parallelism_class,
    expected_lanes: taskRuns[0].expected_lanes, repetitions: baseline.length,
    vanilla_pass_rate: vanilla.filter(item => item.pass).length / vanilla.length,
    solo_pass_rate: baseline.filter(item => item.pass).length / baseline.length,
    homogeneous_pass_rate: homogeneous.filter(item => item.pass).length / homogeneous.length,
    routed_pass_rate: routed.filter(item => item.pass).length / routed.length,
    vanilla_first_pass_rate: booleanRate(vanilla, 'first_pass'),
    solo_first_pass_rate: booleanRate(baseline, 'first_pass'),
    homogeneous_first_pass_rate: booleanRate(homogeneous, 'first_pass'),
    routed_first_pass_rate: booleanRate(routed, 'first_pass'),
    routed_unnecessary_files: routed.reduce((total, item) => total + item.unnecessary_files, 0),
    solo_unnecessary_files: baseline.reduce((total, item) => total + item.unnecessary_files, 0),
    routed_last_message_bytes: routed.reduce((total, item) => total + item.last_message_bytes, 0),
    solo_last_message_bytes: baseline.reduce((total, item) => total + item.last_message_bytes, 0),
    routed_added_lines: routed.reduce((total, item) => total + item.added_lines, 0),
    solo_added_lines: baseline.reduce((total, item) => total + item.added_lines, 0),
    routed_added_code_lines: routed.reduce((total, item) => total + item.added_code_lines, 0),
    solo_added_code_lines: baseline.reduce((total, item) => total + item.added_code_lines, 0),
    routed_added_comment_lines: routed.reduce((total, item) => total + item.added_comment_lines, 0),
    solo_added_comment_lines: baseline.reduce((total, item) => total + item.added_comment_lines, 0),
    routed_added_prose_lines: routed.reduce((total, item) => total + item.added_prose_lines, 0),
    solo_added_prose_lines: baseline.reduce((total, item) => total + item.added_prose_lines, 0),
    routed_added_blank_lines: routed.reduce((total, item) => total + item.added_blank_lines, 0),
    solo_added_blank_lines: baseline.reduce((total, item) => total + item.added_blank_lines, 0),
    routed_duplicate_added_lines: routed.reduce((total, item) => total + item.duplicate_added_lines, 0),
    solo_duplicate_added_lines: baseline.reduce((total, item) => total + item.duplicate_added_lines, 0),
    routed_pure_comment_diffs: routed.filter(item => item.pure_comment_diff).length,
    solo_pure_comment_diffs: baseline.filter(item => item.pure_comment_diff).length,
    routed_solo_median_elapsed_ratio: median(routed.map((item, index) => item.elapsed_ms / Math.max(1, baseline[index].elapsed_ms)))};
});

const reasons = [];
const executionSuccess = runs.every(result => result.pass === true && result.process_exit === 0 && result.verifier_exit === 0);
const cleanRevisionVerified = /^[0-9a-f]{40}$/.test(runReceipt.source_revision) && runReceipt.source_dirty === false;
const releaseStatusPassed = manifest.release_status === 'rc.1' && manifest.promotion_target === 'stable-0.3.0';
let profileProvenancePassed = true;
for (const result of runs) {
  const profile = manifest.profiles[result.arm];
  const auto = result.arm.startsWith('auto-');
  const expectedGuidance = result.arm !== 'vanilla';
  const expectedCap = result.arm === 'vanilla' ? null : result.arm === 'baseline-solo' ? 0 : 6;
  if (result.evaluation_profile !== result.arm || result.evaluation_profile_hash !== profileHash(profile) ||
      result.configured_agent_cap !== expectedCap ||
      (expectedGuidance ? !isHash(result.agent_guidance_hash) : result.agent_guidance_hash !== null) ||
      (auto ? result.auto_overlay_hash !== manifest.auto_overlay.sha256 : result.auto_overlay_hash !== null)) {
    profileProvenancePassed = false;
  }
}
for (const group of groups.values()) {
  if (new Set(arms.map(arm => group.get(arm).prompt_hash)).size !== 1) profileProvenancePassed = false;
}

const adapter = manifest.runtime_telemetry_adapter;
const adapterConfigured = adapter && adapter.contract === 'codex-runtime-telemetry/v1' && isHash(adapter.sha256);
const autoRuns = runs.filter(result => result.arm.startsWith('auto-'));
const telemetryVerified = Boolean(adapterConfigured) && runAdapterContract === adapter.contract &&
  runAdapterHash === adapter.sha256 && autoRuns.every(result =>
  result.orchestration.telemetry_verification === 'verified' &&
  result.orchestration.depth_verification === 'verified' && result.orchestration.depth_observed <= 1 &&
  result.orchestration.waves_verification === 'verified' && result.orchestration.waves_observed <= 4 &&
  result.orchestration.peak_concurrency_verification === 'verified' &&
  result.orchestration.parent_settings_verification === 'verified' &&
  result.orchestration.telemetry_adapter_hash === adapter.sha256 &&
  result.orchestration.telemetry_provenance === `runtime-telemetry-adapter-sha256:${adapter.sha256}`);
const telemetryPartial = autoRuns.some(result => result.orchestration.telemetry_verification === 'partial');
const promotionCapabilityAvailable = telemetryCapability.status === 'available' && Boolean(adapterConfigured);
const smallestEffectiveTeamVerified = telemetryVerified;
const smallestEffectiveTeamPassed = smallestEffectiveTeamVerified && autoRuns.every(result =>
  result.orchestration.planned_fanout === result.expected_lanes &&
  Array.isArray(result.orchestration.planned_lane_ids) &&
  result.orchestration.planned_lane_ids.length === result.expected_lanes &&
  (result.parallelism_class !== 'serial-negative' || result.orchestration.execution === 'SOLO'));
const usageVerified = runs.every(result => result.usage_scope === 'aggregate' &&
  result.input_tokens != null && result.cached_input_tokens != null && result.output_tokens != null &&
  result.reasoning_tokens != null && result.cost_usd != null);
const authorityEvidenceVerified = runs.every(result => verifiedTruth(result, 'safety_violation', 'safety') &&
  verifiedTruth(result, 'authority_violation', 'authority') && result.scope_verification === 'verified' &&
  typeof result.scope_provenance === 'string' && result.scope_provenance.length > 0);
const firstPassEvidenceVerified = runs.every(result => verifiedTruth(result, 'first_pass') && verifiedTruth(result, 'user_interventions'));
const hostEvidenceVerified = authorityEvidenceVerified && firstPassEvidenceVerified;
const verifiedViolation = runs.some(result =>
  (verifiedTruth(result, 'safety_violation', 'safety') && result.safety_violation === true) ||
  (verifiedTruth(result, 'authority_violation', 'authority') && result.authority_violation === true) ||
  (result.scope_verification === 'verified' && result.scope_violation === true));
const authoritySafetyScopePassed = authorityEvidenceVerified && !verifiedViolation;
const qualityPassed = executionSuccess && byTask.every(task =>
  task.routed_pass_rate >= task.solo_pass_rate && task.routed_pass_rate >= task.vanilla_pass_rate);
const firstPassClasses = [...new Set(runs.map(result => result.class))];
const firstPassPassed = firstPassEvidenceVerified && firstPassClasses.every(taskClass => {
  const paired = [...groups.values()].filter(group => group.get('vanilla').class === taskClass);
  const routed = paired.reduce((total, group) => total + Number(group.get('auto-routed').first_pass), 0);
  const solo = paired.reduce((total, group) => total + Number(group.get('baseline-solo').first_pass), 0);
  const vanilla = paired.reduce((total, group) => total + Number(group.get('vanilla').first_pass), 0);
  return routed >= solo && routed >= vanilla;
}) && autoRuns.every(result => result.user_interventions === 0);
const positive = byTask.filter(task => task.parallelism_class === 'parallel-positive');
const serial = byTask.filter(task => task.parallelism_class === 'serial-negative');
const positiveGroups = [...groups.values()].filter(group => group.get('baseline-solo').parallelism_class === 'parallel-positive');
const positiveRatios = positiveGroups.map(group => group.get('auto-routed').elapsed_ms / Math.max(1, group.get('baseline-solo').elapsed_ms));
const positiveBootstrap = positiveRatios.length ? bootstrap(positiveRatios) : {high: 1};
const positiveOverallRatio = positiveRatios.length ? median(positiveRatios) : 1;
const speedPassed = positiveOverallRatio <= 0.75 && positiveBootstrap.high < 1 &&
  positive.filter(task => task.routed_solo_median_elapsed_ratio <= 0.85).length >= 4 &&
  positive.every(task => task.routed_solo_median_elapsed_ratio <= 1.05);
const sixLane = positive.find(task => task.expected_lanes === 6);
const sixPassed = Boolean(sixLane && sixLane.routed_solo_median_elapsed_ratio <= 0.60);
const sixLaneRuns = runs.filter(result => result.task === sixLane?.task && result.arm === 'auto-routed');
const sixLaneCapacityVerified = telemetryVerified && sixLaneRuns.length > 0;
const sixLaneCapacityPassed = sixLaneCapacityVerified && sixLaneRuns.every(result =>
  result.orchestration.execution === 'SWARM' && result.orchestration.planned_fanout === 6 &&
  result.orchestration.actual_fanout === 6 && result.orchestration.available_capacity >= 6 &&
  Array.isArray(result.orchestration.agents) && result.orchestration.agents.length === 6 &&
  result.orchestration.agents.every(agent => agent.status === 'completed'));
const serialRuns = runs.filter(result => result.arm === 'auto-routed' && result.parallelism_class === 'serial-negative');
const serialSolo = serialRuns.filter(result => result.orchestration.execution === 'SOLO').length;
const serialSelectionPassed = serialRuns.length > 0 && serialSolo / serialRuns.length >= 0.95 &&
  serial.every(task => task.routed_solo_median_elapsed_ratio <= 1.05);
const swarmTasks = byTask.filter(task => task.parallelism_class === 'parallel-positive' &&
  runs.some(result => result.task === task.task && result.arm === 'auto-routed' && result.orchestration.execution === 'SWARM'));
const swarmValuePassed = swarmTasks.length > 0 && swarmTasks.every(task =>
  task.routed_solo_median_elapsed_ratio <= 0.70 || task.routed_pass_rate - task.solo_pass_rate >= 0.10);
const dominated = byTask.some(task => {
  const soloRuns = runs.filter(result => result.task === task.task && result.arm === 'baseline-solo');
  const routedRuns = runs.filter(result => result.task === task.task && result.arm === 'auto-routed');
  const effortHigher = usageVerified && routedRuns.reduce((total, result) => total + result.input_tokens + result.output_tokens + result.reasoning_tokens, 0) >
    soloRuns.reduce((total, result) => total + result.input_tokens + result.output_tokens + result.reasoning_tokens, 0);
  return task.routed_pass_rate <= task.solo_pass_rate && task.routed_solo_median_elapsed_ratio >= 1 && effortHigher;
});
const nonDominatedPassed = usageVerified && !dominated;
const hygieneVerified = runs.every(result => result.hygiene_verification === 'verified' &&
  result.hygiene_provenance === 'host-git-diff-objective/v1');
const hygienePassed = hygieneVerified && byTask.every(task =>
  task.routed_unnecessary_files <= task.solo_unnecessary_files &&
  task.routed_last_message_bytes <= task.solo_last_message_bytes &&
  task.routed_added_lines <= task.solo_added_lines &&
  task.routed_added_code_lines <= task.solo_added_code_lines &&
  task.routed_added_comment_lines <= task.solo_added_comment_lines &&
  task.routed_added_prose_lines <= task.solo_added_prose_lines &&
  task.routed_added_blank_lines <= task.solo_added_blank_lines &&
  task.routed_duplicate_added_lines <= task.solo_duplicate_added_lines &&
  task.routed_pure_comment_diffs <= task.solo_pure_comment_diffs) &&
  autoRuns.every(result => result.orchestration.handoff_bytes != null && result.orchestration.duplicated_context_bytes != null);

if (!executionSuccess) reasons.push('one or more arms failed process or verifier execution');
if (!runParityPassed) reasons.push('result set is not the exact preregistered task, repetition, and four-arm inventory');
if (!cleanRevisionVerified) reasons.push('source is not a clean immutable 40-hex revision');
if (!releaseStatusPassed) reasons.push('release status or promotion target does not match rc.1 to stable-0.3.0');
if (!profileProvenancePassed) reasons.push('evaluation profile, AUTO overlay, guidance, cap, or prompt parity is not causally verified');
if (!promotionCapabilityAvailable) reasons.push(`runtime telemetry and stable-promotion capability is unavailable: ${telemetryCapability.blocker}`);
else if (!telemetryVerified) reasons.push('runtime orchestration telemetry is not fully verified by the pinned adapter');
if (smallestEffectiveTeamVerified && !smallestEffectiveTeamPassed) reasons.push('AUTO planned fanout or lane inventory does not match the preregistered task lanes');
if (!usageVerified) reasons.push('aggregate token and effort telemetry is not fully verified');
if (!authorityEvidenceVerified) reasons.push('host-side safety, authority, or scope evidence is not fully verified');
if (verifiedViolation) reasons.push('a verified safety, authority, or scope violation was observed');
if (!firstPassEvidenceVerified) reasons.push('host-side first-pass or user-intervention evidence is not fully verified');
if (runParityPassed && !qualityPassed) reasons.push('absolute success or relative quality gates are not met');
if (firstPassEvidenceVerified && !firstPassPassed) reasons.push('paired first-pass success or zero-intervention gates are not met');
if (runParityPassed && !speedPassed) reasons.push('positive-task speed gates are not met');
if (runParityPassed && !sixPassed) reasons.push('the six-lane 40% speed gate is not met');
if (!sixLaneCapacityVerified) reasons.push('six-lane runtime fanout and capacity evidence is unverified');
else if (!sixLaneCapacityPassed) reasons.push('six-lane runtime did not prove fanout 6 with capacity at least 6');
if (runParityPassed && !serialSelectionPassed) reasons.push('serial SOLO-selection/overhead gates are not met');
if (runParityPassed && !swarmValuePassed) reasons.push('observed SWARM routes do not meet their value gate');
if (!nonDominatedPassed) reasons.push('dominated-route effort evidence is missing or failed');
if (!hygieneVerified) reasons.push('host-derived output and diff hygiene evidence is missing');
else if (!hygienePassed) reasons.push('output/context hygiene evidence failed its paired non-increase gate');

const complete = runParityPassed && cleanRevisionVerified && releaseStatusPassed && profileProvenancePassed &&
  promotionCapabilityAvailable && telemetryVerified && smallestEffectiveTeamVerified && usageVerified &&
  hostEvidenceVerified && sixLaneCapacityVerified;
const passed = complete && executionSuccess && authoritySafetyScopePassed && qualityPassed && firstPassPassed &&
  speedPassed && sixPassed && sixLaneCapacityPassed && smallestEffectiveTeamPassed && serialSelectionPassed && swarmValuePassed &&
  nonDominatedPassed && hygienePassed;
const explicitFailure = !executionSuccess || !cleanRevisionVerified || !releaseStatusPassed || !profileProvenancePassed ||
  verifiedViolation || (sixLaneCapacityVerified && !sixLaneCapacityPassed) ||
  (smallestEffectiveTeamVerified && !smallestEffectiveTeamPassed) ||
  (complete && (!qualityPassed || !firstPassPassed || !speedPassed || !sixPassed || !serialSelectionPassed ||
    !swarmValuePassed || !nonDominatedPassed || !hygienePassed));
const status = passed ? 'passed' : explicitFailure ? 'failed' : 'unverified';
const gate = (known, value) => known ? (value ? 'passed' : 'failed') : 'unverified';

const summary = {
  schema: 2,
  contract: 'codex-baseline-benchmark-summary/v2',
  runs: runs.length,
  task_repetitions: taskRepetitions,
  provenance: {
    source_revision: runReceipt.source_revision,
    source_dirty: runReceipt.source_dirty,
    source_hash: runReceipt.source_hash,
    version: releaseVersion,
    candidate_status: manifest.release_status,
    payload_hash: payloadHash,
    run_receipt_hash: sha256(runReceiptBytes),
    run_receipt_status: runReceipt.status,
    manifest_hash: actualManifestHash,
    result_set_hash: sha256(resultBytes),
    release_status: manifest.release_status,
    promotion_target: manifest.promotion_target,
    clean_revision_verified: cleanRevisionVerified,
    manifest_bound: true
  },
  by_arm: byArm,
  by_cache_state: byCacheState,
  comparisons,
  by_task: byTask,
  gates: {
    status,
    promotion_allowed: passed,
    execution_success: executionSuccess ? 'passed' : 'failed',
    run_parity: runParityPassed ? 'passed' : 'unverified',
    source_provenance: cleanRevisionVerified ? 'passed' : 'failed',
    release_status: releaseStatusPassed ? 'passed' : 'failed',
    profile_provenance: profileProvenancePassed ? 'passed' : 'failed',
    authority_safety_scope: verifiedViolation ? 'failed' : authorityEvidenceVerified ? 'passed' : 'unverified',
    quality: gate(runParityPassed, qualityPassed),
    first_pass: gate(firstPassEvidenceVerified, firstPassPassed),
    positive_speed: gate(runParityPassed, speedPassed),
    six_lane: gate(runParityPassed, sixPassed),
    six_lane_capacity: gate(sixLaneCapacityVerified, sixLaneCapacityPassed),
    smallest_effective_team: gate(smallestEffectiveTeamVerified, smallestEffectiveTeamPassed),
    serial_selection: gate(runParityPassed && telemetryVerified, serialSelectionPassed),
    swarm_value: gate(runParityPassed && telemetryVerified, swarmValuePassed),
    non_dominated: gate(usageVerified, nonDominatedPassed),
    hygiene: gate(telemetryVerified && hygieneVerified, hygienePassed),
    host_evidence: hostEvidenceVerified ? 'verified' : 'unverified',
    promotion_capability: promotionCapabilityAvailable ? 'available' : 'unavailable',
    telemetry: telemetryVerified ? 'verified' : telemetryPartial ? 'partial' : 'unverified',
    reasons
  },
  limitations: [
    'Public fixtures can be learned or overfit.',
    'Fast is excluded from every arm.',
    'Missing host-side truth, a capable pinned runtime telemetry adapter, or clean-revision provenance blocks promotion.'
  ]
};
process.stdout.write(`${JSON.stringify(summary)}\n`);
