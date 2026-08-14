# Security model

## Assets and trust boundaries

Protected assets are the user's Codex/config/auth state, unrelated skills and
instructions, repositories, credentials, and filesystem outside managed roots.
Trusted inputs are a reviewed baseline source and explicit lifecycle command.
Repository content, package scripts, existing AI prose, links/reparse points,
live files changed after planning, and network content are untrusted.

## Controls

- No network, package bootstrap, auth/session inspection, privilege escalation,
  hook installation, broad permission enablement, or project-code execution.
- Exact managed markers/prefixed targets and three-way hashes; conflicts fail
  closed rather than overwrite user work.
- Absolute root containment, segment link/reparse checks, literal paths, bounded
  inventory, sensitive-name exclusions, safe temporary naming, and `umask 077`
  on Unix.
- Transaction lock, durable pending journal, backup before replacement, staged
  same-parent moves, whole-file compare-and-swap for global guidance, hash
  revalidation, and deterministic recovery. Journal schema, object IDs, target
  roots, stage/old derivation, backup locations, hashes, and states are
  allowlisted and globally preflighted before the first recovery mutation.
- PowerShell strict mode, terminating errors, .NET UTF-8-no-BOM and flush APIs,
  `-LiteralPath`, raw local-drive validation, and Junction/reparse tests.
- Every installable source file is pinned by path, byte length, and SHA-256 plus
  an aggregate digest. Unsigned local source is labelled and requires explicit
  acknowledgement; Windows creates the verified snapshot under the local,
  reparse-free HOME rather than a potentially shared `%TEMP%`; HOME and every
  exchange-relevant ancestor reject untrusted owner/ACL mutation rights,
  with a protected child DACL owned by the caller and limited to caller/SYSTEM/
  Administrators. Parent owner/DACL plus child identity/owner/DACL, manifest,
  and every payload hash are checked again immediately before candidate
  construction.
- Onboarding apply requires explicit acknowledgement when existing AI
  instructions need reconciliation. Unix anchors discovery and mutation to an
  open repository directory; Windows combines native directory identity checks
  with a fail-closed owner/private-ACL requirement. A Windows repository whose
  ancestors grant mutation-capable rights to broad groups must be moved to a
  private location or have its ACL narrowed before apply; preview still works.
- Benchmark workspaces/homes are per-arm. Real Codex auth/session files are
  never read or mounted. Fixed `/bin/sh` enters fixed `/bin/bash -p`, suppressing
  `BASH_ENV`, inherited functions, PATH-selected interpreters, and inherited
  option variables before the trusted runner captures the dedicated input into
  a non-exported variable. Privileged mode is dropped immediately; it requests
  no OS privilege. The runner unsets credential variables and transfers two
  bounded lines through the final systemd service stdin pipe. There is no
  background credential writer. Key-touching scanners and system-boundary tools
  use fixed root-owned paths; mutable user Codex/Node executables are copied
  without reflinks, hashed before/after, and only the private frozen copies run.
  Live release evidence additionally requires the caller-pinned Codex SHA-256
  to match; the verified pinned hash is recorded without a contradictory second
  hash field.
  Tool shells exclude key variables and deny `/proc`/network. Workers and
  verifiers run in separate Bubblewrap namespaces under aggregate user-cgroup
  memory/swap/process/CPU/runtime limits; byte-bounded tmpfs mounts constrain
  mutable HOME/workspace storage. After Codex exits, the launcher stops and
  kills every other process in its private PID namespace before scanning or
  exporting mutable content. Bounded scans reject secret-bearing relative
  names, links, special/unreadable entries, excessive count/depth/bytes, and
  credential-shaped contents before host verification.
- The complete evaluated source is copied from a type-aware allowlist into a
  private snapshot, including empty directories and directory modes. Live and
  snapshot hashes are rechecked around every worker/verifier and before receipt
  completion; private verifier and frozen executable hashes are also rechecked.
  The live containment canary scans all numeric `/proc/*/environ` for a readable
  key carrier and uses only a preflighted loopback listener with host postflight
  and exact hit count; no external canary request is made.
- Paired task Git metadata is constructed outside the worker, mounted read-only,
  excluded from export, and hash-checked. Changed-path inspection runs host Git
  only inside a separate networkless cgroup/Bubblewrap sandbox with trusted
  metadata and local/system/global execution features disabled. Source
  provenance first freezes ordinary Git metadata, rejects local includes,
  hooks, filesystem monitors, clean/process filters, and executable diff
  drivers, then runs read-only against that snapshot in a separate networkless
  cgroup/Bubblewrap boundary. Transient services disable argument environment
  expansion so host-owned command strings arrive byte-for-byte. Installed
  operational checks have no Git metadata
  and explicitly report unversioned/null provenance while binding the exact
  reduced runtime tree through `source_hash`; they are not release evidence.

## Explicit limitations

The Unix directory-descriptor boundary and Windows identity/ACL checks detect
the tested rename/link races, but they are not a hostile concurrent-kernel or
administrator boundary. Administrators and SYSTEM are explicit Windows trust
principals. ACL, owner, ADS, xattrs, and every Windows attribute are outside
portable exact-restore scope. The source manifest proves layout/version consistency but
not publisher authenticity; public releases need signed immutable artifacts and
a documented trust root. The API key necessarily exists in trusted runner
memory, crosses a trusted service stdin pipe, and exists in the Codex parent
process environment during a live benchmark. Key-bearing processes disable core
dumps. A hostile same-user process, host, or admin
remains outside the local sandbox boundary. Public fixtures are learnable, so release
claims need rotated private holdouts or an external worker. The reviewer role is
not an authority boundary, hooks are absent because their coverage/failure
semantics are insufficient, and no prompt can replace OS sandboxing or user
authority.

## Security regression cases

The suites cover linked managed roots/Junctions, device/UNC/ADS roots, malformed
and path-tampered journals, corrupt recovery preimages, concurrent whole-file
guidance edits, untrusted package scripts that must never execute, sensitive
filenames, bounded traversal, onboarding apply races, dry-run null mutation,
managed drift, hard interruption/recovery, exact AGENTS restoration, path spaces
in risk fixtures, source-payload tampering, post-verify snapshot DACL/content
mutation, broad-group onboarding Delete rights, credential-boundary behavior,
and static shell analysis. Evaluation negatives additionally cover PATH
hijacking, key line breaks, last-arm source drift, executable/source snapshots,
malformed mode tuples/JSONL, readable key-carrier `/proc`, dead listeners,
forged commands, content/path-name leaks, and managed-runtime output rejection.
Before a release, independently review both installers
for injection, path handling, deletion scope, credentials, update provenance,
transaction ambiguity, and benchmark isolation.
