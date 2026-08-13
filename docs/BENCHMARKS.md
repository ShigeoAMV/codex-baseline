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

Live mode consumes quota:

```bash
export CODEX_BASELINE_BENCHMARK_API_KEY='<dedicated-short-lived-key>'
codex-baseline benchmark --live --repetitions 3
unset CODEX_BASELINE_BENCHMARK_API_KEY
```

Shared ChatGPT/Codex authentication is deliberately unsupported. Create a
dedicated, short-lived API key with the narrowest practical budget/permissions;
do not reuse the normal Codex session. The key is supplied only to the Codex
parent process, is excluded from tool-shell inheritance, and normal auth/session
files are never read, linked, copied, or mounted. `/proc` is denied by the Codex
permission profile. Raw JSONL/stderr still requires human secret review before
publication; the built-in pattern scan is only a fail-closed heuristic.

The runner captures process/verifier success, elapsed time, turns, commands,
file-change events, actual changed/unnecessary paths, failed command events,
subagent events, installed baseline-layer bytes, and tokens where emitted by
JSONL. Retry count and review findings are explicit `null` because stable JSONL
does not expose a reliable retry concept and these tasks have no separate
reviewer. Run metadata contains Codex/model, source revision/dirty state, full
evaluated-source hash, manifest hash, auth handling, and isolation label. Every
arm rechecks the frozen source hash; changing code, docs, fixtures, or verifiers
mid-run invalidates the experiment. An interrupted run retains `status: running`
plus `INVALID.md`. `summary.json` retains every paired per-task delta, aggregate
pass outcomes, per-arm medians/totals, and an explicit null confidence interval.
The default three pairs per task are too small for a defensible interval or a
superiority claim; inspect raw pairs, failures, and dispersion.

Unix live `run.json` and native Windows static JSON share the
`codex-baseline-benchmark/v1` envelope (`platform`, `mode`, `status`, isolation,
model/verifier execution truth). Platform-specific result details remain
explicit rather than being flattened into a false parity claim.

Linux/WSL live workers run under Bubblewrap with a fresh filesystem namespace,
no source/verifier mount, a synthetic HOME/CODEX_HOME, the task workspace, and
only required read-only executables/system files. The Codex API transport shares
network because the model call requires it, while the Codex permission profile
denies tool network. After worker exit, generated code is executed by the
verifier in a second Bubblewrap namespace with no network, cleared environment,
resource limits, a 60-second timeout, read-only verifier, and only the workspace
writable. The model worker also runs under `prlimit` bounds for CPU time, address
space, file size, descriptors, processes, and core dumps. Git uses an isolated
HOME, disabled hooks, empty templates, and no
system/global config. The result label is `os-sandboxed-local`.

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
model-visible. Repeated live task prompts then measure probabilistic workflow
and skill selection with `scripts/routing-probe.sh`; they require the same
dedicated key and OS isolation. Their variance must be reported rather than
called deterministic.

The deterministic test double proves paired-run mechanics and credential-free
fixture execution, not real API credential containment. The final real-model
canary (a synthetic key marker that must not appear in tool output/artifacts and
a denied tool-network attempt) remains a required live release receipt.
