# Aurora PostgreSQL (global database member) behind RDS Proxy.
locals {
  is_primary     = var.role == "primary"
  db_instances   = local.is_primary ? var.az_count : 2 # standby keeps two AZs so it is Multi-AZ after promotion
  db_secret_arn  = local.is_primary ? aws_secretsmanager_secret.db[0].arn : var.db_secret_arn
  engine_major   = split(".", var.aurora_engine_version)[0]
  db_master_user = "docflow_admin"
}

resource "aws_db_subnet_group" "this" {
  name       = local.prefix
  subnet_ids = aws_subnet.data[*].id
}

resource "aws_rds_cluster_parameter_group" "this" {
  name   = local.prefix
  family = "aurora-postgresql${local.engine_major}"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
  parameter {
    # Log queries slower than the API's p99 budget so slow-query regressions are visible per deploy.
    name  = "log_min_duration_statement"
    value = "400"
  }
  parameter {
    # Kill sessions that hold locks while idle in a transaction (a classic connection-pool leak).
    name  = "idle_in_transaction_session_timeout"
    value = "60000"
  }
}

# ---- credentials: generated ephemerally, written write-only. Never stored in Terraform state.
ephemeral "aws_secretsmanager_random_password" "db" {
  count               = local.is_primary ? 1 : 0
  password_length     = 40
  exclude_punctuation = true
}

resource "aws_secretsmanager_secret" "db" {
  count       = local.is_primary ? 1 : 0
  name        = "${var.name}-${var.environment}/aurora/app"
  description = "Aurora credentials used by RDS Proxy and injected into tasks"
  kms_key_id  = aws_kms_key.platform.arn

  dynamic "replica" {
    for_each = var.secret_replica_regions
    content {
      region = replica.value # encrypted with the replica region's aws/secretsmanager key
    }
  }
}

resource "aws_secretsmanager_secret_version" "db" {
  count                    = local.is_primary ? 1 : 0
  secret_id                = aws_secretsmanager_secret.db[0].id
  secret_string_wo         = jsonencode({ username = local.db_master_user, password = ephemeral.aws_secretsmanager_random_password.db[0].random_password })
  secret_string_wo_version = var.db_secret_version
}

resource "aws_rds_cluster" "this" {
  cluster_identifier                  = local.prefix
  engine                              = "aurora-postgresql"
  engine_version                      = var.aurora_engine_version
  global_cluster_identifier           = var.global_cluster_id
  database_name                       = local.is_primary ? "docflow" : null
  master_username                     = local.is_primary ? local.db_master_user : null
  master_password_wo                  = local.is_primary ? ephemeral.aws_secretsmanager_random_password.db[0].random_password : null
  master_password_wo_version          = local.is_primary ? var.db_secret_version : null
  db_subnet_group_name                = aws_db_subnet_group.this.name
  vpc_security_group_ids              = [aws_security_group.db.id]
  db_cluster_parameter_group_name     = aws_rds_cluster_parameter_group.this.name
  storage_encrypted                   = true
  kms_key_id                          = aws_kms_key.platform.arn
  backup_retention_period             = var.backup_retention_days
  preferred_backup_window             = "02:00-03:00"
  copy_tags_to_snapshot               = true
  deletion_protection                 = var.environment == "prod"
  skip_final_snapshot                 = false
  final_snapshot_identifier           = "${local.prefix}-final"
  iam_database_authentication_enabled = true
  enabled_cloudwatch_logs_exports     = ["postgresql"]

  lifecycle {
    # Global-database membership and promotion are managed by the failover runbook, not by a plan.
    ignore_changes = [replication_source_identifier, global_cluster_identifier]
  }
}

resource "aws_rds_cluster_instance" "this" {
  count                                 = local.db_instances
  identifier                            = "${local.prefix}-${count.index}"
  cluster_identifier                    = aws_rds_cluster.this.id
  engine                                = aws_rds_cluster.this.engine
  engine_version                        = aws_rds_cluster.this.engine_version
  instance_class                        = var.aurora_instance_class
  availability_zone                     = local.azs[count.index]
  promotion_tier                        = count.index
  db_subnet_group_name                  = aws_db_subnet_group.this.name
  publicly_accessible                   = false
  auto_minor_version_upgrade            = true
  ca_cert_identifier                    = "rds-ca-rsa2048-g1"
  performance_insights_enabled          = true
  performance_insights_kms_key_id       = aws_kms_key.platform.arn
  performance_insights_retention_period = 7
  monitoring_interval                   = 30
  monitoring_role_arn                   = aws_iam_role.rds_monitoring.arn
}

resource "aws_iam_role" "rds_monitoring" {
  name = "${local.prefix}-rds-monitoring"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "monitoring.rds.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "${local.arn_pfx}:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# ---- RDS Proxy: pools connections so scaling out tasks cannot exhaust the database, and shortens
# failover for clients (it keeps client connections open while it reconnects to the new writer).
resource "aws_iam_role" "proxy" {
  name = "${local.prefix}-rds-proxy"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "rds.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy" "proxy" {
  name = "read-db-secret"
  role = aws_iam_role.proxy.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = [local.db_secret_arn] },
      { Effect = "Allow", Action = ["kms:Decrypt"], Resource = ["*"], Condition = { StringEquals = { "kms:ViaService" = "secretsmanager.${local.region}.amazonaws.com" } } },
    ]
  })
}

resource "aws_db_proxy" "this" {
  name                   = local.prefix
  engine_family          = "POSTGRESQL"
  role_arn               = aws_iam_role.proxy.arn
  vpc_subnet_ids         = aws_subnet.data[*].id
  vpc_security_group_ids = [aws_security_group.proxy.id]
  require_tls            = true
  idle_client_timeout    = 1800

  auth {
    auth_scheme               = "SECRETS"
    secret_arn                = local.db_secret_arn
    client_password_auth_type = "POSTGRES_SCRAM_SHA_256"
    iam_auth                  = "DISABLED"
  }
}

resource "aws_db_proxy_default_target_group" "this" {
  db_proxy_name = aws_db_proxy.this.name
  connection_pool_config {
    max_connections_percent      = var.db_proxy_max_connections_percent
    max_idle_connections_percent = 50
    connection_borrow_timeout    = 5 # fail fast instead of queueing behind a saturated pool
  }
}

resource "aws_db_proxy_target" "this" {
  db_proxy_name         = aws_db_proxy.this.name
  target_group_name     = aws_db_proxy_default_target_group.this.name
  db_cluster_identifier = aws_rds_cluster.this.cluster_identifier
}

resource "aws_db_proxy_endpoint" "read_only" {
  db_proxy_name          = aws_db_proxy.this.name
  db_proxy_endpoint_name = "${local.prefix}-ro"
  vpc_subnet_ids         = aws_subnet.data[*].id
  vpc_security_group_ids = [aws_security_group.proxy.id]
  target_role            = "READ_ONLY"
}
