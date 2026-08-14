# Candidate evaluation

Research date: 2026-08-14

Decision vocabulary:

- **Adopt**: use directly in the supported baseline.
- **Extract**: implement the useful mechanism without installing the framework.
- **Experimental**: isolate, pin, and benchmark; never enable globally by default.
- **Reject**: do not install or depend on it for the baseline.

The matrix compresses the mission's evaluation fields as follows: `Current`
covers maintenance, releases, real use, bugs, and license; `Fit` covers Codex
compatibility and Windows/WSL/Linux/app/CLI; `Cost/risk` covers token/context and
workflow overhead, lock-in, dependencies, and security; `Value` covers
verification, scale, requirement preservation, extensibility, and native
equivalence. Community reports are expanded in `COMMUNITY-FINDINGS.md`.

## Native foundation

| Candidate | Purpose and architecture | Current / platform evidence | Cost, risk, and testability | Decision |
| --- | --- | --- | --- | --- |
| Native `AGENTS.md` | Layer global invariants with repo and subtree guidance | Stable across CLI, IDE, and app; global override and project precedence are implemented in 0.147 | Near-zero operational lock-in, but every loaded byte consumes context and stale/generated text can harm results | **Adopt**, with a measured small global block and conflict-safe repo onboarding |
| Native Agent Skills | Progressive workflow disclosure from `.agents/skills` | Stable across CLI, IDE, and app; open Agent Skills format; symlinks supported | Initial metadata has a bounded context cost; full skill costs only on activation; quality varies sharply | **Adopt** a very small tested set; reject bulk packs |
| Project `.codex/config.toml` and profile files | Durable trusted-repo overrides and explicit user configuration layers | Stable and cross-client; profiles changed in 0.134 and are now separate files | Strong native precedence/trust model; project keys have security restrictions and profiles are not automatic routing | **Adopt selectively**; do not write provider/auth/telemetry settings during onboarding |
| Native custom agents and subagents | Isolated roles and parallel bounded work | Stable in app, CLI, and IDE; token overhead and lifecycle issues remain | Useful for read-heavy breadth/fresh review; write conflicts and runtime permission inheritance need controls | **Adopt selectively**, with one fresh reviewer and explicit ownership rather than default fan-out |
| Plan, Review, and Goal modes | Proportional planning, native review, and persistent bounded work | Stable current product capabilities; Goal mode GA since May 2026 | Replaces much custom workflow machinery; plan/self-review still is not executable proof | **Adopt**; augment with acceptance/evidence artifacts and deterministic checks |
| Native hooks | Lifecycle scripts around tools, compaction, prompts, agents, and stop | GA, but 0.147 differs from current docs on async handlers and open surface/coverage bugs exist | Additive concurrent handlers, trust UX, mostly fail-open errors, context spill, and dangerous Stop continuation semantics | **Do not use in core initially**; only add a narrow synchronous hook after a measured need and cross-surface smoke tests |
| `codex exec --json` | Noninteractive automation and JSONL telemetry | Stable on CLI, with schema-constrained final output and token/tool events | Machine-testable and low lock-in; careful parser/error handling and auth isolation required | **Adopt** for benchmarks and controlled reviews |
| Native plugins | Package skills, MCP, hooks, assets, and templates | Stable in app and CLI 0.147; IDE extension lacks plugin support | Adds marketplace/cache/update surface; useful only when packaging justifies it | **Defer** for the core; standalone skills are more portable. Revisit for distribution after the baseline stabilizes |

Detailed native evidence and source-code/documentation disagreements are in
`EVIDENCE.md`.

## External workflow frameworks

