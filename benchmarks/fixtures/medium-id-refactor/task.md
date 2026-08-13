Refactor the duplicated identifier normalization in `src/user.js` and
`src/order.js` into a single `normalizeId` implementation in `src/ids.js`.
Both existing public APIs and behaviour must remain unchanged: identifiers are
strings, trimmed, uppercased, non-empty, at most 32 characters, and limited to
ASCII letters, digits, underscore, and hyphen. Make both modules consume the
shared function and add direct tests in `test/ids.test.js`. Do not modify the
existing domain test or add dependencies.
