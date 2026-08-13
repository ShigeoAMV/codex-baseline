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
  never read or mounted. A dedicated key reaches only the Codex parent; tool
  shells exclude key variables and deny `/proc`/network. Workers and verifiers
  run in separate Bubblewrap namespaces, with verifier network/resource limits.

## Explicit limitations

The Unix directory-descriptor boundary and Windows identity/ACL checks detect
the tested rename/link races, but they are not a hostile concurrent-kernel or
administrator boundary. Administrators and SYSTEM are explicit Windows trust
principals. ACL, owner, ADS, xattrs, and every Windows attribute are outside
portable exact-restore scope. The source manifest proves layout/version consistency but
not publisher authenticity; public releases need signed immutable artifacts and
a documented trust root. The API key necessarily exists in the Codex parent
process environment during a live benchmark, and a hostile host/admin remains
outside the local sandbox boundary. Public fixtures are learnable, so release
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
and static shell analysis. Before a release, independently review both installers
for injection, path handling, deletion scope, credentials, update provenance,
transaction ambiguity, and benchmark isolation.
