# ADR 0005: Warm standby for regional disasters

**Status:** accepted

| Strategy | RTO | RPO | Cost | Fit |
|---|---|---|---|---|
| Backup & restore | hours–days | hours | $ | No: misses both targets |
| Pilot light | tens of minutes–hours | minutes | $$ | Risky for a 60-minute RTO: everything must scale from zero |
| **Warm standby** | **minutes** | **seconds–minutes** | **$$$** | **Chosen** |
| Active-active | ~0 | ~0 | $$$$ | Needs multi-writer data design; not justified by a 60-minute RTO |

## Decision
- The standby region runs the full stack at minimum size: 3 API tasks, 1 worker and a two-instance Aurora secondary.
- Route 53 fails the **origin** over automatically when the primary ALB is unreachable or API capacity collapses. The standby then serves reads straight away.
- **Promoting the database for writes is a human decision**, made with on-call and an approver following the runbook. Automatic promotion risks split-brain and replicating the incident that caused the outage, such as a bad migration.

## Consequences
- Roughly 15–20% of the primary region's cost.
- Quarterly game days: AZ evacuation and a regional switchover. Each measures actual RTO and RPO against the targets.
