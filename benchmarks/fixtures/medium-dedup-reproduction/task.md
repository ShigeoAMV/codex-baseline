Reproduce and fix the concurrent request-deduplication bug in `src/dedup.js`.
Calls for the same key while a loader is pending must share one loader promise;
different keys remain independent. A fulfilled or rejected loader must be
removed without deleting a newer in-flight value for that key. Add focused
regression coverage to `test/dedup.test.js`, including concurrent calls and
retry after rejection. Preserve the CommonJS API and add no dependencies.
