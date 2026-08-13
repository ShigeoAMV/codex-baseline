# Codex Engineering Baseline

A small, evidence-driven baseline for Codex CLI on Linux, WSL2, and native
Windows. It adds universal engineering invariants, four progressively disclosed
skills, safe repository onboarding, health/lifecycle operations, and a paired
evaluation harness without installing an external orchestration framework.

The baseline deliberately owns **zero `config.toml` keys and zero hooks**. It
preserves the user's models, providers, permissions, MCP servers, hooks, rules,
auth, and unrelated skills. Codex supplies native Plan, Goal, Review, Subagents,
sandboxing, config precedence, and app worktrees.

## Install

Review the local checkout first. Installation never fetches from the network.

Linux or WSL2:

```bash
./scripts/codex-baseline.sh install --dry-run
./scripts/codex-baseline.sh install --acknowledge-unverified-source
codex-baseline doctor
```

Native Windows PowerShell 5.1+:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\codex-baseline.ps1 install -DryRun
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\codex-baseline.ps1 install -AcknowledgeUnverifiedSource
& "$HOME\.local\bin\codex-baseline.ps1" doctor
```

The v0.1.0 checkout is an unsigned local source. Both installers verify every
installable file against the versioned path/byte/SHA-256 manifest, print source
origin, revision/dirty state when available, trust label, and aggregate payload
hash, then require explicit acknowledgement before mutation. That proves the
checkout matches its manifest; it is not publisher authentication.

The installer merges one marker-delimited block into the active global
`AGENTS.md`, copies four prefixed skills to the native user-skill directory,
installs one advisory reviewer role, and creates a versioned runtime snapshot.
It does not read or copy authentication/session data.

## Daily use

For an existing configured repository, use Codex normally:

```bash
cd project
codex
```

For a new or unfamiliar repository, preview static onboarding once:

```bash
codex-baseline onboard /path/to/project
codex-baseline onboard --apply /path/to/project
# If preview reports existing AI instructions, review them, then:
codex-baseline onboard --apply --acknowledge-existing-instructions /path/to/project
```

The default preview executes no project command. Applied commands are labelled
`declared, not executed`; review and run the relevant ones separately.

Workflow selection remains visible and proportional:

- `LEAN`: small, clear, local, reversible, low-risk change.
- `STRICT`: meaningful multi-file/API/refactor/moderate-risk change.
- `DEEP`: architecture, migration, security-sensitive, ambiguous, multi-hour,
  or large unknown-repository work.
- `HIGH RISK`: an independent axis that strengthens authority, permission,
  rollback, verification, and security review.

Only matching skills are loaded. A small task should remain inspect-change-check;
a substantial delivery gets acceptance criteria and conformance evidence.

## Lifecycle

```bash
codex-baseline doctor --json
codex-baseline update --dry-run
codex-baseline update --acknowledge-unverified-source
codex-baseline rollback --dry-run
codex-baseline rollback
codex-baseline uninstall --dry-run
codex-baseline uninstall
codex-baseline benchmark --static
```

`update` applies the reviewed local source; it never fetches. Mutations use a
locked journal, per-object previous/installed/desired hashes, backups, staged
replacement, and recovery of incomplete transactions. Managed drift is a hard
conflict. Rollback/uninstall never silently discard drifted managed content.

## Validate and benchmark

```bash
./tests/run.sh
./tests/run-powershell.sh
codex-baseline benchmark --static
CODEX_BASELINE_BENCHMARK_API_KEY='<dedicated-short-lived-key>' \
  CODEX_BASELINE_EXPECTED_CODEX_SHA256='<reviewed-codex-sha256>' \
  scripts/benchmark.sh --live --repetitions 3
CODEX_BASELINE_BENCHMARK_API_KEY='<dedicated-short-lived-key>' \
  CODEX_BASELINE_EXPECTED_CODEX_SHA256='<reviewed-codex-sha256>' \
  scripts/routing-probe.sh --repetitions 3
CODEX_BASELINE_BENCHMARK_API_KEY='<dedicated-short-lived-key>' \
  CODEX_BASELINE_EXPECTED_CODEX_SHA256='<reviewed-codex-sha256>' \
  scripts/benchmark.sh --canary
```

These live commands are Linux/WSL-only in v0.1.0, consume account quota, and
never mount or copy normal Codex auth/session files. The routing command also
runs read-only, host-verified DEEP/high-risk planning, ambiguity, onboarding,
and conformance cases. Each Codex arm runs in a fresh Bubblewrap filesystem with
only its synthetic home/workspace and required executables; Codex tool network
is denied, while the parent Codex transport necessarily reaches the API. The
verifier runs afterward in a separate networkless sandbox. Aggregate memory,
process, CPU, runtime and mutable-storage bounds are enforced by a user cgroup
and byte-bounded tmpfs mounts. Results are labelled
`os-sandboxed-local-cgroup`; high-confidence release comparisons still need rotated
private holdouts or an external worker unable to mount this source/verifier.
The canary uses only a preflighted loopback listener and fails unless tool-shell
environment, the key-carrying process environment in `/proc`, exact content and
path-name secret scans, and tool network all remain contained. The fixed-shell
bootstrap ignores Bash startup hooks; the trusted runner then removes the input
key from its exported environment before starting helpers and transfers it
through the final cgroup service's stdin pipe. The caller-pinned Codex hash must
match the frozen executable and is recorded in each live receipt.
Release receipts use these direct checkout scripts so paired, routing, and
Canary runs bind the same complete source hash; installed-wrapper runs bind the
installed runtime instead.

## Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Installation and platforms](docs/INSTALL.md)
- [Operations, upgrades, and recovery](docs/OPERATIONS.md)
- [Onboarding](docs/ONBOARDING.md)
- [Security model](docs/SECURITY.md)
- [Benchmark design](docs/BENCHMARKS.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Release and provenance](docs/RELEASE.md)
- [Release candidate report](docs/RELEASE-CANDIDATE-REPORT.md)
- [Research evidence](docs/research/EVIDENCE.md)
- [Architecture decisions](docs/research/DECISIONS.md)
- [Dogfood DEEP-work contract](docs/examples/DEEP-WORK-PLAN.md)
- [Mission traceability](docs/requirements/TRACEABILITY.md)

## Support truth

The release candidate is executed on WSL2/Linux (12 end-to-end test groups) and
in native Windows PowerShell 5.1 through WSL interoperability (95 lifecycle and
69 onboarding/benchmark assertions). A native-Codex test double proves Windows
Doctor version/capability logic; the real native Windows Codex binary is not
installed and remains `not verified`. Codex App behavior is
based on current official product contracts plus CLI prompt-input probes, not a
complete cross-client execution test. See [platform status](docs/PLATFORMS.md).

## License

No external framework code is bundled. This is a local release candidate, not a
publisher-authenticated public release. Before public redistribution, add an
explicit license and a publisher-controlled signing trust root; until then, no
permission beyond applicable law is implied.
