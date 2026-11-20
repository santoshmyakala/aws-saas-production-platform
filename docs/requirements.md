# From requirements to architecture constraints

The platform serves **Docflow**, a fictional B2B SaaS product for document processing: an API, an admin portal, document processing in the background, and third-party integrations. Every design choice in this repository traces back to the requirements below.

## Requirements

| Requirement | Target | Why it matters |
|---|---|---|
| Daily requests | ~12 million | ≈ 140 RPS on average, but traffic is business-hours shaped |
| Peak traffic | 3,000 requests/second | Sizing input for every tier |
| Availability | 99.95% per 30 days | Error budget ≈ **21.6 minutes** of full outage, or 0.05% of requests |
| Latency | p99 ≤ 400 ms at the load balancer | Drives the per-hop budget in [request-path.md](request-path.md) |
| Recovery time (RTO) | 60 minutes for a regional disaster | Warm standby, not backup-and-restore |
| Recovery point (RPO) | 15 minutes | Continuous cross-region replication, not daily snapshots |

## What each requirement forces

| Requirement | Constraint on the design | Where it lives |
|---|---|---|
| 99.95% | No single point of failure inside a region. **Every AZ must work alone**: its own NAT gateway, tasks and a database instance | `modules/region/network.tf`, `data.tf` |
| 99.95% | Capacity for **N+1 AZs**: losing one AZ at peak must not overload the other two | `compute.tf` (`n_plus_one_tasks`), test `capacity_survives_one_az_loss` |
| 99.95% | Deployments are the most common cause of outages, so they must be **gradual and self-reverting** | ECS canary + alarm rollback, test `safe_deployments` |
| 3,000 RPS | Scale on the measured capacity unit (requests per task), not CPU | `aws_appautoscaling_policy.api_rps` |
| 3,000 RPS | Scaling the app must not exhaust the database | RDS Proxy pooling, borrow-latency alarm |
| p99 ≤ 400 ms | Slow work leaves the request path | SQS queue + worker; the API returns 202 |
| p99 ≤ 400 ms | Every hop has a timeout shorter than the caller's | 2 s request deadline, 5 s pool-borrow limit, 10 s CloudFront origin timeout |
| RTO 60 min | A running copy in a second region that can take traffic immediately | `module.standby`, Route 53 failover |
| RPO 15 min | Continuous replication with lag well under 15 min, and an alarm before it is at risk | Aurora Global Database, `global_rpo_lag` alarm |
| Security | Least privilege per workload, encryption everywhere, no path around the WAF | `security.tf`, test `edge_cannot_be_bypassed` |

## The numbers

**Error budget.** 30 days × 24 h × 60 min × 0.05% = 21.6 minutes. Spending it at 14.4× the allowed rate exhausts it in about two days, which justifies a page. At 6× it lasts five days and justifies a ticket. Those are the two burn-rate alarm pairs in `observability.tf`.

**API capacity.** Load testing sets `task_rps_capacity` (default 200 RPS per task at the p99 target):

```
tasks needed at peak            = 3000 / 200            = 15
survive the loss of 1 of 3 AZs  = 15 × 3 / 2            = 22.5 → 23
spread evenly across 3 AZs      = round up to multiple of 3 = 24  (8 per AZ)
```

Autoscaling tracks 70% of task capacity, adding headroom above that floor for bursts. `max_tasks` is a cost guardrail, not a capacity plan.

**Database connections.** 24–90 API tasks × 10 pooled connections = 240–900 client connections. RDS Proxy multiplexes them onto at most 80% of Aurora's `max_connections`. Adding tasks therefore can't cause a connection storm. Instead, pool saturation shows up as borrow latency and alarms.

**Queue.** The visibility timeout is 6 × the 30 s worker timeout. A slow worker therefore doesn't get its message redelivered to a second worker while it's still processing.
