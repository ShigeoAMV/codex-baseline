# Community and research findings

Research date: 2026-08-15

Community posts and issue reports locate failure surfaces. They do not establish
prevalence or effectiveness. Papers are labelled by strength and scope; very
recent 2026 preprints need replication.

## Findings that affect the design

1. Static context is scarce. A global `AGENTS.md` should be a short invariant
   and routing layer, not an encyclopedia.
2. Skills help mainly when narrow, expert, version-compatible, and paired with
   executable evaluations. Generic packs are often neutral or costly.
3. Subagents can materially shorten independent critical-path work, including
   large six-lane tasks, but useful lane count matters more than available slots.
   Shared writes, verbose duplicated context, idle waits, and unconstrained Sol
   children can erase the speed benefit and sharply increase token use.
4. Additional model passes help when they receive new external evidence. Pure
   self-correction can worsen a result.
5. Tests are strong but incomplete executable specifications. Visible tests can
   be overfit and do not prove hidden behavior, security, or product intent.
6. Ralph/Gauntlet-style iteration must be a finite state machine with frozen
   criteria, external verification, progress deltas, and explicit limits.
7. Underspecified tasks frequently produce scope and intent violations.
   Reversible discovery can proceed; risky or irreversible ambiguity needs a
   real clarification/authority gate.
8. Hooks are useful policy/telemetry aids but not a complete security boundary.
9. Output reduction is not task-cost reduction. Evaluate the provider bill,
   turns, latency, retries, and correctness on paired tasks rather than trusting
   a tool's byte counter or one model/provider result.

## Primary research

### Static repository guidance

