# Evidence register

Research date: 2026-08-15 (Europe/Zurich)

This file records claims that materially constrain the baseline architecture.
Candidate comparisons, community reports, decisions, and rejected mechanisms
live in the adjacent records. A source link is evidence for the stated claim,
not an endorsement of every recommendation on that page.

## Evidence method

1. Prefer current official documentation and behavior of the installed CLI.
2. Use upstream repositories, releases, source, and issue trackers for external
   implementation claims.
3. Use community reports to discover friction, not as ground truth.
4. Prefer primary papers for research claims.
5. Record conflict and uncertainty instead of flattening it.

The official OpenAI manual was refreshed on 2026-08-15 with the bundled
`openai-docs` helper. Its individual source pages are linked below. Local CLI
output is reproducible with `codex --version`, `codex doctor`,
`codex features list`, and the relevant `--help` commands.

## Inspected environment

| Signal | Observed evidence | Consequence |
| --- | --- | --- |
| Repository | Empty Git repository, no commits, no project `AGENTS.md` or `PLAN.md` before this work | No legacy baseline architecture to preserve; existing user-level configuration still must be preserved |
| Host | Ubuntu 26.04 on WSL2, kernel 6.18.33.2 | Linux and WSL behavior can be executed in this environment |
| Codex CLI | `codex-cli 0.147.0`; released 2026-08-07 at commit `be6e8eac...`; `codex doctor` reported it as latest stable on 2026-08-13 while 0.148 alpha builds existed | Pin research observations to stable 0.147.0; do not build on alpha behavior; reassess volatile details later |
| Codex health | 17 OK, one idle app-server, zero warnings and failures | Current CLI is suitable for behavior probes and benchmark execution |
| Stable feature flags | `goals`, `hooks`, `multi_agent`, `plugins`, `skill_search`, `unified_exec` reported stable | Prefer these native primitives; do not recreate them without contrary evidence |
| Local config | Customized global `AGENTS.md`, user config, two MCP servers, and an existing hook; auth configured | Installer tests need realistic preservation, managed ownership, and rollback; credentials must never be copied into repository artifacts |
| Native Windows | Windows PowerShell 5.1 and PowerShell 7 are reachable; native Codex 0.147.0 is installed and its v0.2 Doctor/config probes have executed | Run the v0.3 native optimizer/lifecycle matrix before making a current candidate claim; the old receipt remains historical |
| Runtimes | Node 24 is present in WSL; no universal runtime decision yet | Presence on one machine is not evidence for a cross-platform dependency |

## Native Codex evidence

