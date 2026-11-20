output "app_url" { value = "https://${local.app_fqdn}" }
output "cloudfront_distribution_id" { value = aws_cloudfront_distribution.app.id }
output "primary_api_min_tasks" { value = module.primary.api_min_tasks }
output "standby_api_min_tasks" { value = module.standby.api_min_tasks }
output "global_cluster_id" { value = aws_rds_global_cluster.this.id }
