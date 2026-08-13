# Dogfood DEEP-work contract

Status: active until every gate in `docs/requirements/TRACEABILITY.md` has
authoritative evidence. This is the durable contract used to build this
baseline; `PLAN.md` is its concise checkpoint view.

## Objective and scope

Build a version-controlled, native-first Codex baseline for Linux, WSL2, and
native Windows that installs safely, onboards repositories, routes work by
complexity and independent risk, verifies results, supports rollback, and
measures vanilla versus baseline behavior.

In scope: current ecosystem research; global guidance; four focused skills; one
advisory reviewer; Bash and PowerShell lifecycle; static onboarding; doctor;
paired evaluation; platform, security, operations, and maintenance documents;
independent final reviews; all 46 mission gates.

Non-goals: replacing Codex orchestration; editing user model/provider/auth/MCP,
permission, hook, or plugin configuration; network fetching in lifecycle
commands; executing untrusted repository code during discovery; claiming
publisher authenticity from hashes; claiming native-Windows live behavior when
native Codex is absent; adopting an unproven external framework.

## Constraints and authority

- Preserve unknown user configuration and bytes outside owned markers.
- Never read, copy, mount, or log normal Codex auth/session material.
- No administrator privilege and no automatic broad permission enablement.
- Installation/update consume only a separately acquired, reviewed local source.
- Mutations stop on links/reparse points, drift, races, corrupt state, ambiguous
  ownership, missing authority, or unverifiable rollback.
- The original mission and traceability ledger outrank this plan.

## Dependencies

Linux/WSL lifecycle uses Bash and standard utilities. Native Windows uses
Windows PowerShell 5.1+. Live evaluation additionally requires Git, jq, Node,
Bubblewrap, timeout, prlimit, Codex CLI, and a dedicated short-lived benchmark
API key. Native Plan/Goal/Review/Subagents/Skills/config precedence remain Codex
responsibilities rather than bundled dependencies.

## Risks and rollback

| Risk | Control / rollback |
| --- | --- |
| User configuration loss | Exact ownership, preimage backup, three-way hashes, whole-file CAS, journal recovery, exact rollback tests |
| Path/journal manipulation | Closed schema, derived paths, allowlisted roots/IDs/states, no-follow boundaries, global preflight |
| Untrusted repository execution | Bounded static onboarding only; explicit separate authority for any later probe |
| Benchmark code attacks host | Separate worker/verifier Bubblewrap namespaces, no verifier network, cleared environment, limits/timeouts |
| Credential disclosure | Dedicated key only; no normal auth mount; tool env and `/proc` denied; artifact scan |
| Requirement drift | Frozen 46-gate ledger plus fresh original-request conformance review |
| Endless autonomous loop | New-evidence/progress requirement, bounded review rounds, measurable stop, missing-authority escape |

Every source change is recoverable through version control after the initial
source commit. Every installed-state change is independently recoverable through
the lifecycle journal and `rollback`/`uninstall` paths.

## Acceptance and verification

The 46 rows in `docs/requirements/TRACEABILITY.md` are the acceptance criteria.
Each row names the proof required; a row remains partial when evidence is
indirect or an environment capability is unavailable. Deterministic platform
suites, prompt-input discovery, static/verifier contracts, paired results, and
fresh reviews are complementary evidence rather than substitutes for one
another.

## Task graph

```text
dated research -> challenged decisions -> architecture freeze
                                      |
                     +----------------+----------------+
                     |                                 |
              lifecycle/onboarding              workflows/evaluation
                     |                                 |
              platform hardening                 behavior probes
                     +----------------+----------------+
                                      |
                         source freeze + full tests
                                      |
                   security / architecture / maintainability reviews
                                      |
                       original-request conformance audit
                                      |
                    traceability close + final report + release
```

Independent research, fixture construction, native-Windows validation, and
read-only reviews may run in parallel. Shared payload edits, manifest generation,
integration, versioning, and final conformance remain sequential.

## Checkpoints, stop, and escape

Checkpoint state, open decisions, test evidence, and next action live in
`PLAN.md`; durable requirements live in the traceability ledger. Work stops only
when all justified findings are resolved, required tests pass on the labelled
platforms, final reviews have no unresolved critical issue, and every mission
gate is verified or explicitly not applicable by its own wording.

If a dedicated benchmark credential or another authority-only input is missing,
finish all independent work, record exactly which evidence remains absent, and
ask for that input. Do not weaken the acceptance contract or loop without a new
signal.
