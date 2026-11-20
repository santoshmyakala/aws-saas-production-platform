data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account = data.aws_caller_identity.current.account_id
  region  = data.aws_region.current.region
  arn_pfx = "arn:${data.aws_partition.current.partition}"
}

# ---------------------------------------------------------------- encryption
# One customer-managed key per region for logs, queues, secrets, the database and the alarm topic.
# Key usage is granted through IAM (the root-account statement); services that cannot use IAM get
# narrowly scoped statements with encryption-context conditions.
resource "aws_kms_key" "platform" {
  description             = "${local.prefix} data at rest"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.kms.json
}

resource "aws_kms_alias" "platform" {
  name          = "alias/${local.prefix}"
  target_key_id = aws_kms_key.platform.key_id
}

data "aws_iam_policy_document" "kms" {
  statement {
    sid       = "AccountAdministersKeyThroughIAM"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["${local.arn_pfx}:iam::${local.account}:root"]
    }
  }
  statement {
    sid       = "CloudWatchLogsForThisAccountOnly"
    actions   = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${local.region}.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["${local.arn_pfx}:logs:${local.region}:${local.account}:log-group:*"]
    }
  }
  statement {
    sid       = "CloudWatchAlarmsPublishToEncryptedTopic"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account]
    }
  }
}

# ---------------------------------------------------------------- security groups
# Tiered: CloudFront → ALB → app → RDS Proxy → Aurora. Every hop references the previous group.
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "alb" {
  name        = "${local.prefix}-alb"
  description = "HTTPS from CloudFront origin-facing addresses only"
  vpc_id      = aws_vpc.this.id
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_cloudfront" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from CloudFront"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "To API tasks"
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
  referenced_security_group_id = aws_security_group.app.id
}

resource "aws_security_group" "app" {
  name        = "${local.prefix}-app"
  description = "API and worker tasks"
  vpc_id      = aws_vpc.this.id
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "From the ALB"
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_egress_rule" "app_to_proxy" {
  security_group_id            = aws_security_group.app.id
  description                  = "PostgreSQL via RDS Proxy"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.proxy.id
}

resource "aws_vpc_security_group_egress_rule" "app_to_endpoints" {
  security_group_id            = aws_security_group.app.id
  description                  = "AWS APIs through interface endpoints"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.endpoints.id
}

resource "aws_vpc_security_group_egress_rule" "app_to_s3" {
  security_group_id = aws_security_group.app.id
  description       = "S3 through the gateway endpoint (ECR image layers)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  prefix_list_id    = aws_vpc_endpoint.s3.prefix_list_id
}

resource "aws_vpc_security_group_egress_rule" "app_to_internet_https" {
  security_group_id = aws_security_group.app.id
  description       = "Third-party HTTPS APIs through the zonal NAT gateway"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "endpoints" {
  name        = "${local.prefix}-endpoints"
  description = "Interface endpoints, reachable from app tasks only"
  vpc_id      = aws_vpc.this.id
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_from_app" {
  security_group_id            = aws_security_group.endpoints.id
  description                  = "HTTPS from app tasks"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.app.id
}

resource "aws_security_group" "proxy" {
  name        = "${local.prefix}-rds-proxy"
  description = "RDS Proxy, reachable from app tasks only"
  vpc_id      = aws_vpc.this.id
}

resource "aws_vpc_security_group_ingress_rule" "proxy_from_app" {
  security_group_id            = aws_security_group.proxy.id
  description                  = "PostgreSQL from app tasks"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.app.id
}

resource "aws_vpc_security_group_egress_rule" "proxy_to_db" {
  security_group_id            = aws_security_group.proxy.id
  description                  = "To Aurora"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.db.id
}

resource "aws_vpc_security_group_egress_rule" "proxy_to_secrets" {
  security_group_id            = aws_security_group.proxy.id
  description                  = "Secrets Manager through the interface endpoint"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.endpoints.id
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_from_proxy" {
  security_group_id            = aws_security_group.endpoints.id
  description                  = "HTTPS from RDS Proxy"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.proxy.id
}

resource "aws_security_group" "db" {
  name        = "${local.prefix}-aurora"
  description = "Aurora, reachable from RDS Proxy only"
  vpc_id      = aws_vpc.this.id
}

resource "aws_vpc_security_group_ingress_rule" "db_from_proxy" {
  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL from RDS Proxy"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.proxy.id
}

# ---------------------------------------------------------------- IAM
data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account]
    }
  }
}

# Execution role: used by the ECS agent only (pull image, write logs, inject the DB secret).
resource "aws_iam_role" "execution" {
  name               = "${local.prefix}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "${local.arn_pfx}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "execution_secret" {
  name = "read-db-secret"
  role = aws_iam_role.execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "DbSecret", Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = [local.db_secret_arn] },
      # The secret is encrypted with this region's key (primary) or aws/secretsmanager (replica):
      # allow decryption only when Secrets Manager is the caller.
      { Sid = "DecryptSecret", Effect = "Allow", Action = ["kms:Decrypt"], Resource = ["*"], Condition = { StringEquals = { "kms:ViaService" = "secretsmanager.${local.region}.amazonaws.com" } } },
    ]
  })
}

# API task role: may only enqueue work. It cannot read the queue, other secrets or any data store API.
resource "aws_iam_role" "api" {
  name               = "${local.prefix}-api"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy" "api" {
  name = "least-privilege"
  role = aws_iam_role.api.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      { Sid = "EnqueueJobs", Effect = "Allow", Action = ["sqs:SendMessage"], Resource = [aws_sqs_queue.jobs.arn] },
      { Sid = "EncryptMessages", Effect = "Allow", Action = ["kms:GenerateDataKey", "kms:Decrypt"], Resource = [aws_kms_key.platform.arn] },
    ], local.telemetry_statements)
  })
}

# Worker task role: may only consume its own queue.
resource "aws_iam_role" "worker" {
  name               = "${local.prefix}-worker"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy" "worker" {
  name = "least-privilege"
  role = aws_iam_role.worker.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      { Sid = "ConsumeJobs", Effect = "Allow", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueAttributes"], Resource = [aws_sqs_queue.jobs.arn] },
      { Sid = "DecryptMessages", Effect = "Allow", Action = ["kms:Decrypt"], Resource = [aws_kms_key.platform.arn] },
    ], local.telemetry_statements)
  })
}

locals {
  # OpenTelemetry collector sidecar: traces to X-Ray, metrics to CloudWatch in our namespace only.
  telemetry_statements = [
    { Sid = "Traces", Effect = "Allow", Action = ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules", "xray:GetSamplingTargets"], Resource = ["*"] },
    { Sid = "Metrics", Effect = "Allow", Action = ["cloudwatch:PutMetricData"], Resource = ["*"], Condition = { StringEquals = { "cloudwatch:namespace" = var.name } } },
  ]
}

resource "aws_iam_role" "flow_logs" {
  name = "${local.prefix}-flow-logs"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Condition = { StringEquals = { "aws:SourceAccount" = local.account } }
    }]
  })
}

resource "aws_iam_role_policy" "flow_logs" {
  name = "write-flow-logs"
  role = aws_iam_role.flow_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
      Resource = ["${aws_cloudwatch_log_group.flow.arn}:*"]
    }]
  })
}
