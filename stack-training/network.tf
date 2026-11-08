# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Private VPC for the pipeline's SageMaker Processing and Training jobs and the
# scheduled drift and fairness jobs. The subnets have no internet gateway and
# no NAT gateway, so the jobs reach nothing outside the VPC except Amazon S3,
# through a gateway endpoint whose policy admits only this project's buckets,
# and CloudWatch metrics, through an interface endpoint. SageMaker itself pulls the
# container images from Amazon ECR and ships the job logs to CloudWatch Logs,
# so neither needs a route from these subnets. Python packages for the
# processing steps come from a wheelhouse in the scripts bucket
# (scripts/script_uploader.sh), not from PyPI.
#
# Created when training_vpc_enabled = true and vpc_config is null; vpc_config
# places the jobs in your own subnets instead.

locals {
  create_training_vpc = var.training_vpc_enabled && var.vpc_config == null
  training_vpc_name   = "${var.project_name}-training"

  project_bucket_arns = [
    module.s3_raw_data.bucket_arn,
    module.s3_processed_data.bucket_arn,
    module.s3_scripts.bucket_arn,
    module.s3_model_artifacts.bucket_arn,
    module.s3_inference_results.bucket_arn,
    module.s3_monitoring.bucket_arn,
  ]
}

data "aws_availability_zones" "available" {
  #checkov:skip=CKV_AWS_394:Zone names differ per account and zone IDs per Region, so a sample for any Region cannot pin them; the subnets take the first two available zones, and vpc_config runs the jobs in subnets you choose
  count = local.create_training_vpc ? 1 : 0
  state = "available"
}

# KICS: flow logs are aws_flow_log.training (training_vpc_flow_logs); no Network Firewall because the subnets have no route out of the VPC
# kics-scan ignore-line
resource "aws_vpc" "training" {
  count = local.create_training_vpc ? 1 : 0

  cidr_block = var.training_vpc_cidr
  # The S3 gateway endpoint needs the default VPC DNS so standard S3 URLs
  # resolve to it.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = local.training_vpc_name }
}

# The default security group of a VPC allows all traffic between its members.
# Nothing uses it here; managing it with no rules removes that allowance.
resource "aws_default_security_group" "training" {
  count  = local.create_training_vpc ? 1 : 0
  vpc_id = aws_vpc.training[0].id

  tags = { Name = "${local.training_vpc_name}-default-unused" }
}

resource "aws_subnet" "training" {
  count = local.create_training_vpc ? 2 : 0

  vpc_id                  = aws_vpc.training[0].id
  availability_zone       = data.aws_availability_zones.available[0].names[count.index]
  cidr_block              = cidrsubnet(var.training_vpc_cidr, 1, count.index)
  map_public_ip_on_launch = false

  tags = { Name = "${local.training_vpc_name}-private-${data.aws_availability_zones.available[0].names[count.index]}" }
}

# One route table with no default route: the only route besides the local one
# is the S3 prefix list the gateway endpoint adds.
resource "aws_route_table" "training" {
  count  = local.create_training_vpc ? 1 : 0
  vpc_id = aws_vpc.training[0].id

  tags = { Name = "${local.training_vpc_name}-private" }
}

resource "aws_route_table_association" "training" {
  count = local.create_training_vpc ? 2 : 0

  subnet_id      = aws_subnet.training[count.index].id
  route_table_id = aws_route_table.training[0].id
}

resource "aws_vpc_endpoint" "s3" {
  count = local.create_training_vpc ? 1 : 0

  vpc_id            = aws_vpc.training[0].id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.training[0].id]

  # The jobs read and write only the project buckets; anything else through
  # this endpoint is denied, so a job cannot copy data to another bucket.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "ProjectBucketsOnly"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:*"
      Resource  = concat(local.project_bucket_arns, [for arn in local.project_bucket_arns : "${arn}/*"])
    }]
  })

  tags = { Name = "${local.training_vpc_name}-s3" }
}

resource "aws_security_group" "training_jobs" {
  #checkov:skip=CKV2_AWS_5:Attached by SageMaker to the job ENIs through the pipeline definition's VpcConfig
  count = local.create_training_vpc ? 1 : 0

  name        = "${local.training_vpc_name}-jobs"
  description = "SageMaker training and processing jobs: HTTPS to Amazon S3 only"
  vpc_id      = aws_vpc.training[0].id

  tags = { Name = "${local.training_vpc_name}-jobs" }
}

resource "aws_vpc_security_group_egress_rule" "jobs_to_s3" {
  count = local.create_training_vpc ? 1 : 0

  security_group_id = aws_security_group.training_jobs[0].id
  description       = "HTTPS to Amazon S3 through the gateway endpoint"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  prefix_list_id    = aws_vpc_endpoint.s3[0].prefix_list_id
}

