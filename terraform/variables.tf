variable "name" {
  type    = string
  default = "docflow"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "primary_region" {
  type    = string
  default = "us-east-1"
}

variable "dr_region" {
  type    = string
  default = "us-west-2"
  validation {
    condition     = var.dr_region != var.primary_region
    error_message = "The DR region must differ from the primary region."
  }
}

variable "domain_name" {
  description = "Apex domain hosted in Route 53, e.g. example.com."
  type        = string
}

variable "hosted_zone_id" {
  type = string
}

variable "cloudfront_certificate_arn" {
  description = "ACM certificate in us-east-1 covering app.<domain>."
  type        = string
}

variable "alb_certificate_arns" {
  description = "ACM certificates covering origin.<domain>, keyed by primary / standby."
  type        = object({ primary = string, standby = string })
}

variable "origin_verify_header" {
  description = "Shared secret CloudFront adds to origin requests. Rotate by applying a new value (both ends update together)."
  type        = string
  sensitive   = true
  validation {
    condition     = length(var.origin_verify_header) >= 32
    error_message = "Use at least 32 random characters."
  }
}

variable "api_image" {
  type = string
}

variable "worker_image" {
  type = string
}

variable "otel_collector_image" {
  type = string
}

variable "peak_rps" {
  type    = number
  default = 3000
}

variable "task_rps_capacity" {
  type    = number
  default = 200
}

variable "waf_rate_limit_per_ip" {
  description = "Requests per IP per 5 minutes before WAF blocks it."
  type        = number
  default     = 2000
}

variable "alarm_email" {
  type    = string
  default = ""
}

variable "aurora_engine_version" {
  type    = string
  default = "16.6"
}
