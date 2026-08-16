# Benchmark and behavior evaluation

The v0.3 suite has four arms: `vanilla`, `baseline-solo`,
`auto-homogeneous` with equal parent/child model, effort and speed, and
the real product arm `auto-routed`. Task, starter, account, sandbox, and repetition are
held equal; every arm receives a fresh workspace, HOME, and CODEX_HOME. Order is
stably randomized and alternated rather than letting warm-cache or arm-order
effects masquerade as acceleration.

The homogeneous arm is valid only when actual parent/child model, effort, and
speed telemetry proves equality. A requested setting or prompt label is not
proof; absent telemetry keeps that comparison `unverified` and blocks promotion.
The two AUTO arms receive the reviewed, hash-pinned evaluation overlay by
appending it to their fresh ephemeral global `AGENTS.md`; the baseline-SOLO and
vanilla arms never receive it, and it is never copied into task text. Per-arm
receipts bind the profile object, overlay bytes, final guidance bytes, and
agent-cap config bytes. The summarizer rejects an AUTO guidance hash equal to
the SOLO guidance hash and requires both AUTO config hashes to match each other
but differ from SOLO, providing a causal check that AUTO was actually activated.

Ten maintained tasks include six parallel-positive tasks with explicit two-,
three-, four-, and six-lane structures plus four serial negative controls.
Verifiers remain outside the worker workspace. Static mode proves each fixture
is well-formed and the starter fails its verifier:

```bash
codex-baseline benchmark --static
```

The live promotion gate uses ten paired repetitions per task/arm and 10,000
deterministic bootstrap resamples. Safety/scope/hidden-verifier quality must be
at least as good as both SOLO and vanilla; two AUTO-only verifier failures or
one verified safety or authority violation stops the suite before the next arm.
Across positive tasks AUTO must improve
paired median wall-clock time by at least 25% with the upper 95% ratio interval
below 1.0, make at least four of six tasks at least 15% faster, and make the
six-lane case at least 40% faster. No positive class may regress more than 5% at
equal quality. Serial controls must choose SOLO in at least 95% of runs with no
more than 5% median overhead. A SWARM route survives only with at least 30%
speed or ten percentage points of first-pass improvement. A route that is no
better in quality, slower, and more expensive is dominated and fails.

Tokens, cached input, cost, turns, retries, child effort, duplicated context,
handoff bytes, and unnecessary artifacts are reported rather than hidden. They
are diagnostic gates against waste, not permission to sacrifice correctness.
Fast is evaluated separately and never counted as subagent acceleration.
Without the dedicated key, these live facts remain `unverified`; the RC may be
built, but stable `0.3.0` and performance claims are not authorized. A key is
necessary but not sufficient for this candidate: its manifest explicitly marks
runtime orchestration telemetry and stable promotion as `unavailable` for the
current Codex JSONL contract.

Live release evaluation consumes quota. Run the three commands directly from
the reviewed checkout so every receipt covers the same full source scope. First
record the SHA-256 of the exact reviewed Codex executable; the runner freezes
that executable and refuses a mismatch rather than trusting a PATH name or a
self-reported version:

```bash
CODEX_BIN=$(readlink -f "$(command -v codex)")
CODEX_SHA256=$(sha256sum -- "$CODEX_BIN" | awk '{print $1}')
CODEX_BASELINE_BENCHMARK_API_KEY='<dedicated-short-lived-key>' \
  CODEX_BASELINE_EXPECTED_CODEX_SHA256="$CODEX_SHA256" \
  scripts/benchmark.sh --live --repetitions 10 \
    --host-evidence-verifier /reviewed/path/host-evidence-verifier \
    --expected-evidence-verifier-sha256 '<reviewed-verifier-sha256>'
CODEX_BASELINE_BENCHMARK_API_KEY='<dedicated-short-lived-key>' \
  CODEX_BASELINE_EXPECTED_CODEX_SHA256="$CODEX_SHA256" \
  scripts/routing-probe.sh --repetitions 3
CODEX_BASELINE_BENCHMARK_API_KEY='<dedicated-short-lived-key>' \
  CODEX_BASELINE_EXPECTED_CODEX_SHA256="$CODEX_SHA256" \
  scripts/benchmark.sh --canary
```

