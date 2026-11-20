# Offline tests for the whole platform: both regions, the edge and DNS failover.
mock_provider "aws" {
  source          = "./tests/mocks"
  override_during = plan
}
mock_provider "aws" {
  alias           = "dr"
  source          = "./tests/mocks"
  override_during = plan
}
mock_provider "aws" {
  alias           = "edge"
  source          = "./tests/mocks"
  override_during = plan
}

override_resource {
  target          = aws_route53_health_check.primary_alb
  override_during = plan
  values          = { id = "hc-alb" }
}
override_resource {
  target          = aws_route53_health_check.primary_capacity
  override_during = plan
  values          = { id = "hc-capacity" }
}
override_resource {
  target          = aws_route53_health_check.primary
  override_during = plan
  values          = { id = "hc-primary" }
}

variables {
  domain_name                = "example.com"
  hosted_zone_id             = "Z0000000000000"
  cloudfront_certificate_arn = "arn:aws:acm:us-east-1:111111111111:certificate/edge"
  alb_certificate_arns = {
    primary = "arn:aws:acm:us-east-1:111111111111:certificate/primary"
    standby = "arn:aws:acm:us-west-2:111111111111:certificate/standby"
  }
  origin_verify_header = "0123456789abcdef0123456789abcdef"
  api_image            = "111111111111.dkr.ecr.us-east-1.amazonaws.com/api@sha256:0000000000000000000000000000000000000000000000000000000000000000"
  worker_image         = "111111111111.dkr.ecr.us-east-1.amazonaws.com/worker@sha256:0000000000000000000000000000000000000000000000000000000000000000"
  otel_collector_image = "public.ecr.aws/aws-observability/aws-otel-collector@sha256:0000000000000000000000000000000000000000000000000000000000000000"
}

run "regions" {
  command = plan

  assert {
    condition     = output.primary_api_min_tasks == 24 && output.standby_api_min_tasks == 3
    error_message = "Primary sized for N+1 at peak; standby kept warm at a small floor."
  }
  assert {
    condition     = aws_rds_global_cluster.this.storage_encrypted && aws_rds_global_cluster.this.deletion_protection
    error_message = "The global database must be encrypted and protected."
  }
}

run "edge_protection" {
  command = plan

  assert {
    condition     = aws_wafv2_web_acl.edge.scope == "CLOUDFRONT" && aws_cloudfront_distribution.app.web_acl_id == aws_wafv2_web_acl.edge.arn
    error_message = "CloudFront must be protected by the WAF web ACL."
  }
  assert {
    condition     = one([for r in aws_wafv2_web_acl.edge.rule : r if r.name == "rate-limit-per-ip"]).statement[0].rate_based_statement[0].limit == 2000
    error_message = "Per-IP rate limiting must be enforced at the edge."
  }
  assert {
    condition     = length([for r in aws_wafv2_web_acl.edge.rule : r if r.name == "sqli"]) == 1 && length([for r in aws_wafv2_web_acl.edge.rule : r if r.name == "common"]) == 1
    error_message = "OWASP common and SQL-injection managed rules must be on."
  }
  assert {
    condition     = one(aws_cloudfront_distribution.app.viewer_certificate).minimum_protocol_version == "TLSv1.2_2021"
    error_message = "Viewer TLS must be 1.2+ with modern ciphers."
  }
  assert {
    condition     = one(one(aws_cloudfront_distribution.app.origin).custom_origin_config).origin_protocol_policy == "https-only"
    error_message = "CloudFront must reach the origin over HTTPS only."
  }
  assert {
    condition     = one(aws_cloudfront_distribution.app.origin).domain_name == "origin.example.com"
    error_message = "CloudFront must use the failover origin record, not a single region."
  }
  assert {
    condition     = length(aws_wafv2_web_acl_logging_configuration.edge.redacted_fields) == 1
    error_message = "WAF logs must redact the Authorization header."
  }
}

run "dns_failover" {
  command = plan

  assert {
    condition     = one(aws_route53_record.origin_primary.failover_routing_policy).type == "PRIMARY" && one(aws_route53_record.origin_standby.failover_routing_policy).type == "SECONDARY"
    error_message = "The origin record must fail over from primary to standby."
  }
  assert {
    condition     = aws_route53_record.origin_primary.health_check_id == "hc-primary" && aws_route53_health_check.primary.type == "CALCULATED"
    error_message = "Primary must be gated by the combined (reachability + capacity) health check."
  }
  assert {
    condition     = toset(aws_route53_health_check.primary.child_healthchecks) == toset(["hc-alb", "hc-capacity"]) && aws_route53_health_check.primary.child_health_threshold == 2
    error_message = "Both the ALB check and the capacity alarm must be healthy for the primary to keep traffic."
  }
}

run "dr_region_must_differ" {
  command = plan
  variables {
    dr_region = "us-east-1"
  }
  expect_failures = [var.dr_region]
}

run "weak_origin_secret_rejected" {
  command = plan
  variables {
    origin_verify_header = "short"
  }
  expect_failures = [var.origin_verify_header]
}
