# Codex Baseline 0.3.0-rc.1 candidate report

Date: 2026-08-16

## Verdict

The implementation is an unsigned `0.3.0-rc.1` source candidate. Autonomous
SOLO/TEAM/SWARM selection, safe optimizer transactions, parallelism-aware
onboarding, and v2 evaluation contracts are implemented and deterministically
testable. Installed RC guidance deliberately remains `SOLO`: autonomous global
activation, stable `0.3.0`, a stable tag/channel, and every speed or quality
claim remain blocked. The current Codex 0.147 JSONL contract does not expose
the authoritative orchestration telemetry required by the frozen four-arm live
gates, and this RC has no independently distributed runner-attestation trust
root. A benchmark key is necessary for a future live run but is not sufficient
to promote this candidate.

## Architecture and authority

The user supplies the goal. In the evaluation profile Codex derives immediately
useful independent lanes and selects `SOLO` (zero children), `TEAM` (one to
three), or `SWARM` (four to six). Empty slots are not filled. The parent retains
requirements, architecture, authority, integration, conflict resolution, final
tests, and the answer. Child packets are narrow and bounded; one writer is the
default, parallel writers require disjoint ownership in separate verified
worktrees, and parallel tests require isolated mutable resources.

Parent model, reasoning/Ultra, and session speed remain user-controlled. Child
model hints are per-spawn and capability-bound; no global child model or effort
is persisted. Runtime facts not exposed by Codex are recorded as `unverified`
and `null`, never estimated.

The installed RC uses the same safety/ownership rules, and its model-visible
production guidance instructs `SOLO`. This policy and its output-schema check do
not technically prohibit the runtime from creating a child. A trusted,
non-installed test overlay is the only supported path that activates AUTO before
promotion. The RC already bundles a separate deterministic stable guidance
variant, so an authorized stable release would install AUTO guidance rather
than silently retaining the RC gate. A fresh install may establish an absent
agent-thread cap of six, but capacity does not itself activate delegation.

## Config and lifecycle

`optimize` is non-mutating without `--apply`. It can explicitly enable agents
with cap six, manage the documented Fast pair, or restore only Baseline-owned
keys. It never owns `config.toml` as a file and never changes parent model,
reasoning, Ultra, or speed implicitly. `ultrafast` is a reserved interface that
returns structured `unavailable` without changing bytes.

Bash and PowerShell use key-scoped v2 journals, typed allowlists, exact
Target/Stage/Old derivation, compare-and-swap checks, atomic replacement, and a
durable core/config coordinator. Foreign bytes, comments, Unicode, BOM, line
endings, final newline, and independent user keys are preserved. Windows
preserves Owner and DACL/protection and rejects ADS/reparse/hardlink ambiguity.
Unix requires exact ACL/xattr inspection, rejects unsupported metadata, and
detects parent default ACL inheritance before target mutation. Journals contain
only safe managed tokens and hashes, never complete user config or secrets.

## Onboarding

Project onboarding remains optional. Global routing works immediately after
installation. Onboarding adds a bounded static parallelism map for source roots
and manifest-backed package boundaries plus explicit placeholders for API
boundaries, generated ownership, caches/build outputs, ports, databases,
fixtures, test shards, and write-conflict regions. Evidence is labelled
`declared`, `inferred`, or `unknown`; no project code is executed and no static
inference is described as verified isolation.

## Evaluation and token discipline

The four benchmark arms are Vanilla, Baseline forced SOLO, AUTO-homogeneous,
and AUTO-routed. Six parallel-positive and four serial-negative tasks run in
paired repetitions. Promotion checks first-pass result, safety, authority,
scope, latency, interventions, tokens/cached input/cost, retries, child effort,
handoff bytes, duplicate context, and unnecessary artifacts. Missing host
evidence remains unverified. A hash-pinned networkless host verifier is required
for first-pass, intervention, safety, and authority truth, and a verified
violation stops before the next arm. Verified AUTO fan-out must equal the
preregistered useful-lane count for each task; serial controls must use SOLO.
Fast is measured separately.

The product philosophy treats context and output as scarce: use the smallest
effective team, prefer direct parallel tool calls for small structured reads,
avoid best-of-N by default, keep child context and handoffs narrow, and do not
add files, prose, comments, or code without functional value.

## Verification status

The frozen `5afc214d...0902` working-tree snapshot in a private ext4 Git clone
passes all 15 local groups with exit zero. This
includes static contracts, install/rollback, onboarding, the optimizer matrix,
journal tampering, real ACL/xattr rejection, SIGKILL
install/rollback/uninstall convergence, benchmark/Canary truth, 16 routing plus
four behavior cases, worktree isolation, cross-version self-update, prompt
discovery, and documentation inventory. That snapshot also passes 604 native
Windows lifecycle assertions plus
79 onboarding/benchmark assertions under Windows PowerShell 5.1.26100.8875;
those suites also exercise PowerShell 7.6.3 compatibility, quoted TOML,
activation vetoes, protected and unprotected DACLs, metadata-tamper recovery,
restrictive config staging, and RC/stable release boundaries. A final security
delta removed every lifecycle Git invocation so repository-local filters cannot
execute before acknowledgement. The resulting payload passes the focused Unix
lifecycle group and 13 focused native provenance assertions across PowerShell
5.1 and 7.6.3. Its 76-file payload inventory is bound to SHA-256
`8356e50d0f4321d7f2038816866e019f0a94a6fc23123bdda10c3025de50cfcd`.

These deterministic receipts do not constitute a clean immutable revision:
the candidate remains an uncommitted source diff. A fresh combined security,
architecture/maintainability, and original-request conformance review plus its
bounded post-fix recheck reached Critical 0 / High 0. Local RC review sign-off is
complete; an immutable revision still requires an explicit commit decision.

No dedicated benchmark key, authoritative runtime telemetry adapter, or
independently verifiable runner attestation was available. Therefore real-model fan-out,
capacity, child model/effort, depth, concurrency, token/latency improvement, and
the frozen promotion thresholds remain `unverified`. This candidate makes no
autonomous performance claim and must not be tagged or published as stable.

## Minimal use

```bash
./scripts/codex-baseline.sh install --dry-run
./scripts/codex-baseline.sh install --acknowledge-unverified-source
codex-baseline doctor
codex-baseline optimize --check
cd project && codex
```

Optional project mapping is `codex-baseline onboard /path/to/project`, followed
by reviewed `--apply`. Explicit config optimization is
`codex-baseline optimize --apply`; normal use requires neither command.

## Remaining boundaries

Stable promotion requires a future officially supportable telemetry source, an
independently distributed attestation trust root, the exact live gates, a clean
immutable revision, final review sign-off, and publisher authentication/signing described in
[`RELEASE.md`](RELEASE.md). Bare-metal Linux distro coverage and a complete
Codex App/IDE matrix remain partial. The retained
[`RELEASE-CANDIDATE-REPORT.md`](RELEASE-CANDIDATE-REPORT.md) is the historical
v0.2 evidence record.
