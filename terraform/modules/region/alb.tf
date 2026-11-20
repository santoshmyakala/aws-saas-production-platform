# Regional entry point. Only CloudFront can reach it (prefix list + shared origin header), so the
# WAF in front of CloudFront cannot be bypassed.
resource "aws_s3_bucket" "alb_logs" {
  bucket_prefix = "${local.prefix}-alb-logs-"
  force_destroy = var.environment != "prod"
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket                  = aws_s3_bucket.alb_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # ALB access-log delivery supports SSE-S3 only
    }
  }
}

resource "aws_s3_bucket_versioning" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    expiration {
      days = var.log_retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AlbLogDelivery"
        Effect    = "Allow"
        Principal = { Service = "logdelivery.elasticloadbalancing.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.alb_logs.arn}/AWSLogs/${local.account}/*"
      },
      {
        Sid       = "TlsOnly"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.alb_logs.arn, "${aws_s3_bucket.alb_logs.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })
}

resource "aws_lb" "this" {
  name                       = substr(replace(local.prefix, "_", "-"), 0, 32)
  load_balancer_type         = "application"
  internal                   = false # internet-facing, but the security group admits CloudFront only
  subnets                    = aws_subnet.public[*].id
  security_groups            = [aws_security_group.alb.id]
  drop_invalid_header_fields = true
  desync_mitigation_mode     = "strictest"
  enable_deletion_protection = var.environment == "prod"
  idle_timeout               = 60

  access_logs {
    bucket  = aws_s3_bucket.alb_logs.id
    enabled = true
  }
  depends_on = [aws_s3_bucket_policy.alb_logs]
}

# Two target groups: ECS shifts traffic between them during canary deployments.
resource "aws_lb_target_group" "api" {
  for_each                      = toset(["blue", "green"])
  name                          = substr("${var.name}-${var.environment}-${substr(var.role, 0, 4)}-${each.key}", 0, 32)
  vpc_id                        = aws_vpc.this.id
  target_type                   = "ip"
  protocol                      = "HTTP"
  port                          = var.container_port
  deregistration_delay          = 30
  load_balancing_algorithm_type = "least_outstanding_requests"

  health_check {
    path                = "/healthz/ready" # checks dependencies, unlike a bare liveness probe
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.alb_certificate_arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Forbidden"
      status_code  = "403"
    }
  }
}

resource "aws_lb_listener_rule" "from_cloudfront" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10

  condition {
    http_header {
      http_header_name = "X-Origin-Verify"
      values           = [var.origin_verify_header]
    }
  }

  action {
    type = "forward"
    forward {
      target_group {
        arn    = aws_lb_target_group.api["blue"].arn
        weight = 100
      }
      target_group {
        arn    = aws_lb_target_group.api["green"].arn
        weight = 0
      }
    }
  }

  lifecycle {
    ignore_changes = [action] # weights are owned by ECS during deployments
  }
}

# Static liveness path for Route 53 health checks: proves the region's load balancer is reachable
# without depending on which target group a deployment is currently using. Application health is
# judged separately from the capacity alarm (see the root module's calculated health check).
resource "aws_lb_listener_rule" "alb_alive" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 1
  condition {
    path_pattern {
      values = ["/__alb_alive"]
    }
  }
  action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "ok"
      status_code  = "200"
    }
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_health_checkers" {
  count             = length(var.health_checker_cidrs)
  security_group_id = aws_security_group.alb.id
  description       = "Route 53 health checkers"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = var.health_checker_cidrs[count.index]
}