# The scheduled drift and fairness jobs (stack-inference monitoring.tf) publish
# their metrics with PutMetricData, which needs this interface endpoint; it is
# billed per Availability Zone hour.
resource "aws_security_group" "monitoring_endpoint" {
  #checkov:skip=CKV2_AWS_5:Attached to aws_vpc_endpoint.monitoring through security_group_ids; Checkov does not follow count-indexed references
  count = local.create_training_vpc && var.training_vpc_monitoring_endpoint ? 1 : 0

  name        = "${local.training_vpc_name}-monitoring-endpoint"
  description = "CloudWatch metrics interface endpoint: HTTPS from the SageMaker jobs only"
  vpc_id      = aws_vpc.training[0].id

  tags = { Name = "${local.training_vpc_name}-monitoring-endpoint" }
}

resource "aws_vpc_security_group_ingress_rule" "monitoring_endpoint_from_jobs" {
  count = local.create_training_vpc && var.training_vpc_monitoring_endpoint ? 1 : 0

  security_group_id            = aws_security_group.monitoring_endpoint[0].id
  description                  = "HTTPS from the SageMaker jobs"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.training_jobs[0].id
}

resource "aws_vpc_security_group_egress_rule" "jobs_to_monitoring_endpoint" {
  count = local.create_training_vpc && var.training_vpc_monitoring_endpoint ? 1 : 0

  security_group_id            = aws_security_group.training_jobs[0].id
  description                  = "HTTPS to the CloudWatch metrics interface endpoint"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.monitoring_endpoint[0].id
}

resource "aws_vpc_endpoint" "monitoring" {
  count = local.create_training_vpc && var.training_vpc_monitoring_endpoint ? 1 : 0

  vpc_id              = aws_vpc.training[0].id
  service_name        = "com.amazonaws.${var.aws_region}.monitoring"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.training[*].id
  security_group_ids  = [aws_security_group.monitoring_endpoint[0].id]
  private_dns_enabled = true

  tags = { Name = "${local.training_vpc_name}-monitoring" }
}

# SageMaker asks for traffic between the instances of one multi-instance job
# (https://docs.aws.amazon.com/sagemaker/latest/dg/process-vpc.html). The
# rules admit only members of this group, so nothing outside it can connect.
resource "aws_vpc_security_group_ingress_rule" "jobs_from_jobs" {
  count = local.create_training_vpc ? 1 : 0

  security_group_id            = aws_security_group.training_jobs[0].id
  description                  = "Instances of the same multi-instance job"
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.training_jobs[0].id
}

resource "aws_vpc_security_group_egress_rule" "jobs_to_jobs" {
  count = local.create_training_vpc ? 1 : 0

  security_group_id            = aws_security_group.training_jobs[0].id
  description                  = "Instances of the same multi-instance job"
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.training_jobs[0].id
}

################################################################################
# VPC flow logs
################################################################################

# Every accepted and rejected flow of the job ENIs, in a log group encrypted
# with the project key. Flow records are small, so the cost is the CloudWatch
# Logs ingestion of a few records per connection.
resource "aws_cloudwatch_log_group" "training_vpc_flow_logs" {
  count = local.create_training_vpc && var.training_vpc_flow_logs ? 1 : 0

  name              = "/aws/vpc/${local.training_vpc_name}/flow-logs"
  retention_in_days = var.log_retention_days
  kms_key_id        = module.kms.key_arn
}

resource "aws_iam_role" "training_vpc_flow_logs" {
  count = local.create_training_vpc && var.training_vpc_flow_logs ? 1 : 0

  name                 = "${var.project_name}-training-vpc-flow-logs-role"
  description          = "Lets VPC Flow Logs publish the ${var.project_name} training VPC flow records to CloudWatch Logs"
  permissions_boundary = var.permissions_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:vpc-flow-log/*" }
      }
    }]
  })
}

resource "aws_iam_role_policy" "training_vpc_flow_logs" {
  count = local.create_training_vpc && var.training_vpc_flow_logs ? 1 : 0

  name = "${var.project_name}-training-vpc-flow-logs-policy"
  role = aws_iam_role.training_vpc_flow_logs[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams",
        ]
        Resource = [
          aws_cloudwatch_log_group.training_vpc_flow_logs[0].arn,
          "${aws_cloudwatch_log_group.training_vpc_flow_logs[0].arn}:*",
        ]
      },
      {
        # DescribeLogGroups has no resource type, so it takes "*".
        Effect   = "Allow"
        Action   = "logs:DescribeLogGroups"
        Resource = "*"
      },
    ]
  })
}

resource "aws_flow_log" "training" {
  count = local.create_training_vpc && var.training_vpc_flow_logs ? 1 : 0

  vpc_id               = aws_vpc.training[0].id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.training_vpc_flow_logs[0].arn
  iam_role_arn         = aws_iam_role.training_vpc_flow_logs[0].arn

  tags = { Name = "${local.training_vpc_name}-flow-logs" }
}
