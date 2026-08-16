#!/usr/bin/env node

import readline from 'node:readline';

const send = (value) => process.stdout.write(`${JSON.stringify(value)}\n`);
const failTurn = process.argv.includes('--fail-turn');
const thread = {
  id: 'root-real-id',
  parentThreadId: null,
  sessionId: 'session-real-id',
  status: { type: 'idle' },
};

const lines = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
lines.on('line', (line) => {
  const message = JSON.parse(line);
  if (message.method === 'initialize') {
    send({ id: message.id, result: { userAgent: 'fake-app-server/1' } });
  } else if (message.method === 'initialized') {
    // Notification; no response.
  } else if (message.method === 'thread/start') {
    send({ id: message.id, result: {
      thread,
      model: 'gpt-5.6-sol',
      modelProvider: 'openai',
      reasoningEffort: 'high',
      serviceTier: 'standard',
      approvalPolicy: 'never',
      approvalsReviewer: 'user',
      cwd: message.params.cwd,
      sandbox: { type: 'workspaceWrite' },
    } });
    send({ method: 'thread/started', params: { thread } });
  } else if (message.method === 'turn/start') {
    send({ id: message.id, result: { turn: { id: 'turn-root', status: 'inProgress', startedAt: 1000 } } });
    send({ method: 'thread/settings/updated', params: { threadId: thread.id, threadSettings: { model: 'gpt-5.6-sol', effort: 'high', serviceTier: 'standard' } } });
    send({ method: 'turn/started', params: { threadId: thread.id, turn: { id: 'turn-root', status: 'inProgress', startedAt: 1000 } } });
    send({ method: 'item/completed', params: { threadId: thread.id, turnId: 'turn-root', completedAtMs: 1400, item: { id: 'message-1', type: 'agentMessage', text: 'fake final answer' } } });
    send({ method: 'thread/tokenUsage/updated', params: { threadId: thread.id, tokenUsage: { total: { inputTokens: 10, cachedInputTokens: 2, outputTokens: 4, reasoningOutputTokens: 1, totalTokens: 14 } } } });
    send({ method: 'turn/completed', params: { threadId: thread.id, turn: { id: 'turn-root', status: failTurn ? 'failed' : 'completed', startedAt: 1000, completedAt: 1002 } } });
  }
});
