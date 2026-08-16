import { createHash } from 'node:crypto';
import { readFileSync, statSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const INPUT_CONTRACT = 'codex-app-server-telemetry-input/v1';
const OUTPUT_CONTRACT = 'codex-app-server-telemetry/v1';
const MAX_EVENTS = 100_000;
const MAX_EVENT_BYTES = 4 * 1024 * 1024;
const MAX_INPUT_BYTES = 64 * 1024 * 1024;

const fail = (message) => {
  throw new Error(`app-server telemetry: ${message}`);
};

const isObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
const exactKeys = (value, keys) => isObject(value) &&
  JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...keys].sort());
const boundedString = (value, label, max = 512) => {
  if (typeof value !== 'string' || value.length === 0 || value.length > max || /[\0\r\n]/u.test(value)) {
    fail(`${label} is invalid`);
  }
  return value;
};
const integer = (value, label) => {
  if (!Number.isSafeInteger(value) || value < 0) fail(`${label} is invalid`);
  return value;
};

const pseudonym = (salt, kind, value) => `${kind}-${createHash('sha256')
  .update(salt).update('\0').update(kind).update('\0').update(value).digest('hex').slice(0, 16)}`;

const itemType = (item) => item?.type;
const isSpawnItem = (item) =>
  ['collabAgentToolCall', 'collabToolCall'].includes(itemType(item)) &&
  ['spawnAgent', 'spawn_agent'].includes(item?.tool);

const receivers = (item) => {
  const values = [];
  if (Array.isArray(item?.receiverThreadIds)) values.push(...item.receiverThreadIds);
  if (typeof item?.receiverThreadId === 'string') values.push(item.receiverThreadId);
  if (typeof item?.newThreadId === 'string') values.push(item.newThreadId);
  for (const value of values) boundedString(value, 'receiver thread id');
  return [...new Set(values)];
};

const publicSettings = (settings) => {
  if (!isObject(settings)) return null;
  const model = typeof settings.model === 'string' && settings.model.length > 0 ? settings.model : null;
  const effort = typeof settings.effort === 'string' && settings.effort.length > 0 ? settings.effort : null;
  const tier = settings.serviceTier;
  const speed = tier === 'fast' ? 'fast' : tier === null || tier === undefined || tier === 'standard' ? 'standard' : String(tier);
  return { model, effort, speed };
};

const normalizeAgentStatus = (value) => {
  switch (value) {
    case 'completed': return 'completed';
    case 'errored':
    case 'notFound':
    case 'failed': return 'failed';
    case 'interrupted': return 'interrupted';
    case 'timeout': return 'timeout';
    default: return 'unverified';
  }
};

const usageFields = (total) => {
  if (!isObject(total)) fail('token total is invalid');
  return {
    input_tokens: integer(total.inputTokens, 'input token total'),
    cached_input_tokens: integer(total.cachedInputTokens, 'cached input token total'),
    output_tokens: integer(total.outputTokens, 'output token total'),
    reasoning_tokens: integer(total.reasoningOutputTokens, 'reasoning token total'),
    total_tokens: integer(total.totalTokens, 'combined token total'),
  };
};

const monotonicUsage = (previous, next) => {
  if (!previous) return;
  for (const key of Object.keys(next)) {
    if (next[key] < previous[key]) fail(`token total decreased for ${key}`);
  }
};

const derivePeak = (intervals) => {
  const points = [];
  for (const { start, end } of intervals) {
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || end < start) fail('turn interval is invalid');
    points.push([start, 1], [end, -1]);
  }
  points.sort((left, right) => left[0] - right[0] || left[1] - right[1]);
  let active = 0;
  let peak = 0;
  for (const [, delta] of points) {
    active += delta;
    if (active < 0) fail('turn interval ordering is contradictory');
    peak = Math.max(peak, active);
  }
  if (active !== 0) fail('turn interval did not terminate');
  return peak;
};

