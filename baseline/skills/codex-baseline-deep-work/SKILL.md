---
name: codex-baseline-deep-work
description: Run a bounded evidence-driven workflow for architecture implementation, migrations, security-sensitive changes, multi-hour autonomous work, large unknown repositories, major refactors, or requests with material ambiguity and multiple acceptance criteria. Use for DEEP work or when explicitly asked for a rigorous spec-to-verification process. Do not trigger for read-only explanation, diagnosis, or architecture orientation without a requested durable plan; also exclude small clear fixes, routine documentation, simple configuration, and tasks a focused inspect-change-check loop can safely complete.
---

# Codex Baseline Deep Work

State `Workflow: DEEP`, the reason, planned verification, and planned independent
review. Treat HIGH RISK as a separate axis that can only strengthen this flow.

## Contract before implementation

1. Inspect repository guidance, current code/state, and authoritative external
   sources for facts that may have changed. Do not ask questions answerable from
   evidence.
2. Write a durable plan/state artifact containing objective, scope, non-goals,
   constraints, risks, dependencies, rollback/recovery, task graph, current
   milestone, blockers, and stopping conditions.
3. Translate the original request into observable acceptance criteria. Map each
   criterion to the strongest feasible proof. Freeze the contract; record any
   later change with source and authority.
4. Ask one concise question at a time only for a material product/architecture
   decision that evidence cannot resolve.
5. Challenge the proposed design with a fresh read-only critic before major
   implementation. Resolve Critical findings first and record dispositions.

## Execution

- Prefer one capable agent. Delegate only independent exploration, isolated file
  ownership, or fresh review. Give each task scope, output contract, ownership,
  deadline, and expected evidence. Never overlap writable work; use worktrees.
- Complete coherent milestones: criteria, implementation, executable checks,
  review, checkpoint. Keep the main context focused on requirements, decisions,
  and integration.
- Use Goal mode for durable continuation when available. The repository state
  artifact remains authoritative across clients/sessions.
- For volatile dependencies, record exact installed version, current primary
  source, source date, and compatibility evidence before implementing.

## Verification and convergence

Use executable truth, then static analysis, structured inspection, independent
judgment, and builder assessment in that order. Prefer a fail-before regression
test when feasible; add integration, property/differential, security, performance,
or recovery tests according to risk.

Every additional iteration must add a new signal: failing test, runtime evidence,
static finding, or independent counterexample. Stop on maximum budget, repeated
no-diff/no-new-evidence, missing authority, or an unmeasurable success condition.
Never loop "until perfect" or self-declare done from visible tests alone.

Before completion, invoke `$codex-baseline-conformance-review` with the original
request, frozen criteria, diff/artifact, and exact command receipt. Fix justified
findings, rerun affected checks, and leave unresolved uncertainty explicit.
