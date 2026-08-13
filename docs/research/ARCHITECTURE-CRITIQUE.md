# Independent architecture critique and disposition

Review date: 2026-08-13

A fresh-context, read-only critic read the original mission, traceability ledger,
and research architecture. Verdict: **accept-with-changes**. No implementation
had begun. This record preserves the material findings and their disposition.

| Severity | Finding | Disposition |
| --- | --- | --- |
| Critical | Multi-file deployment lacked journal states, locking, crash recovery, concurrent-edit detection, and a bounded metadata promise | Accepted. D003 now defines a flushed transaction state machine, per-object receipts, lock/recovery, three-way conflicts, fault injection, and portable restore scope |
| Critical | Onboarding lacked an untrusted-repository boundary and could imply execution of malicious project commands | Accepted. D009 is static/no-execute by default, bounds input and traversal, redacts credential material, separates opt-in isolated probes, and adds adversarial fixtures |
| High | Universal config ownership was undefined | Accepted. D016 explicitly manages zero keys in existing user TOML and constrains optional whole-file profiles |
| High | Update/uninstall/rollback lacked three-way drift rules | Accepted. D003 records previous/installed/desired state and conflicts on live drift |
| High | Symlink/reparse/path policy did not handle TOCTOU and Windows path classes | Accepted. D003 adds segment inspection, immediate revalidation, root containment, same-volume staging, and adversarial cases |
| High | Dual Bash/PowerShell logic risks divergent byte/path semantics | Accepted. D017 defines one JSON operations contract, explicit encoding, APIs, and native-Windows cases |
| High | Routing was incorrectly called deterministic and skill linkage was vague | Accepted. D005 now calls it probabilistic, defines override/tie/risk rules, logging, cross-skill tests, and repeated probes |
| High | Reviewer role was not technically read-only | Accepted with an honest boundary. D007 keeps the role advisory and requires review artifacts to label actual external isolation; v0.1.0 does not claim a bundled isolated runner |
| High | Benchmark isolation/statistics were incomplete | Accepted. D012 adds separate homes, credential isolation, verifier separation, pre-registration, randomization, hashes, holdouts, dispersion, and confidence reporting |
| High | Moving fetch outside update did not establish supply-chain provenance | Accepted. D018 requires payload manifests, hashes, origin/dirty reporting, staged update, and a signature/trust procedure for verified releases |
| Medium | Open-ended 0.147+ compatibility claims conflict with known feature/surface drift | Accepted. D019 defines a capability/surface matrix and fail/degrade labels |
| Medium | Global-block byte budget ignored total model-visible overhead | Accepted. D004 measures full baseline context deltas by workflow and treats 3,500 bytes as a testable initial maximum |

The critic classified only 12 of 46 gates as having a plausible full
architectural mechanism before reconciliation, 28 partial, and six unsupported.
D003, D009, D015-D019 specifically close the unsupported architecture gaps for
deployment/lifecycle, threat boundaries, inspectability, exact scoped recovery,
and periodic research revalidation. All gates still require implementation and
authoritative verification; this acceptance is permission to implement, not a
completion claim.
