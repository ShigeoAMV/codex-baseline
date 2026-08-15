# Windows update regression fix plan

Date: 2026-08-14

## Objective

Restore installed-runtime `codex-baseline update` on native Windows after two
user-observed failures: an invalid `HttpWebRequest` redirect-property value in
Windows PowerShell 5.1 and an avoidable `Get-Acl` module-autoload dependency
seen when the command was launched from PowerShell 7 through a Windows
PowerShell shim.

## Scope

- Keep the existing manual HTTPS redirect validation, host allowlist, timeout,
  byte limits, credential policy, private staging, and ACL checks unchanged.
- Remove the invalid automatic-redirect limit assignment while retaining
  `AllowAutoRedirect = $false`.
- Read directory ACLs through the native runtime API appropriate to Windows
  PowerShell/.NET Framework and PowerShell 7/.NET instead of the `Get-Acl`
  cmdlet/module-autoload path.
- Create private staging directories through the equivalent ACL-aware native
  API exposed by each runtime.
- Add causal regression coverage under Windows PowerShell 5.1 and, when
  installed, PowerShell 7.
- Regenerate the installable payload manifest because the PowerShell runtime is
  part of the versioned payload.

## Non-goals

- Do not edit the user's installed runtime or custom `codex-baseline.cmd` shim.
- Do not change update endpoints, redirect count, allowed hosts, proxy policy,
  archive validation, trust labels, acknowledgement, transaction, or rollback
  behavior.
- Do not add a dependency, hook, configuration key, network call in tests, or a
  new launcher format.
- Do not publish, commit, or install the fix as part of this task.

## Constraints, dependencies, and evidence

- Update/network and ACL path handling are HIGH RISK and must fail closed.
- Tests must use the existing local update fixtures; no production endpoint or
  authentication/session file may be accessed.
- Microsoft documents that `MaximumAutomaticRedirections` throws when set to
  zero or less and matters only when automatic redirects are enabled.
- .NET Framework exposes `DirectoryInfo.GetAccessControl()`; modern .NET
  exposes the equivalent static `FileSystemAclExtensions.GetAccessControl()`.
  Both paths request only the consumed Access and Owner sections and enumerate
  native SID rules with `GetAccessRules`; requesting the SACL would require an
  unavailable privilege, and PowerShell 7 does not provide the adapted
  `.Access` property without the Security module.
- Windows PowerShell 5.1 and PowerShell 7.6.3 are available on the current host.
- Rollback for repository changes is the exact reviewed diff; runtime recovery
  remains the existing transaction/rollback mechanism and is not modified.

## Frozen acceptance criteria

| ID | Observable criterion | Strongest feasible proof |
| --- | --- | --- |
| WU1 | Request setup never assigns zero to `MaximumAutomaticRedirections`; automatic redirects remain disabled and redirects remain manually validated | Causal static source assertion for request setup plus existing redirect-policy inspection; local transport intentionally bypasses HTTP |
| WU2 | Private staging ACL validation no longer invokes `Get-Acl` in production and preserves owner/access/protection checks | Source assertion plus PowerShell 5.1 and 7 lifecycle ACL/adversarial tests |
| WU3 | Installed-wrapper update check succeeds with local transport under Windows PowerShell 5.1 | Existing installed-wrapper lifecycle fixture |
| WU4 | The same installed wrapper update check succeeds directly under available PowerShell 7 | New optional-on-availability native lifecycle assertion |
| WU5 | No target/state mutation, network, auth read, redirect-policy weakening, or rollback regression is introduced | Existing snapshots/canaries, full native suites, payload check, diff review |
| WU6 | Installable manifest exactly describes the changed payload | Canonical payload generator comparison |

The contract is frozen by the user's request to fix both pasted failures.
Later scope changes require explicit user authority or new executable evidence.

## Risks and controls

