# Independent architecture and maintainability review - 2026-08-13

Reviewer: fresh read-only reviewer (`release_arch_maint_audit`). Scope: original
mission, architecture, lifecycle/onboarding/evaluation implementation, contracts,
documentation, and repository state. This review preceded the current
disposition pass and is not the final immutable-revision sign-off.

## Findings and disposition

| Severity | Finding | Current disposition / evidence |
| --- | --- | --- |
| Critical | The repository had no commit, so source/version/provenance claims lacked an immutable anchor | Closed. Initial commit `4b0430cbb3328e40c7da837d72c770e9ac4d88b7` anchors the candidate; 11/11 Unix, 83 lifecycle, and 58 onboarding/benchmark assertions passed from that clean revision |
| High | Documentation claimed a bundled isolated reviewer runner that did not exist | Closed by correcting D007, architecture, and changelog: the role is advisory; v0.1.0 ships no isolated runner and review artifacts must label actual external isolation |
| High | Windows Doctor did not enforce minimum Codex version or probe required stable capabilities | Closed. It parses manifest `minimum_codex`, executes strict-config and feature probes, and native PowerShell tests cover current/older test doubles while retaining the real-binary limitation |
| High | Onboarding reported existing instructions but applied without explicit conflict acknowledgement; generated guidance carried too few discovered boundaries | Closed. Apply now stops before mutation on conflicts unless explicitly acknowledged; model guidance adds safe source/architecture/generated/risk paths while excluding unsafe path strings; Unix and Windows tests cover it |
| High | No valid real paired or probabilistic routing result existed | Open pending a dedicated short-lived benchmark key. Deterministic runner mechanics and real prompt-input discovery are not misreported as real-model comparative evidence |
| Medium | Schema/contract evidence was weaker than implementation claims | Partially closed. Shared schemas, exact operations contract, golden cross-platform keys, strict manifest validation, and negative journal tests exist. A general schema-engine dependency is not imposed on normal install |
| Medium | Decisions/help/docs contradicted actual `--force`, rollback target, research-check, reviewer isolation, holdout labels, and test counts | Closed in current docs: no force flag, rollback unwinds current state, offline research-check exists, isolation claims are corrected, holdout label is `os-sandboxed-local`, and receipts carry current counts |
| Low | Unix Doctor required `sha256sum` despite common code supporting `shasum` | Closed. Doctor now accepts either hash tool and reports a combined missing dependency only when neither exists |

## Review status

The second fresh read-only review inspected clean commit `46ba57b` and found no
critical issue. Its actionable findings are disposed as follows:

- Exact-revision tests: still a release procedure item; both full suites will be
  rerun after the final evidence commit, with the external attestation bound to
  that exact `HEAD` to avoid a self-referential receipt commit.
- Future Codex versions: closed in the candidate. Both Doctors parse
  `tested_codex`, continue probes, and label newer versions
  `unverified-future-version`; Unix and native Windows tests cover 0.148.0.
- Operations contract overclaim: closed by narrowing D017 to shared inventories
  and report IDs, making schema arrays exact, and validating exact states,
  commands, reports, and objects in both native manifest readers/tests.
- Direct onboarding semantics and planning/resume/context/runtime activation
  proof: not disguised as implementation completion. R06, R11, R15, R17, R24,
  R25, and R35 are now `partial` until the named runtime evidence exists.

A final read-only delta review against the immutable candidate is still required;
this record proves that the second-round findings drove changes, not final
mission completion.
