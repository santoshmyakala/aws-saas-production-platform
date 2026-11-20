# ECS on Fargate: API service (behind the ALB) and queue worker. See docs/decisions/0002-compute.md.
locals {
  # Capacity rule: with one AZ lost, the remaining AZs must still carry peak traffic.
  #   tasks >= peak_rps / task_rps * az_count / (az_count - 1), rounded up to a multiple of az_count
  n_plus_one_tasks = ceil(var.peak_rps / var.task_rps_capacity * var.az_count / (var.az_count - 1))
  api_min_tasks = (local.is_primary ?
    ceil(local.n_plus_one_tasks / var.az_count) * var.az_count :
  var.standby_min_tasks)
  worker_min_tasks = local.is_primary ? var.az_count : 1
  db_pool_per_task = 10
}

resource "aws_ecs_cluster" "this" {
  name = local.prefix
  setting {
    name  = "containerInsights"
    value = "enhanced"
  }
}

resource "aws_cloudwatch_log_group" "service" {
  for_each          = toset(["api", "worker", "otel"])
  name              = "/ecs/${local.prefix}/${each.key}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.platform.arn
}

locals {
  common_env = [
    { name = "DB_HOST", value = aws_db_proxy.this.endpoint },
    { name = "DB_READ_HOST", value = aws_db_proxy_endpoint.read_only.endpoint },
    { name = "DB_NAME", value = "docflow" },
    { name = "DB_POOL_MAX", value = tostring(local.db_pool_per_task) },
    { name = "DB_SSLMODE", value = "verify-full" },
    { name = "QUEUE_URL", value = aws_sqs_queue.jobs.url },
    { name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = "http://localhost:4318" },
    { name = "OTEL_RESOURCE_ATTRIBUTES", value = "deployment.environment=${var.environment},cloud.region=${local.region}" },
  ]
  db_secrets = [
    { name = "DB_USER", valueFrom = "${local.db_secret_arn}:username::" },
    { name = "DB_PASSWORD", valueFrom = "${local.db_secret_arn}:password::" },
  ]
  otel_sidecar = {
    name                   = "otel-collector"
    image                  = var.otel_collector_image
    essential              = false
    readonlyRootFilesystem = true
    user                   = "10001"
    command                = ["--config=/etc/ecs/ecs-default-config.yaml"]
    logConfiguration = {
      logDriver = "awslogs"
      options   = { awslogs-group = aws_cloudwatch_log_group.service["otel"].name, awslogs-region = local.region, awslogs-stream-prefix = "otel" }
    }
  }
}

resource "aws_ecs_task_definition" "api" {
  family                   = "${local.prefix}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 1024
  memory                   = 2048
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.api.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }
  container_definitions = jsonencode([
    {
      name                   = "api"
      image                  = var.container_image
      essential              = true
      readonlyRootFilesystem = true
      user                   = "10001"
      portMappings           = [{ containerPort = var.container_port, protocol = "tcp" }]
      environment            = concat(local.common_env, [{ name = "REQUEST_DEADLINE_MS", value = "2000" }, { name = "MAX_INFLIGHT", value = "64" }])
      secrets                = local.db_secrets
      linuxParameters        = { initProcessEnabled = true }
      stopTimeout            = 30
      logConfiguration = {
        logDriver = "awslogs"
        options   = { awslogs-group = aws_cloudwatch_log_group.service["api"].name, awslogs-region = local.region, awslogs-stream-prefix = "api" }
      }
    },
    local.otel_sidecar,
  ])
}

resource "aws_ecs_task_definition" "worker" {
  family                   = "${local.prefix}-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.worker.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }
  container_definitions = jsonencode([
    {
      name                   = "worker"
      image                  = var.worker_image
      essential              = true
      readonlyRootFilesystem = true
      user                   = "10001"
      environment            = concat(local.common_env, [{ name = "WORKER_TIMEOUT_SECONDS", value = tostring(var.worker_timeout_seconds) }])
      secrets                = local.db_secrets
      linuxParameters        = { initProcessEnabled = true }
      stopTimeout            = 120 # finish the in-flight message before shutdown
      logConfiguration = {
        logDriver = "awslogs"
        options   = { awslogs-group = aws_cloudwatch_log_group.service["worker"].name, awslogs-region = local.region, awslogs-stream-prefix = "worker" }
      }
    },
    local.otel_sidecar,
  ])
}