const deriveWaves = (intervals) => {
  if (intervals.length === 0) return 0;
  const sorted = [...intervals].sort((left, right) => left.start - right.start || left.end - right.end);
  let waves = 0;
  let currentEnd = -1;
  for (const interval of sorted) {
    if (waves === 0 || interval.start > currentEnd) waves += 1;
    currentEnd = Math.max(currentEnd, interval.end);
  }
  return waves;
};

const validateDescriptor = (descriptor) => {
  if (!exactKeys(descriptor, ['schema', 'contract', 'root_thread_id', 'run_salt', 'configured_agent_cap'])) {
    fail('input descriptor shape is invalid');
  }
  if (descriptor.schema !== 1 || descriptor.contract !== INPUT_CONTRACT) fail('input descriptor contract is invalid');
  boundedString(descriptor.root_thread_id, 'root thread id');
  if (typeof descriptor.run_salt !== 'string' || !/^[0-9a-f]{64}$/u.test(descriptor.run_salt)) fail('run salt is invalid');
  if (!Number.isSafeInteger(descriptor.configured_agent_cap) || descriptor.configured_agent_cap < 0 || descriptor.configured_agent_cap > 6) {
    fail('configured agent cap is invalid');
  }
};

export function reduceAppServerTelemetry(descriptor, events) {
  validateDescriptor(descriptor);
  if (!Array.isArray(events) || events.length > MAX_EVENTS) fail('event collection is invalid or oversized');

  const root = descriptor.root_thread_id;
  const threads = new Map();
  const settings = new Map();
  const starts = new Map();
  const intervals = new Map();
  const terminal = new Map();
  const usages = new Map();
  const spawnAttempts = new Map();
  const reroutes = new Map();
  const timedOutThreads = new Set();

  const addSettings = (threadId, value) => {
    boundedString(threadId, 'settings thread id');
    const normalized = publicSettings(value);
    if (!normalized) fail('thread settings are invalid');
    const values = settings.get(threadId) ?? [];
    values.push(normalized);
    settings.set(threadId, values);
  };

  for (const event of events) {
    if (!isObject(event)) fail('event is not an object');
    const method = event.method;
    const params = event.params;
    if (method === 'thread/started') {
      const value = params?.thread;
      if (!isObject(value)) fail('thread/started payload is invalid');
      const id = boundedString(value.id, 'started thread id');
      const parent = value.parentThreadId ?? null;
      if (parent !== null) boundedString(parent, 'parent thread id');
      const previous = threads.get(id);
      if (previous && previous.parent !== parent) fail('thread parent changed');
      threads.set(id, { parent });
    } else if (method === 'thread/settings/updated' || method === 'host/threadStartResponse') {
      addSettings(params?.threadId, params?.threadSettings);
    } else if (method === 'model/rerouted') {
      const id = boundedString(params?.threadId, 'rerouted thread id');
      boundedString(params?.toModel, 'rerouted model', 256);
      reroutes.set(id, params.toModel);
    } else if (method === 'turn/started') {
      const threadId = boundedString(params?.threadId, 'turn thread id');
      const turnId = boundedString(params?.turn?.id, 'turn id');
      const start = integer(params?.turn?.startedAt, 'turn start time');
      const key = `${threadId}\0${turnId}`;
      if (starts.has(key)) fail('duplicate turn start');
      starts.set(key, start);
    } else if (method === 'turn/completed') {
      const threadId = boundedString(params?.threadId, 'completed turn thread id');
      const turnId = boundedString(params?.turn?.id, 'completed turn id');
      const end = integer(params?.turn?.completedAt, 'turn completion time');
      const key = `${threadId}\0${turnId}`;
      const start = starts.get(key);
      if (start === undefined) fail('turn completed without a start');
      const values = intervals.get(threadId) ?? [];
      values.push({ start, end });
      intervals.set(threadId, values);
      const status = normalizeAgentStatus(params?.turn?.status);
      terminal.set(threadId, status === 'unverified' && params?.turn?.status === 'completed' ? 'completed' : status);
    } else if (method === 'thread/tokenUsage/updated') {
      const threadId = boundedString(params?.threadId, 'usage thread id');
      const next = usageFields(params?.tokenUsage?.total);
      monotonicUsage(usages.get(threadId), next);
      usages.set(threadId, next);
    } else if (method === 'item/started' || method === 'item/completed') {
      const item = params?.item;
      if (!isSpawnItem(item)) continue;
      const id = boundedString(item.id, 'spawn item id');
      const sender = boundedString(item.senderThreadId, 'spawn sender thread id');
      if (sender !== root) fail('delegation depth exceeds the root policy');
      const attempt = spawnAttempts.get(id) ?? {
        id,
        sender,
        requestedModel: item.model ?? null,
        requestedEffort: item.reasoningEffort ?? null,
        prompt: item.prompt ?? null,
        receivers: [],
        start: null,
        end: null,
        status: null,
        agentStates: {},
      };
      if (attempt.sender !== sender) fail('spawn sender changed');
      if (item.model !== null && item.model !== undefined) {
        boundedString(item.model, 'requested model', 256);
        if (attempt.requestedModel !== null && attempt.requestedModel !== item.model) fail('requested model changed');
        attempt.requestedModel = item.model;
      }
      if (item.reasoningEffort !== null && item.reasoningEffort !== undefined) {
        boundedString(item.reasoningEffort, 'requested effort', 64);
        if (attempt.requestedEffort !== null && attempt.requestedEffort !== item.reasoningEffort) fail('requested effort changed');
        attempt.requestedEffort = item.reasoningEffort;
      }
      if (item.prompt !== null && item.prompt !== undefined) {
        if (typeof item.prompt !== 'string' || Buffer.byteLength(item.prompt, 'utf8') > MAX_EVENT_BYTES) fail('spawn prompt is invalid');
        if (attempt.prompt !== null && attempt.prompt !== item.prompt) fail('spawn prompt changed');
        attempt.prompt = item.prompt;
      }
      attempt.receivers = [...new Set([...attempt.receivers, ...receivers(item)])];
      if (method === 'item/started') {
        const start = integer(params?.startedAtMs, 'spawn start time');
        if (attempt.start !== null && attempt.start !== start) fail('spawn start changed');
        attempt.start = start;
      } else {
        attempt.end = integer(params?.completedAtMs, 'spawn completion time');
        attempt.status = item.status ?? null;
        if (isObject(item.agentsStates)) attempt.agentStates = { ...attempt.agentStates, ...item.agentsStates };
      }
      spawnAttempts.set(id, attempt);
    } else if (event.type === 'host/timeout') {
      timedOutThreads.add(boundedString(event.threadId, 'timeout thread id'));
    }
  }

  if (!threads.has(root) || threads.get(root).parent !== null) fail('root thread is missing or has a parent');
  for (const [id, value] of threads) {
    if (id === root) continue;
    const visited = new Set([id]);
    let parent = value.parent;
    let depth = 0;
    while (parent !== null) {
      if (visited.has(parent)) fail('thread parent cycle detected');
      visited.add(parent);
      depth += 1;
      if (!threads.has(parent)) fail('thread graph is disconnected');
      parent = threads.get(parent).parent;
    }
    if (!visited.has(root)) fail('thread graph is disconnected from the root');
    if (depth > 1) fail('observed delegation depth exceeds one');
  }

  const childToAttempt = new Map();
  for (const attempt of spawnAttempts.values()) {
    for (const child of attempt.receivers) {
      if (!threads.has(child)) fail('spawn receiver thread was not started');
      if (threads.get(child).parent !== root) fail('spawn receiver has the wrong parent thread');
      if (childToAttempt.has(child) && childToAttempt.get(child) !== attempt.id) fail('receiver thread belongs to multiple spawn attempts');
      childToAttempt.set(child, attempt.id);
    }
  }
  for (const [id, value] of threads) {
    if (id !== root && value.parent === root && !childToAttempt.has(id)) fail('child thread has no spawn evidence');
  }

  const attempts = [...spawnAttempts.values()];
  const children = [...childToAttempt.keys()];
  if (attempts.length > descriptor.configured_agent_cap || children.length > descriptor.configured_agent_cap) {
    fail('observed fanout exceeds configured capacity');
  }

  const plannedLaneIds = attempts.map((attempt) => pseudonym(descriptor.run_salt, 'lane', attempt.id)).sort();
  const agents = [];
  let partial = false;
  let fallbacks = 0;
  let interrupts = 0;
  let timeouts = 0;
  for (const child of children) {
    const attempt = spawnAttempts.get(childToAttempt.get(child));
    const observedValues = settings.get(child) ?? [];
    const observed = observedValues.length > 0 ? observedValues.at(-1) : null;
    const actualModel = reroutes.get(child) ?? observed?.model ?? null;
    const actualEffort = observed?.effort ?? null;
    let status = terminal.get(child) ?? normalizeAgentStatus(attempt.agentStates?.[child]?.status);
    if (timedOutThreads.has(child)) status = 'timeout';
    if (!observed || !actualModel || !actualEffort || status === 'unverified') partial = true;
    if (status === 'interrupted') interrupts += 1;
    if (status === 'timeout') timeouts += 1;
    if ((attempt.requestedModel !== null && actualModel !== null && attempt.requestedModel !== actualModel) ||
        (attempt.requestedEffort !== null && actualEffort !== null && attempt.requestedEffort !== actualEffort)) fallbacks += 1;
    agents.push({
      id: pseudonym(descriptor.run_salt, 'agent', child),
      lane_id: pseudonym(descriptor.run_salt, 'lane', attempt.id),
      requested_model: attempt.requestedModel,
      actual_model: actualModel,
      requested_effort: attempt.requestedEffort,
      actual_effort: actualEffort,
      status,
    });
  }
  agents.sort((left, right) => left.lane_id.localeCompare(right.lane_id));

  const rootSettings = settings.get(root) ?? [];
  const parentBefore = rootSettings[0] ?? null;
  const parentAfter = rootSettings.at(-1) ?? null;
  if (!parentBefore || !parentAfter || !parentBefore.model || !parentBefore.effort || !parentAfter.model || !parentAfter.effort) partial = true;

  const childIntervals = [];
  const allIntervals = [];
  for (const id of [root, ...children]) {
    const values = intervals.get(id) ?? [];
    if (values.length === 0) partial = true;
    allIntervals.push(...values);
    if (id !== root) childIntervals.push(...values);
  }
  const peak = allIntervals.length > 0 ? derivePeak(allIntervals) : null;
  const waves = childIntervals.length === children.length ? deriveWaves(childIntervals) : null;
  if (peak === null || waves === null) partial = true;

  const aggregate = {
    input_tokens: 0,
    cached_input_tokens: 0,
    output_tokens: 0,
    reasoning_tokens: 0,
  };
  for (const id of [root, ...children]) {
    const value = usages.get(id);
    if (!value) {
      partial = true;
      continue;
    }
    aggregate.input_tokens += value.input_tokens;
    aggregate.cached_input_tokens += value.cached_input_tokens;
    aggregate.output_tokens += value.output_tokens;
    aggregate.reasoning_tokens += value.reasoning_tokens;
  }

  let handoffBytes = 0;
  let duplicatedContextBytes = 0;
  const seenPrompts = new Set();
  for (const attempt of attempts) {
    if (typeof attempt.prompt !== 'string') {
      partial = true;
      continue;
    }
    const bytes = Buffer.byteLength(attempt.prompt, 'utf8');
    handoffBytes += bytes;
    if (seenPrompts.has(attempt.prompt)) duplicatedContextBytes += bytes;
    seenPrompts.add(attempt.prompt);
  }

  const spawnErrors = attempts
    .filter((attempt) => attempt.receivers.length === 0 || ['failed', 'errored'].includes(attempt.status))
    .map((attempt) => `${pseudonym(descriptor.run_salt, 'lane', attempt.id)}:spawn-failed`)
    .sort();
  const plannedFanout = attempts.length;
  const execution = plannedFanout === 0 ? 'SOLO' : plannedFanout <= 3 ? 'TEAM' : 'SWARM';
  const writeIsolation = 'unverified';
  const testIsolation = 'unverified';

  return {
    schema: 1,
    contract: OUTPUT_CONTRACT,
    // This verifies only the App Server evidence reduced here. Environment
    // isolation and integration quality remain independently unverified below.
    verification: partial ? 'partial' : 'verified',
    usage: usages.size === children.length + 1 ? {
      ...aggregate,
      usage_scope: 'aggregate-unpriced',
      cost_usd: null,
      retry_count: null,
      review_findings: null,
    } : {
      input_tokens: null,
      cached_input_tokens: null,
      output_tokens: null,
      reasoning_tokens: null,
      usage_scope: 'unverified',
      cost_usd: null,
      retry_count: null,
      review_findings: null,
    },
    orchestration: {
      execution,
      selection_reason: `observed ${plannedFanout} spawn-agent call(s)`,
      planned_lane_ids: plannedLaneIds,
      planned_fanout: plannedFanout,
      actual_fanout: children.length,
      available_capacity: descriptor.configured_agent_cap,
      agents,
      depth_intended: 1,
      depth_observed: children.length === 0 ? 0 : 1,
      waves_planned: plannedFanout === 0 ? 0 : null,
      waves_observed: waves,
      peak_concurrency: peak,
      spawn_errors: spawnErrors,
      fallbacks,
      interrupts,
      timeouts,
      conflicts: null,
      integration_rework_events: null,
      handoff_bytes: handoffBytes,
      duplicated_context_bytes: duplicatedContextBytes,
      write_isolation: writeIsolation,
      test_isolation: testIsolation,
      parent_before: parentBefore ?? { model: null, effort: null, speed: null },
      parent_after: parentAfter ?? { model: null, effort: null, speed: null },
    },
  };
}

