# Self-update delivery plan

Date: 2026-08-14

## Objective

Let an installed `codex-baseline` discover, preview, download, verify, and apply
the latest stable GitHub release without requiring the user to maintain or pull
a Git checkout, while preserving the existing transactional update, recovery,
and rollback guarantees.

## Scope

- Add `codex-baseline update --check` for a non-mutating latest-release check.
- Make `codex-baseline update --dry-run` from the installed runtime fetch and
  verify the release payload, then exercise the existing transactional preview.
- Make acknowledged installed-runtime `update` stage and verify the release,
  then let the currently installed updater apply that data source through the
  existing transaction engine. Downloaded scripts are never executed pre-apply.
- Keep checkout-local update behavior available and add an explicit offline
  archive path for reviewed/pre-acquired releases.
- Support Linux/WSL with Bash and native Windows with PowerShell 5.1.
- Add a deterministic maintainer command for producing the two release archives
  and the strict latest-release descriptor consumed by both clients.
- Update lifecycle, release, security, architecture, troubleshooting, version,
  changelog, payload manifest, and traceability documentation.

## Non-goals

- Do not run `git pull`, edit a checkout, install Git, or require Git at runtime.
- Do not claim publisher authentication while no independently distributed
  trust root and signing identity exist.
- Do not generate, store, or request a signing private key.
- Do not auto-update in the background, add a daemon/hook, or contact GitHub
  during install, doctor, rollback, uninstall, or tests.
- Do not weaken managed-drift checks, source acknowledgement, rollback, or
  interrupted-transaction recovery.
- Do not support arbitrary update mirrors or prerelease channels in this change.

## Constraints and decisions

- Workflow is DEEP and update networking is HIGH RISK.
- The only production metadata endpoint is the repository's fixed GitHub
  `releases/latest/download/codex-baseline-update-v1.txt` asset. Its exact ASCII
  grammar and order are:

  ```text
  contract=codex-baseline-update/v1
  version=<MAJOR.MINOR.PATCH>
  tag=v<same version>
  trust=unsigned-github-release
  tar_name=codex-baseline-<version>.tar.gz
  tar_bytes=<1..67108864>
  tar_sha256=<64 lowercase hex>
  zip_name=codex-baseline-<version>.zip
  zip_bytes=<1..67108864>
  zip_sha256=<64 lowercase hex>
  ```

  There are exactly ten LF-terminated lines, no duplicate/extra fields, and no
  control/non-ASCII bytes. Version-pinned asset URLs are derived locally as
  `https://github.com/ShigeoAMV/codex-baseline/releases/download/<tag>/<name>`;
  the descriptor cannot supply a URL.
- Linux/WSL consumes a `.tar.gz`; Windows consumes a `.zip`. Each archive hash
  must match the descriptor before extraction and bind descriptor version = tag
  = archive root = `VERSION` = manifest version. The extracted source must then
  pass the existing exact manifest/payload verification before planning.
- Archives are extracted only below private temporary directories. Entry names,
  kinds, duplicates, traversal, links/reparse points, and the single top-level
  source root are validated before use. Limits are 64 MiB compressed, 128 MiB
  total regular-file content, 512 entries, eight path components, and 240 ASCII
  path bytes. Sparse/PAX/device/special members, `.git`, ADS/device names,
  trailing dot/space segments, and Windows case-fold collisions are rejected.
  The post-extraction regular-file inventory must equal the manifest payload
  plus `baseline/manifest.json`; no other file is accepted.
- The descriptor and archive share the same GitHub publisher boundary. Hashes
  protect transfer consistency, not publisher authenticity. Live apply remains
  gated by the existing explicit unsigned-source acknowledgement.
- Production downloads use HTTPS only, at most three manually validated
  redirects, only `github.com`, `release-assets.githubusercontent.com`, and
  `objects.githubusercontent.com`, a 10-second connect and 60-second per-request
  limit, streaming byte ceilings, and no retry. Curl user configuration is
  disabled. No GitHub/Codex token is read or sent; platform-native HTTPS proxy
  configuration remains an explicit user-controlled transport boundary.
- Tests use local fixtures/test-only transport injection; they perform no
  external network request.
- Existing transaction schema and object inventory remain unchanged. Network
  acquisition completes before the mutation lock/transaction begins. The
  trusted updater repeats current-version/anti-downgrade validation while
  holding that lock, immediately before planning.
- The v1 endpoint always denotes a monotonically increasing stable release;
  every supported future release must continue publishing both v1 assets until
  a separately designed compatibility transition exists.
- Artifact trust (`unsigned-local-source`) remains the manifest/doctor value;
  acquisition channel (`unsigned-github-release`, `offline-archive`, or local
  checkout) is printed by update and is not misrepresented as authenticated or
  persisted by the unchanged transaction schema.

## Risks and controls