# Lets ECS shift ALB listener-rule weights during canary deployments.
resource "aws_iam_role" "ecs_infrastructure" {
  name = "${local.prefix}-ecs-infrastructure"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "ecs.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_infrastructure" {
  role       = aws_iam_role.ecs_infrastructure.name
  policy_arn = "${local.arn_pfx}:iam::aws:policy/AmazonECSInfrastructureRolePolicyForLoadBalancers"
}

resource "aws_ecs_service" "api" {
  name                               = "api"
  cluster                            = aws_ecs_cluster.this.id
  task_definition                    = aws_ecs_task_definition.api.arn
  desired_count                      = local.api_min_tasks
  launch_type                        = "FARGATE"
  platform_version                   = "LATEST"
  availability_zone_rebalancing      = "ENABLED"
  enable_execute_command             = false # no shell access into production tasks
  propagate_tags                     = "SERVICE"
  health_check_grace_period_seconds  = 30
  deployment_minimum_healthy_percent = 100 # never drop below the N+1 floor during a rollout
  deployment_maximum_percent         = 200

  network_configuration {
    subnets          = aws_subnet.app[*].id
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api["blue"].arn
    container_name   = "api"
    container_port   = var.container_port
    advanced_configuration {
      alternate_target_group_arn = aws_lb_target_group.api["green"].arn
      production_listener_rule   = aws_lb_listener_rule.from_cloudfront.arn
      role_arn                   = aws_iam_role.ecs_infrastructure.arn
    }
  }

  deployment_configuration {
    strategy             = "CANARY"
    bake_time_in_minutes = var.canary_bake_minutes # old revision kept warm for instant rollback
    canary_configuration {
      canary_percent              = var.canary_percent
      canary_bake_time_in_minutes = var.canary_bake_minutes
    }
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # Health checks only prove the task is up. These SLO alarms decide whether it is healthy for real
  # traffic; any of them firing during the canary rolls the deployment back automatically.
  alarms {
    enable      = true
    rollback    = true
    alarm_names = [aws_cloudwatch_metric_alarm.error_rate_fast.alarm_name, aws_cloudwatch_metric_alarm.latency_p99.alarm_name, aws_cloudwatch_metric_alarm.db_connections.alarm_name]
  }

  lifecycle {
    ignore_changes = [desired_count] # owned by autoscaling
  }
}

resource "aws_ecs_service" "worker" {
  name                               = "worker"
  cluster                            = aws_ecs_cluster.this.id
  task_definition                    = aws_ecs_task_definition.worker.arn
  desired_count                      = local.worker_min_tasks
  launch_type                        = "FARGATE"
  platform_version                   = "LATEST"
  availability_zone_rebalancing      = "ENABLED"
  enable_execute_command             = false
  propagate_tags                     = "SERVICE"
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  network_configuration {
    subnets          = aws_subnet.app[*].id
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  alarms {
    enable      = true
    rollback    = true
    alarm_names = [aws_cloudwatch_metric_alarm.dlq_not_empty.alarm_name]
  }

  lifecycle {
    ignore_changes = [desired_count]
  }
}

# ---------------------------------------------------------------- autoscaling
resource "aws_appautoscaling_target" "api" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.api.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = local.api_min_tasks
  max_capacity       = var.max_tasks
}

# Scale on requests per task (the measured capacity unit), computed across both target groups so it
# keeps working while a canary deployment splits traffic.
resource "aws_appautoscaling_policy" "api_rps" {
  name               = "requests-per-task"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.api.service_namespace
  resource_id        = aws_appautoscaling_target.api.resource_id
  scalable_dimension = aws_appautoscaling_target.api.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = var.task_rps_capacity * 0.7 # 30% headroom for bursts while new tasks start
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
    customized_metric_specification {
      metrics {
        id          = "requests"
        return_data = false
        metric_stat {
          stat = "Sum"
          metric {
            namespace   = "AWS/ApplicationELB"
            metric_name = "RequestCount"
            dimensions {
              name  = "LoadBalancer"
              value = aws_lb.this.arn_suffix
            }
          }
        }
      }
      metrics {
        id          = "tasks"
        return_data = false
        metric_stat {
          stat = "Average"
          metric {
            namespace   = "ECS/ContainerInsights"
            metric_name = "RunningTaskCount"
            dimensions {
              name  = "ClusterName"
              value = aws_ecs_cluster.this.name
            }
            dimensions {
              name  = "ServiceName"
              value = aws_ecs_service.api.name
            }
          }
        }
      }
      metrics {
        id          = "rps_per_task"
        expression  = "requests / 60 / tasks"
        label       = "Requests per second per task"
        return_data = true
      }
    }
  }
}

resource "aws_appautoscaling_target" "worker" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.worker.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = local.worker_min_tasks
  max_capacity       = 30
}

# Scale on backlog per task (queue depth ÷ running workers), not CPU.
resource "aws_appautoscaling_policy" "worker_backlog" {
  name               = "backlog-per-task"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.worker.service_namespace
  resource_id        = aws_appautoscaling_target.worker.resource_id
  scalable_dimension = aws_appautoscaling_target.worker.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = var.worker_max_backlog_per_task
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
    customized_metric_specification {
      metrics {
        id          = "visible"
        return_data = false
        metric_stat {
          stat = "Average"
          metric {
            namespace   = "AWS/SQS"
            metric_name = "ApproximateNumberOfMessagesVisible"
            dimensions {
              name  = "QueueName"
              value = aws_sqs_queue.jobs.name
            }
          }
        }
      }
      metrics {
        id          = "tasks"
        return_data = false
        metric_stat {
          stat = "Average"
          metric {
            namespace   = "ECS/ContainerInsights"
            metric_name = "RunningTaskCount"
            dimensions {
              name  = "ClusterName"
              value = aws_ecs_cluster.this.name
            }
            dimensions {
              name  = "ServiceName"
              value = aws_ecs_service.worker.name
            }
          }
        }
      }
      metrics {
        id          = "backlog_per_task"
        expression  = "visible / tasks"
        label       = "Messages waiting per worker"
        return_data = true
      }
    }
  }
}
