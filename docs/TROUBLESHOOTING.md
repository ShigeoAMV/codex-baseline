# Troubleshooting

## Both global AGENTS files are non-empty

Codex gives `AGENTS.override.md` priority, so the installer refuses to guess.
Choose which global file should be active, merge your own content deliberately,
and rerun the dry-run.

## Managed content drifted

A prefixed skill, reviewer, runtime, wrapper, or managed block no longer equals
the installed hash. Preserve the changed content, compare it with the source and
journal, then either incorporate the intended change into this repository or
restore the installed version. There is no blind force flag.

## Pending transaction or lock

A live mutation auto-recovers a pending journal. `doctor` reports a pending
transaction as failure and a lock as warning. If an operation is truly still
running, wait. If recovery fails, follow the manual evidence-preserving process
in [Operations](OPERATIONS.md); never delete broad home/Codex directories.

## Skill does not trigger

Check that all four `SKILL.md` files exist in `$AGENTS_HOME/skills`, descriptions
remain valid YAML, and the prompt actually matches the positive use cases. Small
tasks intentionally should not load deep-work/conformance/retrospective skills.
Use an explicit `$skill-name` mention when deterministic invocation is required.

## Onboarding requires existing-instruction acknowledgement

The preview found `AGENTS.md`, `.codex`, `.agents`, or another supported AI
instruction path. Read the reported paths and reconcile real conflicts first.
Then rerun apply with `--acknowledge-existing-instructions` on Unix/WSL or
`-AcknowledgeExistingInstructions` on Windows. The flag authorizes only the
marker-block merge; it never overwrites the other instructions.

## Native Windows Codex says not verified

The PowerShell lifecycle can be healthy while the native Codex binary is absent.
Install Codex separately using official instructions, rerun `doctor`, and add a
native prompt/skill behavior probe before changing the platform label.

## Benchmark cannot authenticate

Live mode accepts only a dedicated short-lived key in
`CODEX_BASELINE_BENCHMARK_API_KEY`. Shared ChatGPT/Codex auth was removed because
mounting a real auth file into any evaluated worker breaks the credential
boundary. Confirm the dedicated key is active, budgeted, and accepted by the API;
never point the runner at normal auth/session files. Do not publish JSONL,
stderr, or last-message artifacts without a separate secret review.

## Live evaluation says the cgroup boundary is unavailable

Paired, routing, and Canary modes require a working systemd user manager plus
`systemd-run --user`, `systemctl`, Bubblewrap, `prlimit`, `timeout`, Git, `jq`,
Node, and Codex. This is an aggregate resource/safety boundary, not an optional
performance feature. Enable the user manager for the current Linux/WSL session
and rerun the deterministic suite; do not bypass the preflight or downgrade the
receipt label. Static benchmark validation remains available without a model.

## Source manifest mismatch

Install/update verifies the complete installable payload before creating state
or taking a lock. A path, byte-length, file-hash, aggregate-hash, or operations
contract mismatch means the checkout differs from the versioned release
inventory. Do not bypass it. Restore a reviewed checkout or, as a maintainer,
update payload code, regenerate every manifest entry and aggregate digest, run
both platform suites, review the diff, and release a new version as appropriate.
