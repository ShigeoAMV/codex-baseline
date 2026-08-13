Implement the feature-flag evaluator in `src/flags.js`, expand its tests, and
document its public API in `README.md`. `createEvaluator(definitions)` must
validate and snapshot all definitions at construction. A flag has a required
`default` scalar (`boolean`, string, or finite number), optional non-empty
ordered rules of `{when, value}`, and an optional non-empty rollout array of
`{percentage, value}`.

Rules use exact equality for every own key in their non-empty `when` object;
the first matching rule wins. All values for one flag must have the same type.
Rollout percentages are positive integers totalling exactly 100. When no rule
matches, rollout selection uses the first eight hex digits of SHA-256 over
`FLAG_NAME + ":" + context.subject`, interpreted as an unsigned 32-bit integer,
scaled to `[0, 100)`, and compared with cumulative percentages. Rollout
evaluation therefore requires a non-empty string `context.subject`. Without a
rollout, use the default.

`evaluate(name, context = {})` returns a frozen result containing `value` and
`source` (`rule`, `rollout`, or `default`), plus `ruleIndex` for a rule match or
`rolloutIndex` for rollout. `listFlags()` returns a frozen, sorted array of flag
names. Unknown flags, malformed definitions, malformed context, and invalid
rollouts must throw. Construction and evaluation must not mutate caller data,
and later caller mutation must not change results. Keep CommonJS, use only Node
standard modules, and limit changes to `src/flags.js`, `test/flags.test.js`, and
`README.md`.
