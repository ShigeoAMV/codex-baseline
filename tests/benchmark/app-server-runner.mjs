import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { reduceAppServerTelemetry } from '../../benchmarks/runtime/app-server-telemetry.mjs';

const root = resolve(import.meta.dirname, '..', '..');
const temporary = mkdtempSync(join(tmpdir(), 'codex-baseline-app-server-'));
const prompt = join(temporary, 'prompt.txt');
const last = join(temporary, 'last.txt');
await import('node:fs/promises').then(({ writeFile }) => writeFile(prompt, 'Return one concise result.', { mode: 0o600 }));

const result = spawnSync(process.execPath, [
  join(root, 'benchmarks', 'runtime', 'app-server-runner.mjs'),
  '--server', process.execPath,
  '--server-arg', join(root, 'tests', 'fixtures', 'fake-app-server.mjs'),
  '--cwd', temporary,
  '--prompt-file', prompt,
  '--last-message', last,
  '--model', 'gpt-5.6-sol',
  '--effort', 'high',
  '--service-tier', 'standard',
], { encoding: 'utf8', timeout: 10_000 });

assert.equal(result.status, 0, result.stderr);
assert.equal(readFileSync(last, 'utf8'), 'fake final answer');
const events = result.stdout.trim().split(/\r?\n/u).map(JSON.parse);
assert(events.some((event) => event.method === 'host/threadStartResponse'));
assert(events.some((event) => event.method === 'thread/started'));
assert(events.some((event) => event.method === 'thread/tokenUsage/updated'));
assert(events.some((event) => event.method === 'turn/completed'));
assert(!result.stdout.includes('Return one concise result.'));
const receipt = reduceAppServerTelemetry({
  schema: 1,
  contract: 'codex-app-server-telemetry-input/v1',
  root_thread_id: 'root-real-id',
  run_salt: 'c'.repeat(64),
  configured_agent_cap: 6,
}, events);
assert.equal(receipt.verification, 'verified');
assert.equal(receipt.orchestration.execution, 'SOLO');
assert.equal(receipt.usage.usage_scope, 'aggregate-unpriced');
assert.equal(receipt.usage.input_tokens, 10);

const failed = spawnSync(process.execPath, [
  join(root, 'benchmarks', 'runtime', 'app-server-runner.mjs'),
  '--server', process.execPath,
  '--server-arg', join(root, 'tests', 'fixtures', 'fake-app-server.mjs'),
  '--server-arg', '--fail-turn',
  '--cwd', temporary,
  '--prompt-file', prompt,
  '--last-message', last,
], { encoding: 'utf8', timeout: 10_000 });
assert.equal(failed.status, 1);
assert.match(failed.stderr, /root turn ended with status failed/u);
process.stdout.write('app-server protocol runner tests passed\n');
