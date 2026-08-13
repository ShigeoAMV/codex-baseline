# Frozen criteria

- C1: `GET /hello` returns HTTP 200 with `{"message":"hello"}` and an integration test passes.
- C2: a rollback drill restores the exact pre-deployment hash and its receipt is attached.
