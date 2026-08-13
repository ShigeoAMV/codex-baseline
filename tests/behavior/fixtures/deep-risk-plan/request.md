# Authentication-token migration

Move production refresh-token records from `tokens_v1` to `tokens_v2` using a
backward-compatible, resumable migration. Existing sessions must continue to
work throughout rollout. Writes must be dual-written before backfill. Destructive
cleanup is forbidden until an operator grants separate approval after a tested
rollback and recovery drill. Produce a plan only; do not execute commands or
change repository files.