const readJson = (path, label, limit) => {
  const stat = statSync(path, { throwIfNoEntry: true });
  if (!stat.isFile() || stat.size > limit) fail(`${label} file is unsafe or oversized`);
  return JSON.parse(readFileSync(path, 'utf8'));
};

const readJsonLines = (path) => {
  const stat = statSync(path, { throwIfNoEntry: true });
  if (!stat.isFile() || stat.size > MAX_INPUT_BYTES) fail('event file is unsafe or oversized');
  const lines = readFileSync(path, 'utf8').split(/\n/u).filter((line) => line.length > 0);
  if (lines.length > MAX_EVENTS) fail('event file has too many records');
  return lines.map((line, index) => {
    if (Buffer.byteLength(line, 'utf8') > MAX_EVENT_BYTES) fail(`event line ${index + 1} is oversized`);
    return JSON.parse(line);
  });
};

async function main(argv) {
  if (argv.length !== 3 || argv[0] !== 'reduce') {
    process.stderr.write('usage: node benchmarks/runtime/app-server-telemetry.mjs reduce DESCRIPTOR.json EVENTS.jsonl\n');
    process.exitCode = 64;
    return;
  }
  const descriptor = readJson(argv[1], 'descriptor', 64 * 1024);
  const events = readJsonLines(argv[2]);
  process.stdout.write(`${JSON.stringify(reduceAppServerTelemetry(descriptor, events))}\n`);
}

if (typeof process.argv[1] === 'string' && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2)).catch((error) => {
    process.stderr.write(`${error?.message ?? String(error)}\n`);
    process.exitCode = 1;
  });
}