| Mechanism | Current evidence | Architectural implication | Source |
| --- | --- | --- | --- |
| Guidance layers | Global discovery uses the first non-empty `$CODEX_HOME/AGENTS.override.md` or `AGENTS.md`. Project discovery walks root to CWD and prefers `AGENTS.override.md` at each level; closer guidance wins. The 0.147 source applies `project_doc_max_bytes` as a total project-doc budget, despite ambiguous short prose. | Keep universal guidance short and put discovered repository facts in repo guidance. Detect the active global file and malformed override situations; do not emulate project precedence. | [AGENTS.md](https://learn.chatgpt.com/docs/agent-configuration/agents-md), [0.147 source](https://github.com/openai/codex/blob/be6e8eac029b183056b7e4402879f15d2c85f61b/codex-rs/core/src/agents_md.rs#L88-L125) |
| Project config | Trusted repositories can provide nested `.codex/config.toml` layers; closest wins. Untrusted project config, hooks, and rules are ignored. Project layers cannot change provider/auth routing, profiles, notification commands, or telemetry. Relative paths resolve from the containing `.codex` directory. | Onboarding may add project-local safe settings, but must not depend on them in untrusted repos or write secrets/machine paths/provider settings. | [Config basics](https://learn.chatgpt.com/docs/config-file/config-basic), [advanced config](https://learn.chatgpt.com/docs/config-file/config-advanced#project-config-files-codexconfigtoml) |
| Profiles | Since 0.134, `--profile name` overlays `$CODEX_HOME/name.config.toml`; old inline `[profiles.name]` and top-level selectors are no longer the supported format and can conflict. | Profiles are explicit experimental/permission variants, not automatic task routing. Generate no legacy inline profiles. | [Advanced config](https://learn.chatgpt.com/docs/config-file/config-advanced#profiles), [0.147 loader tests](https://github.com/openai/codex/blob/be6e8eac029b183056b7e4402879f15d2c85f61b/codex-rs/config/src/loader/tests.rs#L107-L219) |
| Skills | Codex initially exposes skill name/description/path, then loads full instructions only when selected. The initial list is capped at 2% of context or 8,000 characters when context size is unknown. User skills live in `$HOME/.agents/skills`; repo skills in `.agents/skills`; symlinked skill folders are supported. Stable 0.147 still reads legacy `$CODEX_HOME/skills`, but marks that root deprecated in source. | Skills are the primary progressive-disclosure mechanism. Keep the set small and descriptions front-loaded and non-overlapping. Migrate legacy skills but do not install new baseline skills there. | [Build skills](https://learn.chatgpt.com/docs/build-skills), [0.147 host roots](https://github.com/openai/codex/blob/be6e8eac029b183056b7e4402879f15d2c85f61b/codex-rs/ext/skills/src/host_roots.rs#L87-L135) |
| Skill invocation | Skills can be invoked explicitly or implicitly by description; official guidance asks for positive, negative, incomplete, and edge-case activation tests. | Routing tests must check non-activation as well as activation. Scripts belong in a skill only for deterministic processing. | [Build skills](https://learn.chatgpt.com/docs/build-skills) |
| Plugins | Stable 0.147 plugins can package skills, MCP/connectors, hooks, assets, and task templates. Plugins cover app and CLI, but the IDE extension does not currently support them. | Do not make the core baseline a plugin merely for packaging; standalone skills are the broader common denominator. Reconsider a plugin only when distribution of multiple capabilities justifies the cache/marketplace layer. | [Plugins](https://learn.chatgpt.com/docs/plugins), [packaging](https://developers.openai.com/plugins/build/plugins), [0.147 release](https://github.com/openai/codex/releases/tag/rust-v0.147.0) |
| Subagents | Current clients support native child roles and bounded concurrent threads. Official guidance emphasizes context isolation, parallel work, lifecycle management, and task-specific role/model selection; extra children consume extra context/tokens and shared writes can conflict. | Select the smallest effective team from real independent lanes. Separate planned/actual fan-out, keep the parent integrating, bound waits/waves, and require worktree/test isolation for parallel writes/execution. | [Subagents](https://learn.chatgpt.com/docs/agent-configuration/subagents) |
| Custom agents | Stable built-ins include `default`, `worker`, and `explorer`; user roles live under `~/.codex/agents`, project roles under `.codex/agents`, and may override normal config fields. Current runtime permission overrides can supersede agent defaults. | Use narrow native explorer/reviewer roles where they add fresh context; do not mistake a role file for an enforceable permission boundary. | [Subagents](https://learn.chatgpt.com/docs/agent-configuration/subagents) |
| Model orchestration | Current GPT guidance recommends concise prompts, explicit output contracts, and delegating only bounded work whose result can be integrated. Available child model/effort choices are runtime capabilities, not a stable universal catalog. | Child packets carry only goal, minimal scope, ownership, dependencies, evidence, deadline, and compact output. Pin a child model only when offered; retry a rejected pin once with inherited settings and never persist a global child default. | [Latest model guide](https://developers.openai.com/api/docs/guides/latest-model) |
| Fast mode | Fast is a user-controlled Codex speed/service-tier setting rather than an orchestration decision. It can change latency and quota economics independently of child fan-out. | Parent/session speed remains user-owned. An explicit optimizer preset may manage only the documented Fast key pair; benchmark Fast separately from autonomous execution. | [Fast mode](https://learn.chatgpt.com/docs/agent-configuration/speed) |
| Ultrafast | The current Ultrafast preview is API-only and does not publish a stable Codex CLI/App `config.toml` activation contract. | Expose a future-proof command result, but return `unavailable`, nonzero, and byte-identical config until an official Codex config contract and positive capability probe exist. | [Ultrafast preview](https://openai.com/index/previewing-ultrafast/) |
| Long-running work | Goal mode is available in app, CLI, and IDE. Official guidance requires a clear outcome, constraints, definition of done, progress visibility, and intervention when blocked. | Use native Goal mode for durable work rather than a custom endless continuation loop. Persist repository-level checkpoints for portability. | [Long-running work](https://learn.chatgpt.com/docs/long-running-work) |
| Goal semantics | The stable 0.147 continuation template explicitly requires scope fidelity, progress, a requirement-by-requirement completion audit, and strict complete/blocked rules. Goal mode does not broaden permissions. | Native Goal mode already supplies most Ralph-style persistence required by the mission; custom code should provide objective gates and durable project evidence, not another continuation engine. | [0.147 goal template](https://github.com/openai/codex/blob/be6e8eac029b183056b7e4402879f15d2c85f61b/codex-rs/prompts/templates/goals/continuation.md) |
| Planning | Plan mode and proportional planning are native; official guidance also supports interview-first prompts and durable execution plans for large work. | LEAN must not force a plan. DEEP can use native Plan/Goal modes plus durable criteria and state. | [Best practices](https://learn.chatgpt.com/guides/best-practices) |
| Review | CLI provides `codex review` for uncommitted changes, base branches, or commits. | Use native review entry points where available; conformance still needs the original requirements and verification evidence. | [Code review](https://learn.chatgpt.com/docs/code-review) |
| Hooks | Hooks are stable in 0.147.0. Multiple matching hooks run concurrently, user/plugin hooks require hash-based trust, project hooks require a trusted repo, default timeout is 600 seconds, and large output spills after about 2,500 tokens. | Hooks are optional guardrails, not a default orchestration engine. Any adopted hook needs bounded output, explicit timeout, cross-platform commands, trust UX, and failure tests. | [Hooks](https://learn.chatgpt.com/docs/hooks) |
| Hook enforcement limits | Hosted tools bypass local Pre/PostToolUse hooks; specialized paths can opt out. Background hooks cannot block. A `Stop` block creates a new user-like continuation prompt, while `stop_hook_active` exposes whether continuation already happened. | Hooks are not a complete security boundary. Avoid a global Stop loop; use deterministic commands/tests and explicit stopping criteria. | [Hooks](https://learn.chatgpt.com/docs/hooks) |
| Worktrees | Codex-managed worktrees and handoff are currently desktop-app features; Git worktrees remain available manually in CLI workflows. Worktrees consume disk and have branch/cleanup constraints. | Do not require app-managed worktrees. Document manual Git worktrees for parallel writable CLI work and test cleanup behavior separately. | [Worktrees](https://learn.chatgpt.com/docs/environments/git-worktrees) |
| Non-interactive mode | `codex exec --json` emits JSONL events, including tool/file/plan events and token usage; `--output-schema` constrains the final response; `--ignore-user-config` and `--ignore-rules` aid controlled runs. | Use JSONL as the benchmark telemetry substrate and output schemas for machine-consumable reviewer/conformance results. | [Non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode) |
| CLI/documentation drift | Current prose still describes `--full-auto` as deprecated compatibility, but stable 0.147 help and release evidence show it removed. | Runtime capability probes and versioned compatibility checks outrank stale prose; never generate `--full-auto`. | [0.147 release](https://github.com/openai/codex/releases/tag/rust-v0.147.0), local `codex exec --help` |
| Security | `codex exec` defaults to read-only and official guidance says to use the least required permissions. Workspace-write normally keeps network off and protects `.git`, `.codex`, and `.agents`; required MCP initialization can fail closed. Permission profiles are beta and do not safely compose with legacy sandbox fields. | Benchmark and automation runners must set permissions explicitly and avoid broad access or user-auth exposure to untrusted code. Keep stable sandbox defaults in the universal core; permission profiles may be opt-in after compatibility tests. | [Non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode), [sandbox](https://learn.chatgpt.com/docs/sandboxing), [permissions](https://learn.chatgpt.com/docs/permissions) |
| WSL | Codex runs as Linux inside WSL2. WSL1 stopped being supported in Codex 0.115. Repositories under the Linux filesystem are recommended over `/mnt/c` for performance and semantics. | Treat WSL2 as a Linux execution path with an explicit interop layer; do not claim WSL1 support. | [WSL](https://learn.chatgpt.com/docs/windows/wsl) |
| Native Windows | Codex has native CLI/app/IDE support and a separate Windows sandbox. | Provide native PowerShell entry points and Windows path/quoting tests; do not assume WSL is the Windows implementation. | [Windows sandbox](https://learn.chatgpt.com/docs/windows/windows-sandbox) |
| Prompt inspection | Installed CLI 0.147.0 exposes `codex debug prompt-input`, which renders model-visible inputs without running a model. | Use it for deterministic guidance and skill-discovery probes where possible. | Local `codex debug prompt-input --help` and executed probe, 2026-08-13 |
| Built-in doctor | Installed CLI 0.147.0 exposes a redacted `codex doctor --json` report. | Baseline `doctor` should augment or consume native health data rather than duplicate it. | Local `codex doctor --help` and executed doctor, 2026-08-13 |

## Conflicts and uncertainties

- The current CLI proves WSL behavior but not native-Windows Codex behavior.
  PowerShell execution alone is not sufficient to label native Codex integration
  tested.
- Official docs describe supported behavior; they do not prove that every
  surface behaves identically in all releases. Cross-surface claims need local
  probes or must remain explicitly partial.
- Hooks are documented and stable, but their breadth makes a global quality-gate
  hook expensive and failure-prone. Adoption remains unproven until a narrower
  mechanism shows measurable benefit.
- The current hook documentation describes `async = true`, while stable 0.147
  source explicitly skips async handlers as unsupported. Async support existed
  only on later development code at the research date; the baseline must use
  synchronous hooks only if it adopts any. See [0.147 discovery
  source](https://github.com/openai/codex/blob/be6e8eac029b183056b7e4402879f15d2c85f61b/codex-rs/hooks/src/engine/discovery.rs#L461-L483).
- Current hook infrastructure failures, timeouts, missing executables, and
  malformed output are generally fail-open. An open issue demonstrates this for
  `UserPromptSubmit`, and another reports a Windows IDE surface dispatch gap.
  Hooks cannot be the only secrets or completion boundary. See [issue
  33630](https://github.com/openai/codex/issues/33630) and [issue
  33413](https://github.com/openai/codex/issues/33413).
- `codex exec --json` exposes usable telemetry, but benchmark fairness still
  depends on authentication isolation, prompt equivalence, task randomization,
  repeated trials, and verifiers hidden from the worker.
- The local global `AGENTS.md` contains repository-specific guidance. The
  baseline must preserve it, while `doctor` should identify the context cost and
  recommend moving project-only rules without changing them automatically.
