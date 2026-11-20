# ADR 0001: Design from failure domains, then pick services

**Status:** accepted

## Context
Running in three AZs doesn't by itself make a system available. A single NAT gateway, a database writer in one AZ, or a deployment that hits every AZ at once can still take the whole platform down.

## Decision
Draw the failure-domain map ([failure-domains.md](../failure-domains.md)) before choosing services. Each AZ is self-sufficient: its own NAT gateway, routes, tasks and database instance. Shared components must be regional managed services with their own multi-AZ design (ALB, SQS, RDS Proxy, VPC endpoints). Every rule is enforced as a plan-time test.

## Consequences
- Three NAT gateways cost more than one (≈ 2 × $33/month plus data processing). VPC endpoints remove most AWS-API traffic from NAT, which offsets part of the cost.
- Staging may use `nat_mode = "single"`; production rejects it at plan time.
