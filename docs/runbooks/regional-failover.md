# Runbook: regional failover to the warm standby

**Targets:** RTO 60 min, RPO 15 min. **Decision owner:** incident commander with approval from the service owner.

## 1. Automatic: traffic (minutes)
Route 53 marks the primary unhealthy when both of these fail together, within about a minute:
- its ALB stops answering `/__alb_alive`;
- the API capacity alarm fires.

CloudFront's origin then resolves to the standby, which serves **reads** at once. Writes fail until step 3.

## 2. Decide (≤ 15 min)
- Is the primary region really impaired (AWS Health), or is it our own release? **If it's our release, roll back instead and don't fail over.** Replication has already copied any bad data to the standby.
- Check `AuroraGlobalDBRPOLag` in the standby: the expected data loss is the current lag.

## 3. Promote the database (approved step)
If the primary region is still reachable, use **managed switchover** (no data loss):
```bash
aws rds switchover-global-cluster --global-cluster-identifier docflow-prod \
  --target-db-cluster-identifier arn:aws:rds:us-west-2:<acct>:cluster:docflow-prod-standby
```
If the primary region is down, use **managed failover**, accepting loss up to the replication lag:
```bash
aws rds failover-global-cluster --global-cluster-identifier docflow-prod \
  --target-db-cluster-identifier arn:aws:rds:us-west-2:<acct>:cluster:docflow-prod-standby --allow-data-loss
```

## 4. Scale the standby (≈ 5–10 min)
```bash
aws application-autoscaling register-scalable-target --region us-west-2 --service-namespace ecs \
  --resource-id service/docflow-prod-standby/api --scalable-dimension ecs:service:DesiredCount \
  --min-capacity 24 --max-capacity 90
```
Do the same for the worker (`--min-capacity 3`). Then confirm p99 and the error ratio on the standby dashboard.

## 5. Return to primary (planned, later)
1. Rebuild or repair the primary.
2. Let it rejoin the global cluster as the secondary.
3. Run a **switchover** back in a maintenance window.
4. Restore `min_capacity` in both regions with `terraform apply`. Terraform remains the source of truth.

## Rehearse
Run this quarterly as a game day, using switchover on staging. Record measured RTO and RPO.
