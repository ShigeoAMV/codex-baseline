Fix the path-traversal and symlink-escape vulnerability in
`src/safe-path.js`, add adversarial tests, and update `SECURITY.md`.
`resolveExistingFile(root, requestPath)` handles an untrusted URL-style path.
It may accept zero or one leading slash, decodes each path segment exactly once,
and returns the canonical absolute path only for an existing regular file below
a canonical, non-symlink root directory.

Reject a non-absolute or symlink root; NUL, backslash, malformed percent escapes,
encoded slash or backslash, absolute/drive/UNC forms; empty, dot, or dot-dot
segments after decoding; and every symlink or non-directory ancestor. Reject a
symlink, directory, or non-regular leaf. Prefix siblings such as `/srv/app-old`
must never count as descendants. Throw before returning any unsafe path, do not
create or modify filesystem entries, and preserve the CommonJS API. Tests must
cover traversal plus ancestor and leaf symlinks. Document the validation and
the remaining lookup/open TOCTOU limitation with caller-side no-follow or
descriptor-based mitigation. Use only Node standard modules and modify only
`src/safe-path.js`, `test/safe-path.test.js`, and `SECURITY.md`.
