# Release and provenance

## Current status

Version 0.1.0 is a local release candidate. The installable payload is pinned by
path, byte length, per-file SHA-256, and aggregate digest, and both installers
freeze a reverified private snapshot before use. This proves internal integrity
relative to the checked-out manifest. It does not authenticate a publisher.
The consolidated current evidence and explicit missing gates are in the
[release candidate report](RELEASE-CANDIDATE-REPORT.md).

No public verified release is claimed until all of these are true:

1. the source is committed at an immutable revision and the tree is clean;
2. Linux/WSL and native PowerShell suites pass at that revision;
3. real paired/routing evaluation uses a dedicated short-lived API key and the
   credential/network canary passes;
4. final security, architecture/maintainability, and original-request reviews
   are recorded and all critical findings are resolved;
5. the traceability ledger and final report point to the exact receipts;
6. the publisher chooses an explicit license and an offline-controlled signing
   identity whose public trust root is distributed independently of the release;
7. an immutable source archive, manifest, and checksum are signed, and clean
   install/rollback is reproduced from that archive before publication.

Do not generate and commit a signing private key, and do not treat a public key
shipped only inside the same unsigned archive as a trust root. Until an owner
supplies that external publisher identity, install requires explicit
`unsigned-local-source` acknowledgement and release notes retain that label.

## Maintainer checklist

```bash
scripts/research-check.sh --json
scripts/release-payload.sh
./tests/run.sh
./tests/run-powershell.sh
git status --short
git rev-parse HEAD
```

Compare the payload generator with `baseline/manifest.json`, inspect every
changed file, and save command exits, platform versions, source revision, and
payload hash in the release evidence. Signing and publishing are separate,
explicit maintainer actions; lifecycle commands perform no fetch or network
access.
