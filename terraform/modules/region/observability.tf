# SLO-based alerting. Error budget for 99.95% over 30 days = 0.05% of requests (~21.6 minutes of full
# outage). Pages fire on *burn rate* (how fast the budget is being spent), using two windows each so a
# short spike doesn't page but a sustained one pages within minutes (Google SRE workbook, ch. 5).
locals {
  error_budget = (100 - var.availability_slo) / 100
  burn_windows = {
    # name        = [long window s, short window s, burn multiplier, severity]
    page_fast   = [3600, 300, 14.4, "page"]
    ticket_slow = [21600, 1800, 6, "ticket"]
  }
  alb_dim = { LoadBalancer = aws_lb.this.arn_suffix }
}

resource "aws_sns_topic" "alarms" {
  name              = "${local.prefix}-alarms"
  kms_master_key_id = aws_kms_key.platform.arn
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alarm_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# One error-ratio alarm per window: long + short of each burn-rate pair.
locals {
  ratio_alarms = merge([for k, v in local.burn_windows : {
    "${k}_long"  = { period = v[0], threshold = v[2] * local.error_budget, pair = k }
    "${k}_short" = { period = v[1], threshold = v[2] * local.error_budget, pair = k }
  }]...)
}

resource "aws_cloudwatch_metric_alarm" "error_ratio" {
  for_each            = local.ratio_alarms
  alarm_name          = "${local.prefix}-error-ratio-${each.key}"
  alarm_description   = "5xx ratio above ${each.value.threshold * 100}% over ${each.value.period / 60} min (burn-rate window)."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = each.value.threshold
  treat_missing_data  = "notBreaching"

  metric_query {
    id = "requests"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      period      = each.value.period
      stat        = "Sum"
      dimensions  = local.alb_dim
    }
  }
  metric_query {
    id = "target5xx"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      period      = each.value.period
      stat        = "Sum"
      dimensions  = local.alb_dim
    }
  }
  metric_query {
    id = "elb5xx"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_ELB_5XX_Count"
      period      = each.value.period
      stat        = "Sum"
      dimensions  = local.alb_dim
    }
  }
  metric_query {
    id          = "ratio"
    expression  = "(FILL(target5xx,0) + FILL(elb5xx,0)) / IF(requests > 0, requests, 1)"
    label       = "5xx ratio"
    return_data = true
  }
}

resource "aws_cloudwatch_composite_alarm" "slo_burn" {
  for_each          = local.burn_windows
  alarm_name        = "${local.prefix}-slo-burn-${each.key}"
  alarm_description = "Availability SLO ${var.availability_slo}%: error budget burning at ${each.value[2]}x (${each.value[3]})."
  alarm_rule        = "ALARM(\"${aws_cloudwatch_metric_alarm.error_ratio["${each.key}_long"].alarm_name}\") AND ALARM(\"${aws_cloudwatch_metric_alarm.error_ratio["${each.key}_short"].alarm_name}\")"
  alarm_actions     = [aws_sns_topic.alarms.arn]
  ok_actions        = [aws_sns_topic.alarms.arn]
}

# Fast signal used by deployments: a canary that raises the 5-minute error ratio past the fast-burn
# threshold is rolled back without waiting for the 1-hour window.
resource "aws_cloudwatch_metric_alarm" "error_rate_fast" {
  alarm_name          = "${local.prefix}-deploy-error-rate"
  alarm_description   = "Deployment guard: 5xx ratio over 1 minute (2 of 3) above the fast-burn threshold."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  threshold           = local.burn_windows.page_fast[2] * local.error_budget
  treat_missing_data  = "notBreaching"

  metric_query {
    id = "requests"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      period      = 60
      stat        = "Sum"
      dimensions  = local.alb_dim
    }
  }
  metric_query {
    id = "target5xx"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      period      = 60
      stat        = "Sum"
      dimensions  = local.alb_dim
    }
  }
  metric_query {
    id          = "ratio"
    expression  = "FILL(target5xx,0) / IF(requests > 0, requests, 1)"
    return_data = true
  }
}

resource "aws_cloudwatch_metric_alarm" "latency_p99" {
  alarm_name          = "${local.prefix}-latency-p99"
  alarm_description   = "p99 target response time above the ${var.latency_p99_seconds * 1000} ms objective (3 of 5 minutes)."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p99"
  dimensions          = local.alb_dim
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.latency_p99_seconds
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
}

