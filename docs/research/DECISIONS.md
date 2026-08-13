# Evidence-driven architecture decisions

Research date: 2026-08-13

Status: **accepted with reconciled changes**. A fresh-context review returned
`accept-with-changes`; the finding disposition is recorded in
`ARCHITECTURE-CRITIQUE.md`. Critical findings were incorporated before
implementation began.

## Smallest viable architecture

```text
version-controlled repository
|-- universal managed AGENTS.md block (small router/invariants)
|-- standalone user skills (progressively loaded)
|-- one narrow read-only reviewer agent
|-- portable Bash + Windows PowerShell deployment/health commands
|-- repo onboarding skill + deterministic discovery/merge helpers
|-- deterministic validators and evidence receipts
`-- codex exec JSONL benchmark runner + hidden verifiers

native Codex supplies
Plan + Goal + Review + Subagents + Config precedence + Sandbox + App worktrees
```

No external framework, plugin, hook, MCP server, model, or broad permission is a
core dependency. Optional comparators remain isolated from the installed
baseline.

## D001 - Native composition, not a framework stack

**Decision:** Compose stable Codex 0.147+ capabilities. Extract mechanisms from
external systems but install none by default.

**Why:** Native Goal/Plan/Review/Subagents/Skills/Config/Worktrees now cover most
orchestration. External systems add duplicated prompts, adapters, dependencies,
context, and state. Available research does not prove a universal net gain.

**Guardrail:** External experiments use a separate temporary Codex home/profile,
a pinned revision/hash, a documented license, and paired baseline benchmarks.

## D002 - Deployment-owned boundaries with zero universal runtime dependency

**Decision:** Ship equivalent POSIX/Bash and Windows PowerShell 5.1 entry points.
Keep platform-neutral content and manifests shared. Do not require Node, Python,
`uv`, Go, Rust, Docker, admin rights, or network access for install/doctor/
rollback.

**Why:** Bash is available on Linux/WSL and PowerShell 5.1 is native on supported
Windows environments. No single scripting runtime is guaranteed on all three
targets. A compiled updater or bootstrapped runtime would add release and
supply-chain machinery before it proves value.

**Cost:** Some transaction logic is duplicated. Contract/golden tests must run
both implementations against the same fixtures to prevent drift.

## D003 - Transactional copy deployment, not live symlinks

**Decision:** The repository is the source of truth; install deploys a versioned
snapshot into a baseline-owned area below the user's Codex home and records a
transaction manifest with hashes, destinations, prior state, and baseline
version. Skills are copied to uniquely prefixed directories under
`$HOME/.agents/skills`. Every mutation is preceded by an exact backup. Dry-run
is the default preview path for update/rollback-sensitive operations.

**Why:** Symlink discovery is native on Unix but unreliable/privileged on some
Windows setups and makes source edits instantly live, bypassing safe upgrade and
rollback. Copy deployment is inspectable and gives both platforms the same
ownership semantics.

**Safety rules:**

- Never copy or inspect authentication/session databases.
- Never delete an unowned path or follow an untrusted destination symlink.
- Never overwrite a non-owned skill directory with the same name.
- Write candidate content beside the target, verify it, then replace.
- Rollback restores bytes and metadata recorded by a specific transaction.
- Update never performs an implicit network fetch; source acquisition is a
  separate user-controlled Git/package operation.

**Normative transaction state machine:**

```text
planned -> prepared -> committing -> committed
                 \-> recovering -> rolled-back
