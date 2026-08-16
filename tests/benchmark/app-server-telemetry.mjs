import assert from 'node:assert/strict';
import { reduceAppServerTelemetry } from '../../benchmarks/runtime/app-server-telemetry.mjs';

const hash = (character) => character.repeat(64);

const descriptor = {
  schema: 1,
  contract: 'codex-app-server-telemetry-input/v1',
  root_thread_id: 'root-thread',
  run_salt: hash('a'),
  configured_agent_cap: 6,
};

const thread = (id, parentThreadId = null) => ({
  id,
  parentThreadId,
  sessionId: 'session',
  cliVersion: '0.147.0',
  cwd: '/workspace',
  ephemeral: true,
  modelProvider: 'openai',
  preview: '',
  source: parentThreadId ? { subAgent: { thread_spawn: { depth: 1, parent_thread_id: parentThreadId } } } : 'appServer',
  status: { type: 'active', activeFlags: [] },
  turns: [],
  createdAt: 1,
  updatedAt: 1,
});

const settings = (threadId, model, effort, serviceTier = null) => ({
  method: 'thread/settings/updated',
  params: {
    threadId,
    threadSettings: {
      approvalPolicy: 'never',
      approvalsReviewer: 'user',
      collaborationMode: 'default',
      cwd: '/workspace',
      model,
      modelProvider: 'openai',
      effort,
      sandboxPolicy: { type: 'workspaceWrite' },
      serviceTier,
    },
  },
});

const spawnItem = (id, child, model, effort, prompt, status = 'inProgress', agentStatus = 'running') => ({
  id,
  type: 'collabAgentToolCall',
  tool: 'spawnAgent',
  status,
  senderThreadId: 'root-thread',
  receiverThreadIds: child ? [child] : [],
  model,
  reasoningEffort: effort,
  prompt,
  agentsStates: child ? { [child]: { status: agentStatus } } : {},
});

const started = (threadId, turnId, at) => ({
  method: 'turn/started',
  params: { threadId, turn: { id: turnId, items: [], status: 'inProgress', startedAt: at } },
});

const completed = (threadId, turnId, at, status = 'completed') => ({
  method: 'turn/completed',
  params: { threadId, turn: { id: turnId, items: [], status, completedAt: at } },
});

const usage = (threadId, turnId, inputTokens, cachedInputTokens, outputTokens, reasoningOutputTokens) => ({
  method: 'thread/tokenUsage/updated',
  params: {
    threadId,
    turnId,
    tokenUsage: {
      last: { inputTokens, cachedInputTokens, outputTokens, reasoningOutputTokens,
        totalTokens: inputTokens + outputTokens },
      total: { inputTokens, cachedInputTokens, outputTokens, reasoningOutputTokens,
        totalTokens: inputTokens + outputTokens },
      modelContextWindow: 200000,
    },
  },
});

const events = [
  { method: 'thread/started', params: { thread: thread('root-thread') } },
  settings('root-thread', 'gpt-5.6-sol', 'high'),
  started('root-thread', 'root-turn', 1000),
  { method: 'item/started', params: { threadId: 'root-thread', turnId: 'root-turn', startedAtMs: 1100,
    item: spawnItem('spawn-a', 'child-a', 'gpt-5.6-terra', 'medium', 'lane A') } },
  { method: 'thread/started', params: { thread: thread('child-a', 'root-thread') } },
  settings('child-a', 'gpt-5.6-terra', 'medium'),
  started('child-a', 'turn-a', 1120),
  { method: 'item/started', params: { threadId: 'root-thread', turnId: 'root-turn', startedAtMs: 1150,
    item: spawnItem('spawn-b', 'child-b', 'gpt-5.6-luna', 'low', 'lane B') } },
  { method: 'thread/started', params: { thread: thread('child-b', 'root-thread') } },
  settings('child-b', 'gpt-5.6-luna', 'low'),
  started('child-b', 'turn-b', 1160),
  usage('child-a', 'turn-a', 10, 2, 4, 1),
  completed('child-a', 'turn-a', 1400),
  { method: 'item/completed', params: { threadId: 'root-thread', turnId: 'root-turn', completedAtMs: 1400,
    item: spawnItem('spawn-a', 'child-a', 'gpt-5.6-terra', 'medium', 'lane A', 'completed', 'completed') } },
  usage('child-b', 'turn-b', 20, 5, 6, 2),
  completed('child-b', 'turn-b', 1450),
  { method: 'item/completed', params: { threadId: 'root-thread', turnId: 'root-turn', completedAtMs: 1450,
    item: spawnItem('spawn-b', 'child-b', 'gpt-5.6-luna', 'low', 'lane B', 'completed', 'completed') } },
  usage('root-thread', 'root-turn', 100, 30, 40, 10),
  settings('root-thread', 'gpt-5.6-sol', 'high'),
  completed('root-thread', 'root-turn', 1500),
];

