# Installation and platform guide

## Before installation

Use a reviewed, immutable release or trusted checkout. The installer validates
the exact installable path inventory, byte lengths, per-file SHA-256 values,
aggregate payload hash, operations contract, and version. It prints the local
origin, Git revision/dirty state when safely available, and the
`unsigned-local-source` trust label. v0.1.0 does not authenticate a publisher or
verify a release signature, so mutation requires an explicit acknowledgement.
Installation never performs `git pull`, package installation, or any network
request.

Backups are part of the transaction. A preview is still recommended:

```bash
git status --short
./scripts/codex-baseline.sh install --dry-run
./scripts/codex-baseline.sh install --acknowledge-unverified-source
```

## Linux

Requires Bash, coreutils (`find`, `realpath`, `stat`, `sort`, SHA-256 tool), and
a supported Codex CLI. Run:

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
drive. Native Windows Codex must be installed separately and is not fetched.

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
