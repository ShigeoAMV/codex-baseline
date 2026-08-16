# Rejected and deferred ideas

Research date: 2026-08-15

Rejection means "not in the universal supported baseline," not that a project
has no value. Rejected packages can remain isolated benchmark subjects. A
decision can be revisited when new evidence changes its measurable tradeoff.

| Idea | Status | Strongest reason | Revisit condition |
| --- | --- | --- | --- |
| Stack Superpowers + Spec Kit + OMX + GSD + BMAD + Gauntlet | rejected | Duplicated orchestration, conflicting triggers/state, extreme context and maintenance cost, and no comparative evidence of combined benefit | Never as a stack; test one isolated mechanism at a time |
| Large universal `AGENTS.md` | rejected | Static context has mixed/no correctness evidence and measurable cost; it becomes stale and crowds task/code context | Only increase a measured byte budget for a proven universal invariant |
| Generated global repository summaries | rejected | Research shows generated context can raise cost without correctness gain and becomes stale across repositories | A repo-local, owner-reviewed, freshness-labelled artifact proves benefit |
| Bulk install of skill collections | rejected | SWE-Skills-Bench finds most tested public skills add no pass-rate value and can add up to 451% token cost; skills are also a supply chain | Individual pinned skill passes activation, security, and paired task evals |
| Core baseline as a Codex plugin | deferred | Plugins add marketplace/cache/update machinery and do not currently cover the IDE, while standalone skills cover CLI/IDE/app | Distribution of multiple mature capabilities materially improves install/update UX across required surfaces |
| Global Stop hook that continues until tests pass | rejected | Stop `block` means continue, infrastructure is mostly fail-open, repeated hooks can loop, and tests can be incomplete/gamed | No revisit; native Goal mode plus explicit bounded gates is safer |
| Any core lifecycle hook in v1 | deferred | Stable 0.147 conflicts with current async docs and open CLI/IDE/tool-coverage issues prevent a dependable universal boundary | A repeated failure has no lower-layer fix and a synchronous bounded hook passes the cross-platform/surface matrix |
| Hook-only secret, permission, or completion enforcement | rejected | Hosted/special tool paths can bypass hooks; crashes/timeouts/malformed output can fail open | Never as sole enforcement; hooks may complement OS sandbox, CI, and deterministic rules |
| Custom Ralph continuation engine | rejected | Native Goal mode already preserves objective/completion audits; open loops add drift, cost, false done, and side-effect risk | A benchmark shows a bounded external orchestrator adds unique value over Goal mode |
| Unlimited Gauntlet/doubt iterations | rejected | Intrinsic self-review is weak and extra rounds without new evidence waste compute or degrade results | A finite risk-triggered review with new evidence, max rounds, and no-progress stop is allowed |
| Blind subagents or maximum fan-out for every meaningful task | rejected | Slot count is not useful-lane count; duplicated context, integration, shared state, and idle lifecycle can cost more tokens and time | Automatic TEAM/SWARM is allowed only for evidenced immediately runnable lanes and remains subject to live gates |
| Parallel writable agents in one checkout | rejected | Overlapping files and shared Git state make ownership and rollback ambiguous | Separate worktrees, non-overlapping ownership, and integration order are explicit |
| User-selected TURBO/parallelism mode as a required task decision | rejected | The product goal is zero routine orchestration decisions for the user | Respect explicit veto/caps, but otherwise Codex selects SOLO/TEAM/SWARM itself |
| Fill all six slots or routine best-of-N duplication | rejected | Artificial lanes consume context/tokens and add integration without critical-path value | At most two competing hypotheses when high uncertainty makes a wrong path more expensive than duplicate analysis |
| Global child model/effort defaults or model-catalog/`multi_agent_v2` hacks | rejected | Offered models/capabilities vary by runtime and account; hidden global routing can burn tokens or break compatibility | Task-local offered model hint, one inherited fallback, and honest actual-model telemetry |
| Duplicate planner/researcher/tester wrapper-agent suite | rejected | Built-in explorer/worker plus the existing reviewer cover the needed roles; extra wrappers add prompt and maintenance surface | Add a role only after a distinct permission/context contract and paired result prove unique value |
| Automatically enable Fast/Ultrafast as an orchestration optimization | rejected | Session speed and its quota/economic tradeoff belong to the user; Ultrafast has no stable Codex config contract | Fast only through explicit optimizer apply; Ultrafast remains non-mutating unavailable until an official contract/probe |
| Hidden task classifier service/model | rejected | Adds cost, latency, and opaque behavior for a semantic decision the main agent can state and fixtures can test | A controlled benchmark shows materially better routing at acceptable overhead |
| New inline `[profiles.*]` config | rejected | Removed native profile format since 0.134 and can conflict with separate profile files | Never for supported 0.147+ |
| `codex exec --full-auto` | rejected | Removed in stable 0.147 despite stale prose; it also obscures actual sandbox intent | Never; use explicit sandbox/approval settings |
| Broad `danger-full-access` default | rejected | Violates least privilege and turns repository/prompt mistakes into host-level effects | Only an explicitly isolated external runner may select it for one controlled invocation |
| Background/implicit Git-pull update | rejected | Mutating a checkout or updating without an explicit lifecycle command complicates pinning, review, and rollback | Never; v0.2.0 instead uses explicit bounded release acquisition, exact verification, offline fallback, and transactional apply |
| Live source symlinks as deployment | rejected | Source edits become instantly active, bypass transaction/rollback; Windows symlink behavior is uneven | Optional developer mode only, never the default install |
| Node/Python/uv as mandatory installer runtime | rejected for v1 | None is guaranteed on native Windows plus Linux/WSL; bootstrapping adds dependencies and network/supply-chain surface | Cross-platform maintenance data proves dual native scripts cost more than a pinned runtime |
| Docker as the universal baseline runtime | rejected | High friction and unavailable/inappropriate for ordinary local one-line tasks | Benchmark workers may use containers for isolation, not daily install |
| GitHub Spec Kit globally | rejected | Valuable traceability but excessive artifact/process overhead for small and Brownfield tasks | Isolated large/regulatory tasks show net benefit in paired benchmarks |
| Superpowers globally | rejected | Strong discipline but intrusive auto-triggered process, subagent/token cost, and duplicated native Codex behavior | Pinned experimental profile wins a representative paired suite |
| JRA `grill-me` package | rejected | Essentially no adoption/release/Codex evidence; native mechanisms cover it | None; use independently specified interview mechanism |
| Raw Ralph loop | rejected | Unbounded execution and unreliable stopping are the central known failures | None; only the extracted bounded state principles survive |
| `pi-gauntlet` installation | rejected | Pi-specific lock-in, high persona/skill/extension footprint, unresolved license metadata | A Codex-native port with clear license and comparative evidence |
| OMX as baseline | rejected | Large invasive runtime, Linux bias, license ambiguity, state/deadlock/Stop-loop issues, and near-total native overlap | Only isolated expert experimentation after license resolution |
| Archived/old GSD | rejected | Governance/token incident and archival | Never; Open GSD is a separate candidate |
| Open GSD as baseline | deferred/experimental | High churn and large installer/hook/artifact surface despite useful durable phases | Pinned stable release passes security, rollback, and paired outcome benchmark |
| BMAD as baseline | deferred/experimental | Dependency/role/artifact footprint exceeds native needs; loop lacks native Windows | Pinned, narrowly scoped profile demonstrates improved large-task conformance |
| Pilot Shell | rejected | Proprietary license, heavy dependency/global-config footprint, Claude-first design, unsupported independent token claims | No universal adoption; proprietary evaluation only if user separately licenses it |
| Agent Validator dependency | deferred/experimental | Narrow deterministic design is promising, but independent adoption is low and Node becomes mandatory | It beats built-in verifier orchestration in paired tasks and passes supply-chain review |
| Proof Loop package | deferred/extract | Minimal protocol is useful but project is young, unreleased, and Windows evidence is weak | Mechanisms are implemented locally; package adoption requires maturity and platform tests |
| Model self-verdict as "done" | rejected | Research and benchmark audits show accepted patches can still be wrong and skill induction can learn from failed outcomes | Never alone; a verdict may supplement executable/independent evidence |
| Automatically append every failure to instructions | rejected | Creates context bloat and treats symptoms instead of enforceable causes | Only stable, repeated, non-mechanically-enforceable behavior may become concise guidance after review |

## Ideas deliberately extracted

- Spec Kit: clarify, freeze criteria, analyze consistency, trace spec -> tasks.
- Superpowers: right-size process, fail-before tests, fresh review handoff.
- Ralph/Open GSD: durable state and fresh contexts, but bounded.
- Gauntlet/pi-gauntlet: reviewer independence and original-request comparison.
- BMAD: evidence-owned findings, review lenses, content-addressed snapshots.
- Source-driven development: bind volatile implementation to exact upstream
  version/documentation.
- Doubt-driven development: adversarial review only when risk justifies a new
  evidence-producing pass.
