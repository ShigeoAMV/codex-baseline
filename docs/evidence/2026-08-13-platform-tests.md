# Platform verification receipt - 2026-08-13

Source state at execution: commit
`4b0430cbb3328e40c7da837d72c770e9ac4d88b7`. Installable payload SHA-256:
`23c8a3dc7087fce163aa78ede49561a2ebbd9d542a4cab41160bce187f744c51`.
The tree was clean when the parallel platform reruns started.

## WSL2/Linux

- Host: Ubuntu 26.04 LTS under WSL2, Linux
  `6.18.33.2-microsoft-standard-WSL2`, x86_64.
- Codex CLI: `codex-cli 0.147.0`.
- Command: `./tests/run.sh`.
- Result: exit 0, 11/11 groups passed.
- Covered: syntax/ShellCheck, payload/operations contracts, context/path budgets,
  clean install, null dry-run, idempotence, exact rollback, preservation/drift,
  real SIGKILL recovery, corrupt/tampered/truncated journals, concurrent global
  guidance, symlink roots, bounded static onboarding, explicit instruction
  conflict acknowledgement, root-swap/concurrent apply, ten benchmark fixture
  contracts, paired runner mechanics, routing runner mechanics, documentation
  links, and real `codex debug prompt-input` discovery.

The Linux implementation was executed on a Linux kernel/filesystem through
WSL2. This is not a separate bare-metal/distribution matrix.

## Native Windows PowerShell

- Shell: Windows PowerShell `5.1.26100.8875`, invoked through WSL interop.
- Command: `./tests/run-powershell.sh` (dispatches the following two native
  PowerShell suites).
- Lifecycle subcommand: `powershell.exe -NoProfile -ExecutionPolicy Bypass
  -File "$(wslpath -w tests/windows/lifecycle.ps1)"`.
- Result: exit 0, 83 assertions passed.
- Onboarding/benchmark subcommand: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File
  "$(wslpath -w tests/windows/onboard-benchmark.ps1)"`.
- Result: exit 0, 58 assertions passed.

These are real native Windows filesystem and PowerShell executions. The
lifecycle suite includes a controlled native-Codex command test double for
minimum-version, strict-config, and stable feature parsing. The real native
Windows Codex executable is absent, so its sandbox, prompt discovery, and model
behavior remain not verified. Windows benchmark evidence is static contract
validation; it explicitly executes neither Bash verifier nor model.

## Research freshness

- Command: `scripts/research-check.sh --json`.
- Result: exit 0, `current`, 12 pinned sources, `network_access:false`.
- Review-by: 2026-11-11.