| Evidence | Result | Strength and implication |
| --- | --- | --- |
| [Evaluating AGENTS.md](https://arxiv.org/abs/2602.11988), 2026-02-12 | Across CTXbench and SWE-bench Lite, LLM-generated context changed resolution by roughly -0.5/-2 points while increasing cost about 20-23%; human context showed a non-significant +2.4 points | Medium/high. Do not auto-inject generated summaries globally; measure concise human guidance |
| [On the Impact of AGENTS.md](https://arxiv.org/abs/2601.20404), revised 2026-03-30 | 10 repos / 124 PRs: 28.64% lower median runtime and 16.58% fewer output tokens at comparable completion | Low/medium workshop evidence. Good files may improve efficiency, but does not prove universal correctness gain |
| [Do Context Files Help Coding Agents?](https://arxiv.org/abs/2607.27250), 2026-07-28 | 17 tasks, three repos, 288 runs: no measurable correctness effect | Low due small task set. Reinforces paired local evaluation |

The disagreement is actionable: optimize context files for accurate commands,
boundaries, and routing, then benchmark rather than assuming benefit.

### Skills

| Evidence | Result | Strength and implication |
| --- | --- | --- |
| [SWE-Skills-Bench](https://arxiv.org/abs/2603.15401), 2026-03-16 | 39 of 49 public skills did not improve pass rate; mean +1.2%; token overhead reached +451%; three skills hurt due to mismatch/staleness | Medium/preliminary. Reject bulk packs; version and A/B-test each baseline skill |
| [Embedded/IoT skill study](https://arxiv.org/abs/2603.19583), published 2026-05-26 | 378 hardware-validated experiments across 42 narrow tasks: compact expert skills strongly outperformed no/LLM-generated skills | Medium/high within a narrow domain. Expertise plus objective hardware oracle is the useful pattern |
| [Skill Induction](https://openreview.net/forum?id=GmCoFYNEIU), 2026 | Hybrid agent gained 10.3 points on WebArena, but its model verifier accepted 20/31 failures and failed tasks polluted skill updates | Low/medium. Never learn/update skills from self-verdict alone |

### Verification and executable specifications

| Evidence | Result | Design consequence |
| --- | --- | --- |
| [TDD-Bench Verified](https://arxiv.org/abs/2412.02883) | 449 real issues; automated TDD improved fail-to-pass outcomes and coverage | Prefer a reproduced failing check before the fix where feasible |
| [WebApp1K](https://arxiv.org/abs/2505.09027) | 1,000 tasks / 19 models: tests and clear instructions help; long prompts suffer instruction loss | Keep criteria concise and executable |
| [Security tests as executable specifications](https://arxiv.org/abs/2608.09740), 2026-08-10 | 2,705 trajectories / 31 tasks / 16 CWEs: visible security tests improved joint hidden correctness by 19.3 points on average but hurt in two of nine conditions | Very recent. Add security tests, but retain hidden/independent checks and threat review |
| [Are SWE-bench issues really solved?](https://arxiv.org/abs/2503.15223), ICSE 2026 | 7.8% of accepted patches failed developer suites; 29.6% differed from ground truth, many clearly wrong | High. A benchmark's visible verifier is evidence, not full correctness |
| [Agentic property-based testing](https://openreview.net/forum?id=0ajBvBWKrB) | 100 Python packages; 56% manually reviewed reports valid, 86% among top 21 | Medium. Use property/differential tests for suitable high-risk behavior, then review findings |

The baseline verification ladder is therefore: build/lint/type checks, focused
fail-before regression test, integration/E2E behavior, then risk-triggered
property/differential/security checks. Every handoff reports tested scope and
remaining gaps.

### Test-time compute and review

- [Scaling test-time compute](https://arxiv.org/abs/2408.03314) shows adaptive
  allocation can beat naive best-of-N on reasoning tasks, but is not
  coding-specific.
- [Intrinsic self-correction limitations](https://openreview.net/forum?id=IkmD3fKBPQ)
  found that unaided self-correction often fails or degrades answers.
- [CRITIC](https://arxiv.org/abs/2305.11738) supports tool-interactive external
  feedback, while [SWE-Search](https://proceedings.iclr.cc/paper_files/paper/2025/hash/a1e6783e4d739196cad3336f12d402bf-Abstract-Conference.html)
  shows repository repair can benefit from proposal and validation search.

Extra rounds are justified only by risk/uncertainty and a new signal. The
baseline needs maximum attempts plus a no-progress stop.

### Multi-agent systems

| Evidence | Result | Design consequence |
| --- | --- | --- |
| [MAESTRO](https://arxiv.org/abs/2601.00481), 2026 | Across 12 systems, architecture affected cost, latency, and reproducibility more than many model/tool changes; run variance was high | Compare repeated runs and architecture cost, not a single success |
| [E2EDevBench](https://arxiv.org/abs/2511.04064) | Controlled systems met only about half of requirements on average; omissions and weak self-verification dominated | Maintain original-request traceability outside worker memory |
| [Agentless](https://arxiv.org/abs/2407.01489), FSE 2025 | A simple localization -> repair -> validation flow could beat complex agents | Use SOLO for coupled work; multi-agent routes still bear the burden of a real critical-path advantage |
| [Early diagnosis of wasted computation](https://arxiv.org/abs/2606.01365), 2026 | Tool reliability, recovery, repeated loops, information gain, and budget pressure are proposed early failure signals | Track retries/no-change/new-evidence signals in autonomous runs |

Provider case studies support mechanisms but not their marketing numbers:

- OpenAI's [Harness Engineering](https://openai.com/index/harness-engineering/)
  emphasizes agent-readable runtime state, progressive docs, architecture
  linters, isolated worktrees, and agent-to-agent review.
- OpenAI's [Symphony](https://openai.com/index/open-source-codex-orchestration-symphony/)
  uses ticket state and a dependency DAG, avoids blocked tasks, and restarts
  stalled workers; ambiguous/judgment-heavy tasks remain interactive.
- Cursor's [scaling agents](https://cursor.com/blog/scaling-agents) report found
  flat shared locks and integrator bottlenecks ineffective; planner/worker/judge
  cycles worked better.
- Anthropic's [multi-agent research](https://www.anthropic.com/engineering/multi-agent-research-system)
  reported a large breadth-first search gain at roughly 15x tokens; this does
  not generalize to shared-code implementation.

### Requirements and clarification

| Evidence | Result | Design consequence |
| --- | --- | --- |
| [UnderSpecBench](https://arxiv.org/abs/2607.02294), 2026-07-02 | On 2,208 DevOps variants, agents violated goal or scope 55.8-67.8% under underspecification; prose blast-radius warnings barely changed willingness to act | Require explicit scope/authority before irreversible or broad action |
| [ClarEval](https://arxiv.org/abs/2603.00187) and [ClarifyCodeBench](https://arxiv.org/abs/2607.00711) | Coding capability and efficient ambiguity detection/clarification are decoupled; more thinking helps only partly | Research discoverable facts first, then ask one material decision at a time |
| [SWE-RPG](https://arxiv.org/abs/2608.09072), 2026-08-10 | On 163 tasks, implicit requirements were the main bottleneck in 24.5-46% | Treat acceptance criteria and original-request conformance as first-class artifacts |

### Context retrieval

Peer-reviewed repository completion work consistently favors task-local,
structure/dependency-aware retrieval over broad dumps: [RepoCoder](https://aclanthology.org/2023.emnlp-main.151/),
[DraCo](https://aclanthology.org/2024.acl-long.431/),
[CodeRAG](https://aclanthology.org/2025.emnlp-main.1187/),
[CodeMEM](https://aclanthology.org/2026.findings-acl.834/), and
[AIRCoder](https://aclanthology.org/2026.acl-long.1166/). Their tasks are
narrower than autonomous issue solving, so this is directional evidence, not a
complete harness benchmark.

## Community and upstream failure surfaces

### Token and context optimizers

A July 2026 JetBrains paired-evaluation series provides the strongest
independent comparison found, while remaining Claude-specific:

- a forcibly activated Caveman skill reduced output tokens by 8.5%, not the
  advertised 65%, because code and tool calls dominated agent work;
- RTK v0.43.0 produced real per-command compression but increased median
  low-effort task cost by 7.6% and was neutral at high effort; its internal
  counter substantially overstated the provider counterfactual;
- Ponytail v4.8.4 reduced median task cost by 10.3%, time by 11%, and written
  code by 15% without a detected task-score difference. Its own OpenAI
  reproduction nevertheless measured GPT-5.5 at 38.7% higher cost and slightly
  slower, demonstrating that prompt-level optimization is model-specific.

The newer CtxWire, Caveman 2 input proxy, Headroom releases, and JetBrains
Context have useful mechanisms but no independent current Codex-on-Windows
full-task result. CtxWire adds command hooks/approval behavior; Caveman 2 and
Headroom interpose on provider traffic; JetBrains Context requires a service
subscription and targets large-repository retrieval rather than general output
compression.

Design response: install none by default. Extract only a compact invariant that
checks existing repository code, the standard library, and native platform
capabilities before adding dependencies or abstractions, with validation,
security, accessibility, compatibility, tests, and requested behavior outside
the simplification budget. Keep external tools isolated until paired results on
the current Codex/GPT stack show a net benefit.

### Subagent lifecycle

Upstream reports include a spawn acknowledged without execution ([#23296](https://github.com/openai/codex/issues/23296)),
a nominal 300-second wait lasting hours ([#24951](https://github.com/openai/codex/issues/24951)),
finished children consuming slots ([#13947](https://github.com/openai/codex/issues/13947)),
skill-trigger ambiguity ([#23496](https://github.com/openai/codex/issues/23496)),
and dynamic payload loss with a custom provider ([#35932](https://github.com/openai/codex/issues/35932)).
Reddit reports both useful parallel unit-test work and token doubling,
busy-polling, and over-spawn ([availability thread](https://www.reddit.com/r/codex/comments/1rvm2si/subagents_are_now_available_in_codex/),
[busy-polling](https://www.reddit.com/r/codex/comments/1vkqwz1/how_to_spawn_subagents_without_codex_looping_and/),
[over-spawn](https://www.reddit.com/r/codex/comments/1rfeigi/subagent_madnress_with_0105/)).

Three 2026-08-15 community samples reinforce, but do not prove, the current
design: users report that narrow child scopes outperform broad duplicated
prompts ([Sub-Agent Usage](https://www.reddit.com/r/codex/comments/1tzv912/subagent_usage/));
some report Sol-parent/Luna-child delegation as an efficient practical route
([Sol/Luna experience](https://www.reddit.com/r/codex/comments/1veqtnq/delegating_tasks_from_sol_to_luna_subagents_is/));
and others diagnose unexpectedly high consumption when expensive children run
without visible routing/telemetry ([token-burn case](https://www.reddit.com/r/codex/comments/1vfbgtp/if_you_experience_extensive_token_burn_and_use/)).
These are anecdotal failure/success signals, not product contracts or prevalence
estimates.

Design response: Codex automatically chooses SOLO/TEAM/SWARM from the exact
number of independent, immediately runnable lanes. Each delegated task needs a
minimal scope, output contract, ownership, deadline, receipt, bounded wait, and
explicit closure. No filler children or overlapping writes; task-local child
model hints fall back once and runtime facts remain `unverified` when not
observable. Measure correctness, wall time, total/cached tokens, handoff bytes,
and duplicated context together.

### Hooks

Reported failures include huge visible context injection ([#16933](https://github.com/openai/codex/issues/16933)),
write paths bypassing hooks ([#17794](https://github.com/openai/codex/issues/17794)),
trust bypass problems ([#24093](https://github.com/openai/codex/issues/24093)),
and encrypted delegated messages that a hook cannot inspect ([#33284](https://github.com/openai/codex/issues/33284)).

Design response: no core hook. Any future hook gets a per-release, per-surface,
per-tool smoke test; OS sandbox, Git policy, CI, and deterministic validators
remain authoritative.

### Guidance and workflow frameworks

Users report both reliable `AGENTS.md` loading and apparent misses; an upstream
reproduction found intermittent missing parent context in a subtree
([#25651](https://github.com/openai/codex/issues/25651)). Debugging advice is to
inspect rollout/prompt input rather than infer loading from behavior
([discussion #12668](https://github.com/openai/codex/discussions/12668)).

Superpowers/Spec Kit praise centers on structure, audit trails, and fresh
review; recurring complaints center on obvious questions, token cost,
over/underengineering, unexpected worktrees/commits, and cumbersome Brownfield
or post-implementation flows ([HN](https://news.ycombinator.com/item?id=45547344),
[Spec Kit #2625](https://github.com/github/spec-kit/issues/2625),
[#1191](https://github.com/github/spec-kit/issues/1191),
[#442](https://github.com/github/spec-kit/issues/442),
[#2789](https://github.com/github/spec-kit/issues/2789)).

Ralph users repeatedly report endless/early loops, continuing after green CI,
unsupported "production ready" claims, context degradation, and missing
UI/product oracles. No independent comparative evidence was found for a
specific Gauntlet implementation.

Design response: adaptive depth, executable evidence, hidden/independent
verifiers, immutable criteria, and finite iteration. Popularity is not proof.