| Risk | Control / recovery |
| --- | --- |
| Removing the invalid property accidentally enables redirects | Retain and assert `AllowAutoRedirect = $false`; existing loop validates every response location and host |
| Runtime-specific ACL API returns different information | Request the same required Access/Owner sections and run identical owner/access/protection checks under both engines |
| PowerShell 7 lacks the .NET Framework ACL-aware directory overload | Use its documented `FileSystemAclExtensions.CreateDirectory` equivalent and immediately revalidate the resulting ACL |
| PowerShell 7 coverage becomes a mandatory new runtime dependency | Execute the compatibility assertion only when `pwsh` is present; PowerShell 5.1 remains the minimum |
| Test seam bypasses production behavior | Invoke the installed wrapper and existing local descriptor/archive transport through the real staging and ACL path |
| Payload integrity drifts | Regenerate and compare all byte/hash entries; review only the expected manifest delta |

## Task graph

1. Record fail-before evidence for the invalid property and PowerShell 7 ACL
   compatibility path.
2. Obtain a fresh read-only design challenge against this contract. Resolved:
   enumerate native SID rules instead of the absent PowerShell 7 `.Access`
   adapter; request Access and Owner rather than privileged SACL data; add a
   PowerShell 7 adversarial ACL case; keep request construction proof static
   because tests may not open even a loopback network listener.
3. Add focused regression assertions.
4. Implement the smallest runtime-compatible request/ACL fix.
5. Regenerate the payload manifest and run focused native tests.
6. Run the complete PowerShell suites and feasible full local checks.
7. Review the diff, obtain independent conformance review, and map WU1-WU6 to
   exact command receipts.

## Current milestone, blockers, and stopping conditions

Current milestone: implementation, deterministic verification, and independent
conformance review complete.

No authority blocker exists. The PowerShell 7 `Get-Acl` module-load error was
not reproduced in a clean nested shell, so the fix must remove only the
unnecessary module dependency and must not weaken ACL validation to chase an
environment-specific symptom.

Stop if either runtime lacks a native ACL API with equivalent owner/access/
protection data, if the fix requires weakening redirect or staging security, if
tests would contact the public endpoint, or after one repeated iteration adds
no new evidence.

## Verification receipt and criterion mapping

- Fail-before native lifecycle: exit 1 at the new assertion because production
  assigned `MaximumAutomaticRedirections = 0`.
- Fail-before focused ACL source assertion: exit 1 because production invoked
  `Get-Acl`.
- Windows PowerShell 5.1 and PowerShell 7 parsers accept the changed runtime.
- `tests/windows/lifecycle.ps1`: PASS, 141 assertions under Windows PowerShell
  5.1.26100.8875, including PowerShell 7.6.3 installed-update happy path and
  adversarial untrusted-ACL rejection.
- `tests/run-powershell.sh`: PASS, 141 lifecycle plus 69 onboarding/benchmark
  assertions.
- `tests/run.sh`: PASS, 13/13 groups from a private WSL filesystem copy with
  pinned ShellCheck 0.9.0 and Codex 0.147.0 tools; no external network.
- Canonical `scripts/release-payload.sh` output equals
  `baseline/manifest.json`: payload hash
  `9472d60d49f60ab618c0b4dba185e585731f1e0340e49cc917cef09acd6fa9f2`.

| Criterion | Result / evidence |
| --- | --- |
| WU1 | delivered: invalid assignment absent; static test retains `AllowAutoRedirect = $false`; existing manual redirect loop/allowlist unchanged |
| WU2 | delivered: no production `Get-Acl`; both runtimes request Access/Owner and enumerate native SID rules; adversarial checks pass |
| WU3 | delivered: installed-wrapper update check passes under Windows PowerShell 5.1 local transport |
| WU4 | delivered: installed-wrapper update check passes directly under PowerShell 7.6.3 local transport |
| WU5 | delivered: full native and Unix lifecycle/security/rollback/canary suites pass without external network or installed-runtime edits |
| WU6 | delivered: canonical per-file and aggregate payload hashes match the manifest exactly |

Missing: none. Partial: none within this bug-fix contract. Drifted or
unauthorized: none. The public production endpoint remains outside test scope,
as required by the repository's no-network test contract.

Fresh advisory conformance review (shared workspace, isolation not technically
enforced): no Critical, High, Medium, or Low finding; WU1-WU6 and the explicit
user request classified `delivered`; verdict `accept`. The reviewer retained
the existing self-update U6 public-endpoint limitation as `partial` and noted
that activating the fix in the user's installed runtime remains a separate,
explicitly authorized deployment step.