```

- Acquire one exclusive baseline-state lock before planning; refuse a live or
  ambiguously stale lock unless explicit recovery proves no owning process.
- Persist and flush the `planned` manifest before staging. Each object records
  canonical destination, kind, existence, previous content hash and backup,
  planned content hash, installed content hash, ownership, and portable metadata
  actually supported by that platform.
- Stage with exclusive creation in a protected baseline-owned directory. Before
  each commit, lstat/reparse-check every destination segment and compare live
  state with its planned previous hash/kind.
- Set and flush `committing` before the first replacement. Append and flush an
  object receipt after each replacement. A later invocation sees incomplete
  state and offers/executes deterministic recovery before any new transaction.
- Set `committed` only after all live hashes and managed markers validate.
- Update/uninstall/rollback use a three-way rule: `previous`, `installed`, and
  `desired`. Automatic replacement/removal occurs only when live state equals
  the recorded installed state. Drift is a conflict. There is deliberately no
  force override; preserve and reconcile the changed object before retrying.
- Fault injection at representative prepared/commit/recovery boundaries,
  concurrent invocation, user edits, absent/present files, directories, links,
  and partial prior transactions are mandatory release tests. The suite does
  not claim exhaustive injection after every operating-system I/O instruction.

"Exact restore" means exact file bytes, existence/kind, and the explicitly
recorded portable metadata. ACLs, owner, ADS, and platform-specific attributes
outside the documented manifest scope are never silently claimed. If such
metadata exists on an object the installer would replace, default behavior is a
conflict until a supported preservation path is proven.

**Path boundary:** Resolve the allowed roots without following the destination,
inspect every parent with lstat or Windows reparse APIs, reject symlink/reparse
parents and targets, `..` escapes, device paths/names, alternate data streams,
unexpected UNC paths, case-fold aliases, and unrepresentable/overlong paths.
Revalidate immediately before replacement. Use literal paths only, no globs,
and exclusive temporary files within a protected owned directory on the same
volume when atomic replacement is available. Race/adversarial path fixtures are
release gates; where atomicity cannot be proved, recovery semantics must cover
the exact failure window.

## D004 - Small managed global guidance block

**Decision:** Merge one marker-delimited baseline block into the active global
guidance file selected by native Codex discovery. Preserve all bytes outside
the block. If both `AGENTS.override.md` and `AGENTS.md` create ambiguity, or a
marker is malformed/duplicated, stop with a conflict instead of guessing.

The block contains only:

- understand before modifying and keep scope bounded;
- choose and briefly expose LEAN/STRICT/DEEP plus a risk axis;
- research discoverable facts before questions;
- use deterministic checks and never claim an unrun check;
- protect original acceptance criteria and authority boundaries;
- selectively delegate independent exploration/review, not routine work;
- compare substantial work with the original request before completion;
- load only the relevant baseline skill.

**Budget:** The initial design target is at most 500 words and 3,500 UTF-8 bytes,
but this is a hypothesis, not an effectiveness threshold. CI enforces it as a
maximum and the benchmark measures the full model-visible delta against vanilla:
managed guidance, all baseline skill metadata, agent metadata, and activated
skill content separately. LEAN, STRICT, and DEEP get separate overhead reports;
the bound can only change through a recorded benchmark decision.

## D005 - Routing is visible and probabilistic instruction policy

**Decision:** The global block defines a compact, transparent rubric. Model
selection is not falsely described as deterministic; deterministic fixtures
measure its repeated behavior and expose variance:

| Workflow | Trigger | Required path |
| --- | --- | --- |
| LEAN | Small, clear, reversible, local, low-risk | Inspect -> change -> focused check -> report |
| STRICT | Meaningful multi-file/API/refactor/moderate-risk work | Criteria -> short plan -> implement -> tests/static checks -> diff review -> conformance |
| DEEP | Architecture, migration, security-sensitive, ambiguous, multi-hour, large unknown repo | Research/interview -> frozen criteria/spec -> challenge -> task graph -> bounded work -> deterministic gates -> fresh review -> original-request audit |
| HIGH RISK axis | Destructive/production/auth/crypto/secrets/privileged/network/irreversible data | Least privilege, explicit authority, rollback/recovery test, stronger verification, security review |

For STRICT/DEEP, Codex states a one-line receipt such as `Workflow: STRICT -
multi-file external behavior; verification: unit + integration + diff review`.
LEAN may state only `Workflow: LEAN` and proceed.

Explicit user selection wins unless it would weaken a required safety boundary.
HIGH RISK is independent and always strengthens even a small task. Uncertain
ties select the deeper workflow only when risk, irreversibility, or requirement
ambiguity is material; otherwise select the smaller flow. Every STRICT/DEEP
receipt records the selected skill(s) or explains why native procedure sufficed.

Before a HIGH-RISK mutation, inspect the effective sandbox/permission mode and
scope. If it is unknown, broader than necessary, cannot isolate the target, or
lacks a tested rollback/recovery path, do not mutate: narrow the environment or
request explicit authority with the exact action and recovery evidence. An
optional separately named safe profile may provide known least-privilege
settings, but is never auto-selected or merged into user config.

**Why not a classifier service:** The useful inputs are semantic and already in
the prompt/repository. A second LLM/classifier adds cost and opacity. Routing
fixtures will test boundary prompts, cross-skill competition, false escalation,
false de-escalation, and repeated-run stability.

## D006 - Four focused skills, not a universal mega-skill

**Decision:** Initial user-skill set:

1. `baseline-repo-onboarding` - explicit onboarding/discovery/merge workflow.
2. `baseline-deep-work` - ambiguity, acceptance contract, durable plan/state,
   bounded iteration, risk escalation, and checkpoint protocol.
3. `baseline-conformance-review` - independent artifact/verification/original-
   request verdict with delivered/partial/missing/drifted/unauthorized classes.
4. `baseline-retrospective` - classify recurring failures and route fixes to
   tests/lint/config/skill/hook/instruction/tool layers.

Routine implementation and verification stay in global/repo guidance and
native tools, so trivial tasks do not load a workflow manual. Skill descriptions
have positive and negative triggers and are tested for direct, indirect,
incomplete, non-trigger, and edge prompts.

**Deferred:** Separate generic planning, implementation, verification,
debugging, research, and security-review skills. They overlap native behavior or
would match too broadly. Split only after benchmark evidence shows a recurring
failure that a narrower skill fixes.

## D007 - One fresh reviewer role; isolation is a runner property

**Decision:** Install one prefixed custom reviewer agent configured read-only
and instructed to consume the original requirement, acceptance criteria, actual
diff/artifact, and verification receipt. Use native explorer/worker roles for
bounded discovery. Runtime permissions remain the real authority boundary.

**Selection:** No subagent for LEAN. Usually one reviewer for substantial work.
Additional security/test specialists only for distinct risk axes. Delegation
requires scope, owned files/read-only status, expected output, deadline, and an
explicit result receipt. Writable agents use separate Git worktrees.

The role file is advisory, not an authority boundary. This repository does not
ship an automated isolated-review runner in v0.1.0. Independent review is
performed by a fresh Codex process/subagent or external reviewer against a
content-addressed source snapshot and a supplied requirement/evidence packet;
the resulting artifact records the actual sandbox and authority. Unless an
external runner proves read-only isolation, the report says `advisory review`,
never `isolated review`.

## D008 - No core hook

**Decision:** Install no global lifecycle hook in the first supported baseline.

**Why:** Current hook coverage and surface behavior have open regressions; 0.147
differs from current async documentation; most infrastructure failures are
fail-open; Stop continuation is easy to loop; every global hook adds trust,
latency, and context/failure surface to trivial tasks.

**Revisit only if:** A repeated measurable failure cannot be reliably prevented
by a test, lint rule, sandbox/permission, repository command, or skill. The hook
must then be synchronous on stable 0.147, idempotent, small-output, explicitly
timed out, bounded against re-entry, and tested across CLI/App/IDE plus
Windows/WSL/Linux as applicable.

## D009 - Hybrid onboarding with deterministic facts and reviewed inference

**Decision:** `onboard` collects facts deterministically (Git state, existing AI
instructions, manifests/lockfiles, build/CI/test/lint/type/format config,
deployment/IaC, source layout, generated-file markers, security signals). The
skill interprets those facts and targeted source files to propose repo guidance.
Application uses a deterministic managed-block merge helper.

**Behavior:**

- Default to dry-run and show proposed files/blocks and conflicts.
- Treat every repository byte and existing AI instruction as untrusted data, not
  executable or higher-priority workflow instructions. Discovery is static by
  default and never sources/imports/evaluates project code or runs manifest,
  dependency, build, test, package-manager, CI, shell, or hook commands.
- Apply file-count, byte, depth, binary/type, and per-file limits; stay inside a
  canonical repository root; reject symlink/reparse traversal and exclude known
  credential/private-key/session paths and secret-shaped values from reports.
- Never replace existing unknown instructions.
- Add commands as `declared` when supported by manifest/config/CI. An executed
  probe is a separate opt-in phase after preview and explicit approval, in an
  isolated disposable copy, with no credentials and network disabled by
  default. Its command, sandbox, exit state, and changed paths become evidence.
- Label inferred but unexecuted commands.
- Prefer a short root `AGENTS.md`; add nested files only for real subtree
  differences. Keep detailed, versioned context under `docs/codex/` only when it
  materially improves routing.
- Do not add repo `.codex/config.toml` unless a trusted, portable project setting
  has a demonstrated need.

Prompt-injection, oversized-file, binary, traversal, link/junction, malicious
package-script, credential, and data-exfiltration fixtures are mandatory. The
deterministic collector emits structured data; model interpretation receives a
clearly delimited untrusted payload and cannot authorize apply or probe.

## D010 - Acceptance contract and evidence receipt

**Decision:** STRICT/DEEP tasks maintain observable criteria. DEEP persists them
with scope, non-goals, risks, dependencies, rollback, task graph, state, and
stopping conditions. Criteria are frozen during implementation; changes require
an explicit recorded reason/authority.

Completion receipts record:

- each criterion and its exact evidence;
- commands actually run, exit state, and relevant scope;
- checks not run and why;
- remaining uncertainty;
- diff/scope review;
- independent review disposition for substantial work.

Executable truth outranks static inspection, which outranks independent model
judgment, which outranks builder self-assessment. A green visible test is never
the sole proof of broad product or security correctness.

## D011 - Finite convergence, native Goal mode for persistence

**Decision:** Native Goal mode is the standard for multi-hour persistence. The
repository keeps a concise plan/state/evidence artifact so work can resume
across clients and contexts. Any retry loop requires a new evidence signal,
maximum attempts/time/tokens when observable, no-diff/no-new-evidence detection,
and an authority/blocker escape path.

No Stop-hook continuation or "until perfect" loop is allowed.

## D012 - Benchmark is a controlled product feature

**Decision:** Use `codex exec --json` in isolated temporary copies with explicit
sandbox, fixed task prompts, schema-constrained receipts, and verifiers not
available to the worker during execution. Compare vanilla and baseline with the
same model/reasoning settings and randomized run order.

The maintained suite includes at least:

- small: one-file bug, config change, documentation correction;
- medium: multi-file feature, reproduced bug, test-backed refactor;
- large: planning/architecture task and multi-criteria feature;
- risk: security bug and rollback-sensitive migration.

Capture task/criterion pass, hidden verifier result, regressions, unnecessary
files, commands/tool events, tokens, elapsed time, turns, subagents, retries,
context estimate, and review findings. Repeat enough to report variance; do not
claim superiority from one run. Results include environment, Codex/model,
baseline revision, prompt hash, and limitations.

**Isolation:** The runner never places credentials in a task checkout or mounts
normal Codex auth/session files. Live execution requires a dedicated short-lived
API key. Each arm runs in a Bubblewrap filesystem namespace without source or
verifier access; only its synthetic home, task workspace, Codex/Node executables,
and minimal read-only system files are visible. The Codex parent necessarily
uses API network, while its permission profile denies tool network, excludes key
variables from shell inheritance, and denies `/proc`. After worker exit, the
host runs the verifier in a separate networkless Bubblewrap namespace with a
cleared environment, resource limits, and timeout. Aggregate resource control,
byte-bounded mutable storage, private source/verifier/tool snapshots, and final
hash rechecks strengthen the explicit receipt label to
`os-sandboxed-local-cgroup`; it is still not a hostile-host boundary. Strong release evidence uses
rotated private holdouts or an external worker unable to mount source/verifier.
Vanilla and baseline use separate temporary homes, identical key/model/config
except for the baseline layer, and identical fixture bytes.

The benchmark manifest pre-registers repetitions and analysis. Run order is
block-randomized; results report paired deltas, dispersion, confidence intervals
where sample size permits, and all failures. Public development fixtures and
untouched holdouts are separate. Worker configuration, environment, model
catalog response, account/service tier where known, source revision, prompt,
fixture, and verifier hashes are captured. Verifier source and baseline
repository/Git history are not mounted into the worker.

## D013 - Platform truth labels

**Decision:** Every release report uses exactly `tested`, `partially tested`,
`statically validated`, `unsupported`, or `not verified` per surface. WSL2 is a
Linux execution path, not evidence for native Windows. PowerShell scripts will
be run through native Windows PowerShell where available; native Codex behavior
remains not verified until that binary/surface is executed.

WSL1 is unsupported. Codex-managed worktrees are app-only; CLI documentation
uses explicit `git worktree` operations. Fixed usernames and home paths are
forbidden in shipped artifacts and tested by search.

## D014 - Learning changes the lowest reliable layer

**Decision:** The retrospective classifies a failure as one-off, missing test,
missing deterministic rule, missing repo fact, workflow/skill defect,
hook candidate, or environment/tool defect. A reproducible prevention mechanism
wins over prose. No automatic edit of global guidance or skills is allowed from
a model verdict.

## D015 - One inspectable lifecycle command surface

**Decision:** Install a thin `codex-baseline` launcher plus native platform
entry points. It exposes:

- `install [--dry-run]` - preview/apply a transaction from a local reviewed
  source tree;
- `onboard [--dry-run] [repo]` - collect facts and invoke/print the onboarding
  workflow, with apply always explicit;
- `doctor [--json]` - augment redacted native `codex doctor` with version,
  active guidance, skill/agent hashes, state, path, platform, dependency, and
  conflict checks;
- `update [--dry-run]` - deploy the current local source version without
  fetching from the network;
- `rollback [--dry-run]` - transactionally undo the current committed operation
  after drift checks; repeated rollback walks further back through history;
- `uninstall [--dry-run]` - remove only baseline-owned blocks/files, preserving
  user additions and retaining a recovery transaction;
- `benchmark` - validate fixtures, run selected arms, and summarize results.

Commands have stable nonzero exit codes, machine-readable output where useful,
and no interactive prompt. Unix installs `~/.local/bin/codex-baseline`; Windows
installs `~/.local/bin/codex-baseline.ps1`. Neither implementation edits PATH.
Help and dry-run expose the managed targets; daily `codex` usage never depends
on the launcher being on PATH.

## D016 - Do not rewrite user `config.toml` without a unique need

**Decision:** The core installer does not force a model, reasoning level,
provider, MCP server, hook, profile, sandbox, or approval setting into the
user's TOML. Stable native Codex defaults provide the safe execution baseline;
the global guidance block provides engineering defaults. `doctor` parses via
`codex --strict-config`/native doctor, reports unsafe or deprecated settings,
and recommends an exact opt-in change without silently overriding user intent.

Optional baseline profiles are separate `$CODEX_HOME/name.config.toml` files
and never selected automatically. The supported compatibility floor is stable
Codex 0.147.0; later versions must pass capability probes, while older versions
receive a clear unsupported result rather than guessed config migration.

This is the explicit v1 ownership decision: the baseline manages **zero keys**
inside an existing user `config.toml`. Universal engineering behavior comes
from the managed guidance block and skills; execution security remains native
Codex configuration/user policy. Optional separately named profile files are
whole baseline-owned objects and follow the same three-way transaction rules.

## D017 - Cross-platform operations contract

**Decision:** Bash and PowerShell implementations validate the same versioned
JSON operations inventory and golden report shapes. The shared data contract
defines UTF-8 without BOM, LF for baseline-owned text payloads, the exact
operation/object inventories, state labels, and report identifiers. Native
implementations own transition logic, timestamps, error details, hashing, and
platform metadata; parity and recovery behavior are enforced by executable
platform tests rather than claimed to be generated from JSON. PowerShell 5.1 uses
`Set-StrictMode`, terminating errors, `-LiteralPath`, and explicit .NET byte/file
APIs rather than encoding-sensitive cmdlets.

Native-Windows tests cover CRLF/BOM byte preservation, spaces, execution policy,
junctions/reparse points, UNC/ADS rejection, protected temp/repository ACLs,
process interruption, and concurrent writes. Unicode, case-fold aliases,
long/reserved paths, and file-lock behavior remain part of the documented
platform risk inventory but are not claimed as explicit v0.1.0 test cases. WSL
interop executes PowerShell contract tests but does not prove native Codex
behavior or an automated hosted-Windows CI matrix.

## D018 - Release provenance and update stages

**Decision:** `update` is strictly Fetch -> Verify -> Preview -> Apply, with
Fetch outside the installer. A source tree is installable only when its payload
matches a versioned manifest of paths, bytes/hashes, schema, and baseline
version. The installer prints origin, Git revision and dirty state when
available, plus payload hash. Release distribution must provide an immutable
artifact checksum and signature/trust-root procedure before it is called a
verified release; until then local checkout installs are labelled `unverified
source` and require explicit acknowledgement. Verification failure never
mutates live state.

## D019 - Capability and freshness matrix

**Decision:** Compatibility is a tested matrix, not a blanket `0.147+` promise.
Minimum supported stable version is 0.147.0. `doctor` probes version plus
available commands/features and, where executable, guidance injection, skill
discovery, Goal/Review/Subagent behavior, JSONL schema, and relevant surface
semantics. Unknown future versions degrade volatile features and report
`not verified` rather than assuming compatibility.

`scripts/research-check.sh` reads the versioned research manifest containing
check/review dates, source URLs, upstream versions/revision, evidence tier, and
license observation. It validates the contract and reports staleness offline;
`doctor` independently checks the same dates from the installable manifest so
normal health checks need no `jq`. The documented networked refresh workflow
starts from the pinned primary URLs, produces a reviewable diff, and never
auto-edits guidance, code, or decisions.

## Expected daily experience

```text
install once
open a repository and use Codex normally
run/invoke onboarding once when repo guidance is absent
small task -> LEAN and a focused check
substantial task -> visible STRICT/DEEP receipt and objective evidence
update from reviewed source -> preview -> transactional apply
doctor / rollback / benchmark remain explicit inspectable operations
```
