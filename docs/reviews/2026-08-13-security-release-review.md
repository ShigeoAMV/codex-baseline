# Independent security release review - 2026-08-13

Reviewer: fresh read-only security reviewer (`release_security_audit`). Review
scope: Bash/PowerShell lifecycle, onboarding, benchmark isolation, credentials,
update provenance, recovery, and tests. The review preceded the hardening pass;
this is its finding/disposition record, not a fresh final sign-off.

## Findings and disposition

| Severity | Finding | Current disposition / evidence |
| --- | --- | --- |
| High | The manifest was unsigned and no publisher trust root existed | Open only for public distribution. Local installs remain explicitly `unsigned-local-source`, require acknowledgement, and [release policy](../RELEASE.md) forbids a public verified claim without an independently distributed owner signing root and license |
| High | Installers verified mutable source and later copied it again, leaving a verify-to-use race | Closed. Both platforms freeze and reverify a private exact source snapshot before candidates; source-mutation injections fail before target/state creation (`tests/run.sh`, `tests/windows/lifecycle.ps1`) |
| High | Onboarding could write outside the intended repo after root/ancestor rename to a symlink/Junction | Closed for the tested boundary. Unix uses an open directory descriptor for discovery/apply; Windows checks native directory identity and private ACLs at mutation boundaries; both suites inject root swaps and prove the replacement target remains empty |
| Medium | Pending/current recovery did not always require a complete object inventory | Closed. Exact operation/object ID sets and parent-derived rollback sets are validated globally before mutation; truncated pending journals remain pending and leave live hashes unchanged on both platforms |
| Medium | Benchmark credential/tool-network boundary lacked a real negative canary | Open pending live evaluation. Shared auth is removed, dedicated key only is enforced, tool env/network and `/proc` are denied, but the real-model canary requires the dedicated benchmark key |
| Medium | Model worker lacked host resource limits | Mitigated. Worker now uses `prlimit` for CPU, address space, output file size, descriptors, processes, and core dumps; verifier retains separate Bubblewrap/network/timeout/resource limits. No cgroup/disk-quota claim is made |

Additional release hardening after the review validates full journal schemas,
derived stage/old/backup paths and hashes, whole-file global-guidance CAS, corrupt
preimages, source inventory/hash, reparse/path classes, exact backup restore, and
onboarding conflict acknowledgement. The executed receipts are in
[platform tests](../evidence/2026-08-13-platform-tests.md).

## Review status

No critical finding was reported. Public publication remains blocked on owner
publisher identity/license; real live benchmark security evidence remains
partial. A fresh final security review against an immutable revision is still
required before the local release candidate can be signed off.
