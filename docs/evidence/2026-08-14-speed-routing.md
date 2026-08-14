# Speed-routing candidate receipt - 2026-08-14

## Scope

Candidate branch `codex/speed-routing` narrows false escalation without changing
the HIGH-RISK axis. It distinguishes focused and broad read-only work, makes
file count and keywords insufficient escalation signals, caps unrequested LEAN
overhead, and excludes read-only architecture orientation from automatic
deep-work selection.

The managed global block is 2,751 bytes and 368 words, within the enforced
3,500-byte/500-word maximum. Canonical installable payload SHA-256:
`1b5f0203a5cec42bafabef03c289bb78fa00269e3326b351c9f436d8179cc5b7`.

## Executed evidence

- The isolated credential-free routing harness completed one deterministic
  repetition: 10/10 routing classifications and 4/4 host-verified behavior
  cases passed. The four new boundaries cover focused read-only diagnosis, a
  small two-file fix, broad read-only architecture analysis, and genuine
  multi-hour architecture implementation. This uses the repository Codex test
  double and proves runner/contracts, not probabilistic model behavior.
- `bash -n` passed for repository Bash entrypoints, libraries, verifiers,
  behavior scripts, the Codex test double, and `tests/run.sh`.
- `scripts/release-payload.sh` matched the manifest after canonical sorting;
  `scripts/check-docs.sh`, `scripts/research-check.sh --json`, routing-run schema
  validation, JSON assertions, and `git diff --check` passed.
- An isolated install reported 8/8 managed objects and 4/4 skills with the
  candidate payload hash; uninstall removed the dispatcher. Doctor reported
  exactly the pre-existing host mismatch: WSL Codex 0.145.0 is below the
  supported minimum 0.147.0.

## Explicitly unverified

- No real-model routing distribution, current-baseline/candidate elapsed-time,
  turn, command, or token comparison ran. It requires the dedicated short-lived
  benchmark key; normal Codex authentication/session files remain unsupported.
- `./tests/run.sh` stopped before its first test group because ShellCheck is not
  installed in WSL. No network install or test skip was used.
- Native PowerShell lifecycle and onboarding suites stopped because inherited
  `%LOCALAPPDATA%` ACLs grant FullControl to unresolved SID
  `S-1-5-21-2363829159-3772595814-2973517376-1002`. The installer correctly
  failed closed; the ACL was not changed.

This candidate therefore has focused deterministic evidence but is not a
release or measured performance claim.

## Combined v0.2.0 integration verification

The reviewed self-update work was frozen as commit `3fd9ce7`, then the routing
candidate was integrated semantically rather than by choosing whole conflicting
files. The combined canonical installable payload SHA-256 is
`d4dc8bf6a71a944fdd27ed94c210e6ec2e20107a6e5b8e3a111576d000b1c291`;
all 62 payload entries match the regenerated manifest.

- `CODEX_BASELINE_TEST_GROUP=routing ./tests/run.sh` passed from an isolated
  safe-mode WSL filesystem copy: 10 routing cases, four behavior cases, schema
  validation, frozen-source receipts, and fail-closed artifact mechanics.
- `CODEX_BASELINE_TEST_GROUP=self-update ./tests/run.sh` passed on the combined
  source, including byte-identical duplicate release builds and remote/offline
  archive, integrity, concurrency, rollback, and no-external-network cases.
- Bash and PowerShell syntax, Python compilation, all repository JSON,
  documentation links, research freshness, payload inventory/hash comparison,
  and `git diff --check` passed.
- The full Unix suite passes all 13 groups from a private WSL filesystem copy
  with pinned ShellCheck 0.9.0 and Codex 0.147.0 test tools. This includes the
  deterministic paired/Canary mechanics and real prompt-input discovery, but
  not a real-model paired performance run.
- The native Windows suites pass 134 lifecycle and 69 onboarding/benchmark
  assertions under Windows PowerShell 5.1.26100.8875. The bridge now supplies
  native module paths explicitly, and each suite atomically creates a protected
  system-drive test root; production ACL validation was not weakened.
