# Codex Engineering Baseline

A small, evidence-driven baseline for Codex CLI on Linux and WSL2, plus Codex
CLI or the Codex desktop app on native Windows. It adds universal engineering
invariants, evaluation-gated autonomous execution-team selection, four
progressively disclosed skills, safe repository onboarding, health/lifecycle
operations, and a paired evaluation harness without installing an external
orchestration framework.

> **Status:** the source payload is `0.3.0`, release candidate `rc.1`. It is an
> Apache-2.0-licensed, unsigned public preview. The autonomous routing and
> optimizer implementation can be tested from this candidate, but installed RC
> guidance remains `SOLO`; autonomous global activation, stable `0.3.0`, a
> stable tag/channel, and speed or quality claims remain blocked until the
> frozen four-arm live gates pass. AUTO is exercised only through a trusted,
> non-installed evaluation overlay. Installation therefore retains the
> `unsigned-local-source` acknowledgement.

The baseline owns zero hooks and normally leaves `config.toml` alone. v0.3 has
one narrow exception: a fresh install may add the previously absent
`agents.max_concurrent_threads_per_session = 6` when agents are not disabled
and neither a current nor legacy cap already exists. This optional mutation
also requires an executable CLI for isolated strict-config validation; an
app-only install skips it and leaves `config.toml` user-owned. Existing settings
win;
`agents.enabled=false` or `features.multi_agent=false` explicitly vetoes the
automatic cap and remains user-owned.
Further key ownership is explicit through `optimize --apply`; parent model,
reasoning/Ultra, providers, permissions, MCP servers, hooks, rules, auth, and
unrelated skills remain user-owned.

## Install

Review the local checkout first. Installation never fetches from the network.

```bash
git clone https://github.com/ShigeoAMV/codex-baseline.git
cd codex-baseline
```

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

Native Windows supports both standalone-CLI and desktop-app-only hosts. The
desktop app is detected through its healthy AppX package; Baseline never relies
on the app's private versioned executable paths. CLI-specific Doctor checks and
config optimization remain unverified or unavailable until an executable CLI
exists, while guidance, skills, reviewer, runtime, lifecycle, and app use remain
supported.

The v0.3.0 candidate checkout is an unsigned local source. Both installers verify every
installable file against the versioned path/byte/SHA-256 manifest, print source
origin, intentionally unavailable revision/dirty state, trust label, and aggregate payload
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

Workflow selection remains visible and proportional. The installed RC guidance
instructs `SOLO`; the following automatic execution vocabulary is active only
in the trusted evaluation profile until promotion gates pass. This is a
model-visible policy plus an output-schema check, not an OS/runtime block on
child creation:

- `LEAN`: small, clear, local, reversible, low-risk change.
- `STRICT`: meaningful multi-file/API/refactor/moderate-risk change.
- `DEEP`: architecture implementation, migration, security-sensitive,
  materially ambiguous, multi-hour, or large unknown-repository work.
- `HIGH RISK`: an independent axis that strengthens authority, permission,
  rollback, verification, and security review.
- `SOLO`: no child; the default for small or coupled work.
- `TEAM`: one to three children for that many immediately useful independent
  lanes.
- `SWARM`: four to six children only when four to six real lanes can start now.

File count and keywords do not escalate work on their own. Focused read-only
explanation or diagnosis remains `LEAN`; broad read-only analysis uses native
`STRICT` without loading deep-work.

The parent keeps requirements, architecture, integration, final tests, and the
answer. It uses direct parallel tool calls for small structured reads and
subagents only when fresh model judgment, context isolation, or independent
critical-path work is useful. One writer is the default; parallel writers need
disjoint ownership in verified worktrees, and parallel tests need isolated
caches, outputs, ports, databases, and fixtures. Empty slots are never filled
with duplicate work. Child packets and handoffs are deliberately narrow so
parallelism does not become automatic context/token bloat.

Only matching skills are loaded. A small task should remain inspect-change-check;
a substantial delivery gets acceptance criteria and conformance evidence.

## Lifecycle

