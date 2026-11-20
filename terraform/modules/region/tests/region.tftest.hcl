# Offline tests for one region (mocked AWS provider: no credentials, no cost).
mock_provider "aws" {
  override_during = plan

  mock_data "aws_availability_zones" {
    defaults = { names = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d"] }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111111111111" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:us-east-1:111111111111:key/00000000-0000-0000-0000-000000000000" }
  }
  mock_resource "aws_sqs_queue" {
    defaults = { arn = "arn:aws:sqs:us-east-1:111111111111:jobs", url = "https://sqs.us-east-1.amazonaws.com/111111111111/jobs" }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-east-1:111111111111:secret:docflow-prod/aurora/app-AbCdEf" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/mock" }
  }
  mock_resource "aws_lb" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:111111111111:loadbalancer/app/docflow/abc", arn_suffix = "app/docflow/abc" }
  }
  mock_resource "aws_lb_target_group" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:111111111111:targetgroup/docflow/abc" }
  }
  mock_resource "aws_lb_listener" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:111111111111:listener/app/docflow/abc/def" }
  }
  mock_resource "aws_lb_listener_rule" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:111111111111:listener-rule/app/docflow/abc/def/ghi" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-east-1:111111111111:log-group:mock" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::docflow-alb-logs" }
  }
  mock_resource "aws_ecs_task_definition" {
    defaults = { arn = "arn:aws:ecs:us-east-1:111111111111:task-definition/docflow:1" }
  }
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:us-east-1:111111111111:alarms" }
  }
  mock_resource "aws_rds_cluster" {
    defaults = { arn = "arn:aws:rds:us-east-1:111111111111:cluster:docflow", engine = "aurora-postgresql", engine_version = "16.6" }
  }
}

override_resource {
  target          = aws_subnet.public[0]
  override_during = plan
  values          = { id = "subnet-public-a" }
}
override_resource {
  target          = aws_nat_gateway.this[0]
  override_during = plan
  values          = { id = "nat-a" }
}
override_resource {
  target          = aws_subnet.public[1]
  override_during = plan
  values          = { id = "subnet-public-b" }
}
override_resource {
  target          = aws_nat_gateway.this[1]
  override_during = plan
  values          = { id = "nat-b" }
}
override_resource {
  target          = aws_subnet.public[2]
  override_during = plan
  values          = { id = "subnet-public-c" }
}
override_resource {
  target          = aws_nat_gateway.this[2]
  override_during = plan
  values          = { id = "nat-c" }
}

variables {
  environment          = "prod"
  role                 = "primary"
  alb_certificate_arn  = "arn:aws:acm:us-east-1:111111111111:certificate/mock"
  origin_verify_header = "0123456789abcdef0123456789abcdef"
  container_image      = "111111111111.dkr.ecr.us-east-1.amazonaws.com/api@sha256:0000000000000000000000000000000000000000000000000000000000000000"
  worker_image         = "111111111111.dkr.ecr.us-east-1.amazonaws.com/worker@sha256:0000000000000000000000000000000000000000000000000000000000000000"
  otel_collector_image = "public.ecr.aws/aws-observability/aws-otel-collector@sha256:0000000000000000000000000000000000000000000000000000000000000000"
  global_cluster_id    = "docflow-prod"
}

run "zonal_isolation" {
  command = plan

  assert {
    condition     = length(aws_nat_gateway.this) == 3
    error_message = "Production needs one NAT gateway per AZ."
  }
  assert {
    condition     = alltrue([for i in range(3) : aws_nat_gateway.this[i].subnet_id == aws_subnet.public[i].id])
    error_message = "Each NAT gateway must sit in its own AZ's public subnet."
  }
  assert {
    condition     = alltrue([for i in range(3) : one(aws_route_table.app[i].route).nat_gateway_id == aws_nat_gateway.this[i].id])
    error_message = "App subnets in AZ-x must egress through the NAT gateway in AZ-x (no cross-AZ dependency)."
  }
  assert {
    condition     = alltrue([for rt in aws_route_table.data : length(rt.route) == 0])
    error_message = "The data tier must have no route to the internet."
  }
  assert {
    condition     = length(distinct([for s in aws_subnet.app : s.availability_zone])) == 3
    error_message = "App subnets must span three distinct AZs."
  }
}