const receipt = reduceAppServerTelemetry(descriptor, events);
assert.equal(receipt.schema, 1);
assert.equal(receipt.contract, 'codex-app-server-telemetry/v1');
assert.equal(receipt.verification, 'verified');
assert.equal(receipt.orchestration.execution, 'TEAM');
assert.equal(receipt.orchestration.planned_fanout, 2);
assert.equal(receipt.orchestration.actual_fanout, 2);
assert.equal(receipt.orchestration.depth_observed, 1);
assert.equal(receipt.orchestration.waves_observed, 1);
assert.equal(receipt.orchestration.peak_concurrency, 3);
assert.equal(receipt.orchestration.fallbacks, 0);
assert.deepEqual(receipt.orchestration.parent_before, { model: 'gpt-5.6-sol', effort: 'high', speed: 'standard' });
assert.deepEqual(receipt.orchestration.parent_after, receipt.orchestration.parent_before);
assert.deepEqual(receipt.usage, {
  input_tokens: 130,
  cached_input_tokens: 37,
  output_tokens: 50,
  reasoning_tokens: 13,
  usage_scope: 'aggregate-unpriced',
  cost_usd: null,
  retry_count: null,
  review_findings: null,
});
assert.equal(receipt.orchestration.agents.length, 2);
assert.ok(receipt.orchestration.agents.every((agent) => !agent.id.includes('child-')));
assert.ok(receipt.orchestration.planned_lane_ids.every((lane) => !lane.includes('spawn-')));
assert.ok(!JSON.stringify(receipt).includes('lane A'));
assert.ok(!JSON.stringify(receipt).includes('root-thread'));

const expectReject = (label, mutate, pattern) => {
  const candidateDescriptor = structuredClone(descriptor);
  const candidateEvents = structuredClone(events);
  mutate(candidateDescriptor, candidateEvents);
  assert.throws(() => reduceAppServerTelemetry(candidateDescriptor, candidateEvents), pattern, label);
};

expectReject('parent cycle', (_descriptor, candidate) => {
  candidate.find((event) => event.method === 'thread/started' && event.params.thread.id === 'child-a')
    .params.thread.parentThreadId = 'child-b';
  candidate.find((event) => event.method === 'thread/started' && event.params.thread.id === 'child-b')
    .params.thread.parentThreadId = 'child-a';
}, /cycle|disconnected/i);

expectReject('unknown receiver', (_descriptor, candidate) => {
  candidate.find((event) => event.method === 'item/started').params.item.receiverThreadIds = ['not-started'];
}, /receiver|thread/i);

expectReject('decreasing token total', (_descriptor, candidate) => {
  const index = candidate.findIndex((event) => event.method === 'turn/completed' && event.params.threadId === 'child-a');
  candidate.splice(index, 0, usage('child-a', 'turn-a', 11, 2, 4, 1), usage('child-a', 'turn-a', 9, 2, 4, 1));
}, /decreas|monotonic/i);

expectReject('recursive child spawn', (_descriptor, candidate) => {
  candidate.push({ method: 'item/started', params: { threadId: 'child-a', turnId: 'turn-a', startedAtMs: 1200,
    item: { ...spawnItem('recursive', 'grandchild', null, null, 'do more'), senderThreadId: 'child-a' } } });
  candidate.push({ method: 'thread/started', params: { thread: thread('grandchild', 'child-a') } });
}, /depth|delegat|root/i);

expectReject('fanout above configured capacity', (candidateDescriptor) => {
  candidateDescriptor.configured_agent_cap = 1;
}, /fanout|capacity/i);

const partialEvents = events.filter((event) => !(event.method === 'thread/settings/updated' && event.params.threadId === 'child-b'));
const partial = reduceAppServerTelemetry(descriptor, partialEvents);
assert.equal(partial.verification, 'partial');
assert.equal(partial.orchestration.agents.find((agent) => agent.actual_model === null).status, 'completed');

console.log('app-server telemetry reducer tests passed');
