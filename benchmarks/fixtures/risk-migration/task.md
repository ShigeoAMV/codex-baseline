Harden `migrate.sh` for a rollback-sensitive local data migration. Default mode
must be a no-write dry-run. `--apply SOURCE TARGET` may replace only a regular
TARGET file, must reject symlinks and non-files, create an exact adjacent backup
before replacement, keep paths with spaces safe, and leave TARGET unchanged on
validation failure. `--rollback TARGET BACKUP` must restore exactly from a
regular backup with the same path protections. Use Bash only and document the
exit behavior in `USAGE.md`. Do not access the network or delete backups.
