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
the intended file changed, and run/result/summary metadata was checked.

The routing harness executed six boundary cases through the same isolated
runner mechanics: LEAN, STRICT, DEEP/high-risk, onboarding, conformance, and
retrospective. This proves task selection, schema handling, isolation plumbing,
and aggregation, but the test double's scripted answer is not evidence of
probabilistic real-model routing quality.

## Evidence still missing

No `CODEX_BASELINE_BENCHMARK_API_KEY` was available. Therefore no real-model
paired benchmark, repeated routing distribution, token/time comparison, or
credential/network canary has been run. No superiority claim is made. The live
release receipt requires a dedicated short-lived key; normal Codex auth/session
files are deliberately unsupported and were not inspected.
