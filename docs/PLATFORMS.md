# Platform status

Status vocabulary is fixed: `tested`, `partially tested`, `statically validated`,
`unsupported`, or `not verified`.

| Surface | Status for 0.2.0 | Evidence / boundary |
| --- | --- | --- |
| WSL2 Ubuntu 26.04 lifecycle | tested | The current v0.2.0 tree passes all 13 Unix groups from a private WSL filesystem copy with pinned ShellCheck 0.9.0 and Codex 0.147.0 test tools |
| Linux CLI implementation | partially tested | Executed under WSL2 Linux kernel/filesystem; shell/static behavior covered, separate bare-metal distro run absent |
| Native Windows PowerShell 5.1 lifecycle | tested | The current v0.2.0 tree passes 141 assertions under Windows PowerShell 5.1.26100.8875 from an atomically protected system-drive test root; production ancestor checks remain unchanged |
| Native Windows PowerShell 7 compatibility | tested | PowerShell 7.6.3 runs installed-wrapper update staging and rejects adversarial untrusted ACL mutation rights through the same native security checks; PowerShell 5.1 remains the minimum runtime |
| Native Windows onboarding/benchmark contract | tested | The current v0.2.0 tree passes all 69 native assertions under Windows PowerShell 5.1.26100.8875 |
| Native Windows Codex CLI | tested | Native Codex 0.147.0 is discovered; Doctor exercises stable capabilities and strict-config validation without reading authentication/session files |
| Codex CLI 0.147 prompt discovery | tested | `codex debug prompt-input` proved global, root, nested guidance and skill metadata |
| Linux/WSL evaluation isolation | tested | Static four-class verifiers plus deterministic fake-Codex paired, routing/behavior, and containment-Canary mechanics execute with private source/tool copies, aggregate user cgroups, bounded tmpfs storage, and Bubblewrap; all real-model receipts remain pending |
| Codex App / IDE discovery | partially tested | Official current contract supports AGENTS/skills; no full local cross-client execution probe |
| Codex App worktrees | partially tested | Native feature evaluated/documented; not required or executed by core |
| WSL1 | unsupported | Targeted Codex line no longer supports WSL1 |

PowerShell execution through WSL interoperability is real native Windows shell
execution but not evidence for native Windows Codex sandbox, app, or CLI behavior.
Release claims must keep that distinction.