```bash
codex-baseline doctor --json
codex-baseline optimize --check --json
codex-baseline optimize --apply
codex-baseline optimize --speed fast --apply
codex-baseline optimize --restore --dry-run
codex-baseline update --check
codex-baseline update --dry-run
codex-baseline update --acknowledge-unverified-source
codex-baseline update --offline /path/to/codex-baseline-0.3.0-rc.1.tar.gz --dry-run
codex-baseline rollback --dry-run
codex-baseline rollback
codex-baseline uninstall --dry-run
codex-baseline uninstall
codex-baseline benchmark --static
```

`optimize` is inspect-only unless `--apply` is supplied. It can enable agents
with cap six or manage the documented Fast pair; `--speed keep` is the default.
`standard` removes only Baseline-owned Fast values. `ultrafast` currently
returns structured `unavailable` without changing bytes. No optimizer call
changes the parent model or reasoning setting.

From the installed wrapper, `update` checks/downloads the latest stable GitHub
release; this RC is not published to that stable channel. A checkout script
remains local unless `--remote` is explicit.
Downloads use a strict descriptor, bounded HTTPS redirects, per-asset SHA-256,
safe archive extraction, and the existing exact payload manifest. The release
is still unsigned, so apply requires `--acknowledge-unverified-source`; this is
integrity and transport consistency, not publisher authentication. `--offline`
keeps the reviewed/pre-acquired path networkless. Existing locked journals,
three-way drift checks, backups, recovery, and rollback remain the mutation
boundary. Existing v0.1.1 installations need one final reviewed local v0.2.0
install/update because old installed code cannot acquire this command
retroactively; subsequent v1 updates are self-contained.

## Validate and benchmark

```bash
./tests/run.sh
./tests/run-powershell.sh
codex-baseline benchmark --static
CODEX_BASELINE_BENCHMARK_API_KEY='<dedicated-short-lived-key>' \
  CODEX_BASELINE_EXPECTED_CODEX_SHA256='<reviewed-codex-sha256>' \
  scripts/benchmark.sh --live --repetitions 10
CODEX_BASELINE_BENCHMARK_API_KEY='<dedicated-short-lived-key>' \
  CODEX_BASELINE_EXPECTED_CODEX_SHA256='<reviewed-codex-sha256>' \
  scripts/routing-probe.sh --repetitions 3
CODEX_BASELINE_BENCHMARK_API_KEY='<dedicated-short-lived-key>' \
  CODEX_BASELINE_EXPECTED_CODEX_SHA256='<reviewed-codex-sha256>' \
  scripts/benchmark.sh --canary
```

These live commands are Linux/WSL-only in the v0.3 candidate, consume account quota, and
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

- [Maintainer start-here guide](DEVELOPER-README.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Installation and platforms](docs/INSTALL.md)
- [Operations, upgrades, and recovery](docs/OPERATIONS.md)
- [Onboarding](docs/ONBOARDING.md)
- [Security model](docs/SECURITY.md)
- [Benchmark design](docs/BENCHMARKS.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Release and provenance](docs/RELEASE.md)
- [Current v0.3 release candidate report](docs/RELEASE-CANDIDATE-REPORT-0.3.md)
- [Historical v0.2 release candidate report](docs/RELEASE-CANDIDATE-REPORT.md)
- [Research evidence](docs/research/EVIDENCE.md)
- [Architecture decisions](docs/research/DECISIONS.md)
- [Dogfood DEEP-work contract](docs/examples/DEEP-WORK-PLAN.md)
- [Mission traceability](docs/requirements/TRACEABILITY.md)

## Support truth

The recorded 13-group WSL/Linux and 141/69 native PowerShell receipts belong to
v0.2.0 and remain historical evidence. The current working tree has passed the
App Server protocol/reducer tests, the ten-task static benchmark, Bash
self-update, and native Windows lifecycle (612 assertions) plus
onboarding/benchmark (79 assertions); the final reducer-only truth-label delta
also passed its focused tests and exact payload check. A clean-commit matrix is
still required for release evidence. The authenticated four-arm evaluation is unverified
because no dedicated benchmark key is available; independent isolation,
pricing, and attestation evidence are also required. Therefore no autonomous
speedup or stable-release claim is made. See
[platform status](docs/PLATFORMS.md).

## License

Licensed under the [Apache License 2.0](LICENSE). No external orchestration
framework code is bundled. The public source preview is not yet a
publisher-authenticated release; a publisher-controlled signing trust root is
still required before that stronger provenance claim can be made.
