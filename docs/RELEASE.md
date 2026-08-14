# Release and provenance

## Current status

Version 0.2.0 is an Apache-2.0-licensed public source preview. The installable
payload is pinned by path, byte length, per-file SHA-256, and aggregate digest,
and both installers freeze a reverified private snapshot before use. This
proves internal integrity relative to the checked-out manifest. It does not
authenticate a publisher. The consolidated current evidence and explicit
missing gates are in the [release candidate report](RELEASE-CANDIDATE-REPORT.md).

No public verified release is claimed until all of these are true:

1. the source is committed at an immutable revision and the tree is clean;
2. Linux/WSL and native PowerShell suites pass at that revision;
3. real paired/routing evaluation uses a dedicated short-lived API key and the
   credential/network canary passes;
4. final security, architecture/maintainability, and original-request reviews
   are recorded and all critical findings are resolved;
5. the traceability ledger and final report point to the exact receipts;
6. the publisher supplies an offline-controlled signing identity whose public
   trust root is distributed independently of the release;
7. an immutable source archive, manifest, and checksum are signed, and clean
   install/rollback is reproduced from that archive before publication.

Do not generate and commit a signing private key, and do not treat a public key
shipped only inside the same unsigned archive as a trust root. The Apache-2.0
license permits public use and contribution, but it does not solve publisher
authentication. Until an owner supplies that external publisher identity,
install requires explicit `unsigned-local-source` acknowledgement and release
notes retain that label.

## Maintainer checklist

```bash
scripts/research-check.sh --json
scripts/release-payload.sh
python3 scripts/release-update.py --output /private/release-output
./tests/run.sh
./tests/run-powershell.sh
git status --short
git rev-parse HEAD
```

Tracked reports participate in the complete live `source_hash`. Avoid a
self-referential evidence commit with this sequence:

1. run preliminary paired, routing, and Canary evaluation;
2. reconcile the tracked traceability/report documents and commit them;
3. rerun both platform suites on that clean commit;
4. rerun all three live commands directly from the unchanged checkout;
5. put final receipt hashes and independent-review attestations in a detached
   `release-attestations` ref or equivalent external signed statement;
6. make no subsequent tracked edit to the evaluated commit.

The three live commands must report the same source hash and revision. The
installed wrapper is useful operationally, but it hashes the reduced installed
runtime and therefore is not the final full-checkout release evidence path.

Compare the payload generator with `baseline/manifest.json`, inspect every
changed file, and save command exits, platform versions, source revision, and
payload hash in the release evidence. Signing and publishing are separate,
explicit maintainer actions. Install, doctor, rollback, uninstall, local/offline
update, and tests perform no fetch; installed-runtime/explicit remote update
uses only the published bounded v1 descriptor and platform assets.
