# ADR 0002: ECS on Fargate for the API and worker

**Status:** accepted

## Options

| | ECS Fargate | EKS | EC2 Auto Scaling | Lambda |
|---|---|---|---|---|
| Start-up | 30–60 s | 1–3 min (pod + node) | 2–5 min | ms to seconds (cold start) |
| Operating effort | Low | High: cluster, add-ons, upgrades | Medium: AMIs, patching | Low |
| Isolation | Per task | Per pod / namespace | Shared instance | Per invocation |
| Typical failure modes | Task restarts, image pull, quotas | Control-plane add-ons, node pressure | Patch drift, slow scaling | Concurrency limits, timeouts |

## Decision
ECS on Fargate. The workload is containerised HTTP APIs plus queue workers at 3,000 RPS. The team doesn't need Kubernetes' extensibility, and Fargate removes node patching, which is the most common source of drift.

## Revisit when
- **EKS:** many services need shared platform tooling, a service mesh or multi-tenant isolation (see [ai-infrastructure-hpc-gpu](https://github.com/santoshmyakala/ai-infrastructure-hpc-gpu) for a GPU case).
- **EC2:** steady, high utilisation makes reserved instances clearly cheaper, or specialised hardware is needed.
- **Lambda:** for spiky, event-driven side work such as notifications. The worker could move there if its p99 processing time stays well under the 15-minute limit.