# Connection pressure: time to borrow a pooled connection. Rising borrow latency is the early warning
# for the "more tasks made it slower" failure mode.
resource "aws_cloudwatch_metric_alarm" "db_connections" {
  alarm_name          = "${local.prefix}-db-connection-borrow-latency"
  alarm_description   = "RDS Proxy borrow latency above 50 ms: the pool is saturated."
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnectionsBorrowLatency"
  dimensions          = { ProxyName = aws_db_proxy.this.name }
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = 50000 # microseconds
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "db_cpu" {
  alarm_name          = "${local.prefix}-aurora-cpu"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  dimensions          = { DBClusterIdentifier = aws_rds_cluster.this.cluster_identifier, Role = "WRITER" }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "global_rpo_lag" {
  count               = local.is_primary ? 0 : 1
  alarm_name          = "${local.prefix}-aurora-global-rpo-lag"
  alarm_description   = "Cross-region replication lag above 5 minutes: the 15-minute RPO is at risk."
  namespace           = "AWS/RDS"
  metric_name         = "AuroraGlobalDBRPOLag"
  dimensions          = { DBClusterIdentifier = aws_rds_cluster.this.cluster_identifier }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  comparison_operator = "GreaterThanThreshold"
  threshold           = 300000      # ms
  treat_missing_data  = "breaching" # no lag data from a standby means replication is broken
  alarm_actions       = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  alarm_name          = "${local.prefix}-jobs-dlq-not-empty"
  alarm_description   = "Messages reached the dead-letter queue: investigate before redriving."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.jobs_dlq.name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "queue_age" {
  alarm_name          = "${local.prefix}-jobs-oldest-message-age"
  alarm_description   = "Oldest job waiting more than 5 minutes: workers are not keeping up."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  dimensions          = { QueueName = aws_sqs_queue.jobs.name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  comparison_operator = "GreaterThanThreshold"
  threshold           = 300
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "nat_port_allocation" {
  count               = local.nat_count
  alarm_name          = "${local.prefix}-nat-${local.azs[count.index]}-port-allocation"
  alarm_description   = "NAT gateway cannot allocate source ports: egress connections are failing in this AZ."
  namespace           = "AWS/NATGateway"
  metric_name         = "ErrorPortAllocation"
  dimensions          = { NatGatewayId = aws_nat_gateway.this[count.index].id }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_dashboard" "service" {
  dashboard_name = local.prefix
  dashboard_body = jsonencode({
    widgets = [
      { type = "metric", x = 0, y = 0, width = 12, height = 6, properties = {
        title   = "Latency p50 / p95 / p99 (s)", region = local.region, view = "timeSeries",
        metrics = [for p in ["p50", "p95", "p99"] : ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.this.arn_suffix, { stat = p }]]
      } },
      { type = "metric", x = 12, y = 0, width = 12, height = 6, properties = {
        title   = "Requests and 5xx", region = local.region, view = "timeSeries", stat = "Sum",
        metrics = [["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.this.arn_suffix], [".", "HTTPCode_Target_5XX_Count", ".", "."], [".", "HTTPCode_ELB_5XX_Count", ".", "."]]
      } },
      { type = "metric", x = 0, y = 6, width = 12, height = 6, properties = {
        title   = "RDS Proxy: borrow latency (µs) and client connections", region = local.region, view = "timeSeries",
        metrics = [["AWS/RDS", "DatabaseConnectionsBorrowLatency", "ProxyName", aws_db_proxy.this.name], [".", "ClientConnections", ".", "."]]
      } },
      { type = "metric", x = 12, y = 6, width = 12, height = 6, properties = {
        title   = "Queue backlog, age and DLQ", region = local.region, view = "timeSeries",
        metrics = [["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.jobs.name], [".", "ApproximateAgeOfOldestMessage", ".", "."], [".", "ApproximateNumberOfMessagesVisible", ".", aws_sqs_queue.jobs_dlq.name]]
      } },
    ]
  })
}

# Regional health signal for DNS failover: the API has lost more than one AZ's worth of capacity.
resource "aws_cloudwatch_metric_alarm" "api_capacity" {
  alarm_name          = "${local.prefix}-api-capacity-collapse"
  alarm_description   = "Running API tasks below half the N+1 floor: more than one AZ's capacity is gone."
  namespace           = "ECS/ContainerInsights"
  metric_name         = "RunningTaskCount"
  dimensions          = { ClusterName = aws_ecs_cluster.this.name, ServiceName = aws_ecs_service.api.name }
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 3
  comparison_operator = "LessThanThreshold"
  threshold           = ceil(local.api_min_tasks / 2)
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
}
