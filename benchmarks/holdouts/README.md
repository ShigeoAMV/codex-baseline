# Holdout policy

`risk-migration` is labelled as the release holdout in the suite manifest. Its
worker workspace contains only the task and starter files; the verifier remains
host-side. A strong release run copies the worker workspace into an external
isolated worker that cannot mount this repository or `benchmarks/verifiers`.

Local runs are always labelled `weak-isolation`: a sufficiently adversarial
process with host read access could discover the verifier. Results from that
mode are useful development evidence, never proof against deliberate gaming.
