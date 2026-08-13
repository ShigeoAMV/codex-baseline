---
name: codex-baseline-retrospective
description: "Analyze a repeated Codex engineering failure after a concrete incident or pattern and route prevention to the lowest reliable layer: test, lint/static rule, repository guidance, focused skill, bounded hook, or environment/tool fix. Use when the same failure recurs, after a failed substantial workflow, or when explicitly asked for a harness retrospective. Do not trigger for one-off bugs, blame analysis, ordinary code review, or automatic instruction growth."
---

# Codex Baseline Retrospective

Do not edit guidance or install enforcement automatically. Produce a reviewed,
testable prevention proposal.

## Workflow

1. Reconstruct the incident from the original request, actual artifact/diff,
   commands, failures, review findings, and environment. Separate observation
   from inference.
2. Determine whether it is a one-off or a recurring class. For a recurring
   claim, cite at least two independent occurrences or one reproducible invariant.
3. Create the smallest reproduction or executable regression check when feasible.
4. Classify the missing control:
   - repository/product defect;
   - missing test or verifier;
   - missing lint/type/static rule;
   - missing or stale repository fact;
   - focused workflow/skill defect;
   - hook candidate only when no lower reliable layer works;
   - environment, dependency, permission, or tool defect;
   - one-off with no durable change justified.
5. Choose the lowest deterministic prevention layer. Tests/rules outrank skills;
   focused repo guidance outranks global prose; a hook requires a measurable
   repeated gap, bounded output/timeout/re-entry behavior, and platform tests.
6. Define success and removal criteria, owner, affected platforms/versions,
   expected context/process overhead, and validation against both trigger and
   non-trigger cases.

## Output

Return: evidence, root cause, recurrence classification, proposed layer, exact
change, executable validation, false-positive/regression risk, and why higher-
overhead alternatives were rejected. Never learn from a model self-verdict alone.
