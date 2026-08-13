# Behavior and benchmark receipt - 2026-08-13

## Proven behavior

The final group of `./tests/run.sh` installed the release candidate into an
isolated home and executed `codex debug prompt-input` with Codex CLI 0.147.0.
Assertions proved that model-visible input contains:

- the managed global guidance block;
- root repository guidance;
- nested repository refinement;
- name/description metadata for all four installed skills.

The test does not infer loading from a model answer; it inspects Codex's rendered
prompt input. Skill body loading remains progressive and selection-dependent.

## Deterministic evaluation mechanics

Static benchmark validation executed all ten registered starter verifiers. Each
unchanged starter failed as required. The tasks cover three small, three medium,
two large, and two risk-sensitive cases. The full test also ran one paired
vanilla/baseline repetition through the real Bubblewrap runner using a
deterministic credential-free Codex test double; both isolated arms passed, only
the intended file changed, and run/result/summary metadata was checked against
the published Draft 2020-12 schemas. Private source/verifier/tool hashes are
checked before/after use, aggregate cgroup and mutable tmpfs bounds are active,
and final-arm drift leaves a running/INVALID receipt.

The routing harness executed six boundary cases through the isolated test-double
path and matched the expected LEAN, STRICT, DEEP/high-risk, onboarding,
conformance, and retrospective tuples. Four additional read-only cases exercised
DEEP/high-risk planning, research-first ambiguity, semantic onboarding, and
independent conformance against host-side verifiers; each unchanged starter
failed its verifier. The completed run receipt binds all results to one frozen
source hash, and source-drift, missing/linked output, worker-HOME credential
leakage, and special-file negatives fail closed. The real host-owned inspector,
semantic fixture facts, networkless behavior verifier, fresh HOME, final-source
recheck, and schema receipts are exercised. This proves runner, fixture,
verifier, and receipt mechanics, not probabilistic real-model routing, skill
activation, or behavior quality.

## Evidence still missing

No `CODEX_BASELINE_BENCHMARK_API_KEY` was available. Therefore no real-model
paired benchmark, repeated routing distribution, token/time comparison, or
credential/network canary has been run. No superiority claim is made. The live
release receipt requires a dedicated short-lived key; normal Codex auth/session
files are deliberately unsupported and were not inspected. The executable
`benchmark --canary` path and its deterministic exact-command positive plus
forged-marker, active-key, sentinel, mutable-HOME/workspace, link/special-entry,
and real-listener-hit negatives are covered locally, but that is not a
real-model containment result.
Additional deterministic negatives cover fixed-command forgery, readable
key-carrier `/proc`, listener death, credential-bearing filenames/directories,
key line breaks, PATH hijacking, exact listener hit counts, output inside the
managed runtime, and post-last-arm source invalidation.
