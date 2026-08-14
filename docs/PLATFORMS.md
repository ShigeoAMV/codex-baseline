# Platform status

Status vocabulary is fixed: `tested`, `partially tested`, `statically validated`,
`unsupported`, or `not verified`.

| Surface | Status for 0.2.0 | Evidence / boundary |
| --- | --- | --- |
| WSL2 Ubuntu 26.04 lifecycle | partially tested | The inherited v0.1.1 tree passed 12/12 Unix groups. The v0.2.0 focused self-update/adversarial group passes, but the current full rerun is blocked by absent ShellCheck and host Codex 0.145.0 below the required 0.147.0 |
| Linux CLI implementation | partially tested | Executed under WSL2 Linux kernel/filesystem; shell/static behavior covered, separate bare-metal distro run absent |
| Native Windows PowerShell 5.1 lifecycle | partially tested | The inherited v0.1.1 tree passed 95 native assertions. v0.2.0 parses under PowerShell 5.1 and has new installed-wrapper/adversarial fixtures, but the current suite correctly stops because `%LOCALAPPDATA%` inherits foreign-SID FullControl |
| Native Windows onboarding/benchmark contract | partially tested | The inherited v0.1.1 tree passed 69 native assertions; the current v0.2.0 full native rerun is blocked at the shared lifecycle staging precondition before this group executes |
| Native Windows Codex CLI | not verified | Native Codex binary is not installed in this environment |
| Codex CLI 0.147 prompt discovery | tested | `codex debug prompt-input` proved global, root, nested guidance and skill metadata |
| Linux/WSL evaluation isolation | tested | Static four-class verifiers plus deterministic fake-Codex paired, routing/behavior, and containment-Canary mechanics execute with private source/tool copies, aggregate user cgroups, bounded tmpfs storage, and Bubblewrap; all real-model receipts remain pending |
| Codex App / IDE discovery | partially tested | Official current contract supports AGENTS/skills; no full local cross-client execution probe |
| Codex App worktrees | partially tested | Native feature evaluated/documented; not required or executed by core |
| WSL1 | unsupported | Targeted Codex line no longer supports WSL1 |

PowerShell execution through WSL interoperability is real native Windows shell
execution but not evidence for native Windows Codex sandbox, app, or CLI behavior.
Release claims must keep that distinction.
