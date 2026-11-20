# Runbook: one Availability Zone is impaired

**Expected impact:** none to brief elevated latency. Capacity is sized N+1, so two AZs carry peak traffic.

## Signals
- ALB `UnHealthyHostCount` rising in one AZ; tasks in one subnet failing to start.
- `<prefix>-nat-<az>-port-allocation` alarm, or third-party calls failing only from one AZ.
- Aurora failover event if the writer was in that AZ.

## Steps
1. **Confirm it's zonal:** AWS Health Dashboard, and errors grouped by AZ in the dashboard and logs.
2. **Shift capacity away:** use ALB zonal shift (Application Recovery Controller) on the load balancer for the impaired AZ. ECS AZ rebalancing places replacement tasks in healthy AZs.
3. **Check the floor:** at least 16 API tasks must be running in the remaining AZs (2/3 of 24). Autoscaling adds more if RPS per task is above target.
4. **Database:** if the writer moved, check `DatabaseConnectionsBorrowLatency` has recovered (RDS Proxy reconnects automatically).
5. **Egress:** each AZ uses its own NAT, so no route change is needed. If NAT in a healthy AZ shows port-allocation errors, check whether connection reuse broke (a new client per request).

## Verify
```bash
aws elbv2 describe-target-health --target-group-arn <blue-or-green-tg> \
  --query 'TargetHealthDescriptions[].[Target.AvailabilityZone,TargetHealth.State]' --output text | sort | uniq -c
```
```bash
# from a task in each healthy AZ (debug task, not ECS Exec on production services)
curl -sS -o /dev/null -w '%{http_code}\n' https://api.github.com
```

End the zonal shift when the AZ is healthy. Record actual impact against the error budget.
