# Platform status

Status vocabulary is fixed: `tested`, `partially tested`, `statically validated`,
`unsupported`, or `not verified`.

| Surface | Status for 0.1.1 | Evidence / boundary |
| --- | --- | --- |
| WSL2 Ubuntu 26.04 lifecycle | tested | 12/12 Unix end-to-end groups, including real SIGKILL recovery, provenance, symlink/race boundaries, onboarding, benchmark/routing mechanics, worktree isolation, and discovery |
| Linux CLI implementation | partially tested | Executed under WSL2 Linux kernel/filesystem; shell/static behavior covered, separate bare-metal distro run absent |
| Native Windows PowerShell 5.1 lifecycle | tested | PowerShell 5.1.26100.8875 through WSL interop: 95 lifecycle assertions, including current/old/future-version probes, exact operations IDs, protected snapshot/ancestor DACL including direct HOME `DeleteChild` rejection, post-verify tampering, Junction, path/journal tampering, recovery, provenance, rollback/uninstall |
| Native Windows onboarding/benchmark contract | tested | 69 native assertions; lazy bounded discovery, owner and broad-group Delete/WRITE_DAC/WRITE_OWNER rejection, apply/conflict acknowledgement and static benchmark contracts execute; Bash verifier/live arms are explicitly not executed |
| Native Windows Codex CLI | not verified | Native Codex binary is not installed in this environment |
| Codex CLI 0.147 prompt discovery | tested | `codex debug prompt-input` proved global, root, nested guidance and skill metadata |
| Linux/WSL evaluation isolation | tested | Static four-class verifiers plus deterministic fake-Codex paired, routing/behavior, and containment-Canary mechanics execute with private source/tool copies, aggregate user cgroups, bounded tmpfs storage, and Bubblewrap; all real-model receipts remain pending |
| Codex App / IDE discovery | partially tested | Official current contract supports AGENTS/skills; no full local cross-client execution probe |
| Codex App worktrees | partially tested | Native feature evaluated/documented; not required or executed by core |
| WSL1 | unsupported | Targeted Codex line no longer supports WSL1 |

PowerShell execution through WSL interoperability is real native Windows shell
execution but not evidence for native Windows Codex sandbox, app, or CLI behavior.
Release claims must keep that distinction.
