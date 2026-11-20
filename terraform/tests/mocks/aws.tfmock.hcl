mock_data "aws_availability_zones" {
  defaults = { names = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d"] }
}
mock_data "aws_region" {
  defaults = { region = "us-east-1" }
}
mock_data "aws_caller_identity" {
  defaults = { account_id = "111111111111" }
}
mock_data "aws_partition" {
  defaults = { partition = "aws" }
}
mock_data "aws_iam_policy_document" {
  defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
}
mock_resource "aws_kms_key" {
  defaults = { arn = "arn:aws:kms:us-east-1:111111111111:key/00000000-0000-0000-0000-000000000000" }
}
mock_resource "aws_sqs_queue" {
  defaults = { arn = "arn:aws:sqs:us-east-1:111111111111:jobs", url = "https://sqs.us-east-1.amazonaws.com/111111111111/jobs" }
}
mock_resource "aws_secretsmanager_secret" {
  defaults = { arn = "arn:aws:secretsmanager:us-east-1:111111111111:secret:docflow-prod/aurora/app-AbCdEf" }
}
mock_resource "aws_iam_role" {
  defaults = { arn = "arn:aws:iam::111111111111:role/mock" }
}
mock_resource "aws_lb" {
  defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:111111111111:loadbalancer/app/docflow/abc", arn_suffix = "app/docflow/abc" }
}
mock_resource "aws_lb_target_group" {
  defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:111111111111:targetgroup/docflow/abc" }
}
mock_resource "aws_lb_listener" {
  defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:111111111111:listener/app/docflow/abc/def" }
}
mock_resource "aws_lb_listener_rule" {
  defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:111111111111:listener-rule/app/docflow/abc/def/ghi" }
}
mock_resource "aws_cloudwatch_log_group" {
  defaults = { arn = "arn:aws:logs:us-east-1:111111111111:log-group:mock" }
}
mock_resource "aws_s3_bucket" {
  defaults = { arn = "arn:aws:s3:::docflow-alb-logs" }
}
mock_resource "aws_ecs_task_definition" {
  defaults = { arn = "arn:aws:ecs:us-east-1:111111111111:task-definition/docflow:1" }
}
mock_resource "aws_sns_topic" {
  defaults = { arn = "arn:aws:sns:us-east-1:111111111111:alarms" }
}
mock_resource "aws_rds_cluster" {
  defaults = { arn = "arn:aws:rds:us-east-1:111111111111:cluster:docflow", engine = "aurora-postgresql", engine_version = "16.6" }
}

mock_data "aws_ip_ranges" {
  defaults = { cidr_blocks = ["15.177.0.0/18", "54.243.31.192/26"] }
}
mock_data "aws_cloudfront_cache_policy" {
  defaults = { id = "managed-policy" }
}
mock_data "aws_cloudfront_origin_request_policy" {
  defaults = { id = "managed-policy" }
}
mock_data "aws_cloudfront_response_headers_policy" {
  defaults = { id = "managed-policy" }
}
mock_resource "aws_wafv2_web_acl" {
  defaults = { arn = "arn:aws:wafv2:us-east-1:111111111111:global/webacl/docflow/abc" }
}
mock_resource "aws_cloudfront_distribution" {
  defaults = { domain_name = "d111111abcdef8.cloudfront.net", hosted_zone_id = "Z2FDTNDATAQYW2" }
}