| Risk | Control / recovery |
| --- | --- |
| Compromised or mutable publisher channel | Honest `unsigned-github-release` label, explicit acknowledgement, exact descriptor/archive/payload verification; signed releases remain a separate gate |
| Archive traversal, link, reparse, bomb, or canonical collision | Strict bounded inventory before extraction, private temp root, exact post-extraction inventory, and negative fixtures |
| Partial/corrupt download | Exact time/redirect/byte ceilings, HTTPS host allowlist, SHA-256 match, cleanup on every exit |
| Downgrade or malformed version | Stable numeric SemVer validation and refusal to apply an older version through the remote path |
| Apply failure after acquisition | Existing journal recovery and exact `rollback`; downloaded staging is disposable |
| Platform drift | Shared descriptor contract, equivalent native implementations, Unix full suite, and native PowerShell suite |
| Unexpected network behavior | Network occurs only for installed-runtime update/check; install, doctor, rollback, uninstall, local/offline update, and all tests remain networkless |

## Frozen acceptance criteria and proof

| ID | Observable criterion | Strongest planned proof |
| --- | --- | --- |
| U1 | Installed `update --check` reports current and latest stable version without changing managed/state files | Unix and PowerShell lifecycle fixture snapshots |
| U2 | Installed `update --dry-run` downloads/verifies/extracts the release and runs the existing plan without managed/state mutation | End-to-end local-transport lifecycle tests |
| U3 | Acknowledged installed `update` applies release data transactionally without executing downloaded code; doctor reports it and rollback restores the exact prior state | Cross-version installed-wrapper Unix and PowerShell lifecycle tests with an execution canary and exact hashes |
| U4 | Checkout-local and explicit offline archive update paths require no network and remain supported | Lifecycle tests with network-client canary/failure fixture |
| U5 | Wrong archive hash, malformed/oversize descriptor, downgrade including a concurrent newer install, traversal, duplicate/case collision, link/reparse/special entry, bomb/oversize, wrong root, offline replacement race, and manifest/payload tampering fail before mutation | Adversarial negative fixtures on both platforms |
| U6 | Update sends no GitHub/Codex authentication, disables user client config, enforces the HTTPS redirect-host/time/size policy, and documents native proxy behavior | Static scan, redirect/timeout/host-escape fixtures, credential environment canary, and security review |
| U7 | Release artifacts are reproducible from a clean source and descriptor/archive hashes agree | Deterministic release-artifact command and repeat/hash test |
| U8 | Help and production docs clearly distinguish remote, local, offline, unsigned trust, dry-run, and rollback | Documentation/link/contract checks |
| U9 | Existing install/doctor/rollback/uninstall behavior and full platform suites remain green | `./tests/run.sh` and `./tests/run-powershell.sh` |
| U10 | The unavoidable one-time transition from v0.1.1 is honest: that already-installed code cannot gain a command retroactively; a reviewed local v0.2.0 install/update is documented once, after which v1 self-update is supported | Upgrade documentation and an explicit compatibility test beginning with the first self-update-capable runtime |

The contract is frozen by the user's 2026-08-14 request to add the previously
recommended self-update behavior. Later criterion changes require a recorded
source and authority here.

## Task graph

1. Freeze this contract and record current upstream/API facts.
2. Add fail-before lifecycle and adversarial update fixtures.
3. Implement the strict release descriptor/artifact producer.
4. Parameterize the trusted transaction engine for a verified data source and
   implement Bash acquisition, archive validation, locked downgrade recheck,
   apply, and cleanup without executing archive content.
5. Implement equivalent PowerShell 5.1 behavior.
6. Regenerate the installable manifest and update version/docs/contracts.
7. Run targeted negatives, full Unix, and native PowerShell suites.
8. Inspect the complete diff, obtain fresh security/design review, fix justified
   findings, rerun affected checks, and run original-request conformance review.

## Current milestone and blockers

Current milestone: implementation, deterministic release generation, Unix
installed-wrapper integration, and adversarial/concurrency fixtures are
complete. The focused Unix self-update group, syntax checks, documentation link
check, payload-manifest comparison, and fresh security review pass. The
environment-limited full-platform reruns remain.

There is no published GitHub release yet, so production endpoint success cannot
be exercised against a real release in this change. Local transport fixtures
prove the client protocol without external network access. Publisher signing is
blocked on an owner-controlled identity and independently distributed trust
root and is deliberately not inferred from this request. Existing v0.1.1 code
cannot be retrofitted; it needs one final reviewed local acquisition of the
first self-update-capable release.

The current WSL environment lacks ShellCheck and has Codex CLI 0.145.0 below
the project's required 0.147.0, so the full Unix suite stops on environment
preconditions. The native Windows suite fails closed before lifecycle mutation
because `%LOCALAPPDATA%` grants inherited FullControl to foreign SID
`S-1-5-21-2363829159-3772595814-2973517376-1002`. These controls are not relaxed;
clean receipts require compliant test hosts.

## Stopping conditions

- Stop before mutation if authority expands beyond this repository or managed
  baseline paths.
- Stop if a safe cross-platform archive validation path cannot be established.
- Stop rather than weaken provenance, drift, recovery, or rollback gates.
- Stop after one repeated no-new-evidence iteration and report the unresolved
  issue instead of looping.
