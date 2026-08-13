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

Milestones 4-6 - integration, behavior evaluation, documentation, and final
independent audits.

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
| 7. Dogfood and completion audit | In progress | `594c535` platform reruns and three fresh audits completed; Git/credential boundary findings are being reconciled before the final immutable revision |

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

## Open decisions

- Whether live paired results justify any claim beyond "working evaluation
  mechanism"; default is to report inconclusive results rather than overfit.
- Whether direct skill-activation telemetry becomes available; current model
  `selected_skills` output remains explicitly probabilistic rather than a direct
  activation event.

## External evidence inputs

- A real paired/routing run requires a dedicated short-lived benchmark API key;
  normal Codex auth/session files are intentionally unsupported.
- A publisher-authenticated public release requires an owner-controlled signing
  identity/trust root and an explicit license. The local release candidate stays
  labelled `unsigned-local-source` until then.

## Next action

Finish the accepted security fix delta: isolate worker Git metadata, sandbox
scope inspection, harden credential entrypoints, pin Codex binary identity,
strengthen schemas, and fix review-noted state/documentation drift. Regenerate
the payload manifest, rerun both complete platform suites, commit the clean
revision, rerun from it, bind the exact results through `release-attestations`,
and obtain short final read-only delta reviews. When the dedicated credential is available, run preliminary
evaluation, finalize and commit tracked reports, then rerun all three live
checkout commands on that unchanged commit. Bind their safe receipt hashes
through a detached attestation and close traceability only against the
real-model evidence.
