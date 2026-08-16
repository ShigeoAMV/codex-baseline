# App-server orchestration telemetry for v0.3 rc.2

Status: contract frozen for implementation
Frozen: 2026-08-16
Base: `v0.3.0-rc.1` / commit
`f29265abdd900cbc82ec350d4f6fcfd79ad9e2d5`

## Objective

Replace the false product-level blocker “Codex orchestration telemetry is
unavailable” with an executable, version-bound adapter over the documented
Codex app-server stdio protocol. Produce authoritative orchestration and token
receipts for the existing four-arm benchmark without reading Codex auth or
persisted session files. Use the resulting evidence to decide whether a later
release candidate may enable autonomous `SOLO|TEAM|SWARM`; do not pre-approve
that activation or any speed claim.

## Scope

In scope:

- a pinned app-server JSONL client for one fresh ephemeral root thread per arm;
- host-derived parent/child graphs from collab tool items and thread lifecycle
  notifications;
- requested and observed model, effort, service tier, depth, waves, peak
  concurrency, terminal state, spawn failures, retries, interrupts, and token
  totals where the exact Codex 0.147 protocol supplies them;
- a closed, hash-bound telemetry receipt consumed by the existing benchmark
  result and summary contracts;
- deterministic protocol fixtures, replay/tamper negatives, and a bounded live
  capability probe;
- corrected research, benchmark, traceability, and release documentation.

Out of scope:

- reading, copying, parsing, or logging real Codex authentication or persisted
  session files;
- enabling stable AUTO merely because the adapter exists;
- estimating absent child facts from prompts, process counts, or model prose;
- WebSocket transport, remote listeners, experimental model-catalog hacks, or
  `multi_agent_v2`;
- changing parent model, reasoning, speed, sandbox, or user authority;
- manufacturing an independent publisher attestation inside the same runner.

## Authoritative inputs and dependencies

- Official OpenAI Subagents documentation, observed 2026-08-16: project and
  skill instructions may request delegation; subagent activity is surfaced by
  current clients.
- Official Codex App Server documentation, observed 2026-08-16: stdio is JSONL;
  app-server streams thread, turn, item, model reroute, and per-thread token
  usage events.
- Exact generated schema from `codex-cli 0.147.0`: collab agent tool calls
  expose sender/receiver IDs, requested model/effort and agent states; spawned
  threads expose parent/depth; thread settings expose observed model/effort;
  item events carry lifecycle timestamps.
- Runtime dependencies remain the already-required pinned Codex binary, Node,
  Bash, jq, Bubblewrap/cgroup boundary, and the dedicated benchmark API key for
  a full live suite. Schema generation is a capability probe, not a build-time
  network fetch.

## Constraints and security boundary

- Launch only the caller-pinned ordinary Codex binary, verify its SHA-256 and
  version before and after the run, and use stdio rather than a network
  listener.
- Use a fresh isolated `CODEX_HOME` and ephemeral thread. Authentication may be
  supplied only by the existing dedicated benchmark-key channel; the adapter
  must not discover or open auth/session files.
- Persist only allowlisted numeric/enumerated facts, IDs hashed with a run salt,
  binary/schema/input hashes, and terminal error classes. Do not persist raw
  prompts, agent messages, command output, environment values, or thread logs.
- Treat requested model/effort separately from observed thread settings and
  model-reroute events. Missing observed settings remain `unverified`.
- Derive depth from the parent graph and fail on cycles, duplicate IDs,
  disconnected children, depth greater than one, or a child that spawns a
  descendant.
- Derive waves and peak concurrency only from host-received lifecycle times and
  active intervals. Missing or contradictory boundaries remain `unverified` or
  fail closed; they are never guessed.
- Per-thread token totals use the final monotonic `thread/tokenUsage/updated`
  total. Reject decreasing counters, duplicate terminal totals with different
  values, and aggregate mismatches.
- The adapter cannot attest its own trustworthiness. Promotion still requires
  an independently distributed runner-attestation trust root or equivalent
  externally verified CI provenance.

## Risks, rollback, and recovery

