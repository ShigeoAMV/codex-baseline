# Current architecture

The API reads `tokens_v1`. A background worker owns migrations. Deployments use
three stages: canary, 25 percent, then full. Backups are restored in a disposable
environment by `ops/restore-check`; the migration verifier is
`ops/token-migration-check`. Security review is mandatory before canary rollout.
The product owner has already chosen a 30-day compatibility window, so no
product decision is missing for planning.
