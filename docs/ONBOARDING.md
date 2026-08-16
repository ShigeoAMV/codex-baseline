# Repository onboarding

Onboarding is a bounded static collector plus a focused interpretation skill.
The command previews by default and treats all repository bytes as untrusted
data. It never sources/imports/evaluates project code and never runs manifests,
package managers, builds, tests, hooks, Git commands, or network requests.
Global workflow routing works after installation and onboarding remains
optional. The RC's installed execution guidance instructs SOLO until live
promotion; this is not an OS/runtime spawn prohibition. The optional parallelism
map can improve future/evaluation AUTO decisions but does not activate
TEAM/SWARM.

```bash
codex-baseline onboard /path/to/repo
codex-baseline onboard --json /path/to/repo
codex-baseline onboard --max-files 2000 --max-entries 10000 /path/to/repo
codex-baseline onboard --apply /path/to/repo
codex-baseline onboard --apply --acknowledge-existing-instructions /path/to/repo
```

The collector inventories bounded files, manifests, CI, existing AI guidance,
docs, tests, quality configuration, deployment/IaC, source roots, generated paths,
and risk-shaped directories; excludes dependency/build trees, sensitive
filenames, oversized/binary-budgeted content, control-character names, and
links; and extracts only safe script names from an already accepted snapshot of
the root `package.json`. It reports visited entries separately from accepted
files so directory/link floods cannot bypass the traversal budget. Commands are
declared and unverified. Unix and Windows JSON share
`codex-baseline-onboarding/v2`; Windows uses `-MaxFiles`/`-MaxVisited`.

v0.3 also emits an optional static parallelism map. Recognized source folders
are labelled `source_root`; they are not promoted to package boundaries unless
a bounded package/workspace manifest supplies that evidence. Package/API
boundaries, generated-file ownership, shared caches/build outputs, ports,
databases, fixtures, declared test shards, and safe or conflict-prone write
areas remain explicit `unknown` placeholders when discovery has no evidence.
Every statement is labelled `declared`, `inferred`, or `unknown`; the map is
capped at 64 entries. Static discovery never upgrades an inference to verified
isolation: unknown or conflicting write/test boundaries fall back to a single
writer and serial test execution. The map helps Codex avoid redundant
exploration and unsafe lanes; it does not command a fixed agent count.

`--apply` updates only a marker-delimited root `AGENTS.md` block, preserves all
other text, creates a timestamped adjacent backup when content changes, and is
idempotent. If static discovery finds existing AI instructions other than an
already-current baseline-only block, apply stops before mutation until their
reported paths have been reviewed and the explicit acknowledgement flag is
supplied (`-AcknowledgeExistingInstructions` on PowerShell). It snapshots and
hashes the preimage, rechecks it immediately before atomic replacement, and
fails closed on a concurrent edit or link/reparse change. Unix applies through
an anchored repository directory descriptor; Windows repeatedly checks native
directory identity and rejects apply paths whose ACL permits untrusted parent or
child deletion or whose owner is outside the caller/SYSTEM/Administrators/
TrustedInstaller boundary. Broad token groups are not trusted merely because
the caller belongs to them. Apply from a private repository path; on shared
volumes, use preview only until owner/ACL checks are satisfied. A failed Windows
replacement restores the verified in-memory preimage without trusting a corrupt
backup. Windows enumeration is lazy, so `MaxVisited` stops a high-fan-out
directory without first materializing all entries.

The generated block carries only allowlisted path strings for likely source
roots, architecture evidence, generated-file signals, risk-sensitive paths,
and the bounded parallelism map. Unsafe path names remain visible in structured
JSON but never become model instructions. Inferred commands and isolation
claims remain explicitly unexecuted/unverified.

Executed probes remain intentionally outside onboarding. Run a reviewed
command later in a disposable copy with least privilege, no credentials, and
network disabled unless genuinely required; record command, sandbox, exit, and
changed paths as evidence.