| Candidate | Current upstream evidence | Architecture and platform fit | Cost, risk, verification, and native overlap | Decision |
| --- | --- | --- | --- | --- |
| [GitHub Spec Kit](https://github.com/github/spec-kit), [v0.16.2](https://github.com/github/spec-kit/releases/tag/v0.16.2) | MIT; released 2026-08-10 and active 2026-08-12; Python 3.11+ / `uv` | Constitution -> Specify -> Plan -> Tasks -> Implement, plus Clarify/Analyze/Checklist/Converge. Linux/macOS/Windows and current Codex skills | Formal traceability and convergence are useful for large/regulatory work. Medium/high artifact and context overhead; Brownfield/bugfix flow, PowerShell and template drift have generated recurring issues. Native Plan/Goal replaces much orchestration. | **Experimental + Extract** clarification, acceptance mapping, consistency analysis, and convergence |
| [Superpowers](https://github.com/obra/superpowers), [v6.3.0](https://github.com/obra/superpowers/releases/tag/v6.3.0) | MIT; active release 2026-08-12; current release improves adaptive ceremony, Codex waits, and worktree cleanup | Auto-triggered skills for brainstorming, plan, worktree, subagent implementation, TDD, and reviews; Codex plugin for app/CLI | Mature and test-oriented but still strongly controls behavior, adds approval stops and many agent turns, and historically had PowerShell/Codex adapter churn. Native Codex now covers most plumbing. | **Experimental + Extract** right-sizing, TDD discipline, and fresh review handoff; never globally mandatory |
| [JRA grill-me](https://github.com/JRA-CodingLab/grill-me) | MIT; created/updated 2026-06-30; no releases or meaningful adoption | Claude-oriented interview/check skill, no demonstrated Codex portability | Low install cost but almost no maintenance/effectiveness evidence; native Plan mode and user-input tools cover its core | **Reject package; Extract** one-question rounds, explicit assumption/confidence, and stop threshold |
| Interview skills from [Addy Osmani](https://github.com/addyosmani/agent-skills) and [Matt Pocock](https://github.com/mattpocock/skills) | Both MIT and active; releases 2026-08-04/06; current Codex portability work | Small composable skills; separate code/docs interview variants | Lower lock-in than full frameworks, but references/manifest packaging and secret handling still require audit and local activation tests | **Extract**, or selectively adopt only after a paired eval |
| Ralph method: [original](https://ghuntley.com/ralph/), [iannuttall](https://github.com/iannuttall/ralph), [ralph-orchestrator](https://github.com/mikeyobrien/ralph-orchestrator) | Fragmented implementations; orchestrator MIT v2.10.1 (2026-06-23), other activity/license hygiene varies | Fresh loop context plus durable specs/plan and test backpressure; some Codex support, uneven Windows support | Persistence and fresh context are useful; open-ended loops invite drift, false completion, cost, and side effects. Native Goal/Resume and subagents replace most machinery. | **Extract** frozen criteria, ledger, fresh verification, iteration/time/no-progress limits. Orchestrator only **Experimental** |
| [Gauntlet Loop](https://somethingbig.ai/gauntlet-loop) | July 2026 method article; no versioned software or license | Small pieces, separate builders and fresh critics against a quality bar; Codex-compatible conceptually | Independent criticism is useful, but repeated rounds with manual stop have high compute cost and no safe default boundary | **Extract** inspectable bar, blind critic, largest-gap verdict; add explicit budget and stagnation stop |
| [pi-gauntlet](https://github.com/jjuraszek/pi-gauntlet), [v4.8.1](https://github.com/jjuraszek/pi-gauntlet/releases/tag/v4.8.1) | Very young, seven stars, release 2026-08-12; SPDX license unresolved | Pi-specific gates, 13 skills, seven personas and three extensions | Strong original-prompt conformance ideas but direct Pi lock-in and high context/process cost; not designed for Codex | **Reject installation; Extract** phase gates and original-request conformance |
| [Oh My Codex / OMX](https://github.com/Yeachan-Heo/oh-my-codex), [v0.20.5](https://github.com/Yeachan-Heo/oh-my-codex/releases/tag/v0.20.5) | Highly active 2026-08-10 release; package says MIT but no root license recognized | Large TypeScript/Rust runtime with hooks, teams, HUD, interview, planning, Ralph, and ultragoal; Linux/macOS favored, native Windows/app caveats | Highest lock-in and attack/failure surface; open cross-chat state and conductor deadlock issues, historical Stop-loop failures. Native features replace nearly all capabilities. | **Reject core**; optional isolated research only after license resolution |
| Old GSD / [Open GSD](https://github.com/open-gsd/gsd-core), [v1.10.0](https://github.com/open-gsd/gsd-core/releases/tag/v1.10.0) | Old repo archived after governance/token incident. Open GSD MIT, active 2026-08-08 release but high churn on `next` | Discuss -> Plan -> fresh-context wave execution -> Verify -> Ship; durable state; Codex and Windows support | Useful state and verify-before-ship concepts, but large installer/hook/artifact surface. Recent fixes include Windows spawn safety, reparse-point deletion, false success and boundary bugs. | Old GSD **Reject**. Open GSD **Experimental + Extract**, pinned only |
| [BMAD Method](https://github.com/bmad-code-org/BMAD-METHOD), [v6.11.0](https://github.com/bmad-code-org/BMAD-METHOD/releases/tag/v6.11.0) | MIT plus trademark terms; active release 2026-08-10; Node 20.12+, Python 3.10+, `uv` | Adaptive product/architecture/build/review framework; optional test architect and loop. Main tools cross-platform; loop uses tmux and lacks native Windows | Better right-sizing and evidence ownership in v6.11, but still a large dependency/role/artifact system. Native Codex covers orchestration. | **Experimental + Extract** right-sizing, evidence-source rules, lenses, and content-addressed snapshots |
| [Pilot Shell](https://github.com/maxritter/pilot-shell), [v10.2.2](https://github.com/maxritter/pilot-shell/releases/tag/v10.2.2) | Active 2026-08-11; proprietary subscription, not open source | Claude-first; reduced Codex features; macOS/Linux/WSL2; installs Python/uv, Node, hooks, graph/browser/LSP stack and writes global config | Very high dependency, supply-chain, global-config, license, and lock-in cost. Token savings are vendor claims without an independent benchmark. | **Reject**; independently implement generic doctor/dry-run/rollback/measurement ideas |

### Ten-question external-framework policy ledger

Each entry explicitly answers the mission policy in order: **C** capability,
**N** native equivalent, **B** expected measurable benefit, **O** overhead,
**I** invasiveness, **M** maintenance, **U** user reports, **P** platform fit,
**D** disableability, and **E** evaluation plan.

- **Spec Kit** - C formal spec/traceability; N Plan/Goal plus focused skills
  cover most flow; B fewer requirement omissions on large/regulatory work; O
  medium/high files, context, Python/uv; I repository artifacts and commands; M
  active v0.16.2; U useful audit trail but Brownfield/questions/template drift;
  P Linux/WSL/Windows and Codex, app through skills; D isolate/remove profile;
  E only a pinned large-task paired comparator before adoption.
- **Superpowers** - C TDD/decomposition/worktree/review discipline; N current
  skills, Plan, subagents, review, and worktrees overlap; B higher executable
  completion without slowing LEAN; O many triggers/turns/tokens; I global plugin
  behavior if installed normally; M active v6.3.0; U strong structure plus
  over-ceremony and adapter/PowerShell churn; P CLI/app, Windows history mixed; D
  separate temporary Codex home only; E paired small/medium/large tasks.
- **grill-me/interview packages** - C ambiguity interview; N Plan and native
  user-input tools cover it; B fewer material assumption errors; O low/medium
  question latency; I small skill; M JRA weak, other collections active; U little
  independent outcome evidence; P concept portable, packaging varies; D remove
  one isolated skill; E ambiguity fixtures measuring unnecessary questions and
  conformance before any adoption.
- **Ralph/orchestrators** - C fresh-context persistence loop; N Goal/resume plus
  durable repository state; B fewer long-task dropouts; O high repeated compute;
  I process/state runner; M fragmented, one active MIT orchestrator; U useful
  persistence but endless/early-stop/side-effect failures; P uneven native
  Windows; D external runner can be omitted; E compare bounded recovery tasks,
  never evaluate an unbounded production loop.
- **Gauntlet/pi-gauntlet** - C independent iterative criticism and conformance;
  N review/subagents plus the conformance skill; B more actionable missed
  requirements per review round; O high reviewer tokens/personas; I method low,
  Pi package high; M article unversioned, Pi young; U little independent use and
  manual-stop risk; P concept portable, package Pi-specific; D advisory phase is
  removable; E measure new verified findings and false positives with a hard
  round limit.
- **OMX** - C broad teams/hooks/HUD/interview/Ralph runtime; N nearly complete
  native overlap; B no unique benefit established; O highest dependency/context
  and attack surface; I rewrites orchestration/global state; M very active but
  license ambiguity; U deadlocks, cross-chat state and historical Stop loops; P
  Linux/macOS favored with Windows/app caveats; D only isolated throwaway home;
  E none until license/safety are resolved, then broad paired suite.
- **Old/Open GSD** - C durable phased planning/execution/verification; N
  Goal/Plan/skills/subagents cover core; B possible long-task resumability; O
  large installer/hooks/artifacts; I high; M old archived, Open GSD active/high
  churn; U governance incident plus recent boundary/false-success fixes; P Open
  GSD claims Windows/Codex, old variants vary; D pinned external profile; E
  security/rollback gate followed by large-task paired runs.
- **BMAD** - C adaptive product/architecture/build/review roles; N native
  orchestration plus four skills covers baseline need; B possible complex-task
  coverage; O Node/Python/uv, roles and artifacts; I high; M active v6.11.0; U
  improved right-sizing but continuing framework footprint; P main flow
  cross-platform, loop lacks native Windows; D isolated profile; E paired large
  architecture/product tasks only.
- **Pilot Shell** - C integrated proprietary harness/tool stack; N almost all
  plumbing exists natively or in narrow scripts; B vendor token claims remain
  unverified; O very high runtimes/hooks/global config/license; I very high; M
  active v10.2.2; U no adequate independent Codex benchmark; P macOS/Linux/WSL2,
  reduced Codex and no native-Windows confidence; D subscription installation
  can be removed but global changes require audit; E no adoption, optional
  licensed evaluation only.
- **Agent Validator / Proof Loop** - C deterministic gates and frozen evidence;
  N repository tests plus structured receipts cover the mechanism; B fewer false
  completion claims; O Node for Validator, low Python stdlib for Proof Loop; I
  low/medium adapter/state; M Validator active but little independent use, Proof
  Loop quiet; U insufficient independent reports; P Validator cross-platform,
  Proof Loop Windows evidence weak; D clean standalone removal; E narrow paired
  verifier comparison before adding either dependency.

No external framework is adopted in v0.2.0, so the policy's adoption benchmark
condition is not triggered. Extracted mechanisms are independently tested by
the baseline routing, lifecycle, conformance, and evaluation contracts.

## Narrow mechanisms and collections

| Candidate | Evidence | Fit and risk | Decision |
| --- | --- | --- | --- |
| [Agent Skills standard](https://github.com/agentskills/agentskills) | Apache-2.0 code / CC-BY-4.0 docs; native current Codex format | Portable progressive format; says nothing about quality or safety | **Adopt format** |
| Deprecated [OpenAI Skills](https://github.com/openai/skills) | Upstream now points to OpenAI Plugins | Stale distribution source | **Reject old repo**; use official plugin directory selectively |
| Addy Osmani and Matt Pocock collections | Active, MIT, small/composable, current Codex work | Useful source, but releases still report manifest/reference issues; bulk install increases context and supply-chain exposure | **Reference / selective extract**, never blanket install |
| [Anthropic skills](https://github.com/anthropics/skills) | Mixed Apache and source-available licensing; Claude-specific assumptions | Good examples but license and portability vary by folder | **Reference only**, audit each item |
| [VoltAgent Awesome Agent Skills](https://github.com/VoltAgent/awesome-agent-skills) | Large discovery list; list license does not license targets | Popularity/curation is not a security or effectiveness review | **Discovery only; reject bulk install** |
| [Agent Validator](https://github.com/codagent-ai/agent-validator), v1.13.1 | MIT, Node 18+, active July 2026, low independent adoption | Deterministic build/lint/type/test/security gates and structured state with a Codex adapter. Narrower than full frameworks but adds runtime/dependency. | **Experimental comparator**, not initial dependency |
| [Proof Loop](https://github.com/LeoStehlik/proof-loop) | MIT, six stars, no releases, quiet since May 2026 | Frozen criteria, separate builder/verifier, evidence and mechanical done gate; stdlib Python but weak Windows evidence | **Extract** minimal acceptance/evidence protocol; experimental only |
| Source-driven development | Current [Addy Osmani skill](https://github.com/addyosmani/agent-skills/blob/main/skills/source-driven-development/SKILL.md); no independent workflow benchmark | Exact installed version -> current primary docs -> implementation -> tests. Adds research cost only for volatile APIs/standards. | **Extract as conditional gate** for volatile/security-sensitive dependencies |
| Doubt-driven development | Current [skill](https://github.com/addyosmani/agent-skills/blob/main/skills/doubt-driven-development/SKILL.md); no independent outcome evidence | Fresh critic over contract plus artifact, bounded to three rounds. Useful only when criticism yields new evidence. | **Extract as DEEP/risk option**, measure actionable yield and false positives |
| TDD-oriented workflow | TDD-Bench and related research support executable fail-to-pass tests, but visible tests remain incomplete and gameable | Strong verification mechanism when behavior is testable; should not force low-value tests for docs/config or replace integration/security criteria | **Adopt proportionally**, require fail-before where feasible and wider checks by risk |
| Context-engineering approaches | Repository-completion research consistently favors targeted structure/dependency retrieval over broad dumps | Task retrieval generalizes imperfectly to autonomous work but aligns with native progressive disclosure and indexed discovery | **Adopt mechanism**, not a new framework |

## Token and context optimizers

Headline percentages below are not treated as savings unless a paired full-task
measurement supports them. Command-output bytes, provider input tokens, model
output tokens, cached input, task cost, latency, and correctness are different
metrics.

| Candidate | Current upstream and platform evidence | End-to-end evidence and risk | Decision |
| --- | --- | --- | --- |
| [RTK](https://github.com/rtk-ai/rtk), [v0.45.0](https://github.com/rtk-ai/rtk/releases/tag/v0.45.0) | Apache-2.0, active, native Windows binary and WSL support. Current Codex setup installs `AGENTS.md` plus `RTK.md` instructions rather than a transparent Codex hook. | Individual filters materially reduce some verbose command outputs. A pinned independent Claude Code evaluation measured 7.6% higher median task cost at low effort and no difference at high effort; most session bytes never crossed the Bash hook. Tool-owned `gain` estimates are not equivalent to provider billing. | **Reject default installation**; direct, pinned command-level comparator only if a repository proves a noisy-output bottleneck |
| [CtxWire](https://github.com/pivanov/ctx-wire), [0.1.65](https://github.com/pivanov/ctx-wire/releases/tag/0.1.65) | MIT, created June 2026, native Windows installer, secret scrubbing, recoverable local logs, and current Codex PreToolUse integration. | No independent full-session Codex/Windows benchmark. Codex wiring adds a hook and modifies user config; wrapped commands are auto-approved by default unless its safer mode is selected. The young project has a much smaller operational history than RTK. | **Experimental only** in a separate Codex home, with safe mode, no broad shims/MCP wrapping, and paired bill/correctness measurement |
| [Caveman](https://github.com/JuliusBrussee/caveman), [v2.0.0](https://github.com/JuliusBrussee/caveman/releases/tag/v2.0.0) | The terse-output skill is MIT and Windows-compatible; the new input-compression proxy/runtime is BSL-1.1 and changes the provider boundary. | An independent forced-skill Claude benchmark measured 8.5% fewer output tokens, far below the historical 65% claim. Caveman 2 reports 33.2% fewer provider input tokens in its own pinned Claude benchmark, but was released three days before this review and has no independent Codex/Windows result. | **Reject core and proxy**; concise final responses remain a native style choice |
| [Ponytail](https://github.com/DietrichGebert/ponytail), [v4.9.0](https://github.com/DietrichGebert/ponytail/releases/tag/v4.9.0) | MIT Codex plugin with Node lifecycle hooks. It promotes reuse, standard-library/native capabilities, and minimal correct implementations. | The strongest independent result among the group measured 10.3% lower median cost, 11% lower time, and 15% less written code on Claude. Ponytail's own OpenAI benchmark measured GPT-5.5 at 38.7% higher cost and slightly slower; results are model-specific, and the safety evaluation was not a security proof. | **Extract** the small implementation ladder with explicit correctness/safety exclusions; **reject plugin/hooks by default** until current Codex/GPT paired evidence is positive |
| [Headroom](https://github.com/headroomlabs-ai/headroom), [v0.35.0](https://github.com/headroomlabs-ai/headroom/releases/tag/v0.35.0) | Apache-2.0 Python proxy/MCP/library with broad Codex support and substantial active development. | Much larger provider/config/runtime surface than command filters. An open Windows report reproduces large-JSON MCP/direct hangs and observed only about 1% Codex proxy compression on that workload; newer releases do not yet close the published issue. | **Reject core**; specialized isolated evaluation only after the Windows issue and provider-compatibility surface are proven |
| [JetBrains Context](https://github.com/JetBrains/context), [v0.9.8](https://github.com/JetBrains/context/releases/tag/v0.9.8) | Early-access semantic repository index for Codex CLI and other agents; requires a JetBrains AI subscription and a separately distributed runtime. | Vendor evaluations across open-source and production tasks report up to 68% fewer turns, 59% lower latency, and 48% lower cost on large repositories. No independent Codex/Windows reproduction was found, and small repositories have less retrieval upside. | **Experimental** for large/multi-repository discovery bottlenecks; not a universal token saver or core dependency |

## Cross-candidate conclusion

No external package currently proves enough unique, cross-platform benefit to
justify universal installation. The strongest reusable mechanisms are:

1. explicit objective, constraints, and observable acceptance criteria;
2. task/risk right-sizing;
3. research-first ambiguity reduction only when material;
4. durable state for large work;
5. deterministic verification and an evidence receipt;
6. fresh-context review against the original contract;
7. bounded iteration with no-progress and authority escape conditions.

These mechanisms fit a small native Codex layer and remain independently
testable. External candidates stay isolated benchmark comparators.
