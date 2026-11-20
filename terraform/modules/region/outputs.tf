output "vpc_id" { value = aws_vpc.this.id }
output "alb_arn" { value = aws_lb.this.arn }
output "alb_dns_name" { value = aws_lb.this.dns_name }
output "alb_zone_id" { value = aws_lb.this.zone_id }
output "ecs_cluster_name" { value = aws_ecs_cluster.this.name }
output "api_min_tasks" {
  description = "API floor: survives the loss of one AZ at peak (primary) or warm-standby floor."
  value       = local.api_min_tasks
}
output "queue_url" { value = aws_sqs_queue.jobs.url }
output "db_cluster_arn" { value = aws_rds_cluster.this.arn }
output "db_proxy_endpoint" { value = aws_db_proxy.this.endpoint }
output "db_secret_arn" { value = local.db_secret_arn }
output "kms_key_arn" { value = aws_kms_key.platform.arn }
output "alarm_topic_arn" { value = aws_sns_topic.alarms.arn }
output "capacity_alarm_name" { value = aws_cloudwatch_metric_alarm.api_capacity.alarm_name }
