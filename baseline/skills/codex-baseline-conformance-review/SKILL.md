---
name: codex-baseline-conformance-review
description: Independently audit a substantial implementation, plan, migration, or release against the original user request and frozen acceptance criteria using the actual diff or artifact and verification evidence. Use after meaningful STRICT or DEEP work, before declaring a large goal complete, or when asked for requirement conformance. Do not trigger for ordinary small edits, generic code review without original requirements, or as a substitute for executable tests.
---

# Codex Baseline Conformance Review

Review from evidence, not the builder's narrative. If isolation is not enforced,
label the result `advisory review` rather than `isolated review`.

## Required inputs

Obtain all of:

- original request, not merely the latest plan;
- frozen acceptance criteria and authorized changes;
- relevant specification and non-goals;
- actual diff, files, runtime artifact, or deployment state;
- exact verification receipt with commands, exits, scope, and omissions.

Missing input is a finding. Do not reconstruct it from intent.

## Review order

1. Map every explicit requirement, deliverable, named command, invariant, and
   platform claim to authoritative current evidence.
2. Inspect the artifact/diff for functional errors, missed requirements,
   regressions, unsafe assumptions, weak or implementation-coupled tests,
   unnecessary changes, security issues, and maintainability risk.
3. Prefer executable counterexamples. Never rerun mutating commands in a
   read-only reviewer; request a host-side verifier where necessary.
4. Check claimed test scope against actual command/config coverage. A green
   narrow test cannot prove a broad claim.
5. Classify every requirement as `delivered`, `partial`, `missing`, `drifted`,
   `unauthorized`, or `not applicable` with justification.

## Output

Report findings first by `CRITICAL`, `HIGH`, `MEDIUM`, `LOW`, each with evidence,
impact, and smallest corrective action. Then provide the requirement matrix,
verification gaps, and verdict: `accept`, `accept-with-changes`, or `reject`.
Do not praise, edit, or silently narrow the completion standard.
