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

Acquire a reviewed source release separately, inspect its revision/diff, then:

```bash
./scripts/codex-baseline.sh update --dry-run
./scripts/codex-baseline.sh update --acknowledge-unverified-source
codex-baseline doctor
```

Both preview and apply verify the exact versioned payload. The installer prints
local source origin, revision/dirty state when available, unsigned trust label,
and aggregate payload SHA-256. Apply requires acknowledgement because the
manifest is integrity metadata, not a publisher signature. Fetch stays outside
the installer: acquire -> inspect -> preview -> apply.

An update is another parent-linked transaction. Schema migrations must be added
to both platform implementations and the shared `baseline/operations.json`
contract, then exercised against the previous release before changing `schema`.
v0.1.0 supports schema 1 only and fails closed on a different source schema.

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
