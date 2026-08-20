# Codex Engineering Baseline: durable progress

Last updated: 2026-08-15

## Objective

Build and prove a production-quality, version-controlled Codex engineering
baseline for Linux, WSL2, and native Windows. It must keep ordinary use simple,
select workflow depth according to complexity and risk, preserve existing user
configuration, and verify outcomes objectively.

The full acceptance contract is the original mission supplied for this project.
`docs/requirements/TRACEABILITY.md` converts that contract into auditable gates.

## Current milestone

Milestone 9 - autonomous multi-agent acceleration v0.3 release candidate. The
frozen contract is
[`docs/plans/2026-08-15-autonomous-multi-agent.md`](docs/plans/2026-08-15-autonomous-multi-agent.md).
Implementation and deterministic verification are in progress. The numeric
  source payload is `0.3.0` with release status `rc.1`; installed execution stays
  SOLO, while autonomous activation, stable promotion, tag, channel publication,
  and speed/quality claims are blocked until the live gates pass. Existing v0.2
  receipts below remain historical evidence, not v0.3 proof.

### Acceptance criteria

- Unix/WSL and native PowerShell lifecycle suites pass from isolated homes.
- Prompt-input probes prove global/project/nested guidance and skill metadata.
- Live behavior and paired vanilla/baseline benchmark results are recorded with
  honest isolation and statistical limitations.
- Production documentation covers daily use, maintenance, security, platforms,
  failure recovery, and research freshness.
- Fresh security, maintainability, architecture, and original-mission audits
  leave no unresolved internal critical finding on the final fix revision.

## Milestones

| Milestone | State | Exit evidence |
| --- | --- | --- |
| 1. Evidence and challenged architecture | Complete | Five research records, 20 decisions, two independent critiques and disposition |
| 2. Portable install and rollback core | Complete | Unix lifecycle suite and native PowerShell 5.1 lifecycle suite |
| 3. Repository onboarding | Complete | Static untrusted-repo fixture; dry-run/apply/idempotence/link/secret/no-exec checks |
| 4. Adaptive workflows and reusable skills | In progress | Four validated skills, stable AUTO guidance bundled behind the RC gate, real prompt discovery, 16 classifications and six host-verified behavior cases including the two focused decision probes; real-model telemetry remains unavailable |
| 5. Doctor, update, and lifecycle safety | Complete | Hash/drift health, freshness, update, uninstall/rollback, lock and crash recovery checks |
| 6. Evaluation harness | In progress | Four arms, exact smallest-team gates, host-side verifiers, and deterministic containment pass; live paired promotion is unavailable on the current Codex telemetry contract |
| 7. Dogfood and completion audit | In progress | Current v0.3 RC working tree passes the final local platform matrices and fresh combined C0/H0 review; an immutable revision remains |
| 8. Explicit remote self-update | In progress | Deterministic RC preview assets, cross-version update/rollback/uninstall, crash recovery, and 15/15 Unix plus 604/79 native Windows receipts pass; stable publication remains blocked |
| 9. Autonomous execution acceleration | RC implemented; stable blocked | SOLO/TEAM/SWARM evaluation engine, dormant stable AUTO activation, smallest-effective-team gates, safe key-owned optimizer, optional onboarding map, and v2 truth contracts are implemented; official orchestration telemetry and independent attestation trust remain unavailable |

## Current evidence

- Repository started empty: no commits, project `AGENTS.md`, or prior `PLAN.md`.
- Environment: Ubuntu 26.04 under WSL2, Linux kernel 6.18.33.2.
- Codex CLI: 0.147.0, reported current by `codex doctor` on 2026-08-13.
- Codex health: 17 checks OK, one idle app server, zero warnings/failures.
- Native Windows PowerShell 5.1 is reachable from WSL; the current v0.2.0 tree
  passes 141 lifecycle and 69 onboarding/benchmark assertions. PowerShell
  7.6.3 additionally passes installed-update staging and adversarial ACL
  compatibility checks. Native Windows Codex 0.147.0 is installed and its
  stable capabilities/config are exercised.
- Node.js 24.18.0 is available in WSL. It is not yet accepted as a universal
  runtime dependency.
- The active global Codex configuration is customized and therefore provides a
  real preservation/merge test case. Authentication data was not read.
- Initial immutable source anchor:
  `4b0430cbb3328e40c7da837d72c770e9ac4d88b7`; the complete Unix and native
  PowerShell matrices passed from its clean tree.
- Reconciled candidate `594c535a52d95ab285ad8127e9d304bb3e681738`
  passed 12/12 Unix/WSL groups plus 95 and 69 native Windows assertions. Its
  fresh reviews found a worker-Git/host boundary Critical, credential-startup
  High, and shell-state Medium; these are not treated as signed off until the
  current fix delta, new full reruns, and final delta reviews pass.
