# ADR 0003: Aurora PostgreSQL behind RDS Proxy, as an Aurora Global Database

**Status:** accepted

## Decision
- **Aurora PostgreSQL**: a writer plus two readers in three AZs; failover in about 30–60 s; 14 days of point-in-time recovery.
- **RDS Proxy** in front, for three reasons:
  - It caps database connections at 80% of `max_connections`, whatever the task count. Without it, 90 tasks × 10 connections could exhaust the database during a scale-out.
  - It keeps client connections open during writer failover.
  - It requires TLS.
- **Global Database** to the DR region, with replication lag typically around a second, which is far inside the 15-minute RPO.
- **Credentials** are generated as an ephemeral value and written through write-only arguments, so the password is never stored in Terraform state. To rotate it, bump `db_secret_version`.

## Consequences
- Schema changes must be backward compatible (expand → deploy → migrate → contract). During a canary, old and new code run against the same schema.
- Replication copies destructive changes too. PITR, not the replica, is the recovery path for logical corruption.
