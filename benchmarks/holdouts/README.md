# Holdout policy

`risk-migration` and `risk-safe-path` are labelled `public-holdout` in the suite
manifest. Their worker workspaces contain only the task and starter files; the
verifiers remain host-side. These are regression holdouts, not secret tests: a
model or operator can learn every public fixture and verifier from this source.
A strong release run therefore rotates private holdouts or copies the worker
workspace into an external isolated worker that cannot mount this repository or
`benchmarks/verifiers`.

Local runs are labelled `os-sandboxed-local-cgroup`: the evaluated worker cannot
mount the live source or verifier, but this is not a hostile-host or private-test
boundary. An administrator or unrelated same-host process can inspect local
state. Results are useful development evidence, never proof against deliberate
gaming or memorisation.