- Candidate `cec60fd54603205609dff66364c6b9593339d7ef` closed those findings and
  again passed 12/12 plus 95 and 69 from a clean tree. Final delta review found
  two remaining host-code paths: PATH-selected dispatcher `dirname` before
  trusted sourcing and repository-local `core.fsmonitor` during source
  provenance.
- Candidate `ef480aab632881f617566f507e0143b4ef0e1602` closed those paths, removed
  contradictory Codex-hash receipt fields, strengthened successful
  routing/behavior schema semantics, and passed 12/12 Unix/WSL plus 95 and 69
  native Windows assertions before and after commit. Conformance and
  architecture reviewers signed it off; security review then demonstrated the
  broader repository-local clean/process-filter execution class during source
  Git provenance.
- Candidate `0fd0ca8d8f1362c972efefe9d5b043eeec31665a` freezes ordinary
  source Git metadata, rejects executable local Git configuration, runs
  provenance read-only in a networkless cgroup/Bubblewrap boundary, disables
  `systemd-run` argument expansion, and passed 12/12 Unix/WSL groups plus 95
  and 69 native Windows assertions from its clean commit. Its detached
  attestation binds those results. All three final reviewers then identified
  the same remaining gap: enabled `extensions.worktreeConfig` can expose an
  unchecked `config.worktree` scope. The current fix rejects that extension
  fail-closed and adds a non-execution regression test.
- Candidate `3f3e16c3513f2b5a33f6a6098f31d302ae34f520` passed its clean
  post-commit matrix with 12/12 Unix/WSL groups plus 95 and 69 native Windows
  assertions. Final commit `a11ed2aa3b0bd04453824f17191d10c6101fc984`
  makes the last test-only regression oracle causal while preserving the exact
  production payload. Its detached `release-attestations` note binds the tree,
  payload, platform receipts, targeted final checks, and fresh Security,
  Architecture, Maintainability, and Original-mission Conformance C0/H0/M0
  sign-offs.
- Public source distribution is Apache-2.0 licensed and carries an explicit
  private vulnerability-reporting policy. It remains an unsigned public preview
  until an owner-controlled signing identity and independently distributed
  trust root exist.
- v0.2.0 adds an explicit installed-runtime release updater without `git pull`.
  The focused Unix group passes deterministic build, check/dry-run/apply,
  downloaded-code canary, hostile archives, concurrent anti-downgrade,
  rollback, and exact-state restoration.
- The current v0.2.0 working tree passes all 13 Unix groups from a private WSL
  filesystem copy using pinned ShellCheck 0.9.0 and Codex 0.147.0 test tools.
  It also passes both native Windows PowerShell suites with 141 and 69
  assertions, including focused PowerShell 7.6.3 update/ACL compatibility.
  Windows tests atomically create a protected system-drive test root instead of
  relying on the foreign-writable `%LOCALAPPDATA%` ancestry; production path
  validation remains unchanged and fail-closed.
- The `0.3.0-rc.1` snapshot with payload hash `5afc214d...0902` passed all 15
  Unix/WSL groups from a private ext4 Git clone, 604 native Windows lifecycle
  assertions, and 79 native Windows onboarding/benchmark assertions. A final
  security delta removed all lifecycle Git invocation and passed the focused
  Unix lifecycle group plus 13 native Windows provenance assertions. The
  resulting 76-file payload hash is
  `8356e50d0f4321d7f2038816866e019f0a94a6fc23123bdda10c3025de50cfcd`.
- Codex CLI 0.147 does not expose the authoritative orchestration facts required
  by the preregistered promotion gate. No independently distributed runner-
  attestation trust root exists in this RC, so stable generation is explicitly
  unavailable even with a benchmark API key.

## Open decisions

- Whether live paired results justify any claim beyond "working evaluation
  mechanism"; default is to report inconclusive results rather than overfit.
- Whether direct skill-activation telemetry becomes available; current model
  `selected_skills` output remains explicitly probabilistic rather than a direct
  activation event.
- Whether the frozen live gates justify stable autonomous routing claims. Until
  then runtime capacity, actual child model/effort, recursion depth, and
  concurrency observations that the client does not expose remain `unverified`.

## External evidence inputs

- A real paired/routing run requires a dedicated short-lived benchmark API key;
  normal Codex auth/session files are intentionally unsupported.
- A publisher-authenticated release requires an owner-controlled signing
  identity and independently distributed trust root. No such private signing
  key is available locally; the public source preview therefore stays labelled
  `unsigned-local-source` despite its Apache-2.0 license.

## Next action

The final 15-group private-ext4 WSL suite, frozen-v0.2 cross-version
transactions, native Windows PowerShell 5.1/7 matrices, final security delta,
and combined C0/H0 review are complete. Freeze an immutable candidate revision
only after an explicit commit decision. Stop at the explicitly unsigned
`0.3.0-rc.1` state and publish neither a stable tag nor performance claims.
Future stable work first needs authoritative runtime telemetry and an
independently verifiable runner-attestation trust root; only then may it execute
the unchanged candidate's frozen four-arm live suite and emit a promotion
receipt.
