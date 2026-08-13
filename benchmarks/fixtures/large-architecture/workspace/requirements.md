# Event intake service

- Accept up to 2,000 JSON events/second over HTTPS.
- Preserve accepted events through a 30-minute downstream outage.
- Reject invalid tenant IDs before durable storage.
- Prevent one tenant from exhausting all capacity.
- Deliver at least once to an existing HTTP processor; duplicates are allowed
  and must carry a stable event ID.
- Operators need per-tenant backlog, age, rejection, retry, and dead-letter
  metrics without exposing payloads.
- Deploy on Linux with MySQL already available. Adding a durable queue requires
  an explicit operational-cost justification.
- A rollout must be reversible without losing events already accepted.
