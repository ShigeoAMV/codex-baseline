# Windows private staging root regression

## Objective

Make local Windows install/update work from a normal Codex-managed user profile
without weakening the fail-closed ACL boundary used for verified source staging.

## Scope

- Select a private staging parent whose ancestors cannot be mutated by sandbox
  or unrelated user SIDs.
- Preserve the current protected owner/DACL checks on the created directory.
- Add native PowerShell 5.1 and 7 regression coverage for a user home carrying
  an untrusted mutable ACE.
- Exercise the real local update command and preserve rollback/recovery.

## Non-goals

- Trusting Codex sandbox accounts, stale SIDs, `Users`, or `Authenticated Users`.
- Relaxing source manifest, reparse-point, ownership, or DACL validation.
- Publishing a GitHub update release; the installed-wrapper 404 remains a
  separate absence-of-release condition.

## Constraints and risks

- Staging is security-sensitive because verified source bytes become executable.
- A writable ancestor can replace or remove a protected child, so protecting
  only a directory inside the user profile is insufficient.
- The system-volume root must itself pass the existing ancestor ACL checks, and
  the random staging directory must be created with the existing protected ACL.
- Enterprise systems that forbid creating a private directory at the system
  volume root must fail closed with a clear diagnostic.

## Acceptance criteria and proof

1. Production staging no longer traverses the mutable user-profile ancestry.
   Proof: native regression with an explicitly untrusted mutable home ACE.
2. The chosen system-volume root and every existing ancestor are checked with
   the existing untrusted Delete/DeleteChild/ACL/ownership rules.
   Proof: code inspection plus retained adversarial ACL tests.
3. The created directory remains current-user-owned, protected, and grants full
   control only to the current user, SYSTEM, and Administrators.
   Proof: existing native ACL assertions under PowerShell 5.1 and 7.
4. A real local `update -AcknowledgeUnverifiedSource` succeeds and `doctor`
   reports the installed payload.
   Proof: direct native command receipt on this host.
5. The latest-release 404 is not hidden or reclassified.
   Proof: documentation/handoff states that remote update needs a published
   GitHub release asset.

## Task graph

1. Reproduce and identify the SID/ancestor responsible.
2. Challenge the staging-root design against ACL and race boundaries.
3. Implement the smallest location-selection change and regression fixture.
4. Run focused tests, native lifecycle matrices, real local update, and doctor.
5. Run a fresh conformance review and resolve any Critical/High finding.

## Rollback and recovery

The implementation creates only a random, protected temporary directory and
removes it in the existing `finally` paths. If installation has committed but a
later check fails, `codex-baseline rollback` remains the product rollback. The
source change itself is reversible as a single Git commit.

## Current milestone and stopping conditions

Milestone: implemented and verified. The production-profile regression passes
under PowerShell 5.1 and 7.6.3; a real local update installed payload
`33207cf4...f34d`, and Doctor reports 8/8 objects with zero failures. The full
native lifecycle suite passes 625 assertions with exit zero and empty stderr.
Stop and reopen this plan if system-volume creation requires elevation on a
supported host, an adversarial ACL regression is weakened, or native
PowerShell parity regresses.
