# Codex Engineering Baseline: durable progress

Last updated: 2026-08-14

## Objective

Build and prove a production-quality, version-controlled Codex engineering
baseline for Linux, WSL2, and native Windows. It must keep ordinary use simple,
select workflow depth according to complexity and risk, preserve existing user
configuration, and verify outcomes objectively.

The full acceptance contract is the original mission supplied for this project.
`docs/requirements/TRACEABILITY.md` converts that contract into auditable gates.

## Current milestone

Milestones 4, 6, and 7 - external real-model evaluation and authenticated
release provenance. The deterministic implementation and final local audits are
complete.

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
| 1. Evidence and challenged architecture | Complete | Five research records, 19 decisions, two independent critiques and disposition |
| 2. Portable install and rollback core | Complete | Unix lifecycle suite and native PowerShell 5.1 lifecycle suite |
| 3. Repository onboarding | Complete | Static untrusted-repo fixture; dry-run/apply/idempotence/link/secret/no-exec checks |
| 4. Adaptive workflows and reusable skills | In progress | Four validated skills, real prompt discovery, six classifications and four host-verified behavior cases; repeated real-model probes pending |
| 5. Doctor, update, and lifecycle safety | Complete | Hash/drift health, freshness, update, uninstall/rollback, lock and crash recovery checks |
| 6. Evaluation harness | In progress | Four classes and host-side verifiers pass static validation; live paired run pending |
| 7. Dogfood and completion audit | In progress | Final immutable local revision and detached C0/H0/M0 review attestation are complete; live-model evidence and publisher signing remain |

## Current evidence

- Repository started empty: no commits, project `AGENTS.md`, or prior `PLAN.md`.
- Environment: Ubuntu 26.04 under WSL2, Linux kernel 6.18.33.2.
- Codex CLI: 0.147.0, reported current by `codex doctor` on 2026-08-13.
- Codex health: 17 checks OK, one idle app server, zero warnings/failures.
- Native Windows PowerShell 5.1 is reachable from WSL; 95 lifecycle and 69
  onboarding/benchmark assertions pass. Native Windows Codex is not installed.
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

## Open decisions

- Whether live paired results justify any claim beyond "working evaluation
  mechanism"; default is to report inconclusive results rather than overfit.
- Whether direct skill-activation telemetry becomes available; current model
  `selected_skills` output remains explicitly probabilistic rather than a direct
  activation event.

## External evidence inputs

- A real paired/routing run requires a dedicated short-lived benchmark API key;
  normal Codex auth/session files are intentionally unsupported.
- A publisher-authenticated release requires an owner-controlled signing
  identity and independently distributed trust root. No such private signing
  key is available locally; the public source preview therefore stays labelled
  `unsigned-local-source` despite its Apache-2.0 license.

## Next action

When the dedicated credential is available, run preliminary evaluation,
finalize and commit tracked reports, then rerun all three live checkout commands
on that unchanged commit. Bind their safe receipt hashes through a detached
attestation and close only the real-model-dependent traceability rows. Separately,
the owner may establish an offline-controlled signing identity, publish its
trust root independently, and replace the unsigned preview with a
publisher-authenticated release; never generate or commit that private key as
part of an automated repository workflow.
