# Request path: client → Route 53 → CloudFront (TLS, WAF, caching) → origin.<domain> (Route 53 failover)
# → regional ALB → ECS. See docs/request-path.md for the latency budget of each hop.

# ---------------------------------------------------------------- WAF
resource "aws_wafv2_web_acl" "edge" {
  provider    = aws.edge
  name        = "${var.name}-${var.environment}-edge"
  description = "Managed protections plus per-IP rate limiting in front of CloudFront"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "rate-limit-per-ip"
    priority = 0
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit_per_ip
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit-per-ip"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "ip-reputation"
    priority = 1
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesAmazonIpReputationList"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "ip-reputation"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "common"
    priority = 2
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
        # Document uploads exceed the rule set's 8 KB body limit: count instead of block, and enforce
        # the real limit in the API.
        rule_action_override {
          name = "SizeRestrictions_BODY"
          action_to_use {
            count {}
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "common"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "known-bad-inputs"
    priority = 3
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "sqli"
    priority = 4
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesSQLiRuleSet"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "sqli"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name}-edge"
    sampled_requests_enabled   = true
  }
}

resource "aws_cloudwatch_log_group" "waf" {
  provider          = aws.edge
  name              = "aws-waf-logs-${var.name}-${var.environment}" # prefix required by WAF
  retention_in_days = 90
}

resource "aws_wafv2_web_acl_logging_configuration" "edge" {
  provider                = aws.edge
  resource_arn            = aws_wafv2_web_acl.edge.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]
  redacted_fields {
    single_header {
      name = "authorization"
    }
  }
}

# ---------------------------------------------------------------- CloudFront
data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

data "aws_cloudfront_response_headers_policy" "security" {
  name = "Managed-SecurityHeadersPolicy"
}

resource "aws_cloudfront_distribution" "app" {
  enabled         = true
  comment         = "${var.name} ${var.environment}"
  aliases         = [local.app_fqdn]
  http_version    = "http2and3"
  is_ipv6_enabled = true
  price_class     = "PriceClass_100"
  web_acl_id      = aws_wafv2_web_acl.edge.arn

  origin {
    origin_id   = "regional-alb"
    domain_name = local.origin # Route 53 failover record: primary region, else warm standby
    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_protocol_policy   = "https-only"
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_read_timeout      = 10 # well above p99, well below the client's patience
      origin_keepalive_timeout = 30
    }
    custom_header {
      name  = "X-Origin-Verify"
      value = var.origin_verify_header
    }
  }

  # API: never cached, all methods, viewer headers/cookies/query forwarded.
  default_cache_behavior {
    target_origin_id           = "regional-alb"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security.id
  }

  # Static assets: cached at the edge, absorbing most GETs before they reach a region.
  ordered_cache_behavior {
    path_pattern               = "/static/*"
    target_origin_id           = "regional-alb"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.optimized.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security.id
  }

  viewer_certificate {
    acm_certificate_arn      = var.cloudfront_certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
}

# ---------------------------------------------------------------- DNS
resource "aws_route53_record" "app" {
  for_each = toset(["A", "AAAA"])
  zone_id  = var.hosted_zone_id
  name     = local.app_fqdn
  type     = each.key
  alias {
    name                   = aws_cloudfront_distribution.app.domain_name
    zone_id                = aws_cloudfront_distribution.app.hosted_zone_id
    evaluate_target_health = false
  }
}

# Primary region is healthy only if its ALB answers AND it still has enough API capacity.
resource "aws_route53_health_check" "primary_alb" {
  fqdn              = module.primary.alb_dns_name
  type              = "HTTPS"
  port              = 443
  resource_path     = "/__alb_alive"
  request_interval  = 10
  failure_threshold = 3
}

resource "aws_route53_health_check" "primary_capacity" {
  type                            = "CLOUDWATCH_METRIC"
  cloudwatch_alarm_name           = module.primary.capacity_alarm_name
  cloudwatch_alarm_region         = var.primary_region
  insufficient_data_health_status = "LastKnownStatus"
}

resource "aws_route53_health_check" "primary" {
  type                   = "CALCULATED"
  child_health_threshold = 2
  child_healthchecks     = [aws_route53_health_check.primary_alb.id, aws_route53_health_check.primary_capacity.id]
}

# Automatic failover moves *traffic* to the standby, which serves reads immediately. Promoting the
# standby database for writes is a deliberate, approved step (docs/runbooks/regional-failover.md):
# a replicated database also replicates a bad migration, so a human confirms the cause first.
resource "aws_route53_record" "origin_primary" {
  zone_id         = var.hosted_zone_id
  name            = local.origin
  type            = "A"
  set_identifier  = "primary"
  health_check_id = aws_route53_health_check.primary.id
  failover_routing_policy {
    type = "PRIMARY"
  }
  alias {
    name                   = module.primary.alb_dns_name
    zone_id                = module.primary.alb_zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "origin_standby" {
  zone_id        = var.hosted_zone_id
  name           = local.origin
  type           = "A"
  set_identifier = "standby"
  failover_routing_policy {
    type = "SECONDARY"
  }
  alias {
    name                   = module.standby.alb_dns_name
    zone_id                = module.standby.alb_zone_id
    evaluate_target_health = true
  }
}
