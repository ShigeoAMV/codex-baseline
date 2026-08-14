# Release candidate report - 2026-08-14

## Verdict

Version 0.1.0 is an evidence-backed, Apache-2.0-licensed **unsigned public source
preview**, not a mission-complete or publisher-authenticated release.
Deterministic lifecycle, onboarding, recovery, prompt-input discovery, and
evaluation-runner mechanics are implemented. Mandatory real-model
paired/routing evaluation is still missing because no dedicated short-lived
benchmark key was available.

## Architecture

The repository is the source of truth. A transactional Bash implementation for
Linux/WSL2 and a native PowerShell 5.1 implementation for Windows install one
small managed global guidance block, four progressively disclosed skills, one
advisory reviewer role, a static repository collector, lifecycle/Doctor tools,
and a paired evaluation harness. The baseline owns no user `config.toml` keys,
hooks, auth/session state, or unrelated instructions/skills. Native Codex owns
configuration precedence, permissions/sandbox, Plan, Goal, Review, Subagents,
skill discovery, project guidance, and app worktrees.

## Adopted mechanisms

- Native AGENTS hierarchy and Agent Skills for thin global policy plus focused
  workflow detail.
- Transparent LEAN/STRICT/DEEP routing with a separate HIGH-RISK axis.
- Content-addressed unsigned-source verification, private verified snapshots,
  explicit acknowledgement, journaled three-way deployment, exact backups,
  recovery, rollback, uninstall, and drift conflicts.
- Bounded no-exec onboarding with conflict acknowledgement and deterministic
  marker-block apply; semantic interpretation remains a focused skill step.
- Executable verifiers, fresh advisory review, original-request traceability,
  and failure routing to the lowest reliable control layer.
- Native Goal continuation with durable repository state, plus explicit
  worktree isolation only for conflicting writable workers.

## Rejected or deferred mechanisms

No external orchestration framework, bulk skill pack, classifier service,
always-on hook, unrestricted autonomous loop, daemon, or universal Node/Python
runtime was adopted. Native Codex already covers the useful orchestration
surface; framework stacking adds context, conflicts, dependency, and supply-chain
cost without measured benefit. Hooks are deferred because current coverage,
trust, transcript, and subagent-payload behavior are not strong enough for a
core safety boundary. Ralph/Gauntlet ideas were reduced to bounded native Goal,
state, acceptance, verifier, and stop contracts.
The candidate-by-candidate record and strongest reasons are linked in
[`REJECTED-IDEAS.md`](research/REJECTED-IDEAS.md); this grouping is only the
release summary, not a substitute for the evidence matrix.

## Community and research effects

Recent user reports and primary research consistently warned that static
context can reduce success, generic skills are often neutral or expensive,
subagents help independent breadth more than coupled implementation, intrinsic
self-review is weak, visible tests invite gaming, and ambiguous requirements are
a dominant end-to-end failure source. Those findings produced the small global
layer, only four narrow skills, selective delegation, host-side verifiers,
explicit ambiguity handling, no core hooks, and honest holdout limitations.
Authoritative/upstream facts, community reports, and research strength remain
separated in the five dated research records and 12-source manifest.

## Verification performed

- WSL2/Linux: `./tests/run.sh`, 12/12 groups, including syntax/ShellCheck,
  payload/contract checks, clean install/idempotence/exact rollback, hard-crash
  recovery, journal/path/link/concurrency attacks, bounded onboarding, ten
  verifier fixtures, deterministic paired/routing/behavior/Canary mechanics,
  documentation, and
  real Codex 0.147 `debug prompt-input` discovery, and conflicting-write
  worktree isolation.
- Native Windows PowerShell 5.1: lifecycle and onboarding/benchmark suites cover
  install/update/doctor/rollback/uninstall, exact recovery, DACL/owner/Junction/
  path attacks, post-verification source mutation, conflict-safe onboarding,
  lazy traversal limits, and static benchmark contracts.
- Research: offline contract reports 12 pinned sources, current through the
  recorded review date, with no network during validation.
- Independent review: security, architecture/maintainability, and original-
  mission conformance findings are recorded under `docs/reviews/`; the detached
  `release-attestations` note on `a11ed2a` records final C0/H0/M0 sign-offs for
  the unchanged production payload.

Exact final-revision command counts and commit/payload binding belong in the
platform receipt after the last evidence commit and an external attestation;
tracked evidence cannot name its own future commit without creating another
untested commit.

## Platform status

| Surface | Status | Boundary |
| --- | --- | --- |
| WSL2 Ubuntu implementation | tested | Executed on the WSL2 Linux kernel/filesystem |
| Bare-metal Linux implementation | partially tested | Same Bash/Linux path plus static and isolated mechanics execute under WSL2; no separate distro/kernel matrix |
| Native Windows PowerShell 5.1 | tested | Real Windows filesystem/PowerShell; real native Windows Codex is absent |
| Codex CLI 0.147 prompt discovery | tested | Global/root/nested guidance and all skill metadata rendered |
| Real-model Linux/WSL paired, routing/behavior, and Canary runs | not verified | Dedicated evaluation key absent |
| Codex App/IDE | partially tested | Official contracts plus CLI discovery; no complete local cross-client run |

## Benchmark

Ten maintained tasks cover three small, three medium, two large, and two
risk-sensitive cases. Every unchanged starter fails its host-side verifier; a
deterministic credential-free test double proves paired isolation, changed-path
accounting, schema, and aggregation. Six routing boundary cases plus four
host-verified read-only behavior cases prove runner mechanics for classification,
DEEP/high-risk planning, ambiguity, onboarding, and conformance. These are not
real-model performance results. No baseline-vs.-vanilla advantage,
routing/behavior rate, token saving, or elapsed-time improvement is claimed.

## Minimal usage

```bash
./scripts/codex-baseline.sh install --dry-run
./scripts/codex-baseline.sh install --acknowledge-unverified-source
codex-baseline doctor
cd project && codex
codex-baseline onboard /path/to/project
```

On native Windows, use `scripts\codex-baseline.ps1` and the equivalent
PowerShell switches. Review an onboarding preview before `--apply`; acknowledge
existing instructions only after reconciling the reported paths.

## Remaining uncertainty and completion gate

The dedicated-key live run must execute all ten paired tasks for three
repetitions, `scripts/routing-probe.sh --repetitions 3`, and
`scripts/benchmark.sh --canary`, each with the independently recorded expected
Codex binary SHA-256, then preserve only safe receipts and report
inconclusive results honestly. Native Windows Codex, separate bare-metal Linux
distributions, and a full App/IDE matrix remain explicitly unverified/partial.
Public redistribution is permitted under Apache-2.0. A
publisher-authenticated release additionally needs an independently
distributed signing root; that stronger provenance claim is separate from the
original mission's mandatory live benchmark.
