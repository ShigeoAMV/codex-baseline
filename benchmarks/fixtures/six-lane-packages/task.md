Six packages have frozen, mutually independent APIs and one localized defect
family each. Fix all six implementations against these contracts:

- `a.normalizeHeaders(entries)` lowercases names, trims values, joins duplicate
  values with `, `, and does not mutate the input.
- `b.retryDelays(baseMs, attempts, maxMs)` returns bounded exponential delays
  for every attempt and rejects invalid integers.
- `c.dedupeStable(values, keyOf)` keeps the first value for each derived key in
  stable order without mutating the input.
- `d.parseFeatureFlags(text)` parses trimmed `name=true|false` lines, ignores
  blank/comment lines, rejects malformed rows, and lets the last duplicate win.
- `e.partitionSettled(results)` preserves order while separating fulfilled
  values from rejected reasons, including falsy payloads.
- `f.joinUrl(base, path)` joins exactly one boundary slash without damaging a
  URL scheme, query string, or fragment.

Each package is an immediately runnable lane with disjoint files; do not change
APIs, add dependencies, or create files. The parent integrates and verifies.
