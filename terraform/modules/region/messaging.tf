# Async document processing: SQS with a dead-letter queue. Delivery is at-least-once, so the worker
# is idempotent (see resilience-patterns-lab for the implementation and its tests).
resource "aws_sqs_queue" "jobs_dlq" {
  name                              = "${local.prefix}-jobs-dlq"
  message_retention_seconds         = 1209600 # 14 days to investigate and redrive
  kms_master_key_id                 = aws_kms_key.platform.arn
  kms_data_key_reuse_period_seconds = 300
}

resource "aws_sqs_queue" "jobs" {
  name                              = "${local.prefix}-jobs"
  visibility_timeout_seconds        = var.worker_timeout_seconds * 6 # AWS guidance: >= 6x the processing timeout
  message_retention_seconds         = 345600
  receive_wait_time_seconds         = 20 # long polling
  kms_master_key_id                 = aws_kms_key.platform.arn
  kms_data_key_reuse_period_seconds = 300
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.jobs_dlq.arn
    maxReceiveCount     = 5 # poison messages are isolated after five failed attempts
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "jobs_dlq" {
  queue_url = aws_sqs_queue.jobs_dlq.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.jobs.arn]
  })
}
