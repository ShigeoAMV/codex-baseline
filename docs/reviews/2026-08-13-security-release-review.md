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

The second fresh read-only review inspected clean commit `46ba57b` and reported
no critical finding, two cross-platform local-RC highs, and one public-only high:

- Windows source snapshots inherited `%TEMP%` ACLs and were not revalidated
  immediately before use. Closed in the candidate: snapshot creation now
  requires a local reparse-free temporary root, protected owner-bound DACL,
  native directory identity, and a second complete manifest/payload verification.
  Native tests weaken the post-verify DACL and mutate post-verify content; both
  fail before managed-home mutation.
- Windows onboarding trusted every group in the caller token and did not verify
  owners. Closed in the candidate: only the caller, SYSTEM, and Administrators
  are trusted for mutation-capable ACEs, path owners are allowlisted, and a
  `BUILTIN\\Users` Delete-right test proves exact AGENTS bytes remain unchanged.
- Public publisher authenticity remains intentionally open and external.

The review also found eager Windows directory materialization; the collector now
uses lazy enumeration and stops as soon as `MaxVisited` is exceeded. Residual
live-run risks remain explicit: the API parent carries the dedicated key, and
`prlimit` is not an aggregate cgroup/PID/disk quota. A final read-only delta
review of the immutable candidate is still required; this record does not claim
that review before it happens.

## Third-round delta and disposition

The next read-only review of clean commit `0b3cf89` found no critical issue but
correctly withheld local-RC sign-off for two remaining Windows ACL windows:
untrusted `WRITE_DAC`/`WRITE_OWNER` rights were not treated as mutation-capable,
and only the private snapshot child, not its exchange-relevant temp ancestors,
was ACL-gated. The resulting candidate now:

- rejects untrusted Delete/DeleteChild/ChangePermissions/TakeOwnership rights
  across every relevant onboarding path component and tests broad-group Delete,
  WRITE_DAC, WRITE_OWNER, plus an injected untrusted-owner observation;
- avoids the observed shared `%TEMP%` boundary entirely, stages directly below
  validated local HOME, validates owner and mutation-capable ACLs through every
  HOME ancestor, then enforces the protected caller-owned child DACL and native
  child identity/full-payload rehash;
- points exact final-revision evidence to a detached Git attestation rather than
  pretending the historical tracked receipt covers later code.

The same review confirmed lazy `MaxVisited`, complete journal recovery checks,
the Unix directory-handle boundary, and the static benchmark key/verifier split.
Final sign-off still depends on a fresh read-only audit of the last commit and
the exact-commit platform attestation.
