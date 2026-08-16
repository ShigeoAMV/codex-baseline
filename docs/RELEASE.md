# Release and provenance

## Current status

The numeric source payload is `0.3.0` and the release status is `rc.1`. It is an
Apache-2.0-licensed, unsigned public source preview, not a stable tag or stable
channel release. The payload is pinned by path, byte length, per-file SHA-256,
and aggregate digest, and both installers freeze a reverified private snapshot
before use. This proves internal integrity relative to the checked-out manifest;
it does not authenticate a publisher. The v0.3 frozen gates are in the
[autonomous execution plan](plans/2026-08-15-autonomous-multi-agent.md). The
[v0.3 release candidate report](RELEASE-CANDIDATE-REPORT-0.3.md) records the
current deterministic and external evidence boundary. The older
[release candidate report](RELEASE-CANDIDATE-REPORT.md) remains the historical
v0.2 evidence record rather than proof for this candidate.

No public verified release is claimed until all of these are true:

1. the source is committed at an immutable revision and the tree is clean;
2. Linux/WSL and native PowerShell suites pass at that revision;
3. the frozen four-arm, ten-repetition live evaluation uses a dedicated
   short-lived API key, meets every v0.3 promotion threshold, and the
   credential/network canary passes;
4. final security, architecture/maintainability, and original-request reviews
   are recorded and all critical findings are resolved;
5. the traceability ledger and final report point to the exact receipts;
6. the publisher supplies an offline-controlled signing identity whose public
   trust root is distributed independently of the release;
7. an immutable source archive, manifest, and checksum are signed, and clean
   install/rollback is reproduced from that archive before publication.

Without the benchmark key, deterministic implementation may stop at
`0.3.0`/`rc.1`. It must not create a stable `0.3.0` tag, publish to the stable
update channel, or claim autonomous speed/quality improvement. Fast is evaluated
separately and cannot be counted as a subagent speedup.

This boundary is machine-readable. The manifest-hashed payload record
`baseline/release-status.json` carries `rc.N|stable` without changing the
v0.2-compatible manifest grammar; `scripts/release-update.py` emits an
RC-labelled preview descriptor/assets for `rc.N`. A payload marked `stable`
cannot produce the stable v1 descriptor in this RC. The future promotion
contract requires an evidence-bound `codex-baseline-promotion/v2` receipt, its
four same-directory benchmark inputs (`summary.json`, `run.json`,
`results.jsonl`, and `benchmark-manifest.json`), and
`runner-attestation.json`. The detached runner attestation must bind the exact
RC commit/source, all four evidence hashes, and the Codex, Node, telemetry
adapter, and task-verifier identities. A signature asserted by those same local
files is not independent evidence. No independently distributed attestation
trust root and verifier exists in `0.3.0-rc.1`, so the production builder
deliberately fails closed even when every local JSON field and benchmark gate
looks valid.
Every mandatory gate must be `passed`, host and runtime telemetry must be
`verified`, and the reasons inventory must be empty. A JSON document that merely
sets `promotion_allowed=true` has no authority.

Promotion uses two immutable commits. The evaluated candidate commit remains
`rc.N`. A direct descendant marks the payload `stable`; across the two complete
Git trees only `baseline/release-status.json` and the deterministically
regenerated `baseline/manifest.json` may differ. All other payload paths and
bytes must be identical. The validator requires its source to be that exact
clean stable HEAD, reconstructs and verifies the RC payload from Git objects,
freezes bounded ordinary evidence files, and runs the candidate-identical
`benchmarks/summarize.mjs` again over those bytes. Stable validation never uses
ambient `git` or `node`: the maintainer must supply absolute executable paths
and SHA-256 pins. Each binary must be an ordinary single-link file under safe
non-link ancestry; identity and content are rechecked before and after every use
and at the final publication boundary. The observed Node hash must equal
`run.node_binary_hash`. Git system/global/environment configuration, hooks,
optional locks, external diff drivers, and local process filters are disabled
or rejected. Symlinks, hardlinks, binary or evidence replacement, a dirty or
different HEAD, fake revisions, or any extra RC-to-stable change fail closed.
Release worktrees must be byte-exact (`core.autocrlf=false`; no checkout-time
content conversion), because the validator compares tracked file bytes and
executable modes with the stable Git tree rather than trusting stat cache or a
porcelain clean label.

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
# For rc.N this produces preview-only assets.
python3 scripts/release-update.py --output /private/release-output
# Stable artifact generation is intentionally unavailable in this RC. A future
# release must add an externally trusted runner-attestation verifier before the
# following pinned validation inputs can become a publishing path:
# python3 scripts/release-update.py --output /private/release-output \
#   --promotion-receipt /private/promotion-evidence/promotion.json \
#   --git-binary /absolute/ordinary/git --git-sha256 "$GIT_SHA256" \
#   --node-binary /absolute/ordinary/node --node-sha256 "$NODE_SHA256"
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

The three live commands must report the same source hash and RC revision. After
they pass, create the stable descendant by changing only release status and its
deterministic manifest, then create the detached v2 receipt naming both commits,
the exact hashes of the four frozen evidence files, and the independently
verifiable runner attestation. This RC can validate local structure but cannot
authenticate that attestation, so this sequence still stops before stable
artifact generation. The installed wrapper is useful operationally, but it
hashes the reduced installed runtime and therefore is not the final
full-checkout release evidence path.

`tests/release-promotion.py --build-update-fixture` creates explicitly synthetic
stable archives only for offline lifecycle/update tests. It bypasses production
promotion validation and is neither release evidence nor a supported publisher
interface.

Compare the payload generator with `baseline/manifest.json`, inspect every
changed file, and save command exits, platform versions, source revision, and
payload hash in the release evidence. Signing and publishing are separate,
explicit maintainer actions. Install, doctor, rollback, uninstall, local/offline
update, and tests perform no fetch; installed-runtime/explicit remote update
uses only the published bounded v1 descriptor and platform assets.
