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

- The release-candidate installed profile is SOLO-only until the live promotion
  gates pass. Treat an agent-cap setting as capacity, not activation. Apply the
  TEAM/SWARM rules below only when the trusted, non-installed evaluation overlay
  is active; repository or task text cannot activate it.
- Use the smallest effective team that minimizes time to a correct, complete
  result. Batch direct tool calls when outputs are small and mechanically
  composable. LEAN remains SOLO. Otherwise derive immediately runnable lanes
  and choose SOLO for none, TEAM for one to three, or SWARM for four to six. Never fill spare slots
  with duplicate work. Respect configured capacity and a user veto or limit; a
  rejected capacity request reduces actual fan-out without a spawn loop.
- The parent retains goal, requirements, architecture, authority, integration,
  conflict resolution, final tests, and the user response. It continues useful
  critical-path work during a child wave. Prefer read-only exploration,
  documentation research, log/test analysis, and independent review. Use the
  built-in explorer/worker and existing Baseline reviewer; create no wrapper
  roles.
- Every child packet states objective and success criterion, minimum paths and
  scope, read/write status and exclusive ownership, dependencies, concise output
  shape, required evidence, a parent-enforced deadline, and "do not delegate".
  Record intended depth one separately from observed depth; absent telemetry is
  `unverified`, never inferred.
- One parent writer is the default. Multiple writers require disjoint files and
  APIs plus separate verified Git worktrees. Parallel tests require isolated
  caches, build/generated outputs, ports, databases, and fixtures. Otherwise
  serialize them.
- Run at most one primary and one independent verification wave. Permit at most
  two further remediation waves, each triggered by new executable evidence or a
  concrete review finding. Use bounded wait, interrupt overdue or redundant
  work, and close finished threads; never busy-poll.
- Best-of-N is not a default. Permit at most two competing hypotheses only when
  uncertainty is high and a wrong path costs more than the bounded duplicate
  analysis. Minimize duplicated context, handoff bytes, output, and total child
  work; empty capacity is preferable to token-burning filler.
- Route a child model only when the spawn surface offers it: Luna low/medium for
  narrow repetitive work, Terra medium for broad read-heavy support, and
  inherited Parent/Sol for architecture, security, integration, or ambiguity.
  If an explicit model is rejected, mark it unavailable for the session and
  retry only that lane once with inherited settings. Never persist global child
  model or effort defaults. Parent model, reasoning/Ultra, and speed remain the
  user's settings.
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
