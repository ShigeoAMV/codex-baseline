# Operations, upgrades, and recovery

## Inspect

`doctor` reports Codex/platform, installed transaction, global marker count,
managed object hashes, four skills, native capability smoke, zero owned config
keys/hooks, installed baseline version, source trust/scope/payload digest, and
research age. It also reports required runtime-command health, the effective
managed paths, strict-config acceptance, whether the current Codex probe
reported deprecated/unsupported settings, and the explicit boundary that
user-owned hooks are preserved but not enumerated. Unix and Windows JSON share
`codex-baseline-doctor/v1`; platform-specific verification labels remain
explicit. Versions newer than manifest `tested_codex` still receive strict and
feature probes but are labelled `unverified-future-version` rather than assumed
compatible. JSON is intended for automation.

The state lives below `$CODEX_HOME/codex-baseline/state` (the equivalent native
Windows path on Windows). Inspect it, but do not hand-edit an active journal.

## Update

The installed wrapper can check and stage the latest stable GitHub release:

```bash
codex-baseline update --check
codex-baseline update --dry-run
codex-baseline update --acknowledge-unverified-source
codex-baseline doctor
```

`--check` downloads only the strict v1 descriptor. Preview/apply downloads the
platform archive into private staging, enforces HTTPS redirect/host/time/size
limits, verifies descriptor byte count and SHA-256, rejects unsafe/special/
oversize archive members, and requires the extracted inventory to equal the
payload manifest plus manifest file. Downloaded scripts are never executed;
the already-installed updater verifies and applies the data through the normal
transaction engine. It repeats anti-downgrade validation while holding the
mutation lock.

The descriptor and archive are still on the same unsigned publisher boundary.
Apply therefore requires explicit acknowledgement and reports
`unsigned-github-release`; the installed artifact remains labelled
`unsigned-local-source` until publisher signing and an independent trust root
exist. No GitHub/Codex credential is used. Platform-native HTTPS proxy settings
remain user-controlled transport configuration.

For a reviewed local checkout or pre-acquired archive, keep networking outside:

```bash
./scripts/codex-baseline.sh update --local --dry-run
codex-baseline update --offline /path/to/codex-baseline-0.2.0.tar.gz --dry-run
codex-baseline update --offline /path/to/codex-baseline-0.2.0.tar.gz --acknowledge-unverified-source
```

Native Windows uses the equivalent `-Check`, `-Local`, and `-Offline <zip>`
spellings. v0.1.1 predates self-update and needs one reviewed local transition
to v0.2.0; the v1 descriptor/assets are retained by later supported releases.

An update is another parent-linked transaction. Schema migrations must be added
to both platform implementations and the shared `baseline/operations.json`
contract, then exercised against the previous release before changing `schema`.
v0.2.0 supports schema 1 only and fails closed on a different source schema.

## Rollback and uninstall

```bash
codex-baseline rollback --dry-run
codex-baseline rollback
codex-baseline uninstall --dry-run
codex-baseline uninstall
```

Rollback unwinds the current committed state to its parent. Uninstall repeatedly
unwinds the install/update chain and retains transaction history for inspection.
Drift in a managed skill/reviewer/runtime/wrapper blocks the operation. User text
outside the AGENTS marker is preserved.

PowerShell supports the equivalent `-DryRun` spelling. A rollback of an uninstall
restores that uninstall transaction; a second rollback can restore pre-install
state, as covered by its lifecycle test. Rollback and uninstall operate from the
validated installed journal/current version and do not require trusting a newly
supplied update payload.

## Interrupted operation

The next non-dry mutation detects `state/pending`, validates the journal, and
recovers. If recovery fails, stop using mutation commands and inspect:

- pending transaction ID and `state`;
- each object's target, status, old/stage path, and backup;
- path links/reparse points or manual edits;
- filesystem capacity and permissions.

Do not remove state, old, or stage objects until their hashes and intended
preimage are understood. Preserve a copy of the entire baseline state directory
before manual recovery.

## Research refresh and release

The manifest records `research_checked` and `research_review_by`; `doctor` warns
after the review date. `scripts/research-check.sh --json` validates the pinned
offline research manifest and its agreement with the installable manifest.
Refresh official documentation, stable CLI behavior,
important upstream releases/issues, and material community failure modes. Then
update the evidence/decisions, capability/platform matrix, dates, tests,
`VERSION`, manifest, and changelog. A public release should add a cryptographic
signature and trust-root procedure at the distribution boundary; the repository
already carries the immutable per-file and aggregate payload digests used by
both native installers.

`scripts/release-payload.sh` deterministically prints the canonical payload
array and aggregate hash without editing the source. Compare its JSON with
`baseline/manifest.json`, review every changed path/hash, then run both complete
platform suites. The test suite rejects any manifest/generator disagreement.
