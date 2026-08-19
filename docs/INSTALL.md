# Installation and platform guide

## Before installation

Use a reviewed, immutable release or trusted checkout. The installer validates
the exact installable path inventory, byte lengths, per-file SHA-256 values,
aggregate payload hash, operations contract, and version. It prints the local
origin, an intentionally unavailable revision/dirty state, and the
`unsigned-local-source` trust label. Lifecycle commands never query checkout
Git metadata because repository-local filters and helpers are untrusted. The
`0.3.0` payload / `rc.1` candidate does
not authenticate a publisher or verify a release signature, so mutation
requires an explicit acknowledgement. It is not a stable channel release;
stable promotion and performance claims remain blocked until the documented
live gates pass.
Installation never performs `git pull`, package installation, or any network
request. Network access is confined to an explicit/installed-runtime remote
`update`; local and offline update remain networkless.

Backups are part of the transaction. A preview is still recommended:

```bash
git status --short
./scripts/codex-baseline.sh install --dry-run
./scripts/codex-baseline.sh install --acknowledge-unverified-source
```

## Linux

Requires Bash, coreutils (`find`, `realpath`, `stat`, `sort`, SHA-256 tool),
`iconv`, `getfacl` (normally package `acl`), `getfattr` (normally package
`attr`), and a supported Codex CLI. The ACL/xattr inspectors are mandatory for
an existing `config.toml`; mutation stops before touching state when either is
unavailable because metadata preservation cannot otherwise be proved. Remote
update additionally requires an ordinary `curl`
executable, `gzip`, and GNU tar; the command reports a missing capability and
stops before mutation. Local install/update does not require them. Run:

```bash
./scripts/codex-baseline.sh install --acknowledge-unverified-source
"${HOME}/.local/bin/codex-baseline" doctor
```

Add `$HOME/.local/bin` to `PATH` if your distribution does not already do so.

## WSL2

Use the Linux path above. Keep repositories under the WSL Linux filesystem for
performance and Unix semantics. WSL1 is unsupported by the targeted Codex
version. WSL `$HOME/.codex` and native Windows `%USERPROFILE%\.codex` are
separate unless the user explicitly chooses otherwise; sharing is discouraged
because their path, auth, sandbox, and executable semantics differ.

## Native Windows

PowerShell 5.1 is the minimum supported shell. No execution-policy change is
installed; invoke the reviewed local script explicitly:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\codex-baseline.ps1 install -DryRun
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\codex-baseline.ps1 install -AcknowledgeUnverifiedSource
& "$HOME\.local\bin\codex-baseline.ps1" doctor -Json
```

The script uses literal paths, .NET byte APIs, UTF-8 without BOM, reparse-point
checks, and an adjacent PowerShell wrapper. It does not assume a username or
drive. Either the separately installed Codex CLI or a healthy Codex desktop
AppX package is sufficient for Baseline installation; neither is fetched.
Desktop-app-only installation never depends on the app's private versioned
executable paths.

## Existing configuration

The installer chooses non-empty global `AGENTS.override.md` or `AGENTS.md` using
native priority. If both are non-empty, duplicate/malformed markers exist, a
prefixed target is unowned, or a managed target drifted, it stops. Resolve the
ambiguity manually; do not delete user data to make the installer proceed.

`CODEX_HOME` and `AGENTS_HOME` overrides are supported. The home directory,
Codex home, and agents home must be absolute safe non-root locations without a
symbolic/reparse path segment. Native Windows additionally rejects relative,
UNC/device, alternate-data-stream, and reparse-ancestor roots before
normalization. No installer reads, copies, or tests with Codex auth/session
files.

The installer does not change the parent model, reasoning/Ultra, speed,
provider, permission, MCP, hook, or global child-model settings. v0.3 has one
narrow automatic config exception: on a fresh install it may add an absent
`agents.max_concurrent_threads_per_session = 6` when agents are not explicitly
disabled and neither a current nor legacy cap exists. Existing settings always
win; `agents.enabled=false` and `features.multi_agent=false` both veto this
exception and remain user-owned. The exception also requires an executable CLI
for isolated strict-config validation. App-only installation skips the cap and
leaves `config.toml` user-owned. Update never acquires a cap it did not
previously own. Preview includes the
planned key change. Use `codex-baseline optimize --check` to inspect and
`optimize --restore --dry-run` to preview its key-level inverse.
