# Three tiers × N AZs. Public: ALB + NAT. App: ECS tasks. Data: Aurora + RDS Proxy (no internet route at all).
data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_region" "current" {}

locals {
  prefix = "${var.name}-${var.environment}-${var.role}"
  azs    = slice(data.aws_availability_zones.available.names, 0, var.az_count)
  # /24 per subnet: public 0-9, app 10-19, data 20-29 (third octet) — documented in docs/network-plan.md
  public_cidrs = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i)]
  app_cidrs    = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, 10 + i)]
  data_cidrs   = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, 20 + i)]
  nat_count    = var.nat_mode == "per_az" ? var.az_count : 1
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = local.prefix }
}

# Lock down the default security group so nothing can accidentally use it.
resource "aws_default_security_group" "locked" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${local.prefix}-default-unused" }
}

resource "aws_subnet" "public" {
  count             = var.az_count
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.public_cidrs[count.index]
  availability_zone = local.azs[count.index]
  tags              = { Name = "${local.prefix}-public-${local.azs[count.index]}", Tier = "public" }
}

resource "aws_subnet" "app" {
  count             = var.az_count
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.app_cidrs[count.index]
  availability_zone = local.azs[count.index]
  tags              = { Name = "${local.prefix}-app-${local.azs[count.index]}", Tier = "app" }
}

resource "aws_subnet" "data" {
  count             = var.az_count
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.data_cidrs[count.index]
  availability_zone = local.azs[count.index]
  tags              = { Name = "${local.prefix}-data-${local.azs[count.index]}", Tier = "data" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = local.prefix }
}

resource "aws_eip" "nat" {
  count  = local.nat_count
  domain = "vpc"
  tags   = { Name = "${local.prefix}-nat-${local.azs[count.index]}" }
}

resource "aws_nat_gateway" "this" {
  count         = local.nat_count
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = { Name = "${local.prefix}-nat-${local.azs[count.index]}" }
  depends_on    = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "${local.prefix}-public" }
}

resource "aws_route_table_association" "public" {
  count          = var.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One route table per AZ: tasks in AZ-x leave through the NAT in AZ-x, so losing an AZ never takes
# egress away from the surviving AZs.
resource "aws_route_table" "app" {
  count  = var.az_count
  vpc_id = aws_vpc.this.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[var.nat_mode == "per_az" ? count.index : 0].id
  }
  tags = { Name = "${local.prefix}-app-${local.azs[count.index]}" }
}

resource "aws_route_table_association" "app" {
  count          = var.az_count
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.app[count.index].id
}

# Data tier: local routes only.
resource "aws_route_table" "data" {
  count  = var.az_count
  vpc_id = aws_vpc.this.id
  route  = [] # explicitly empty: Terraform removes any route added outside code
  tags   = { Name = "${local.prefix}-data-${local.azs[count.index]}" }
}

resource "aws_route_table_association" "data" {
  count          = var.az_count
  subnet_id      = aws_subnet.data[count.index].id
  route_table_id = aws_route_table.data[count.index].id
}

# ---------------------------------------------------------------- VPC endpoints
# AWS API traffic stays on the AWS network: no NAT dependency (or NAT cost) for image pulls,
# logs, secrets, queue and KMS calls.
locals {
  interface_endpoints = ["ecr.api", "ecr.dkr", "logs", "secretsmanager", "sqs", "kms", "sts", "ssm", "monitoring", "xray"]
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.app[*].id
  tags              = { Name = "${local.prefix}-s3" }
}

resource "aws_vpc_endpoint" "interface" {
  for_each            = toset(local.interface_endpoints)
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = aws_subnet.app[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  tags                = { Name = "${local.prefix}-${each.key}" }
}

# ---------------------------------------------------------------- flow logs
resource "aws_cloudwatch_log_group" "flow" {
  name              = "/vpc/${local.prefix}/flow-logs"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.platform.arn
}

resource "aws_flow_log" "this" {
  vpc_id                   = aws_vpc.this.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow.arn
  iam_role_arn             = aws_iam_role.flow_logs.arn
  max_aggregation_interval = 60
}