Execute the script paths directly; do not prefix them with an ambient `bash`.
`--expected-codex-sha256 HASH` is equivalent to the hash environment variable.
When a later reviewed candidate registers a telemetry adapter in
`benchmarks/manifest.json`, paired live mode additionally takes the inseparable
pair `--runtime-telemetry-adapter /absolute/reviewed/file` and
`--expected-runtime-telemetry-adapter-sha256 HASH`. These flags are live-only;
supplying one without the other, a linked/non-executable file, a hash mismatch,
or a contract/hash that differs from the manifest fails before any arm runs.
The current RC intentionally registers `null`, so it refuses a supplied adapter
and cannot produce promotion-authorizing orchestration telemetry. The manifest's
`runtime_telemetry_capability` records the exact independent blocker. Codex CLI
0.147 `exec --json` exposes the documented thread/turn/item vocabulary and turn
token usage, but no authoritative child lane, requested/actual child model and
effort, depth, waves, peak concurrency, or parent-settings events. The canonical
[Codex SDK event types](https://github.com/openai/codex/blob/main/sdk/typescript/src/events.ts)
and [item types](https://github.com/openai/codex/blob/main/sdk/typescript/src/items.ts)
therefore do not support a truthful adapter for the promotion contract. An
adapter based on model prose, private session files, or synthetic events would
fabricate proof and remains rejected.

The task verifier proves executable task correctness, while the host Git check
proves the declared changed-path scope. Neither can honestly infer first-pass
status, user interventions, safety, or authority from a successful exit. Those
four truths therefore remain `null` with `verification: unverified` unless a
separately reviewed, executable host-evidence verifier and its expected SHA-256
are supplied together. After each arm, that verifier receives a read-only JSON
descriptor for the task prompt, sandboxed workspace, events, last message, and
task-verifier log. It must emit exactly `first_pass`, `user_interventions`,
`safety_violation`, and `authority_violation`; the runner records the verifier
hash as provenance. Missing evidence blocks promotion, and a verified safety or
authority violation terminates the live suite before another arm starts.

All three live commands are Linux/WSL-only in the v0.3 candidate. `--tasks` and
`--repetitions` apply to paired mode, not Canary mode; mode flags are mutually
exclusive. Per-invocation timeout is bounded to 1-1,800 seconds; its transient
service gets a slightly longer hard runtime and whole-control-group kill.

Shared ChatGPT/Codex authentication is deliberately unsupported. Create a
dedicated, short-lived API key with the narrowest practical budget/permissions;
do not reuse the normal Codex session. The executable entrypoint first starts
fixed `/bin/sh`, removes Bash startup influences, and enters fixed `/bin/bash -p`;
privileged mode here only suppresses `BASH_ENV`, inherited functions, and
option variables and is dropped immediately. The runner then copies the input value to a
non-exported variable and unsets all credential variables before runner path
discovery or a runner-invoked helper. The final cgroup service receives two
bounded lines on stdin; its launcher exports the key only for the Codex parent.
No background FIFO writer retains the key after a caller crash. The key is
excluded from tool-shell inheritance, and normal
auth/session files are never read, linked, copied, or mounted. `/proc` is denied
by the Codex permission profile. Every expected output and the complete mutable
workspace and worker-HOME trees are scanned for the exact active key, the Canary
sentinel, and credential-shaped patterns in both file contents and relative
path names; missing/unreadable files, links, special entries, excessive depth,
entry count, or total bytes fail closed before verification or receipt
completion. Raw
JSONL/stderr still requires human secret review before publication; automated
scans remain a fail-closed heuristic rather than proof that arbitrary secrets
are absent.

The runner captures process/verifier success, elapsed time, turns, commands,
file-change events, actual changed/unnecessary paths, failed command events,
tokens/cached input/cost where observable, and raw subagent events. The v2
receipt separates planned from actual fan-out and records lane IDs, capacity,
requested/actual child model and effort, depth, waves, peak concurrency, spawn
errors/fallbacks/interrupts/timeouts, write/test isolation, conflicts,
integration rework, handoff bytes, duplicated context, and parent settings
before/after. Host Git diff analysis separately records last-message bytes,
added lines, code/comment/prose/blank-line counts, repeated added lines, pure
comment diffs, and unallowed files. These are deliberately conservative,
objective waste proxies; they do not claim to decide whether prose, comments,
or code are semantically unnecessary. The paired hygiene gate requires the
AUTO-routed proxy totals not to exceed SOLO. Missing truth or runtime
telemetry is `null/unverified`, never estimated. First-pass comparisons use the
same task/repetition groups across all four arms and never substitute ordinary
task pass rate. Run metadata contains Codex/model, source revision/dirty state, full
evaluated-source hash, release version and payload hash, manifest hash, the verified caller-pinned Codex binary
hash, auth handling, and isolation label. Every
arm rechecks the frozen source hash; changing code, docs, fixtures, or verifiers
mid-run invalidates the experiment. Every result is schema-validated before it
is appended. The summarizer rejects missing/duplicate task-arm pairs, input
parity drift, pass/exit contradictions, profile drift, and contradictory
fan-out/capacity telemetry. It also rejects any verified AUTO plan whose fan-out
or lane count differs from the preregistered `expected_lanes`. Serial controls
must prove zero planned lanes and `SOLO`; a two-, three-, or four-lane task
cannot promote after indiscriminately planning six Children. The six-lane gate requires verified execution
`SWARM`, planned and actual fan-out six, capacity at least six, and six distinct
completed child receipts. The current RC registers no runtime telemetry
adapter, so these runtime gates truthfully remain `unverified` and stable
promotion is capability-blocked until Codex exposes the required authoritative
events and a reviewed adapter is added with its pinned hash.
An interrupted or unsuccessful run retains `status: running`
plus `INVALID.md`. `summary.json` retains every paired comparison, aggregate
pass outcomes, per-arm/per-task medians, and deterministic 95% bootstrap
intervals from 10,000 resamples. The first cold run and later cache-compatible
runs are reported separately; no outlier is removed and timeout is failure.
Any arm failure prevents both summary publication and the `completed` status;
two AUTO-only process/verifier failures stop before the next arm. Finalization
first builds a completed run candidate, binds its SHA-256 plus the exact result,
manifest, revision, release-status, version, and payload hashes into a candidate
summary, validates both schemas, and stages an exact `benchmark-manifest.json`
whose hash must equal the completed receipt. It then atomically publishes that
frozen manifest, the summary, and finally the completed receipt. If the process stops
between those replaces, `run.json` remains `running` and `INVALID.md` makes the
candidate summary unusable. A zero exit therefore means every requested arm and
verifier passed, not that the baseline is statistically superior to vanilla.

The adapter boundary is `codex-runtime-telemetry/v1`. After an arm has exited,
the runner freezes the exact adapter bytes into a private executable and runs
that copy in a networkless, read-only Bubblewrap sandbox. Its JSON input binds
task, repetition, arm, configured cap, source hash, running-receipt hash,
evaluation-profile/config hashes, and the SHA-256 plus fixed sandbox path of the
events, last-message, and profile-receipt artifacts. Output may contain only
the existing usage and orchestration fields plus those input hashes. The host
rejects extra keys, replayed hashes, duplicate lane/agent IDs, contradictory
execution/fan-out/capacity, depth above one, more than four waves, impossible
peak concurrency, parent-setting drift, and inconsistent spawn/retry/fallback/
interrupt/timeout counts. It then adds adapter provenance itself and
merge-whitelists the validated fields into the result receipt.

Token/cost values are accepted only when the raw JSONL contains one completed
parent-turn usage object with integer token counters, explicit aggregate scope,
and a non-negative cost. The adapter must reproduce those host-derived values
exactly; it cannot upgrade parent-only, missing, cumulative, or ambiguous usage.
Otherwise usage remains `null/unverified`, which blocks the effort and
non-domination gates even if orchestration telemetry is otherwise valid.

Git revision/dirty metadata is read only from an ordinary `.git` directory.
The runner freezes that metadata, rejects local executable Git configuration
(including includes, fsmonitor, filters, and diff helpers), and evaluates it in
a networkless read-only cgroup/Bubblewrap boundary. Linked-worktree Git metadata
is deliberately unsupported for release evidence and fails closed. An installed
operational wrapper has no Git checkout and therefore records revision
`unversioned` and dirty state `null`; its full runtime `source_hash` remains the
authoritative scope identifier for that non-release check.

Unix live `run.json` and native Windows static JSON share the
`codex-baseline-benchmark/v2` envelope (`platform`, `mode`, `status`, isolation,
model/verifier execution truth). Published conditional JSON Schemas reject
cross-mode truth tuples such as a no-model paired receipt. Platform-specific result details remain
explicit rather than being flattened into a false parity claim.

Linux/WSL live workers run under Bubblewrap with a fresh filesystem namespace,
no live source/verifier mount, a synthetic HOME/CODEX_HOME, a byte-bounded tmpfs
task workspace, and only required read-only executables/system files. The
complete evaluated source is copied to a private snapshot whose hash must equal
the frozen live-source hash; source, snapshot, private verifier, and frozen
Codex/Node executable hashes are checked before and after use. The Codex API transport shares
network because the model call requires it, while the Codex permission profile
denies tool network. After worker exit, generated code is executed by the
verifier in a second Bubblewrap namespace with no network, cleared environment,
resource limits, a 60-second timeout, a private read-only verifier copy, and only
a bounded temporary overlay writable. A systemd user cgroup bounds aggregate
memory/swap, processes, CPU share, and runtime for the whole process tree;
Bubblewrap tmpfs mounts bound mutable bytes, while `prlimit` adds per-process
file-size, descriptor, address-space, CPU and core-dump limits. Trusted Git
metadata is built outside the worker, mounted read-only at `/workspace/.git`,
excluded from worker export, and hash-checked around use. Changed-path metrics
run through host-owned Git only in a separate networkless cgroup/Bubblewrap
sandbox with system/global config, hooks, fsmonitor, textconv, and ignores
disabled. The result label is `os-sandboxed-local-cgroup`.
Before a worker scan or export, the launcher stops and kills every residual
process except itself and Bubblewrap's private PID-1 reaper; a non-zombie
survivor invalidates the run.

This blocks the evaluated agent from reading the source/verifier through its
workspace. It is not a hostile-host boundary: an administrator or unrelated
same-host process can inspect memory/files, and public fixtures can be learned.
A strong release experiment therefore uses rotated private holdouts or an
external container/VM/service whose worker cannot mount this checkout or
verifier. Windows PowerShell currently validates the manifest/contracts and
labels Bash verifier execution `not-executed-native-static`; live paired
evaluation is Linux/WSL-only in the v0.3 candidate.

Behavior probes use `codex debug prompt-input` for deterministic proof that the
global block, skill metadata, root project guidance, and nested refinement are
model-visible. `scripts/routing-probe.sh` then runs six repeated classification
boundaries plus four read-only behavior cases: DEEP/high-risk planning,
research-first material ambiguity, semantic onboarding, and independent
original-request conformance. The generic response schema is model-visible,
while case expectations and executable host verifiers are not mounted. The
model must invoke the host-owned, bounded, read-only `/behavior-inspect` helper
exactly once; the helper emits its completion marker only after complete
enumeration. A pass also requires zero file-change events, frozen source and
tool hashes, a fresh worker HOME, clean mutable HOME/output trees, a sandboxed
host verifier, and a completed `run.json`. Its
`results.jsonl`, `behavior-results.jsonl`, and summary are covered by the
`routing-*` and `behavior-result` contracts. These runs require the same
dedicated key and OS isolation; their variance and self-reported skill field
must be reported as probabilistic evidence, not deterministic activation proof.

The deterministic test double proves paired-run, routing/behavior receipt, and
Canary parsing/fail-closed mechanics, not real-model behavior or API credential
containment. `benchmark --canary` injects a
fresh sentinel only into the Codex parent, requires the tool shell environment
to omit all key variables, scans every numeric `/proc/*/environ` and fails if a
readable key carrier is found, scans artifact contents and path names for the
exact sentinel and API key, and attempts tool network only against a preflighted
loopback TCP listener. A pass requires no worker connection plus a successful
host postflight and exact listener hit count. The resulting `run.json` and `canary.json` remain
a required real-model release receipt; their envelopes are defined by
`contracts/benchmark-report.schema.json` and
`contracts/benchmark-canary.schema.json`.

By default live outputs go under
`${XDG_STATE_HOME:-$HOME/.local/state}/codex-baseline/`, outside the managed
runtime. An installed wrapper may be used for an operational check, but its
receipt intentionally hashes the installed runtime scope, not this complete
checkout. Output inside an installed managed runtime is rejected.

Final evidence avoids a self-referential source hash: first run preliminary
evaluation, update and commit the tracked report/ledger, then rerun all three
commands on that unchanged clean commit. Store receipt hashes and final review
attestations outside the tracked source (for example, a detached attestations
ref); do not edit tracked files afterward. A successful full promotion summary
contains exactly the values needed by the separately validated promotion
receipt: `provenance.version`, `provenance.candidate_status`,
`gates.promotion_allowed`, `provenance.source_revision`,
`provenance.source_dirty`, and `provenance.payload_hash`.