run "aws_apis_do_not_depend_on_nat" {
  command = plan

  assert {
    condition     = alltrue([for svc in ["ecr.api", "ecr.dkr", "logs", "secretsmanager", "sqs", "kms", "sts"] : contains(keys(aws_vpc_endpoint.interface), svc)])
    error_message = "Image pulls, logs, secrets, queue, KMS and STS calls must use VPC endpoints."
  }
  assert {
    condition     = aws_vpc_endpoint.s3.vpc_endpoint_type == "Gateway"
    error_message = "S3 (ECR layers) must use the gateway endpoint."
  }
}

run "capacity_survives_one_az_loss" {
  command = plan

  # 3000 RPS / 200 per task = 15 tasks; ×3/2 for N+1 = 22.5 → 23 → rounded up to a multiple of 3 = 24
  assert {
    condition     = output.api_min_tasks == 24
    error_message = "API floor must carry peak traffic on two of three AZs."
  }
  assert {
    condition     = output.api_min_tasks * 2 / 3 * var.task_rps_capacity >= var.peak_rps
    error_message = "After losing one AZ the remaining tasks must still serve peak."
  }
  assert {
    condition     = aws_ecs_service.api.deployment_minimum_healthy_percent == 100
    error_message = "Deployments must never drop below the N+1 floor."
  }
}

run "edge_cannot_be_bypassed" {
  command = plan

  assert {
    condition     = aws_vpc_security_group_ingress_rule.alb_from_cloudfront.prefix_list_id != null && aws_vpc_security_group_ingress_rule.alb_from_cloudfront.cidr_ipv4 == null
    error_message = "The ALB may only admit CloudFront's origin-facing prefix list."
  }
  assert {
    condition     = one(aws_lb_listener.https.default_action).type == "fixed-response" && one(one(aws_lb_listener.https.default_action).fixed_response).status_code == "403"
    error_message = "Requests without the CloudFront origin header must be rejected."
  }
  assert {
    condition     = aws_lb.this.drop_invalid_header_fields
    error_message = "The ALB must drop invalid header fields."
  }
  assert {
    condition     = startswith(aws_lb_listener.https.ssl_policy, "ELBSecurityPolicy-TLS13")
    error_message = "TLS 1.3 policy required on the ALB."
  }
}

run "safe_deployments" {
  command = plan

  assert {
    condition     = one(aws_ecs_service.api.deployment_configuration).strategy == "CANARY"
    error_message = "The API must deploy as a canary."
  }
  assert {
    condition     = one(one(aws_ecs_service.api.deployment_configuration).canary_configuration).canary_percent <= 10
    error_message = "The canary must start with a small share of traffic."
  }
  assert {
    condition     = one(aws_ecs_service.api.alarms).rollback && length(one(aws_ecs_service.api.alarms).alarm_names) >= 3
    error_message = "Error-rate, latency and DB-pressure alarms must roll a bad deployment back."
  }
  assert {
    condition     = one(aws_ecs_service.api.deployment_circuit_breaker).rollback
    error_message = "Tasks that never become healthy must trigger rollback."
  }
}

run "database_resilience" {
  command = plan

  assert {
    condition     = length(distinct([for i in aws_rds_cluster_instance.this : i.availability_zone])) == 3
    error_message = "Aurora writer and readers must sit in three different AZs."
  }
  assert {
    condition     = aws_rds_cluster.this.storage_encrypted && aws_rds_cluster.this.deletion_protection
    error_message = "Aurora must be encrypted and deletion-protected in prod."
  }
  assert {
    condition     = aws_rds_cluster.this.backup_retention_period >= 7
    error_message = "Point-in-time recovery window must be at least 7 days."
  }
  assert {
    condition     = alltrue([for i in aws_rds_cluster_instance.this : !i.publicly_accessible])
    error_message = "No database instance may be publicly accessible."
  }
  assert {
    condition     = aws_db_proxy.this.require_tls && one(aws_db_proxy_default_target_group.this.connection_pool_config).max_connections_percent <= 90
    error_message = "RDS Proxy must require TLS and leave connection headroom on the database."
  }
  assert {
    condition     = aws_rds_cluster.this.master_password == null
    error_message = "The master password must only be set through the write-only argument (never in state)."
  }
}

