# Independent architecture and maintainability review - 2026-08-13

Reviewer: fresh read-only reviewer (`release_arch_maint_audit`). Scope: original
mission, architecture, lifecycle/onboarding/evaluation implementation, contracts,
documentation, and repository state. This review preceded the current
disposition pass and is not the final immutable-revision sign-off.

## Findings and disposition

| Severity | Finding | Current disposition / evidence |
| --- | --- | --- |
| Critical | The repository had no commit, so source/version/provenance claims lacked an immutable anchor | Open until the release-candidate tree is committed and the full matrix is rerun at that revision |
| High | Documentation claimed a bundled isolated reviewer runner that did not exist | Closed by correcting D007, architecture, and changelog: the role is advisory; v0.1.0 ships no isolated runner and review artifacts must label actual external isolation |
| High | Windows Doctor did not enforce minimum Codex version or probe required stable capabilities | Closed. It parses manifest `minimum_codex`, executes strict-config and feature probes, and native PowerShell tests cover current/older test doubles while retaining the real-binary limitation |
| High | Onboarding reported existing instructions but applied without explicit conflict acknowledgement; generated guidance carried too few discovered boundaries | Closed. Apply now stops before mutation on conflicts unless explicitly acknowledged; model guidance adds safe source/architecture/generated/risk paths while excluding unsafe path strings; Unix and Windows tests cover it |
| High | No valid real paired or probabilistic routing result existed | Open pending a dedicated short-lived benchmark key. Deterministic runner mechanics and real prompt-input discovery are not misreported as real-model comparative evidence |
| Medium | Schema/contract evidence was weaker than implementation claims | Partially closed. Shared schemas, exact operations contract, golden cross-platform keys, strict manifest validation, and negative journal tests exist. A general schema-engine dependency is not imposed on normal install |
| Medium | Decisions/help/docs contradicted actual `--force`, rollback target, research-check, reviewer isolation, holdout labels, and test counts | Closed in current docs: no force flag, rollback unwinds current state, offline research-check exists, isolation claims are corrected, holdout label is `os-sandboxed-local`, and receipts carry current counts |
| Low | Unix Doctor required `sha256sum` despite common code supporting `shasum` | Closed. Doctor now accepts either hash tool and reports a combined missing dependency only when neither exists |

## Review status

The critical immutable-revision finding remains open until the initial commit
and post-commit rerun. A fresh final architecture/maintainability review is then
required; this record proves dogfood feedback and disposition, not final
completion.
