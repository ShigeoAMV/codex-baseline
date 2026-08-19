# Platform status

Status vocabulary is fixed: `tested`, `partially tested`, `statically validated`,
`unsupported`, or `not verified`.

The table below is the `0.3.0` payload / `rc.1` candidate receipt from
2026-08-16. Its four-arm real-model autonomous evaluation is `not verified`:
the current Codex JSONL contract lacks required authoritative orchestration
telemetry and no independent runner-attestation trust root exists. A dedicated
benchmark key alone is insufficient; stable promotion and speed claims remain
blocked.

| Surface | Status for 0.3.0-rc.1 | Evidence / boundary |
| --- | --- | --- |
| WSL2 lifecycle | tested | A private-ext4 candidate snapshot passes all 15 Unix groups with pinned ShellCheck 0.9.0 and the repository test tools; the final lifecycle-provenance delta passes the focused lifecycle group, including a hostile-Git non-execution test; config tests include real ACL/xattr and hard-crash convergence |
| Linux CLI implementation | partially tested | Executed under the WSL2 Linux kernel and ext4 filesystem; separate bare-metal distro coverage remains absent |
| Native Windows PowerShell 5.1 lifecycle | tested | The current candidate passes 625 lifecycle assertions under Windows PowerShell 5.1.26100.8875, including embedded PowerShell 7.6.3 cases. Coverage includes OS-volume private staging, direct and inherit-only ACL attacks, identity-bound cleanup, exact Owner/DACL protection, restrictive config staging, ADS/reparse, TOML, composite recovery, and release boundaries |
| Native Windows PowerShell 7 compatibility | tested | The lifecycle matrix invokes PowerShell 7.6.3 for optimizer/config, quoted-key/veto, protected/unprotected DACL, recovery, and metadata-tamper cases; PowerShell 5.1 remains the minimum runtime |
| Native Windows onboarding/benchmark contract | tested | The final payload passes 79 native onboarding/benchmark assertions under Windows PowerShell 5.1.26100.8875 |
| Native Windows Codex CLI | tested | Native Codex 0.147.0 is discovered; Doctor exercises stable capabilities and strict-config validation without reading authentication/session files |
| Native Windows desktop-app-only | tested | Doctor recognizes the healthy AppX package when no executable CLI is available; installation deploys guidance, skills, reviewer, and runtime while skipping unvalidated optional config ownership |
| Codex CLI 0.147 prompt discovery | tested | `codex debug prompt-input` proved global, root, nested guidance and skill metadata |
| Linux/WSL evaluation isolation | tested | Six positive/four serial benchmark fixtures plus deterministic four-arm, 16-case routing/four-case behavior, host-receipt, and containment-Canary mechanics execute with private source/tool copies, aggregate user cgroups, bounded tmpfs, and Bubblewrap; all real-model receipts remain pending |
| Codex App / IDE discovery | partially tested | Official current contract supports AGENTS/skills; no full local cross-client execution probe |
| Codex App worktrees | partially tested | Native feature evaluated/documented; not required or executed by core |
| WSL1 | unsupported | Targeted Codex line no longer supports WSL1 |

PowerShell execution through WSL interoperability is real native Windows shell
execution but not evidence for native Windows Codex sandbox, app, or CLI behavior.
Release claims must keep that distinction.
