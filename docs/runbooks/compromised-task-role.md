# Runbook: an ECS task role is compromised

## What an attacker can reach (by design)

| Role | Can | Cannot |
|---|---|---|
| `api` | `sqs:SendMessage` to the jobs queue; encrypt with the platform key; write traces and metrics in the `docflow` namespace | Read or delete jobs; read any secret; touch Aurora's management API; reach other queues |
| `worker` | Receive, delete and change visibility on the jobs queue; decrypt | Enqueue; read secrets; anything else |

Database credentials are injected by the **execution** role at task start, so they're not readable through the task role. No task has ECS Exec, so there's no interactive shell into production.

## Signals
- CloudTrail: calls from the role's session outside its normal API set, or from outside the VPC (`sourceIPAddress` not a VPC endpoint).
- GuardDuty: `InstanceCredentialExfiltration`-style findings, or anomalous API usage.
- Sudden SQS `NumberOfMessagesSent` spikes (API role) or DLQ growth (worker role).

## Contain
1. Attach a **deny-all inline policy** to the role. It takes effect for existing sessions within seconds:
   ```bash
   aws iam put-role-policy --role-name docflow-prod-primary-api --policy-name incident-deny-all \
     --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Deny","Action":"*","Resource":"*"}]}'
   ```
2. **Revoke active sessions** (IAM console → Role → *Revoke active sessions*). This denies credentials issued before now.
3. **Rotate** the database secret. Bump `db_secret_version` and apply. Old tasks lose access, and new tasks pick the new secret up.
4. **Redeploy** a known-good digest, then remove the deny policy.

## Investigate
Use CloudTrail Lake or Athena over the trail, filtered on the role's ARN, from the first anomalous event. Check the VPC flow logs for unexpected destinations through the NAT gateway.
