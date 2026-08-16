# Autonomous multi-agent acceleration v0.3

Status: implementation candidate
Frozen: 2026-08-15
Target source payload: `0.3.0`; release status: `rc.1`. A stable tag, stable
channel publication, and stable `0.3.0` claims require the live promotion
gates. The stable numeric payload version preserves direct update compatibility
with installed v0.2 clients, whose frozen parser rejects prerelease versions.

## Objective

Make Codex choose its own smallest effective execution team for every task. The
ordered objective is: preserve authority and safety; maximize correct complete
first-pass delivery; minimize wall-clock time; minimize repair/user turns; then
avoid unnecessary context, prose, code, comments, and files.

## Scope and non-goals

In scope: automatic `SOLO|TEAM|SWARM` routing with zero required per-task user
choice; fan-out and runtime receipts; task-specific child model routing; bounded
waves and write/test isolation; a key-owned Codex TOML optimizer; automatic
fresh-install ownership of an absent agent-cap key; static onboarding
parallelism hints; versioned operations/routing/behavior/benchmark contracts;
cross-platform lifecycle tests; and release-gated live evaluation.

Out of scope: changing the parent model, reasoning/Ultra, or session speed
without an explicit optimizer speed request; global child model/effort
defaults; model-catalog or `multi_agent_v2` patches; a fifth skill or duplicate
agent roles; unbounded Gauntlet loops; shared-workspace parallel writers;
reading Codex authentication/session files; claiming stable v0.3 or an automatic
speedup without live evidence.

## Constraints and authority

- Existing explicit agent disable/cap settings win. Fresh install may add only
  an absent `agents.max_concurrent_threads_per_session = 6` when agents are not
  disabled. This is the authorized v0.3 exception to zero config ownership.
- `optimize` is inspect-only unless `--apply`; `speed=keep` is the default.
- Managed TOML paths fail closed on invalid/ambiguous structures, links/reparse
  points, unsafe metadata, drift, or failed compare-and-swap validation.
- Journals contain only allowlisted paths, safe scalar/trivia bytes, and hashes,
  never a complete user config or secret material.
- Depth one is a policy until executable client evidence proves enforcement;
  unavailable telemetry is `unverified`, never inferred.
- The global block remains below 500 words and 3,500 bytes.
- Candidate installs remain production-SOLO. A trusted, non-installed overlay
  exercises AUTO only inside isolated evaluation. Autonomous global activation,
  stable publication/promotion, and claims remain blocked until live gates pass.
- The frozen eight-object operations/v1 core remains byte-contract compatible
  so a v0.2 updater can validate v0.3. Config ownership is the separately
  versioned `codex-baseline-config-operations/v2` plane under the same lifecycle
  lock; together they form the documented operations-v2 product contract.
- Automatic fresh-install cap ownership is retained. A durable composite intent
  precedes lifecycle mutation; core reaches its desired state before the
  allowlisted config delta is applied. Recovery either resumes that delta after
  a committed core change or retains the source config when core rolls back.
  Update never adds a cap that was not already Baseline-owned.
- Config metadata support is deliberately narrow: Windows preserves and
  verifies Owner plus DACL/protection, rejects reparse points, hard links and
  non-default ADS, and does not claim SACL preservation; Unix preserves mode
  and owner and rejects links or detected ACL/xattr state it cannot preserve.
  CAS detects cooperative edits immediately before and after replacement; it
  is not claimed as a hostile-writer or power-loss atomic primitive.

## Risks and recovery

The highest risks are corrupting user config, losing Windows ACL/DACL state,
overwriting independent user changes, recursive/duplicate fan-out, shared-write
conflicts, misleading model routing, and benchmark claims unsupported by live
telemetry. Config writes use candidate validation in an isolated `CODEX_HOME`,
pre-replace CAS, atomic replacement, allowlisted transaction state, and
key-level three-way restore. Rollback and uninstall restore only unchanged
baseline-owned values. Unsupported ACL/xattr/ADS/reparse cases stop before
mutation. A failed release gate leaves the stable v0.3 promotion blocked rather
than weakening the gate.

