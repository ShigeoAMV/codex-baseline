# Architecture

## Outcome

The repository is the single source of truth. Installation composes current
native Codex features with a deliberately small managed layer:

```text
reviewed source checkout
|-- one global AGENTS marker block       -> universal invariants/router
|-- four standalone user skills          -> progressive workflow detail
|-- one custom reviewer role             -> fresh advisory perspective
|-- Bash + PowerShell lifecycle           -> deploy/doctor/recover
|-- hashed payload + operations contract  -> provenance/platform parity
|-- static onboarding collector           -> repo-specific facts
`-- codex exec JSONL benchmark            -> paired evaluation

Codex native: config precedence, permissions/sandbox, Plan, Goal, Review,
              Subagents, skill discovery, project guidance, app worktrees
```

No framework, plugin, MCP server, hook, network fetch, daemon, database, Node,
Python, Docker, or administrator privilege is an installation dependency. Bash
is the Linux/WSL runtime; Windows PowerShell 5.1 is the native Windows runtime.
`jq`, Node, Git, Bubblewrap, `timeout`, and `prlimit` are Linux/WSL benchmark-only
dependencies; the PowerShell benchmark command performs native static contract
validation without pretending to execute Bash verifiers or live model arms.

The source manifest is not a loose file list: both installers require the exact
path inventory, byte lengths, file hashes, aggregate canonical payload digest,
encoding/version metadata, and shared eight-object operations contract before
install/update planning. The source is explicitly `unsigned-local-source`, its
origin/revision/dirty state and payload hash are printed, and mutation requires
acknowledgement. After verification, installers copy the exact payload into a
private temporary snapshot, reverify it, and build every candidate only from
that frozen snapshot, closing the verify-to-use window in a mutable checkout.
Publisher authenticity remains a release-distribution concern.

## Ownership and precedence

The baseline owns only its exact marker block and uniquely prefixed targets. It
owns no arbitrary `AGENTS.md` bytes, user config key, auth state, unrelated
skill, hook, plugin, repository config, or project command. Native root-to-leaf
project `AGENTS.md` discovery refines the global block; closer repository rules
win when they conflict within Codex's normal instruction hierarchy.

Each live object records `previous`, `installed`, and `desired` hashes. Update,
rollback, and uninstall proceed only when the live managed hash equals the
recorded installed hash. For the global block, edits outside the markers are
user-owned and survive; exact whole-file restoration is used when no intervening
user edit exists.

## Transaction protocol

One exclusive state lock protects mutation. A transaction records parent,
version, operation, target/root/kind, existence, previous hash/backup, desired
hash, installed hash, and per-object state.

```text
planned -> prepared -> committing -> committed
                 \-> recovering -> rolled-back
```

The pending pointer is durable before preparation. Candidates are staged beside
their destinations, checked, and revalidated immediately before move. A hard
process interruption leaves the journal, old/stage paths, and pending pointer;
the next live mutation validates the complete journal and every recovery
preimage before the first rollback mutation. Target/root, stage/old derivation,
backup sources, hashes, object IDs/kinds/states, and transaction fields are
allowlisted. Tests inject a `SIGKILL` mid-commit on Unix and a commit fault on
PowerShell, corrupt preimages, tamper journal targets, and race whole-file global
guidance changes.

Portable exactness covers bytes, existence/kind, executable/mode bits preserved
by the platform copy operation (including Unix tree-root mode), and
UTF-8-no-BOM for generated Windows state. It does not claim preservation of
owners, ACLs, ADS, or arbitrary extended attributes. Reparse/symlink paths fail
closed.

## Workflow policy

Routing is a transparent, probabilistic instruction policy, not a deterministic
classifier. HIGH RISK overrides task size. User selection wins unless it would
weaken a required safety boundary. Skills contain deeper procedure only for
onboarding, complex durable work, original-request conformance, and repeated
failure retrospectives. Routine LEAN/STRICT work uses native behavior.

Subagents are justified by independent breadth, isolated implementation, or a
fresh review. Delegation includes scope, ownership/read-only status, output,
deadline, and receipt. Writable parallel work requires separate worktrees. The
reviewer TOML is advisory. v0.1.0 ships no automated isolated review runner;
fresh review artifacts must record the actual external sandbox and otherwise
use the label `advisory review`.

## Verification and learning

Executable results outrank static inspection, independent review, and builder
self-assessment. Substantial tasks freeze observable criteria and end with a
receipt mapping each criterion to evidence. The retrospective changes the lowest
reliable layer: product/test/static rule before repo guidance, focused skill,
and only then a bounded hook. No model verdict edits global policy automatically.

Paired live evaluation places each model arm in a fresh Bubblewrap filesystem
without source/verifier access; the Codex permission profile denies tool network
and credential inheritance while the parent transport reaches the API. A
separate networkless, resource-bounded Bubblewrap process runs the verifier after
worker exit. This is `os-sandboxed-local`, not a hostile-host or private-holdout
claim.

The architecture decisions, rejected mechanisms, and evidence are normative in
[`docs/research/DECISIONS.md`](research/DECISIONS.md). Volatile product facts
remain in dated research records and a machine-readable review-by date rather
than in universal instructions.