run "async_processing" {
  command = plan

  assert {
    condition     = jsondecode(aws_sqs_queue.jobs.redrive_policy).maxReceiveCount == 5
    error_message = "Poison messages must move to the DLQ after five attempts."
  }
  assert {
    condition     = aws_sqs_queue.jobs.visibility_timeout_seconds >= 6 * var.worker_timeout_seconds
    error_message = "Visibility timeout must be at least 6x the worker timeout to avoid duplicate deliveries."
  }
  assert {
    condition     = aws_sqs_queue.jobs.kms_master_key_id != null && aws_sqs_queue.jobs_dlq.kms_master_key_id != null
    error_message = "Queues must be encrypted with the platform key."
  }
}

run "least_privilege" {
  command = plan

  assert {
    condition     = alltrue([for s in jsondecode(aws_iam_role_policy.api.policy).Statement : !contains(s.Action, "sqs:ReceiveMessage") && !contains(s.Action, "sqs:DeleteMessage")])
    error_message = "The API may enqueue but never consume or delete jobs."
  }
  assert {
    condition     = alltrue([for s in jsondecode(aws_iam_role_policy.worker.policy).Statement : !contains(s.Action, "sqs:SendMessage")])
    error_message = "The worker may not enqueue jobs."
  }
  assert {
    condition     = alltrue(flatten([for p in [aws_iam_role_policy.api.policy, aws_iam_role_policy.worker.policy] : [for s in jsondecode(p).Statement : [for a in s.Action : !endswith(a, ":*")]]]))
    error_message = "Task roles must not use wildcard actions."
  }
  assert {
    condition     = !aws_ecs_service.api.enable_execute_command && !aws_ecs_service.worker.enable_execute_command
    error_message = "No interactive shell into production tasks."
  }
}

run "slo_alerting" {
  command = plan

  # 99.95% → error budget 0.0005; fast burn 14.4x → 0.72% errors
  assert {
    condition     = abs(aws_cloudwatch_metric_alarm.error_ratio["page_fast_short"].threshold - 0.0072) < 0.000001
    error_message = "Fast-burn threshold must be 14.4x the 99.95% error budget."
  }
  assert {
    condition     = alltrue([for q in aws_cloudwatch_metric_alarm.error_ratio["page_fast_long"].metric_query : q.expression != null || one(q.metric).period == 3600]) && alltrue([for q in aws_cloudwatch_metric_alarm.error_ratio["page_fast_short"].metric_query : q.expression != null || one(q.metric).period == 300])
    error_message = "Fast burn uses a 1 h window confirmed by a 5 min window."
  }
  assert {
    condition     = aws_cloudwatch_metric_alarm.latency_p99.extended_statistic == "p99" && aws_cloudwatch_metric_alarm.latency_p99.threshold == 0.4
    error_message = "Latency alarm must watch p99 against the 400 ms objective."
  }
}

run "standby_is_warm_not_cold" {
  command = plan
  variables {
    role          = "standby"
    db_secret_arn = "arn:aws:secretsmanager:us-west-2:111111111111:secret:docflow-prod/aurora/app-AbCdEf"
  }

  assert {
    condition     = output.api_min_tasks == 3 && length(aws_rds_cluster_instance.this) == 2
    error_message = "Standby keeps minimal running capacity and a two-AZ database replica."
  }
  assert {
    condition     = length(aws_secretsmanager_secret.db) == 0 && length(aws_secretsmanager_secret_version.db) == 0
    error_message = "The standby inherits credentials from the primary (replicated secret)."
  }
  assert {
    condition     = length(aws_cloudwatch_metric_alarm.global_rpo_lag) == 1
    error_message = "The standby must alarm when replication lag threatens the RPO."
  }
}

run "prod_rejects_shared_nat" {
  command = plan
  variables {
    nat_mode = "single"
  }
  expect_failures = [var.nat_mode]
}

run "rejects_mutable_image_tags" {
  command = plan
  variables {
    container_image = "111111111111.dkr.ecr.us-east-1.amazonaws.com/api:latest"
  }
  expect_failures = [var.container_image]
}

run "staging_may_share_nat" {
  command = plan
  variables {
    environment = "staging"
    nat_mode    = "single"
  }
  assert {
    condition     = length(aws_nat_gateway.this) == 1 && !aws_rds_cluster.this.deletion_protection
    error_message = "Staging may trade NAT redundancy for cost."
  }
}
