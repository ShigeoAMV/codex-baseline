#!/usr/bin/env node

import { spawn } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const MAX_LINE_BYTES = 4_194_304;
const MAX_PROMPT_BYTES = 1024 * 1024;

const fail = (message) => {
  throw new Error(`app-server runner: ${message}`);
};

const parseArgs = (argv) => {
  const options = { serverArgs: [] };
  for (let index = 0; index < argv.length; index += 1) {
    const name = argv[index];
    const value = argv[index + 1];
    if (!name.startsWith('--') || value === undefined) fail(`missing value for ${name}`);
    index += 1;
    switch (name) {
      case '--server': options.server = value; break;
      case '--server-arg': options.serverArgs.push(value); break;
      case '--cwd': options.cwd = value; break;
      case '--prompt-file': options.promptFile = value; break;
      case '--last-message': options.lastMessage = value; break;
      case '--model': options.model = value; break;
      case '--effort': options.effort = value; break;
      case '--service-tier': options.serviceTier = value; break;
      default: fail(`unknown option ${name}`);
    }
  }
  for (const name of ['server', 'cwd', 'promptFile', 'lastMessage']) {
    if (typeof options[name] !== 'string' || options[name].length === 0) fail(`--${name} is required`);
  }
  return options;
};

const readPrompt = (path) => {
  const value = readFileSync(path);
  if (value.length === 0 || value.length > MAX_PROMPT_BYTES || value.includes(0)) fail('prompt is empty, oversized, or contains NUL');
  return value.toString('utf8');
};

export async function runAppServer(options) {
  const prompt = readPrompt(options.promptFile);
  const child = spawn(options.server, options.serverArgs, {
    cwd: options.cwd,
    env: process.env,
    stdio: ['pipe', 'pipe', 'inherit'],
    windowsHide: true,
  });

  let nextId = 1;
  let buffer = '';
  let rootThreadId = null;
  let rootCompleted = false;
  let rootTurnStatus = null;
  let finalMessage = '';
  const pending = new Map();
  let resolveRootCompletion;
  const rootCompletion = new Promise((resolveCompletion) => { resolveRootCompletion = resolveCompletion; });

  const send = (value) => {
    if (!child.stdin.write(`${JSON.stringify(value)}\n`)) child.stdin.once('drain', () => {});
  };
  const request = (method, params) => new Promise((resolveRequest, rejectRequest) => {
    const id = nextId;
    nextId += 1;
    pending.set(id, { resolve: resolveRequest, reject: rejectRequest, method });
    send({ id, method, params });
  });

  const handle = (message, raw) => {
    if (message.id !== undefined && (Object.hasOwn(message, 'result') || Object.hasOwn(message, 'error'))) {
      const entry = pending.get(message.id);
      if (!entry) fail(`unexpected response id ${message.id}`);
      pending.delete(message.id);
      if (message.error) entry.reject(new Error(`${entry.method} failed: ${message.error.message ?? 'unknown error'}`));
      else entry.resolve(message.result);
      return;
    }

    // A server-initiated request is never implicitly approved by the benchmark.
    if (message.id !== undefined && typeof message.method === 'string') {
      if (message.method.endsWith('/requestApproval')) send({ id: message.id, result: { decision: 'decline' } });
      else send({ id: message.id, error: { code: -32601, message: 'unsupported server request' } });
      return;
    }

    if (typeof message.method !== 'string') fail('server message has no method');
    process.stdout.write(`${raw}\n`);
    if (message.method === 'item/completed' && message.params?.threadId === rootThreadId &&
        message.params?.item?.type === 'agentMessage' && typeof message.params.item.text === 'string') {
      finalMessage = message.params.item.text;
    }
    if (message.method === 'turn/completed' && message.params?.threadId === rootThreadId) {
      rootCompleted = true;
      rootTurnStatus = message.params?.turn?.status ?? null;
      resolveRootCompletion();
    }
  };

  const exitPromise = new Promise((resolveExit, rejectExit) => {
    child.once('error', rejectExit);
    child.once('exit', (code, signal) => {
      if (!rootCompleted) rejectExit(new Error(`server exited before root completion (${code ?? signal})`));
      else resolveExit({ code, signal });
    });
  });

  child.stdout.setEncoding('utf8');
  child.stdout.on('data', (chunk) => {
    buffer += chunk;
    while (true) {
      const newline = buffer.indexOf('\n');
      if (newline < 0) break;
      const raw = buffer.slice(0, newline).replace(/\r$/u, '');
      buffer = buffer.slice(newline + 1);
      if (Buffer.byteLength(raw, 'utf8') > MAX_LINE_BYTES) {
        child.kill();
        fail('server emitted an oversized line');
      }
      if (raw.length > 0) handle(JSON.parse(raw), raw);
    }
  });

  try {
    await request('initialize', {
      clientInfo: { name: 'codex_baseline_benchmark', title: 'Codex Baseline Benchmark', version: '0.3.0' },
      capabilities: { experimentalApi: true },
    });
    send({ method: 'initialized', params: {} });
    const startParams = {
      cwd: resolve(options.cwd),
      approvalPolicy: 'never',
      sandbox: 'workspace-write',
      ephemeral: true,
      serviceName: 'codex-baseline-benchmark',
    };
    if (options.model) startParams.model = options.model;
    if (options.serviceTier) startParams.serviceTier = options.serviceTier;
    const started = await request('thread/start', startParams);
    rootThreadId = started?.thread?.id;
    if (typeof rootThreadId !== 'string' || rootThreadId.length === 0) fail('thread/start returned no thread id');
    const hostSettings = {
      model: started.model ?? options.model ?? null,
      effort: started.reasoningEffort ?? options.effort ?? null,
      serviceTier: started.serviceTier ?? options.serviceTier ?? null,
    };
    process.stdout.write(`${JSON.stringify({ method: 'host/threadStartResponse', params: { threadId: rootThreadId, threadSettings: hostSettings } })}\n`);
    const turnParams = { threadId: rootThreadId, input: [{ type: 'text', text: prompt }] };
    if (options.model) turnParams.model = options.model;
    if (options.effort) turnParams.effort = options.effort;
    if (options.serviceTier) turnParams.serviceTier = options.serviceTier;
    await request('turn/start', turnParams);

    await rootCompletion;
    writeFileSync(options.lastMessage, finalMessage, { encoding: 'utf8', flag: 'w', mode: 0o600 });
    child.stdin.end();
    const graceful = new Promise((resolveGraceful) => setTimeout(resolveGraceful, 250, false));
    const exited = await Promise.race([exitPromise.then(() => true), graceful]);
    if (!exited) child.kill();
    await exitPromise;
    if (rootTurnStatus !== 'completed') fail(`root turn ended with status ${rootTurnStatus ?? 'unknown'}`);
  } catch (error) {
    child.kill();
    throw error;
  }
}

async function main(argv) {
  await runAppServer(parseArgs(argv));
}

if (typeof process.argv[1] === 'string' && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2)).catch((error) => {
    process.stderr.write(`${error?.message ?? String(error)}\n`);
    process.exitCode = 1;
  });
}
