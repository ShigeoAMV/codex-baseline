# Benchmark and behavior evaluation

The suite compares `vanilla` and `baseline` arms with the same task, starter,
model, account, sandbox, and repetition. It alternates arm order using a stable
task/repetition hash. Each arm receives a fresh workspace, HOME, and CODEX_HOME;
baseline installation is the only intended difference.

Ten maintained tasks cover every requested type: small one-file bug, simple
configuration, and documentation correction; medium multi-file feature,
reproduced concurrency bug, and test-backed refactor; large architecture and
multi-criteria feature; risk-sensitive rollback migration and security/path
traversal. Verifiers remain outside the worker workspace. Static mode proves
each fixture is well-formed and the starter fails its verifier:

```bash
codex-baseline benchmark --static
```

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
  scripts/benchmark.sh --live --repetitions 3
CODEX_BASELINE_BENCHMARK_API_KEY='<dedicated-short-lived-key>' \
  CODEX_BASELINE_EXPECTED_CODEX_SHA256="$CODEX_SHA256" \
  scripts/routing-probe.sh --repetitions 3
CODEX_BASELINE_BENCHMARK_API_KEY='<dedicated-short-lived-key>' \
  CODEX_BASELINE_EXPECTED_CODEX_SHA256="$CODEX_SHA256" \
  scripts/benchmark.sh --canary
```

Execute the script paths directly; do not prefix them with an ambient `bash`.
`--expected-codex-sha256 HASH` is equivalent to the hash environment variable.

All three live commands are Linux/WSL-only in v0.1.0. `--tasks` and
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
subagent events, installed baseline-layer bytes, and tokens where emitted by
JSONL. Retry count and review findings are explicit `null` because stable JSONL
does not expose a reliable retry concept and these tasks have no separate
reviewer. Run metadata contains Codex/model, source revision/dirty state, full
evaluated-source hash, manifest hash, the verified caller-pinned Codex binary
hash, auth handling, and isolation label. Every
arm rechecks the frozen source hash; changing code, docs, fixtures, or verifiers
mid-run invalidates the experiment. An interrupted run retains `status: running`
plus `INVALID.md`. `summary.json` retains every paired per-task delta, aggregate
pass outcomes, per-arm medians/totals, and an explicit null confidence interval.
The default three pairs per task are too small for a defensible interval or a
superiority claim; inspect raw pairs, failures, and dispersion.
The runner writes a completed receipt but exits nonzero when any arm fails; a
zero exit therefore means every requested arm and verifier passed, not that the
baseline is statistically superior to vanilla.

Git revision/dirty metadata is read only from an ordinary `.git` directory.
The runner freezes that metadata, rejects local executable Git configuration
(including includes, fsmonitor, filters, and diff helpers), and evaluates it in
a networkless read-only cgroup/Bubblewrap boundary. Linked-worktree Git metadata
is deliberately unsupported for release evidence and fails closed. An installed
operational wrapper has no Git checkout and therefore records revision
`unversioned` and dirty state `null`; its full runtime `source_hash` remains the
authoritative scope identifier for that non-release check.

Unix live `run.json` and native Windows static JSON share the
`codex-baseline-benchmark/v1` envelope (`platform`, `mode`, `status`, isolation,
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
evaluation is Linux/WSL-only in v0.1.0.

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
ref); do not edit tracked files afterward.
