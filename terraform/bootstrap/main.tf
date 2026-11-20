# One-time bootstrap (run locally with admin credentials): GitHub OIDC trust, remote state, CI roles.
# After this, no long-lived AWS keys exist anywhere in GitHub.
terraform {
  required_version = ">= 1.11"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "github_repository" {
  description = "owner/name of the repository allowed to assume the roles"
  type        = string
  default     = "santoshmyakala/aws-saas-production-platform"
}

provider "aws" {
  region = var.region
}


locals {
  oidc_host = "token.actions.githubusercontent.com"
  # The OIDC "sub" claim encodes the GitHub environment, so trust is scoped per environment.
  plan_subjects   = [for e in ["plan-staging", "plan-production"] : "repo:${var.github_repository}:environment:${e}"]
  deploy_subjects = [for e in ["staging", "production"] : "repo:${var.github_repository}:environment:${e}"]
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://${local.oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
}

# ---------------------------------------------------------------- state
resource "aws_kms_key" "state" {
  description         = "Terraform state for ${var.github_repository}"
  enable_key_rotation = true
}

resource "aws_s3_bucket" "state" {
  bucket_prefix = "tfstate-docflow-"
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "TlsOnly"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

# ---------------------------------------------------------------- roles
data "aws_iam_policy_document" "trust" {
  for_each = { plan = local.plan_subjects, deploy = local.deploy_subjects }
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = each.value
    }
  }
}

resource "aws_iam_role" "ci" {
  for_each             = data.aws_iam_policy_document.trust
  name                 = "gha-docflow-${each.key}"
  assume_role_policy   = each.value.json
  max_session_duration = 3600
}

# Plan: read everything, write only the state lock file.
resource "aws_iam_role_policy_attachment" "plan_read_only" {
  role       = aws_iam_role.ci["plan"].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# Deploy: creates VPCs, IAM roles, databases… it needs broad rights. It is protected by the GitHub
# environment rules (main only, reviewers for production) and should carry a permissions boundary in
# a real organisation (see docs/ci-cd.md).
resource "aws_iam_role_policy_attachment" "deploy_admin" {
  role       = aws_iam_role.ci["deploy"].name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_role_policy" "state_access" {
  for_each = aws_iam_role.ci
  name     = "terraform-state"
  role     = each.value.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:ListBucket"], Resource = [aws_s3_bucket.state.arn] },
      {
        Effect   = "Allow"
        Action   = each.key == "deploy" ? ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"] : ["s3:GetObject"]
        Resource = ["${aws_s3_bucket.state.arn}/*"]
      },
      # plan needs to take the lock file too (use_lockfile), but nothing else
      { Effect = "Allow", Action = ["s3:PutObject", "s3:DeleteObject"], Resource = ["${aws_s3_bucket.state.arn}/*.tflock"] },
      { Effect = "Allow", Action = ["kms:Decrypt", "kms:GenerateDataKey"], Resource = [aws_kms_key.state.arn] },
    ]
  })
}

output "github_variables" {
  description = "Set these as GitHub Actions variables (see docs/ci-cd.md)."
  value = {
    AWS_PLAN_ROLE_ARN   = aws_iam_role.ci["plan"].arn
    AWS_DEPLOY_ROLE_ARN = aws_iam_role.ci["deploy"].arn
    TF_STATE_BUCKET     = aws_s3_bucket.state.bucket
    AWS_REGION          = var.region
  }
}
