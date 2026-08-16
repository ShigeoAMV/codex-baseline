# Operations, upgrades, and recovery

## Inspect

`doctor` reports Codex/platform, installed transaction, global marker count,
managed object hashes, four skills, native capability smoke, owned config keys
and drift, optimizer/Fast/Ultrafast capability, zero owned hooks, installed
baseline version, source trust/scope/payload digest, and research age. It also
reports required runtime-command health, the effective
managed paths, strict-config acceptance, whether the current Codex probe
reported deprecated/unsupported settings, and the explicit boundary that
user-owned hooks are preserved but not enumerated. Unix and Windows JSON share
`codex-baseline-doctor/v2`; platform-specific verification labels remain
explicit. Versions newer than manifest `tested_codex` still receive strict and
feature probes but are labelled `unverified-future-version` rather than assumed
compatible. JSON is intended for automation.

The state lives below `$CODEX_HOME/codex-baseline/state` (the equivalent native
Windows path on Windows). Inspect it, but do not hand-edit an active journal.

## Optimize

Optimizer inspection is the default; mutation always requires `--apply`:

```bash
codex-baseline optimize
codex-baseline optimize --check --json
codex-baseline optimize --apply
codex-baseline optimize --speed fast --dry-run
codex-baseline optimize --speed fast --apply
codex-baseline optimize --speed standard --apply
codex-baseline optimize --restore --dry-run
codex-baseline optimize --restore --apply
```

Without an explicit speed argument, `speed=keep` preserves the session setting.
The general apply path enables agents and sets cap six through key ownership.
Fast owns the pair `service_tier = "fast"` and `features.fast_mode = true`;
standard removes only unchanged Baseline-owned Fast values and rejects a
conflicting unowned service tier. Ultrafast currently exits nonzero with the
structured status `unavailable` and does not change any bytes. Parent model,
reasoning/Ultra, providers, permissions, and global child model/effort defaults
are never managed.

A fresh install has one automatic exception: it may add a previously absent
`agents.max_concurrent_threads_per_session = 6` if agents are not explicitly
disabled and neither a current nor legacy cap exists. Existing values always
win; `agents.enabled=false` and `features.multi_agent=false` both veto this
exception and remain user-owned. Update does not acquire a previously unowned
cap. PowerShell uses the
equivalent `-Check`, `-Apply`, `-DryRun`, `-Restore`, and `-Speed` spellings.

The whole `config.toml` is never owned. Strict parsing rejects invalid TOML and
ambiguous duplicate, dotted, quoted, or inline definitions of managed paths.
The patcher preserves foreign bytes, comments, Unicode, BOM, line endings, and
final-newline state. Journals contain only allowlisted key paths, safe scalar/
trivia bytes, and hashes, never a full config or secrets. Candidate validation
uses an isolated temporary `CODEX_HOME`; key-level three-way restore keeps
unrelated user edits and stops on managed-key drift.

The core file transaction contract intentionally remains the eight-object
`codex-baseline-operations/v1` contract so installed v0.2 updaters can validate
the candidate. Config is the separately versioned
`codex-baseline-config-operations/v2` plane under the same lock. A fresh
install's core and cap changes form one composite operation: both preflight,
the composite intent is durable before core commit, and the allowlisted cap is
applied only after core reaches the desired state. Recovery resumes the config
delta after a committed core change or retains the source config when core
recovery returns to the source. Rollback and uninstall use the same core-first,
config-second coordinator, so config ownership is not released ahead of a
failed reverse core transaction.
Together these planes are the v0.3 operations-v2 product contract; the label
does not alter the compatibility-critical core schema.

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

An `rc.N` checkout is deliberately absent from that stable channel.
`scripts/release-update.py` emits an RC-labelled, non-consumable preview
descriptor and RC-labelled assets while the manifest-hashed
`baseline/release-status.json` remains `rc.N`. Only a `stable` payload plus an
exact clean-revision promotion receipt may emit the consumable v1 descriptor;
this prevents an RC working tree from accidentally publishing stable-looking
metadata.

For a reviewed local checkout or pre-acquired archive, keep networking outside:

```bash
./scripts/codex-baseline.sh update --local --dry-run
codex-baseline update --offline /path/to/codex-baseline-0.2.0.tar.gz --dry-run
codex-baseline update --offline /path/to/codex-baseline-0.2.0.tar.gz --acknowledge-unverified-source
```

Native Windows uses the equivalent `-Check`, `-Local`, and `-Offline <zip>`
spellings. v0.1.1 predates self-update and needs one reviewed local transition
to v0.2.0; the v1 descriptor/assets are retained by later supported releases.

An update is another parent-linked transaction. The core schema stays at v1 for
v0.2 compatibility; config semantics evolve through the separate v2 contract.
Cross-version tests must exercise v0.2 -> v0.3 apply, rollback, uninstall, and
crash recovery before promotion. A v0.2 runtime still fails closed on a changed
core schema, which is why v0.3 does not change it.

## Rollback and uninstall

```bash
codex-baseline rollback --dry-run
codex-baseline rollback
codex-baseline uninstall --dry-run
codex-baseline uninstall
```

Rollback unwinds the current committed state to its parent. Uninstall repeatedly
unwinds the install/update chain and retains transaction history for inspection.
Drift in a managed skill/reviewer/runtime/wrapper or owned config key blocks the
operation. User text outside the AGENTS marker and unrelated config changes are
preserved. Rollback/uninstall remove or restore only an unchanged
Baseline-installed scalar; an independently edited owned key stops closed.

PowerShell supports the equivalent `-DryRun` spelling. On PowerShell, a rollback
of an uninstall restores that uninstall transaction; a second rollback can
restore pre-install state, as covered by its lifecycle test. Unix uninstall
unwinds to the terminal uninstalled state and is not itself rollback-restorable.
Rollback and uninstall operate from the validated installed journal/current
version and do not require trusting a newly supplied update payload.

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
