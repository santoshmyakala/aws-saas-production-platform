# Runbook: latency rises after a deployment

**The usual cause:** a new query without an index. It passes health checks, but under real load it holds connections longer, the pool saturates, and every request slows.

## Automatic protection
During the canary, any of these alarms rolls the deployment back without human action:
- `<prefix>-latency-p99`
- `<prefix>-db-connection-borrow-latency`
- `<prefix>-deploy-error-rate`

## If it got past the canary
1. **Compare** p99 by target group: the new revision is on the target group ECS shifted to.
2. **Roll back:** re-apply the previous image digest. The deployment is another canary, in reverse.
3. **Find the query:** Performance Insights → top SQL by wait, plus `log_min_duration_statement` entries (≥ 400 ms) in `/aws/rds/cluster/<cluster>/postgresql`.
4. **Fix forward safely:** add the index with `CREATE INDEX CONCURRENTLY` in a separate, backward-compatible migration before redeploying.

## Don't
- **Don't scale out the API.** More tasks mean more concurrent slow queries, and the database is the bottleneck.
- **Don't raise the pool size.** It moves the queue from the proxy into Aurora.
