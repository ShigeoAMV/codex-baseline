# Platform verification receipt - 2026-08-13

Source state at execution: local uncommitted release-candidate tree. Installable
payload SHA-256: `2b5515ec4baa1f81938c459b198fa873cf294bb334e2fc7bbc5db5fcb5d0419b`.
The final immutable-revision rerun must supersede this receipt before release.

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
- Command: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File
  "$(wslpath -w tests/windows/lifecycle.ps1)"`.
- Result: exit 0, 83 assertions passed.
- Command: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File
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
