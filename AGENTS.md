# Codex Baseline Repository

- Read `PLAN.md` and `docs/requirements/TRACEABILITY.md` before substantial work.
- Preserve the original mission; do not mark a gate verified without the exact
  evidence named in the traceability ledger.
- Treat installers, onboarding, updates, hooks, benchmark runners, and path
  handling as security-sensitive infrastructure.
- Use `apply_patch` for source edits. Keep generated build/results artifacts out
  of source unless explicitly documented.
- Run `./tests/run.sh` for the full local suite. Run
  `./tests/run-powershell.sh` when native Windows PowerShell is reachable.
- No network fetch is part of install, doctor, rollback, uninstall, offline/local
  update, or tests. Installed-runtime/explicit remote update may fetch only the
  bounded public release endpoints defined by the self-update contract.
- Do not read, copy, log, or test with real Codex authentication/session files.
