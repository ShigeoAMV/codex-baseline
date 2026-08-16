#!/usr/bin/env node

import fs from 'node:fs';

function fail(message) {
  process.stderr.write(`routing receipt invalid: ${message}\n`);
  process.exitCode = 1;
}

function same(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
}

function validate(input) {
  const receipt = input?.runtime_receipt ?? input;
  if (!receipt || typeof receipt !== 'object' || Array.isArray(receipt)) {
    return 'missing runtime_receipt object';
  }
  if (receipt.verification === 'unverified') {
    const unavailable = [
      'actual_fanout', 'available_capacity', 'depth_observed', 'waves_observed',
      'peak_concurrency', 'spawn_failures', 'fallbacks', 'interrupts', 'timeouts',
      'conflicts', 'integration_rework_actions', 'handoff_bytes',
      'duplicate_context_bytes', 'parent_settings_before', 'parent_settings_after',
      'parent_settings_unchanged'
    ];
    if (unavailable.some((key) => receipt[key] !== null)) return 'unverified receipt invented runtime data';
    if ((receipt.children ?? []).some((child) => child.verification !== 'unverified')) return 'unverified receipt contains a verified child';
    if (receipt.depth_verification !== 'unverified' || receipt.parent_settings_verification !== 'unverified') return 'unverified receipt has verified sub-status';
    return null;
  }
  if (receipt.verification !== 'verified') return 'unknown verification status';
  if (!input?.runtime_receipt || !Array.isArray(input.planned_lanes) ||
      !Number.isInteger(input.planned_fanout) || !Number.isInteger(input.child_limit) ||
      !Number.isInteger(input.wave_limit)) {
    return 'verified runtime receipt requires its complete routing decision';
  }
  const plannedLaneIds = input.planned_lanes.map((lane) => lane?.id);
  const plannedLanes = new Set(plannedLaneIds);
  if (plannedLaneIds.some((id) => typeof id !== 'string' || id.length === 0) ||
      plannedLanes.size !== plannedLaneIds.length || plannedLanes.size !== input.planned_fanout) {
    return 'planned lane inventory disagrees with planned fan-out';
  }
  if (input.planned_fanout < 0 || input.planned_fanout > input.child_limit ||
      input.child_limit < 0 || input.child_limit > 6 || input.wave_limit < 0 || input.wave_limit > 4) {
    return 'planned fan-out exceeds routing limits';
  }
  const children = receipt.children ?? [];
  if (children.some((child) => child.verification !== 'verified')) return 'verified receipt contains an unverified child';
  if (!Number.isInteger(receipt.actual_fanout) || !Number.isInteger(receipt.available_capacity)) return 'verified fan-out/capacity is missing';
  if (receipt.actual_fanout < 0 || receipt.available_capacity < 0) return 'verified fan-out/capacity is negative';
  if (receipt.actual_fanout > input.planned_fanout) return 'actual fan-out exceeds planned fan-out';
  if (receipt.actual_fanout > receipt.available_capacity) return 'actual fan-out exceeds available capacity';
  const lanes = new Set(children.map((child) => child.lane_id));
  if (lanes.size !== receipt.actual_fanout) return 'unique observed lanes do not equal actual fan-out';
  if ([...lanes].some((lane) => !plannedLanes.has(lane))) return 'observed child lane was not planned';
  const attempts = new Map();
  for (const child of children) {
    if (!Number.isInteger(child.wave) || child.wave < 1 || child.wave > input.wave_limit) return 'child wave exceeds the planned wave limit';
    if (!Number.isInteger(child.attempt) || child.attempt < 1 || child.attempt > 2) return 'child attempt is outside the bounded retry policy';
    const laneAttempts = attempts.get(child.lane_id) ?? [];
    if (laneAttempts.includes(child.attempt)) return 'duplicate child attempt for one lane';
    laneAttempts.push(child.attempt);
    attempts.set(child.lane_id, laneAttempts);
  }
  for (const [lane, laneAttempts] of attempts) {
    laneAttempts.sort((a, b) => a - b);
    if (laneAttempts.length === 2 && !same(laneAttempts, [1, 2])) return `non-contiguous retry attempts for lane ${lane}`;
    const laneChildren = children.filter((child) => child.lane_id === lane).sort((a, b) => a.attempt - b.attempt);
    if (laneChildren.length === 2 &&
        (laneChildren[0].outcome !== 'failed' || laneChildren[0].fallback_used !== false || laneChildren[1].fallback_used !== true)) {
      return `retry/fallback sequence is inconsistent for lane ${lane}`;
    }
  }
  if (receipt.peak_concurrency > Math.min(receipt.actual_fanout, receipt.available_capacity)) return 'peak concurrency exceeds fan-out/capacity';
  const count = (predicate) => children.filter(predicate).length;
  if (count((child) => child.outcome === 'failed') !== receipt.spawn_failures) return 'spawn failure counter disagrees with children';
  if (count((child) => child.fallback_used === true) !== receipt.fallbacks) return 'fallback counter disagrees with children';
  if (count((child) => child.outcome === 'interrupted') !== receipt.interrupts) return 'interrupt counter disagrees with children';
  if (count((child) => child.outcome === 'timeout') !== receipt.timeouts) return 'timeout counter disagrees with children';
  const maxWave = children.reduce((value, child) => Math.max(value, child.wave ?? 0), 0);
  if (maxWave !== receipt.waves_observed) return 'wave counter disagrees with children';
  if (receipt.waves_observed > input.wave_limit) return 'observed waves exceed the planned wave limit';
  if (!Number.isInteger(receipt.depth_intended) || !Number.isInteger(receipt.depth_observed) ||
      receipt.depth_observed < 0 || receipt.depth_observed > receipt.depth_intended) {
    return 'observed delegation depth exceeds intended depth';
  }
  if (receipt.parent_settings_unchanged !== true || !same(receipt.parent_settings_before, receipt.parent_settings_after)) return 'parent settings changed or equality is fabricated';
  if (receipt.depth_verification !== 'verified' || receipt.parent_settings_verification !== 'verified') return 'verified receipt has unverified sub-status';
  return null;
}

const paths = process.argv.slice(2);
if (paths.length === 0) {
  fail('usage: validate-routing-receipt.mjs FILE|-');
} else {
  for (const path of paths) {
    try {
      const text = path === '-' ? fs.readFileSync(0, 'utf8') : fs.readFileSync(path, 'utf8');
      const message = validate(JSON.parse(text));
      if (message) fail(message);
    } catch (error) {
      fail(error instanceof Error ? error.message : String(error));
    }
  }
}