## Acceptance contract

| ID | Acceptance criterion | Required evidence |
| --- | --- | --- |
| A1 | Codex autonomously selects `SOLO=0`, `TEAM=1..3`, or `SWARM=4..6`; no task prompt is required | Global/deep-work contracts, routing schemas, raw forward tasks, repeated live routing |
| A2 | Six children are used only for six immediate independent lanes and runtime capacity; planned and actual fan-out differ honestly | Positive/negative routing fixtures, capacity/spawn-failure receipts |
| A3 | Parent owns requirements, integration, final gates, and user response; writes/tests parallelize only with verified isolation | Guidance plus worktree/cache/port/DB/fixture/generated-output tests |
| A4 | Parent model, reasoning/Ultra, and speed never change implicitly; child routing is capability-bound with one inherited fallback | Config snapshots, spawn fallback fixtures, doctor/receipt fields |
| A5 | Install manages only an absent agent-cap exception; optimizer supports check/apply/restore and explicit speed presets | Unix, PowerShell 5.1, and PowerShell 7 lifecycle matrices |
| A6 | TOML mutation preserves foreign bytes and supported metadata, fails closed on ambiguity/drift/links, and is crash recoverable without logging full config | Byte fixtures, crash phases, CAS races, native ACL/reparse tests |
| A7 | Onboarding emits bounded static parallelism hints labelled `declared|inferred|unknown` without executing repository code | Golden reports and malicious/no-exec fixtures |
| A8 | Contract v2 records lanes, fan-out, depth, waves, capacity, model truth, failures, isolation, conflicts, and handoff; missing truth is `unverified` | JSON Schema positive/negative tests and producers/consumers |
| A9 | Global/skill prompts and handoffs avoid repetition and code/output ballast | Size gates plus prompt/handoff/unnecessary-change metrics |
| A10 | Stable `0.3.0` and speed/quality claims remain blocked until the approved four-arm live suite passes | Dedicated-key receipts, paired statistics, promotion report |
| A11 | v0.2 to v0.3 update, rollback, and uninstall preserve independent user state | Cross-version Unix and native Windows transactions |
| A12 | Original mission remains traceable and fresh security, architecture, maintainability, and conformance reviews have no unresolved Critical/High issue | Updated ledger, exact test receipt, fresh review artifacts |

## Task graph and milestone

1. Freeze this contract, refresh official evidence, and disposition a fresh
   pre-implementation architecture/security critique.
2. Implement guidance, skill, research, schemas, onboarding hints, and static
   receipts.
3. Implement the shared semantic optimizer contract in native Bash and native
   PowerShell, then integrate install/update/rollback/uninstall.
4. Add deterministic and adversarial tests before broad documentation claims.
5. Run the full Unix suite and both native PowerShell suites; forward-test the
   changed skill with raw tasks.
6. Run fresh independent security, architecture/maintainability, and original-
   request conformance reviews; remediate only from new evidence.
7. Without a dedicated benchmark key, stop with the numeric `0.3.0` payload
   explicitly marked release candidate `rc.1`, live gates unverified, and no
   stable tag/channel publication. With a key, run the frozen four-arm live
   suite before stable promotion.

Current milestone: step 1. Dependencies: Codex 0.147.0 for local contract
checks; Bash/jq/Python/ShellCheck for Unix verification; Windows PowerShell 5.1
and PowerShell 7 for native verification; a dedicated short-lived API key only
for the final live gate. Current blocker: no dedicated benchmark key is
available, so stable promotion is not authorized.

Stopping conditions: unresolved config/metadata corruption risk; inability to
preserve explicit user authority; repeated no-new-evidence remediation; missing
native platform proof for a platform claim; or any attempt to satisfy a gate by
weakening its verifier.
