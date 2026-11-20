# ADR 0004: Canary deployments judged by SLO alarms

**Status:** accepted

## Context
A release can pass `/healthz` and still add a slow query that only hurts under real load. Health checks prove a task is up, not that the release is safe.

## Decision
- Images are referenced by **digest** only (validated in Terraform), so every deployment is immutable and can be reverted exactly.
- ECS's built-in **canary** sends 5% of traffic to the new revision for 10 minutes. The old revision stays warm for another 10 minutes after the full shift.
- Three alarms roll back automatically:
  - 5xx ratio above the fast-burn threshold;
  - p99 latency above 400 ms;
  - RDS Proxy borrow latency above 50 ms (connection pressure, the signature of a slow query).
- The circuit breaker rolls back revisions whose tasks never become healthy.
- `deployment_minimum_healthy_percent = 100` means a rollout never drops below the N+1 capacity floor.

## Why ECS-native rather than CodeDeploy
The origin-verify header check lives in an ALB **listener rule**. ECS's built-in strategy shifts listener-rule weights directly, while CodeDeploy manages listener default actions. It also removes a separate service and its IAM surface.
