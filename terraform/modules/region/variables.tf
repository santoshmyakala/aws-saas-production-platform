variable "name" {
  description = "Platform name, used as a prefix for every resource."
  type        = string
  default     = "docflow"
}

variable "environment" {
  description = "prod or staging. Production enforces the failure-domain rules below."
  type        = string
  validation {
    condition     = contains(["prod", "staging"], var.environment)
    error_message = "environment must be prod or staging."
  }
}

variable "role" {
  description = "primary serves traffic; standby is the warm-standby copy in the DR region."
  type        = string
  validation {
    condition     = contains(["primary", "standby"], var.role)
    error_message = "role must be primary or standby."
  }
}

# ---------------------------------------------------------------- network
variable "vpc_cidr" {
  description = "VPC CIDR. A /16 leaves room for three /24 subnets per tier per AZ and future growth."
  type        = string
  default     = "10.0.0.0/16"
  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && tonumber(split("/", var.vpc_cidr)[1]) <= 18
    error_message = "Use a /18 or larger VPC so every tier can get one subnet per AZ with room to grow."
  }
}

variable "az_count" {
  description = "Number of Availability Zones. Capacity is sized so the platform survives the loss of one."
  type        = number
  default     = 3
  validation {
    condition     = var.az_count >= 2 && var.az_count <= 4
    error_message = "az_count must be between 2 and 4."
  }
}

variable "nat_mode" {
  description = "per_az: one NAT gateway per AZ with zonal routing (required in prod). single: one shared NAT, a cross-AZ single point of failure — only for staging."
  type        = string
  default     = "per_az"
  validation {
    condition     = contains(["per_az", "single"], var.nat_mode)
    error_message = "nat_mode must be per_az or single."
  }
  validation {
    condition     = var.environment != "prod" || var.nat_mode == "per_az"
    error_message = "Production requires one NAT gateway per AZ: a shared NAT makes every AZ depend on one zone's egress."
  }
}

# ---------------------------------------------------------------- edge
variable "alb_certificate_arn" {
  description = "ACM certificate in this region for the ALB's HTTPS listener."
  type        = string
}

variable "origin_verify_header" {
  description = "Shared secret CloudFront sends in X-Origin-Verify; the ALB rejects requests without it, so WAF cannot be bypassed."
  type        = string
  sensitive   = true
}

# ---------------------------------------------------------------- compute
variable "container_image" {
  description = "Immutable image reference for the API (registry/repo@sha256:...). Tags are rejected."
  type        = string
  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.container_image))
    error_message = "container_image must be pinned by digest (…@sha256:<64 hex>) so every deployment is immutable and reversible."
  }
}

variable "worker_image" {
  description = "Immutable image reference for the queue worker."
  type        = string
  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.worker_image))
    error_message = "worker_image must be pinned by digest."
  }
}

variable "container_port" {
  type    = number
  default = 8080
}

variable "peak_rps" {
  description = "Peak requests per second the platform must serve (requirement)."
  type        = number
  default     = 3000
}

variable "task_rps_capacity" {
  description = "Sustainable requests per second per API task at the p99 target, measured by load test."
  type        = number
  default     = 200
}

variable "standby_min_tasks" {
  description = "Warm-standby floor in the DR region. Scaled out by the failover runbook."
  type        = number
  default     = 3
}

variable "max_tasks" {
  type    = number
  default = 90
}

variable "worker_timeout_seconds" {
  description = "Upper bound for processing one message. Visibility timeout is derived from it."
  type        = number
  default     = 30
}

variable "worker_max_backlog_per_task" {
  description = "Acceptable queue backlog per worker task (latency target ÷ average processing time)."
  type        = number
  default     = 100
}

# ---------------------------------------------------------------- data
variable "aurora_engine_version" {
  type    = string
  default = "16.6"
}

variable "aurora_instance_class" {
  type    = string
  default = "db.r7g.xlarge"
}

variable "global_cluster_id" {
  description = "Aurora global database identifier (created at the root)."
  type        = string
}

variable "backup_retention_days" {
  description = "Automated backups / point-in-time recovery window."
  type        = number
  default     = 14
  validation {
    condition     = var.backup_retention_days >= 7
    error_message = "Keep at least 7 days of point-in-time recovery."
  }
}

variable "db_proxy_max_connections_percent" {
  description = "Share of the database's max_connections that RDS Proxy may use; the rest is headroom for admin and failover."
  type        = number
  default     = 80
}

# ---------------------------------------------------------------- observability
variable "availability_slo" {
  description = "Availability objective, e.g. 99.95."
  type        = number
  default     = 99.95
}

variable "latency_p99_seconds" {
  description = "p99 latency objective at the load balancer."
  type        = number
  default     = 0.4
}

variable "log_retention_days" {
  type    = number
  default = 90
}

variable "alarm_email" {
  description = "Optional e-mail subscription for the alarm topic (on-call tooling usually subscribes instead)."
  type        = string
  default     = ""
}

variable "db_secret_arn" {
  description = "Standby only: ARN of the replicated database secret in this region (the primary creates and replicates it)."
  type        = string
  default     = null
}

variable "secret_replica_regions" {
  description = "Primary only: regions that receive a replica of the database secret (the DR region)."
  type        = list(string)
  default     = []
}

variable "db_secret_version" {
  description = "Bump to rotate the master password: a new ephemeral value is generated and written to both Aurora and the secret."
  type        = number
  default     = 1
}

variable "otel_collector_image" {
  description = "AWS Distro for OpenTelemetry collector image, pinned by digest."
  type        = string
  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.otel_collector_image))
    error_message = "otel_collector_image must be pinned by digest."
  }
}

variable "canary_percent" {
  description = "Share of production traffic the new revision receives before full rollout."
  type        = number
  default     = 5
}

variable "canary_bake_minutes" {
  description = "How long the canary is observed against the rollback alarms."
  type        = number
  default     = 10
}

variable "health_checker_cidrs" {
  description = "Route 53 health-checker IPv4 ranges allowed to reach the ALB's static liveness path."
  type        = list(string)
  default     = []
}
