locals {
  tags     = { Project = var.name, Environment = var.environment, ManagedBy = "terraform" }
  app_fqdn = "app.${var.domain_name}"
  origin   = "origin.${var.domain_name}"
}

data "aws_ip_ranges" "route53_health_checks" {
  services = ["route53_healthchecks"]
  regions  = ["GLOBAL", var.primary_region, var.dr_region]
}

# ---------------------------------------------------------------- data: one global database
resource "aws_rds_global_cluster" "this" {
  global_cluster_identifier = "${var.name}-${var.environment}"
  engine                    = "aurora-postgresql"
  engine_version            = var.aurora_engine_version
  storage_encrypted         = true
  deletion_protection       = var.environment == "prod"
}

# ---------------------------------------------------------------- regions
module "primary" {
  source = "./modules/region"

  name                   = var.name
  environment            = var.environment
  role                   = "primary"
  vpc_cidr               = "10.10.0.0/16"
  alb_certificate_arn    = var.alb_certificate_arns.primary
  origin_verify_header   = var.origin_verify_header
  container_image        = var.api_image
  worker_image           = var.worker_image
  otel_collector_image   = var.otel_collector_image
  peak_rps               = var.peak_rps
  task_rps_capacity      = var.task_rps_capacity
  global_cluster_id      = aws_rds_global_cluster.this.id
  aurora_engine_version  = var.aurora_engine_version
  secret_replica_regions = [var.dr_region]
  health_checker_cidrs   = data.aws_ip_ranges.route53_health_checks.cidr_blocks
  alarm_email            = var.alarm_email
}

# Warm standby: same architecture, minimal running capacity, read-only database replica.
module "standby" {
  source    = "./modules/region"
  providers = { aws = aws.dr }

  name                  = var.name
  environment           = var.environment
  role                  = "standby"
  vpc_cidr              = "10.20.0.0/16" # non-overlapping, so the regions can be peered later if needed
  alb_certificate_arn   = var.alb_certificate_arns.standby
  origin_verify_header  = var.origin_verify_header
  container_image       = var.api_image
  worker_image          = var.worker_image
  otel_collector_image  = var.otel_collector_image
  peak_rps              = var.peak_rps
  task_rps_capacity     = var.task_rps_capacity
  global_cluster_id     = aws_rds_global_cluster.this.id
  aurora_engine_version = var.aurora_engine_version
  db_secret_arn         = replace(module.primary.db_secret_arn, ":${var.primary_region}:", ":${var.dr_region}:")
  health_checker_cidrs  = data.aws_ip_ranges.route53_health_checks.cidr_blocks
  alarm_email           = var.alarm_email

  depends_on = [module.primary] # the secondary cluster can only join after the primary exists
}