Primary risks are protocol drift, subscribing only to the parent while missing
child events, confusing requested with actual settings, double-counting token
updates, leaking prompts in receipts, hanging on server-initiated requests, and
turning an experimental field into a stable product promise.

The new path is additive and capability-gated. If schema or live probes fail,
the benchmark returns the existing structured `unavailable` result and keeps
production execution SOLO. Rollback is removal of the adapter registration and
runner path; no user config or installed state is mutated. The app-server child
process is bounded, interrupted on deadline, and killed with its process tree
before temporary state is removed.

## Acceptance criteria and proof

| ID | Observable criterion | Required proof |
| --- | --- | --- |
| T1 | Exact Codex 0.147 schema contains the required stable/accepted event fields | Generated-schema validator plus missing/changed-field negatives |
| T2 | One root and N children produce an acyclic parent graph with exact actual fan-out/depth | Protocol fixtures and a controlled live subagent probe |
| T3 | Requested and observed child model/effort remain distinct and reroutes are preserved | Fixture matrix plus live receipt where available |
| T4 | Start/end intervals yield exact waves and peak concurrency without inference | Deterministic timestamp fixtures, overlap/boundary/contradiction tests |
| T5 | Final per-thread token totals are monotonic and sum exactly once | Duplicate/decrease/mismatch fixtures and live token events |
| T6 | Receipt contains no prompt, message, command output, environment value, auth, or session bytes | Closed schema, secret canaries, byte scan |
| T7 | Adapter replay, extra fields, wrong run/thread/config/schema/binary hashes, cycles and forged child IDs fail closed | Adversarial adapter boundary suite |
| T8 | Benchmark can distinguish unavailable, partial, and verified telemetry without weakening existing gates | Four-arm deterministic runner tests and summary tests |
| T9 | Parent settings before/after are byte- and event-equivalent | App-server thread settings receipts plus existing config snapshots |
| T10 | Failure/timeout leaves no app-server process, listener, workspace mutation, or persisted session | Fault injection and quiescence tests |
| T11 | Full Unix and native Windows suites pass; fresh conformance review reports no unresolved Critical/High | Exact command receipts and review artifact |
| T12 | AUTO activation remains blocked unless the original live quality/speed gates and external attestation gate pass | Release/promotion negative tests |

## Design challenge and dispositions

- **Child subscriptions may be incomplete.** Do not assume parent subscription
  covers descendants. Correlate collab items with `thread/started`, explicitly
  subscribe/resume only through documented methods if needed, and require a live
  proof before marking T2-T5 verified.
- **Requested is not actual.** A spawn item alone cannot prove model/effort.
  Require thread settings or reroute evidence; otherwise emit `unverified`.
- **App-server schemas are version-specific.** Bind the generated schema hash
  and Codex binary hash to every receipt and fail closed on drift.
- **The rich protocol does not create independent trust.** Keep release
  promotion unavailable until external CI/publisher provenance exists.
- **A live probe costs tokens.** Run only one bounded capability probe during
  development; the ten-repetition four-arm suite still needs the dedicated
  benchmark credential and explicit release work.

## Task graph and milestone

1. Freeze this contract and capture exact protocol/schema facts.
2. Add fail-first schema and event-stream fixtures.
3. Implement a pure receipt reducer with no Codex dependency.
4. Implement the bounded stdio app-server host and integrate it into one
   benchmark arm behind explicit capability selection.
5. Run one controlled live child probe; disposition missing events without
   weakening truth semantics.
6. Integrate all four arms, capability registration, summary and promotion
   gates.
7. Run focused security tests, complete Unix/native Windows suites, then fresh
   conformance review.

Current milestone: step 2. No implementation claim is accepted until the
fail-first fixtures demonstrate the old `exec --json` path cannot satisfy T2-T5
and the new reducer rejects malformed evidence.

Stopping conditions: required child events are not delivered to the controlling
stdio connection; actual settings remain unobservable and the frozen gates
cannot honestly classify them; a receipt would need raw session/auth data; a
new path weakens user authority or containment; or two remediation attempts add
no new executable evidence.
